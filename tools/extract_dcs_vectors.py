#!/usr/bin/env python3
"""Turn a MAME DCS register trace into datapath test vectors.

The gameplay crackle is a full-scale wrap that survived every non-arithmetic
explanation, so each unit of the DSP datapath gets checked against the operands
MAME actually computed with - not against synthetic stimulus, and not against
F19, which is the only thing this core had ever been verified on.

Capture a trace first. In a MAME debugger script, or via Lua with
manager.machine.debugger:command():

    trace <file>,:dcs:dcs,noloop,{tracelog "|%04X %04X ...|",<regs>}

Two traps, both of which produce a trace that looks fine and is useless:

  * Set the visible CPU FIRST. `focus :dcs:dcs` in a debugscript works, but
    issuing it through Lua's command() does NOT take - set
    manager.machine.debugger.visible_cpu directly instead. Otherwise the action's
    register symbols resolve against the wrong device and are silently dropped.
  * Register symbols must be UPPERCASE.

MAME logs registers BEFORE each instruction executes. So an instruction's INPUTS
are on its own line and its RESULT is on the NEXT line. Getting that backwards
compares against the wrong values and every vector "passes".

Register order per unit (must match the tracelog):

    --unit mac    MX0,MX1,MY0,MY1,MR0,MR1,MR2,MSTAT
    --unit alu    AR,AX0,AX1,AY0,AY1,MR1,ASTAT,MSTAT
    --unit shift  SI,SE,SR0,SR1,SB,AR,ASTAT,MSTAT
"""

import argparse
import re
import sys
from collections import Counter

LINE = re.compile(
    r'^\|([0-9A-Fa-f]{4}) ([0-9A-Fa-f]{4}) ([0-9A-Fa-f]{4}) ([0-9A-Fa-f]{4}) '
    r'([0-9A-Fa-f]{4}) ([0-9A-Fa-f]{4}) ([0-9A-Fa-f]{4}) ([0-9A-Fa-f]{4})\|'
    r'([0-9A-Fa-f]{4}): (.*)$')

# ---- MAC ------------------------------------------------------------------
# Signedness: 1,2,3,4,8,C = SS | 5,9,D = SU | 6,A,E = US | else UU
# Accumulate: 2,8,9,A,B = MR+XY | 3,C,D,E,F = MR-XY | else XY ; Rounding: 1,2,3
MAC_SUB = {
    ("", "RND"): 0x1, ("+", "RND"): 0x2, ("-", "RND"): 0x3,
    ("", "SS"): 0x4, ("", "SU"): 0x5, ("", "US"): 0x6, ("", "UU"): 0x7,
    ("+", "SS"): 0x8, ("+", "SU"): 0x9, ("+", "US"): 0xA, ("+", "UU"): 0xB,
    ("-", "SS"): 0xC, ("-", "SU"): 0xD, ("-", "US"): 0xE, ("-", "UU"): 0xF,
}
MAC_RE = re.compile(r'^MR\s*=\s*(?:MR\s*([+-])\s*)?M([XY])(\d)\s*\*\s*M([XY])(\d)\s*\(([A-Z]+)\)')

# ---- ALU ------------------------------------------------------------------
# alu_xread: 0=AX0 1=AX1 2=AR 3=MR0 4=MR1 5=MR2 6=SR0 7=SR1
# alu_yread: 0=AY0 1=AY1 2=AF 3=0.  Sub: 3 = X+Y, 7 = X-Y, 9 = Y-X
ALU_X = {"AX0": 1, "AX1": 2, "AR": 0, "MR1": 5}      # index into the traced row
ALU_Y = {"AY0": 3, "AY1": 4}
ALU_RE = re.compile(r'^AR = ([A-Z0-9]+) ([+-]) ([A-Z0-9]+)(?:,|$)')

# ---- shifter --------------------------------------------------------------
SH_XI = {"SI": 0, "AR": 2, "SR0": 6, "SR1": 7}
SH_SRC = {"SI": 0, "AR": 5, "SR0": 2, "SR1": 3}      # index into the traced row
SH_BASE = {("LSHIFT", "HI"): 0x0, ("LSHIFT", "LO"): 0x2,
           ("ASHIFT", "HI"): 0x4, ("ASHIFT", "LO"): 0x6,
           ("NORM", "HI"): 0x8, ("NORM", "LO"): 0xA}
SH_RE = re.compile(r'^SR = (SR OR )?(LSHIFT|ASHIFT|NORM) ([A-Z0-9]+)'
                   r'(?: BY (-?\d+))? \((HI|LO)\)')


def read_rows(path):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE.match(line.rstrip("\n"))
            if m:
                g = m.groups()
                rows.append(tuple(int(x, 16) for x in g[:8]) + (g[9].strip(),))
    return rows


def do_mac(rows):
    out, skipped = [], Counter()
    for i in range(len(rows) - 1):
        r = rows[i]
        m = MAC_RE.match(r[8])
        if not m:
            continue
        sign, xk, xn, yk, yn, mode = m.groups()
        if xk != "X" or yk != "Y" or (sign or "", mode) not in MAC_SUB:
            skipped[r[8].split(",")[0]] += 1
            continue
        nxt = rows[i + 1]
        # row: MX0 MX1 MY0 MY1 MR0 MR1 MR2 MSTAT
        out.append((MAC_SUB[(sign or "", mode)], int(xn), int(yn), r[7],
                    r[0], r[1], r[2], r[3], r[4], r[5], r[6],
                    nxt[4], nxt[5], nxt[6]))
    return out, skipped


def do_alu(rows):
    out, skipped = [], Counter()
    for i in range(len(rows) - 1):
        r = rows[i]
        m = ALU_RE.match(r[8])
        if not m:
            continue
        a, op, b = m.groups()
        if a in ALU_X and b in ALU_Y:
            sub = 0x3 if op == "+" else 0x7
            xv, yv = r[ALU_X[a]], r[ALU_Y[b]]
        elif a in ALU_Y and b in ALU_X:
            sub = 0x9 if op == "-" else 0x3        # Y-X, or commutative add
            xv, yv = r[ALU_X[b]], r[ALU_Y[a]]
        else:
            skipped[r[8].split(",")[0]] += 1
            continue
        nxt = rows[i + 1]
        # row: AR AX0 AX1 AY0 AY1 MR1 ASTAT MSTAT
        out.append((sub, xv, yv, r[6], r[7], nxt[0], nxt[6]))
    return out, skipped


def do_shift(rows):
    out, skipped = [], Counter()
    for i in range(len(rows) - 1):
        r = rows[i]
        m = SH_RE.match(r[8])
        if not m:
            continue
        orv, op, src, byn, hl = m.groups()
        if src not in SH_XI or (op, hl) not in SH_BASE:
            skipped[src if src not in SH_XI else op] += 1
            continue
        mode = SH_BASE[(op, hl)] | (1 if orv else 0)
        # "BY n" carries its own count; otherwise the shift comes from SE.
        sc = (int(byn) if byn is not None else r[1]) & 0xff
        nxt = rows[i + 1]
        # row: SI SE SR0 SR1 SB AR ASTAT MSTAT
        out.append((mode, SH_XI[src], sc, r[0], r[5], r[2], r[3], r[4], r[7],
                    nxt[2], nxt[3]))
    return out, skipped


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace")
    ap.add_argument("--unit", required=True, choices=("mac", "alu", "shift"))
    ap.add_argument("-o", "--out", required=True)
    args = ap.parse_args()

    rows = read_rows(args.trace)
    if not rows:
        sys.exit("no register-bearing lines found - the tracelog action probably "
                 "did not take; see the notes at the top of this file")

    out, skipped = {"mac": do_mac, "alu": do_alu, "shift": do_shift}[args.unit](rows)
    if not out:
        sys.exit("no %s instructions found - check the tracelog register order" % args.unit)

    with open(args.out, "w") as f:
        for v in out:
            f.write(" ".join("%04x" % x for x in v) + "\n")

    print("trace rows : %d" % len(rows))
    print("%-5s vectors: %d" % (args.unit, len(out)))
    print("first field: %s" % " ".join("%X:%d" % kv
                                       for kv in sorted(Counter(v[0] for v in out).items())))
    if skipped:
        print("skipped    : %s" % dict(skipped.most_common(4)))
    print("wrote %s" % args.out)


if __name__ == "__main__":
    main()
