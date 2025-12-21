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
# Set window icon if available for a consistent branded look.
    try {
        $iconPath = Join-Path $ToolDirectory 'icon.ico'
        if (Test-Path -LiteralPath $iconPath) {
            $uri = New-Object System.Uri($iconPath, [System.UriKind]::Absolute)
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit()
            $bi.UriSource = $uri
            $bi.EndInit()
            $Window.Icon = $bi
            # Also set taskbar info to ensure the taskbar uses our icon instead of PowerShell's.
            $taskInfo = New-Object System.Windows.Shell.TaskbarItemInfo
            $taskInfo.Description = "3C-FD Tool"
            $Window.TaskbarItemInfo = $taskInfo
        }
    } catch {
        # ignore icon load failures
    }

# Load patcher functions (dot-source) without executing main logic
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
    $sections = @{
        Warnings   = New-Object System.Collections.Generic.List[string]
        SystemInfo = New-Object System.Collections.Generic.List[string]
        IniOptions = New-Object System.Collections.Generic.List[string]
        Conflicts  = New-Object System.Collections.Generic.List[string]
        LargeTxi   = New-Object System.Collections.Generic.List[string]
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
        if ($cpu) { $sections.SystemInfo.Add("CPU: $($cpu.Name)") }
    } catch {
        $sections.SystemInfo.Add("CPU: <unavailable>")
    }

    try {
        $gpus = Get-CimInstance Win32_VideoController
        if ($gpus) {
            $sections.SystemInfo.Add("GPUs:")
            foreach ($gpu in $gpus) {
                $name = $gpu.Name
                $ram = if ($gpu.AdapterRAM) { "{0:N0} MB" -f ([Math]::Round($gpu.AdapterRAM / 1MB)) } else { $null }
                $driver = $gpu.DriverVersion
                $extra = @()
                if ($ram) { $extra += $ram }
                if ($driver) { $extra += "Driver $driver" }
                $suffix = if ($extra.Count) { " (" + ($extra -join ", ") + ")" } else { "" }
                $sections.SystemInfo.Add("  - $name$suffix")
            }
        } else {
            $sections.SystemInfo.Add("GPUs: <none detected>")
        }
    } catch {
        $sections.SystemInfo.Add("GPUs: <unavailable>")
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        if ($os) {
            $caption = $os.Caption
            $version = $os.Version
            $build = $os.BuildNumber
            $sections.SystemInfo.Add("Windows: $caption (Version $version, Build $build)")
        }
    } catch {
        $sections.SystemInfo.Add("Windows: <unavailable>")
    }

    try {
        # Reliable monitor enumeration is tricky via Win32_DesktopMonitor; use Screen + EDID where available.
        $sections.SystemInfo.Add("Displays (Screens):")
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $screens = [System.Windows.Forms.Screen]::AllScreens
            if (-not $screens -or $screens.Count -eq 0) {
                $sections.SystemInfo.Add("  - <none detected>")
            } else {
                foreach ($s in $screens) {
                    $b = $s.Bounds
                    $isPrimary = if ($s.Primary) { " Primary" } else { "" }
                    $hz = $null
                    try { $hz = [DisplayUtil]::GetCurrentRefreshRate($s.DeviceName) } catch { $hz = $null }
                    $hzText = if ($hz) { " ${hz}Hz" } else { "" }
                    $sections.SystemInfo.Add("  - $($s.DeviceName): $($b.Width)x$($b.Height)${hzText} @ ($($b.X),$($b.Y))$isPrimary")
                }
            }
        } catch {
            $sections.SystemInfo.Add("  - <unavailable: $($_.Exception.Message)>")
        }
    } catch {
        $sections.SystemInfo.Add("Monitors: <unavailable>")
    }

    try {
        $sigPath = Join-Path $ToolDirectory 'version-signatures.json'
        if (Test-Path -LiteralPath $sigPath) {
            $sigData = Get-Content -LiteralPath $sigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $sigs = @($sigData.signatures | Where-Object { $_.game -eq $ResolvedGame })
            $exePath = Resolve-ExePath -GameId $ResolvedGame -BaseDirectory (Split-Path -Parent $FilePath)
            if ($exePath -and $sigs.Count -gt 0) {
                $exeBytes = [IO.File]::ReadAllBytes($exePath)
                $matched = $null
                $matchedName = $null
                foreach ($s in $sigs) {
                    $pat = Convert-HexPattern -Hex ([string]$s.hex)
                    $offset = [int]$s.offset
                    if ($exeBytes.Length -ge $offset + $pat.Bytes.Length) {
                        $slice = $exeBytes[$offset..($offset + $pat.Bytes.Length - 1)]
                        $eq = $true
                        for ($i = 0; $i -lt $pat.Bytes.Length; $i++) {
                            if ($pat.Bytes[$i] -ne $slice[$i]) { $eq = $false; break }
                        }
                        if ($eq) { $matched = $s.name; $matchedName = $s.name; break }
                    }
                }
                if ($matched) {
                    $sections.SystemInfo.Add("EXE signature: $matched")
                    if ($matchedName -eq "KOTOR 2 Steam (Aspyr)") {
                        # Check for Steam Workshop content when using Aspyr build
                        $steamRoot = $null
                        $exeDir = Split-Path -Parent $exePath
                        $cur = $exeDir
                        while ($cur -and $cur -ne [IO.Path]::GetPathRoot($cur)) {
                            if ([IO.Path]::GetFileName($cur) -ieq "steamapps") { $steamRoot = $cur; break }
                            $cur = Split-Path -Parent $cur
                        }
                        if ($steamRoot) {
                            $wsPath = Join-Path $steamRoot "workshop\\content\\208580"
                            if (Test-Path -LiteralPath $wsPath) {
                                $any = Get-ChildItem -LiteralPath $wsPath -Force -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
                                if ($any) {
                                    $sections.Warnings.Add("Warning: Steam Workshop files detected for KOTOR II (Aspyr).")
                                }
                            }
                        }
                    }
                } else {
                    $sections.SystemInfo.Add("EXE signature: <unknown>")
                }
            }
        }
    } catch {
        $sections.SystemInfo.Add("EXE signature: <unavailable: $($_.Exception.Message)>")
    }

    try {
        $iniName = Split-Path -Leaf $FilePath
        $sections.IniOptions.Add("INI ($iniName) Graphics Options:")

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
            $sections.IniOptions.Add("  - $($p.Label): $val")
        }
    } catch {
        $sections.IniOptions.Add("INI Graphics Options: <unavailable: $($_.Exception.Message)>")
    }

    try {
        $overridePath = Join-Path (Split-Path -Parent $FilePath) "Override"
        if (Test-Path -LiteralPath $overridePath) {
            try {
                # Warn if Override contains subfolders
                $hasFolders = Get-ChildItem -LiteralPath $overridePath -Directory -Force -ErrorAction Stop | Select-Object -First 1
                if (-not $hasFolders) {
                    $hasFolders = Get-ChildItem -LiteralPath $overridePath -Directory -Force -Recurse -ErrorAction Stop | Select-Object -First 1
                }
                if ($hasFolders) { $sections.Warnings.Add("Warning: Folders detected inside Override.") }

                # Gather potential conflict bases
                $tpc = @(Get-ChildItem -LiteralPath $overridePath -Recurse -File -Force -Filter *.tpc)
                $txi = @(Get-ChildItem -LiteralPath $overridePath -Recurse -File -Force -Filter *.txi)
                $tga = @(Get-ChildItem -LiteralPath $overridePath -Recurse -File -Force -Filter *.tga)

                $tpcSet = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($f in $tpc) { [void]$tpcSet.Add([IO.Path]::GetFileNameWithoutExtension($f.Name).ToLowerInvariant()) }
                $txiSet = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($f in $txi) { [void]$txiSet.Add([IO.Path]::GetFileNameWithoutExtension($f.Name).ToLowerInvariant()) }

                $conflictBases = $txiSet.Where({ $tpcSet.Contains($_) })
                $conflictFiles = New-Object System.Collections.Generic.List[string]
                foreach ($base in $conflictBases) {
                    $matched = @($tpc + $txi + $tga | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name).ToLowerInvariant() -eq $base })
                    foreach ($m in $matched) {
                        $rel = $m.FullName.Substring($overridePath.Length).TrimStart('\')
                        $conflictFiles.Add($rel)
                    }
                }
                if ($conflictBases.Count -gt 0) {
                    $sections.Warnings.Add("Warning: $($conflictBases.Count) TPC/TXI conflict detected.")
                }
                if ($conflictFiles.Count -gt 0) {
                    $sections.Conflicts.AddRange($conflictFiles)
                } else {
                    $sections.Conflicts.Add("No TPC/TXI conflicts detected.")
                }

                # List TXI files over 3KB
                $sizeLimitBytes = 3KB
                $largeTxi = @($txi | Where-Object { $_.Length -gt $sizeLimitBytes })
                if ($largeTxi.Count -gt 0) {
                    $sections.Warnings.Add("Warning: $($largeTxi.Count) TXI files exceed 3KB.")
                    foreach ($f in $largeTxi) {
                        $rel = $f.FullName.Substring($overridePath.Length).TrimStart('\')
                        $sections.LargeTxi.Add("$rel ($([math]::Round($f.Length / 1KB,2)) KB)")
                    }
                } else {
                    $sections.LargeTxi.Add("No TXI files exceed 3KB.")
                }
            } catch {
                $sections.Warnings.Add("Warning: Override scan unavailable.")
                $sections.Conflicts.Add("TPC/TXI conflicts: <unavailable>")
                $sections.LargeTxi.Add("TXI files over 3KB: <unavailable>")
            }
        } else {
            $sections.Warnings.Add("Warning: Override folder not found.")
            $sections.Conflicts.Add("Override folder files: <not found>")
            $sections.LargeTxi.Add("TXI files over 3KB: <not available>")
        }
    } catch {
        $sections.Warnings.Add("Warning: Override scan error: $($_.Exception.Message)")
        $sections.Conflicts.Add("Override folder files: <unavailable>")
        $sections.LargeTxi.Add("TXI files over 3KB: <unavailable>")
    }

    return [pscustomobject]@{
        Warnings   = ($sections.Warnings -join "`r`n")
        SystemInfo = ($sections.SystemInfo -join "`r`n")
        IniOptions = ($sections.IniOptions -join "`r`n")
        Conflicts  = ($sections.Conflicts -join "`r`n")
        LargeTxi   = ($sections.LargeTxi -join "`r`n")
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

    # Red warning text shown when needed
    $warningBlock = New-Object System.Windows.Controls.TextBlock
    $warningBlock.Foreground = "Red"
    $warningBlock.Margin = "0,0,0,8"
    $warningBlock.Visibility = "Collapsed"

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

    function New-InfoBox($labelText) {
        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Margin = "0,0,0,8"

        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $labelText
        $label.FontWeight = "Bold"
        $panel.Children.Add($label) | Out-Null

        $tb = New-Object System.Windows.Controls.TextBox
        $tb.IsReadOnly = $true
        $tb.AcceptsReturn = $true
        $tb.TextWrapping = "Wrap"
        $tb.VerticalScrollBarVisibility = "Auto"
        $tb.HorizontalScrollBarVisibility = "Auto"
        $tb.MinHeight = 120
        $tb.Text = "Select the Info tab and click Refresh to load details."
        $panel.Children.Add($tb) | Out-Null

        return $panel, $tb
    }

    $systemPanel, $systemBox = New-InfoBox -labelText "System info"
    $iniPanel, $iniBox = New-InfoBox -labelText "INI options"
    $conflictPanel, $conflictBox = New-InfoBox -labelText "TPC/TXI conflicts"
    $txiPanel, $txiBox = New-InfoBox -labelText "TXI files over 3KB"

    $infoTab.Tag = @{
        Loaded = $false
        Warnings = $warningBlock
        SystemBox = $systemBox
        IniBox = $iniBox
        ConflictBox = $conflictBox
        TxiBox = $txiBox
    }

    $refreshBtn.Tag = $infoTab
    $refreshBtn.Add_Click({
        param($s, $e)
        try {
            $tab = [System.Windows.Controls.TabItem]$s.Tag
            $tag = $tab.Tag
            $data = Get-SystemInfoSections
            $warnBlock = [System.Windows.Controls.TextBlock]$tag.Warnings
            if ([string]::IsNullOrWhiteSpace($data.Warnings)) {
                $warnBlock.Visibility = "Collapsed"
                $warnBlock.Text = ""
            } else {
                $warnBlock.Text = $data.Warnings
                $warnBlock.Visibility = "Visible"
            }
            ([System.Windows.Controls.TextBox]$tag.SystemBox).Text = $data.SystemInfo
            ([System.Windows.Controls.TextBox]$tag.IniBox).Text = $data.IniOptions
            ([System.Windows.Controls.TextBox]$tag.ConflictBox).Text = $data.Conflicts
            ([System.Windows.Controls.TextBox]$tag.TxiBox).Text = $data.LargeTxi
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
            $combined = @(
                "Warnings:",
                ([System.Windows.Controls.TextBlock]$tag.Warnings).Text,
                "",
                "System info:",
                ([System.Windows.Controls.TextBox]$tag.SystemBox).Text,
                "",
                "INI options:",
                ([System.Windows.Controls.TextBox]$tag.IniBox).Text,
                "",
                "TPC/TXI conflicts:",
                ([System.Windows.Controls.TextBox]$tag.ConflictBox).Text,
                "",
                "TXI files over 3KB:",
                ([System.Windows.Controls.TextBox]$tag.TxiBox).Text
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
            $outPath = Join-Path $baseDir 'filelist.txt'
            $items = Get-ChildItem -LiteralPath $baseDir -Recurse -Force -File
            $paths = $items | ForEach-Object { $_.FullName.Substring($baseDir.Length).TrimStart('\') }
            Set-Content -LiteralPath $outPath -Value ($paths -join "`r`n") -Encoding UTF8
            $StatusText.Text = "Indexed files to $(Split-Path -Leaf $outPath)"
        } catch {
            $StatusText.Text = "Index failed: $($_.Exception.Message)"
        }
    })

    $btnRow.Children.Add($refreshBtn) | Out-Null
    $btnRow.Children.Add($copyBtn) | Out-Null
    $btnRow.Children.Add($indexBtn) | Out-Null
    $infoPanel.Children.Add($warningBlock) | Out-Null
    $infoPanel.Children.Add($btnRow) | Out-Null
    $infoPanel.Children.Add($systemPanel) | Out-Null
    $infoPanel.Children.Add($iniPanel) | Out-Null
    $infoPanel.Children.Add($conflictPanel) | Out-Null
    $infoPanel.Children.Add($txiPanel) | Out-Null
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
                        $State[$tag.sec][$tag.key] = "1"
                    })
                    $cb.Add_Unchecked({
                        param($s,$e)
                        $tag = $s.Tag
                        $State[$tag.sec][$tag.key] = "0"
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
                        $State[$tag.sec][$tag.key] = [string]$v
                        $tag.tb.Text = [string]$v
                    })

                    $tb.Add_TextChanged({
                        param($s,$e)
                        $tag = $s.Tag
                        $v = 0
                        if (-not [int]::TryParse($s.Text, [ref]$v)) { return }
                        if ($v -lt $tag.min) { $v = $tag.min }
                        if ($v -gt $tag.max) { $v = $tag.max }
                        $State[$tag.sec][$tag.key] = [string]$v
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
                        $State[$tag.sec][$tag.key] = $s.Text
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
        Write-Ini -Data $State -Path $FilePath
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
