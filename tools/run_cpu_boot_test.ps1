[CmdletBinding()]
param(
    [ValidateSet('kinst', 'kinst2')]
    [string]$Set = 'kinst',

    [ValidateRange(10, 1000000)]
    [int]$Instructions = 1000,

    [switch]$FullBoot,

    [switch]$T2LoopTest,

    [switch]$V1LoopTest,

    [switch]$A0A1LoopTest,

    [switch]$StopOnIo,

    [ValidateRange(0, 10000)]
    [int]$ReadDelay = 0,

    [ValidateRange(0, 10000)]
    [int]$WriteDelay = 0,

    [ValidateRange(0, 1)]
    [int]$Trace = 1,

    [ValidateRange(1000, 1000000000)]
    [int]$TimeoutNs = 20000000,

    [string]$ModelSimBin = 'C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem'
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$cpuSource = Join-Path $project 'rtl/cpu'
$simSource = Join-Path $project 'sim'
$buildRoot = Join-Path $simSource 'cpu_build'
$workLibrary = Join-Path $buildRoot 'work'
$memLibrary = Join-Path $buildRoot 'mem'

foreach ($tool in @('vlib.exe', 'vmap.exe', 'vcom.exe', 'vlog.exe', 'vsim.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool))) {
        throw "ModelSim tool not found: $(Join-Path $ModelSimBin $tool)"
    }
}

Push-Location $project
try {
    & (Join-Path $PSScriptRoot 'prepare_bootrom.ps1') -Set $Set

    New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $workLibrary '_info'))) {
        & (Join-Path $ModelSimBin 'vlib.exe') $workLibrary
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create ModelSim work library.' }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $memLibrary '_info'))) {
        & (Join-Path $ModelSimBin 'vlib.exe') $memLibrary
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create ModelSim mem library.' }
    }

    & (Join-Path $ModelSimBin 'vmap.exe') work $workLibrary
    if ($LASTEXITCODE -ne 0) { throw 'Failed to map ModelSim work library.' }
    & (Join-Path $ModelSimBin 'vmap.exe') mem $memLibrary
    if ($LASTEXITCODE -ne 0) { throw 'Failed to map ModelSim mem library.' }

    $memFiles = @('RamMLAB.vhd', 'SyncFifoFallThroughMLAB.vhd', 'dpram.vhd')
    foreach ($file in $memFiles) {
        & (Join-Path $ModelSimBin 'vcom.exe') -2008 -work mem (Join-Path $cpuSource $file)
        if ($LASTEXITCODE -ne 0) { throw "VHDL compile failed: $file (mem)" }
    }

    $workFiles = @(
        'functions.vhd', 'export.vhd', 'dpram.vhd', 'divider.vhd',
        'cpu_instrcache.vhd', 'cpu_datacache.vhd', 'cpu_TLB_instr.vhd',
        'cpu_TLB_data.vhd', 'cpu_mul.vhd', 'cpu_FPU_sqrt.vhd',
        'cpu_FPU.vhd', 'cpu_cop0.vhd', 'cpu.vhd'
    )
    foreach ($file in $workFiles) {
        & (Join-Path $ModelSimBin 'vcom.exe') -2008 -work work (Join-Path $cpuSource $file)
        if ($LASTEXITCODE -ne 0) { throw "VHDL compile failed: $file (work)" }
    }

    & (Join-Path $ModelSimBin 'vcom.exe') -2008 -work work (Join-Path $simSource 'ki_cpu_wrapper.vhd')
    if ($LASTEXITCODE -ne 0) { throw 'VHDL compile failed: ki_cpu_wrapper.vhd' }
    & (Join-Path $ModelSimBin 'vlog.exe') -sv -work work (Join-Path $simSource 'tb_ki_cpu_boot.sv')
    if ($LASTEXITCODE -ne 0) { throw 'SystemVerilog compile failed: tb_ki_cpu_boot.sv' }

    $bootHex = "sim/media/${Set}_boot.hex"
    $do = 'run -all; quit -f'
    $passMarker = Join-Path $simSource 'cpu_boot_pass.flag'
    if (Test-Path -LiteralPath $passMarker) {
        Remove-Item -LiteralPath $passMarker
    }
    $genericArg = "-gRETIRE_TARGET=$Instructions"
    $bootArg = "+BOOT_HEX=$bootHex"
    $setArg = if ($Set -eq 'kinst2') { '+KI2=1' } else { '+KI2=0' }
    $fastBootArg = if ($FullBoot) { '+FAST_BOOT=0' } else { '+FAST_BOOT=1' }
    $loopTestArg = if ($T2LoopTest) { '+T2_LOOP_TEST=1' } else { '+T2_LOOP_TEST=0' }
    $v1LoopTestArg = if ($V1LoopTest) { '+V1_LOOP_TEST=1' } else { '+V1_LOOP_TEST=0' }
    $a0a1LoopTestArg = if ($A0A1LoopTest) { '+A0A1_LOOP_TEST=1' } else { '+A0A1_LOOP_TEST=0' }
    $stopOnIoArg = if ($StopOnIo) { '+STOP_ON_IO=1' } else { '+STOP_ON_IO=0' }
    $readDelayArg = "+READ_DELAY=$ReadDelay"
    $writeDelayArg = "+WRITE_DELAY=$WriteDelay"
    $traceArg = "+TRACE=$Trace"
    $timeoutArg = "+TIMEOUT_NS=$TimeoutNs"
    $arguments = @(
        '-c', '-t', '1ps',
        '-L', 'altera_mf', '-L', 'lpm', '-L', 'sgate', '-L', 'altera', '-L', 'cyclonev',
        $genericArg, $bootArg, $setArg, $fastBootArg, $loopTestArg,
        $v1LoopTestArg, $a0a1LoopTestArg,
        $stopOnIoArg,
        $readDelayArg, $writeDelayArg, $traceArg, $timeoutArg,
        'work.tb_ki_cpu_boot', '-do', $do
    )
    & (Join-Path $ModelSimBin 'vsim.exe') $arguments
    if ($LASTEXITCODE -ne 0) { throw 'KI CPU boot simulation failed.' }
    foreach ($attempt in 1..20) {
        if (Test-Path -LiteralPath $passMarker) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $passMarker)) {
        throw 'KI CPU boot simulation ended without its pass marker. Inspect sim/cpu_boot_trace.log.'
    }

    $passText = Get-Content -LiteralPath $passMarker
    if (-not $T2LoopTest -and -not $V1LoopTest -and -not $A0A1LoopTest -and -not $StopOnIo -and
        $Set -eq 'kinst' -and $Instructions -ge 310 -and
        $passText -notmatch 'self_test=1') {
        throw 'KI CPU/RAM self-test checkpoint was not reached successfully.'
    }
    Write-Host $passText
    Write-Host "CPU trace: $(Join-Path $simSource 'cpu_boot_trace.log')"
    Write-Host "Bus trace: $(Join-Path $simSource 'cpu_bus_trace.log')"
} finally {
    Pop-Location
}
