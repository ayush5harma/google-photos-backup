[CmdletBinding()]
param(
    [string]$Out = (Join-Path $PSScriptRoot '../build/windows'),
    [string]$PythonVersion = '3.13',
    [switch]$SkipSmokeTest
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Build on a native Windows x64 host.' }
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') { throw 'Only native Windows x64 builds are supported.' }
$Root = Split-Path $PSScriptRoot -Parent
$Out = [System.IO.Path]::GetFullPath($Out)
$Bundle = Join-Path $Out 'Google Photos Backup'
$Verification = Join-Path $Out 'verification'
New-Item -ItemType Directory -Force -Path $Out, $Verification | Out-Null
if (Test-Path $Bundle) { Remove-Item -Recurse -Force $Bundle }
$Project = Join-Path $Root 'Windows/GooglePhotosBackup.App/GooglePhotosBackup.App.csproj'
& dotnet publish $Project -c Release -r win-x64 --self-contained true -p:Platform=x64 -p:WindowsAppSDKSelfContained=true -o $Bundle
if ($LASTEXITCODE -ne 0) { throw 'Native WinUI publish failed.' }

$Runtime = Join-Path $Bundle 'runtime'
$PythonRoot = Join-Path $Runtime 'python'
$BridgeRoot = Join-Path $Runtime 'bridge'
New-Item -ItemType Directory -Force -Path $PythonRoot, $BridgeRoot | Out-Null
& uv python install $PythonVersion
if ($LASTEXITCODE -ne 0) { throw 'Managed Python installation failed.' }
$ManagedPython = (& uv python find --managed-python --no-project $PythonVersion | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Managed Python discovery failed.' }
$ManagedRoot = (& $ManagedPython -I -B -c 'import sys; print(sys.base_prefix)').Trim()
if ($LASTEXITCODE -ne 0) { throw 'Managed Python could not start.' }
Copy-Item -Recurse -Force -Path (Join-Path $ManagedRoot '*') -Destination $PythonRoot
$Python = Join-Path $PythonRoot 'python.exe'
if (-not (Test-Path $Python)) { throw 'Managed runtime has no root python.exe.' }
& uv pip install --python $Python --target (Join-Path $BridgeRoot 'site-packages') -r (Join-Path $Root 'Bridge/requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Pinned bridge dependency installation failed.' }
Copy-Item (Join-Path $Root 'Bridge/gpmc_bridge.py') $BridgeRoot
& (Join-Path $PSScriptRoot 'verify-windows.ps1') -Bundle $Bundle -ReportDirectory (Join-Path $Verification 'original')

$Archive = Join-Path $Out 'Google-Photos-Backup-Windows-x64.zip'
if (Test-Path $Archive) { Remove-Item $Archive }
[System.IO.Compression.ZipFile]::CreateFromDirectory($Bundle, $Archive, [System.IO.Compression.CompressionLevel]::Optimal, $true)
$Relocated = Join-Path ([System.IO.Path]::GetTempPath()) ('google-photos-backup-relocation-' + [guid]::NewGuid().ToString('N'))
try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Relocated)
    & (Join-Path $PSScriptRoot 'verify-windows.ps1') -Bundle (Join-Path $Relocated 'Google Photos Backup') -ReportDirectory (Join-Path $Verification 'relocated') -SmokeTest:(-not $SkipSmokeTest)
} finally {
    if (Test-Path $Relocated) { Remove-Item -Recurse -Force $Relocated }
}
$Digest = (Get-FileHash -Algorithm SHA256 $Archive).Hash.ToLowerInvariant()
"$Digest  $([System.IO.Path]::GetFileName($Archive))" | Set-Content -Encoding utf8 ("$Archive.sha256")
Write-Host "Packaged unsigned Windows x64 build: $Archive"
