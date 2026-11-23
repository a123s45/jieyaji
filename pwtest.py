# -*- coding: utf-8 -*-
"""
pwtest.py - in-process password tester for 解压姬 (ported from BazzaCuda/Extractor logic)

Usage: python pwtest.py <archive> <password_file>

Prints one line to stdout:
  FOUND <base64-utf8-password>   exit 0
  NOTFOUND                       exit 1
  UNSUPPORTED                    exit 2

Key ideas ported from Extractor (main.pas, test7zArchive / findPW):
  1. test passwords in-process (no subprocess per attempt)
  2. verify a password by extracting ONLY THE SMALLEST file and comparing size
  3. move-to-front: remember recently matched passwords in a hot list
"""
import base64
import ctypes
import os
import sys
import uuid
from contextlib import contextmanager

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(BASE, 'bin', 'pylibs'))
sys.path.insert(0, BASE)

HOT_FILE = os.path.join(BASE, 'data', 'hot_passwords.txt')
HOT_LIMIT = 50

# Same mutex name as Invoke-WithFileMutex 'Local\JieyajiHotPw' in
# extract-worker.ps1: worker processes and this helper must serialise their
# read-modify-write cycles on the shared hot password cache.
HOT_MUTEX_NAME = 'Local\\JieyajiHotPw'
WAIT_OBJECT_0 = 0x00000000
WAIT_ABANDONED = 0x00000080


def _kernel32():
    k32 = ctypes.WinDLL('kernel32', use_last_error=True)
    k32.CreateMutexW.restype = ctypes.c_void_p
    k32.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
    k32.WaitForSingleObject.restype = ctypes.c_uint32
    k32.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    k32.ReleaseMutex.restype = ctypes.c_bool
    k32.ReleaseMutex.argtypes = [ctypes.c_void_p]
    k32.CloseHandle.restype = ctypes.c_bool
    k32.CloseHandle.argtypes = [ctypes.c_void_p]
    return k32


@contextmanager
def file_mutex(name, timeout_ms=20000):
    """Cross-process named mutex. Yields False on failure so callers degrade
    instead of deadlocking (an unlocked write beats a hung worker)."""
    k32 = None
    handle = None
    acquired = False
    try:
        k32 = _kernel32()
        handle = k32.CreateMutexW(None, False, name)
        if handle:
            acquired = k32.WaitForSingleObject(handle, int(timeout_ms)) in (WAIT_OBJECT_0, WAIT_ABANDONED)
    except Exception:
        handle = None
    try:
        yield acquired
    finally:
        if handle and k32:
            try:
                if acquired:
                    k32.ReleaseMutex(handle)
                k32.CloseHandle(handle)
            except Exception:
                pass


def read_passwords(pw_file):
    seen = set()
    out = []

    def add(p):
        if p not in seen:
            seen.add(p)
            out.append(p)

    add('')  # no-password attempt first, like Extractor's entry at index 0
    try:
        with open(HOT_FILE, 'r', encoding='utf-8-sig') as f:
            for line in f.read().splitlines():
                if line:
                    add(line)
    except OSError:
        pass
    try:
        with open(pw_file, 'r', encoding='utf-8-sig', errors='replace') as f:
            for line in f.read().splitlines():
                if line:
                    add(line)
                    t = line.strip()
                    if t and t != line:
                        add(t)
    except OSError:
        pass
    return out


def mark_hot(pw):
    if not pw:
        return
    # Several workers can match different passwords at the same moment. The old
    # open('w') truncated the file in place, so a concurrent writer could read a
    # half-written list (or erase the other worker's entry). Serialise on the
    # shared mutex and swap in a fully written temp file atomically.
    with file_mutex(HOT_MUTEX_NAME):
        tmp = None
        try:
            lines = []
            if os.path.isfile(HOT_FILE):
                with open(HOT_FILE, 'r', encoding='utf-8-sig') as f:
                    lines = [l for l in f.read().splitlines() if l]
            lines = [pw] + [l for l in lines if l != pw]
            os.makedirs(os.path.dirname(HOT_FILE), exist_ok=True)
            tmp = '%s.%d.%s.tmp' % (HOT_FILE, os.getpid(), uuid.uuid4().hex[:8])
            with open(tmp, 'w', encoding='utf-8') as f:
                f.write('\n'.join(lines[:HOT_LIMIT]) + '\n')
            os.replace(tmp, HOT_FILE)
            tmp = None
        except OSError:
            if tmp:
                try:
                    os.remove(tmp)
                except OSError:
                    pass


class UnsupportedScheme(Exception):
    pass


# Verifying a password means decompressing the smallest entry into memory, once
# per candidate. On an archive whose smallest entry is itself huge (a 2GB
# single-file pack) that degenerates into "decompress everything for every
# password" - measured at 375s on a 2GB single-file archive. Past this limit we
# bail out to the 7z loop instead: there a wrong password is rejected instantly
# by the AES check value, and only the right one pays for an extraction.
VERIFY_SIZE_LIMIT = 64 * 1024 * 1024


def try_zip(path, pw):
    import zipfile
    with zipfile.ZipFile(path) as zf:
        best = None
        for info in zf.infolist():
            if info.is_dir() or info.file_size == 0:
                continue
            if best is None or info.file_size < best.file_size:
                best = info
        if best is None:
            return None  # nothing to verify against
        if best.file_size > VERIFY_SIZE_LIMIT:
            raise UnsupportedScheme()
        if best.compress_type == 99:
            # WinZip AES: zipfile can never verify this - bail out entirely,
            # let the 7z loop handle it instead of failing every attempt slowly
            raise UnsupportedScheme()
        pwd = pw.encode('utf-8') if pw else None
        data = zf.read(best, pwd=pwd)
        return len(data) == best.file_size


def try_7z(path, pw):
    import py7zr
    from py7zr.io import BytesIOFactory
    with py7zr.SevenZipFile(path, password=(pw if pw else None)) as z:
        best = None
        for info in z.list():
            if info.is_directory or info.uncompressed == 0:
                continue
            if best is None or info.uncompressed < best.uncompressed:
                best = info
        if best is None:
            return None
        if best.uncompressed > VERIFY_SIZE_LIMIT:
            raise UnsupportedScheme()
        factory = BytesIOFactory(best.uncompressed + 4096)
        z.extract(targets=[best.filename], factory=factory)
        bio = factory.get(best.filename)
        if bio is None:
            return False
        data = bio.read()
        return len(data) == best.uncompressed


def _dll_find(archive, cands):
    """Fastest path: 7z.dll in-process (see arc7z.py).

    Returns ('found', pw) / ('nomatch', None) / ('unsupported', reason).
    'nomatch' is a real answer; 'unsupported' means the caller must fall back
    to the pure-python testers below.
    """
    try:
        import arc7z
    except Exception as exc:                       # missing dll, bad arch...
        return 'unsupported', 'import arc7z: %s' % exc
    try:
        pw, stats = arc7z.find(archive, cands)
    except Exception as exc:                       # never let the fast path break us
        return 'unsupported', 'arc7z: %r' % (exc,)
    if stats.get('unsupported'):
        return 'unsupported', stats.get('reason') or stats.get('mode')
    if pw is not None:
        return 'found', pw
    return 'nomatch', None


def main():
    if len(sys.argv) < 3:
        print('UNSUPPORTED')
        return 2
    archive = sys.argv[1]
    pw_file = sys.argv[2]
    cands = read_passwords(pw_file)

    # 1) 7z.dll handles zip/zip-AES/7z/-mhe/rar/rar5 and rejects a wrong
    #    password from the AES verifier in microseconds instead of spawning
    #    7z.exe (37 ms) per candidate.
    state, val = _dll_find(archive, cands)
    if state == 'found':
        sys.stdout.write('FOUND ' + base64.b64encode(val.encode('utf-8')).decode('ascii') + '\n')
        sys.stdout.flush()
        mark_hot(val)
        return 0
    if state == 'nomatch':
        print('NOTFOUND')
        return 1
    sys.stderr.write('pwtest: dll path unavailable (%s), trying pure python\n' % val)

    # 2) Pure python fallback (no native code involved).
    ext = os.path.splitext(archive)[1].lower()
    if ext == '.zip':
        tester = try_zip
    elif ext == '.7z':
        tester = try_7z
    else:
        print('UNSUPPORTED')
        return 2

    for pw in cands:
        try:
            r = tester(archive, pw)
        except UnsupportedScheme:
            print('UNSUPPORTED')
            return 2
        except Exception:
            r = False
        if r:
            sys.stdout.write('FOUND ' + base64.b64encode(pw.encode('utf-8')).decode('ascii') + '\n')
            sys.stdout.flush()
            mark_hot(pw)
            return 0
    print('NOTFOUND')
    return 1


if __name__ == '__main__':
    sys.exit(main())
