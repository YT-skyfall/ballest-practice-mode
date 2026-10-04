; Ballest Practice Mode v1.0.1
; Built by GitHub Actions on Windows using Inno Setup 6.
; UE4SS files are bundled from the official UE4SS release and are only
; installed when a working UE4SS installation is not already detected.

#define MyAppName "Ballest Practice Mode"
#define MyAppVersion "1.0.1"
#define MyAppPublisher "Ballest Practice Mode"
#define MyAppExeName "Ballest-Win64-Shipping.exe"

[Setup]
AppId={{7A061651-3B88-40D6-A9F4-6CF4DB78CF3C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={code:GetDefaultInstallDir}
DirExistsWarning=no
DisableProgramGroupPage=yes
DisableWelcomePage=no
OutputDir=output
OutputBaseFilename=Ballest-PracticeMode-Installer
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName=Ballest Practice Mode
CreateUninstallRegKey=yes
Uninstallable=yes
SetupLogging=yes
CloseApplications=no
RestartApplications=no

[Files]
; UE4SS is a dependency. Never remove it during Practice Mode uninstall because
; other mods may depend on the same UE4SS installation.
Source: "payload\ue4ss\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs onlyifdoesntexist uninsneveruninstall; Check: ShouldInstallUE4SS

; Practice Mode itself is always installed/updated.
Source: "..\mod\PracticeMode\*"; DestDir: "{app}\ue4ss\Mods\PracticeMode"; Flags: recursesubdirs createallsubdirs ignoreversion

[UninstallDelete]
Type: filesandordirs; Name: "{app}\ue4ss\Mods\PracticeMode"

[Code]
#include "QuietUE4SS.iss"

var
  DependencyPage: TOutputMsgWizardPage;

function StripVdfValue(const Line, Key: string): string;
var
  P, I, QuoteCount, StartPos: Integer;
begin
  Result := '';
  P := Pos('"' + Key + '"', Line);
  if P = 0 then
    exit;

  QuoteCount := 0;
  StartPos := 0;

  for I := 1 to Length(Line) do
  begin
    if Line[I] = '"' then
    begin
      QuoteCount := QuoteCount + 1;
      if QuoteCount = 3 then
        StartPos := I + 1
      else if (QuoteCount = 4) and (StartPos > 0) then
      begin
        Result := Copy(Line, StartPos, I - StartPos);
        StringChangeEx(Result, '\\', '\', True);
        exit;
      end;
    end;
  end;
end;

function FindInstallDirFromLibrary(const LibraryRoot: string): string;
var
  Manifest, InstallDir, Candidate: string;
  Lines: TArrayOfString;
  I: Integer;
begin
  Result := '';
  Manifest := AddBackslash(LibraryRoot) + 'steamapps\appmanifest_3339810.acf';

  if not FileExists(Manifest) then
    exit;

  InstallDir := 'Ballest of Them All';

  if LoadStringsFromFile(Manifest, Lines) then
  begin
    for I := 0 to GetArrayLength(Lines) - 1 do
    begin
      if Pos('"installdir"', Lines[I]) > 0 then
      begin
        InstallDir := StripVdfValue(Lines[I], 'installdir');
        if InstallDir <> '' then
          break;
      end;
    end;
  end;

  Candidate :=
    AddBackslash(LibraryRoot) +
    'steamapps\common\' + InstallDir +
    '\Ballest\Binaries\Win64';

  if FileExists(AddBackslash(Candidate) + '{#MyAppExeName}') then
    Result := Candidate;
end;

function FindBallestInstallDir: string;
var
  SteamPath, LibraryFile, LibraryPath, Found: string;
  Lines: TArrayOfString;
  I: Integer;
begin
  Result := '';

  if not RegQueryStringValue(HKCU, 'Software\Valve\Steam', 'SteamPath', SteamPath) then
    RegQueryStringValue(HKLM32, 'SOFTWARE\Valve\Steam', 'InstallPath', SteamPath);

  if SteamPath = '' then
    exit;

  Found := FindInstallDirFromLibrary(SteamPath);
  if Found <> '' then
  begin
    Result := Found;
    exit;
  end;

  LibraryFile := AddBackslash(SteamPath) + 'steamapps\libraryfolders.vdf';

  if not LoadStringsFromFile(LibraryFile, Lines) then
    exit;

  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    if Pos('"path"', Lines[I]) > 0 then
    begin
      LibraryPath := StripVdfValue(Lines[I], 'path');
      if LibraryPath <> '' then
      begin
        Found := FindInstallDirFromLibrary(LibraryPath);
        if Found <> '' then
        begin
          Result := Found;
          exit;
        end;
      end;
    end;
  end;
end;

function GetDefaultInstallDir(Param: string): string;
begin
  Result := FindBallestInstallDir;

  if Result = '' then
    Result :=
      ExpandConstant('{pf32}') +
      '\Steam\steamapps\common\Ballest of Them All\Ballest\Binaries\Win64';
end;

function UE4SSAlreadyInstalled: Boolean;
begin
  Result :=
    FileExists(ExpandConstant('{app}\dwmapi.dll')) and
    FileExists(ExpandConstant('{app}\ue4ss\UE4SS.dll'));
end;

function ShouldInstallUE4SS: Boolean;
begin
  Result := not UE4SSAlreadyInstalled;
end;

procedure InitializeWizard;
begin
  DependencyPage := CreateOutputMsgPage(
    wpSelectDir,
    'Automatic dependency setup',
    'UE4SS is handled for you.',
    'Practice Mode requires UE4SS. If a working UE4SS installation is already ' +
    'present, the installer leaves its files alone. Otherwise, the compatible UE4SS ' +
    'build bundled with this installer is installed automatically.' + #13#10 + #13#10 +
    'UE4SS debug windows are hidden on launch for a cleaner experience. ' +
    'You can still open the UE4SS GUI with Ctrl+O if troubleshooting is needed.' + #13#10 + #13#10 +
    'You do not need to download UE4SS separately.'
  );
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  ExePath: string;
begin
  Result := True;

  if CurPageID = wpSelectDir then
  begin
    ExePath := AddBackslash(WizardDirValue) + '{#MyAppExeName}';

    if not FileExists(ExePath) then
    begin
      MsgBox(
        'That folder does not appear to be Ballest''s Win64 folder.' + #13#10 + #13#10 +
        'Select the folder containing Ballest-Win64-Shipping.exe.' + #13#10 + #13#10 +
        'Usually:' + #13#10 +
        '...\Steam\steamapps\common\Ballest of Them All\Ballest\Binaries\Win64',
        mbError,
        MB_OK
      );
      Result := False;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  SettingsPath, ModDir: string;
begin
  if CurStep = ssPostInstall then
  begin
    SettingsPath := ExpandConstant('{app}\ue4ss\UE4SS-settings.ini');
    ModDir := ExpandConstant('{app}\ue4ss\Mods\PracticeMode');

    ApplyQuietUE4SSWindowSettings(SettingsPath, ModDir);

    Log('Practice Mode installation complete.');
    if UE4SSAlreadyInstalled then
      Log('UE4SS detected/installed successfully.');
  end;
end;

procedure CurUninstallStepChanged(
  CurUninstallStep: TUninstallStep
);
var
  SettingsPath, ModDir: string;
begin
  if CurUninstallStep = usUninstall then
  begin
    SettingsPath := ExpandConstant('{app}\ue4ss\UE4SS-settings.ini');
    ModDir := ExpandConstant('{app}\ue4ss\Mods\PracticeMode');

    RestoreUE4SSWindowSettings(SettingsPath, ModDir);
  end;
end;
