#!/usr/bin/env python3
"""repair-broken-zip.py: 扫描损坏中央目录的 polyglot zip(如 MP4+ZIP64+损坏CD),
重建中央目录生成可被 7z 打开的修复副本. 用法:
  python repair-broken-zip.py <input> <output>
返回 0=成功, 1=失败.
"""
import struct, sys, os

CHUNK = 64 * 1024 * 1024

def main():
    if len(sys.argv) != 3:
        print('usage: repair-broken-zip.py <input> <output>')
        return 1
    src, out = sys.argv[1], sys.argv[2]
    size = 0
    with open(src, 'rb') as f:
        size = f.seek(0, 2)

    # scan all local file header offsets
    offsets = []
    with open(src, 'rb') as f:
        pos = 0
        while pos < size:
            f.seek(pos - 4 if pos > 0 else 0)
            buf = f.read(CHUNK + 4)
            if not buf:
                break
            base = pos - 4 if pos > 0 else 0
            i = 0
            while True:
                i = buf.find(b'PK\x03\x04', i)
                if i < 0:
                    break
                offsets.append(base + i)
                i += 4
            pos += CHUNK - 4 if pos > 0 else CHUNK
    offsets = sorted(set(offsets))
    print('candidates: %d' % len(offsets), file=sys.stderr)

    # parse entries, keep only ones with valid names
    entries = []
    with open(src, 'rb') as f:
        for off in offsets:
            f.seek(off)
            b = f.read(30)
            if len(b) < 30:
                continue
            sig = struct.unpack('<I', b[0:4])[0]
            if sig != 0x04034b50:
                continue
            flags = struct.unpack('<H', b[6:8])[0]
            method = struct.unpack('<H', b[8:10])[0]
            crc = struct.unpack('<I', b[14:18])[0]
            csize = struct.unpack('<I', b[18:22])[0]
            usize = struct.unpack('<I', b[22:26])[0]
            nlen = struct.unpack('<H', b[26:28])[0]
            elen = struct.unpack('<H', b[28:30])[0]
            if nlen < 4 or nlen > 512 or elen > 2048:
                continue
            name = f.read(nlen)
            extra = f.read(elen)
            # name sanity: avoid binary garbage (decoy entries)
            try:
                nm = name.decode('utf-8')
            except Exception:
                try:
                    nm = name.decode('gbk')
                except Exception:
                    continue
            if not nm.strip() or '\x00' in nm:
                continue
            printable = sum(1 for c in nm if c.isprintable())
            if printable < max(3, len(nm) // 2):
                continue
            real_us, real_cs = usize, csize
            i = 0
            while i + 4 <= len(extra):
                tag, sz = struct.unpack('<HH', extra[i:i+4])
                data = extra[i+4:i+4+sz]
                if tag == 0x0001:
                    p = 0
                    if usize == 0xFFFFFFFF and len(data) >= p+8:
                        real_us = struct.unpack('<Q', data[p:p+8])[0]; p += 8
                    if csize == 0xFFFFFFFF and len(data) >= p+8:
                        real_cs = struct.unpack('<Q', data[p:p+8])[0]; p += 8
                i += 4 + sz
            entries.append({
                'off': off, 'flags': flags, 'method': method, 'crc': crc,
                'csize': real_cs, 'usize': real_us, 'name': name,
            })

    if not entries:
        print('no valid zip entries found', file=sys.stderr)
        return 1
    print('valid entries: %d' % len(entries), file=sys.stderr)

    # write new zip: entry data (renumbered from 0) + rebuilt CD
    cd = bytearray()
    new_off = 0
    with open(out, 'wb') as o:
        with open(src, 'rb') as f:
            for e in entries:
                # write local header + name (30 bytes fixed)
                need_z = e['csize'] > 0xFFFFFFFF or e['usize'] > 0xFFFFFFFF
                z = b''
                if need_z:
                    if e['usize'] > 0xFFFFFFFF:
                        z += struct.pack('<Q', e['usize'])
                    if e['csize'] > 0xFFFFFFFF:
                        z += struct.pack('<Q', e['csize'])
                extra = struct.pack('<HH', 0x0001, len(z)) + z if z else b''
                cs_f = e['csize'] if not need_z else 0xFFFFFFFF
                us_f = e['usize'] if not need_z else 0xFFFFFFFF
                lh = struct.pack('<IHHHHHIIIHH',
                    0x04034b50, 45, e['flags'] & ~0x08, e['method'],
                    0, 0, e['crc'], cs_f, us_f,
                    len(e['name']), len(extra))
                o.write(lh)
                o.write(e['name'])
                o.write(extra)
                # copy data
                f.seek(e['off'] + 30 + len(e['name']) + len(
                    struct.pack('<HH', 0, 0)  # placeholder, replaced below
                ))
                # real extra length unknown here; recompute: header 30 + nlen + elen
                f.seek(e['off'])
                hb = f.read(30)
                elen0 = struct.unpack('<H', hb[28:30])[0]
                data_off = e['off'] + 30 + len(e['name']) + elen0
                f.seek(data_off)
                remaining = e['csize']
                while remaining > 0:
                    chunk = f.read(min(8 * 1024 * 1024, remaining))
                    if not chunk:
                        break
                    o.write(chunk)
                    remaining -= len(chunk)
                # CD record with new offset
                need_zip64 = need_z or new_off > 0xFFFFFFFF
                z2 = b''
                if e['usize'] > 0xFFFFFFFF:
                    z2 += struct.pack('<Q', e['usize'])
                if e['csize'] > 0xFFFFFFFF:
                    z2 += struct.pack('<Q', e['csize'])
                if new_off > 0xFFFFFFFF:
                    z2 += struct.pack('<Q', new_off)
                extra2 = struct.pack('<HH', 0x0001, len(z2)) + z2 if z2 else b''
                cs2 = e['csize'] if e['csize'] <= 0xFFFFFFFF else 0xFFFFFFFF
                us2 = e['usize'] if e['usize'] <= 0xFFFFFFFF else 0xFFFFFFFF
                lho2 = new_off if new_off <= 0xFFFFFFFF else 0xFFFFFFFF
                rec = struct.pack('<IHHHHHHIIIHHHHHII',
                    0x02014b50, 45, 45, e['flags'] & ~0x08, e['method'],
                    0, 0, e['crc'], cs2, us2,
                    len(e['name']), len(extra2), 0, 0, 0, 0, lho2)
                cd += rec + e['name'] + extra2
                new_off += 30 + len(e['name']) + len(extra) + e['csize']

        # append central directory + EOCD
        cd_off = new_off
        o.write(cd)
        z64 = struct.pack('<IQHHIIQQQQ',
            0x06064b50, 44, 45, 45, 0, 0,
            len(entries), len(entries), len(cd), cd_off)
        loc = struct.pack('<IIQI', 0x07064b50, 0, cd_off + len(cd), 1)
        eocd = struct.pack('<IHHHHIIH',
            0x06054b50, 0, 0, len(entries) & 0xFFFF, len(entries) & 0xFFFF,
            min(len(cd), 0xFFFFFFFF), min(cd_off, 0xFFFFFFFF), 0)
        o.write(z64)
        o.write(loc)
        o.write(eocd)

    print('repaired -> %s (%d bytes, %d entries)' % (out, os.path.getsize(out), len(entries)), file=sys.stderr)
    return 0

if __name__ == '__main__':
    sys.exit(main())
