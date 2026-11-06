# Killer Instinct Test ROM: MiSTer Core vs Original Hardware

This report compares results from the Killer Instinct memory, CPU and IDE test ROM on the MiSTer core and on an original board.

| Platform | Source | Test ROM build |
|---|---|---|
| **Original hardware** | Real KI board, A-19489 | Nov 1 2026 |
| **MiSTer core** | This core, current build | Nov 1 2026 |

**Original hardware measurements courtesy of [MisterAddons](https://github.com/misteraddons).**

Units: throughput is in MB/s (MB = 10^6 bytes). Timings are in CPU cycles, where 1 cycle = 2 × CP0 Count. Every value is the best of 3 runs.

---

## Summary

- **The core and the board both pass all 263 CPU tests** (2,748 checks, 0 failed). PRId, FIR and Config match the board exactly.
- **The heavy frame (KI2 barrel explosion) is within 1.2% of the board** (3,615 vs 3,660 kcycles), and the rendered checksum is identical.
- **Where the board uses its fastest memory (SRAM, VRAM), the core's reads are within 2% of the board.** Uncached SRAM reads are 98.0% of the board's speed. Cached reads are 99.5%.
- **The core is faster than the board in some places:** board DRAM (the core puts DRAM and SRAM on the same SDRAM), cached writes, IDE, `multu` and `divu`.
- **The one place the core is clearly slower is dependent-miss latency.** The pointer chase takes 26.10 cycles per load against the board's 24.21 (+1.89 cycles, +7.8%).

---

## 1. Memory, CPU & IDE speed test

### Memory throughput (MB/s)

| Region | Test | Original HW | MiSTer core | Core / HW |
|---|---|---:|---:|---:|
| SRAM `00000-2FFFF` | Uncached read | 63.97 | 62.72 | 98.0% |
| | Uncached write | 100.03 | 99.86 | 99.8% |
| | Cached read | 133.32 | 132.66 | 99.5% |
| | Cached write | 112.27 | 140.31 | 125.0% |
| VRAM0 `30000-57FFF` | Uncached read | 63.97 | 63.99 | 100.0% |
| | Uncached write | 100.03 | 133.38 | 133.3% |
| | Cached read | 133.32 | 133.28 | 100.0% |
| | Cached write | 112.27 | 261.16 | 232.6% |
| VRAM1 `58000-7FFFF` | Uncached read | 63.97 | 63.99 | 100.0% |
| | Uncached write | 100.03 | 133.38 | 133.3% |
| | Cached read | 133.32 | 133.28 | 100.0% |
| | Cached write | 112.27 | 261.16 | 232.6% |
| DRAM `8000000-87FFFFF` | Uncached read | 54.68 | 62.71 | 114.7% |
| | Uncached write | 56.79 | 99.86 | 175.8% |
| | Cached read | 113.47 | 132.66 | 116.9% |
| | Cached write | 69.02 | 140.31 | 203.3% |

On the board, SRAM and VRAM give identical results, and DRAM is slower than both. In the core, SRAM and DRAM give identical results because both live in the same SDRAM. As a result, the core's DRAM runs at SRAM speed, faster than the board's DRAM. Cached writes are faster than the board in every region.

### IDE

| Test | Original HW | MiSTer core | Core / HW |
|---|---:|---:|---:|
| LBA 0-127 (64 KiB), MB/s | 3.57 | 4.69 | 131.4% |

### CPU (cycles per operation, lower is faster)

| Test | Original HW | MiSTer core | Difference |
|---|---:|---:|---:|
| MIPS (ALU rate) | 96.96 | 96.96 | match |
| ALU `addu` | 1.03 | 1.03 | match |
| Load `lw` (D-cache hit) | 1.03 | 1.03 | match |
| Mul `multu` | 8.00 | 5.03 | core 2.97 faster |
| Div `divu` | 40.99 | 37.03 | core 3.96 faster |
| FPU `add.s` | 4.00 | 4.03 | +0.03 |
| Vsync (Hz) | 58.96 | 58.98 | +0.02 Hz |

---

## 2. SRAM uncached read sweep

The test reads an 8 KiB window at 16 KiB steps across all 512 KiB, looking for a speed step between regions.

| | Original HW | MiSTer core |
|---|---:|---:|
| Peak (MB/s) | 63.96 | 63.97 |
| Result | Flat, no step found | Flat, no step found |

On the board, every bar is the same height across SRAM, VRAM0 and VRAM1. On the core, the SRAM bars (`00000-2FFFF`) are slightly shorter than the VRAM bars, which matches the 62.72 vs 63.99 gap on page 1. That gap is too small for the test to call it a step.

---

## 3. SDRAM latency: dependent miss

Cycles per dependent load with a cold D-cache. Lower is faster.

| Test | Original HW | MiSTer core | Core − HW |
|---|---:|---:|---:|
| Chase, 128 KiB shuffled, 4096 nodes | 24.21 | 26.10 | +1.89 |
| Stride 32 | 24.20 | 26.07 | +1.87 |
| Stride 64 | 24.20 | 26.17 | +1.97 |
| Stride 128 | 24.21 | 26.17 | +1.96 |
| Stride 256 | 24.21 | 26.18 | +1.97 |
| Stride 512 | 24.20 | 26.17 | +1.97 |
| Stride 1 Ki | 24.21 | 26.10 | +1.89 |
| Stride 2 Ki | 24.20 | 26.17 | +1.97 |
| Stride 4 Ki | 24.21 | 26.17 | +1.96 |
| Stride 8 Ki | 24.20 | 26.14 | +1.94 |
| Bank pair, 1 KiB | 24.21 | 26.12 | +1.91 |
| Bank pair, bank01 | 24.18 | 26.21 | +2.03 |
| Bank ratio | 1.00 | 0.99 | |

Every latency case on the core is a steady ~1.9-2.0 cycles above the board. Neither platform shows a stride or bank effect. This is the core's largest remaining gap to the board.

### Loads hitting in the D-cache (cycles per load)

| Test | Original HW | MiSTer core |
|---|---:|---:|
| 1 destination | 1.03 | 1.03 |
| 8 destinations | 1.03 | 1.03 |
| Dependent chain | 2.01 | 2.01 |

The core matches the board exactly, including the board's one-cycle load-use delay.

### Cached stores (cycles per 32-byte line)

| Test | Original HW | MiSTer core |
|---|---:|---:|
| 4 of 4 words | 46.86 | 23.56 |
| 1 of 4 words | 45.36 | 13.79 |
| Ratio | 0.96 | 0.58 |

The core stores into the cache about twice as fast as the board. This matches the cached-write column on page 1.

---

## 4. Heavy frame: KI2 barrel explosion

This page replays the sprite blend of KI2's heaviest frame: 10 sprites, cold D-cache, best of 3.

| Sprite | Runs | Pixels | HW cyc/px | Core cyc/px | HW kcycles | Core kcycles | Core vs HW |
|---|---|---:|---:|---:|---:|---:|---:|
| 312×240 | right | 73,625 | 20.31 | 19.97 | 1,495 | 1,470 | −1.7% |
| 34×36 | left | 1,060 | 39.98 | 39.12 | 42 | 41 | −2.2% |
| 146×112 | left | 7,151 | 29.51 | 28.98 | 211 | 207 | −1.8% |
| 312×240 | left | 69,787 | 18.10 | 18.03 | 1,263 | 1,258 | −0.4% |
| 63×43 | right | 1,025 | 61.99 | 59.64 | 63 | 61 | −3.8% |
| 56×52 | right | 1,732 | 42.41 | 41.28 | 73 | 71 | −2.7% |
| 81×90 | left | 4,705 | 30.62 | 29.92 | 144 | 140 | −2.3% |
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

## 5. CPU tests (iris cpu-tests, R4600 expectations, little-endian)

| | Original HW | MiSTer core |
|---|---|---|
| CPU | R4600 | R4600 |
| PRId | `0x2020` | `0x2020` |
| FIR | `0x2020` | `0x2020` |
| Config | `0x000264B3` | `0x000264B3` |
| Checks | 2,748 passed, 0 failed | 2,748 passed, 0 failed |
| Tests | 263 run, 0 failed | 263 run, 0 failed |
| Result | Every test passed | Every test passed |

The core passes every test the board passes.

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
FPU_CVT_L_NARROW     => true
```

With these features disabled, the core fails 19 of the 263 tests (235 of 2,748 checks).

| | MiSTer core (release features disabled) |
|---|---|
| Checks | 2,513 passed, 235 failed |
| Tests | 263 run, 19 failed |

| Group | Failed tests | Count | Cause |
|---|---|---:|---|
| Trap instructions | `mem/load_then_trap`, `excep/teq_tne`, `excep/tlt_tge`, `excep/trap_immediate` | 4 | `NO_TRAP_INSTR` |
| User mode and CP0 usability | `excep/cp0_unusable_user`, `excep/cp0_usable_cu0`, `umode/syscall_first`, `umode/syscall_second`, `umode/break_then_syscall`, `umode/interrupt_then_sys`, `umode/load_miss_first`, `umode/load_miss_third`, `umode/fetch_miss_jump`, `umode/fetch_miss_entry`, `umode/kseg0_load_first`, `umode/kseg0_load_third`, `umode/unaligned_load_first`, `umode/dword_ops_with_ux` | 14 | `INSTR_KSEG_ONLY` (user-mode code fetches from KUSEG); `ADDR32_ONLY` for `dword_ops_with_ux` |
| FPU long conversion | `fpu/vec_cvt_from_l` | 1 | `FPU_CVT_L_NARROW` |

All 19 failures exercise features that KI does not use. None of them affect the game.

---

## Where the core differs from the board

| Area | Core vs board | Note |
|---|---|---|
| Dependent-miss latency | **1.9-2.0 cycles slower** (+7.8%) | Largest remaining gap |
| Uncached SRAM read | 1.25 MB/s slower (−2.0%) | VRAM matches exactly |
| Cached SRAM read | 0.66 MB/s slower (−0.5%) | VRAM matches exactly |
| `add.s` | +0.03 cycles | Effectively a match |
| DRAM (all four tests) | 15-76% faster | Core's DRAM shares the SRAM's SDRAM |
| Cached writes | 25-133% faster | Stores into the cache ~2× faster than the board |
| Uncached VRAM write | 33% faster | |
| IDE | 31% faster | |
| `multu` / `divu` | 2.97 / 3.96 cycles faster | |
| Heavy frame | 1.2% faster | Same checksum |

Everything else matches the board: ALU, cache-hit loads, the load-use delay, VRAM reads, vsync, CPU identification, and all 263 CPU tests.

---

*Original hardware measurements courtesy of MisterAddons.*
