<#
.SYNOPSIS
  Simple PowerShell WPF UI to edit KOTOR/KOTOR2 INI settings.
.DESCRIPTION
  Loads an INI file, renders tabs for each section with checkboxes for booleans and textboxes for other values, and saves back.
.NOTES
  Requires Windows with .NET/WPF available. Run from this folder:
    powershell -ExecutionPolicy Bypass -File .\kotor2-config-ui.ps1 -FilePath .\swkotor2.ini
#>

[CmdletBinding()]
param(
    [string]$FilePath,
    [ValidateSet('auto', 'kotor', 'kotor2')]
    [string]$Game = 'auto'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Path/INI helpers ---
function Assert-File {
    param([string]$Path, [switch]$Writable)
    if (-not $Path) { throw "File path required." }
    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }
    if ($Writable -and (Get-Item -LiteralPath $Path).Attributes.HasFlag([IO.FileAttributes]::ReadOnly)) {
        throw "File is read-only: $Path"
    }
}

function Read-Ini {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $lines = $raw -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
    $data = [ordered]@{}
    $current = $null
    foreach ($line in $lines) {
        if (-not $line -or $line.Trim().StartsWith(';')) { continue }
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $current = $matches[1]
            if (-not $data.Contains($current)) { $data[$current] = [ordered]@{} }
            continue
        }
        if ($line -match '^\s*([^=]+?)\s*=\s*(.*)$' -and $current) {
            $k = $matches[1].Trim()
            $v = $matches[2].Trim()
            $data[$current][$k] = $v
        }
    }
    return $data
}

# --- INI parsing/writing ---
function Write-Ini {
    param([System.Collections.IDictionary]$Data, [string]$Path)
    $sb = New-Object System.Text.StringBuilder
    foreach ($section in $Data.Keys) {
        $null = $sb.AppendLine("[$section]")
        foreach ($k in $Data[$section].Keys) {
            $v = $Data[$section][$k]
            $null = $sb.AppendLine("$k=$v")
        }
        $null = $sb.AppendLine()
    }
    Set-Content -LiteralPath $Path -Value $sb.ToString().TrimEnd() -Encoding UTF8
}

function Resolve-Game {
    param([string]$RequestedGame, [string]$BaseDirectory)

    if ($RequestedGame -and $RequestedGame -ne 'auto') { return $RequestedGame }

    $k2 = Join-Path $BaseDirectory 'swkotor2.exe'
    if (Test-Path -LiteralPath $k2) { return 'kotor2' }

    $k1 = Join-Path $BaseDirectory 'swkotor.exe'
    if (Test-Path -LiteralPath $k1) { return 'kotor' }

    throw "Unable to auto-detect game EXE in '$BaseDirectory'. Provide -Game kotor or -Game kotor2."
}

function Resolve-IniPath {
    param(
        [string]$ProvidedFilePath,
        [ValidateSet('auto', 'kotor', 'kotor2')][string]$RequestedGame,
        [string]$BaseDirectory
    )

    if ($ProvidedFilePath) {
        return (Resolve-Path -LiteralPath $ProvidedFilePath).Path
    }

    $resolvedGame = Resolve-Game -RequestedGame $RequestedGame -BaseDirectory $BaseDirectory
    $iniName = if ($resolvedGame -eq 'kotor2') { 'swkotor2.ini' } else { 'swkotor.ini' }
    $iniPath = Join-Path $BaseDirectory $iniName
    if (-not (Test-Path -LiteralPath $iniPath)) {
        throw "INI not found: $iniPath (provide -FilePath explicitly)"
    }
    return (Resolve-Path -LiteralPath $iniPath).Path
}

# --- Metadata loader ---
function Load-Metadata {
    param([ValidateSet('kotor', 'kotor2')][string]$ResolvedGame, [string]$BaseDirectory)
    $fileName = if ($ResolvedGame -eq 'kotor2') { 'metadata-kotor2.json' } else { 'metadata-kotor.json' }
    $metaPath = Join-Path $BaseDirectory $fileName
    if (-not (Test-Path -LiteralPath $metaPath)) { throw "Metadata file not found: $metaPath" }
    $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $meta.tabs) { throw "Metadata missing 'tabs': $metaPath" }
    return $meta
}

try {
    # Use the parent of this tool folder as the game directory.
    $ToolDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $baseForIni = Split-Path -Parent $ToolDirectory

    $FilePath = Resolve-IniPath -ProvidedFilePath $FilePath -RequestedGame $Game -BaseDirectory $baseForIni
    Assert-File -Path $FilePath -Writable
    $BaseDirectory = if ($baseForIni) { $baseForIni } else { Split-Path -Parent (Resolve-Path -LiteralPath $FilePath) }
    $ResolvedGame = Resolve-Game -RequestedGame $Game -BaseDirectory $BaseDirectory
    $Metadata = Load-Metadata -ResolvedGame $ResolvedGame -BaseDirectory $ToolDirectory
$State = Read-Ini -Path $FilePath
} catch {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        "Couldn't find or open the INI in the launch folder.`n`n$($_.Exception.Message)",
        "KOTOR Settings Editor",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
    return
}

Add-Type -AssemblyName PresentationFramework

# Track which INI keys originally existed
function New-KeyId {
    param([string]$Section, [string]$Key)
    return "$Section||$Key"
}

$OriginalSections = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$OriginalKeySet   = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$OriginalValues   = @{}
foreach ($sec in $State.Keys) {
    $null = $OriginalSections.Add($sec)
    foreach ($k in $State[$sec].Keys) {
        $null = $OriginalKeySet.Add((New-KeyId -Section $sec -Key $k))
        $OriginalValues[(New-KeyId -Section $sec -Key $k)] = [string]$State[$sec][$k]
    }
}

$ChangedKeySet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
function Update-ChangedFlag {
    param([string]$Section, [string]$Key, [string]$CurrentValue)
    $id = New-KeyId -Section $Section -Key $Key
    if ($OriginalKeySet.Contains($id)) {
        $orig = $OriginalValues[$id]
        if ($CurrentValue -ceq $orig) {
            $null = $ChangedKeySet.Remove($id)
        } else {
            $null = $ChangedKeySet.Add($id)
        }
    } else {
        if ([string]::IsNullOrEmpty($CurrentValue) -or $CurrentValue -ceq "0") {
            $null = $ChangedKeySet.Remove($id)
        } else {
            $null = $ChangedKeySet.Add($id)
        }
    }
}

function Set-StateValue {
    param([string]$Section, [string]$Key, [string]$Value)
    if (-not $State.Contains($Section)) { $State[$Section] = [ordered]@{} }
    $State[$Section][$Key] = $Value
    Update-ChangedFlag -Section $Section -Key $Key -CurrentValue $Value
}

# --- Base window markup ---
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="KOTOR Settings Editor" Height="700" Width="960"
        WindowStartupLocation="CenterScreen">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    <StackPanel Orientation="Horizontal" Margin="0,0,0,8" HorizontalAlignment="Left">
      <Button x:Name="SaveBtn" Content="Save ini" Padding="10,6" />
      <TextBlock x:Name="StatusText" Margin="12,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
    <TabControl x:Name="Tabs" Grid.Row="1"/>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$Window = [Windows.Markup.XamlReader]::Load($reader)
$Tabs   = $Window.FindName("Tabs")
$SaveBtn = $Window.FindName("SaveBtn")
$StatusText = $Window.FindName("StatusText")
$Window.Title = "3C-FD Tool ($ResolvedGame)"
# Set window icon if available
    try {
        $iconPath = Join-Path $ToolDirectory 'icon.ico'
        if (Test-Path -LiteralPath $iconPath) {
            $uri = New-Object System.Uri($iconPath, [System.UriKind]::Absolute)
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit()
            $bi.UriSource = $uri
            $bi.EndInit()
            $Window.Icon = $bi
            $taskInfo = New-Object System.Windows.Shell.TaskbarItemInfo
            $taskInfo.Description = "3C-FD Tool"
            $Window.TaskbarItemInfo = $taskInfo
        }
    } catch {
        # ignore icon load failures
    }

# Load patcher functions
$patcherPath = Join-Path $ToolDirectory 'patcher.ps1'
if (-not (Test-Path -LiteralPath $patcherPath)) {
    throw "patcher.ps1 not found in $ToolDirectory"
}
. $patcherPath

# --- Patch tab rendering ---
function Resolve-ExePath {
    param([ValidateSet('kotor', 'kotor2')][string]$GameId, [string]$BaseDirectory)
    $exeName = if ($GameId -eq 'kotor2') { 'swkotor2.exe' } else { 'swkotor.exe' }
    $exePath = Join-Path $BaseDirectory $exeName
    if (-not (Test-Path -LiteralPath $exePath)) { return $null }
    return (Resolve-Path -LiteralPath $exePath).Path
}

function Render-Patches {
    param(
        [System.Windows.Controls.TabItem]$Tab,
        [string]$ResolvedGameId,
        [string]$IniPath
    )

    $tag = $Tab.Tag
    $list = [System.Windows.Controls.StackPanel]$tag.ListPanel
    $list.Children.Clear()

    $baseDir = Split-Path -Parent $IniPath
    $exePath = Resolve-ExePath -GameId $ResolvedGameId -BaseDirectory $baseDir
    if (-not $exePath) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = "No game EXE found in this folder."
        $list.Children.Add($tb) | Out-Null
        return
    }

    $exeBytes = [IO.File]::ReadAllBytes($exePath)
    $patches = @(Load-Patches -BaseDirectory $ToolDirectory)
    if ($patches.Count -eq 0) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = "No patch files found in .\\patches\\ (JSON)."
        $list.Children.Add($tb) | Out-Null
        return
    }

        foreach ($p in $patches) {
            $row = New-Object System.Windows.Controls.StackPanel
            $row.Margin = "0,0,0,10"

            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $p.Name
            $cb.Tag = $p
            $statusInfo = Analyze-PatchStatus -Patch $p -Bytes $exeBytes
            if ($statusInfo.Status -eq "Not found") { continue }
            $cb.IsEnabled = $statusInfo.ApplyEnabled
            $cb.IsChecked = $statusInfo.AlreadyApplied

            $desc = New-Object System.Windows.Controls.TextBlock
            $desc.Text = if ($p.Description) { "$($statusInfo.Status) - $($p.Description)" } else { "$($statusInfo.Status)" }
            $desc.Margin = "24,2,0,0"

            $row.Children.Add($cb) | Out-Null
            $row.Children.Add($desc) | Out-Null
            $list.Children.Add($row) | Out-Null
    }
}

# --- Info tab content builder ---
function Get-SystemInfoSections {
    $section = @{
        System    = New-Object System.Collections.Generic.List[string]
        Ini       = New-Object System.Collections.Generic.List[string]
        Conflicts = New-Object System.Collections.Generic.List[string]
        Workshop  = New-Object System.Collections.Generic.List[string]
    }

    if (-not ("DisplayUtil" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class DisplayUtil
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

    public static int? GetCurrentRefreshRate(string deviceName)
    {
        var mode = new DEVMODE();
        mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        const int ENUM_CURRENT_SETTINGS = -1;
        if (!EnumDisplaySettings(deviceName, ENUM_CURRENT_SETTINGS, ref mode))
        {
            return null;
        }
        if (mode.dmDisplayFrequency <= 1) return null;
        return mode.dmDisplayFrequency;
    }
}
"@ -ErrorAction SilentlyContinue
    }

    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        if ($cpu) { $section.System.Add("CPU: $($cpu.Name)") }
    } catch {
        $section.System.Add("CPU: <unavailable>")
    }

    try {
        $gpus = Get-CimInstance Win32_VideoController
        if ($gpus) {
            $section.System.Add("GPUs:")
            foreach ($gpu in $gpus) {
                $name = $gpu.Name
                $ram = if ($gpu.AdapterRAM) { "{0:N0} MB" -f ([Math]::Round($gpu.AdapterRAM / 1MB)) } else { $null }
                $driver = $gpu.DriverVersion
                $extra = @()
                if ($ram) { $extra += $ram }
                if ($driver) { $extra += "Driver $driver" }
                $suffix = if ($extra.Count) { " (" + ($extra -join ", ") + ")" } else { "" }
                $section.System.Add("  - $name$suffix")
            }
        } else {
            $section.System.Add("GPUs: <none detected>")
        }
    } catch {
        $section.System.Add("GPUs: <unavailable>")
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        if ($os) {
            $caption = $os.Caption
            $version = $os.Version
            $build = $os.BuildNumber
            $section.System.Add("Windows: $caption (Version $version, Build $build)")
        }
    } catch {
        $section.System.Add("Windows: <unavailable>")
    }

    try {
        # Reliable monitor enumeration is tricky via Win32_DesktopMonitor; use Screen + EDID where available.
        $section.System.Add("Displays (Screens):")
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $screens = [System.Windows.Forms.Screen]::AllScreens
            if (-not $screens -or $screens.Count -eq 0) {
                $section.System.Add("  - <none detected>")
            } else {
                foreach ($s in $screens) {
                    $b = $s.Bounds
                    $isPrimary = if ($s.Primary) { " Primary" } else { "" }
                    $hz = $null
                    try { $hz = [DisplayUtil]::GetCurrentRefreshRate($s.DeviceName) } catch { $hz = $null }
                    $hzText = if ($hz) { " ${hz}Hz" } else { "" }
                    $section.System.Add("  - $($s.DeviceName): $($b.Width)x$($b.Height)${hzText} @ ($($b.X),$($b.Y))$isPrimary")
                }
            }
        } catch {
            $section.System.Add("  - <unavailable: $($_.Exception.Message)>")
        }
    } catch {
        $section.System.Add("Monitors: <unavailable>")
    }

    try {
        $iniName = Split-Path -Leaf $FilePath
        $section.Ini.Add("INI ($iniName) Graphics Options:")

        function Get-IniValue {
            param([string]$Section, [string]$Key)
            if (-not $State) { return $null }
            if (-not $State.Contains($Section)) { return $null }
            if (-not $State[$Section].Contains($Key)) { return $null }
            $v = [string]$State[$Section][$Key]
            if ($v -eq '') { return $null }
            return $v
        }

        function Format-BoolIni {
            param([string]$Value)
            if ($null -eq $Value) { return "<missing>" }
            if ($Value -eq '1') { return "On (1)" }
            if ($Value -eq '0') { return "Off (0)" }
            return $Value
        }

        $graphicsSection = "Graphics Options"
        $pairs = @(
            @{ Label = "Width"; Key = "Width"; Type = "text" }
            @{ Label = "Height"; Key = "Height"; Type = "text" }
            @{ Label = "RefreshRate"; Key = "RefreshRate"; Type = "text" }
            @{ Label = "V-Sync"; Key = "V-Sync"; Type = "bool" }
            @{ Label = "Disable Vertex Buffer Objects"; Key = "Disable Vertex Buffer Objects"; Type = "bool" }
            @{ Label = "Allow Windowed Mode"; Key = "AllowWindowedMode"; Type = "bool" }
            @{ Label = "FullScreen"; Key = "FullScreen"; Type = "bool" }
            @{ Label = "Frame Buffer"; Key = "Frame Buffer"; Type = "bool" }
            @{ Label = "Grass"; Key = "Grass"; Type = "bool" }
            @{ Label = "Soft Shadows"; Key = "Soft Shadows"; Type = "bool" }
        )

        foreach ($p in $pairs) {
            $raw = Get-IniValue -Section $graphicsSection -Key $p.Key
            $val = if ($p.Type -eq 'bool') { Format-BoolIni -Value $raw } else { if ($null -eq $raw) { "<missing>" } else { $raw } }
            $section.Ini.Add("  - $($p.Label): $val")
        }
    } catch {
        $section.Ini.Add("INI Graphics Options: <unavailable: $($_.Exception.Message)>")
    }

    try {
        $overridePath = Join-Path (Split-Path -Parent $FilePath) "Override"
        if (Test-Path -LiteralPath $overridePath) {
            $count = (Get-ChildItem -LiteralPath $overridePath -File -Recurse -Force | Measure-Object).Count
            $section.Conflicts.Add("Override folder files: $count")

            try {
                $tpc = Get-ChildItem -LiteralPath $overridePath -Recurse -File -Force -Filter *.tpc
                $txi = Get-ChildItem -LiteralPath $overridePath -Recurse -File -Force -Filter *.txi
                $tpcLookup = @{}
                foreach ($f in $tpc) {
                    $base = [IO.Path]::GetFileNameWithoutExtension($f.Name).ToLowerInvariant()
                    if (-not $tpcLookup.ContainsKey($base)) { $tpcLookup[$base] = $f }
                }
                $conflictEntries = New-Object System.Collections.Generic.List[string]
                foreach ($f in $txi) {
                    $base = [IO.Path]::GetFileNameWithoutExtension($f.Name).ToLowerInvariant()
                    if ($tpcLookup.ContainsKey($base)) {
                        $tpcFile = $tpcLookup[$base]
                        $txiRel = $f.FullName.Substring($overridePath.Length).TrimStart('\')
                        $tpcRel = $tpcFile.FullName.Substring($overridePath.Length).TrimStart('\')
                        $conflictEntries.Add("  - $base (txi: $txiRel, tpc: $tpcRel)")
                    }
                }
                $section.Conflicts.Add("TPC/TXI Conflicts: " + $conflictEntries.Count)
                if ($conflictEntries.Count -gt 0) {
                    $section.Conflicts.AddRange($conflictEntries)
                }
            } catch {
                $section.Conflicts.Add("TPC/TXI Conflicts: <unavailable>")
            }

            try {
                $largeTxi = @(Get-ChildItem -LiteralPath $overridePath -Recurse -File -Force -Filter *.txi | Where-Object { $_.Length -gt 3KB })
                $section.Conflicts.Add("TXI files over 3 KB: $($largeTxi.Count)")
                foreach ($f in $largeTxi | Sort-Object FullName) {
                    $rel = $f.FullName.Substring($overridePath.Length).TrimStart('\')
                    $sizeKb = [Math]::Round($f.Length / 1KB, 1)
                    $section.Conflicts.Add("  - $rel (${sizeKb} KB)")
                }
            } catch {
                $section.Conflicts.Add("TXI files over 3 KB: <unavailable: $($_.Exception.Message)>")
            }
        } else {
            $section.Conflicts.Add("Override folder files: <not found>")
            $section.Conflicts.Add("TXI files over 3 KB: Override folder not found")
        }
    } catch {
        $section.Conflicts.Add("Override folder files: <unavailable: $($_.Exception.Message)>")
        $section.Conflicts.Add("TXI files over 3 KB: <unavailable>")
    }

    try {
        $sigPath = Join-Path $ToolDirectory 'version-signatures.json'
        if (Test-Path -LiteralPath $sigPath) {
            $sigData = Get-Content -LiteralPath $sigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $sigs = @($sigData.signatures | Where-Object { $_.game -eq $ResolvedGame })
            $exePath = Resolve-ExePath -GameId $ResolvedGame -BaseDirectory (Split-Path -Parent $FilePath)
            $matchedName = $null
            if ($exePath -and $sigs.Count -gt 0) {
                $exeBytes = [IO.File]::ReadAllBytes($exePath)
                foreach ($s in $sigs) {
                    $pat = Convert-HexPattern -Hex ([string]$s.hex)
                    $offset = [int]$s.offset
                    if ($exeBytes.Length -ge $offset + $pat.Bytes.Length) {
                        $slice = $exeBytes[$offset..($offset + $pat.Bytes.Length - 1)]
                        $eq = $true
                        for ($i = 0; $i -lt $pat.Bytes.Length; $i++) {
                            if ($pat.Bytes[$i] -ne $slice[$i]) { $eq = $false; break }
                        }
                        if ($eq) { $matchedName = $s.name; break }
                    }
                }
                if ($matchedName) {
                    $section.System.Add("EXE signature: $matchedName")
                } else {
                    $section.System.Add("EXE signature: <unknown>")
                }
            }
        }
    } catch {
        $section.System.Add("EXE signature: <unavailable: $($_.Exception.Message)>")
    }

    # --- Steam Workshop detection (KOTOR 2 Steam build only) ---
    try {
        if ($ResolvedGame -eq 'kotor2' -and $matchedName -eq 'KOTOR 2 Steam') {
            $gameDir = Split-Path -Parent $FilePath            # .../steamapps/common/<game>
            $commonDir = Split-Path -Parent $gameDir            # .../steamapps/common
            $steamapps = Split-Path -Parent $commonDir          # .../steamapps

            if ($steamapps -and (Split-Path -Leaf $commonDir) -ieq 'common' -and (Split-Path -Leaf $steamapps) -ieq 'steamapps') {
                $workshopPath = Join-Path $steamapps 'workshop\\content\\208580'
                if (Test-Path -LiteralPath $workshopPath) {
                    $mods = @(Get-ChildItem -LiteralPath $workshopPath -Directory -Force)
                    if ($mods.Count -gt 0) {
                        $section.Workshop.Add("Steam Workshop mods under 208580: $($mods.Count)")
                        foreach ($mod in $mods) {
                            $section.Workshop.Add("  - $($mod.Name)")
                            $files = @(Get-ChildItem -LiteralPath $mod.FullName -File -Recurse -Force)
                            foreach ($f in $files | Sort-Object FullName) {
                                $rel = $f.FullName.Substring($mod.FullName.Length).TrimStart('\\')
                                $section.Workshop.Add("      * $rel")
                            }
                        }
                    } else {
                        $section.Workshop.Add("Steam Workshop (208580): no subdirectories found.")
                    }
                } else {
                    $section.Workshop.Add("Steam Workshop path not found: $workshopPath")
                }
            } else {
                $section.Workshop.Add("Steam Workshop scan skipped: game not under steamapps/common.")
            }
        } else {
            $section.Workshop.Add("Steam Workshop scan skipped (not KOTOR 2 Steam signature).")
        }
    } catch {
        $section.Workshop.Add("Steam Workshop scan failed: $($_.Exception.Message)")
    }

    return [pscustomobject]@{
        System    = $section.System
        Ini       = $section.Ini
        Conflicts = $section.Conflicts
        Workshop  = $section.Workshop
    }
}

# --- Control factory helpers ---
function Get-ControlType {
    param($Section, $Key, $Value)
    if ($Value -in @('0','1')) { return 'bool' }
    if ($Value -as [double]) { return 'number' }
    return 'text'
}

# --- Tab builder (Info, Patches, Settings) ---
function Build-Tabs {
    $Tabs.Items.Clear()

    $infoTab = New-Object System.Windows.Controls.TabItem
    $infoTab.Header = "Info"

    $infoScroll = New-Object System.Windows.Controls.ScrollViewer
    $infoScroll.VerticalScrollBarVisibility = "Auto"
    $infoPanel = New-Object System.Windows.Controls.StackPanel
    $infoPanel.Margin = "8"

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = "Horizontal"
    $btnRow.Margin = "0,0,0,8"

    $refreshBtn = New-Object System.Windows.Controls.Button
    $refreshBtn.Content = "Refresh"
    $refreshBtn.Padding = "10,6"
    $refreshBtn.Margin = "0,0,8,0"

    $copyBtn = New-Object System.Windows.Controls.Button
    $copyBtn.Content = "Copy to clipboard"
    $copyBtn.Padding = "10,6"

    $indexBtn = New-Object System.Windows.Controls.Button
    $indexBtn.Content = "Export File List"
    $indexBtn.Padding = "10,6"
    $indexBtn.Margin = "8,0,0,0"

    function New-SectionBox([string]$header) {
        $box = New-Object System.Windows.Controls.GroupBox
        $box.Header = $header
        $box.Margin = "0,0,0,8"
        $tb = New-Object System.Windows.Controls.TextBox
        $tb.IsReadOnly = $true
        $tb.AcceptsReturn = $true
        $tb.TextWrapping = "Wrap"
        $tb.VerticalScrollBarVisibility = "Auto"
        $tb.HorizontalScrollBarVisibility = "Auto"
        $tb.MinHeight = 120
        $tb.Text = "Select the Info tab and click Refresh to load details."
        $box.Content = $tb
        return @{ Box = $box; TextBox = $tb }
    }

    $systemBox = New-SectionBox -header "System Info"
    $iniBox = New-SectionBox -header "INI Options"
    $conflictBox = New-SectionBox -header "TPC/TXI Conflicts"
    $workshopBox = New-SectionBox -header "Steam Workshop (KOTOR 2 Steam)"

    $infoTab.Tag = @{
        Loaded = $false
        Sections = @{
            System = $systemBox.TextBox
            Ini = $iniBox.TextBox
            Conflicts = $conflictBox.TextBox
            Workshop = $workshopBox.TextBox
        }
    }

    $refreshBtn.Tag = $infoTab
    $refreshBtn.Add_Click({
        param($s, $e)
        try {
            $tab = [System.Windows.Controls.TabItem]$s.Tag
            $tag = $tab.Tag
            $sections = $tag.Sections
            $data = Get-SystemInfoSections
            $sections.System.Text    = ($data.System   -join "`r`n")
            $sections.Ini.Text       = ($data.Ini      -join "`r`n")
            $sections.Conflicts.Text = ($data.Conflicts -join "`r`n")
            $sections.Workshop.Text  = ($data.Workshop -join "`r`n")
            $tag.Loaded = $true
            $tab.Tag = $tag
            $StatusText.Text = "System info loaded."
        } catch {
            $StatusText.Text = "Info load failed: $($_.Exception.Message)"
        }
    })

    $copyBtn.Tag = $infoTab
    $copyBtn.Add_Click({
        param($s, $e)
        try {
            $tab = [System.Windows.Controls.TabItem]$s.Tag
            $tag = $tab.Tag
            $sections = $tag.Sections
            $combined = @(
                "=== System Info ==="
                $sections.System.Text
                ""
                "=== INI Options ==="
                $sections.Ini.Text
                ""
                "=== TPC/TXI Conflicts ==="
                $sections.Conflicts.Text
                ""
                "=== Steam Workshop ==="
                $sections.Workshop.Text
            ) -join "`r`n"
            [System.Windows.Clipboard]::SetText($combined)
            $StatusText.Text = "Copied system info to clipboard."
        } catch {
            $StatusText.Text = "Copy failed: $($_.Exception.Message)"
        }
    })

    $indexBtn.Tag = $infoTab
    $indexBtn.Add_Click({
        param($s, $e)
        try {
            $baseDir = Split-Path -Parent $FilePath
            $simplePath = Join-Path $baseDir 'filelist_simple.txt'
            $detailedPath = Join-Path $baseDir 'filelist_detailed.txt'
            $items = Get-ChildItem -LiteralPath $baseDir -Recurse -Force -File
            $entriesDetailed = $items | ForEach-Object {
                $relative = $_.FullName.Substring($baseDir.Length).TrimStart('\')
                $size = $_.Length
                $stamp = $_.LastWriteTimeUtc.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")
                "$relative,$size,$stamp"
            }
            $entriesSimple = $items | ForEach-Object {
                $_.FullName.Substring($baseDir.Length).TrimStart('\')
            }

            $linesDetailed = @()
            $linesDetailed += "Path,SizeBytes,LastModifiedUTC"
            $linesDetailed += $entriesDetailed
            Set-Content -LiteralPath $detailedPath -Value $linesDetailed -Encoding UTF8
            Set-Content -LiteralPath $simplePath -Value $entriesSimple -Encoding UTF8
            $StatusText.Text = "Indexed files to $(Split-Path -Leaf $simplePath) and $(Split-Path -Leaf $detailedPath)"
        } catch {
            $StatusText.Text = "Index failed: $($_.Exception.Message)"
        }
    })

    $btnRow.Children.Add($refreshBtn) | Out-Null
    $btnRow.Children.Add($copyBtn) | Out-Null
    $btnRow.Children.Add($indexBtn) | Out-Null
    $infoPanel.Children.Add($btnRow) | Out-Null
    $infoPanel.Children.Add($systemBox.Box) | Out-Null
    $infoPanel.Children.Add($iniBox.Box) | Out-Null
    $infoPanel.Children.Add($conflictBox.Box) | Out-Null
    $infoPanel.Children.Add($workshopBox.Box) | Out-Null
    $infoScroll.Content = $infoPanel
    $infoTab.Content = $infoScroll
    $Tabs.Items.Add($infoTab) | Out-Null

    $patchesTab = New-Object System.Windows.Controls.TabItem
    $patchesTab.Header = "Patches"
    $patchScroll = New-Object System.Windows.Controls.ScrollViewer
    $patchScroll.VerticalScrollBarVisibility = "Auto"
    $patchPanel = New-Object System.Windows.Controls.StackPanel
    $patchPanel.Margin = "8"

    $patchHeader = New-Object System.Windows.Controls.TextBlock
    $patchHeader.Text = "Loads patch files from .\\patches\\*.json and applies them to the game EXE in this folder."
    $patchHeader.Margin = "0,0,0,8"
    $patchPanel.Children.Add($patchHeader) | Out-Null

    $patchBtnRow = New-Object System.Windows.Controls.StackPanel
    $patchBtnRow.Orientation = "Horizontal"
    $patchBtnRow.Margin = "0,0,0,8"

    $patchRefreshBtn = New-Object System.Windows.Controls.Button
    $patchRefreshBtn.Content = "Load EXE"
    $patchRefreshBtn.Padding = "10,6"
    $patchRefreshBtn.Margin = "0,0,8,0"

    $patchApplyBtn = New-Object System.Windows.Controls.Button
    $patchApplyBtn.Content = "Apply"
    $patchApplyBtn.Padding = "10,6"

    $patchRestoreBtn = New-Object System.Windows.Controls.Button
    $patchRestoreBtn.Content = "Restore from backup"
    $patchRestoreBtn.Padding = "10,6"
    $patchRestoreBtn.Margin = "8,0,0,0"

    $patchBtnRow.Children.Add($patchRefreshBtn) | Out-Null
    $patchBtnRow.Children.Add($patchApplyBtn) | Out-Null
    $patchBtnRow.Children.Add($patchRestoreBtn) | Out-Null
    $patchPanel.Children.Add($patchBtnRow) | Out-Null

    $patchList = New-Object System.Windows.Controls.StackPanel
    $patchPanel.Children.Add($patchList) | Out-Null

    $patchOutput = New-Object System.Windows.Controls.TextBox
    $patchOutput.IsReadOnly = $true
    $patchOutput.AcceptsReturn = $true
    $patchOutput.TextWrapping = "Wrap"
    $patchOutput.VerticalScrollBarVisibility = "Auto"
    $patchOutput.HorizontalScrollBarVisibility = "Auto"
    $patchOutput.MinHeight = 120
    $patchOutput.Margin = "0,8,0,0"
    $patchPanel.Children.Add($patchOutput) | Out-Null

    $patchesTab.Tag = @{
        ListPanel = $patchList
        Output = $patchOutput
    }

    $patchRefreshBtn.Tag = $patchesTab
    $patchRefreshBtn.Add_Click({
        param($s,$e)
        try {
            Render-Patches -Tab ([System.Windows.Controls.TabItem]$s.Tag) -ResolvedGameId $ResolvedGame -IniPath $FilePath
            $StatusText.Text = "Patches refreshed."
            $tag = ([System.Windows.Controls.TabItem]$s.Tag).Tag
            $outBox = [System.Windows.Controls.TextBox]$tag.Output
            $outBox.Text = "Loaded EXE and updated patch statuses."
        } catch {
            $StatusText.Text = "Patches refresh failed: $($_.Exception.Message)"
        }
    })

    $patchApplyBtn.Tag = $patchesTab
    $patchApplyBtn.Add_Click({
        param($s,$e)
        try {
            $tab = [System.Windows.Controls.TabItem]$s.Tag
            $tag = $tab.Tag
            $list = [System.Windows.Controls.StackPanel]$tag.ListPanel

            $exePath = Resolve-ExePath -GameId $ResolvedGame -BaseDirectory (Split-Path -Parent $FilePath)
            if (-not $exePath) { throw "No game EXE found in this folder." }

            $baseBytes = [IO.File]::ReadAllBytes($exePath)
            $ops = New-Object System.Collections.Generic.List[object]
            foreach ($child in $list.Children) {
                if ($child -isnot [System.Windows.Controls.StackPanel]) { continue }
                if ($child.Children.Count -lt 1) { continue }
                $cb = $child.Children[0]
                if ($cb -isnot [System.Windows.Controls.CheckBox] -or -not $cb.Tag) { continue }
                $p = $cb.Tag
                $statusInfo = Analyze-PatchStatus -Patch $p -Bytes $baseBytes
                if ($statusInfo.AlreadyApplied -and $cb.IsChecked -eq $false) {
                    $ops.Add([pscustomobject]@{ Patch = $p; Reverse = $true })
                } elseif (-not $statusInfo.AlreadyApplied -and $statusInfo.ApplyEnabled -and $cb.IsChecked -eq $true) {
                    $ops.Add([pscustomobject]@{ Patch = $p; Reverse = $false })
                }
            }
            if ($ops.Count -eq 0) { throw "No patches selected to apply/undo." }

            $backup = "$exePath.bak"
            if (-not (Test-Path -LiteralPath $backup)) {
                Copy-Item -LiteralPath $exePath -Destination $backup -Force
            }

            $patchOps = @()
            foreach ($op in $ops) {
                $patchOps += (Prepare-PatchOps -Patch $op.Patch -Bytes $baseBytes -Reverse:$op.Reverse)
            }
            $bytes = [byte[]]$baseBytes.Clone()
            foreach ($po in $patchOps) {
                [Array]::Copy($po.Data, 0, $bytes, $po.Offset, $po.Data.Length)
            }
            [IO.File]::WriteAllBytes($exePath, $bytes)

            Render-Patches -Tab $tab -ResolvedGameId $ResolvedGame -IniPath $FilePath
            $StatusText.Text = "Applied patches (backup: $(Split-Path -Leaf $backup))."
            $outBox = [System.Windows.Controls.TextBox]$tab.Tag.Output
            $forward = ($ops | Where-Object { -not $_.Reverse } | ForEach-Object { $_.Patch.Name }) -join ", "
            $reversed = ($ops | Where-Object { $_.Reverse } | ForEach-Object { $_.Patch.Name }) -join ", "
            $lines = @()
            if ($forward) { $lines += "Applied: $forward" }
            if ($reversed) { $lines += "Undid: $reversed" }
            if (-not $lines) { $lines += "No changes." }
            $lines += "Backup: $(Split-Path -Leaf $backup)"
            $outBox.Text = ($lines -join "`r`n")
        } catch {
            $StatusText.Text = "Patch apply failed: $($_.Exception.Message)"
        }
    })

    $patchRestoreBtn.Tag = $patchesTab
    $patchRestoreBtn.Add_Click({
        param($s,$e)
        try {
            $tab = [System.Windows.Controls.TabItem]$s.Tag
            $tag = $tab.Tag
            $outBox = [System.Windows.Controls.TextBox]$tag.Output
            $exePath = Resolve-ExePath -GameId $ResolvedGame -BaseDirectory (Split-Path -Parent $FilePath)
            if (-not $exePath) { throw "No game EXE found in this folder." }
            $backup = "$exePath.bak"
            if (-not (Test-Path -LiteralPath $backup)) { throw "No backup found: $backup" }
            Copy-Item -LiteralPath $backup -Destination $exePath -Force
            Render-Patches -Tab $tab -ResolvedGameId $ResolvedGame -IniPath $FilePath
            $StatusText.Text = "Restored from backup."
            $outBox.Text = "Restored: $(Split-Path -Leaf $backup)"
        } catch {
            $StatusText.Text = "Restore failed: $($_.Exception.Message)"
        }
    })


    $patchesTab.Tag = $patchesTab.Tag
    $patchScroll.Content = $patchPanel
    $patchesTab.Content = $patchScroll
    $Tabs.Items.Add($patchesTab) | Out-Null

    foreach ($tabMeta in @($Metadata.tabs)) {
        $section = [string]$tabMeta.name
        if (-not $section) { continue }
        if (-not $State.Contains($section)) { $State[$section] = [ordered]@{} }
        $tab = New-Object System.Windows.Controls.TabItem
        $tab.Header = $section
        $scroll = New-Object System.Windows.Controls.ScrollViewer
        $scroll.VerticalScrollBarVisibility = "Auto"
        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Margin = "8"

        foreach ($keyMeta in @($tabMeta.keys)) {
            function Get-OptionalJsonPropertyValue {
                param([object]$Obj, [string]$Name)
                if ($null -eq $Obj) { return $null }
                $prop = $Obj.PSObject.Properties[$Name]
                if ($null -eq $prop) { return $null }
                return $prop.Value
            }

            $key = [string]$keyMeta.key
            if (-not $key) { continue }
            $type = [string]$keyMeta.type
            $min = Get-OptionalJsonPropertyValue -Obj $keyMeta -Name 'min'
            $max = Get-OptionalJsonPropertyValue -Obj $keyMeta -Name 'max'
            $step = Get-OptionalJsonPropertyValue -Obj $keyMeta -Name 'step'
            $tooltip = [string](Get-OptionalJsonPropertyValue -Obj $keyMeta -Name 'tooltip')

            $tooltipText = if ($tooltip) {
                $tooltip
            } else {
                $details = @("[$section]", "Key: $key")
                if ($type) { $details += "Type: $type" }
                if ($type -eq 'slider-int') {
                    if ($null -ne $min -and $null -ne $max) { $details += "Range: $min..$max" }
                    elseif ($null -ne $min) { $details += "Min: $min" }
                    elseif ($null -ne $max) { $details += "Max: $max" }
                    if ($null -ne $step) { $details += "Step: $step" }
                }
                $details -join "`r`n"
            }

            if (-not $State[$section].Contains($key)) { $State[$section][$key] = "" }
            $value = [string]$State[$section][$key]
            if (-not $type) { $type = Get-ControlType -Section $section -Key $key -Value $value }

            $group = New-Object System.Windows.Controls.StackPanel
            $group.Margin = "0,0,0,12"

            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = "$key"
            $label.FontWeight = "Bold"
            $label.Margin = "0,0,0,4"
            $label.ToolTip = $tooltipText
            $group.Children.Add($label)

            switch ($type) {
                'bool' {
                    if ($value -eq "") { $State[$section][$key] = "0"; $value = "0" }
                    $cb = New-Object System.Windows.Controls.CheckBox
                    $cb.IsChecked = ($value -ne '0')
                    $cb.Content = "Enabled"
                    $cb.ToolTip = $tooltipText
                    $cb.Tag = @{ sec = $section; key = $key }
                    $cb.Add_Checked({
                        param($s,$e)
                        $tag = $s.Tag
                        Set-StateValue -Section $tag.sec -Key $tag.key -Value "1"
                    })
                    $cb.Add_Unchecked({
                        param($s,$e)
                        $tag = $s.Tag
                        Set-StateValue -Section $tag.sec -Key $tag.key -Value "0"
                    })
                    $group.Children.Add($cb)
                }
                'slider-int' {
                    $defaultMin = 0
                    $defaultMax = 100
                    $minValue = if ($null -ne $min) { [int]$min } else { $defaultMin }
                    $maxValue = if ($null -ne $max) { [int]$max } else { $defaultMax }
                    $stepValue = if ($null -ne $step) { [int]$step } else { 1 }

                    $parsed = 0
                    if (-not [int]::TryParse($value, [ref]$parsed)) { $parsed = $minValue }
                    if ($parsed -lt $minValue) { $parsed = $minValue }
                    if ($parsed -gt $maxValue) { $parsed = $maxValue }
                    $State[$section][$key] = [string]$parsed

                    $dock = New-Object System.Windows.Controls.DockPanel
                    $dock.LastChildFill = $true
                    $dock.ToolTip = $tooltipText

                    $tb = New-Object System.Windows.Controls.TextBox
                    $tb.Width = 80
                    $tb.Margin = "0,0,8,0"
                    $tb.Text = [string]$parsed
                    $tb.ToolTip = $tooltipText
                    $tb.Tag = @{ sec = $section; key = $key; min = $minValue; max = $maxValue }
                    [System.Windows.Controls.DockPanel]::SetDock($tb, 'Right')

                    $slider = New-Object System.Windows.Controls.Slider
                    $slider.Minimum = $minValue
                    $slider.Maximum = $maxValue
                    $slider.SmallChange = $stepValue
                    $slider.LargeChange = [Math]::Max(1, ($maxValue - $minValue) / 10)
                    $slider.TickFrequency = $stepValue
                    $slider.IsSnapToTickEnabled = $true
                    $slider.Value = $parsed
                    $slider.ToolTip = $tooltipText
                    $slider.Tag = @{ sec = $section; key = $key; tb = $tb }

                    $slider.Add_ValueChanged({
                        param($s,$e)
                        $tag = $s.Tag
                        $v = [int][Math]::Round($s.Value)
                        Set-StateValue -Section $tag.sec -Key $tag.key -Value ([string]$v)
                        $tag.tb.Text = [string]$v
                    })

                    $tb.Add_TextChanged({
                        param($s,$e)
                        $tag = $s.Tag
                        $v = 0
                        if (-not [int]::TryParse($s.Text, [ref]$v)) { return }
                        if ($v -lt $tag.min) { $v = $tag.min }
                        if ($v -gt $tag.max) { $v = $tag.max }
                        Set-StateValue -Section $tag.sec -Key $tag.key -Value ([string]$v)
                    })

                    $dock.Children.Add($tb) | Out-Null
                    $dock.Children.Add($slider) | Out-Null
                    $group.Children.Add($dock)
                }
                default {
                    $tb = New-Object System.Windows.Controls.TextBox
                    $tb.Text = $value
                    $tb.Margin = "0,4,0,0"
                    $tb.ToolTip = $tooltipText
                    $tb.Tag = @{ sec = $section; key = $key }
                    $tb.Add_TextChanged({
                        param($s,$e)
                        $tag = $s.Tag
                        Set-StateValue -Section $tag.sec -Key $tag.key -Value $s.Text
                    })
                    $group.Children.Add($tb)
                }
            }
            $panel.Children.Add($group)
        }
        $scroll.Content = $panel
        $tab.Content = $scroll
        $Tabs.Items.Add($tab) | Out-Null
    }
    if ($Tabs.Items.Count -gt 0) { $Tabs.SelectedIndex = 0 }
}

# --- Save handler ---
function Save-Data {
    try {
        $toWrite = [ordered]@{}
        foreach ($sec in $State.Keys) {
            $secKeys = @()
            foreach ($k in $State[$sec].Keys) {
                $id = New-KeyId -Section $sec -Key $k
                if ($OriginalKeySet.Contains($id) -or $ChangedKeySet.Contains($id)) {
                    $secKeys += $k
                }
            }
            if ($secKeys.Count -eq 0) { continue }
            $toWrite[$sec] = [ordered]@{}
            foreach ($k in $secKeys) {
                $toWrite[$sec][$k] = $State[$sec][$k]
            }
        }

        Write-Ini -Data $toWrite -Path $FilePath
        $StatusText.Text = "Saved to $FilePath"
    } catch {
        $StatusText.Text = "Save failed: $($_.Exception.Message)"
    }
}

$SaveBtn.Add_Click({ Save-Data })

try {
    Build-Tabs
    $StatusText.Text = "Loaded: $(Split-Path -Leaf $FilePath)"
} catch {
    $StatusText.Text = "Load failed: $($_.Exception.Message)"
}
$Window.ShowDialog() | Out-Null
