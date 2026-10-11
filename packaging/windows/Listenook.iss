#ifndef AppVersion
  #error AppVersion must be supplied by the build script.
#endif
#ifndef AppArch
  #error AppArch must be supplied by the build script.
#endif
#ifndef AppPublisher
  #define AppPublisher "Capyvibe"
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
AppName=Listenook
AppVersion={#AppVersion}
AppVerName=Listenook {#AppVersion}
AppPublisher={#AppPublisher}
UninstallDisplayName=Listenook
UninstallDisplayIcon={app}\Listenook.exe
DefaultDirName={localappdata}\Programs\Listenook
DefaultGroupName=Listenook
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
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no
SetupLogging=yes
ChangesAssociations=yes

[InstallDelete]
Type: files; Name: "{app}\MeowSTT.exe"
Type: files; Name: "{autoprograms}\MeowSTT.lnk"
Type: files; Name: "{autodesktop}\MeowSTT.lnk"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked
Name: "videoassoc"; Description: "Open video files with Listenook (MP4, MKV, MOV, M4V, WebM, AVI)"; GroupDescription: "File associations:"

[Registry]
; Video player: Listenook appears in "Open with" and in Default apps. Windows
; lets the user, not the installer, make it the default.
Root: HKA; Subkey: "Software\Classes\Listenook.Video"; ValueType: string; ValueName: ""; ValueData: "Video"; Flags: uninsdeletekey; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\Listenook.Video\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\Listenook.exe,0"; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\Listenook.Video\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Listenook.exe"" ""%1"""; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\Applications\Listenook.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Listenook"; Flags: uninsdeletekey; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\Applications\Listenook.exe\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Listenook.exe"" ""%1"""; Tasks: videoassoc
Root: HKA; Subkey: "Software\Listenook\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "Listenook"; Flags: uninsdeletekey; Tasks: videoassoc
Root: HKA; Subkey: "Software\Listenook\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "Watch videos with subtitles, sentence by sentence."; Tasks: videoassoc
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "Listenook"; ValueData: "Software\Listenook\Capabilities"; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\.mp4\OpenWithProgids"; ValueType: string; ValueName: "Listenook.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\Applications\Listenook.exe\SupportedTypes"; ValueType: string; ValueName: ".mp4"; ValueData: ""; Tasks: videoassoc
Root: HKA; Subkey: "Software\Listenook\Capabilities\FileAssociations"; ValueType: string; ValueName: ".mp4"; ValueData: "Listenook.Video"; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\.m4v\OpenWithProgids"; ValueType: string; ValueName: "Listenook.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\Applications\Listenook.exe\SupportedTypes"; ValueType: string; ValueName: ".m4v"; ValueData: ""; Tasks: videoassoc
Root: HKA; Subkey: "Software\Listenook\Capabilities\FileAssociations"; ValueType: string; ValueName: ".m4v"; ValueData: "Listenook.Video"; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\.mov\OpenWithProgids"; ValueType: string; ValueName: "Listenook.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\Applications\Listenook.exe\SupportedTypes"; ValueType: string; ValueName: ".mov"; ValueData: ""; Tasks: videoassoc
Root: HKA; Subkey: "Software\Listenook\Capabilities\FileAssociations"; ValueType: string; ValueName: ".mov"; ValueData: "Listenook.Video"; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\.mkv\OpenWithProgids"; ValueType: string; ValueName: "Listenook.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\Applications\Listenook.exe\SupportedTypes"; ValueType: string; ValueName: ".mkv"; ValueData: ""; Tasks: videoassoc
Root: HKA; Subkey: "Software\Listenook\Capabilities\FileAssociations"; ValueType: string; ValueName: ".mkv"; ValueData: "Listenook.Video"; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\.webm\OpenWithProgids"; ValueType: string; ValueName: "Listenook.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\Applications\Listenook.exe\SupportedTypes"; ValueType: string; ValueName: ".webm"; ValueData: ""; Tasks: videoassoc
Root: HKA; Subkey: "Software\Listenook\Capabilities\FileAssociations"; ValueType: string; ValueName: ".webm"; ValueData: "Listenook.Video"; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\.avi\OpenWithProgids"; ValueType: string; ValueName: "Listenook.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKA; Subkey: "Software\Classes\Applications\Listenook.exe\SupportedTypes"; ValueType: string; ValueName: ".avi"; ValueData: ""; Tasks: videoassoc
Root: HKA; Subkey: "Software\Listenook\Capabilities\FileAssociations"; ValueType: string; ValueName: ".avi"; ValueData: "Listenook.Video"; Tasks: videoassoc

[Icons]
Name: "{autoprograms}\Listenook"; Filename: "{app}\Listenook.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Listenook"; Filename: "{app}\Listenook.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\Listenook.exe"; Description: "Launch Listenook"; Flags: nowait postinstall skipifsilent
Filename: "{app}\Listenook.exe"; Flags: nowait postinstall runasoriginaluser; Check: ShouldRelaunch

[Code]
function ShouldRelaunch: Boolean;
begin
  Result := ExpandConstant('{param:relaunch|0}') = '1';
end;
