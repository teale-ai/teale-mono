; TealeNode Inno Setup Script
;
; Builds a self-contained installer: extracts all binaries, shows the
; contributor a 2-page wizard (Welcome, Behavior), downloads the model
; with a visible progress bar, and registers Teale as a Windows service.
;
; Build steps:
;   1. Install Inno Setup 6 from https://jrsoftware.org/isinfo.php
;   2. (First time only) place these files next to this .iss:
;      - teale-node.exe   (cargo build --release --target x86_64-pc-windows-msvc)
;      - teale-tray.exe   (cargo build --release --bin teale-tray)
;      - llama-server.exe (from llama.cpp's Vulkan build — `llama-bXXXX-bin-win-vulkan-x64.zip`)
;      - ggml-*.dll, vulkan-*.dll and any runtime DLLs from the llama-server zip
;      - nssm.exe         (from nssm-2.24/win64/nssm.exe)
;      - post-install.ps1, uninstall.ps1, check-update.ps1 (already in this dir)
;   3. Open this file in Inno Setup Compiler → Build → Compile
;   4. Output: output/Teale.exe (ready to upload to Google Drive)

; Timestamp-style version to match mac-app's CFBundleShortVersionString
; (see mac-app/Sources/InferencePoolApp/Info.plist). Bump for every release.
#define AppVer "2026.04.21.2002"

; NOTE: pilot builds rely on post-install.ps1's Start-BitsTransfer for the
; ~5.7 GB model download. A follow-up release will wire in Inno Download
; Plugin for an inline progress bar inside the wizard UI.

[Setup]
AppName=Teale
AppVersion={#AppVer}
AppPublisher=Teale AI
AppPublisherURL=https://teale.com
DefaultDirName=C:\Teale
DefaultGroupName=Teale
OutputBaseFilename=Teale
OutputDir=output
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
DisableProgramGroupPage=yes
DisableDirPage=yes
SetupIconFile=compiler:SetupClassicIcon.ico
; Min Windows 10 (build 17763 / 1809). Earlier Win10 lacks Modern Standby
; and several PowerShell niceties we use in post-install.
MinVersion=10.0.17763
; Upgrade-in-place: run silently when the same app is already installed and
; the service is running. Rerunning with -Uninstall in deploy-windows.ps1
; works independently.
UninstallDisplayName=Teale — Distributed AI Inference
UninstallDisplayIcon={app}\bin\teale-node.exe
WizardStyle=modern
WizardSizePercent=120

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Binaries → C:\Teale\bin
Source: "teale-node.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "teale-tray.exe"; DestDir: "{app}\bin"; Flags: ignoreversion skipifsourcedoesntexist
Source: "llama-server.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "nssm.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
; Runtime DLLs from the llama-server Vulkan zip (ggml-*.dll, vulkan-*.dll)
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

[Icons]
; Per-user auto-start for the tray app so it appears at login. Service
; itself (machine-level, via NSSM) starts independently at boot.
Name: "{userstartup}\Teale Tray"; Filename: "{app}\bin\teale-tray.exe"; \
    WorkingDir: "{app}"; Tasks: installtray
; Start-menu shortcut to open the Teale dashboard in the default browser.
Name: "{group}\Open Teale Dashboard"; Filename: "https://teale.com/supply"

[Tasks]
Name: "installtray"; Description: "Run Teale Tray at login (shows live status and earnings)"; \
    GroupDescription: "Optional:"; Flags: checkedonce

[Run]
; Run post-install: pass whether the user opted into lid-closed supply.
Filename: "powershell.exe"; \
    Parameters: "-ExecutionPolicy Bypass -File ""{app}\post-install.ps1"" -InstallDir ""{app}"" -AllowSupplyLidClosed ""{code:GetLidClosedFlag}"""; \
    StatusMsg: "Configuring Teale and starting service..."; \
    Flags: runhidden waituntilterminated

; Launch the tray immediately after install (per-user process).
Filename: "{app}\bin\teale-tray.exe"; Description: "Launch Teale Tray now"; \
    Flags: postinstall skipifsilent nowait skipifdoesntexist

; Write version file.
Filename: "powershell.exe"; \
    Parameters: "-ExecutionPolicy Bypass -Command ""Set-Content -Path '{app}\version.txt' -Value 'v{#AppVer}' -Encoding UTF8"""; \
    Flags: runhidden waituntilterminated

; Register on-logon update-check scheduled task.
Filename: "schtasks.exe"; \
    Parameters: "/Create /TN ""TealeUpdateCheck"" /TR ""powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File '{app}\check-update.ps1'"" /SC ONLOGON /RL HIGHEST /F"; \
    Flags: runhidden waituntilterminated

[UninstallRun]
Filename: "schtasks.exe"; Parameters: "/Delete /TN ""TealeUpdateCheck"" /F"; Flags: runhidden waituntilterminated
Filename: "powershell.exe"; \
    Parameters: "-ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"""; \
    Flags: runhidden waituntilterminated

[UninstallDelete]
Type: filesandordirs; Name: "{app}\models"
Type: filesandordirs; Name: "{app}\config"
Type: filesandordirs; Name: "{app}\logs"
; Leave {app}\data intact so the identity key survives reinstalls — this
; preserves credit-earning history. Manual `rm -r C:\Teale\data` if the user
; really wants a fresh identity.
Type: files; Name: "{app}\version.txt"

[Code]
var
  WelcomePage: TOutputMsgWizardPage;
  BehaviorPage: TInputOptionWizardPage;

procedure InitializeWizard;
begin
  // Welcome — plain-English "what this is"
  WelcomePage := CreateOutputMsgPage(
    wpWelcome,
    'Welcome to Teale',
    'How Teale uses your laptop',
    'Teale earns you credits by renting a small slice of your computer''s idle CPU/GPU ' +
    'to run AI inference for other people.' + #13#10 + #13#10 +
    'It only runs when you''re plugged in to AC power. It pauses automatically on battery.' + #13#10 +
    'It runs at a lower priority than your own apps — you won''t notice it while you work.' + #13#10 +
    'You can pause or quit it any time from the system tray.' + #13#10 + #13#10 +
    'Needs: Windows 10/11, 16 GB RAM or more, ~6 GB free disk for the model download.'
  );

  // Behavior — one checkbox, pre-checked, for lid-closed supply
  BehaviorPage := CreateInputOptionPage(
    WelcomePage.ID,
    'Supply behavior',
    'When should Teale supply inference?',
    'Teale will always pause on battery. When the lid is closed on AC power, would you ' +
    'like to keep supplying? (Screen turns off, Wi-Fi stays on, fans may spin up slightly.)',
    False, False
  );
  BehaviorPage.Add('Keep supplying when the lid is closed (AC only) — recommended');
  BehaviorPage.Values[0] := True;
end;

function GetLidClosedFlag(Param: String): String;
begin
  if (BehaviorPage <> nil) and BehaviorPage.Values[0] then
    Result := '1'
  else
    Result := '0';
end;

// RAM gate at the wizard level using a direct kernel32 import —
// Inno Setup's built-in Pascal doesn't define TMemoryStatusEx, so we
// declare it ourselves and call GlobalMemoryStatusEx as an external
// function. Rejects <16 GB machines with a friendly message before
// anything is extracted.
type
  TMemoryStatusEx = record
    dwLength: Cardinal;
    dwMemoryLoad: Cardinal;
    ullTotalPhys: Int64;
    ullAvailPhys: Int64;
    ullTotalPageFile: Int64;
    ullAvailPageFile: Int64;
    ullTotalVirtual: Int64;
    ullAvailVirtual: Int64;
    ullAvailExtendedVirtual: Int64;
  end;

function GlobalMemoryStatusEx(var lpBuffer: TMemoryStatusEx): Boolean;
  external 'GlobalMemoryStatusEx@kernel32.dll stdcall';

function InitializeSetup(): Boolean;
var
  MemStatus: TMemoryStatusEx;
  RamGB: Integer;
begin
  MemStatus.dwLength := SizeOf(MemStatus);
  if GlobalMemoryStatusEx(MemStatus) then
  begin
    RamGB := Round(MemStatus.ullTotalPhys / 1073741824);
    if RamGB < 16 then
    begin
      MsgBox('Teale requires 16 GB of RAM or more. This machine has ' + IntToStr(RamGB) + ' GB.' + #13#10 + #13#10 +
             'Support for smaller devices is coming — we''ll email you when it''s ready.',
             mbInformation, MB_OK);
      Result := False;
      exit;
    end;
  end;
  Result := True;
end;

// Pilot: the 5.7 GB model download happens inside post-install.ps1 via
// BITS. The installer wizard shows "Configuring Teale and starting
// service..." while that runs. A follow-up release will move the download
// here with Inno Download Plugin so users see a real progress bar.
