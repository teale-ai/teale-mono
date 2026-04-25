; TealeNode Inno Setup Script
;
; Builds a self-contained installer: extracts all binaries, shows the
; contributor a 2-page wizard (Welcome, Behavior), registers Teale as a
; Windows service, and launches the local Teale companion window so the
; contributor can choose/download the recommended model after install.
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
#define AppVer "2026.04.24.2142"

[Setup]
AppId={{E314A631-5889-4A53-B275-D90DF6F4A4F1}
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
Source: "supabase-config.json"; DestDir: "{app}\config"; Flags: ignoreversion skipifsourcedoesntexist

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
; Start-menu shortcut to open the local Teale companion window.
Name: "{group}\Open Teale"; Filename: "{app}\bin\teale-tray.exe"; Parameters: "--open-window"

[Registry]
; Register the Teale deep-link protocol for browser-based OAuth callbacks.
Root: HKCR; Subkey: "teale"; ValueType: string; ValueName: ""; ValueData: "URL:Teale Protocol"; Flags: uninsdeletekey
Root: HKCR; Subkey: "teale"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCR; Subkey: "teale\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\bin\teale-tray.exe,0"; Flags: uninsdeletekey
Root: HKCR; Subkey: "teale\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\bin\teale-tray.exe"" ""%1"""; Flags: uninsdeletekey

[Tasks]
Name: "installtray"; Description: "Run Teale Tray at login (shows live status and earnings)"; \
    GroupDescription: "Optional:"; Flags: checkedonce

[Run]
; Run post-install: pass whether the user opted into lid-closed supply.
Filename: "powershell.exe"; \
    Parameters: "-ExecutionPolicy Bypass -File ""{app}\post-install.ps1"" -InstallDir ""{app}"" -AllowSupplyLidClosed ""{code:GetLidClosedFlag}"" -PreservedModelsDir ""{code:GetPreservedModelsDir}"""; \
    StatusMsg: "Configuring Teale and starting service..."; \
    Flags: runhidden waituntilterminated

; Launch the tray immediately after install and open the companion window.
Filename: "{app}\bin\teale-tray.exe"; Parameters: "--open-window"; Description: "Launch Teale now"; \
    Flags: postinstall skipifsilent nowait skipifdoesntexist

; Write version file.
Filename: "powershell.exe"; \
    Parameters: "-ExecutionPolicy Bypass -Command ""Set-Content -Path '{app}\version.txt' -Value 'v{#AppVer}' -Encoding UTF8"""; \
    Flags: runhidden waituntilterminated

; Register on-logon update-check scheduled task.
Filename: "schtasks.exe"; \
    Parameters: "/Create /TN ""TealeUpdateCheck"" /TR ""powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File '{app}\check-update.ps1' -Quiet"" /SC ONLOGON /RU SYSTEM /RL HIGHEST /F"; \
    Flags: runhidden waituntilterminated

; Register a periodic background updater that can download/install silently
; according to the user's saved updater settings.
Filename: "schtasks.exe"; \
    Parameters: "/Create /TN ""TealeBackgroundUpdate"" /TR ""powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File '{app}\check-update.ps1' -Quiet"" /SC HOURLY /MO 6 /RU SYSTEM /RL HIGHEST /F"; \
    Flags: runhidden waituntilterminated

[UninstallRun]
Filename: "schtasks.exe"; Parameters: "/Delete /TN ""TealeUpdateCheck"" /F"; Flags: runhidden waituntilterminated
Filename: "schtasks.exe"; Parameters: "/Delete /TN ""TealeBackgroundUpdate"" /F"; Flags: runhidden waituntilterminated
Filename: "powershell.exe"; \
    Parameters: "-ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"""; \
    Flags: runhidden waituntilterminated

[UninstallDelete]
Type: filesandordirs; Name: "{app}\config"
Type: filesandordirs; Name: "{app}\logs"
; Leave {app}\data intact so the identity key survives reinstalls — this
; preserves credit-earning history. Manual `rm -r C:\Teale\data` if the user
; really wants a fresh identity.
; Leave {app}\models intact so downloaded GGUFs survive uninstall/reinstall.
; Manual deletion is still possible if the user wants to reclaim disk space.
Type: files; Name: "{app}\version.txt"

[Code]
var
  WelcomePage: TOutputMsgWizardPage;
  BehaviorPage: TInputOptionWizardPage;
  PreservedModelsDir: String;

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
    'You can pause supply or close the tray icon any time without uninstalling it.' + #13#10 + #13#10 +
    'Needs: Windows 10/11, 16 GB RAM or more. After install, Teale recommends the best model for this machine and downloads it in the app window.'
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

// Stop the existing TealeNode service and the per-user tray process
// before [Files] extraction — otherwise a reinstall hits
// "DeleteFile failed; code 5. Access is denied." on teale-node.exe
// because the running service holds it open. Called from
// PrepareToInstall, which fires after the wizard and before extraction.
procedure StopExistingInstall;
var
  ResultCode: Integer;
  NssmPath: String;
begin
  NssmPath := ExpandConstant('{app}\bin\nssm.exe');

  // Prefer NSSM's stop (it handles child-process cleanup); fall back to
  // sc.exe if NSSM isn't there yet (first-time install).
  if FileExists(NssmPath) then
    Exec(NssmPath, 'stop TealeNode', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
  else
    Exec(ExpandConstant('{sys}\sc.exe'), 'stop TealeNode', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Give Windows Service Control Manager a moment to release file
  // handles — sc stop returns before the worker has fully drained.
  Sleep(3000);

  // Kill any lingering teale-tray.exe (per-user, not a service).
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM teale-tray.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Also kill any orphaned llama-server.exe that the node spawned — it
  // holds ggml-*.dll and vulkan-*.dll open too.
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM llama-server.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function QuoteForPowerShell(const Value: String): String;
begin
  Result := #34 + Value + #34;
end;

function FindExistingUninstaller(): String;
var
  FindRec: TFindRec;
begin
  Result := '';
  if FindFirst(ExpandConstant('{app}\unins*.exe'), FindRec) then
  begin
    try
      Result := ExpandConstant('{app}\') + FindRec.Name;
    finally
      FindClose(FindRec);
    end;
  end;
end;

procedure PreserveExistingModels;
var
  ResultCode: Integer;
  SourceDir: String;
  Command: String;
begin
  SourceDir := ExpandConstant('{app}\models');
  PreservedModelsDir := ExpandConstant('{commonappdata}\Teale\installer-preserved-models');

  if not DirExists(SourceDir) then
    exit;

  Command :=
    '$source=' + QuoteForPowerShell(SourceDir) + ';' +
    '$dest=' + QuoteForPowerShell(PreservedModelsDir) + ';' +
    'if (!(Test-Path -LiteralPath $source)) { exit 0 };' +
    'if (!(Test-Path -LiteralPath $dest)) {' +
      'Move-Item -LiteralPath $source -Destination $dest -Force;' +
      'exit 0' +
    '};' +
    'Get-ChildItem -LiteralPath $source -Force -ErrorAction SilentlyContinue | ForEach-Object {' +
      'Move-Item -LiteralPath $_.FullName -Destination $dest -Force' +
    '};' +
    'Remove-Item -LiteralPath $source -Force -Recurse -ErrorAction SilentlyContinue;' +
    'exit 0';

  if not Exec('powershell.exe',
    '-ExecutionPolicy Bypass -NoProfile -Command ' + AddQuotes(Command),
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    RaiseException('Failed to preserve previously downloaded models before upgrade.');
  end;

  if ResultCode <> 0 then
    RaiseException('Preserving previously downloaded models failed with exit code ' + IntToStr(ResultCode) + '.');
end;

procedure UninstallExistingInstall;
var
  ResultCode: Integer;
  UninstallerPath: String;
begin
  UninstallerPath := FindExistingUninstaller();
  if UninstallerPath = '' then
    exit;

  if not Exec(UninstallerPath, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    RaiseException('Failed to launch the existing Teale uninstaller.');
  end;

  if ResultCode <> 0 then
    RaiseException('The existing Teale install could not be removed cleanly (exit code ' + IntToStr(ResultCode) + ').');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  PreservedModelsDir := ExpandConstant('{commonappdata}\Teale\installer-preserved-models');
  StopExistingInstall;
  PreserveExistingModels;
  UninstallExistingInstall;
  StopExistingInstall;
  Result := ''; // empty string = success
end;

function GetPreservedModelsDir(Param: String): String;
begin
  Result := PreservedModelsDir;
end;

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
