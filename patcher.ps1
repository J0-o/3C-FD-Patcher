<#
.SYNOPSIS
  Simple binary patcher: search/replace hex blocks in a file.
.DESCRIPTION
  Applies one or more patch JSON files (from ./patches/*.json or a specific file) to a target binary.
  Each patch file contains one or more blocks with:
    - find:    hex string (supports "??" wildcard bytes)
    - replace: hex string (must be same length as find)

  "Already applied" detection:
    - If the "replace" pattern exists, that block is considered applied and skipped.
.EXAMPLE
  ./patcher.ps1 -File .\swkotor2.exe -Patch .\patches\myfix.json -Backup -DryRun
.EXAMPLE
  ./patcher.ps1 -File .\swkotor.exe -PatchesDir .\patches -ApplyAll -Backup
#>
# Core helpers for patch loading/searching/applying are defined below and can be dot-sourced by other scripts.

[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Find')]
    [string]$File,

    [Parameter(ParameterSetName = 'Apply')]
    [string]$Patch,

    [Parameter(ParameterSetName = 'Apply')]
    [string]$PatchesDir = ".\\patches",

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$ApplyAll,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$Backup,

    [Parameter(ParameterSetName = 'Find')]
    [string]$Find,

    [Parameter(ParameterSetName = 'Find')]
    [switch]$AllMatches
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Validation helpers ---
function Assert-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }
}

# --- Pattern parsing/search ---
function Convert-HexPattern {
    param([string]$Hex)
    $clean = ($Hex -replace '\s+', '').ToUpperInvariant()
    if (-not $clean) { throw "Hex string is empty." }
    if (($clean.Length % 2) -ne 0) { throw "Hex string must have an even number of characters." }

    $bytes = New-Object byte[] ($clean.Length / 2)
    $mask = New-Object bool[] ($clean.Length / 2)
    for ($i = 0; $i -lt $clean.Length; $i += 2) {
        $pair = $clean.Substring($i, 2)
        $idx = [int]($i / 2)
        if ($pair -eq '??') {
            $bytes[$idx] = 0
            $mask[$idx] = $false
        } else {
            $bytes[$idx] = [Convert]::ToByte($pair, 16)
            $mask[$idx] = $true
        }
    }
    return [pscustomobject]@{ Bytes = $bytes; Mask = $mask }
}

function Find-PatternIndex {
    param(
        [byte[]]$Data,
        [byte[]]$Pattern,
        [bool[]]$Mask,
        [int]$Start = 0
    )
    if ($Pattern.Length -eq 0) { return -1 }
    if ($Pattern.Length -ne $Mask.Length) { throw "Pattern/mask length mismatch." }
    if ($Data.Length -lt $Pattern.Length) { return -1 }
    if (-not ("MaskedFinder" -as [type])) {
        # Tiny C# helper compiled once for speed. Straight byte scan with an optional mask
        # (?? means wildcard). Much faster than looping in pure PowerShell.
        Add-Type -TypeDefinition @"
using System;

public static class MaskedFinder
{
    // Find first match of pat in data starting at 'start', honoring mask.
    // mask[j] == true => compare that byte; false => wildcard.
    public static int Find(byte[] data, byte[] pat, bool[] mask, int start)
    {
        if (pat.Length == 0 || pat.Length != mask.Length) return -1;
        int last = data.Length - pat.Length;
        for (int i = start; i <= last; i++)
        {
            bool ok = true;
            for (int j = 0; j < pat.Length; j++)
            {
                if (mask[j] && data[i + j] != pat[j]) { ok = false; break; }
            }
            if (ok) return i;
        }
        return -1;
    }
}
"@
    }
    return [MaskedFinder]::Find($Data, $Pattern, $Mask, $Start)
}

# --- Patch file loading ---
function Load-PatchFile {
    param([string]$Path)
    $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $blocks = @($obj.blocks)
    if (-not $blocks -or $blocks.Count -eq 0) { throw "No blocks." }
    return [pscustomobject]@{
        Id = if ($obj.id) { [string]$obj.id } else { [IO.Path]::GetFileNameWithoutExtension($Path) }
        Name = if ($obj.name) { [string]$obj.name } else { [IO.Path]::GetFileNameWithoutExtension($Path) }
        Description = if ($obj.description) { [string]$obj.description } else { "" }
        Blocks = $blocks
        Path = $Path
    }
}

function Load-Patches {
    param([string]$BaseDirectory)
    $dir = Join-Path $BaseDirectory 'patches'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $files = Get-ChildItem -LiteralPath $dir -File -Filter *.json | Sort-Object Name
    $patches = @()
    foreach ($f in $files) {
        try {
            $patches += Load-PatchFile -Path $f.FullName
        } catch {
            $patches += [pscustomobject]@{
                Id = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                Name = $f.Name
                Description = "Invalid patch file: $($_.Exception.Message)"
                Blocks = @()
                Path = $f.FullName
                Invalid = $true
            }
        }
    }
    return $patches
}

# --- Patch status analysis ---
function Analyze-PatchStatus {
    param([object]$Patch, [byte[]]$Bytes)
    if (($Patch.PSObject.Properties['Invalid'] -and $Patch.Invalid) -or -not $Patch.Blocks -or $Patch.Blocks.Count -eq 0) {
        return @{ Status = "Invalid"; ApplyEnabled = $false; AlreadyApplied = $false }
    }
    $allFind = $true
    $allReplace = $true
    foreach ($b in $Patch.Blocks) {
        $from = Convert-HexPattern -Hex ([string]$b.find)
        $to = Convert-HexPattern -Hex ([string]$b.replace)
        $fromIdx = Find-PatternIndex -Data $Bytes -Pattern $from.Bytes -Mask $from.Mask
        $toIdx = Find-PatternIndex -Data $Bytes -Pattern $to.Bytes -Mask $to.Mask
        if ($fromIdx -lt 0) { $allFind = $false }
        if ($toIdx -lt 0) { $allReplace = $false }
    }
    if ($allFind) { return @{ Status = "Found"; ApplyEnabled = $true; AlreadyApplied = $false } }
    if ($allReplace) { return @{ Status = "Applied"; ApplyEnabled = $true; AlreadyApplied = $true } }
    return @{ Status = "Not found"; ApplyEnabled = $false; AlreadyApplied = $false }
}

# --- Patch operation builders ---
function Prepare-PatchOps {
    param(
        [object]$Patch,
        [byte[]]$Bytes,
        [switch]$Reverse
    )
    $ops = @()
    foreach ($b in $Patch.Blocks) {
        $from = Convert-HexPattern -Hex ([string]$b.find)
        $to = Convert-HexPattern -Hex ([string]$b.replace)
        if ($from.Bytes.Length -ne $to.Bytes.Length) { throw "find/replace length mismatch in $($Patch.Name)." }

        if ($Reverse) {
            $temp = $from; $from = $to; $to = $temp
        }

        $targetIdx = Find-PatternIndex -Data $Bytes -Pattern $from.Bytes -Mask $from.Mask
        if ($targetIdx -lt 0) {
            throw "Pattern not found for a block in $($Patch.Name)."
        }
        $ops += [pscustomobject]@{
            Offset = $targetIdx
            Data   = $to.Bytes
            Patch  = $Patch
        }
    }
    return $ops
}

# --- Patch application helpers ---
function Apply-PatchOpsToFile {
    param(
        [string]$FilePath,
        [System.Collections.IEnumerable]$Ops,
        [switch]$Backup
    )
    if ($Backup) {
        $bak = "$FilePath.bak"
        if (-not (Test-Path -LiteralPath $bak)) {
            Copy-Item -LiteralPath $FilePath -Destination $bak -Force
        }
    }
    $fs = [IO.File]::Open($FilePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        foreach ($op in $Ops) {
            $fs.Seek($op.Offset, [IO.SeekOrigin]::Begin) | Out-Null
            $fs.Write($op.Data, 0, $op.Data.Length)
        }
    } finally {
        $fs.Dispose()
    }
}

function Apply-PatchToBytes {
    param(
        [object]$PatchObj,
        [byte[]]$Bytes,
        [switch]$WhatIfOnly
    )
    $changed = 0
    foreach ($b in $PatchObj.Blocks) {
        $from = Convert-HexPattern -Hex ([string]$b.find)
        $to = Convert-HexPattern -Hex ([string]$b.replace)
        if ($from.Bytes.Length -ne $to.Bytes.Length) { throw "find/replace length mismatch in $($PatchObj.Name)." }

        $toIdx = Find-PatternIndex -Data $Bytes -Pattern $to.Bytes -Mask $to.Mask
        if ($toIdx -ge 0) { continue } # already applied

        $fromIdx = Find-PatternIndex -Data $Bytes -Pattern $from.Bytes -Mask $from.Mask
        if ($fromIdx -lt 0) { throw "Search pattern not found for a block in $($PatchObj.Name)." }

        if (-not $WhatIfOnly) {
            [Array]::Copy($to.Bytes, 0, $Bytes, $fromIdx, $to.Bytes.Length)
        }
        $changed++
    }
    return [pscustomobject]@{ Bytes = $Bytes; BlocksChanged = $changed }
}

# --- CLI entry point (skips when dot-sourced) ---
if ($PSBoundParameters.Count -eq 0) { return } # allow dot-sourcing without running

Assert-File -Path $File
$File = (Resolve-Path -LiteralPath $File).Path
$bytes = [IO.File]::ReadAllBytes($File)

if ($PSCmdlet.ParameterSetName -eq 'Find') {
    if (-not $Find) { throw "Specify -Find <hex>." }
    $pat = Convert-HexPattern -Hex $Find
    $results = New-Object System.Collections.Generic.List[string]
    if ($AllMatches) {
        $idx = 0
        $last = $bytes.Length - $pat.Bytes.Length
        while ($idx -le $last) {
            $hit = Find-PatternIndex -Data ($bytes[$idx..($bytes.Length-1)]) -Pattern $pat.Bytes -Mask $pat.Mask
            if ($hit -lt 0) { break }
            $abs = $idx + $hit
            $results.Add(("FOUND at 0x{0:X}" -f $abs))
            $idx = $abs + 1
        }
    } else {
        $hit = Find-PatternIndex -Data $bytes -Pattern $pat.Bytes -Mask $pat.Mask
        if ($hit -ge 0) { $results.Add(("FOUND at 0x{0:X}" -f $hit)) }
    }
    if ($results.Count -eq 0) {
        Write-Host "NOT FOUND"
        exit 1
    } else {
        $results | ForEach-Object { Write-Host $_ }
        exit 0
    }
}

if (-not $File) { throw "Specify -File." }

$patchFiles = @()
if ($ApplyAll) {
    if (-not (Test-Path -LiteralPath $PatchesDir)) { throw "PatchesDir not found: $PatchesDir" }
    $patchFiles = Get-ChildItem -LiteralPath $PatchesDir -File -Filter *.json | Sort-Object Name | Select-Object -ExpandProperty FullName
} elseif ($Patch) {
    Assert-File -Path $Patch
    $patchFiles = @((Resolve-Path -LiteralPath $Patch).Path)
} else {
    throw "Specify -Patch <file> or -ApplyAll (with -PatchesDir)."
}

if ($patchFiles.Count -eq 0) { throw "No patch files found." }

$ops = @()
$totalChanged = 0
foreach ($pf in $patchFiles) {
    $p = Load-PatchFile -Path $pf
    $status = Analyze-PatchStatus -Patch $p -Bytes $bytes
    if ($status.AlreadyApplied) { continue }
    if (-not $status.ApplyEnabled) { continue }
    $ops += Prepare-PatchOps -Patch $p -Bytes $bytes -Reverse:$false
    $totalChanged += $p.Blocks.Count
    Write-Host ("{0}: {1} block(s) queued" -f (Split-Path -Leaf $pf), $p.Blocks.Count)
}

if ($DryRun) {
    Write-Host "Dry run: no changes written. Total blocks queued: $totalChanged"
    exit 0
}

if ($ops.Count -eq 0) {
    Write-Host "No applicable patches to apply."
    exit 0
}

Apply-PatchOpsToFile -FilePath $File -Ops $ops -Backup:$Backup
Write-Host "Patched: $File"
Write-Host "Total blocks changed: $totalChanged"
