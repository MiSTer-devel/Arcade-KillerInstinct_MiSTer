#!/usr/bin/env python3
"""Decode tools/mame_ata_lba_probe.lua output into ATA commands and judge
whether caching them would help.

    python tools/mame_ata_lba_report.py ata.log

The probe logs raw taskfile writes; on its own that says nothing. This turns
them into (LBA, sector count) commands, then answers the two questions that
actually decide whether rtl/ki_ata.sv should keep its banks across commands:

  * how often does the next command start exactly where the last one ended
    (i.e. would plain linear READ-AHEAD have been right), and
  * how many commands would a RETAINED cache of N sectors have served whole
    (i.e. is there any locality to exploit at all).

Measured answer for KI1, 359 emulated seconds with a live match: 85% contiguous,
and retention hits 0/172 commands during camera panning, flat from 8 KB to
512 KB. See the probe's header and the ki-fmv-disk-access-is-linear note.
"""
import re
import sys
from collections import Counter, OrderedDict

# Byte offset within the CS0 block -> taskfile register.
REG = {0x10: "sc", 0x18: "sn", 0x20: "cl", 0x28: "ch", 0x30: "dh", 0x38: "cmd"}
READ_CMDS = (0x20, 0x21, 0xC4)
WRITE_CMDS = (0x30, 0x31, 0xC5)
# Cache sizes to simulate, in sectors. 16 is what ki_ata.sv holds today
# (2 banks x BATCH_SECTORS); 50 more sectors is all the free M10Ks would buy.
CACHE_SIZES = (16, 32, 64, 128, 256, 512, 1024)


def parse(path):
    """Return (commands, geometry). Each command is a dict with lba/n/frame."""
    lines = open(path, errors="replace").read().splitlines()

    # MARK lines give hit-counter -> frame, so commands can be bucketed into
    # boot / attract / player-sweeping phases.
    marks = []
    for ln in lines:
        m = re.search(r"MARK frame (\d+) hits=(\d+)", ln)
        if m:
            marks.append((int(m.group(1)), int(m.group(2))))

    def frame_of(hit):
        for f, h in marks:
            if hit <= h:
                return f
        return marks[-1][0] if marks else 0

    tf = {"sc": 0, "sn": 0, "cl": 0, "ch": 0, "dh": 0}
    # Reset defaults; the game overrides these with INITIALIZE DEVICE
    # PARAMETERS (0x91) early in boot - KI1 programs 40 sectors, 14 heads.
    heads, spt = 13, 47
    cmds = []

    for ln in lines:
        m = re.search(r"TF 100001(\w\w) (\w\w) f=(\d+)", ln)
        if not m:
            continue
        off, val, hit = int(m.group(1), 16), int(m.group(2), 16), int(m.group(3))
        name = REG.get(off)
        if name is None:
            continue
        if name != "cmd":
            tf[name] = val
            continue

        if val == 0x91:
            # Sector count is sectors per track; dh[3:0] is the MAXIMUM head
            # number, so head count is that plus one.
            if tf["sc"]:
                spt = tf["sc"]
            heads = (tf["dh"] & 0xF) + 1
            continue
        if val not in READ_CMDS + WRITE_CMDS:
            continue

        if tf["dh"] & 0x40:
            lba = (((tf["dh"] & 0xF) << 24) | (tf["ch"] << 16) |
                   (tf["cl"] << 8) | tf["sn"])
        else:
            cyl = (tf["ch"] << 8) | tf["cl"]
            lba = (cyl * heads + (tf["dh"] & 0xF)) * spt + tf["sn"] - 1
        cmds.append({"lba": lba, "n": tf["sc"] or 256,   # 0 means 256
                     "frame": frame_of(hit), "write": val in WRITE_CMDS})

    return cmds, (spt, heads)


def report(label, reads):
    if not reads:
        print(f"\n--- {label}: no commands ---")
        return
    total = sum(c["n"] for c in reads)
    print(f"\n--- {label}: {len(reads)} reads, {total} sectors "
          f"({total * 512 / 1048576:.1f} MB) ---")
    print("  sector counts:", dict(sorted(Counter(c["n"] for c in reads).items())))

    contig = fwd = back = 0
    for a, b in zip(reads, reads[1:]):
        end = a["lba"] + a["n"]
        if b["lba"] == end:
            contig += 1
        elif b["lba"] > end:
            fwd += 1
        else:
            back += 1
    pairs = max(1, len(reads) - 1)
    print(f"  next command: contiguous {contig} ({100 * contig / pairs:.0f}%), "
          f"forward jump {fwd}, backward jump {back}")

    distinct = set()
    for c in reads:
        distinct.update(range(c["lba"], c["lba"] + c["n"]))
    print(f"  distinct sectors {len(distinct)} vs {total} requested "
          f"-> re-read factor {total / len(distinct):.2f}x")

    # A hit counts only when the WHOLE command is already resident, since that
    # is what removes the exposed HPS round trip at command start.
    for size in CACHE_SIZES:
        cache = OrderedDict()
        hits = 0
        for c in reads:
            want = range(c["lba"], c["lba"] + c["n"])
            if all(s in cache for s in want):
                hits += 1
                for s in want:
                    cache.move_to_end(s)
            else:
                for s in want:
                    cache[s] = None
                    cache.move_to_end(s)
                while len(cache) > size:
                    cache.popitem(last=False)
        print(f"  retained cache {size:5d} sectors ({size * 512 / 1024:6.1f} KB): "
              f"{hits}/{len(reads)} commands fully resident "
              f"({100 * hits / len(reads):.1f}%)")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    sweep = int(sys.argv[2]) if len(sys.argv) > 2 else 11000

    cmds, (spt, heads) = parse(path)
    if not cmds:
        sys.exit("no ATA commands found - check the probe's liveness counter "
                 "(FINAL hits=) before believing this")

    reads = [c for c in cmds if not c["write"]]
    writes = [c for c in cmds if c["write"]]
    print(f"geometry in force: {spt} sectors/track, {heads} heads")
    print(f"commands: {len(cmds)} ({len(reads)} read, {len(writes)} write)")

    report("all reads", reads)
    report(f"camera-sweeping phase (frame >= {sweep})",
           [c for c in reads if c["frame"] >= sweep])

    print("\n frame window |  cmds | sectors |    MB | lba range")
    last = max(c["frame"] for c in cmds) + 1200
    for w in range(0, last, 1200):
        sel = [c for c in reads if w <= c["frame"] < w + 1200]
        if not sel:
            print(f" {w:6d}-{w + 1200:6d} |     0 |       0 |   0.0 | -")
            continue
        sec = sum(c["n"] for c in sel)
        lo = min(c["lba"] for c in sel)
        hi = max(c["lba"] + c["n"] for c in sel)
        print(f" {w:6d}-{w + 1200:6d} | {len(sel):5d} | {sec:7d} | "
              f"{sec * 512 / 1048576:5.1f} | {lo}-{hi}")


if __name__ == "__main__":
    main()
