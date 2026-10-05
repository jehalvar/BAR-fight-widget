#ifndef AppVersion
  #define AppVersion "0.1.15"
#endif

[Setup]
AppId={{7342C7DB-CFDE-41E2-A4C0-8C2DE321110A}
AppName=BAR Fight Traits
AppVersion={#AppVersion}
VersionInfoProductName=BAR Fight
VersionInfoProductVersion={#AppVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoVersion={#AppVersion}.0
VersionInfoTextVersion={#AppVersion}.0
AppPublisher=BAR Fight
AppPublisherURL=https://bar-fight.com/
AppSupportURL=https://bar-fight.com/
DefaultDirName={localappdata}\BARFight
DefaultGroupName=BAR Fight
PrivilegesRequired=lowest
MinVersion=10.0
WizardStyle=modern
DisableProgramGroupPage=yes
DisableWelcomePage=no
OutputDir=..\dist
OutputBaseFilename=BAR-Fight-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
UninstallDisplayName=BAR Fight Traits
UninstallDisplayIcon={app}\BarFightBridge.exe
CloseApplications=no
RestartApplications=no
SetupLogging=yes
InfoBeforeFile=..\..\PRIVACY.md
#ifdef SignBuild
SignTool=BARFight
SignedUninstaller=yes
#endif

[Messages]
WelcomeLabel1=Player traits inside Beyond All Reason
WelcomeLabel2=This installs the BAR Fight widget and a small background helper. The widget shows traits from public replay history for players in your current match.%n%nThe helper fetches cached profiles using public account IDs and the map name. It does not record gameplay or upload replay files.%n%nOn the next pages, select BAR's data folder and choose whether the helper starts with Windows.

[Tasks]
Name: startup; Description: "Start the BAR Fight helper when I sign in to Windows"; Flags: unchecked
Name: autoupdate; Description: "Keep BAR Fight updated automatically (updates apply after BAR closes)"; Flags: checkedonce
Name: profiles; Description: "Fetch player profiles from bar-fight.com"; Flags: checkedonce

[Files]
Source: "..\build\BarFightBridge.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\BarFightUpdater.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\gui_bar_fight_traits.lua"; DestDir: "{code:GetBarDataDir}\LuaUI\Widgets"; Flags: ignoreversion
Source: "..\gui_bar_fight_player_list.lua"; DestDir: "{code:GetBarDataDir}\LuaUI\Widgets"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\COPYING"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\PRIVACY.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\CODE_SIGNING_POLICY.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\BAR Fight helper"; Filename: "{app}\BarFightBridge.exe"; Parameters: "--data-dir ""{code:GetBarDataDir}"""; Comment: "Start the background helper for the in-game traits widget"
Name: "{group}\BAR Fight website"; Filename: "https://bar-fight.com/"
Name: "{group}\Uninstall BAR Fight Traits"; Filename: "{uninstallexe}"

[Registry]
Root: HKCU; Subkey: "Software\BARFight"; ValueType: string; ValueName: "DataDir"; ValueData: "{code:GetBarDataDir}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "BARFightTraits"; ValueData: """{app}\BarFightBridge.exe"" --data-dir ""{code:GetBarDataDir}"""; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\BarFightBridge.exe"; Parameters: "--data-dir ""{code:GetBarDataDir}"""; Description: "Start the BAR Fight helper"; Flags: nowait postinstall skipifsilent runhidden; Check: ShouldStartHelper

[UninstallDelete]
Type: files; Name: "{code:GetBarDataDir}\LuaUI\Config\bar_fight_traits_request.json"; Check: HasBarDataDir
Type: files; Name: "{code:GetBarDataDir}\LuaUI\Config\bar_fight_traits_response.json"; Check: HasBarDataDir
Type: files; Name: "{code:GetBarDataDir}\LuaUI\Config\bar_fight_timings_request.json"; Check: HasBarDataDir
Type: files; Name: "{code:GetBarDataDir}\LuaUI\Config\bar_fight_timings_response.json"; Check: HasBarDataDir
Type: files; Name: "{app}\bar-fight.ini"

[Code]
var
  BarDirectoryPage: TInputDirWizardPage;
  UninstallDataDir: String;
  UpdatePauseCreated: Boolean;
  KeepUpdatesPaused: Boolean;

function CleanupFileAttributes(FileName: String): LongWord;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function SafeUpdateCleanupPath(const Path: String): Boolean;
var
  Current, Parent: String;
  Attributes: LongWord;
begin
  Result := False;
  Current := Path;
  while Current <> '' do begin
    Attributes := CleanupFileAttributes(Current);
    if (Attributes <> $FFFFFFFF) and ((Attributes and $400) <> 0) then Exit;
    Parent := ExtractFileDir(RemoveBackslashUnlessRoot(Current));
    if Parent = Current then Break;
    Current := Parent;
  end;
  Result := True;
end;

function DeleteOwnedUpdateFile(const RelativeName: String): Boolean;
var
  Path: String;
  Attempt: Integer;
begin
  Path := ExpandConstant('{app}\.update\') + RelativeName;
  Result := False;
  if not SafeUpdateCleanupPath(Path) then Exit;
  { A stopped updater may still be releasing its executable image. }
  for Attempt := 1 to 30 do begin
    if DirExists(Path) then Exit;
    if not FileExists(Path) then begin Result := True; Exit; end;
    if DeleteFile(Path) then begin Result := True; Exit; end;
    Sleep(100);
  end;
end;

function CleanupUpdateState(const Uninstalling: Boolean): Boolean;
var
  Names: TArrayOfString;
  I: Integer;
  Work: String;
begin
  Result := False;
  Work := ExpandConstant('{app}\.update');
  if not SafeUpdateCleanupPath(Work) then Exit;
  SetArrayLength(Names, 5);
  Names[0] := 'BarFightBridge.exe';
  Names[1] := 'BarFightUpdater.exe';
  Names[2] := 'gui_bar_fight_traits.lua';
  Names[3] := 'gui_bar_fight_player_list.lua';
  Names[4] := 'README.md';
  for I := 0 to GetArrayLength(Names) - 1 do begin
    if not DeleteOwnedUpdateFile('stage\' + Names[I]) then Exit;
    if not DeleteOwnedUpdateFile('stage\' + Names[I] + '.tmp') then Exit;
    if not DeleteOwnedUpdateFile('backup\' + Names[I]) then Exit;
    if not DeleteOwnedUpdateFile('backup\' + Names[I] + '.tmp') then Exit;
  end;
  Names[0] := 'runner.exe';
  Names[1] := 'pending.json';
  Names[2] := 'next-check';
  Names[3] := 'highest-version';
  Names[4] := 'journal.json';
  for I := 0 to GetArrayLength(Names) - 1 do begin
    { Keep the committed anti-downgrade floor across installer upgrades. }
    if (Names[I] <> 'highest-version') or Uninstalling then
      if not DeleteOwnedUpdateFile(Names[I]) then Exit;
    if not DeleteOwnedUpdateFile(Names[I] + '.tmp') then Exit;
  end;
  { RemoveDir removes empty directories only. Unrecognized files survive. }
  if SafeUpdateCleanupPath(Work + '\stage') then RemoveDir(Work + '\stage');
  if SafeUpdateCleanupPath(Work + '\backup') then RemoveDir(Work + '\backup');
  RemoveDir(Work);
  Result := True;
end;

function PauseUpdater: Boolean;
begin
  ForceDirectories(ExpandConstant('{app}'));
  Result := SaveStringToFile(ExpandConstant('{app}\update-paused'), '', False);
  UpdatePauseCreated := Result;
end;

function StopUpdater(const DataDir: String): Boolean;
var
  ResultCode: Integer;
  StopDataDir: String;
begin
  Result := True;
  if FileExists(ExpandConstant('{app}\BarFightUpdater.exe')) then begin
    StopDataDir := DataDir;
    { --stop identifies the installation by app directory, even if settings
      were removed before uninstall. It does not inspect this data directory. }
    if StopDataDir = '' then StopDataDir := ExpandConstant('{app}');
    Result := Exec(ExpandConstant('{app}\BarFightUpdater.exe'),
      '--stop --app-dir "' + ExpandConstant('{app}') + '" --data-dir "' + StopDataDir + '"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    if Result then Result := ResultCode = 0;
  end;
end;

function NormalizeBarDir(const Candidate: String): String;
begin
  Result := RemoveBackslashUnlessRoot(Trim(Candidate));
  if (not DirExists(Result + '\LuaUI')) and DirExists(Result + '\data\LuaUI') then
    Result := Result + '\data';
end;

function GetBarDataDir(Param: String): String;
begin
  if Assigned(BarDirectoryPage) then
    Result := NormalizeBarDir(BarDirectoryPage.Values[0])
  else
    Result := UninstallDataDir;
end;

function HasBarDataDir: Boolean;
begin
  Result := GetBarDataDir('') <> '';
end;

function FindRegisteredBar(RootKey: Integer): String;
var
  Names: TArrayOfString;
  I: Integer;
  Key, DisplayName, Folder: String;
begin
  Result := '';
  Key := 'Software\Microsoft\Windows\CurrentVersion\Uninstall';
  if RegGetSubkeyNames(RootKey, Key, Names) then
    for I := 0 to GetArrayLength(Names) - 1 do
      if RegQueryStringValue(RootKey, Key + '\' + Names[I], 'DisplayName', DisplayName) then
        if Pos('beyond', Lowercase(DisplayName)) > 0 then
          if Pos('reason', Lowercase(DisplayName)) > 0 then
            if RegQueryStringValue(RootKey, Key + '\' + Names[I], 'InstallLocation', Folder) then
            begin
              Folder := NormalizeBarDir(Folder);
              if DirExists(Folder + '\LuaUI') then begin Result := Folder; Exit; end;
            end;
end;

function DetectBarDir: String;
begin
  Result := ExpandConstant('{param:BARDATADIR|}');
  if Result <> '' then Exit;
  if RegQueryStringValue(HKCU, 'Software\BARFight', 'DataDir', Result) then
    if DirExists(Result + '\LuaUI') then Exit;
  Result := FindRegisteredBar(HKCU);
  if Result <> '' then Exit;
  Result := FindRegisteredBar(HKLM);
  if Result <> '' then Exit;
  Result := NormalizeBarDir(ExpandConstant('{localappdata}\Programs\Beyond-All-Reason'));
  if DirExists(Result + '\LuaUI') then Exit;
  Result := NormalizeBarDir(ExpandConstant('{localappdata}\Beyond-All-Reason'));
  if DirExists(Result + '\LuaUI') then Exit;
  Result := '';
end;

procedure InitializeWizard;
begin
  BarDirectoryPage := CreateInputDirPage(wpSelectDir, 'Choose your BAR data folder',
    'Where does Beyond All Reason store its game data?',
    'Select the data folder containing LuaUI. You can also select the BAR installation folder if it contains data\LuaUI. No replay files will be read.', False, '');
  BarDirectoryPage.Add('BAR data folder:');
  BarDirectoryPage.Values[0] := DetectBarDir;
  WizardForm.FinishedLabel.Caption := 'BAR Fight Traits is installed.' + #13#10 + #13#10 +
    'Start the helper using the Start menu shortcut whenever you play, or choose Windows startup during installation.' + #13#10 + #13#10 +
    'Restart BAR or reload its UI, then enable custom widgets if needed and enable BAR Fight Traits. Click the BAR Fight button or type /barfight. Select a player, choose a historical position, and click a trait for its evidence.' + #13#10 + #13#10 +
    'This release shows Supreme Isthmus v2.1 history from the last 30 UTC days. Each trait uses the games with the measurements it needs.';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = BarDirectoryPage.ID then
    if not DirExists(GetBarDataDir('') + '\LuaUI') then begin
      MsgBox('Choose an existing BAR data folder containing LuaUI.', mbError, MB_OK);
      Result := False;
    end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  PreviousDir: String;
  ResultCode: Integer;
begin
  Result := '';
  if (GetBarDataDir('') = '') or (not DirExists(GetBarDataDir('') + '\LuaUI')) then begin
    Result := 'The BAR data folder must already exist and contain LuaUI. Use /BARDATADIR="path" for a silent installation.';
    Exit;
  end;
  PreviousDir := GetBarDataDir('');
  if RegQueryStringValue(HKCU, 'Software\BARFight', 'DataDir', PreviousDir) then
    if CompareText(NormalizeBarDir(PreviousDir), GetBarDataDir('')) <> 0 then begin
      Result := 'BAR Fight is already installed for another BAR data folder. Uninstall BAR Fight first, then install it for the new folder.';
      Exit;
    end;
  ExtractTemporaryFile('BarFightBridge.exe');
  if (not PauseUpdater) or (not StopUpdater(PreviousDir)) then begin
    Result := 'Could not pause automatic updates. Close the BAR Fight helper and try again.';
    Exit;
  end;
  if not Exec(ExpandConstant('{tmp}\BarFightBridge.exe'), '--stop --data-dir "' + PreviousDir + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := 'Could not stop the BAR Fight helper. Close it and try installation again.'
  else if ResultCode <> 0 then
    Result := 'The BAR Fight helper did not stop in time. Close it and try installation again.';
end;

function ShouldStartHelper: Boolean;
begin
  Result := ExpandConstant('{param:NORUN|0}') = '0';
end;

function InitializeUninstall: Boolean;
var
  ResultCode: Integer;
begin
  RegQueryStringValue(HKCU, 'Software\BARFight', 'DataDir', UninstallDataDir);
  if UninstallDataDir = '' then
    UninstallDataDir := GetIniString('BAR', 'DataDir', '', ExpandConstant('{app}\bar-fight.ini'));
  Result := PauseUpdater;
  if Result then Result := StopUpdater(UninstallDataDir);
  if not Result then Exit;
  if (UninstallDataDir <> '') and FileExists(ExpandConstant('{app}\BarFightBridge.exe')) then begin
    if not Exec(ExpandConstant('{app}\BarFightBridge.exe'), '--stop --data-dir "' + UninstallDataDir + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      Result := False
    else Result := ResultCode = 0;
    if not Result then
      MsgBox('The BAR Fight helper could not be stopped. Close it and try uninstalling again.', mbError, MB_OK);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    { Files now belong to this installer; an old updater journal must never
      roll them back. Keep the maintenance gate if cleanup cannot complete. }
    KeepUpdatesPaused := True;
    if not CleanupUpdateState(False) then
      RaiseException('Could not clear previous automatic update files. Automatic updates remain paused. Close BAR Fight and run this installer again.');
    KeepUpdatesPaused := False;
    SetIniString('BAR', 'DataDir', GetBarDataDir(''), ExpandConstant('{app}\bar-fight.ini'));
    if WizardIsTaskSelected('profiles') then
      SetIniString('Privacy', 'FetchProfiles', '1', ExpandConstant('{app}\bar-fight.ini'))
    else
      SetIniString('Privacy', 'FetchProfiles', '0', ExpandConstant('{app}\bar-fight.ini'));
    if WizardIsTaskSelected('autoupdate') then
      SetIniString('Updates', 'Enabled', '1', ExpandConstant('{app}\bar-fight.ini'))
    else
      SetIniString('Updates', 'Enabled', '0', ExpandConstant('{app}\bar-fight.ini'));
    if not WizardIsTaskSelected('startup') then
      RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'BARFightTraits');
  end;
end;

procedure DeinitializeSetup;
begin
  if UpdatePauseCreated and (not KeepUpdatesPaused) then DeleteFile(ExpandConstant('{app}\update-paused'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    KeepUpdatesPaused := True;
    if not CleanupUpdateState(True) then
      RaiseException('Could not remove automatic update files. Close BAR Fight and run uninstall again.');
    KeepUpdatesPaused := False;
  end;
end;

procedure DeinitializeUninstall;
begin
  if UpdatePauseCreated and (not KeepUpdatesPaused) then DeleteFile(ExpandConstant('{app}\update-paused'));
end;
