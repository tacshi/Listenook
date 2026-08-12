#ifndef AppVersion
  #error AppVersion must be supplied by the build script.
#endif
#ifndef AppArch
  #error AppArch must be supplied by the build script.
#endif
#ifndef AppPublisher
  #define AppPublisher "MeowSTT"
#endif
#ifndef BuildDir
  #error BuildDir must be supplied by the build script.
#endif
#ifndef OutputDir
  #error OutputDir must be supplied by the build script.
#endif
#ifndef OutputBaseName
  #error OutputBaseName must be supplied by the build script.
#endif
#ifndef SetupIcon
  #error SetupIcon must be supplied by the build script.
#endif

#if AppArch == "arm64"
  #define SupportedArchitecture "arm64"
#elif AppArch == "x64"
  #define SupportedArchitecture "x64compatible"
#else
  #error AppArch must be x64 or arm64.
#endif

[Setup]
AppId={{2CBD3B1E-8EC8-4BCF-9FB6-33AC6EFA2C16}
AppName=MeowSTT
AppVersion={#AppVersion}
AppVerName=MeowSTT {#AppVersion}
AppPublisher={#AppPublisher}
UninstallDisplayName=MeowSTT
UninstallDisplayIcon={app}\MeowSTT.exe
DefaultDirName={localappdata}\Programs\MeowSTT
DefaultGroupName=MeowSTT
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed={#SupportedArchitecture}
ArchitecturesInstallIn64BitMode={#SupportedArchitecture}
MinVersion=10.0.19045
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
SetupIconFile={#SetupIcon}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Icons]
Name: "{autoprograms}\MeowSTT"; Filename: "{app}\MeowSTT.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\MeowSTT"; Filename: "{app}\MeowSTT.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\MeowSTT.exe"; Description: "Launch MeowSTT"; Flags: nowait postinstall skipifsilent
Filename: "{app}\MeowSTT.exe"; Flags: nowait postinstall runasoriginaluser; Check: ShouldRelaunch

[Code]
function ShouldRelaunch: Boolean;
begin
  Result := ExpandConstant('{param:relaunch|0}') = '1';
end;
