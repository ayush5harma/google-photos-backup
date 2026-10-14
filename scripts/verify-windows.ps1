[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Bundle,
    [Parameter(Mandatory)][string]$ReportDirectory,
    [switch]$SmokeTest
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Verification requires Windows.' }
$Bundle = [System.IO.Path]::GetFullPath($Bundle)
$ReportDirectory = [System.IO.Path]::GetFullPath($ReportDirectory)
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null

function Assert-X64PE([string]$Path) {
    $Reader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead($Path))
    try {
        if ($Reader.ReadUInt16() -ne 0x5A4D) { throw "Not a PE binary: $Path" }
        $Reader.BaseStream.Position = 0x3C
        $Offset = $Reader.ReadInt32()
        $Reader.BaseStream.Position = $Offset
        if ($Reader.ReadUInt32() -ne 0x00004550 -or $Reader.ReadUInt16() -ne 0x8664) {
            throw "Expected native x64 PE binary: $Path"
        }
    } finally { $Reader.Dispose() }
}

$App = Join-Path $Bundle 'GooglePhotosBackup.exe'
$Python = Join-Path $Bundle 'runtime/python/python.exe'
$Bridge = Join-Path $Bundle 'runtime/bridge/gpmc_bridge.py'
Assert-X64PE $App
Assert-X64PE $Python
if (-not (Test-Path (Join-Path $Bundle 'coreclr.dll'))) { throw 'The .NET self-contained runtime is missing.' }
if (-not (Test-Path (Join-Path $Bundle 'Microsoft.UI.Xaml.dll'))) { throw 'The self-contained WinUI runtime is missing.' }
$NativeModules = @(Get-ChildItem (Join-Path $Bundle 'runtime/python') -Recurse -Filter '*.pyd')
foreach ($Module in $NativeModules) { Assert-X64PE $Module.FullName }
$NativeDependencies = @(Get-ChildItem (Join-Path $Bundle 'runtime/bridge') -Recurse -Filter '*.pyd')
foreach ($Module in $NativeDependencies) { Assert-X64PE $Module.FullName }
$Machine = (& $Python -I -B -c 'import platform, struct; print(platform.machine(), struct.calcsize("P") * 8)').Trim()
if ($LASTEXITCODE -ne 0 -or $Machine -ne 'AMD64 64') { throw "Incorrect Python architecture: $Machine" }
$VersionOutput = '{"command":"version"}' | & $Python -I -B $Bridge
if ($LASTEXITCODE -ne 0) { throw 'The bundled bridge version request failed.' }
$VersionEvents = @($VersionOutput | ForEach-Object { $_ | ConvertFrom-Json })
$Version = @($VersionEvents | Where-Object { $_.type -eq 'version' })
if ($Version.Count -ne 1 -or $Version[0].gpmc -ne '0.9.0') { throw 'The pinned real gpmc package is missing.' }
& $Python -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import ssl, sqlite3; from gpmc import Client' (Join-Path $Bundle 'runtime/bridge/site-packages')
if ($LASTEXITCODE -ne 0) { throw 'The bundled Python dependencies cannot be imported.' }

$Report = [ordered]@{
    architecture = 'x64'
    appHost = 'native PE x64'
    selfContainedDotNet = $true
    selfContainedWinUI = $true
    python = $Version[0].python
    gpmc = $Version[0].gpmc
    nativePythonModules = $NativeModules.Count + $NativeDependencies.Count
    bridgeSmoke = 'passed'
    uiSmoke = 'not requested'
    signing = 'unsigned CI artifact; no Windows release published'
}
$ReportPath = Join-Path $ReportDirectory 'verification.json'
try {
    if ($SmokeTest) {
        $SmokeReport = Join-Path $ReportDirectory 'ui-smoke.json'
        if (Test-Path $SmokeReport) { Remove-Item $SmokeReport }
        $Start = [System.Diagnostics.ProcessStartInfo]::new($App)
        $Start.WorkingDirectory = $Bundle
        $Start.UseShellExecute = $false
        $Start.ArgumentList.Add('--smoke-test')
        $Start.ArgumentList.Add($SmokeReport)
        $Screenshot = Join-Path $ReportDirectory 'ui-smoke.png'
        $Start.ArgumentList.Add('--screenshot')
        $Start.ArgumentList.Add($Screenshot)
        $Process = [System.Diagnostics.Process]::Start($Start)
        try {
            if (-not $Process.WaitForExit(45000)) {
                $Process.Kill($true)
                $Process.WaitForExit()
                throw 'Synthetic WinUI launch did not exit within 45 seconds; GUI initialization is not verified.'
            }
            if ($Process.ExitCode -ne 0) { throw "Synthetic WinUI launch failed with exit code $($Process.ExitCode)." }
            if (-not (Test-Path $SmokeReport)) { throw 'Synthetic WinUI launch did not produce its initialization report.' }
            $UIReport = Get-Content -Raw $SmokeReport | ConvertFrom-Json
            if ($UIReport.status -ne 'ok') { throw 'Synthetic WinUI initialization was not successful.' }
            if ($UIReport.encryptedCredentialRoundTrip -ne $true) { throw 'Synthetic DPAPI credential round-trip failed.' }
            if (-not (Test-Path $Screenshot) -or (Get-Item $Screenshot).Length -eq 0) { throw 'Synthetic WinUI screenshot was not produced.' }
            $Report.encryptedCredentialRoundTrip = $true
            $Report.uiSmoke = 'passed: constructed MainWindow and exited without authentication or network access'
        } finally { $Process.Dispose() }
    }
} catch {
    $Report.uiSmoke = "failed: $($_.Exception.Message)"
    throw
} finally {
    $Report | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 $ReportPath
}
Write-Host "Verified native app, bundled Python and real bridge in $Bundle"
