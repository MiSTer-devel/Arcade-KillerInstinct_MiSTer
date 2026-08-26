#!/usr/bin/env python3
"""Minimal little-endian MIPS III disassembler for the KI boot ROM.

The boot ROM is the only thing standing between us and a booting core, and
every question about it so far has been answered by hand-decoding words.
This exists so that stops being hand work.

    python tools/disasm.py 9FC00D48 9FC00D90        # disassemble a range
    python tools/disasm.py --writes s1 9FC00000 9FC01000   # find defs of $s1
"""
import argparse
import sys

ROM_BASE = 0x9FC00000
ROM_PATH = 'sim/media/ki-l15d.u98'

REG = ['zero', 'at', 'v0', 'v1', 'a0', 'a1', 'a2', 'a3',
       't0', 't1', 't2', 't3', 't4', 't5', 't6', 't7',
       's0', 's1', 's2', 's3', 's4', 's5', 's6', 's7',
       't8', 't9', 'k0', 'k1', 'gp', 'sp', 's8', 'ra']

SPECIAL = {
    0x00: 'sll', 0x02: 'srl', 0x03: 'sra', 0x04: 'sllv', 0x06: 'srlv',
    0x07: 'srav', 0x08: 'jr', 0x09: 'jalr', 0x0c: 'syscall', 0x0d: 'break',
    0x0f: 'sync', 0x10: 'mfhi', 0x11: 'mthi', 0x12: 'mflo', 0x13: 'mtlo',
    0x14: 'dsllv', 0x16: 'dsrlv', 0x17: 'dsrav', 0x18: 'mult', 0x19: 'multu',
    0x1a: 'div', 0x1b: 'divu', 0x1c: 'dmult', 0x1d: 'dmultu', 0x1e: 'ddiv',
    0x1f: 'ddivu', 0x20: 'add', 0x21: 'addu', 0x22: 'sub', 0x23: 'subu',
    0x24: 'and', 0x25: 'or', 0x26: 'xor', 0x27: 'nor', 0x2a: 'slt',
    0x2b: 'sltu', 0x2c: 'dadd', 0x2d: 'daddu', 0x2e: 'dsub', 0x2f: 'dsubu',
    0x38: 'dsll', 0x3a: 'dsrl', 0x3b: 'dsra', 0x3c: 'dsll32', 0x3e: 'dsrl32',
    0x3f: 'dsra32',
}

OPCODE = {
    0x02: 'j', 0x03: 'jal', 0x04: 'beq', 0x05: 'bne', 0x06: 'blez',
    0x07: 'bgtz', 0x08: 'addi', 0x09: 'addiu', 0x0a: 'slti', 0x0b: 'sltiu',
    0x0c: 'andi', 0x0d: 'ori', 0x0e: 'xori', 0x0f: 'lui', 0x14: 'beql',
    0x15: 'bnel', 0x16: 'blezl', 0x17: 'bgtzl', 0x18: 'daddi', 0x19: 'daddiu',
    0x1a: 'ldl', 0x1b: 'ldr', 0x20: 'lb', 0x21: 'lh', 0x22: 'lwl',
    0x23: 'lw', 0x24: 'lbu', 0x25: 'lhu', 0x26: 'lwr', 0x27: 'lwu',
    0x28: 'sb', 0x29: 'sh', 0x2a: 'swl', 0x2b: 'sw', 0x2c: 'sdl',
    0x2d: 'sdr', 0x2e: 'swr', 0x2f: 'cache', 0x37: 'ld', 0x3f: 'sd',
}

REGIMM = {0x00: 'bltz', 0x01: 'bgez', 0x10: 'bltzal', 0x11: 'bgezal',
          0x02: 'bltzl', 0x03: 'bgezl'}

# Instruction classes by which register they write, so --writes can work
# without a full dataflow model.
LOADS = {'lb', 'lh', 'lwl', 'lw', 'lbu', 'lhu', 'lwr', 'lwu', 'ld',
         'ldl', 'ldr'}
STORES = {'sb', 'sh', 'swl', 'sw', 'sdl', 'sdr', 'swr', 'sd', 'cache'}


def s16(value):
    return value - 0x10000 if value & 0x8000 else value


def decode(pc, word):
    """Return (text, dest_register_or_None)."""
    op = word >> 26
    rs, rt = (word >> 21) & 31, (word >> 16) & 31
    rd, sa = (word >> 11) & 31, (word >> 6) & 31
    funct = word & 63
    imm = word & 0xffff
    target = (pc + 4 & 0xf0000000) | ((word & 0x03ffffff) << 2)
    branch = pc + 4 + (s16(imm) << 2)

    if word == 0:
        return 'nop', None

    if op == 0:
        name = SPECIAL.get(funct)
        if name is None:
            return f'.word 0x{word:08x}', None
        if name in ('sll', 'srl', 'sra', 'dsll', 'dsrl', 'dsra',
                    'dsll32', 'dsrl32', 'dsra32'):
            return f'{name:<8}{REG[rd]},{REG[rt]},{sa}', rd
        if name in ('sllv', 'srlv', 'srav', 'dsllv', 'dsrlv', 'dsrav'):
            return f'{name:<8}{REG[rd]},{REG[rt]},{REG[rs]}', rd
        if name == 'jr':
            return f'{name:<8}{REG[rs]}', None
        if name == 'jalr':
            return f'{name:<8}{REG[rd]},{REG[rs]}', rd
        if name in ('mfhi', 'mflo'):
            return f'{name:<8}{REG[rd]}', rd
        if name in ('mthi', 'mtlo'):
            return f'{name:<8}{REG[rs]}', None
        if name in ('mult', 'multu', 'div', 'divu', 'dmult', 'dmultu',
                    'ddiv', 'ddivu'):
            return f'{name:<8}{REG[rs]},{REG[rt]}', None
        if name in ('syscall', 'break', 'sync'):
            return name, None
        return f'{name:<8}{REG[rd]},{REG[rs]},{REG[rt]}', rd

    if op == 1:
        name = REGIMM.get(rt, f'regimm{rt:02x}')
        return f'{name:<8}{REG[rs]},0x{branch:08x}', (31 if 'al' in name
                                                      else None)

    if op == 0x10:
        if rs == 0:
            return f'{"mfc0":<8}{REG[rt]},${rd}', rt
        if rs == 4:
            return f'{"mtc0":<8}{REG[rt]},${rd}', None
        return f'cop0    0x{word:08x}', None

    name = OPCODE.get(op)
    if name is None:
        return f'.word 0x{word:08x}', None

    if name in ('j', 'jal'):
        return f'{name:<8}0x{target:08x}', (31 if name == 'jal' else None)
    if name in ('beq', 'bne', 'beql', 'bnel'):
        return f'{name:<8}{REG[rs]},{REG[rt]},0x{branch:08x}', None
    if name in ('blez', 'bgtz', 'blezl', 'bgtzl'):
        return f'{name:<8}{REG[rs]},0x{branch:08x}', None
    if name == 'lui':
        return f'{name:<8}{REG[rt]},0x{imm:04x}', rt
    if name in LOADS or name in STORES:
        text = f'{name:<8}{REG[rt]},{s16(imm)}({REG[rs]})'
        return text, (rt if name in LOADS else None)
    return f'{name:<8}{REG[rt]},{REG[rs]},{s16(imm)}', rt


def load_rom(path):
    with open(path, 'rb') as handle:
        return handle.read()


def word_at(rom, address):
    offset = address - ROM_BASE
    if offset < 0 or offset + 4 > len(rom):
        return None
    return int.from_bytes(rom[offset:offset + 4], 'little')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('start')
    parser.add_argument('end')
    parser.add_argument('--rom', default=ROM_PATH)
    parser.add_argument('--writes', help='only show defs of this register')
    args = parser.parse_args()

    rom = load_rom(args.rom)
    start = int(args.start, 16) & ~3
    end = int(args.end, 16)
    want = REG.index(args.writes) if args.writes else None

    for pc in range(start, end, 4):
        word = word_at(rom, pc)
        if word is None:
            break
        text, dest = decode(pc, word)
        if want is not None and dest != want:
            continue
        print(f'{pc:08X}: {word:08x}  {text}')


if __name__ == '__main__':
    main()
