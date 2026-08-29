[CmdletBinding()]
param(
    # Wall-clock limit per testbench. These are RTL-only benches with no CPU
    # core to compile and normally finish in seconds; anything approaching this
    # is a simulation that is not terminating, not one that is merely slow.
    [ValidateRange(10, 3600)]
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$iverilog = Get-Command iverilog -ErrorAction SilentlyContinue
$vvp = Get-Command vvp -ErrorAction SilentlyContinue
$modelsim = 'C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem'
$vlib = Join-Path $modelsim 'vlib.exe'
$vlog = Join-Path $modelsim 'vlog.exe'
$vsim = Join-Path $modelsim 'vsim.exe'

$build = Join-Path $root 'sim/build'
New-Item -ItemType Directory -Force -Path $build | Out-Null

$common = @(
    (Join-Path $root 'rtl/ki_board_pkg.sv'),
    (Join-Path $root 'rtl/ki_board_io.sv'),
    (Join-Path $root 'rtl/ki_ata.sv'),
    (Join-Path $root 'rtl/ki_debug_screen.sv'),
    (Join-Path $root 'rtl/ki_framebuffer.sv'),
    (Join-Path $root 'rtl/ki_sdram_adapter.sv'),
    (Join-Path $root 'rtl/ki_sdram_burst.sv'),
    (Join-Path $root 'rtl/ki_sdram_bist.sv'),
    (Join-Path $root 'rtl/ki_fb_ram.sv'),
    (Join-Path $root 'rtl/ki_memory_bridge.sv'),
    (Join-Path $root 'rtl/ki_video_timing.sv'),
    (Join-Path $root 'sim/mt48lc16m16_ki.sv')
)

# tb_ki_memory_bridge proves the bridge against a behavioural SDRAM port;
# tb_ki_memory_bridge_sdram proves the same bridge against the real adapter,
# burst controller and device model, which is what catches a wrong assumption
# about the burst contract itself.
#
# tb_ki_framebuffer checks the framebuffer against a hand-driven memory port;
# tb_ki_framebuffer_fetch runs it from the real raster through the real memory
# path and checks the PIXELS, including that none of them are late. Those are
# different failures - a fetch can address correctly and still miss its
# scanline - and only the second one reproduces the ragged-fill symptom.
$tests = @('tb_ki_board_io', 'tb_ki_ata', 'tb_ki_debug_screen', 'tb_ki_framebuffer', 'tb_ki_framebuffer_fetch', 'tb_ki_io_align', 'tb_ki_memory_bridge', 'tb_ki_memory_bridge_sdram', 'tb_ki_sdram_burst', 'tb_ki_sdram_adapter_burst', 'tb_ki_sdram_bist', 'tb_ki_sdram_contention', 'tb_ki_sdram_bridge_contention', 'tb_ki_video_timing')
foreach ($test in $tests) {
    $testbench = Join-Path $root "sim/$test.sv"
    if ($iverilog -and $vvp) {
        $output = Join-Path $build "$test.vvp"
        & $iverilog.Source -g2012 -Wall -s $test -o $output @common $testbench
        if ($LASTEXITCODE -ne 0) {
            throw "Compilation failed for $test"
        }
        & $vvp.Source $output
        if ($LASTEXITCODE -ne 0) {
            throw "Simulation failed for $test"
        }
    } elseif ((Test-Path $vlib) -and (Test-Path $vlog) -and (Test-Path $vsim)) {
        $testBuild = Join-Path $build $test
        New-Item -ItemType Directory -Force -Path $testBuild | Out-Null
        Push-Location $testBuild
        try {
            if (-not (Test-Path work)) {
                & $vlib work
                if ($LASTEXITCODE -ne 0) {
                    throw "ModelSim library creation failed for $test"
                }
            }
            & $vlog -sv -work work @common $testbench
            if ($LASTEXITCODE -ne 0) {
                throw "ModelSim compilation failed for $test"
            }
            # -t 1ps: the SDRAM benches place the device pin clock at a
            # sub-nanosecond phase (16.75 ns). At the default 1 ns resolution
            # that quantises and the read window moves.
            #
            # Run under a wall-clock limit and retain the transcript on disk.
            # Use ProcessStartInfo directly: Windows PowerShell's Start-Process
            # rebuilds the inherited environment and fails when a parent has
            # both Path and PATH entries, before ModelSim can even start.
            $doFile = Join-Path $testBuild 'run.do'
            Set-Content -LiteralPath $doFile -Encoding ascii -Value @(
                'onerror {quit -code 1}',
                'run -all',
                'quit -code [coverage attribute -name TESTSTATUS -concise]'
            )
            $logFile = Join-Path $testBuild 'sim.log'
            $errFile = Join-Path $testBuild 'sim.err'
            $started = Get-Date
            # -L altera_mf_ver: the framebuffer store is an explicit altsyncram
            # instantiation (rtl/ki_fb_ram.sv), so every bench that pulls in
            # ki_memory_bridge needs the megafunction simulation models. Without
            # it the instance elaborates to a black box and the framebuffer
            # silently reads X.
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $vsim
            $startInfo.Arguments = "-c -quiet -t 1ps -L altera_mf_ver -do run.do work.$test"
            $startInfo.WorkingDirectory = $testBuild
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $startInfo
            if (-not $proc.Start()) {
                throw "ModelSim failed to start for $test"
            }
            $stdout = $proc.StandardOutput.ReadToEndAsync()
            $stderr = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                try { $proc.Kill() } catch { }
                $proc.WaitForExit()
                Start-Sleep -Milliseconds 250
                Set-Content -LiteralPath $logFile -Encoding ascii -Value $stdout.Result
                Set-Content -LiteralPath $errFile -Encoding ascii -Value $stderr.Result
                Write-Host "--- last output from $test before the timeout ---"
                if (Test-Path -LiteralPath $logFile) {
                    Get-Content -LiteralPath $logFile -Tail 30 |
                        ForEach-Object { Write-Output $_ }
                }
                throw ("$test did not finish within $TimeoutSeconds s. " +
                       "The simulation is not terminating - see $logFile")
            }
            Set-Content -LiteralPath $logFile -Encoding ascii -Value $stdout.Result
            Set-Content -LiteralPath $errFile -Encoding ascii -Value $stderr.Result
            $elapsed = ((Get-Date) - $started).TotalSeconds
            $simOutput = @()
            foreach ($f in @($logFile, $errFile)) {
                if (Test-Path -LiteralPath $f) {
                    $simOutput += Get-Content -LiteralPath $f
                }
            }
            $simOutput | ForEach-Object { Write-Output $_ }
            Write-Host ("{0}: {1:N1}s" -f $test, $elapsed)
            # The TESTSTATUS coverage attribute is not a reliable pass/fail
            # signal - it comes back non-zero even for a clean run - so the
            # gate is ModelSim's own error summary plus the transcript scan
            # below. A run that crashed or was killed has neither, so it still
            # fails here.
            if (-not ($simOutput -match '^# Errors: 0')) {
                throw ("ModelSim did not report a clean run for $test " +
                       "(exit code $($proc.ExitCode)) - see $logFile")
            }
            # A $fatal does NOT always come back as a non-zero exit code, so the
            # suite once reported "all tests passed" while tb_ki_memory_bridge
            # had fataled. Fail on the transcript text as well.
            if ($simOutput -match '\*\* (Fatal|Error)') {
                throw "ModelSim reported an error or fatal in $test"
            }
        } finally {
            Pop-Location
        }
    } else {
        throw 'No supported simulator found. Install Icarus or ModelSim Starter.'
    }
}

# cpu_datacache and cpu_instrcache are VHDL and need their own two-library
# builds, so they run through their own scripts rather than the vlog flow above.
& (Join-Path $PSScriptRoot 'check_ki_fb_cache_bypass.ps1')
if ($LASTEXITCODE -ne 0) { throw 'framebuffer cache-bypass integration check failed' }

& (Join-Path $PSScriptRoot 'run_datacache_test.ps1')
if ($LASTEXITCODE -ne 0) { throw 'datacache write-back test failed' }

& (Join-Path $PSScriptRoot 'run_instrcache_test.ps1')
if ($LASTEXITCODE -ne 0) { throw 'instruction cache test failed' }

# The pre-event execution trace, against the real CPU core. Same two-library
# VHDL build as the caches, but it needs no ROM or disk image - the program is
# written by the bench - so it belongs in the default suite. It is the positive
# control for the FMV instrumentation: a known RAM -> boot ROM jump must come
# back as the right eight decodes, the right opcodes and the right fetch-source
# tag, or nothing read off the hardware trace page can be trusted.
& (Join-Path $PSScriptRoot 'run_cpu_trace_test.ps1')
if ($LASTEXITCODE -ne 0) { throw 'CPU pre-event trace test failed' }

# The DCS audio board. It needs its own script rather than the vlog flow above
# because the benches build with +define+KI_DCS_SIMULATION, which selects the
# behavioural memories and the simulation checks.
# Covers the sparse Audio 2K ROM geometry, the host command mailbox, DDR
# response capture and the mono PCM path.
& (Join-Path $PSScriptRoot 'run_dcs_tests.ps1')
if ($LASTEXITCODE -ne 0) { throw 'DCS audio tests failed' }

Write-Host 'All Killer Instinct RTL unit tests passed.'
