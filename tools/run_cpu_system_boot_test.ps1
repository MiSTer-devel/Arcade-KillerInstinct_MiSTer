param(
    [string]$ModelSimBin = "C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem",
    # Stop shortly after the boot-ROM gate at 9FC0073C resolves instead of
    # running on to the disk-boot milestone, which takes hours of wall clock.
    [switch]$GateOnly,

    # Hold the scanout reader in reset for an uncontended-bus control run.
    [switch]$NoVideo
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$cpuSource = Join-Path $projectRoot "rtl\cpu"
$simSource = Join-Path $projectRoot "sim"
$buildDir = Join-Path $simSource "cpu_system_build"
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

    foreach ($file in @(
        "rtl\ki_board_pkg.sv",
        "rtl\ki_fb_ram.sv",
        "rtl\ki_memory_bridge.sv",
        "rtl\ki_board_io.sv",
        "rtl\ki_ata.sv",
        "rtl\ki_video_timing.sv",
        "rtl\ki_framebuffer.sv",
        # The real memory path, so the bench exercises the same chain as
        # hardware rather than a behavioural stand-in.
        "rtl/ki_sdram_adapter.sv",
        "rtl/ki_sdram_burst.sv",
        "sim\mt48lc16m16_ki.sv",
        "sim\tb_ki_cpu_system_boot.sv"
    )) {
        & $vlog -sv -work work $file
        if ($LASTEXITCODE -ne 0) { throw "vlog failed for $file" }
    }

    $plusargs = @()
    if ($GateOnly) { $plusargs += "+gate_only" }
    if ($NoVideo)  { $plusargs += "+no_video" }

    & $vsim -c -t 1ps -L altera_mf -L altera_mf_ver -L lpm -L sgate -L altera -L cyclonev `
        work.tb_ki_cpu_system_boot @plusargs -do "run -all; quit -f"
    if ($LASTEXITCODE -ne 0) { throw "full KI CPU/system boot simulation failed" }
}
finally {
    Pop-Location
}
