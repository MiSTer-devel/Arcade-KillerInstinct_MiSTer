[CmdletBinding()]
param(
    [ValidateSet('kinst', 'kinst2')]
    [string]$Set = 'kinst'
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$workspace = Split-Path -Parent $project
$zipPath = Join-Path $workspace "games/$Set.zip"
$outputDir = Join-Path $project 'sim/media'

$metadata = if ($Set -eq 'kinst') {
    @{ Name = 'ki-l15d.u98'; Crc = [uint32]0x7b65ca3d }
} else {
    @{ Name = 'ki2-l14.u98'; Crc = [uint32]0x27d0285e }
}

if (-not (Test-Path -LiteralPath $zipPath)) {
    throw "Missing MAME ROM set: $zipPath"
}

if (-not ('KiCrc32' -as [type])) {
    Add-Type -TypeDefinition @'
public static class KiCrc32
{
    public static uint Compute(byte[] data)
    {
        uint crc = 0xffffffffu;
        foreach (byte value in data) {
            crc ^= value;
            for (int bit = 0; bit < 8; bit++)
                crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320u : 0u);
        }
        return ~crc;
    }
}
'@
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entry = $archive.GetEntry($metadata.Name)
    if ($null -eq $entry) {
        throw "ROM set is missing $($metadata.Name)"
    }

    $memory = [System.IO.MemoryStream]::new()
    try {
        $stream = $entry.Open()
        try { $stream.CopyTo($memory) } finally { $stream.Dispose() }
        [byte[]]$bytes = $memory.ToArray()
    } finally {
        $memory.Dispose()
    }
} finally {
    $archive.Dispose()
}

if ($bytes.Length -ne 524288) {
    throw "Unexpected boot ROM size $($bytes.Length); expected 524288 bytes."
}

$actualCrc = [KiCrc32]::Compute($bytes)
if ($actualCrc -ne $metadata.Crc) {
    throw ('Boot ROM CRC mismatch: got {0:x8}, expected {1:x8}.' -f $actualCrc, $metadata.Crc)
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$binaryPath = Join-Path $outputDir "${Set}_boot.bin"
$hexPath = Join-Path $outputDir "${Set}_boot.hex"
[System.IO.File]::WriteAllBytes($binaryPath, $bytes)

$writer = [System.IO.StreamWriter]::new($hexPath, $false, [System.Text.Encoding]::ASCII)
try {
    foreach ($value in $bytes) { $writer.WriteLine('{0:x2}', $value) }
} finally {
    $writer.Dispose()
}

Write-Host ('Prepared {0}: {1} bytes, CRC {2:x8}' -f $metadata.Name, $bytes.Length, $actualCrc)
Write-Host "Simulation hex: $hexPath"
