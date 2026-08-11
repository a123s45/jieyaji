import base64
import json
import os
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
            'threads': 1,
            'delete_source': False,
            'width': 960,
            'height': 640,
            'x': None,
            'y': None,
        }


def save_config(cfg):
    with open(CONFIG, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)


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


def run_worker(job, file_path):
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
        try:
            with open(log_path, 'a', encoding='utf-8') as f:
                f.write('FAIL worker error: %s\n' % exc)
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
    threading.Thread(target=run_worker, args=(job, file_path), daemon=True).start()
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
    job_id = uuid.uuid4().hex
    threads = max(1, min(8, int(data.get('threads', 1))))
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
        'password_file': data.get('password_file') or PW_DEFAULT,
        'collapse': bool(data.get('collapse', True)),
        'delete_source': bool(data.get('delete_source', False)),
        'magic_fallback': bool(data.get('magic_fallback', False)),
    }
    with jobs_lock:
        jobs[job_id] = job
    for _ in range(min(threads, len(files))):
        start_next(job)
    return jsonify({'job_id': job_id})


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
