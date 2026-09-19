#!/usr/bin/env python3
"""Replay a kinst data-access trace through candidate D-cache geometries.

The trace comes from tools/mame_dcache_trace.lua. READ ITS HEADER FIRST: MAME
0.288's MIPS3 core serves plain 32-bit and 8-bit RAM accesses straight from
"fastram", so they never reach a tap. The trace holds every 64-bit access and
every halfword - which is to say KI's block copies - and nothing else.

That decides what this can answer. It CAN say whether the copy streams thrash
a direct-mapped cache, because a copy loop keeps its pointers in registers and
makes few scalar accesses while it runs. It CANNOT give a frame's total miss
count or say anything about scalar data, so do not compare its totals with
the Perf page's MC.

Misses are split the standard way:
  compulsory  first touch of a line in the trace - no cache avoids these
  capacity    misses a FULLY associative cache of the same size still takes
  conflict    what direct-mapping adds on top - what associativity can fix

Usage:  python tools/mame_dcache_sim.py C:/temp/kitrace/dcache.bin
"""

import struct
import sys
from collections import Counter, OrderedDict

LINE = 32
FRAME_CYCLES = 1_695_232          # CY = 0x19DE units of 256, at 100 MHz
FB_PAGES = ((0x30000, 0x55800), (0x58000, 0x7D800))

# Per-miss costs measured in tb_ki_perfbench, bridge gather in place
# (docs/OPTIMIZATION-HISTORY.md, "Dirty victims").
CLEAN_MISS = 80.9
DIRTY_EXTRA = 177.3 - 80.9


def is_fb(addr):
    return any(lo <= addr < hi for lo, hi in FB_PAGES)


def read_frames(path):
    raw = open(path, 'rb').read()
    n = len(raw) // 4
    words = struct.unpack('<%dI' % n, raw[:n * 4])
    frames, cur = [], []
    for w in words:
        if w == 0xFFFFFFFF:
            frames.append(cur)
            cur = []
        else:
            cur.append(w)
    return frames


def accesses(frame):
    """Yield (addr, write, kind). A 64-bit access arrives as two full-mask
    32-bit halves at +0 and +4 - plain 32-bit accesses are invisible, so a
    full-mask event can only be one of those halves. Keep the +0 half: both
    halves always sit in the same 32-byte line."""
    for w in frame:
        addr = w & 0x0FFFFFFF
        write = bool(w & 0x80000000)
        half = bool(w & 0x40000000)
        if half:
            yield addr, write, 'h'
        elif (addr & 7) == 0:
            yield addr, write, 'd'


class SetAssoc:
    """Write-back, write-allocate, LRU - the policy the core's D-cache uses."""

    def __init__(self, size, ways):
        self.ways = ways
        self.sets = size // (LINE * ways)
        self.tag = [[-1] * ways for _ in range(self.sets)]
        self.dirty = [[False] * ways for _ in range(self.sets)]
        self.age = [[0] * ways for _ in range(self.sets)]
        self.t = 0
        # Way prediction, for loads only - a store's way comes from the
        # compare. A predictor that reads one way first is right as often as
        # the hit lands there. Two candidates: the way most recently used by
        # any access (one bit per set that doubles as the LRU state - what
        # cpu_datacache.vhd built), and the way most recently LOADED from.
        # They differ in a copy loop whose source and destination share a set:
        # its stores flip the first every time.
        self.last_load = [0] * self.sets
        self.load_hits = 0
        self.load_mru_ok = 0
        self.load_last_ok = 0

    def access(self, addr, write):
        line = addr // LINE
        s = line % self.sets
        tag = line // self.sets
        self.t += 1
        tags, ages, dirty = self.tag[s], self.age[s], self.dirty[s]
        mru = max(range(self.ways), key=ages.__getitem__)
        for w in range(self.ways):
            if tags[w] == tag:
                if not write:
                    self.load_hits += 1
                    self.load_mru_ok += (w == mru)
                    self.load_last_ok += (w == self.last_load[s])
                    self.last_load[s] = w
                ages[w] = self.t
                if write:
                    dirty[w] = True
                return False, False
        w = min(range(self.ways), key=ages.__getitem__)
        evict_dirty = tags[w] != -1 and dirty[w]
        tags[w], dirty[w], ages[w] = tag, write, self.t
        if not write:
            self.last_load[s] = w
        return True, evict_dirty


class FullyAssoc:
    def __init__(self, size):
        self.lines = size // LINE
        self.lru = OrderedDict()

    def access(self, addr, write):
        line = addr // LINE
        if line in self.lru:
            self.lru.move_to_end(line)
            if write:
                self.lru[line] = True
            return False, False
        evict_dirty = False
        if len(self.lru) >= self.lines:
            _, evict_dirty = self.lru.popitem(last=False)
        self.lru[line] = write
        return True, evict_dirty


CONFIGS = [
    ('16K direct-mapped (this core)', lambda: SetAssoc(16384, 1)),
    ('16K 2-way (the real R4600)',    lambda: SetAssoc(16384, 2)),
    ('16K 4-way',                     lambda: SetAssoc(16384, 4)),
    ('16K fully associative',         lambda: FullyAssoc(16384)),
    ('32K direct-mapped',             lambda: SetAssoc(32768, 1)),
    ('32K 2-way',                     lambda: SetAssoc(32768, 2)),
]


def main(path):
    frames = read_frames(path)
    if not frames:
        sys.exit('no complete frames in ' + path)
    print('Trace: %s, %d frames' % (path, len(frames)))
    print('Holds 64-bit accesses and halfwords ONLY (see the header): the block')
    print('copies, not the whole data stream. Totals are not the Perf page MC.\n')

    # ---------------------------------------------------------- what moves
    per = Counter()
    blocks = Counter()
    for fr in frames:
        for addr, write, kind in accesses(fr):
            region = 'fb' if is_fb(addr) else ('main' if addr >= 0x08000000 else 'low')
            per[(region, 'W' if write else 'R', kind)] += 1
            if kind == 'd':
                blocks[(addr & ~0xFFFF, 'W' if write else 'R')] += 1
    nf = len(frames)
    print('Per frame, by region (d = 64-bit doubleword, h = halfword):')
    for key in sorted(per):
        region, rw, kind = key
        n = per[key] / nf
        extra = ' = %.0f KB' % (n * 8 / 1024) if kind == 'd' else ''
        print('  %-5s %s %s %9.0f%s' % (region, rw, kind, n, extra))

    print('\nWhere the doublewords go, 64 KB blocks, per frame (index = address mod 16 KB):')
    for (base, rw), n in sorted(blocks.items()):
        if n / nf >= 256:
            print('  %08X-%08X %s %7.0f' % (base, base + 0xFFFF, rw, n / nf))

    # ------------------------------------------------ cached stream, replayed
    # The framebuffer pages are forced uncached in the core, so their accesses
    # never touch the D-cache; everything else in RAM is cached in gameplay
    # (the Perf page reads UM = 0 there).
    stream = [(a, w) for fr in frames for a, w, _ in accesses(fr) if not is_fb(a)]
    frame_len = [sum(1 for a, _, _ in accesses(fr) if not is_fb(a)) for fr in frames]

    # Counted over the same frames as the misses: the first frame only warms
    # the caches, so a line first touched there is not a compulsory miss of
    # the measured frames.
    seen = set()
    compulsory = 0
    for i, (a, _) in enumerate(stream):
        ln = a // LINE
        if ln not in seen:
            seen.add(ln)
            if i >= frame_len[0]:
                compulsory += 1

    print('\nCached stream replayed: %d accesses over %d frames' % (len(stream), nf))
    ws = [len({a // LINE for a, _, _ in accesses(fr) if not is_fb(a)}) * LINE / 1024
          for fr in frames]
    print('Working set, distinct cached lines touched per frame: %.0f KB (min %.0f, max %.0f)'
          % (sum(ws) / nf, min(ws), max(ws)))
    print('\n  %-32s %10s %10s %12s %10s   %s' % (
        'geometry', 'miss/fr', 'dirty/fr', 'stall/fr', 'of frame', 'misses, min-max frame'))
    results = {}
    predictors = {}
    for name, make in CONFIGS:
        c = make()
        misses = dirty = 0
        # Warm the cache on the first frame, measure the rest: a cold start
        # would count every line of the first frame as a miss.
        warm = frame_len[0]
        bounds, acc = [], 0
        for n in frame_len:
            acc += n
            bounds.append(acc)
        per_frame = [0] * nf
        f = 0
        for i, (a, w) in enumerate(stream):
            while i >= bounds[f]:
                f += 1
            m, d = c.access(a, w)
            if i >= warm:
                misses += m
                dirty += d
                per_frame[f] += m
        fr = max(1, nf - 1)
        cyc = (misses * CLEAN_MISS + dirty * DIRTY_EXTRA) / fr
        results[name] = misses / fr
        spread = per_frame[1:] or [0]
        print('  %-32s %10.0f %10.0f %12.0f %9.1f%%   %d-%d' % (
            name, misses / fr, dirty / fr, cyc, 100.0 * cyc / FRAME_CYCLES,
            min(spread), max(spread)))
        if isinstance(c, SetAssoc) and c.ways == 2 and c.load_hits:
            predictors[name] = (c.load_hits, c.load_mru_ok, c.load_last_ok)

    for name, (hits, mru_ok, last_ok) in predictors.items():
        print('\nWay prediction for %s, over %d load hits:' % (name, hits))
        print('  most recently used, any access    %5.1f%% right' % (100.0 * mru_ok / hits))
        print('  most recently LOADED from         %5.1f%% right' % (100.0 * last_ok / hits))

    dm = results['16K direct-mapped (this core)']
    fa = results['16K fully associative']
    comp = compulsory / max(1, nf - 1)
    print('\n16K direct-mapped misses per frame, split, over the measured frames:')
    print('  compulsory  %7.0f   first touch of a line - no cache avoids these' % comp)
    print('  capacity    %7.0f   the 16 KB is too small for the reuse distance' % max(0.0, fa - comp))
    print('  conflict    %7.0f   direct-mapping on top - associativity fixes these' % max(0.0, dm - fa))


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'C:/temp/kitrace/dcache.bin')
