#!/usr/bin/env python3
"""Golden model of the KI boot ROM's bitstream reader (9FC00D14..9FC00D9C).

The boot ROM gates its permutation-table initialiser on the return value of
this reader:

    9FC00724: jal  9FC00D48      read 32 bits
    9FC00728: or   t2,v0,zero    (delay slot)
    9FC0073C: beq  t2,zero,...   t2 == 0 skips the initialiser

On hardware the initialiser never runs, so the table is never seeded as a
permutation and the scan at 9FC00CD8 never terminates. The reader's input is
boot-ROM data - fully deterministic, and already checksum-verified against
hardware - so the value t2 *should* take can be computed exactly. That is
what this produces, along with every intermediate, so a simulation or
hardware trace can be diffed against it op by op.

Reader state: s0 = 64-bit accumulator, s1 = source pointer, s2 = bit count.
"""
import sys

ROM_PATH = 'sim/media/ki-l15d.u98'
ROM_BASE = 0xBFC00000
STREAM = 0xBFC00FD0          # computed at 9FC006A8..9FC006C4
MASK64 = (1 << 64) - 1


def s64(value):
    value &= MASK64
    return value - (1 << 64) if value & (1 << 63) else value


class BitReader:
    """Mirrors the ROM routine instruction for instruction.

    `fault` injects a single suspected RTL defect so the sweep can ask which
    one, if any, reproduces the hardware's t2 == 0. Guessing which primitive
    is broken has been wrong six times; this asks the data instead.
    """

    def __init__(self, rom, pointer, fault=None):
        self.rom = rom
        self.fault = fault
        self.trace = []
        # 9FC00D14 init: at = unaligned64(a1); pointer saved as a1 + 7
        self.s0 = self.load64(pointer)
        self.s1 = pointer + 7
        self.s2 = -56                       # sb -56, 12(a0); lb sign-extends

        if fault == 'sd_ld_32':             # sd/ld keep only the low word
            self.s0 &= 0xffffffff
        if fault == 'lb_zero_extend':        # lb fails to sign-extend 0xC8
            self.s2 = 0xc8

    def load64(self, address):
        """LDL 7(base) + LDR 0(base): little-endian 64-bit load."""
        offset = address - ROM_BASE
        value = int.from_bytes(self.rom[offset:offset + 8], 'little')
        if self.fault == 'ldl_dead':          # LDL contributes nothing
            value &= 0xff
        return value

    def dsllv(self, value, amount):
        if self.fault == 'shift_amount_5bit':
            amount &= 31                      # SLLV's 5 bits, not DSLLV's 6
        elif self.fault == 'dsllv_32bit':
            return ((value & 0xffffffff) << (amount & 63)) & 0xffffffff
        else:
            amount &= 63
        return (value << amount) & MASK64

    def dsrlv(self, value, amount):
        if self.fault == 'shift_amount_5bit':
            amount &= 31
        elif self.fault == 'dsrlv_32bit':
            return ((value & 0xffffffff) >> (amount & 63)) & 0xffffffff
        else:
            amount &= 63
        return (value >> amount) & MASK64

    def read(self, n):
        before = (self.s0, self.s1, self.s2)
        v1 = self.load64(self.s1)           # ldl v1,7(s1) / ldr v1,0(s1)
        self.s2 = s64(-self.s2)             # sub  s2,zero,s2
        v0 = self.dsllv(v1, self.s2)        # dsllv v0,v1,s2
        self.s0 = (self.s0 | v0) & MASK64   # or   s0,s0,v0
        self.s2 = s64(n - self.s2)          # sub  s2,a0,s2
        mask = (self.dsllv(1, n) - 1) & MASK64  # dsllv v0,v0,a0 / daddi v0,v0,-1
        result = self.s0 & mask             # and  v0,s0,v0  (delay slot)

        if self.s2 > 0:                     # blez s2 not taken
            self.s1 += 7                    # addi s1,s1,7
            self.s0 = self.dsrlv(v1, self.s2)           # dsrlv s0,v1,s2
            self.s2 = s64(self.s2 - 56)     # addi s2,s2,-56
        else:                               # 9FC00D98
            self.s0 = self.dsrlv(self.s0, n)            # dsrlv s0,s0,a0

        self.trace.append((n, result, before, (self.s0, self.s1, self.s2), v1))
        return result


CALL_BITS = [16, 8, 8, 32, 32]

FAULTS = [
    (None, 'no fault (real hardware behaviour)'),
    ('shift_amount_5bit', 'DSLLV/DSRLV use 5 shift bits instead of 6'),
    ('dsllv_32bit', 'DSLLV operates on the low 32 bits only'),
    ('dsrlv_32bit', 'DSRLV operates on the low 32 bits only'),
    ('sd_ld_32', 'SD/LD to RAM keep only the low 32 bits'),
    ('lb_zero_extend', 'LB fails to sign-extend the bit counter'),
    ('ldl_dead', 'LDL contributes nothing (ruled out by tb_ki_ldl_ldr)'),
]


def run(rom, fault):
    """Return (signature, third_read, t2) under an injected fault."""
    reader = BitReader(rom, STREAM, fault)
    values = [reader.read(bits) for bits in CALL_BITS]
    return values[0], values[2], values[4]


def sweep(rom):
    print('Which single defect reproduces the hardware symptom (t2 == 0)?')
    print('The ROM guards its own stream: read(16) must be 0x7262 and the')
    print('third read must be 0, each backed by a syscall. A fault that')
    print('breaks a guard would trap long before the gate, so it cannot be')
    print('what we are seeing.')
    print()
    header = f'{"fault":<20} {"sig":>6} {"guard":>8} {"t2":>10}  verdict'
    print(header)
    print('-' * len(header))
    for fault, description in FAULTS:
        signature, guard, t2 = run(rom, fault)
        if signature != 0x7262 or guard != 0:
            verdict = 'excluded: would syscall'
        elif t2 == 0:
            verdict = '*** MATCHES HARDWARE ***'
        else:
            verdict = 'excluded: initialiser runs'
        print(f'{str(fault):<20} {signature:>06X} {guard:>8X} {t2:>10X}  '
              f'{verdict}')
        print(f'    {description}')


def main():
    rom = open(ROM_PATH, 'rb').read()
    if '--sweep' in sys.argv:
        sweep(rom)
        return
    reader = BitReader(rom, STREAM)

    print(f'stream base   = {STREAM:08X}')
    print(f'initial s0    = {reader.s0:016X}')
    print(f'initial s1    = {reader.s1:08X}')
    print(f'initial s2    = {reader.s2}')
    print()

    # The exact call sequence from 9FC006DC through 9FC00724.
    calls = [
        (16, '9FC006DC  jal 9FC00D50  read(16)  must == 0x7262'),
        (8,  '9FC006F4  jal 9FC00D58  read(8)   -> s5'),
        (8,  '9FC00708  jal 9FC00D58  read(8)   must == 0'),
        (32, '9FC0071C  jal 9FC00D48  read(32)  discarded'),
        (32, '9FC00724  jal 9FC00D48  read(32)  -> t2  GATES INITIALISER'),
    ]

    results = []
    for bits, label in calls:
        value = reader.read(bits)
        results.append(value)
        _, _, _, after, v1 = reader.trace[-1]
        print(f'{label}')
        print(f'    v1={v1:016X}  -> v0={value:08X}')
        print(f'    after: s0={after[0]:016X} s1={after[1]:08X} s2={after[2]}')

    print()
    signature, _, third, _, t2 = results
    ok = True
    if signature != 0x7262:
        print(f'MODEL ERROR: signature {signature:04X} != 7262')
        ok = False
    if third != 0:
        print(f'MODEL ERROR: third read {third:08X} != 0 (ROM would syscall)')
        ok = False
    if ok:
        print('model self-check OK: signature and syscall guards both satisfied')
    print()
    print(f'EXPECTED t2 = {t2:08X}  -> initialiser '
          f'{"RUNS" if t2 else "IS SKIPPED"}')


if __name__ == '__main__':
    main()
