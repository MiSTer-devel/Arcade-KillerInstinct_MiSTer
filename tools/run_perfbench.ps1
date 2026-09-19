[CmdletBinding()]
param(
    [string]$ModelSimBin = "C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem",
    # Independent filler instructions between the loads. The first entry is
    # the baseline every other row is compared against.
    [int[]]$PadSweep = @(0, 4, 8, 16)
)

# Microbenchmark: the real CPU against the real memory chain.
#
# Builds ki_cpu_core -> ki_memory_bridge -> ki_sdram_adapter -> ki_sdram_burst
# -> mt48lc16m16_ki and runs a hand-assembled program that walks memory one
# 32-byte line at a time. Reports CPU cycles per D-cache miss, split into the
# three fill phases.
#
# See sim/tb_ki_perfbench.sv for why this exists rather than measuring on
# hardware or in tb_ki_datacache_writeback, and docs/OPTIMIZATION-HISTORY.md
# for what it is meant to answer.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root 'sim/perfbench_build'
$workLib = Join-Path $build 'work'
$memLib = Join-Path $build 'mem'

$vlib = Join-Path $ModelSimBin 'vlib.exe'
$vmap = Join-Path $ModelSimBin 'vmap.exe'
$vcom = Join-Path $ModelSimBin 'vcom.exe'
$vlog = Join-Path $ModelSimBin 'vlog.exe'
$vsim = Join-Path $ModelSimBin 'vsim.exe'

New-Item -ItemType Directory -Force -Path $build | Out-Null
Push-Location $build
try {
    if (-not (Test-Path (Join-Path $workLib '_info'))) { & $vlib $workLib }
    if (-not (Test-Path (Join-Path $memLib '_info')))  { & $vlib $memLib }
    & $vmap work $workLib
    & $vmap mem $memLib

    foreach ($f in @('RamMLAB.vhd', 'SyncFifoFallThroughMLAB.vhd', 'dpram.vhd')) {
        & $vcom -quiet -2008 -work mem (Join-Path $root "rtl/cpu/$f")
        if ($LASTEXITCODE -ne 0) { throw "vcom failed for $f" }
    }

    # Same order as run_cpu_boot_test.ps1.
    $cpuFiles = @(
        'functions.vhd', 'export.vhd', 'dpram.vhd', 'divider.vhd',
        'cpu_instrcache.vhd', 'cpu_datacache.vhd', 'cpu_TLB_instr.vhd',
        'cpu_TLB_data.vhd', 'cpu_mul.vhd', 'cpu_FPU_sqrt.vhd',
        'cpu_FPU.vhd', 'cpu_cop0.vhd', 'cpu.vhd'
    )
    foreach ($f in $cpuFiles) {
        & $vcom -quiet -2008 -work work (Join-Path $root "rtl/cpu/$f")
        if ($LASTEXITCODE -ne 0) { throw "vcom failed for $f" }
    }
    & $vcom -quiet -2008 -work work (Join-Path $root 'rtl/ki_cpu_core.vhd')
    if ($LASTEXITCODE -ne 0) { throw 'vcom failed for ki_cpu_core' }

    # The memory chain, plus the device model the SDRAM controller drives.
    $svFiles = @(
        'rtl/ki_board_pkg.sv',
        'rtl/ki_memory_bridge.sv',
        'rtl/ki_sdram_adapter.sv',
        'rtl/ki_sdram_burst.sv',
        'rtl/ki_fb_ram.sv',
        'sim/mt48lc16m16_ki.sv',
        'sim/tb_ki_perfbench.sv'
    )
    & $vlog -sv -quiet -work work ($svFiles | ForEach-Object { Join-Path $root $_ })
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed' }

    'run -all' | Set-Content -Encoding ascii (Join-Path $build 'run.do')

    # Sweep the filler. pad=0 is the back-to-back walk; the larger values add
    # work that does NOT depend on the load, so the deltas say whether any of
    # the fill is being overlapped or the pipeline simply stalls through it.
    $summary = @()
    foreach ($pad in $PadSweep) {
        & $vsim -c -quiet -t 1ps -L altera_mf -do 'run.do' `
            +pad=$pad work.tb_ki_perfbench | Tee-Object -Variable simOutput
        if ($LASTEXITCODE -ne 0) { throw "vsim exited with $LASTEXITCODE" }

        # -notmatch on an ARRAY returns the non-matching elements, which is
        # truthy whenever any line differs - join first and test the text.
        $text = $simOutput -join "`n"
        if ($text -notmatch 'tb_ki_perfbench: PASS') {
            throw "perfbench did not report a clean run at pad=$pad"
        }
        $perMiss = [double]([regex]::Match($text,
            '([0-9.]+) CPU cycles per D-cache miss').Groups[1].Value)
        $perIter = [double]([regex]::Match($text,
            '([0-9.]+) CPU cycles per loop iteration').Groups[1].Value)
        $summary += [pscustomobject]@{
            Pad = $pad; PerMiss = $perMiss; PerIter = $perIter
        }
    }

    Write-Host ''
    Write-Host 'pad  cycles/miss  cycles/iter  delta/iter  cyc per filler'
    $base = $summary[0].PerIter
    foreach ($row in $summary) {
        $delta = $row.PerIter - $base
        # If any of the fill were overlapping the filler, the first few filler
        # instructions would be nearly free and this column would start well
        # below the CPU's plain ALU rate, then climb. A flat value from the
        # first row means the fill is fully exposed and nothing is hidden.
        $perFiller = if ($row.Pad -gt 0) { $delta / $row.Pad } else { 0 }
        '{0,3}  {1,11:N1}  {2,11:N1}  {3,10:N1}  {4,14:N2}' -f `
            $row.Pad, $row.PerMiss, $row.PerIter, $delta, $perFiller |
            Write-Host
    }
    Write-Host ''

    # Validate the stride detector at two points: a 32-byte walk is next-line
    # for every miss, a wider one for none. A detector that merely counted
    # misses would pass the first and fail the second.
    Write-Host 'stride  cycles/miss  next-line          repeated-delta'
    foreach ($stride in @(32, 4096)) {
        & $vsim -c -quiet -t 1ps -L altera_mf -do 'run.do' `
            +stride=$stride work.tb_ki_perfbench | Tee-Object -Variable strideOut
        if ($LASTEXITCODE -ne 0) { throw "vsim exited with $LASTEXITCODE" }
        $text = $strideOut -join "`n"
        if ($text -notmatch 'tb_ki_perfbench: PASS') {
            throw "perfbench did not report a clean run at stride=$stride"
        }
        $perMiss = [regex]::Match($text,
            '([0-9.]+) CPU cycles per D-cache miss').Groups[1].Value
        $nextLine = [regex]::Match($text,
            'next-line misses (.+)$', 'Multiline').Groups[1].Value.Trim()
        $repeated = [regex]::Match($text,
            'repeated-delta misses (.+)$', 'Multiline').Groups[1].Value.Trim()
        '{0,6}  {1,11}  {2,-18} {3}' -f $stride, $perMiss, $nextLine, $repeated |
            Write-Host
    }
    Write-Host ''

    # Dirty victims. Every walk above only loads, so every eviction is clean.
    # Hardware's worst frames are FMV decode, which writes: there the victim
    # is usually dirty, cpu_datacache writes it back BEFORE the fill, and
    # cpu.vhd's scheduler drains its four 64-bit beats ahead of the fill read,
    # each as its own bridge transaction. +dirty=1 pre-dirties the whole cache
    # at an aliasing address so every measured miss pays for that.
    Write-Host 'victims  cycles/miss      F1      F2      F3      WB'
    foreach ($d in @(0, 1)) {
        & $vsim -c -quiet -t 1ps -L altera_mf -do 'run.do' `
            +dirty=$d work.tb_ki_perfbench | Tee-Object -Variable dirtyOut
        if ($LASTEXITCODE -ne 0) { throw "vsim exited with $LASTEXITCODE" }
        $text = $dirtyOut -join "`n"
        if ($text -notmatch 'tb_ki_perfbench: PASS') {
            throw "perfbench did not report a clean run at dirty=$d"
        }
        $f = @('([0-9.]+) CPU cycles per D-cache miss',
               'F1 to first beat\s+([0-9.]+)',
               'F2 beats arriving\s+([0-9.]+)',
               'F3 waiting on done\s+([0-9.]+)',
               'WB writeback states\s+([0-9.]+)') |
             ForEach-Object { [regex]::Match($text, $_).Groups[1].Value }
        $label = if ($d -eq 1) { 'dirty' } else { 'clean' }
        '{0,-7}  {1,11}  {2,6}  {3,6}  {4,6}  {5,6}' -f `
            $label, $f[0], $f[1], $f[2], $f[3], $f[4] | Write-Host
    }
    Write-Host ''

    # The framebuffer line buffer, on against off. Every run above had it on;
    # this one elaborates the CPU without it. Correctness is the hash of every
    # framebuffer load in its two windows, in order, and the MIXED phase's
    # sum: both must equal the unbuffered run's exactly. See
    # docs/OPTIMIZATION-HISTORY.md, "Design: the framebuffer line buffer".
    Write-Host 'FB buffer  RMW cyc/iter  UF/load  hits  fetches  load hash         MIXED sum'
    $fbl = @{}
    foreach ($mode in @('on', 'off')) {
        # A typed array: an if-expression yielding ONE string would otherwise
        # reach vsim as that string's characters.
        [string[]]$extra = @(if ($mode -eq 'off') {
            '-g/tb_ki_perfbench/cpu/FBLINE_BUFFER=0'; '+fblbuf=0'
        } else { '+fblbuf=1' })
        & $vsim -c -quiet -t 1ps -L altera_mf -do 'run.do' $extra `
            work.tb_ki_perfbench | Tee-Object -Variable fblOut
        if ($LASTEXITCODE -ne 0) { throw "vsim exited with $LASTEXITCODE" }
        $text = $fblOut -join "`n"
        if ($text -notmatch 'tb_ki_perfbench: PASS') {
            throw "perfbench did not report a clean run with the line buffer $mode"
        }
        $rmw  = [regex]::Match($text, 'RMW: ([0-9.]+) CPU cycles per iteration, ([0-9.]+) UF cycles per load')
        $cnt  = [regex]::Match($text, 'RMW, 8-byte stride \(buffer\s+\w+\): \d+ loads, (\d+) hits, (\d+) fetches')
        $hash = [regex]::Match($text, 'FB load hash ([0-9a-f]+), MIXED sum ([0-9a-f]+)')
        $fbl[$mode] = $hash.Groups[1].Value + '/' + $hash.Groups[2].Value
        '{0,-9}  {1,12}  {2,7}  {3,4}  {4,7}  {5}  {6}' -f $mode,
            $rmw.Groups[1].Value, $rmw.Groups[2].Value, $cnt.Groups[1].Value,
            $cnt.Groups[2].Value, $hash.Groups[1].Value, $hash.Groups[2].Value | Write-Host
    }
    if ($fbl['on'] -ne $fbl['off']) {
        throw "the line buffer changed what framebuffer loads return: $($fbl['on']) against $($fbl['off'])"
    }
    Write-Host 'line buffer on and off return identical framebuffer loads'
    Write-Host ''

    # Skipped store-miss fills, on against off. Every run above had them on.
    # The bench checks each run's loads and its SDRAM read-back against the
    # program's own model, so both must pass on their own; this adds that the
    # two agree, and the store stream's cycles per line - the saving.
    Write-Host 'skip fill  stream cyc/line  cyc/miss  loads sum         SDRAM sum'
    $skp = @{}
    foreach ($mode in @('on', 'off')) {
        [string[]]$extra = @(if ($mode -eq 'off') {
            '-g/tb_ki_perfbench/cpu/DCACHE_SKIP_FILL=0'; '+skipfill=0'
        } else { '+skipfill=1' })
        & $vsim -c -quiet -t 1ps -L altera_mf -do 'run.do' $extra `
            work.tb_ki_perfbench | Tee-Object -Variable skpOut
        if ($LASTEXITCODE -ne 0) { throw "vsim exited with $LASTEXITCODE" }
        $text = $skpOut -join "`n"
        if ($text -notmatch 'tb_ki_perfbench: PASS') {
            throw "perfbench did not report a clean run with skipped fills $mode"
        }
        $stream = [regex]::Match($text, 'store stream: ([0-9.]+) CPU cycles per line written whole, ([0-9.]+) per miss')
        $sums = [regex]::Match($text, 'loads summed ([0-9a-f]+) \(expect [0-9a-f]+\), SDRAM read back ([0-9a-f]+)')
        $skp[$mode] = $sums.Groups[1].Value + '/' + $sums.Groups[2].Value
        '{0,-9}  {1,15}  {2,8}  {3}  {4}' -f $mode, $stream.Groups[1].Value,
            $stream.Groups[2].Value, $sums.Groups[1].Value, $sums.Groups[2].Value | Write-Host
    }
    if ($skp['on'] -ne $skp['off']) {
        throw "skipping fills changed what the program sees: $($skp['on']) against $($skp['off'])"
    }
    Write-Host 'skipped fills on and off return identical loads and leave identical SDRAM'
    Write-Host ''
}
finally {
    Pop-Location
}
