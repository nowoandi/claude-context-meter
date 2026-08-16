; Inno Setup script for Claude Context Meter.
; Build:  "%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe" ClaudeContextMeter.iss
;
; Installs per-user into %LOCALAPPDATA%\Programs so no administrator rights are needed —
; the widget writes only to its own state files and a scheduled task under the current
; user, and nothing it does warrants an elevation prompt.

#define AppName      "Claude Context Meter"
#define AppVersion   "1.1.1"
#define AppPublisher "nowoandi"
#define AppURL       "https://github.com/nowoandi/claude-context-meter"
; The .vbs, not the .bat: it starts PowerShell with the console hidden from creation, so
; nothing flashes on screen. The .bat now only forwards to it and stays for old shortcuts.
#define AppExeName   "Start-ContextMeter.vbs"

[Setup]
AppId={{7C1F4E92-3A6D-4B58-9E0C-2D5A8F14B7C3}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}/releases
DefaultDirName={localappdata}\Programs\ClaudeContextMeter
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=ClaudeContextMeter-{#AppVersion}-setup
SetupIconFile=ClaudeContextMeter.ico
UninstallDisplayIcon={app}\ClaudeContextMeter.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; The widget already holds this mutex for its single-instance guard, so Inno can use it to
; notice a running copy and ask for it to be closed instead of writing over a file in use.
AppMutex=Global\ClaudeContextMeter

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "ClaudeContextMeter.ps1";   DestDir: "{app}"; Flags: ignoreversion
Source: "Start-ContextMeter.vbs";   DestDir: "{app}"; Flags: ignoreversion
Source: "Start-ContextMeter.bat";   DestDir: "{app}"; Flags: ignoreversion
Source: "ClaudeContextMeter.ico";   DestDir: "{app}"; Flags: ignoreversion
Source: "README.md";                DestDir: "{app}"; Flags: ignoreversion
Source: "README.ru.md";             DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}";        Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\ClaudeContextMeter.ico"; WorkingDir: "{app}"
Name: "{userdesktop}\{#AppName}";  Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\ClaudeContextMeter.ico"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent

[UninstallRun]
; Autostart is a scheduled task owned by the widget, not something the installer created,
; so the uninstaller has to take it out explicitly. Without this the task would survive as
; an entry pointing at files that no longer exist. runhidden, and failures are ignored:
; there may simply be no task, which is not an error.
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""ClaudeContextMeter"" /F"; Flags: runhidden skipifdoesntexist; RunOnceId: "DelTask"

[UninstallDelete]
; Written next to the script only when %LOCALAPPDATA% is unavailable; usually absent.
Type: files; Name: "{app}\ClaudeContextMeter.log"
