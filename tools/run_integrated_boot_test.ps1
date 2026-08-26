# tb_ki_cpu_bridge_boot: the real CPU and the real bridge, against a
# burst-accurate behavioural SDRAM model, downloading the whole 512 KiB ROM
# through ioctl and running to the first KI board register access.
#
# EXPECT ABOUT 1 HOUR 12 MINUTES. Measured end to end: 14.49 ms of simulated
# time in 1:11:50 of wall clock, i.e. ~5 minutes per simulated millisecond. The
# 512 KiB ROM download is 14.42 ms of that - 1.802 ms per 64 KiB, dead linear -
# so the download IS the runtime and the boot itself is the last 0.07 ms.
# That is why this is not in run_tests.ps1.
#
# It is not silent any more - the bench prints DOWNLOAD: every 64 KiB and
# HEARTBEAT: every 100 us once the CPU is out of reset, and has progress
# watchdogs that dump the CPU, bridge and memory-model state within about a
# minute of wall clock if either phase stops advancing. If you see no output
# for several minutes at the start, that is elaboration, not a hang.
param(
    [string]$ModelSimBin = "C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$cpuSource = Join-Path $projectRoot "rtl\cpu"
$simSource = Join-Path $projectRoot "sim"
$buildDir = Join-Path $simSource "cpu_bridge_build"
$workLibrary = Join-Path $buildDir "work"
$memLibrary = Join-Path $buildDir "mem"

& (Join-Path $PSScriptRoot "prepare_bootrom.ps1")

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
    & $vcom -2008 -work work (Join-Path $projectRoot "rtl\ki_cpu_core.vhd")
    if ($LASTEXITCODE -ne 0) { throw "vcom failed for ki_cpu_core.vhd" }

    & $vlog -sv -work work "rtl\ki_board_pkg.sv"
    if ($LASTEXITCODE -ne 0) { throw "vlog failed for ki_board_pkg.sv" }
    & $vlog -sv -work work "rtl\ki_fb_ram.sv"
    if ($LASTEXITCODE -ne 0) { throw "vlog failed for ki_fb_ram.sv" }
    & $vlog -sv -work work "rtl\ki_memory_bridge.sv"
    if ($LASTEXITCODE -ne 0) { throw "vlog failed for ki_memory_bridge.sv" }
    & $vlog -sv -work work "sim\tb_ki_cpu_bridge_boot.sv"
    if ($LASTEXITCODE -ne 0) { throw "vlog failed for tb_ki_cpu_bridge_boot.sv" }

    & $vsim -c -t 1ps -L altera_mf -L altera_mf_ver -L lpm -L sgate -L altera -L cyclonev `
        work.tb_ki_cpu_bridge_boot -do "run -all; quit -f"
    if ($LASTEXITCODE -ne 0) { throw "integrated CPU/bridge boot simulation failed" }
}
finally {
    Pop-Location
}
