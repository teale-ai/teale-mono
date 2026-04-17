; TealeNode Inno Setup Script
; Builds a self-extracting installer that bundles all binaries,
; downloads the model, and installs TealeNode as a Windows service.
;
; To compile:
;   1. Install Inno Setup from https://jrsoftware.org/isinfo.php
;   2. Place these files next to this .iss file:
;      - teale-node.exe   (from cargo build)
;      - llama-server.exe (from C:\Teale\bin\)
;      - nssm.exe         (from C:\Teale\bin\)
;      - post-install.ps1 (included in this directory)
;      - uninstall.ps1    (included in this directory)
;      - check-update.ps1 (included in this directory)
;   3. Open this file in Inno Setup Compiler and click Build > Compile

#define AppVer "0.1.0"

[Setup]
AppName=Teale Node
AppVersion={#AppVer}
AppPublisher=Teale AI
DefaultDirName=C:\Teale
DefaultGroupName=Teale Node
OutputBaseFilename=Teale
OutputDir=output
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
DisableProgramGroupPage=yes
DisableDirPage=yes
SetupIconFile=compiler:SetupClassicIcon.ico

[Files]
; Binaries go to C:\Teale\bin
Source: "teale-node.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "llama-server.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "nssm.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
; Copy DLLs if present (llama-server runtime deps)
Source: "*.dll"; DestDir: "{app}\bin"; Flags: ignoreversion skipifsourcedoesntexist
; Scripts
Source: "post-install.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "check-update.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Dirs]
Name: "{app}\models"
Name: "{app}\config"
Name: "{app}\logs"
Name: "{app}\data"

[Run]
; Run post-install script after extraction — downloads model and installs service
Filename: "powershell.exe"; \
    Parameters: "-ExecutionPolicy Bypass -File ""{app}\post-install.ps1"" -InstallDir ""{app}"""; \
    StatusMsg: "Downloading model and configuring service (this may take a few minutes)..."; \
    Flags: runhidden waituntilterminated

; Write version file for update checker
Filename: "powershell.exe"; \
    Parameters: "-ExecutionPolicy Bypass -Command ""Set-Content -Path '{app}\version.txt' -Value 'v{#AppVer}' -Encoding UTF8"""; \
    Flags: runhidden waituntilterminated

; Register scheduled task for update checks on user login
Filename: "schtasks.exe"; \
    Parameters: "/Create /TN ""TealeNodeUpdateCheck"" /TR ""powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File '{app}\check-update.ps1'"" /SC ONLOGON /RL HIGHEST /F"; \
    Flags: runhidden waituntilterminated

[UninstallRun]
; Remove scheduled task
Filename: "schtasks.exe"; \
    Parameters: "/Delete /TN ""TealeNodeUpdateCheck"" /F"; \
    Flags: runhidden waituntilterminated

; Stop and remove service before uninstalling files
Filename: "powershell.exe"; \
    Parameters: "-ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"""; \
    Flags: runhidden waituntilterminated

[UninstallDelete]
Type: filesandordirs; Name: "{app}\models"
Type: filesandordirs; Name: "{app}\config"
Type: filesandordirs; Name: "{app}\logs"
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\version.txt"
