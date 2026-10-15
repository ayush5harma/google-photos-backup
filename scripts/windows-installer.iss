; Compile with scripts/build-windows.ps1. The installer carries the complete
; self-contained WinUI/.NET app and its native Python backup providers.
#ifndef BundleDir
  #error BundleDir is required
#endif
#if TargetArch == "arm64"
  #define AllowedArchitecture "arm64"
#else
  #if TargetArch != "x64"
    #error TargetArch must be x64 or arm64
  #endif
  #define AllowedArchitecture "x64compatible"
#endif

[Setup]
AppId={{8EA3B68B-C11F-4A89-93E8-629732DD1EE0}
AppName=Google Photos Backup
AppVersion={#AppVersion}
AppPublisher=Google Photos Backup contributors
AppPublisherURL=https://github.com/ayush5harma/google-photos-backup
DefaultDirName={localappdata}\Programs\Google Photos Backup
DefaultGroupName=Google Photos Backup
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed={#AllowedArchitecture}
ArchitecturesInstallIn64BitMode={#AllowedArchitecture}
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=Google-Photos-Backup-{#AppVersion}-Windows-{#TargetArch}-Setup
SetupIconFile={#BundleDir}\Assets\app-icon.ico
UninstallDisplayIcon={app}\GooglePhotosBackup.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
LicenseFile={#BundleDir}\LICENSE

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Google Photos Backup"; Filename: "{app}\GooglePhotosBackup.exe"

[Run]
Filename: "{app}\GooglePhotosBackup.exe"; Description: "Open Google Photos Backup"; Flags: nowait postinstall skipifsilent
