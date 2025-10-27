param (
    [string]$ExePath,
    [string]$PatchFile
)

Add-Type -AssemblyName System.IO.Compression.FileSystem

$exe = Resolve-Path $ExePath
$offset = $null
$desc = $null
$bytesRaw = $null

# Parse patch file
Get-Content $PatchFile | ForEach-Object {
    if ($_ -match '^OFFSET=(.+)$') { $offset = $matches[1] }
    elseif ($_ -match '^DESC=(.+)$') { $desc = $matches[1] }
    elseif ($_ -match '^BYTES=(.+)$') { $bytesRaw = $matches[1] }
}

if (-not $offset -or -not $bytesRaw) {
    Write-Host "ERROR: Invalid patch file format." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "File: $(Split-Path $PatchFile -Leaf)"
Write-Host "Description: $desc"
Write-Host "Offset: $offset"

# Convert offset and bytes
$offsetVal = [int64]::Parse($offset.Replace('0x',''), 'HexNumber')
$bytes = for ($i = 0; $i -lt $bytesRaw.Length; $i += 2) {
    [Convert]::ToByte($bytesRaw.Substring($i, 2), 16)
}

# Apply patch
$fs = [IO.File]::Open($exe, 'Open', 'ReadWrite')
if ($offsetVal + $bytes.Length -gt $fs.Length) {
    Write-Host "ERROR: Patch exceeds file size. Skipping." -ForegroundColor Yellow
    $fs.Close()
    exit 1
}
$fs.Seek($offsetVal, 'Begin') > $null
$fs.Write($bytes, 0, $bytes.Length)
$fs.Close()

Write-Host "Patch applied successfully." -ForegroundColor Green
