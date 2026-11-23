# -*- coding: utf-8 -*-
"""arc7z.py - in-process password probing through 7z.dll (x64).

Why this exists
---------------
The worker's password loop used to spawn 7z.exe once per candidate. Bare
spawn measured 37 ms on this machine, so a 250-entry list burned ~9 s of
pure process creation before the archive was even touched. 7z.dll exposes
IInArchive: open the archive once, then hand the handler a different
password and let its AES verifier reject wrong ones before any data is
decompressed. Wrong candidates cost microseconds instead of 37 ms.

It also covers what pwtest.py's pure-python path cannot:
  * zip with WinZip AES (compress_type 99) - zipfile refuses those
  * rar / rar5 - no usable python library is bundled

Safety
------
Everything below is hand-built ctypes COM. A malformed vtable kills the
process with an access violation, so this module is only ever imported by
the pwtest.py *helper subprocess*: a crash costs one fallback to the old
7z.exe loop, never the GUI or a running batch.

CLI (used for testing):
    python arc7z.py <archive> <password_file>
    -> "FOUND <base64-pw>" / "NOTFOUND" / "UNSUPPORTED"
"""

import ctypes
import os
import sys
from ctypes import (POINTER, addressof, byref, c_int32, c_int64, c_uint32,
                    c_uint64, c_void_p, cast, memmove, string_at)

HRESULT = c_int32
ULONG = c_uint32
UInt32 = c_uint32
UInt64 = c_uint64
Int32 = c_int32
Int64 = c_int64

S_OK = 0
S_FALSE = 1
E_NOINTERFACE = -2147467262
E_FAIL = -2147467259
E_ABORT = -2147467260

FUNC = ctypes.WINFUNCTYPE


# --------------------------------------------------------------------------
# GUID / PROPVARIANT
# --------------------------------------------------------------------------
class GUID(ctypes.Structure):
    _fields_ = [('Data1', c_uint32),
                ('Data2', ctypes.c_uint16),
                ('Data3', ctypes.c_uint16),
                ('Data4', ctypes.c_ubyte * 8)]


def _guid(text):
    body = text.strip('{}').replace('-', '')
    g = GUID()
    g.Data1 = int(body[0:8], 16)
    g.Data2 = int(body[8:12], 16)
    g.Data3 = int(body[12:16], 16)
    tail = bytes.fromhex(body[16:32])
    for i in range(8):
        g.Data4[i] = tail[i]
    return g


IID_IInArchive = _guid('{23170F69-40C1-278A-0000-000600600000}')
IID_IArchiveOpenCallback = _guid('{23170F69-40C1-278A-0000-000600100000}')
IID_IArchiveExtractCallback = _guid('{23170F69-40C1-278A-0000-000600200000}')
IID_IInStream = _guid('{23170F69-40C1-278A-0000-000300030000}')
IID_ISequentialInStream = _guid('{23170F69-40C1-278A-0000-000300010000}')
IID_IOutStream = _guid('{23170F69-40C1-278A-0000-000400030000}')
IID_ICryptoGetTextPassword = _guid('{23170F69-40C1-278A-0000-000500100000}')
IID_ICryptoGetTextPassword2 = _guid('{23170F69-40C1-278A-0000-000500110000}')

_BYTES_IINARCHIVE = bytes(IID_IInArchive)
_BYTES_IINSTREAM = bytes(IID_IInStream)
_BYTES_ISEQ_IN = bytes(IID_ISequentialInStream)
_BYTES_IOUTSTREAM = bytes(IID_IOutStream)
_BYTES_EXTRACT_CB = bytes(IID_IArchiveExtractCallback)
_BYTES_CRYPTO = bytes(IID_ICryptoGetTextPassword)
_BYTES_CRYPTO2 = bytes(IID_ICryptoGetTextPassword2)


class PROPVARIANT(ctypes.Structure):
    # x64: 8-byte header (vt + 3 reserved WORDs) then a 16-byte union.
    _fields_ = [('vt', ctypes.c_uint16),
                ('r1', ctypes.c_uint16),
                ('r2', ctypes.c_uint16),
                ('r3', ctypes.c_uint16),
                ('u_lo', c_uint64),
                ('u_hi', c_uint64)]


VT_EMPTY = 0
VT_BSTR = 8
VT_BOOL = 11
VT_UI4 = 19
VT_UI8 = 21

# NArchive::NItemProp
KPID_PATH = 3
KPID_ISDIR = 6
KPID_SIZE = 7
KPID_ENCRYPTED = 15

# NArchive::NExtract::NOperationResult
OP_OK = 0
OP_WRONG_PASSWORD = 9

_oleaut32 = ctypes.WinDLL('oleaut32')
_oleaut32.SysFreeString.argtypes = [c_void_p]
_oleaut32.SysFreeString.restype = None
_oleaut32.SysAllocString.argtypes = [ctypes.c_wchar_p]
_oleaut32.SysAllocString.restype = c_void_p


def _alloc_bstr(text):
    """SysAllocString copy: the caller owns it and frees it with SysFreeString,
    which matches what 7-Zip handlers expect from CryptoGetTextPassword."""
    return _oleaut32.SysAllocString(text)


def _pv_clear(pv):
    if pv.vt == VT_BSTR and pv.u_lo:
        _oleaut32.SysFreeString(c_void_p(pv.u_lo))
    pv.vt = VT_EMPTY
    pv.u_lo = 0


def _pv_int(pv):
    if pv.vt == VT_UI8:
        return int(pv.u_lo)
    if pv.vt == VT_UI4:
        return int(pv.u_lo & 0xFFFFFFFF)
    if pv.vt == VT_BOOL:
        return 1 if (pv.u_lo & 0xFFFF) else 0
    return 0


def _pv_str(pv):
    if pv.vt == VT_BSTR and pv.u_lo:
        return ctypes.wstring_at(c_void_p(pv.u_lo))
    return ''


# --------------------------------------------------------------------------
# hand-built COM objects
# --------------------------------------------------------------------------
def _put(vtbl, idx, restype, argtypes, fn, keep):
    thunk = FUNC(restype, c_void_p, *argtypes)(fn)
    keep.append(thunk)
    vtbl[idx] = cast(thunk, c_void_p)


class _ComBase(object):
    """One COM object = a 1-slot {lpVtbl} struct plus its vtable."""

    SLOTS = 0

    def __init__(self):
        self._keep = []

    def _alloc(self):
        self.vtbl = (c_void_p * self.SLOTS)()
        self.obj = (c_void_p * 1)()
        self.obj[0] = cast(self.vtbl, c_void_p)
        self.addr = addressof(self.obj)

    def ptr(self):
        return cast(self.obj, c_void_p)

    # default refcounting: never free, we own the object from python
    def _addref(self, this):
        return 1

    def _release(self, this):
        return 1


class FileInStream(_ComBase):
    """ISequentialInStream + IInStream over a regular file."""
    SLOTS = 5

    def __init__(self, path):
        _ComBase.__init__(self)
        self._alloc()
        self.f = open(path, 'rb', buffering=0)
        self._put_defaults()

    def _put_defaults(self):
        _put(self.vtbl, 0, HRESULT, [c_void_p, POINTER(c_void_p)], self._qi, self._keep)
        _put(self.vtbl, 1, ULONG, [], self._addref, self._keep)
        _put(self.vtbl, 2, ULONG, [], self._release, self._keep)
        _put(self.vtbl, 3, HRESULT, [c_void_p, UInt32, POINTER(UInt32)], self._read, self._keep)
        _put(self.vtbl, 4, HRESULT, [Int64, UInt32, POINTER(UInt64)], self._seek, self._keep)

    def _qi(self, this, iid, out):
        if not iid or not out:
            return E_NOINTERFACE
        if string_at(iid, 16) in (_BYTES_IINSTREAM, _BYTES_ISEQ_IN):
            out[0] = c_void_p(self.addr)
            return S_OK
        out[0] = None
        return E_NOINTERFACE

    def _read(self, this, data, size, processed):
        try:
            chunk = self.f.read(size)
        except OSError:
            return E_FAIL
        n = len(chunk)
        if n:
            memmove(data, chunk, n)
        if processed:
            processed[0] = n
        return S_OK

    def _seek(self, this, offset, origin, newpos):
        try:
            self.f.seek(int(offset), int(origin))
            pos = self.f.tell()
        except OSError:
            return E_FAIL
        if newpos:
            newpos[0] = pos
        return S_OK

    def close(self):
        try:
            self.f.close()
        except OSError:
            pass


class DiscardOutStream(_ComBase):
    """IOutStream that throws decompressed bytes away but counts them.

    A correct password is the only one that ever reaches Write(); wrong ones
    are rejected by the AES verifier first. So the 'cost' of verification is
    one extraction of the smallest entry, not one per candidate.
    """
    SLOTS = 6

    def __init__(self):
        _ComBase.__init__(self)
        self._alloc()
        self.bytes = 0
        self.pos = 0
        _put(self.vtbl, 0, HRESULT, [c_void_p, POINTER(c_void_p)], self._qi, self._keep)
        _put(self.vtbl, 1, ULONG, [], self._addref, self._keep)
        _put(self.vtbl, 2, ULONG, [], self._release, self._keep)
        _put(self.vtbl, 3, HRESULT, [c_void_p, UInt32, POINTER(UInt32)], self._write, self._keep)
        _put(self.vtbl, 4, HRESULT, [Int64, UInt32, POINTER(UInt64)], self._seek, self._keep)
        _put(self.vtbl, 5, HRESULT, [UInt64], self._setsize, self._keep)

    def _qi(self, this, iid, out):
        if iid and out and string_at(iid, 16) == _BYTES_IOUTSTREAM:
            out[0] = c_void_p(self.addr)
            return S_OK
        if out:
            out[0] = None
        return E_NOINTERFACE

    def _write(self, this, data, size, processed):
        self.bytes += int(size)
        self.pos += int(size)
        if processed:
            processed[0] = size
        return S_OK

    def _seek(self, this, offset, origin, newpos):
        if newpos:
            newpos[0] = self.pos
        return S_OK

    def _setsize(self, this, size):
        return S_OK


class _CryptoView(_ComBase):
    """ICryptoGetTextPassword (1 method) — a separate object, because the
    vtable slot that answers it differs from the parent's signature."""

    SLOTS = 4

    def __init__(self, owner):
        _ComBase.__init__(self)
        self._alloc()
        self.owner = owner
        _put(self.vtbl, 0, HRESULT, [c_void_p, POINTER(c_void_p)], self._qi, self._keep)
        _put(self.vtbl, 1, ULONG, [], self._addref, self._keep)
        _put(self.vtbl, 2, ULONG, [], self._release, self._keep)
        _put(self.vtbl, 3, HRESULT, [POINTER(c_void_p)], self._get, self._keep)

    def _qi(self, this, iid, out):
        if iid and out and string_at(iid, 16) == _BYTES_CRYPTO:
            out[0] = c_void_p(self.addr)
            return S_OK
        if out:
            out[0] = None
        return E_NOINTERFACE

    def _get(self, this, out_bstr):
        pw = self.owner.password
        if not pw:
            return S_FALSE
        if out_bstr:
            out_bstr[0] = _alloc_bstr(pw)
        return S_OK


class _Crypto2View(_ComBase):
    """ICryptoGetTextPassword2: (Int32* isDefined, BSTR* password)."""

    SLOTS = 4

    def __init__(self, owner):
        _ComBase.__init__(self)
        self._alloc()
        self.owner = owner
        _put(self.vtbl, 0, HRESULT, [c_void_p, POINTER(c_void_p)], self._qi, self._keep)
        _put(self.vtbl, 1, ULONG, [], self._addref, self._keep)
        _put(self.vtbl, 2, ULONG, [], self._release, self._keep)
        _put(self.vtbl, 3, HRESULT, [POINTER(Int32), POINTER(c_void_p)], self._get2, self._keep)

    def _qi(self, this, iid, out):
        if iid and out and string_at(iid, 16) == _BYTES_CRYPTO2:
            out[0] = c_void_p(self.addr)
            return S_OK
        if out:
            out[0] = None
        return E_NOINTERFACE

    def _get2(self, this, defined, out_bstr):
        pw = self.owner.password
        if defined:
            defined[0] = 1 if pw else 0
        if not pw:
            if out_bstr:
                out_bstr[0] = None
            return S_OK
        if out_bstr:
            out_bstr[0] = _alloc_bstr(pw)
        return S_OK


class OpenCallback(_ComBase):
    SLOTS = 5

    def __init__(self, password=''):
        _ComBase.__init__(self)
        self._alloc()
        self.password = password
        self.crypto = _CryptoView(self)
        self.crypto2 = _Crypto2View(self)
        _put(self.vtbl, 0, HRESULT, [c_void_p, POINTER(c_void_p)], self._qi, self._keep)
        _put(self.vtbl, 1, ULONG, [], self._addref, self._keep)
        _put(self.vtbl, 2, ULONG, [], self._release, self._keep)
        _put(self.vtbl, 3, HRESULT, [POINTER(UInt64), POINTER(UInt64)], self._settotal, self._keep)
        _put(self.vtbl, 4, HRESULT, [POINTER(UInt64), POINTER(UInt64)], self._settotal, self._keep)

    def _qi(self, this, iid, out):
        if not (iid and out):
            return E_NOINTERFACE
        raw = string_at(iid, 16)
        if raw == _BYTES_CRYPTO:
            out[0] = c_void_p(self.crypto.addr)
            return S_OK
        if raw == _BYTES_CRYPTO2:
            out[0] = c_void_p(self.crypto2.addr)
            return S_OK
        out[0] = None
        return E_NOINTERFACE

    def _settotal(self, this, a, b):
        return S_OK


class ExtractCallback(_ComBase):
    SLOTS = 8

    def __init__(self, password=''):
        _ComBase.__init__(self)
        self._alloc()
        self.password = password
        self.op_result = -1
        self.out = DiscardOutStream()
        self.crypto = _CryptoView(self)
        self.crypto2 = _Crypto2View(self)
        _put(self.vtbl, 0, HRESULT, [c_void_p, POINTER(c_void_p)], self._qi, self._keep)
        _put(self.vtbl, 1, ULONG, [], self._addref, self._keep)
        _put(self.vtbl, 2, ULONG, [], self._release, self._keep)
        _put(self.vtbl, 3, HRESULT, [UInt64], self._ok1, self._keep)
        _put(self.vtbl, 4, HRESULT, [POINTER(UInt64)], self._ok2, self._keep)
        _put(self.vtbl, 5, HRESULT, [UInt32, POINTER(c_void_p), Int32], self._getstream, self._keep)
        _put(self.vtbl, 6, HRESULT, [Int32], self._prepare, self._keep)
        _put(self.vtbl, 7, HRESULT, [Int32], self._result, self._keep)

    def _qi(self, this, iid, out):
        if not (iid and out):
            return E_NOINTERFACE
        raw = string_at(iid, 16)
        if raw == _BYTES_EXTRACT_CB:
            out[0] = c_void_p(self.addr)
            return S_OK
        if raw == _BYTES_CRYPTO:
            out[0] = c_void_p(self.crypto.addr)
            return S_OK
        if raw == _BYTES_CRYPTO2:
            out[0] = c_void_p(self.crypto2.addr)
            return S_OK
        out[0] = None
        return E_NOINTERFACE

    def _ok1(self, this, total):
        return S_OK

    def _ok2(self, this, completed):
        return S_OK

    def _getstream(self, this, index, out_stream, ask_mode):
        if out_stream:
            out_stream[0] = self.out.ptr()
        return S_OK

    def _prepare(self, this, ask_mode):
        return S_OK

    def _result(self, this, op_res):
        self.op_result = int(op_res)
        return S_OK


# --------------------------------------------------------------------------
# format table (class IDs enumerated from GetHandlerProperty2 on this DLL)
# --------------------------------------------------------------------------
_FMT = {
    '7z': ['{23170F69-40C1-278A-1000-000110070000}'],
    'zip': ['{23170F69-40C1-278A-1000-000110010000}'],
    'rar': ['{23170F69-40C1-278A-1000-000110030000}',
            '{23170F69-40C1-278A-1000-000110CC0000}'],
    'gz': ['{23170F69-40C1-278A-1000-000110EF0000}'],
    'tgz': ['{23170F69-40C1-278A-1000-000110EF0000}'],
    'bz2': ['{23170F69-40C1-278A-1000-000110020000}'],
    'xz': ['{23170F69-40C1-278A-1000-0001100C0000}'],
    'zst': ['{23170F69-40C1-278A-1000-0001100E0000}'],
    'tar': ['{23170F69-40C1-278A-1000-000110EE0000}'],
    'cab': ['{23170F69-40C1-278A-1000-000110080000}'],
    'iso': ['{23170F69-40C1-278A-1000-000110E70000}'],
    'lzh': ['{23170F69-40C1-278A-1000-000110060000}'],
    'z': ['{23170F69-40C1-278A-1000-000110050000}'],
    'wim': ['{23170F69-40C1-278A-1000-000110E60000}'],
    'apk': ['{23170F69-40C1-278A-1000-000110010000}'],
    'jar': ['{23170F69-40C1-278A-1000-000110010000}'],
    'cbz': ['{23170F69-40C1-278A-1000-000110010000}'],
    'epub': ['{23170F69-40C1-278A-1000-000110010000}'],
}

_GENERIC_ORDER = ['7z', 'zip', 'rar']


def _is_x64_dll(path):
    """64-bit python cannot load a 32-bit DLL: LoadLibrary fails with
    WinError 193 ('not a valid Win32 application'). Checking the PE header
    first keeps that noise out of the worker log and skips the x86 copy."""
    try:
        with open(path, 'rb') as f:
            head = f.read(0x400)
        if len(head) < 0x40 or head[:2] != b'MZ':
            return False
        off = int.from_bytes(head[0x3C:0x40], 'little')
        if off + 6 > len(head):
            with open(path, 'rb') as f:
                f.seek(off)
                sig = f.read(6)
            machine = int.from_bytes(sig[4:6], 'little') if len(sig) >= 6 else 0
        else:
            machine = int.from_bytes(head[off + 4:off + 6], 'little')
        return machine == 0x8664
    except OSError:
        return False


def resolve_dll():
    """x64 7z.dll. The bin\\extractors\\7z\\ one ships 32-bit and cannot be
    loaded into 64-bit python at all, so it is only used when it really is x64."""
    here = os.path.dirname(os.path.abspath(__file__))
    for rel in (os.path.join('bin', 'extractors', '7z-x64', '7z.dll'),
                os.path.join('bin', 'extractors', '7z', '7z.dll')):
        p = os.path.join(here, rel)
        if os.path.isfile(p) and _is_x64_dll(p):
            return p
    return None


_dll_cache = {}


def load_dll(path=None):
    path = path or resolve_dll()
    if not path or not os.path.isfile(path):
        raise OSError('7z.dll not found')
    if path in _dll_cache:
        return _dll_cache[path]
    lib = ctypes.WinDLL(path)
    lib.CreateObject.restype = HRESULT
    lib.CreateObject.argtypes = [c_void_p, c_void_p, POINTER(c_void_p)]
    _dll_cache[path] = lib
    return lib


class NotAnArchive(Exception):
    pass


class PasswordNeeded(Exception):
    """Header itself is encrypted; Open only succeeds with the right pw."""


class Archive(object):
    """One opened IInArchive plus its input stream."""

    def __init__(self, path, clsid, dll=None):
        self.dll = dll or load_dll()
        self.path = path
        self.arc = c_void_p()
        hr = self.dll.CreateObject(cast(byref(clsid), c_void_p),
                                   cast(byref(IID_IInArchive), c_void_p),
                                   byref(self.arc))
        if hr != 0 or not self.arc:
            raise NotAnArchive('CreateObject failed hr=%#x' % (hr & 0xFFFFFFFF))
        self.stream = FileInStream(path)
        self.open_cb = None
        self.closed = False

    # ---- low level ----
    def _fn(self, slot, restype, argtypes):
        vtbl = cast(self.arc, POINTER(POINTER(c_void_p)))[0]
        proto = FUNC(restype, c_void_p, *argtypes)
        return proto(vtbl[slot])

    def open(self, password=None):
        """password=None -> plain open (no crypto callback)."""
        if password is None:
            cb_ptr = c_void_p()
            self.open_cb = None
        else:
            self.open_cb = OpenCallback(password)
            cb_ptr = self.open_cb.ptr()
        hr = self._fn(3, HRESULT, [c_void_p, POINTER(UInt64), c_void_p])(
            self.arc, self.stream.ptr(), None, cb_ptr)
        return hr

    def count(self):
        # 7-Zip >= 23 builds its interfaces in strict COM style: an HRESULT
        # return plus an out parameter. (Older 7z.dll returned the value
        # directly, which is why every sample on the net calls it with no
        # arguments - doing that here jumps into the wrong function and
        # faults on a null write.)
        n = UInt32(0)
        hr = self._fn(5, HRESULT, [POINTER(UInt32)])(self.arc, byref(n))
        return int(n.value) if hr == S_OK else 0

    def prop(self, index, prop_id):
        pv = PROPVARIANT()
        hr = self._fn(6, HRESULT, [UInt32, UInt32, POINTER(PROPVARIANT)])(
            self.arc, index, prop_id, byref(pv))
        return hr, pv

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            self._fn(4, HRESULT, [])(self.arc)
        except Exception:
            pass
        self.stream.close()

    # ---- high level ----
    def entries(self, with_names=False):
        out = []
        n = self.count()
        for i in range(n):
            hr_dir, pv_dir = self.prop(i, KPID_ISDIR)
            is_dir = bool(_pv_int(pv_dir)) if hr_dir == S_OK else False
            _pv_clear(pv_dir)
            hr_size, pv_size = self.prop(i, KPID_SIZE)
            size = _pv_int(pv_size) if hr_size == S_OK else 0
            _pv_clear(pv_size)
            hr_enc, pv_enc = self.prop(i, KPID_ENCRYPTED)
            enc = bool(_pv_int(pv_enc)) if hr_enc == S_OK else False
            _pv_clear(pv_enc)
            name = ''
            if with_names:
                hr_n, pv_n = self.prop(i, KPID_PATH)
                name = _pv_str(pv_n)
                _pv_clear(pv_n)
            if is_dir:
                continue
            out.append({'index': i, 'size': size, 'encrypted': enc, 'name': name})
        return out

    def verify(self, index, password):
        """Extract one item into the discard stream. True == password right."""
        cb = ExtractCallback(password)
        idx = (UInt32 * 1)(index)
        hr = self._fn(7, HRESULT, [POINTER(UInt32), UInt32, Int32, c_void_p])(
            self.arc, cast(idx, POINTER(UInt32)), 1, 0, cb.ptr())
        if hr != S_OK:
            return False
        if cb.op_result not in (OP_OK, -1):
            return False
        return cb.out.bytes > 0

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass


def _clsids_for(path):
    ext = os.path.splitext(path)[1].lower().lstrip('.')
    if ext in _FMT:
        return [ _guid(c) for c in _FMT[ext] ]
    if ext.isdigit():
        return []                     # .001/.002 split volumes: not supported here
    order = []
    for name in _GENERIC_ORDER:
        order.extend(_FMT[name])
    return [_guid(c) for c in order]


def open_archive(path, password=None, dll=None):
    """Open path trying every plausible handler. Raises NotAnArchive."""
    lib = dll or load_dll()
    last = None
    for clsid in _clsids_for(path):
        arc = None
        try:
            arc = Archive(path, clsid, lib)
            hr = arc.open(password)
            if hr == S_OK:
                return arc
            last = hr
            arc.close()
        except NotAnArchive as exc:
            last = exc
            if arc is not None:
                try:
                    arc.close()
                except Exception:
                    pass
    raise NotAnArchive('no handler accepted %s (last=%s)' % (os.path.basename(path), last))


# Largest entry we are willing to fully decompress just to confirm a password.
# On a pack whose every file is multiple GB the verification itself becomes
# the bottleneck, and the 7z.exe loop (wrong pw rejected by the AES verifier)
# is cheaper. Same guard pwtest.py uses.
VERIFY_SIZE_LIMIT = 64 * 1024 * 1024


def find_password(path, candidates, dll=None):
    """Return (password, stats) or (None, stats).

    stats: {'mode': 'plain'|'header', 'tried': n, 'entries': ..., 'reason': ...}

    Raises NotAnArchive / OSError when the DLL path cannot handle the file.
    """
    stats = {'mode': '', 'tried': 0, 'entries': 0}
    lib = dll or load_dll()

    # First probe: no password at all. Succeeds on archives with a plaintext
    # header (the overwhelming majority: '-p' encrypts data only).
    probe = open_archive(path, password=None, dll=lib)
    try:
        items = probe.entries()
        stats['entries'] = len(items)
        enc = [e for e in items if e['encrypted'] and e['size'] > 0]
        pool = enc or [e for e in items if e['size'] > 0]
        if not pool:
            stats['reason'] = 'no file entry to verify against'
            stats['unsupported'] = True
            return None, stats
        target = min(pool, key=lambda e: e['size'])
        if target['size'] > VERIFY_SIZE_LIMIT:
            stats['reason'] = 'smallest entry is %d MB, too big to verify in-process' % (
                target['size'] // (1024 * 1024))
            stats['unsupported'] = True
            return None, stats

        # An archive with no encrypted entry at all accepts any password, so
        # only the empty candidate means anything.
        if not enc:
            stats['mode'] = 'plain-nocrypt'
            stats['tried'] = 1 if candidates and candidates[0] == '' else 0
            return ('', stats) if (candidates and candidates[0] == '') else (None, stats)

        stats['mode'] = 'reuse'
        for pw in candidates:
            stats['tried'] += 1
            if probe.verify(target['index'], pw):
                return pw, stats
        return None, stats
    finally:
        probe.close()


def find_password_header_encrypted(path, candidates, dll=None):
    """For -hp rar / -mhe 7z: Open itself validates the password."""
    stats = {'mode': 'header', 'tried': 0, 'entries': 0}
    for pw in candidates:
        stats['tried'] += 1
        try:
            arc = open_archive(path, password=pw, dll=dll)
        except NotAnArchive:
            continue
        try:
            items = arc.entries()
            stats['entries'] = len(items)
            pool = [e for e in items if e['size'] > 0]
            if not pool:
                return pw, stats
            target = min(pool, key=lambda e: e['size'])
            if target['size'] > VERIFY_SIZE_LIMIT:
                # header decrypted -> password already proven
                return pw, stats
            if arc.verify(target['index'], pw):
                return pw, stats
        finally:
            arc.close()
    return None, stats


def find(path, candidates, dll=None):
    """Full strategy: plaintext header first, header-encrypted as fallback.

    Returns (password_or_None, stats). stats['unsupported'] True means "this
    module could not decide" and the caller must fall back to the 7z.exe loop.
    """
    lib = dll or load_dll()
    if not _clsids_for(path):
        # .001/.002 volume sets need IArchiveOpenVolumeCallback, which is not
        # implemented here; hand them to the worker's 7z.exe loop instead of
        # burning the candidate list against a handler that cannot exist.
        return None, {'mode': 'no-handler', 'tried': 0, 'entries': 0,
                      'reason': 'volume set / unknown extension', 'unsupported': True}
    header_mode = False
    try:
        pw, stats = find_password(path, candidates, dll=lib)
    except NotAnArchive:
        header_mode = True
        stats = {'mode': 'header?', 'tried': 0, 'entries': 0}

    if not header_mode:
        return pw, stats

    # Open refused every handler without a password: either the header itself
    # is encrypted (-hp rar / -mhe 7z), or this is a volume set / format the
    # DLL cannot read. Only Open can tell, and it needs the password first.
    pw, stats2 = find_password_header_encrypted(path, candidates, dll=lib)
    if pw is not None:
        return pw, stats2
    stats2['unsupported'] = True
    return None, stats2


def main(argv):
    import base64
    if len(argv) < 3:
        print('UNSUPPORTED')
        return 2
    path = argv[1]
    pw_file = argv[2]
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import pwtest
    cands = pwtest.read_passwords(pw_file)
    try:
        pw, stats = find(path, cands)
    except Exception as exc:
        sys.stderr.write('arc7z: %s\n' % exc)
        print('UNSUPPORTED')
        return 2
    sys.stderr.write('arc7z stats: %r\n' % (stats,))
    if pw is None:
        if stats.get('reason') and not stats.get('tried'):
            print('UNSUPPORTED')
            return 2
        print('NOTFOUND')
        return 1
    sys.stdout.write('FOUND ' + base64.b64encode(pw.encode('utf-8')).decode('ascii') + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
