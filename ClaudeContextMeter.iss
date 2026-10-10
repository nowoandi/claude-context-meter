; Inno Setup script for Claude Context Meter.
; Build:  powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
;         (compiles build\ClaudeContextMeter.exe from launcher\, then runs ISCC on this file)
;
; Installs per-user into %LOCALAPPDATA%\Programs so no administrator rights are needed —
; the widget writes only to its own state files and its HKCU autostart entry, and nothing
; it does warrants an elevation prompt.

#define AppName      "Claude Context Meter"
#define AppVersion   "1.3.2"
#define AppPublisher "Andrej Hermann"
#define AppURL       "https://github.com/nowoandi/claude-context-meter"
; The widget's own executable since 1.3.2: it carries the name and icon Task Manager shows,
; and as a windowed program it opens no console. The .vbs and .bat stay for old shortcuts.
#define AppExeName   "ClaudeContextMeter.exe"

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
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; The widget already holds this mutex for its single-instance guard, so Inno can use it to
; notice a running copy and ask for it to be closed instead of writing over a file in use.
AppMutex=Global\ClaudeContextMeter

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "build\ClaudeContextMeter.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "ClaudeContextMeter.ps1";   DestDir: "{app}"; Flags: ignoreversion
Source: "CodexContext.ps1";         DestDir: "{app}"; Flags: ignoreversion
Source: "Start-ContextMeter.vbs";   DestDir: "{app}"; Flags: ignoreversion
Source: "Start-ContextMeter.bat";   DestDir: "{app}"; Flags: ignoreversion
Source: "ClaudeContextMeter.ico";   DestDir: "{app}"; Flags: ignoreversion
Source: "README.md";                DestDir: "{app}"; Flags: ignoreversion
Source: "README.ru.md";             DestDir: "{app}"; Flags: ignoreversion
Source: "README.de.md";             DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}";        Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{userdesktop}\{#AppName}";  Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent

[UninstallRun]
; Autostart is written by the widget, not by the installer, so the uninstaller has to take
; it out explicitly, or it would survive as an entry pointing at files that no longer exist.
; Since 1.3.2 it is the HKCU Run value (plus Task Manager's StartupApproved switch); before
; that it was a scheduled task, which an install that was never started again may still
; have. runhidden, and failures are ignored: there may simply be nothing, which is not an error.
Filename: "{sys}\reg.exe"; Parameters: "delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v ClaudeContextMeter /f"; Flags: runhidden; RunOnceId: "DelRun"
Filename: "{sys}\reg.exe"; Parameters: "delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"" /v ClaudeContextMeter /f"; Flags: runhidden; RunOnceId: "DelApproved"
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""ClaudeContextMeter"" /F"; Flags: runhidden skipifdoesntexist; RunOnceId: "DelTask"

[UninstallDelete]
; Written next to the script only when %LOCALAPPDATA% is unavailable; usually absent.
Type: files; Name: "{app}\ClaudeContextMeter.log"
