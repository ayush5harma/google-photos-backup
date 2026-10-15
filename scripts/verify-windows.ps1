[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Bundle,
    [Parameter(Mandatory)][string]$ReportDirectory,
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [switch]$SmokeTest
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Verification requires Windows.' }
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ine $Architecture) {
    throw "Runtime verification requires a native Windows $Architecture host."
}
$ExpectedMachine = if ($Architecture -eq 'arm64') { 0xAA64 } else { 0x8664 }
$Bundle = [System.IO.Path]::GetFullPath($Bundle)
$ReportDirectory = [System.IO.Path]::GetFullPath($ReportDirectory)
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null

function Assert-NativePE([string]$Path) {
    $Reader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead($Path))
    try {
        if ($Reader.ReadUInt16() -ne 0x5A4D) { throw "Not a PE binary: $Path" }
        $Reader.BaseStream.Position = 0x3C
        $Offset = $Reader.ReadInt32()
        $Reader.BaseStream.Position = $Offset
        if ($Reader.ReadUInt32() -ne 0x00004550 -or $Reader.ReadUInt16() -ne $ExpectedMachine) {
            throw "Expected native $Architecture PE binary: $Path"
        }
    } finally { $Reader.Dispose() }
}

$App = Join-Path $Bundle 'GooglePhotosBackup.exe'
$Python = Join-Path $Bundle 'runtime/python/python.exe'
$Bridge = Join-Path $Bundle 'runtime/bridge/gpmc_bridge.py'
$ReleaseVersion = (Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION')).Trim()
$ProductVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($App).ProductVersion
if (-not $ProductVersion -or $ProductVersion.Split('+')[0] -ne $ReleaseVersion) {
    throw "Incorrect application version: $ProductVersion (expected $ReleaseVersion)"
}
Assert-NativePE $App
Assert-NativePE $Python
foreach ($RuntimeLibrary in @('coreclr.dll', 'hostfxr.dll', 'hostpolicy.dll', 'Microsoft.UI.Xaml.dll')) {
    Assert-NativePE (Join-Path $Bundle $RuntimeLibrary)
}
$Resources = @(Get-ChildItem $Bundle -Recurse -File | Where-Object { $_.Extension -in @('.pri', '.xbf') } | Sort-Object FullName | ForEach-Object {
    [ordered]@{ path = [System.IO.Path]::GetRelativePath($Bundle, $_.FullName); bytes = $_.Length; sha256 = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant() }
})
$Resources | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 (Join-Path $ReportDirectory 'xaml-resources.json')
if (-not ((Test-Path (Join-Path $Bundle 'GooglePhotosBackup.pri')) -or (Test-Path (Join-Path $Bundle 'resources.pri')))) {
    throw 'The application PRI resource index is missing from the published bundle.'
}
if (-not (Test-Path (Join-Path $Bundle 'coreclr.dll'))) { throw 'The .NET self-contained runtime is missing.' }
if (-not (Test-Path (Join-Path $Bundle 'Microsoft.UI.Xaml.dll'))) { throw 'The self-contained WinUI runtime is missing.' }
$NativeModules = @(Get-ChildItem (Join-Path $Bundle 'runtime/python') -Recurse -Filter '*.pyd')
foreach ($Module in $NativeModules) { Assert-NativePE $Module.FullName }
$NativeDependencies = @(Get-ChildItem (Join-Path $Bundle 'runtime/bridge') -Recurse -Filter '*.pyd')
foreach ($Module in $NativeDependencies) { Assert-NativePE $Module.FullName }
$NativeLibraries = @(Get-ChildItem (Join-Path $Bundle 'runtime') -Recurse -Filter '*.dll')
foreach ($Library in $NativeLibraries) { Assert-NativePE $Library.FullName }
$Machine = (& $Python -I -B -c 'import platform, struct; print(platform.machine(), struct.calcsize("P") * 8)').Trim()
$ExpectedPythonMachine = if ($Architecture -eq 'arm64') { 'ARM64 64' } else { 'AMD64 64' }
if ($LASTEXITCODE -ne 0 -or $Machine -ine $ExpectedPythonMachine) { throw "Incorrect Python architecture: $Machine (expected $ExpectedPythonMachine)" }
$VersionOutput = '{"command":"version"}' | & $Python -I -B $Bridge
if ($LASTEXITCODE -ne 0) { throw 'The bundled bridge version request failed.' }
$VersionEvents = @($VersionOutput | ForEach-Object { $_ | ConvertFrom-Json })
$BridgeVersion = @($VersionEvents | Where-Object { $_.type -eq 'version' })
if ($BridgeVersion.Count -ne 1 -or $BridgeVersion[0].gpmc -ne '0.9.0') { throw 'The pinned real gpmc package is missing.' }
& $Python -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import ssl, sqlite3; from gpmc import Client; from pyicloud_ipd import PyiCloudService' (Join-Path $Bundle 'runtime/bridge/site-packages')
if ($LASTEXITCODE -ne 0) { throw 'The bundled Python dependencies cannot be imported.' }

& $Python -I -B (Join-Path $PSScriptRoot 'verify-icloud.py') $Python (Join-Path $Bundle 'runtime/bridge/icloud_bridge.py')
if ($LASTEXITCODE -ne 0) { throw 'Packaged iCloud signed-out guidance verification failed.' }

$Report = [ordered]@{
    version = $ReleaseVersion
    architecture = $Architecture
    appHost = "native PE $Architecture"
    selfContainedDotNet = $true
    selfContainedWinUI = $true
    python = $BridgeVersion[0].python
    gpmc = $BridgeVersion[0].gpmc
    nativePythonModules = $NativeModules.Count + $NativeDependencies.Count
    nativeRuntimeLibraries = $NativeLibraries.Count
    bridgeSmoke = 'passed'
    icloudSignedOutSmoke = 'passed'
    icloudReclaim = 'disabled: no independent destination proof'
    uiSmoke = 'not requested'
    signing = 'unsigned; no Authenticode signing certificate configured'
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
        $LaunchTime = Get-Date
        $Process = [System.Diagnostics.Process]::Start($Start)
        try {
            if (-not $Process.WaitForExit(45000)) {
                $Process.Kill($true)
                $Process.WaitForExit()
                throw 'Synthetic WinUI launch did not exit within 45 seconds; GUI initialization is not verified.'
            }
            if ($Process.ExitCode -ne 0) {
                if (Test-Path $SmokeReport) {
                    $Failure = Get-Content -Raw $SmokeReport | ConvertFrom-Json
                    Write-Host ("Synthetic UI failure: " + ($Failure | ConvertTo-Json -Compress))
                } else {
                    # 2026-10-15: Native loader failures precede the fixture's managed report.
                    $Events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $LaunchTime } -ErrorAction SilentlyContinue |
                        Where-Object { $_.ProviderName -in @('.NET Runtime', 'Application Error') -and $_.Message -match 'GooglePhotosBackup' } |
                        Select-Object -First 5 TimeCreated, ProviderName, Id, Message)
                    if ($Events.Count -gt 0) {
                        $Events | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 (Join-Path $ReportDirectory 'ui-native-errors.json')
                        Write-Host ($Events | ConvertTo-Json -Depth 3)
                    }
                }
                throw "Synthetic WinUI launch failed with exit code $($Process.ExitCode)."
            }
            if (-not (Test-Path $SmokeReport)) { throw 'Synthetic WinUI launch did not produce its initialization report.' }
            $UIReport = Get-Content -Raw $SmokeReport | ConvertFrom-Json
            if ($UIReport.status -ne 'ok') { throw 'Synthetic WinUI initialization was not successful.' }
            if ($UIReport.icloudPageRendered -ne $true) { throw 'The iCloud sign-in page failed its native UI check.' }
            if ($UIReport.encryptedCredentialRoundTrip -ne $true) { throw 'Synthetic DPAPI credential round-trip failed.' }
            if ($UIReport.navigationCollapsed -ne $true -or $UIReport.navigationReopened -ne $true) {
                throw 'Navigation pane collapse and reopen failed its rendered UI check.'
            }
            if (-not (Test-Path $Screenshot) -or (Get-Item $Screenshot).Length -eq 0) { throw 'Synthetic WinUI screenshot was not produced.' }
            $CollapsedScreenshot = Join-Path $ReportDirectory 'ui-smoke-collapsed.png'
            if (-not (Test-Path $CollapsedScreenshot) -or (Get-Item $CollapsedScreenshot).Length -eq 0) {
                throw 'Collapsed navigation screenshot was not produced.'
            }
            $DarkScreenshot = Join-Path $ReportDirectory 'ui-smoke-dark.png'
            if (-not (Test-Path $DarkScreenshot) -or (Get-Item $DarkScreenshot).Length -eq 0) { throw 'Dark WinUI screenshot was not produced.' }
            if ($UIReport.lightIconSource -notlike '*/Assets/app-icon.png' -or $UIReport.darkIconSource -notlike '*/Assets/app-icon-dark.png') {
                throw 'WinUI did not select both appearance assets.'
            }
            $Report.appearanceIcons = 'passed: decoded light and dark assets after changing the window theme'
            $Report.navigationPane = 'passed: icons rendered without labels in compact mode; labels returned when reopened'
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
