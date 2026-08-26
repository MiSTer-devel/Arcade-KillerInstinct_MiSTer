[CmdletBinding()]
param(
    [ValidateRange(10, 3600)]
    [int]$TimeoutSeconds = 420,

    [string]$ModelSimBin = 'C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem'
)

# The pre-event execution trace, against the real CPU core.
#
# This needs the two-library VHDL build the other CPU benches use, so it cannot
# run through the vlog-only flow in run_tests.ps1. Unlike run_cpu_boot_test.ps1
# it needs no ROM or disk image: the program is nineteen instructions written by
# the bench itself, which is what makes it safe to keep in the default suite.

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$cpuSource = Join-Path $project 'rtl/cpu'
$simSource = Join-Path $project 'sim'
$buildRoot = Join-Path $simSource 'cpu_trace_build'
$workLibrary = Join-Path $buildRoot 'work'
$memLibrary = Join-Path $buildRoot 'mem'

foreach ($tool in @('vlib.exe', 'vmap.exe', 'vcom.exe', 'vlog.exe', 'vsim.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool))) {
        throw "ModelSim tool not found: $(Join-Path $ModelSimBin $tool)"
    }
}

Push-Location $buildRoot -ErrorAction SilentlyContinue
Pop-Location -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
Push-Location $buildRoot
try {
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
    foreach ($bench in @('tb_ki_cpu_trace', 'tb_ki_cpu_reset_artifact', 'tb_ki_cpu_delayslot_irq', 'tb_ki_cpu_badvaddr')) {
        & (Join-Path $ModelSimBin 'vlog.exe') -sv -work work (Join-Path $simSource "$bench.sv")
        if ($LASTEXITCODE -ne 0) { throw "SystemVerilog compile failed: $bench.sv" }
    }

    $doFile = Join-Path $buildRoot 'run.do'
    Set-Content -LiteralPath $doFile -Encoding ascii -Value @(
        'onerror {quit -code 1}',
        'run -all',
        'quit -f'
    )
    foreach ($bench in @('tb_ki_cpu_trace', 'tb_ki_cpu_reset_artifact', 'tb_ki_cpu_delayslot_irq', 'tb_ki_cpu_badvaddr')) {
        $logFile = Join-Path $buildRoot "$bench.log"
        # Use ProcessStartInfo directly for the same reason run_tests.ps1 does:
        # Start-Process rebuilds the environment and fails when a parent has
        # both Path and PATH set.
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = Join-Path $ModelSimBin 'vsim.exe'
        $startInfo.Arguments = ('-c -quiet -t 1ps -L altera_mf -L lpm -L sgate ' +
                                "-L altera -L cyclonev -do run.do work.$bench")
        $startInfo.WorkingDirectory = $buildRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $startInfo
        if (-not $proc.Start()) { throw "ModelSim failed to start for $bench" }
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            $proc.WaitForExit()
            throw "$bench did not finish within $TimeoutSeconds s."
        }
        $simOutput = @($stdout.Result -split "`r?`n") + @($stderr.Result -split "`r?`n")
        Set-Content -LiteralPath $logFile -Encoding ascii -Value $simOutput
        $simOutput | ForEach-Object { Write-Output $_ }
        if (-not ($simOutput -match "${bench}: PASS")) {
            throw "$bench did not report PASS - see $logFile"
        }
        if ($simOutput -match '\*\* (Fatal|Error)') {
            throw "ModelSim reported an error or fatal in $bench - see $logFile"
        }
    }
} finally {
    Pop-Location
}
