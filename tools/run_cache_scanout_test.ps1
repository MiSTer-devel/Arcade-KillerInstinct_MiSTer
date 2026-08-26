# tb_ki_cache_scanout: the game's 256-store ATA PIO write block through the
# real CPU, the real bridge and the real ki_ata.
#
# Hardware says sd_wr has never been asserted, so a block has never reached
# its 256th halfword. The host cannot be at fault - the inner loop at
# 8802D9F4 has no exit branch and issues exactly 256 stores - so this measures
# where they go: counted leaving the CPU, counted arriving at the drive.
#
# Only 4 KiB is downloaded through the SDRAM model rather than the full
# 512 KiB, so this runs in minutes rather than the hour the full boot bench
# takes.
param(
    [string]$ModelSimBin = "C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$cpuSource = Join-Path $projectRoot "rtl\cpu"
$simSource = Join-Path $projectRoot "sim"
$buildDir = Join-Path $simSource "cache_scanout_build"
$workLibrary = Join-Path $buildDir "work"
$memLibrary = Join-Path $buildDir "mem"

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

Push-Location $projectRoot
try {
    $vcom = Join-Path $ModelSimBin "vcom.exe"
    $vlog = Join-Path $ModelSimBin "vlog.exe"
    $vsim = Join-Path $ModelSimBin "vsim.exe"
    $vlib = Join-Path $ModelSimBin "vlib.exe"
    $vmap = Join-Path $ModelSimBin "vmap.exe"

    if (-not (Test-Path -LiteralPath (Join-Path $workLibrary "_info"))) {
        & $vlib $workLibrary
        if ($LASTEXITCODE -ne 0) { throw "vlib failed for work" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $memLibrary "_info"))) {
        & $vlib $memLibrary
        if ($LASTEXITCODE -ne 0) { throw "vlib failed for mem" }
    }
    & $vmap work $workLibrary
    if ($LASTEXITCODE -ne 0) { throw "vmap failed for work" }
    & $vmap mem $memLibrary
    if ($LASTEXITCODE -ne 0) { throw "vmap failed for mem" }

    foreach ($file in @("RamMLAB.vhd", "SyncFifoFallThroughMLAB.vhd", "dpram.vhd")) {
        & $vcom -2008 -work mem (Join-Path $cpuSource $file)
        if ($LASTEXITCODE -ne 0) { throw "vcom failed for $file (mem)" }
    }

    foreach ($file in @(
        "functions.vhd", "export.vhd", "dpram.vhd", "divider.vhd",
        "cpu_instrcache.vhd", "cpu_datacache.vhd", "cpu_TLB_instr.vhd",
        "cpu_TLB_data.vhd", "cpu_mul.vhd", "cpu_FPU_sqrt.vhd",
        "cpu_FPU.vhd", "cpu_cop0.vhd", "cpu.vhd"
    )) {
        & $vcom -2008 -work work (Join-Path $cpuSource $file)
        if ($LASTEXITCODE -ne 0) { throw "vcom failed for $file (work)" }
    }
    & $vcom -2008 -work work (Join-Path $simSource "ki_cpu_wrapper.vhd")
    if ($LASTEXITCODE -ne 0) { throw "vcom failed for ki_cpu_wrapper.vhd" }

    foreach ($file in @(
        "rtl\ki_board_pkg.sv",
        "rtl\ki_fb_ram.sv",
        "rtl\ki_memory_bridge.sv",
        "rtl\ki_board_io.sv",
        "rtl\ki_ata.sv",
        "rtl/ki_sdram_adapter.sv",
        "rtl/ki_sdram_burst.sv",
        "sim\mt48lc16m16_ki.sv",
        "sim\tb_ki_cache_scanout.sv"
    )) {
        & $vlog -sv -work work $file
        if ($LASTEXITCODE -ne 0) { throw "vlog failed for $file" }
    }

    # NumericStdNoWarnings/StdArithNoWarnings: the CPU core reads uninitialised
    # registers out of reset and each one logs a metavalue warning. The first
    # run of this bench wrote an 88 MB transcript of them, and writing it was a
    # large part of the wall clock.
    & $vsim -c -t 1ps -L altera_mf -L altera_mf_ver -L lpm -L sgate -L altera -L cyclonev `
        work.tb_ki_cache_scanout `
        -do "set NumericStdNoWarnings 1; set StdArithNoWarnings 1; run -all; quit -f"
    if ($LASTEXITCODE -ne 0) { throw "cache scanout simulation failed" }
}
finally {
    Pop-Location
}
