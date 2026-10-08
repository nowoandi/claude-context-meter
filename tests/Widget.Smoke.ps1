# Render the real XAML and row functions without launching tray, autostart, or updates.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ClaudeContextMeter.ps1'), [ref]$tokens, [ref]$errors)
$functions = @{}
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $functions[$node.Name] = $node.Extent.Text }
foreach ($name in @('T', 'New-Brush', 'Format-Tokens', 'New-SessionRow', 'New-InfoRow', 'Update-AgentLabels', 'Update-CodexUI', 'Set-ActiveAgent')) { Invoke-Expression $functions[$name] }
$strings = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$Strings' }, $true)
Invoke-Expression $strings.Extent.Text
$xaml = $ast.Find({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -like '<Window xmlns=*' }, $true).Value
$window = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($name in @('RowsPanel', 'HdrLbl', 'Lbl5', 'Lbl7', 'Sum5', 'Sum7', 'LoadNote', 'ClaudeTab', 'CodexTab')) {
    Set-Variable -Name $name -Value $window.FindName($name)
}
$script:Lang = 'ru'; $script:ActiveAgent = 'claude'; $script:State = @{}
$script:HeavyPending = $false; $ActiveMin = 180; $StaleMin = 30; $MaxRows = 6
$timer = [pscustomobject]@{ Interval = [TimeSpan]::Zero }
function Save-State {}
function Update-UI { if ($script:ActiveAgent -eq 'codex') { Update-CodexUI } }
function Get-CodexLimit($key) { if ($key -eq 'primary') { return 12 } else { return 37 } }
$script:CodexTitles = @{ demo = 'Разработка сайта'; unknown = 'Новый чат' }
$script:CodexCache = @{
    demo = @{ Id = 'demo'; IsAgent = $false; Context = 54552; Window = 258400; Model = 'gpt-6.1-sol'; Cwd = 'D:\Projects\Site'; File = [pscustomobject]@{ Exists = $true; LastWriteTime = Get-Date } }
    unknown = @{ Id = 'unknown'; IsAgent = $false; Context = 0; Window = 0; Model = ''; Cwd = ''; File = [pscustomobject]@{ Exists = $true; LastWriteTime = (Get-Date).AddMinutes(-40) } }
}
$ClaudeTab.Add_Checked({ Set-ActiveAgent claude })
$CodexTab.Add_Checked({ Set-ActiveAgent codex })
Update-AgentLabels
$CodexTab.IsChecked = $true
if ($script:ActiveAgent -ne 'codex' -or $RowsPanel.Children.Count -ne 2 -or $Sum5.Text -ne '12%') { throw 'Tab event or Codex rendering failed' }
if ($HdrLbl.Text -ne 'Недавние чаты Codex') { throw 'Codex header not localized' }
$surface = $window.Content
$surface.Measure([Windows.Size]::new(1000, 1000))
$surface.Arrange([Windows.Rect]::new(0, 0, $surface.DesiredSize.Width, $surface.DesiredSize.Height))
$surface.UpdateLayout()
$bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$surface.ActualWidth, [int]$surface.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
$bitmap.Render($surface)
$out = Join-Path $root '_diag'
[void](New-Item -Path $out -ItemType Directory -Force)
$stream = [IO.File]::Create((Join-Path $out 'codex-tabs.png'))
try {
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $encoder.Save($stream)
} finally { $stream.Dispose() }
$ClaudeTab.IsChecked = $true
if ($script:ActiveAgent -ne 'claude' -or $HdrLbl.Text -ne 'Чаты Claude') { throw 'Switch back to Claude failed' }
$window.Close()
'PASS: WPF layout, localized tabs, checked events, known/unknown context rows, and footer'
