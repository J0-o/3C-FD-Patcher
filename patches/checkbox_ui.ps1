Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object Windows.Forms.Form
$form.Text = 'Select Patches to Apply'
$form.Size = New-Object Drawing.Size(320, 250)
$form.StartPosition = 'CenterScreen'

# Optional icon
$iconPath = "$PSScriptRoot\myicon.ico"
if (Test-Path $iconPath) {
    $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconPath)
}

$checkboxes = @()

$features = @(
    'Fog and Reflections Fix',
    '4GB Patch',
    'Subtle Color Shift',
    'Music Volume During Dialogue Fix'
	'(Experimental) Borderless Window Mode'
)

for ($i = 0; $i -lt $features.Count; $i++) {
    $cb = New-Object Windows.Forms.CheckBox
    $cb.Text = $features[$i]
    $cb.Left = 20
    $cb.Top = 20 + ($i * 30)
    $cb.Width = 280
    $cb.Checked = $false
    $form.Controls.Add($cb)
    $checkboxes += $cb
}

$ok = New-Object Windows.Forms.Button
$ok.Text = 'OK'
$ok.Left = 110
$ok.Top = 180
$ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.AcceptButton = $ok
$form.Controls.Add($ok)

if ($form.ShowDialog() -eq 'OK') {
    for ($i = 0; $i -lt $checkboxes.Count; $i++) {
        if ($checkboxes[$i].Checked) {
            Write-Output "$($features[$i] -replace ' ', '_' -replace '[^a-zA-Z0-9_]', '')=1"
        }
    }
}
