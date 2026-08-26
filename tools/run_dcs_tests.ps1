[CmdletBinding()]
param(
    [ValidateRange(10, 3600)]
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

& (Join-Path $PSScriptRoot 'check_dcs_pm_clocking.ps1')
$modelsim = 'C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem'
$vlib = Join-Path $modelsim 'vlib.exe'
$vlog = Join-Path $modelsim 'vlog.exe'
$vsim = Join-Path $modelsim 'vsim.exe'

if (-not ((Test-Path $vlib) -and (Test-Path $vlog) -and (Test-Path $vsim))) {
    throw 'The DCS tests require ModelSim Starter from Quartus Lite 17.0.'
}

function Invoke-ModelSim {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Top,
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)]
        [string]$LogFile,
        [Parameter(Mandatory = $true)]
        [string]$ErrorFile
    )

    # Start-Process fails on some Windows PowerShell/.NET combinations when
    # the inherited environment contains both Path and PATH. Launching via
    # ProcessStartInfo avoids that PowerShell environment-dictionary bug while
    # retaining bounded execution and separate transcript files.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $vsim
    $startInfo.Arguments = "-c -quiet -t 1ps -L altera_mf -do run.do work.$Top"
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Unable to start ModelSim for $Top"
    }

    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        throw "$Top did not finish within $TimeoutSeconds seconds"
    }
    $stdout.Wait()
    $stderr.Wait()
    Set-Content -LiteralPath $LogFile -Encoding ascii -Value $stdout.Result
    Set-Content -LiteralPath $ErrorFile -Encoding ascii -Value $stderr.Result
    return $process.ExitCode
}

$build = Join-Path $root 'sim/build/dcs'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$tests = @(
    @{
        Name = 'tb_ki_dcs_rom_map'
        Sources = @(
            (Join-Path $root 'rtl/dcs/dcs_mem.sv'),
            (Join-Path $root 'sim/tb_ki_dcs_rom_map.sv')
        )
    },
    @{
        Name = 'tb_ki_dcs_audio'
        Sources = @(
            (Join-Path $root 'rtl/dcs/adsp2105.sv'),
            (Join-Path $root 'rtl/ki_dcs_audio.sv'),
            (Join-Path $root 'sim/tb_ki_dcs_audio.sv')
        )
    },
    @{
        Name = 'tb_dcs_pm_ram_primitive'
        Sources = @(
            (Join-Path $root 'sim/tb_dcs_pm_ram_primitive.sv')
        )
    }
)

foreach ($test in $tests) {
    $testBuild = Join-Path $build $test.Name
    New-Item -ItemType Directory -Force -Path $testBuild | Out-Null
    Push-Location $testBuild
    try {
        if (-not (Test-Path work)) {
            & $vlib work
            if ($LASTEXITCODE -ne 0) {
                throw "ModelSim library creation failed for $($test.Name)"
            }
        }

        & $vlog -sv "+define+KI_DCS_SIMULATION" "+incdir+$(Join-Path $root 'rtl/dcs')" -work work @($test.Sources)
        if ($LASTEXITCODE -ne 0) {
            throw "ModelSim compilation failed for $($test.Name)"
        }

        $doFile = Join-Path $testBuild 'run.do'
        Set-Content -LiteralPath $doFile -Encoding ascii -Value @(
            'onerror {quit -code 1}',
            'run -all',
            'quit -code [coverage attribute -name TESTSTATUS -concise]'
        )
        $logFile = Join-Path $testBuild 'sim.log'
        $errFile = Join-Path $testBuild 'sim.err'
        $exitCode = Invoke-ModelSim -Top $test.Name -WorkingDirectory $testBuild `
            -LogFile $logFile -ErrorFile $errFile

        $simOutput = @()
        foreach ($file in @($logFile, $errFile)) {
            if (Test-Path -LiteralPath $file) {
                $simOutput += Get-Content -LiteralPath $file
            }
        }
        $simOutput | ForEach-Object { Write-Output $_ }
        if (-not ($simOutput -match '^# Errors: 0')) {
            throw "ModelSim did not report a clean run for $($test.Name) (exit code $exitCode)"
        }
        if ($simOutput -match '\*\* (Fatal|Error)') {
            throw "ModelSim reported an error or fatal in $($test.Name)"
        }
    } finally {
        Pop-Location
    }
}

Write-Host 'All Killer Instinct DCS audio tests passed.'
