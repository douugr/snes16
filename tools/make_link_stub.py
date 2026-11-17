#!/usr/bin/env python3
"""Gera uma cópia da libBTstack.dylib só para LINKAR em armv7.

A dylib do pacote Cydia tem fatias armv6 e arm64 (sem armv7). O iPad (armv7)
executa a fatia armv6 normalmente, mas o ld recusa linkar armv7 contra armv6.
Aqui a fatia armv6 é marcada como armv7 (só o cabeçalho muda). Em tempo de
execução o app carrega a /usr/lib/libBTstack.dylib original do iPad.
"""
import struct, sys

CPU_ARM, SUB_V6, SUB_V7 = 12, 6, 9
src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, 'rb').read())
if struct.unpack('>I', data[:4])[0] != 0xCAFEBABE:
    sys.exit('esperava um binário universal (fat)')
n = struct.unpack('>I', data[4:8])[0]
done = False
for i in range(n):
    o = 8 + i * 20
    cpu, sub, off, size, align = struct.unpack('>5I', data[o:o + 20])
    if cpu == CPU_ARM and sub == SUB_V6:
        struct.pack_into('>I', data, o + 4, SUB_V7)          # entrada do fat header
        magic = struct.unpack('<I', data[off:off + 4])[0]
        if magic != 0xFEEDFACE:
            sys.exit('fatia armv6 inesperada')
        struct.pack_into('<I', data, off + 8, SUB_V7)        # mach_header.cpusubtype
        done = True
if not done:
    sys.exit('fatia armv6 não encontrada')
open(dst, 'wb').write(data)
print('stub de link gerado:', dst)
