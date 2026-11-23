import base64
import json
import os
import re
import subprocess
import tempfile
import threading
import time
import uuid

from flask import Flask, jsonify, request, send_from_directory

BASE = r'D:\解压姬'
WEBUI = os.path.join(BASE, 'webui')
BG = os.path.join(BASE, 'backgrounds')
CONFIG = os.path.join(BASE, 'gui_config.json')
WORKER = os.path.join(BASE, 'extract-worker.ps1')
MAGIC = os.path.join(BASE, 'magic-extractor.exe')
PW_DEFAULT = os.path.join(BASE, 'passwords.txt')
ICON = os.path.join(BG, 'icon.ico')

CREATE_NO_WINDOW = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
MAX_JOBS = 20

app = Flask(__name__, static_folder=None)

jobs = {}
jobs_lock = threading.Lock()


def load_config():
    try:
        with open(CONFIG, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {
            'background': '',
            'panel_color': '#ffffff',
            'panel_opacity': 0.5,
            'threads': 0,
            'delete_source': False,
            'width': 960,
            'height': 640,
            'x': None,
            'y': None,
        }


def save_config(cfg):
    with open(CONFIG, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)


def _screen_metrics():
    """(primary_w, primary_h, virt_x, virt_y, virt_w, virt_h); fallback to 1080p."""
    try:
        import ctypes
        user32 = ctypes.windll.user32
        return (
            int(user32.GetSystemMetrics(0)),   # SM_CXSCREEN (primary)
            int(user32.GetSystemMetrics(1)),   # SM_CYSCREEN (primary)
            int(user32.GetSystemMetrics(76)),  # SM_XVIRTUALSCREEN
            int(user32.GetSystemMetrics(77)),  # SM_YVIRTUALSCREEN
            int(user32.GetSystemMetrics(78)),  # SM_CXVIRTUALSCREEN
            int(user32.GetSystemMetrics(79)),  # SM_CYVIRTUALSCREEN
        )
    except Exception:
        return (1920, 1080, 0, 0, 1920, 1080)


def _valid_pos(x, y, w, h):
    """Reject off-screen coordinates (pywebview reports x=-25600 when minimized)."""
    if x is None or y is None:
        return False
    try:
        x, y, w, h = int(x), int(y), int(w), int(h)
    except (TypeError, ValueError):
        return False
    _, _, vx, vy, vw, vh = _screen_metrics()
    return (x < vx + vw - 80 and y < vy + vh - 80
            and x + w > vx + 80 and y + h > vy + 80)


def _primary_center(w, h):
    """Center of screen 1 for a window of size (w, h)."""
    cw, ch, *_ = _screen_metrics()
    return (max(0, (cw - w) // 2), max(0, (ch - h) // 2))


@app.route('/')
def index():
    return send_from_directory(WEBUI, 'index.html')


@app.route('/<path:name>')
def static_files(name):
    return send_from_directory(WEBUI, name)


@app.route('/backgrounds/<path:name>')
def background_file(name):
    return send_from_directory(BG, name)


@app.route('/api/config', methods=['GET', 'POST'])
def api_config():
    cfg = load_config()
    if request.method == 'POST':
        data = request.get_json(force=True, silent=True) or {}
        cfg.update(data)
        save_config(cfg)
    return jsonify(cfg)


@app.route('/api/background', methods=['POST'])
def api_background():
    raw = request.get_data(as_text=True)
    if not raw.startswith('data:image/'):
        return jsonify({'error': 'not an image data url'}), 400
    header, b64 = raw.split(',', 1)
    ext = 'png'
    if 'jpeg' in header or 'jpg' in header:
        ext = 'jpg'
    elif 'gif' in header:
        ext = 'gif'
    elif 'bmp' in header:
        ext = 'bmp'
    name = 'bg_' + time.strftime('%Y%m%d_%H%M%S') + '.' + ext
    os.makedirs(BG, exist_ok=True)
    with open(os.path.join(BG, name), 'wb') as f:
        f.write(base64.b64decode(b64))
    cfg = load_config()
    cfg['background'] = name
    save_config(cfg)
    return jsonify({'background': name, 'url': '/backgrounds/' + name})


@app.route('/api/password', methods=['POST'])
def api_password():
    data = request.get_json(force=True, silent=True) or {}
    pw = str(data.get('password', ''))
    if not pw:
        return jsonify({'error': 'empty password'}), 400
    targets = [PW_DEFAULT, r'D:\Extractor\passwords.txt']
    added = False
    updated = []
    for path in dict.fromkeys(targets):
        if not os.path.isfile(path):
            continue
        try:
            with open(path, 'r', encoding='utf-8-sig') as f:
                lines = f.read().splitlines()
            if pw in lines:
                updated.append({'file': path, 'added': False})
                continue
            with open(path, 'a', encoding='utf-8') as f:
                f.write(pw + '\n')
            added = True
            updated.append({'file': path, 'added': True})
        except Exception as exc:
            updated.append({'file': path, 'error': str(exc)})
    msg = '密码已导入密码本' if added else '密码已存在，未重复添加'
    return jsonify({'added': added, 'message': msg, 'updated': updated})


def norm_key(path):
    """Case/relative-insensitive identity for a path in a dedup set."""
    try:
        return os.path.normcase(os.path.abspath(path))
    except Exception:
        return path


# --------------------------------------------------------------- split volumes

_VOL_NUM = re.compile(r'^(?P<stem>.+)\.(?P<num>\d{3})$', re.I)
_VOL_PART = re.compile(r'^(?P<stem>.+)\.part(?P<num>\d+)\.rar$', re.I)
_VOL_Z = re.compile(r'^(?P<stem>.+)\.z(?P<num>\d{2})$', re.I)
_VOL_R = re.compile(r'^(?P<stem>.+)\.r(?P<num>\d{2})$', re.I)


def _volume_member(path):
    """(family, order) when path belongs to a split set, else None.

    Families: 'num:x.7z' (x.7z.001), 'part:x' (x.part1.rar), 'z:x' (x.z01),
    'r:x' (x.r00). Only the first volume of a set is extractable - the worker
    SKIPs the rest anyway, so queueing them just burns worker slots and lets
    concurrent workers poke at the same group.
    """
    leaf = os.path.basename(path)
    m = _VOL_NUM.match(leaf)
    if m:
        stem = m.group('stem')
        num = int(m.group('num'))
        if '.' in stem or num == 1:
            # x.7z.001 / x.zip.001 are unambiguously split volumes.
            return ('num:' + stem.lower(), num)
        # A bare x.002 only counts when x.001 sits next to it - otherwise it is
        # just an ordinary file whose name ends in three digits (summary.123)
        # and must not be filtered out as a stray volume.
        try:
            sibling = os.path.join(os.path.dirname(os.path.abspath(path)), stem + '.001')
            if os.path.isfile(sibling):
                return ('num:' + stem.lower(), num)
        except OSError:
            pass
        return None
    m = _VOL_PART.match(leaf)
    if m:
        return ('part:' + m.group('stem').lower(), int(m.group('num')))
    m = _VOL_Z.match(leaf)
    if m:
        return ('z:' + m.group('stem').lower(), int(m.group('num')))
    m = _VOL_R.match(leaf)
    if m:
        return ('r:' + m.group('stem').lower(), int(m.group('num')))
    return None


def filter_first_volumes(files):
    """Keep only the first volume of every split set.

    Returns (kept, skipped_count). For WinZip/old-RAR splits the first volume is
    the bare .zip/.rar, which may not have been dragged in at all - it is pulled
    from disk when present so the group still gets extracted.
    """
    plain = []
    families = {}
    for f in files:
        v = _volume_member(f)
        if not v:
            plain.append(f)
            continue
        fam, order = v
        key = os.path.dirname(os.path.abspath(f)).lower() + '|' + fam
        families.setdefault(key, []).append((order, f))

    known = {norm_key(p) for p in plain}
    kept = list(plain)
    skipped = 0
    for key, members in families.items():
        members.sort(key=lambda t: t[0])
        fam = key.split('|', 1)[1]
        head = os.path.basename(members[0][1])
        parent = os.path.dirname(os.path.abspath(members[0][1]))
        first_path = None
        if fam.startswith('z:') or fam.startswith('r:'):
            # WinZip / old-RAR: the first volume is the bare .zip / .rar
            rx = _VOL_Z if fam.startswith('z:') else _VOL_R
            ext = '.zip' if fam.startswith('z:') else '.rar'
            m = rx.match(head)
            cand = os.path.join(parent, (m.group('stem') if m else os.path.splitext(head)[0]) + ext)
            if os.path.isfile(cand):
                first_path = cand
        else:
            rx = _VOL_NUM if fam.startswith('num:') else _VOL_PART
            m = rx.match(head)
            stem = m.group('stem') if m else os.path.splitext(head)[0]
            if members[0][0] == 1:
                first_path = members[0][1]
            else:
                # Only .002/.003 was dragged in: the first volume must exist on
                # disk, otherwise the group is unextractable and gets dropped.
                if fam.startswith('num:'):
                    cand = os.path.join(parent, stem + '.001')
                    if os.path.isfile(cand):
                        first_path = cand
                else:
                    pat = re.compile('^' + re.escape(stem) + r'\.part(\d+)\.rar$', re.I)
                    best = None
                    try:
                        for n in os.listdir(parent):
                            mm = pat.match(n)
                            if mm and (best is None or int(mm.group(1)) < best[0]):
                                best = (int(mm.group(1)), os.path.join(parent, n))
                    except OSError:
                        pass
                    if best:
                        first_path = best[1]
        if first_path and norm_key(first_path) not in known:
            kept.append(first_path)
            known.add(norm_key(first_path))
        if first_path:
            skipped += sum(1 for _o, f in members if norm_key(f) != norm_key(first_path))
        else:
            skipped += len(members)
    return kept, skipped


# ------------------------------------------------------------------- threading

def auto_threads():
    """Concurrency the disk can actually use.

    CPU is never the bottleneck: every worker mostly waits on 7z / IO. Past ~4
    parallel extractors the sequential writes of one archive interleave into
    random IO and the batch gets slower, not faster (measured 3.98x on 4).
    """
    try:
        cpu = os.cpu_count() or 4
    except Exception:
        cpu = 4
    return max(2, min(4, cpu // 4))


def resolve_threads(value):
    try:
        n = int(value)
    except (TypeError, ValueError):
        n = 0
    if n <= 0:
        return auto_threads()
    return max(1, min(8, n))


def kill_worker_tree(pid):
    """Kill a worker plus its 7z/unrar grandchildren.

    Without this a worker that blows the timeout kept extracting in the
    background: the slot was freed, the job counted it as failed, and the
    orphan went on writing into the output dir while the next file ran.
    """
    try:
        subprocess.run(['taskkill', '/T', '/F', '/PID', str(pid)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       creationflags=CREATE_NO_WINDOW, timeout=20)
    except Exception:
        pass


def run_worker(job, file_path, out_lock=None):
    # Two archives that resolve to the same output folder (a.zip + a.rar sitting
    # side by side) must not extract in parallel: both would race Resolve-
    # OutputDir, see the folder missing, and merge their output into one place.
    if out_lock is not None:
        out_lock.acquire()
    try:
        _run_worker_inner(job, file_path)
    except BaseException as exc:
        # Never leave a slot occupied - an unhandled error here used to stall
        # the whole job at running=N with no way out.
        try:
            with jobs_lock:
                job['log'].append('FAIL worker crashed: %s' % exc)
                job['done'] += 1
                job['running'] -= 1
        except Exception:
            pass
        try:
            start_next(job)
        except Exception:
            pass
    finally:
        if out_lock is not None:
            out_lock.release()


def _run_worker_inner(job, file_path):
    log_path = os.path.join(tempfile.gettempdir(), 'jieyaji_worker_%s.log' % uuid.uuid4().hex)
    args = [
        'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', WORKER,
        '-FilePath', file_path,
        '-PasswordFile', job['password_file'],
        '-MagicExe', MAGIC,
        '-LogFile', log_path,
    ]
    if job.get('collapse'):
        args.append('-Collapse')
    if job.get('delete_source'):
        args.append('-DeleteSource')
    if job.get('magic_fallback'):
        args.append('-MagicFallback')
    flags = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
    try:
        proc = subprocess.Popen(args, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, creationflags=flags)
    except Exception as exc:
        msg = 'FAIL worker start error: %s' % exc
        with jobs_lock:
            job['log'].append(msg)
            job['done'] += 1
            job['running'] -= 1
        start_next(job)
        return
    # Live-tail the worker log so the UI shows progress while the worker
    # is still running (extraction of multi-GB files takes minutes).
    seen = 0
    finished = threading.Event()

    def tail_log():
        nonlocal seen
        while not finished.is_set():
            try:
                with open(log_path, 'r', encoding='utf-8-sig', errors='replace') as f:
                    lines = f.read().splitlines()
                if len(lines) > seen:
                    with jobs_lock:
                        job['log'].extend(lines[seen:])
                    seen = len(lines)
            except Exception:
                pass
            time.sleep(0.5)
        try:
            with open(log_path, 'r', encoding='utf-8-sig', errors='replace') as f:
                lines = f.read().splitlines()
            if len(lines) > seen:
                with jobs_lock:
                    job['log'].extend(lines[seen:])
        except Exception:
            pass

    tail = threading.Thread(target=tail_log, daemon=True)
    tail.start()
    try:
        proc.communicate(timeout=3600)
        ok = proc.returncode == 0
    except Exception as exc:
        ok = False
        # Kill the worker AND its 7z/unrar grandchildren, then wait for the tree
        # to actually die so the log tail is complete before we report it.
        kill_worker_tree(proc.pid)
        try:
            proc.communicate(timeout=15)
        except Exception:
            pass
        try:
            with open(log_path, 'a', encoding='utf-8') as f:
                f.write('FAIL worker timeout/error: %s (process tree killed)\n' % exc)
        except Exception:
            pass
    finally:
        finished.set()
    tail.join(timeout=2)
    try:
        os.remove(log_path)
    except Exception:
        pass
    with jobs_lock:
        if ok:
            job['ok'] += 1
        job['done'] += 1
        job['running'] -= 1
    start_next(job)


def start_next(job):
    with jobs_lock:
        if job.get('finished'):
            return False
        idx = job.get('index', 0)
        if idx >= job['total']:
            return False
        job['index'] = idx + 1
        job['running'] += 1
        file_path = job['files'][idx]
        # One lock per output identity: same-named archives extract one after
        # another, everything else keeps running fully parallel.
        key = norm_key(file_path)
        locks = job.setdefault('out_locks', {})
        lock = locks.get(key)
        if lock is None:
            lock = threading.Lock()
            locks[key] = lock
    threading.Thread(target=run_worker, args=(job, file_path, lock), daemon=True).start()
    return True


@app.route('/api/extract', methods=['POST'])
def api_extract():
    data = request.get_json(force=True, silent=True) or {}
    raw_files = [f for f in data.get('files', []) if f]
    files = []
    for f in raw_files:
        if os.path.isfile(f):
            files.append(f)
        elif os.path.isdir(f):
            for root, _dirs, names in os.walk(f):
                for n in names:
                    files.append(os.path.join(root, n))
    if not files:
        return jsonify({'error': 'no valid files'}), 400
    # de-dup: the same file can arrive twice (dragged in, then its folder too)
    seen = set()
    unique = []
    for f in files:
        k = norm_key(f)
        if k not in seen:
            seen.add(k)
            unique.append(f)
    files, skipped_vols = filter_first_volumes(unique)
    if not files:
        return jsonify({'error': '选中的全是分卷的非首卷（.002/.z01/.r00 之类），无法单独解压；请拖首卷（.001 / .zip / .rar）'}), 400
    job_id = uuid.uuid4().hex
    threads_raw = data.get('threads', 0)
    threads = resolve_threads(threads_raw)
    try:
        is_auto = int(threads_raw) <= 0
    except (TypeError, ValueError):
        is_auto = True
    job = {
        'id': job_id,
        'files': files,
        'total': len(files),
        'done': 0,
        'ok': 0,
        'running': 0,
        'index': 0,
        'finished': False,
        'log': [],
        'out_locks': {},
        'threads': threads,
        'password_file': data.get('password_file') or PW_DEFAULT,
        'collapse': bool(data.get('collapse', True)),
        'delete_source': bool(data.get('delete_source', False)),
        'magic_fallback': bool(data.get('magic_fallback', False)),
    }
    job['log'].append('[调度] %d 个包，并发 %d 线程%s' % (
        len(files), threads, '（自动）' if is_auto else ''))
    if skipped_vols:
        job['log'].append('[调度] 已跳过 %d 个分卷非首卷（.002/.z01/.r00 等），由首卷统一解压并清理' % skipped_vols)
    if threads > len(files):
        job['log'].append('[调度] 队列只有 %d 个包，线程实际用到 %d' % (len(files), len(files)))
    with jobs_lock:
        # Keep the process from growing forever across long sessions.
        if len(jobs) >= MAX_JOBS:
            stale = [k for k, v in list(jobs.items()) if v.get('finished')]
            for k in stale[:len(jobs) - MAX_JOBS + 1]:
                jobs.pop(k, None)
        jobs[job_id] = job
    for _ in range(min(threads, len(files))):
        start_next(job)
    return jsonify({'job_id': job_id, 'threads': threads, 'total': len(files), 'skipped_volumes': skipped_vols})


@app.route('/api/status/<job_id>')
def api_status(job_id):
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            return jsonify({'error': 'not found'}), 404
        status = {
            'id': job['id'],
            'total': job['total'],
            'done': job['done'],
            'ok': job['ok'],
            'running': job['running'],
            'log': job['log'][-400:],
            'files': job['files'],
            'finished': job['done'] >= job['total'] and job['running'] == 0,
        }
        if status['finished']:
            job['finished'] = True
    return jsonify(status)


def setup_drop(window):
    def on_drop(event):
        files = (event.get('dataTransfer') or {}).get('files') or []
        paths = []
        for f in files:
            p = f.get('pywebviewFullPath')
            if p:
                paths.append(p)
        if paths:
            try:
                window.evaluate_js('addPaths(' + json.dumps(paths) + ')')
            except Exception:
                pass

    def on_loaded():
        try:
            body = window.dom.body
            body.events.drop += on_drop
        except Exception:
            pass

    window.events.loaded += on_loaded


class Api:
    def pick_files(self):
        import webview
        if not webview.windows:
            return []
        w = webview.windows[0]
        try:
            result = w.create_file_dialog(
                webview.OPEN_DIALOG,
                allow_multiple=True,
                file_types=('All files (*.*)',),
            )
        except Exception:
            return []
        if isinstance(result, tuple):
            return list(result)
        if result:
            return [result]
        return []


def setup_close_save(window):
    save_timer = {'t': None}
    state = {'maximized': False, 'minimized': False}
    last = {'width': None, 'height': None, 'x': None, 'y': None}
    try:
        cfg = load_config()
        last['width'] = cfg.get('width')
        last['height'] = cfg.get('height')
        last['x'] = cfg.get('x')
        last['y'] = cfg.get('y')
    except Exception:
        pass

    def persist(width, height, x, y):
        if width is None or height is None:
            return
        if not _valid_pos(x, y, width, height):
            x, y = None, None
        try:
            cfg = load_config()
            cfg['width'] = int(width)
            cfg['height'] = int(height)
            cfg['x'] = x
            cfg['y'] = y
            save_config(cfg)
        except Exception:
            pass

    def debounced_save(width, height, x, y):
        if save_timer['t'] is not None:
            save_timer['t'].cancel()

        def do_save():
            if state['maximized'] or state['minimized']:
                return
            persist(width, height, x, y)

        save_timer['t'] = threading.Timer(0.6, do_save)
        save_timer['t'].daemon = True
        save_timer['t'].start()

    def on_resized(*args):
        if state['maximized'] or state['minimized']:
            return
        if len(args) >= 2:
            last['width'] = int(args[0])
            last['height'] = int(args[1])
            debounced_save(last['width'], last['height'], last['x'], last['y'])

    def on_moved(*args):
        if state['maximized'] or state['minimized']:
            return
        if len(args) >= 2:
            last['x'] = int(args[0])
            last['y'] = int(args[1])
            debounced_save(last['width'], last['height'], last['x'], last['y'])

    def on_maximized(*_args):
        state['maximized'] = True
        state['minimized'] = False

    def on_minimized(*_args):
        state['minimized'] = True

    def on_restored(*_args):
        state['maximized'] = False
        state['minimized'] = False

    def on_closing(*_args):
        try:
            if not state['maximized'] and not state['minimized']:
                last['width'] = window.width
                last['height'] = window.height
                last['x'] = window.x
                last['y'] = window.y
            persist(last['width'], last['height'], last['x'], last['y'])
        except Exception:
            pass

    try:
        window.events.resized += on_resized
        window.events.moved += on_moved
        window.events.maximized += on_maximized
        window.events.minimized += on_minimized
        window.events.restored += on_restored
    except Exception:
        pass
    window.events.closing += on_closing


if __name__ == '__main__':
    import webview

    cfg = load_config()
    width = int(cfg.get('width', 960))
    height = int(cfg.get('height', 640))
    x = cfg.get('x')
    y = cfg.get('y')
    if not _valid_pos(x, y, width, height):
        x, y = _primary_center(width, height)
    api = Api()
    window = webview.create_window(
        '解压姬 - 万能解压助手',
        app,
        width=width,
        height=height,
        x=x,
        y=y,
        easy_drag=False,
        js_api=api,
        background_color='#ffffff',
        confirm_close=False,
    )
    setup_drop(window)
    setup_close_save(window)
    icon = ICON if os.path.isfile(ICON) else None
    webview.start(icon=icon)
