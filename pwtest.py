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
import os
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(BASE, 'bin', 'pylibs'))

HOT_FILE = os.path.join(BASE, 'data', 'hot_passwords.txt')
HOT_LIMIT = 50


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
    try:
        lines = []
        if os.path.isfile(HOT_FILE):
            with open(HOT_FILE, 'r', encoding='utf-8-sig') as f:
                lines = [l for l in f.read().splitlines() if l]
        lines = [pw] + [l for l in lines if l != pw]
        os.makedirs(os.path.dirname(HOT_FILE), exist_ok=True)
        with open(HOT_FILE, 'w', encoding='utf-8') as f:
            f.write('\n'.join(lines[:HOT_LIMIT]) + '\n')
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


def main():
    if len(sys.argv) < 3:
        print('UNSUPPORTED')
        return 2
    archive = sys.argv[1]
    pw_file = sys.argv[2]
    ext = os.path.splitext(archive)[1].lower()
    if ext == '.zip':
        tester = try_zip
    elif ext == '.7z':
        tester = try_7z
    else:
        print('UNSUPPORTED')
        return 2

    for pw in read_passwords(pw_file):
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
