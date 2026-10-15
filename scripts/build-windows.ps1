[CmdletBinding()]
param(
    [string]$Out = (Join-Path $PSScriptRoot '../build/windows'),
    [string]$PythonVersion = '3.13',
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [string]$InnoCompiler,
    [switch]$SkipSmokeTest
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Build on a native Windows host.' }
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ine $Architecture) {
    throw "Build $Architecture on a native Windows $Architecture host; cross-architecture runtime verification is required."
}
$Root = Split-Path $PSScriptRoot -Parent
$Version = (Get-Content -Raw (Join-Path $Root 'VERSION')).Trim()
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid release version.' }
$Platform = if ($Architecture -eq 'arm64') { 'ARM64' } else { 'x64' }
$PythonArchitecture = if ($Architecture -eq 'arm64') { 'aarch64' } else { 'x86_64' }
$PythonRequest = "cpython-$PythonVersion-windows-$PythonArchitecture-none"
$Out = [System.IO.Path]::GetFullPath($Out)
$Bundle = Join-Path $Out 'Google Photos Backup'
$Verification = Join-Path $Out 'verification'
New-Item -ItemType Directory -Force -Path $Out, $Verification | Out-Null
if (Test-Path $Bundle) { Remove-Item -Recurse -Force $Bundle }
$Project = Join-Path $Root 'Windows/GooglePhotosBackup.App/GooglePhotosBackup.App.csproj'
& dotnet publish $Project -c Release -r "win-$Architecture" --self-contained true "-p:Platform=$Platform" -p:WindowsAppSDKSelfContained=true -o $Bundle
if ($LASTEXITCODE -ne 0) { throw 'Native WinUI publish failed.' }

$Runtime = Join-Path $Bundle 'runtime'
$PythonRoot = Join-Path $Runtime 'python'
$BridgeRoot = Join-Path $Runtime 'bridge'
New-Item -ItemType Directory -Force -Path $PythonRoot, $BridgeRoot | Out-Null
& uv python install $PythonRequest
if ($LASTEXITCODE -ne 0) { throw "Managed native Python installation failed: $PythonRequest. No emulated runtime fallback is allowed." }
$ManagedPython = (& uv python find --managed-python --no-project $PythonRequest | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Managed Python discovery failed.' }
$ManagedRoot = (& $ManagedPython -I -B -c 'import sys; print(sys.base_prefix)').Trim()
if ($LASTEXITCODE -ne 0) { throw 'Managed Python could not start.' }
Copy-Item -Recurse -Force -Path (Join-Path $ManagedRoot '*') -Destination $PythonRoot
$Python = Join-Path $PythonRoot 'python.exe'
if (-not (Test-Path $Python)) { throw 'Managed runtime has no root python.exe.' }
& uv pip install --python $Python --target (Join-Path $BridgeRoot 'site-packages') -r (Join-Path $Root 'Bridge/requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Pinned bridge dependency installation failed.' }
Copy-Item (Join-Path $Root 'Bridge/*.py') $BridgeRoot
Copy-Item (Join-Path $Root 'LICENSE') $Bundle
# The 20261009 CPython 3.13.16 ARM64 distribution includes an unused x64
# vcruntime140_1.dll. Keep the shipped runtime strictly native; never remove
# it if any bundled binary references it, or if its format changes.
$ExtraRuntime = Join-Path $PythonRoot 'vcruntime140_1.dll'
if ($Architecture -eq 'arm64' -and (Test-Path $ExtraRuntime)) {
    $ExtraRuntime = (Get-Item -LiteralPath $ExtraRuntime).FullName
    $Bytes = [System.IO.File]::ReadAllBytes($ExtraRuntime)
    $PEOffset = [BitConverter]::ToInt32($Bytes, 0x3C)
    if ([BitConverter]::ToUInt32($Bytes, $PEOffset) -ne 0x00004550) { throw 'Invalid extra Python runtime PE header.' }
    $Machine = [BitConverter]::ToUInt16($Bytes, $PEOffset + 4)
    if ($Machine -eq 0x8664) {
        foreach ($Binary in Get-ChildItem $Runtime -Recurse -File | Where-Object { $_.Extension -in @('.exe', '.dll', '.pyd') -and $_.FullName -ne $ExtraRuntime }) {
            $Contents = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($Binary.FullName))
            if ($Contents.IndexOf('vcruntime140_1.dll', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw "Cannot remove incompatible Python runtime: $($Binary.FullName) references vcruntime140_1.dll."
            }
        }
        Remove-Item $ExtraRuntime
        Write-Host 'Removed unreferenced x64 vcruntime140_1.dll from the upstream ARM64 Python distribution.'
    } elseif ($Machine -ne 0xAA64) { throw "Unexpected extra Python runtime architecture: $Machine" }
}
& (Join-Path $PSScriptRoot 'verify-windows.ps1') -Bundle $Bundle -Architecture $Architecture -ReportDirectory (Join-Path $Verification 'original')

$Archive = Join-Path $Out "Google-Photos-Backup-$Version-Windows-$Architecture.zip"
if (Test-Path $Archive) { Remove-Item $Archive }
[System.IO.Compression.ZipFile]::CreateFromDirectory($Bundle, $Archive, [System.IO.Compression.CompressionLevel]::Optimal, $true)
$Relocated = Join-Path ([System.IO.Path]::GetTempPath()) ('google-photos-backup-relocation-' + [guid]::NewGuid().ToString('N'))
try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Relocated)
    & (Join-Path $PSScriptRoot 'verify-windows.ps1') -Bundle (Join-Path $Relocated 'Google Photos Backup') -Architecture $Architecture -ReportDirectory (Join-Path $Verification 'relocated') -SmokeTest:(-not $SkipSmokeTest)
} finally {
    if (Test-Path $Relocated) { Remove-Item -Recurse -Force $Relocated }
}

if (-not $InnoCompiler) {
    $Candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6/ISCC.exe')
    )
    $Command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($Command) { $Candidates += $Command.Source }
    $InnoCompiler = $Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $InnoCompiler -or -not (Test-Path $InnoCompiler)) {
    throw 'Inno Setup 6 is required to build the executable installer; install it or pass -InnoCompiler <ISCC.exe>.'
}
& $InnoCompiler "/DBundleDir=$Bundle" "/DOutputDir=$Out" "/DAppVersion=$Version" "/DTargetArch=$Architecture" (Join-Path $PSScriptRoot 'windows-installer.iss')
if ($LASTEXITCODE -ne 0) { throw 'Executable installer compilation failed.' }
$Installer = Join-Path $Out "Google-Photos-Backup-$Version-Windows-$Architecture-Setup.exe"
if (-not (Test-Path $Installer)) { throw 'Executable installer was not produced.' }

function Invoke-Setup([string]$Executable, [string[]]$Arguments) {
    $Start = [System.Diagnostics.ProcessStartInfo]::new($Executable)
    $Start.UseShellExecute = $false
    foreach ($Argument in $Arguments) { $Start.ArgumentList.Add($Argument) }
    $Process = [System.Diagnostics.Process]::Start($Start)
    try {
        if (-not $Process.WaitForExit(120000)) { $Process.Kill($true); throw 'Installer verification timed out.' }
        if ($Process.ExitCode -ne 0) { throw "Installer process failed with exit code $($Process.ExitCode)." }
    } finally { $Process.Dispose() }
}

$Installed = Join-Path ([System.IO.Path]::GetTempPath()) ('google-photos-backup-install-' + [guid]::NewGuid().ToString('N'))
try {
    Invoke-Setup $Installer @('/CURRENTUSER', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/NOICONS', "/DIR=$Installed")
    & (Join-Path $PSScriptRoot 'verify-windows.ps1') -Bundle $Installed -Architecture $Architecture -ReportDirectory (Join-Path $Verification 'installed') -SmokeTest:(-not $SkipSmokeTest)
} finally {
    $Uninstaller = Join-Path $Installed 'unins000.exe'
    if (Test-Path $Uninstaller) { Invoke-Setup $Uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') }
    if (Test-Path $Installed) { Remove-Item -Recurse -Force $Installed }
}
foreach ($Artifact in @($Archive, $Installer)) {
    $Digest = (Get-FileHash -Algorithm SHA256 $Artifact).Hash.ToLowerInvariant()
    "$Digest  $([System.IO.Path]::GetFileName($Artifact))" | Set-Content -Encoding utf8 ("$Artifact.sha256")
}
Write-Host "Packaged unsigned native Windows $Architecture build: $Archive and $Installer"
