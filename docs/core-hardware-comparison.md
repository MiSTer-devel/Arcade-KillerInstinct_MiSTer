# Killer Instinct Test ROM: MiSTer Core vs Original Hardware

This report compares results from the Killer Instinct memory, CPU and IDE test ROM on the MiSTer core and on an original board.

| Platform | Source | Test ROM build |
|---|---|---|
| **Original hardware** | Real KI board, A-19489, measured 2026-11-09 | Nov 7 2026 (current CPU tests) |
| **MiSTer core** | This core, release build with all six CPU features disabled (section 10), measured 2026-11-08 | Nov 7 2026 |

**Original hardware measurements courtesy of [MisterAddons](https://github.com/misteraddons).**

Units: throughput is in MB/s (MB = 10^6 bytes). Timings are in CPU cycles, where 1 cycle = 2 × CP0 Count. Every value is the best of 3 runs unless the page says otherwise.

The Nov 7 test ROM reorganizes the pages by what they test and adds caches, TLB, integer, floating-point, system and timing-spread measurements. The sections below follow its page order.

---

## Summary

- **The board passes all 252 CPU tests on the current ROM** (2,708 checks, 0 failed), including the corrected `umode/kernel_addr_badvaddr` (see section 10). PRId, FIR and Config match the board exactly.
- **With every CPU feature enabled, the core passes all 252 tests on the current ROM.** The release build disables six features that KI does not use, and it fails only the 45 tests that exercise them.
- **The heavy frame (KI2 barrel explosion) is within 1.2% of the board** (3,615 vs 3,660 kcycles), and the rendered checksum is identical.
- **Where the board uses its fastest memory (SRAM, VRAM), the core's reads are within 2% of the board.** Uncached SRAM reads are 98.0% of the board's speed. Cached reads are 99.5%.
- **The core is faster than the board in many places:** board DRAM (the core puts DRAM and SRAM on the same SDRAM), cached writes, IDE, integer multiply and divide, `mul.s`/`mul.d`, FP compare-and-branch, uncached ROM reads, and several cache operations.
- **The core is clearly slower in these places:**
  - Dependent-miss latency: 26.10 cycles per load against 24.21 (+1.89, +7.8%).
  - Uncached `sb`/`sh`/`sw`: 35.98 / 35.98 / 16.00 cycles against the board's 7.99 for every size.
  - Code that alternates between two blocks 16 KiB apart: 6.08 cycles per instruction against 1.00. The core's I-cache is direct-mapped; the board's is 2-way.
  - Loads that touch 8 or 16 mapped pages: 12.03 / 9.03 cycles per load against 2.03.
  - `lwc1` into `add.s`: 8.06 cycles against 4.03.
  - `mfc0 Count`: 3.03 cycles against 1.03.
  - Single-precision moves (`mov.s`, `neg.s`): 2.01 cycles against 1.03.
- **Vblank is 234 µs shorter on the core** (1,365.54 vs 1,600.06 µs). The frame period itself matches to 0.03%.

---

## 1. Memory bandwidth

### Throughput (MB/s, 64 KiB, best of 3)

| Region | Test | Original HW | MiSTer core | Core / HW |
|---|---|---:|---:|---:|
| SRAM `00000-2FFFF` | Uncached read | 63.97 | 62.72 | 98.0% |
| | Uncached write | 100.03 | 99.86 | 99.8% |
| | Cached read | 133.32 | 132.66 | 99.5% |
| | Cached write | 112.27 | 140.32 | 125.0% |
| VRAM0 `30000-57FFF` | Uncached read | 63.97 | 63.99 | 100.0% |
| | Uncached write | 100.03 | 133.38 | 133.3% |
| | Cached read | 133.32 | 133.28 | 100.0% |
| | Cached write | 112.27 | 261.16 | 232.6% |
| VRAM1 `58000-7FFFF` | Uncached read | 63.97 | 63.99 | 100.0% |
| | Uncached write | 100.03 | 133.38 | 133.3% |
| | Cached read | 133.32 | 133.28 | 100.0% |
| | Cached write | 112.27 | 261.16 | 232.6% |
| DRAM `8000000-87FFFFF` | Uncached read | 54.68 | 62.72 | 114.7% |
| | Uncached write | 56.79 | 99.86 | 175.8% |
| | Cached read | 113.46 | 132.66 | 116.9% |
| | Cached write | 69.02 | 140.32 | 203.3% |

On the board, SRAM and VRAM give identical results, and DRAM is slower than both. In the core, SRAM and DRAM give identical results because both live in the same SDRAM. As a result, the core's DRAM runs at SRAM speed, faster than the board's DRAM. Cached writes are faster than the board in every region.

### Uncached stores (cycles per store)

| Region | Store | Original HW | MiSTer core | Core − HW |
|---|---|---:|---:|---:|
| SRAM `14000` | `sb` | 7.99 | 35.98 | +27.99 |
| | `sh` | 7.99 | 35.98 | +27.99 |
| | `sw` | 7.99 | 16.00 | +8.01 |
| | `sd` | 7.99 | 8.00 | match |
| DRAM `81C0000` | `sb` | 14.08 | 35.98 | +21.90 |
| | `sh` | 14.08 | 35.98 | +21.90 |
| | `sw` | 14.09 | 16.01 | +1.92 |
| | `sd` | 14.09 | 8.00 | −6.09 |

The board takes the same time for every store size: one SRAM store every 8 cycles and one DRAM store every 14. The core matches the board for `sd` to SRAM, but a byte or halfword store takes 4.5 times as long, and a word store twice as long.

### Uncached `ld` latency (cycles per load)

| When | Region | Original HW | MiSTer core |
|---|---|---:|---:|
| In vblank | SRAM | 12.06 | 12.19 |
| | VRAM front buffer | 12.08 | 12.03 |
| | VRAM back buffer | 12.07 | 12.03 |
| | DRAM | 14.18 | 12.18 |
| Mid frame | SRAM | 12.07 | 12.18 |
| | VRAM front buffer | 12.08 | 12.03 |
| | VRAM back buffer | 12.07 | 12.03 |
| | DRAM | 14.17 | 12.17 |

Neither platform slows down when video scanout is reading VRAM: the vblank and mid-frame rows match. The core's SRAM loads are about 0.12 cycles slower than the board's, and its DRAM loads are 2 cycles faster.

---

## 2. SRAM map

The test reads an 8 KiB window at 16 KiB steps across all 512 KiB, looking for a speed step between regions.

| | Original HW | MiSTer core |
|---|---:|---:|
| Peak (MB/s) | 63.96 | 63.97 |
| Result | Flat, no step found | Flat, no step found |

On the board, every bar is the same height across SRAM, VRAM0 and VRAM1. On the core, the SRAM bars (`00000-2FFFF`) are slightly shorter than the VRAM bars, which matches the 62.72 vs 63.99 gap on page 1. That gap is too small for the test to call it a step.

---

## 3. Memory latency

### Dependent miss (cycles per load, cold D-cache)

| Test | Original HW | MiSTer core | Core − HW |
|---|---:|---:|---:|
| Chase, 128 KiB shuffled, 4096 nodes | 24.21 | 26.10 | +1.89 |
| Stride 32 | 24.20 | 26.07 | +1.87 |
| Stride 64 | 24.20 | 26.10 | +1.90 |
| Stride 128 | 24.21 | 26.07 | +1.86 |
| Stride 256 | 24.20 | 26.07 | +1.87 |
| Stride 512 | 24.20 | 26.10 | +1.90 |
| Stride 1 Ki | 24.21 | 26.07 | +1.86 |
| Stride 2 Ki | 24.20 | 26.07 | +1.87 |
| Stride 4 Ki | 24.21 | 26.07 | +1.86 |
| Stride 8 Ki | 24.21 | 26.07 | +1.86 |
| Bank pair, 1 KiB | 24.21 | 26.12 | +1.91 |
| Bank pair, bank01 | 24.21 | 26.12 | +1.91 |
| Bank ratio | 1.00 | 1.00 | |

Every latency case on the core is a steady ~1.9 cycles above the board. Neither platform shows a stride or bank effect.

### Cached stores (cycles per 32-byte line)

| Test | Original HW | MiSTer core |
|---|---:|---:|
| 4 of 4 words | 46.86 | 23.56 |
| 1 of 4 words | 45.36 | 13.79 |
| Ratio | 0.96 | 0.58 |

The core stores into the cache about twice as fast as the board. This matches the cached-write column on page 1.

---

## 4. Caches and TLB

Cycles, best of 3, each loop warmed once first.

### D-cache

| Test | Unit | Original HW | MiSTer core | Core − HW |
|---|---|---:|---:|---:|
| `lw`, 1 destination | cyc/load | 1.03 | 1.03 | match |
| `lw`, 8 destinations | cyc/load | 1.03 | 1.03 | match |
| `lw` chain | cyc/load | 2.01 | 2.01 | match |
| 2 lines per set | cyc/access | 1.03 | 3.03 | +2.00 |
| 3 lines per set | cyc/access | 24.21 | 13.05 | −11.16 |
| A B A C | cyc/access | 18.15 | 19.57 | +1.42 |
| Dirty victim | cyc/access | 33.57 | 21.37 | −12.20 |
| Index Writeback Invalidate | cyc/op | 12.01 | 4.03 | −7.98 |
| `sw` + Hit Writeback Invalidate | cyc/op | 68.26 | 74.14 | +5.88 |
| `lw` + Hit Invalidate | cyc/op | 36.12 | 27.30 | −8.82 |

Both caches keep two lines in a set without a miss, but the core pays 2 cycles more per access for it. With three lines per set, both miss on every access, and the core's miss is cheaper. A write-back of a dirty victim also costs the core less. A Hit Writeback Invalidate after a store is the one cache operation where the core is slower.

### I-cache (cycles per instruction)

| Test | Original HW | MiSTer core | Core − HW |
|---|---:|---:|---:|
| 1 block | 1.00 | 1.00 | match |
| 2 blocks, 8 KiB apart | 1.00 | 1.00 | match |
| 2 blocks, 16 KiB apart | 1.00 | 6.08 | +5.08 |
| 3 blocks at 0 / 8 / 16 KiB | 4.31 | 4.37 | +0.06 |
| 32 KiB stream | 4.26 | 6.00 | +1.74 |
| ROM, uncached | 149.78 | 82.28 | −67.50 |

The board's 16 KiB I-cache is 2-way with 8 KiB ways, so two blocks 16 KiB apart share a set and both stay cached. The core's I-cache is direct-mapped, so they evict each other on every pass. Uncached code from the boot ROM runs almost twice as fast on the core.

### TLB (cycles per load)

| Test | Original HW | MiSTer core | Core − HW |
|---|---:|---:|---:|
| KSEG0, 16 pages | 2.03 | 1.03 | −1.00 |
| Mapped, 1 page | 1.03 | 1.03 | match |
| Mapped, 2 pages | 1.03 | 1.03 | match |
| Mapped, 4 pages | 1.03 | 1.03 | match |
| Mapped, 8 pages | 2.03 | 12.03 | +10.00 |
| Mapped, 16 pages | 2.03 | 9.03 | +7.00 |

Up to 4 mapped pages, both platforms load at full speed. From 8 pages on, the board adds 1 cycle per load and the core adds 8-11. The board also adds 1 cycle per load across 16 KSEG0 pages, which are not mapped at all, so its extra cycle at 8 and 16 pages is probably not a TLB cost. KI runs entirely in KSEG0 and KSEG1, so it does not depend on the mapped rows.

---

## 5. CPU integer

Pipeline cycles, caches warm, best of 3.

| Test | Unit | Original HW | MiSTer core | Core − HW |
|---|---|---:|---:|---:|
| `addu` chain | cyc/op | 1.03 | 1.03 | match |
| `multu` | cyc/op | 8.00 | 5.03 | −2.97 |
| `divu` | cyc/op | 40.99 | 37.03 | −3.96 |
| `addu` MIPS | MIPS | 96.96 | 96.96 | match |
| `mult` → `mflo` | cyc/pair | 9.06 | 6.06 | −3.00 |
| `mult` → `mfhi` | cyc/pair | 10.06 | 6.06 | −4.00 |
| `dmult` → `mflo` | cyc/pair | 11.06 | 9.06 | −2.00 |
| `divu` → `mflo` | cyc/pair | 43.06 | 38.06 | −5.00 |
| `ddivu` → `mflo` | cyc/pair | 75.06 | 70.06 | −5.00 |
| `beq` taken | cyc/pair | 2.06 | 2.06 | match |
| `bne` untaken | cyc/pair | 2.06 | 2.06 | match |
| `bnel` untaken | cyc/pair | 2.06 | 2.06 | match |
| `lw` → `addu` | cyc | 3.06 | 3.06 | match |
| `lbu` → `addu` | cyc | 3.06 | 3.06 | match |
| `ld` chain | cyc | 2.01 | 2.01 | match |
| `lwl` + `lwr` | cyc | 2.06 | 2.06 | match |
| `ldl` + `ldr` | cyc | 2.06 | 2.06 | match |
| `sw` → `lw` | cyc | 2.06 | 2.06 | match |
| `sync` | cyc/op | 1.03 | 1.03 | match |
| `mfc0 Count` | cyc/op | 1.03 | 3.03 | +2.00 |

The core matches the board on the ALU, branches, loads and stores. Every multiply and divide is 2-5 cycles faster. The board reads `mfc0 Count` in 1 cycle and the core in 3.

---

## 6. CPU floating point

Pipeline cycles, best of 3, FR=1.

| Test | Unit | Original HW | MiSTer core | Core − HW |
|---|---|---:|---:|---:|
| `add.s` | cyc/op | 4.00 | 4.03 | +0.03 |
| `add.d` | cyc/op | 4.00 | 4.03 | +0.03 |
| `mul.s` | cyc/op | 7.99 | 7.01 | −0.98 |
| `mul.d` | cyc/op | 7.99 | 7.01 | −0.98 |
| `div.s` | cyc/op | 31.98 | 32.01 | +0.03 |
| `div.d` | cyc/op | 60.97 | 61.01 | +0.04 |
| `sqrt.s` | cyc/op | 30.98 | 31.01 | +0.03 |
| `sqrt.d` | cyc/op | 59.97 | 60.02 | +0.05 |
| `cvt.d.s` / `cvt.s.d` | cyc | 6.00 | 6.06 | +0.06 |
| `cvt.w.s` / `cvt.s.w` | cyc | 10.00 | 11.06 | +1.06 |
| `mov.s` | cyc | 1.03 | 2.01 | +0.98 |
| `neg.s` | cyc | 1.03 | 2.01 | +0.98 |
| `c.eq` + `bc1t` | cyc | 5.09 | 3.09 | −2.00 |
| `mtc1` → `mfc1` | cyc | 4.03 | 3.06 | −0.97 |
| `lwc1` → `add.s` | cyc | 4.03 | 8.06 | +4.03 |
| `add.s`, 4 destinations | cyc/op | 16.00 | 16.13 | +0.13 |
| `mul.d`, 4 destinations | cyc/op | 24.00 | 24.13 | +0.13 |

Add, divide and square root match the board to within 0.05 cycles. Multiply is 1 cycle faster on the core. The largest gap is a loaded value feeding `add.s`, which takes 4 cycles longer on the core.

---

## 7. System and I/O

### Video

| Test | Original HW | MiSTer core | Core − HW |
|---|---:|---:|---:|
| Vsync (Hz) | 58.96 | 58.98 | +0.02 |
| Frame (µs) | 16,959.98 | 16,954.54 | −5.44 |
| Vblank (µs) | 1,600.06 | 1,365.54 | −234.52 |

### Interrupts (cycles)

| Test | Original HW | MiSTer core |
|---|---:|---:|
| Compare interrupt, min | 10.00 | 12.00 |
| Compare interrupt, max | 54.00 | 88.00 |
| Vblank interrupt, min | 12.00 | 12.00 |
| Vblank interrupt, max | 20.00 | 24.00 |
| `syscall` + `eret` | 39.03 | 42.04 |

### I/O reads (cycles)

| Register | Original HW | MiSTer core | Core − HW |
|---|---:|---:|---:|
| Player 1 | 14.03 | 14.03 | match |
| DIP switches | 14.03 | 14.03 | match |
| IDE status | 48.03 | 14.03 | −34.00 |
| Sound status | 14.03 | 14.03 | match |
| ROM word | 142.03 | 80.03 | −62.00 |
| SRAM word | 12.03 | 28.10 | +16.07 |

### IDE and sound

| Test | Original HW | MiSTer core | Core / HW |
|---|---:|---:|---:|
| IDE read, LBA 0-127 (MB/s) | 3.57 | 4.69 | 131.4% |
| DCS acknowledge, min (µs) | 58.36 | 57.80 | |
| DCS acknowledge, max (µs) | 78.94 | 58.14 | |
| DCS boot (ms) | 0.05 | 0.05 | |

The core's frame period matches the board to 0.03%, but its vblank is 234 µs shorter. Its worst-case interrupt latencies are longer than the board's: 88 cycles against 54 for Compare, and 24 against 20 for vblank. The IDE status register and the boot ROM read faster on the core. The SRAM word read is the one I/O read that is slower, at 28.10 cycles against 12.03. The DCS boot time is 0.05 ms on both, which is too short for a DSP boot, so the test probably times the first byte's handshake.

---

## 8. Heavy frame: KI2 barrel explosion

This page replays the sprite blend of KI2's heaviest frame: 10 sprites, cold D-cache, best of 3.

| Sprite | Runs | Pixels | HW cyc/px | Core cyc/px | HW kcycles | Core kcycles | Core vs HW |
|---|---|---:|---:|---:|---:|---:|---:|
| 312×240 | right | 73,625 | 20.31 | 19.97 | 1,495 | 1,470 | −1.7% |
| 34×36 | left | 1,060 | 39.98 | 39.12 | 42 | 41 | −2.2% |
| 146×112 | left | 7,151 | 29.51 | 28.98 | 211 | 207 | −1.8% |
| 312×240 | left | 69,787 | 18.10 | 18.03 | 1,263 | 1,258 | −0.4% |
| 63×43 | right | 1,025 | 61.99 | 59.66 | 63 | 61 | −3.8% |
| 56×52 | right | 1,732 | 42.41 | 41.29 | 73 | 71 | −2.6% |
| 81×90 | left | 4,705 | 30.61 | 29.91 | 144 | 140 | −2.3% |
| 184×137 | left | 15,808 | 21.05 | 20.88 | 332 | 330 | −0.8% |
| 20×24 | right | 266 | 62.21 | 60.27 | 16 | 16 | −3.1% |
| 19×25 | right | 286 | 59.50 | 57.48 | 17 | 16 | −3.4% |
| **Frame** | | **175,445** | **20.86** | **20.60** | **3,660** | **3,615** | **−1.2%** |

| | Original HW | MiSTer core |
|---|---:|---:|
| vblanks | 2.15 | 2.13 |
| Checksum | `0x727B3D0B` | `0x727B3D0B` |

The core finishes the frame 1.2% faster than the board, and every sprite is within 0.4-3.8% of the board. Both platforms produce the same checksum, so the rendered output is identical.

---

## 9. Timing spread

64 runs of each kernel, cycles per operation.

| Kernel | HW min | HW median | HW max | Core min | Core median | Core max |
|---|---:|---:|---:|---:|---:|---:|
| `addu` chain | 1.03 | 1.03 | 1.03 | 1.03 | 1.03 | 1.03 |
| D-cache `lw` chain | 2.01 | 2.01 | 2.01 | 2.01 | 2.01 | 2.01 |
| Uncached SRAM `ld` | 12.06 | 12.07 | 12.07 | 12.17 | 12.18 | 12.20 |
| Uncached VRAM `ld` | 12.08 | 12.08 | 12.08 | 12.03 | 12.03 | 12.03 |
| Uncached DRAM `ld` | 14.15 | 14.17 | 14.19 | 12.17 | 12.18 | 12.20 |

Both platforms are steady from run to run: no kernel varies by more than 0.04 cycles. The core's SRAM and DRAM loads, which share its SDRAM, spread a little more than the board's SRAM loads.

---

## 10. CPU tests (iris cpu-tests, R4600 expectations, little-endian)

| | Original HW (current 252-test ROM) |
|---|---|
| CPU | R4600 |
| PRId | `0x2020` |
| FIR | `0x2020` |
| Config | `0x000264B3` |
| Checks | 2,708 passed, 0 failed |
| Tests | 252 run, 0 failed |

The board passes every test on the current ROM. On the earlier 264-test ROM it failed one, 2,764 checks passed and 2 failed: `umode/kernel_addr_badvaddr`. The test checks what the R4600 writes to the upper half of BadVAddr when 32-bit User or Supervisor code touches a Kernel address. It expected `0x3FFFFF00`, the value the board had reported for a User-mode load from KSEG0. The board reports that value for User-mode loads from KSEG1, KSEG2 and KSEG3 and a User-mode store to KSEG0. It reports the plain sign extension for the other two cases:

| Case | Board's BadVAddr |
|---|---|
| User-mode jump to KSEG0 (instruction fetch) | `0xFFFFFFFF88058008` (sign extension) |
| Supervisor-mode load from KSEG0 | `0xFFFFFFFF80000000` (sign extension) |

So the R4600's `0x3FFFFF00` upper half applies only to User-mode loads and stores. The test now expects exactly that, and the board passes it.

The current test ROM also adds `excep/user_fetch_via_tlb` and drops the 13 MIPS IV tests (the `mips4` and `mips4_fp` groups). The R4600 is a MIPS III part, so on it those tests only checked that each MIPS IV instruction is refused. That leaves 252 tests.

### Core with every CPU feature enabled

Measured 2026-11-09 on a build with all six generics below set to false, running the current 252-test ROM. **The core passes all 252 tests, like the board.** PRId, FIR and Config match the board exactly.

| | MiSTer core (all features enabled) |
|---|---|
| Tests | 252 run, 0 failed |

The first full-feature run of this ROM failed six User-mode tests. Four CPU accuracy fixes closed them:

- **Exception vectors in 64-bit mode.** The vector's upper half was zero when the exception came from 32-bit code, so a fetch still decoding with UX set took a TLB miss on the vector. Vectors are now always sign-extended.
- **64-bit User segment.** A User address above `xuseg` (`0xFF_FFFFFFFF`) was not flagged as unusable, so it raised no Address Error.
- **Register jumps into Kernel segments.** A User or Supervisor `jr`/`jalr` to a region that mode may not execute from now raises an Address Error at the jump, with EPC and BadVAddr set to the target. Before, only misaligned targets did.
- **BadVAddr `0x3FFFFF00` rule.** It now applies only to User-mode loads and stores, as measured on the board. It no longer applies to Supervisor mode or to instruction fetches.

The jump check sits behind the existing generics: `INSTR_KSEG_ONLY` removes the region half, and `NO_ADDRESS_ERROR` removes all of it. The other three fixes only change 64-bit or User-mode behaviour, and KI never uses either.

On the earlier 263-test ROM, the board passed every test (2,748 checks, 0 failed).

### Failed tests with release features disabled

Release builds disable the following unused CPU features to reduce slack.
```
-- KI uses the 32-bit exception-address contract.
ADDR32_ONLY          => true,
-- KI does not use the optional trap-instruction exception path.
NO_TRAP_INSTR        => true,
-- KI instruction fetches use KSEG0/KSEG1.
INSTR_KSEG_ONLY      => true,
-- KI never converts a long outside +-2^55 to floating point.
FPU_CVT_L_NARROW     => true,
-- Both games' exception handlers serve only the timer interrupt and
-- restart the board on any other cause, so neither takes an address
-- error or a floating-point trap.
NO_ADDRESS_ERROR     => true,
NO_FPU_EXCEPTION     => true
```

Measured 2026-11-08 on a release build with all six features disabled, running
the current 252-test ROM. That ROM adds `excep/user_fetch_via_tlb`, which checks
that a User-mode fetch goes through the TLB, and `umode/kernel_addr_badvaddr`.
It drops the 13 MIPS IV tests. With these features disabled, the core fails 45
of the 252 tests (139 of 2,350 checks). The User-mode tests stop at the
`user_fetch_via_tlb` probe without running their checks.

| | MiSTer core (release features disabled) |
|---|---|
| Checks | 2,211 passed, 139 failed |
| Tests | 252 run, 45 failed |

| Group | Failed tests | Count | Cause |
|---|---|---:|---|
| Trap instructions | `mem/load_then_trap`, `excep/teq_tne`, `excep/tlt_tge`, `excep/trap_immediate` | 4 | `NO_TRAP_INSTR` |
| User mode and CP0 usability | `excep/user_fetch_via_tlb`, `excep/cp0_unusable_user`, `excep/cp0_usable_cu0`, `umode/syscall_first`, `umode/syscall_second`, `umode/break_then_syscall`, `umode/interrupt_then_sys`, `umode/load_miss_first`, `umode/load_miss_third`, `umode/fetch_miss_jump`, `umode/fetch_miss_entry`, `umode/kseg0_load_first`, `umode/kseg0_load_third`, `umode/kernel_addr_badvaddr`, `umode/unaligned_load_first`, `umode/dword_ops_with_ux` | 16 | `INSTR_KSEG_ONLY` (user-mode code fetches from KUSEG); `ADDR32_ONLY` for `dword_ops_with_ux` |
| Address errors | `mem/unaligned_lw_faults`, `mem/unaligned_ld_faults`, `mem/unaligned_sw_faults`, `mem/unaligned_lh_faults`, `fpu/unaligned_access`, `fpu/unaligned_badvaddr` | 6 | `NO_ADDRESS_ERROR` |
| FPU traps | `fpu/trap_invalid`, `fpu/trap_divide_by_zero`, `fpu/trap_overflow`, `fpu/trap_inexact`, `fpu/trap_overflow_via_i`, `fpu/trap_sqrt_negative`, `fpu/trap_ctc1_arms`, `fpu/trap_epc`, `fpu/trap_delay_slot`, `fpu/trap_behind_a_load`, `fpu/denorm_operand`, `fpu/denorm_result_fs0`, `fpu/underflow_enable_e`, `fpu/denorm_double`, `fpu/cmp_trap_on_signal`, `fpu/snan_operands`, `fpu/cvt_out_of_range`, `fpu/cvt_infinity` | 18 | `NO_FPU_EXCEPTION` |
| FPU long conversion | `fpu/vec_cvt_from_l` | 1 | `FPU_CVT_L_NARROW` |

All 45 failures exercise features that KI does not use. None of them affect the game.

---

## Where the core differs from the board

| Area | Core vs board | Note |
|---|---|---|
| Uncached `sb` / `sh` / `sw` | **+28.0 / +28.0 / +8.0 cycles** to SRAM | The board stores every size in 8 cycles; `sd` matches |
| I-cache, blocks 16 KiB apart | **6.08 vs 1.00 cycles per instruction** | The core's I-cache is direct-mapped; the board's is 2-way |
| Mapped loads across 8 / 16 pages | **+10.0 / +7.0 cycles** | KI does not use mapped pages |
| `lwc1` → `add.s` | **+4.03 cycles** | |
| Dependent-miss latency | **~1.9 cycles slower** (+7.8%) | |
| Vblank length | 234 µs shorter | Frame period matches to 0.03% |
| Interrupt latency, worst case | Compare +34 cycles, vblank +4 cycles | Best case matches within 2 cycles |
| `mfc0 Count` | +2.00 cycles | |
| D-cache, 2 lines per set | +2.00 cycles | |
| `mov.s` / `neg.s` / `cvt.w` | ~+1 cycle | |
| SRAM word I/O read | +16.07 cycles | Page 1's uncached SRAM `ld` is only +0.12 |
| Uncached SRAM read | 1.25 MB/s slower (−2.0%) | VRAM matches exactly |
| Cached SRAM read | 0.66 MB/s slower (−0.5%) | VRAM matches exactly |
| DRAM (all four tests) | 15-76% faster | Core's DRAM shares the SRAM's SDRAM |
| Cached writes | 25-133% faster | Stores into the cache ~2× faster than the board |
| Uncached VRAM write | 33% faster | |
| IDE | 31% faster | |
| Integer multiply and divide | 2-5 cycles faster | |
| `mul.s` / `mul.d`, `c.eq` + `bc1t`, `mtc1` → `mfc1` | 1-2 cycles faster | |
| Uncached ROM (code and data) | 44-45% fewer cycles | |
| D-cache misses with 3 lines per set, dirty victims, index and hit-invalidate ops | 8-12 cycles faster | |
| Heavy frame | 1.2% faster | Same checksum |

Everything else matches the board: the ALU, branches, cache-hit loads, the load-use delay, `lwl`/`lwr` and `ldl`/`ldr`, `sync`, `add`, `div` and `sqrt` in both precisions, VRAM reads, vsync, the player, DIP and sound registers, timing stability, and CPU identification.

---

*Original hardware measurements courtesy of MisterAddons.*
