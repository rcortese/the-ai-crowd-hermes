"""Authenticated chunked backup envelope; key lives separately from backups.

AES-256-GCM, random 64-bit nonce prefix, monotonic 32-bit chunk counter,
authenticated header/index, mandatory authenticated empty terminal record.
Not a substitute for off-host backup/key custody.
"""
import argparse
import os
import struct
import sys
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b'MOSS-HONCHO-AESGCM-v1\n'
CHUNK = 1024 * 1024


def exact(stream, count):
    out = bytearray()
    while len(out) < count:
        part = stream.read(count-len(out))
        if not part:
            raise ValueError('Truncated encrypted backup')
        out.extend(part)
    return bytes(out)


def encrypt(src, dst, key):
    aes = AESGCM(key)
    header = MAGIC + os.urandom(8)
    dst.write(header)
    index = 0
    while True:
        chunk = src.read(CHUNK)
        idx = struct.pack('>I', index)
        ciphertext = aes.encrypt(header[-8:]+idx, chunk, header+idx)
        dst.write(struct.pack('>I', len(ciphertext)))
        dst.write(ciphertext)
        if not chunk:
            return
        index += 1


def decrypt(src, dst, key):
    aes = AESGCM(key)
    header = exact(src, len(MAGIC)+8)
    if not header.startswith(MAGIC):
        raise ValueError('Unknown backup envelope')
    index = 0
    while True:
        length = struct.unpack('>I', exact(src,4))[0]
        if not 16 <= length <= CHUNK+16:
            raise ValueError('Invalid ciphertext length')
        idx = struct.pack('>I', index)
        chunk = aes.decrypt(header[-8:]+idx, exact(src,length), header+idx)
        if not chunk:
            if src.read(1):
                raise ValueError('Trailing backup data')
            return
        dst.write(chunk)
        index += 1


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('operation',choices=['encrypt','decrypt'])
    p.add_argument('key',type=Path)
    args = p.parse_args()
    key = args.key.read_bytes()
    if len(key) != 32:
        raise ValueError('Expected 32-byte backup key')
    globals()[args.operation](sys.stdin.buffer,sys.stdout.buffer,key)
