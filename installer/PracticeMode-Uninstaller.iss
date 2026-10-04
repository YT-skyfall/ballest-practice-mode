; Ballest Practice Mode standalone uninstaller
; Removes only Practice Mode. UE4SS and all other mods are intentionally preserved.

#define MyAppName "Ballest Practice Mode Uninstaller"
#define MyAppVersion "1.0.0"
#define BallestExe "Ballest-Win64-Shipping.exe"

[Setup]
AppId={{A8F67E61-73E0-46B7-A04D-B95DA5278CC6}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={tmp}
CreateAppDir=no
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
DisableWelcomePage=yes
OutputDir=output
OutputBaseFilename=Ballest-PracticeMode-Uninstaller
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Uninstallable=no
SetupLogging=yes
CloseApplications=no
RestartApplications=no

[Code]
#include "QuietUE4SS.iss"

const
  PracticeModeUninstallKey =
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
    '{7A061651-3B88-40D6-A9F4-6CF4DB78CF3C}_is1';

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

  if FileExists(AddBackslash(Candidate) + '{#BallestExe}') then
    Result := Candidate;
end;

function FindBallestFromSteam: string;
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

function ReadInstallLocationFromRegistry: string;
begin
  Result := '';

  if RegQueryStringValue(
       HKLM64,
       PracticeModeUninstallKey,
       'InstallLocation',
       Result
     ) then
    exit;

  if RegQueryStringValue(
       HKLM32,
       PracticeModeUninstallKey,
       'InstallLocation',
       Result
     ) then
    exit;

  RegQueryStringValue(
    HKCU,
    PracticeModeUninstallKey,
    'InstallLocation',
    Result
  );
end;

function ReadOriginalUninstallString: string;
begin
  Result := '';

  if RegQueryStringValue(
       HKLM64,
       PracticeModeUninstallKey,
       'UninstallString',
       Result
     ) then
    exit;

  if RegQueryStringValue(
       HKLM32,
       PracticeModeUninstallKey,
       'UninstallString',
       Result
     ) then
    exit;

  RegQueryStringValue(
    HKCU,
    PracticeModeUninstallKey,
    'UninstallString',
    Result
  );
end;

function ExtractExePath(const CommandLine: string): string;
var
  S: string;
  P: Integer;
begin
  Result := '';
  S := Trim(CommandLine);

  if S = '' then
    exit;

  if Copy(S, 1, 1) = '"' then
  begin
    Delete(S, 1, 1);
    P := Pos('"', S);

    if P > 0 then
      Result := Copy(S, 1, P - 1)
    else
      Result := S;
  end
  else
  begin
    P := Pos(' ', S);

    if P > 0 then
      Result := Copy(S, 1, P - 1)
    else
      Result := S;
  end;
end;

procedure RemoveOriginalUninstallRegistration;
var
  UninstallCommand, UninstallExe, UninstallData, UninstallMsg: string;
begin
  UninstallCommand := ReadOriginalUninstallString;
  UninstallExe := ExtractExePath(UninstallCommand);

  RegDeleteKeyIncludingSubkeys(HKLM64, PracticeModeUninstallKey);
  RegDeleteKeyIncludingSubkeys(HKLM32, PracticeModeUninstallKey);
  RegDeleteKeyIncludingSubkeys(HKCU, PracticeModeUninstallKey);

  if UninstallExe <> '' then
  begin
    UninstallData := ChangeFileExt(UninstallExe, '.dat');
    UninstallMsg := ChangeFileExt(UninstallExe, '.msg');

    DeleteFile(UninstallData);
    DeleteFile(UninstallMsg);
    DeleteFile(UninstallExe);
  end;
end;

function FindBallestInstallDir: string;
begin
  Result := ReadInstallLocationFromRegistry;

  if (Result <> '') and
     FileExists(AddBackslash(Result) + '{#BallestExe}') then
    exit;

  Result := FindBallestFromSteam;
end;

function InitializeSetup(): Boolean;
var
  BallestDir, ModDir, SettingsPath: string;
begin
  Result := False;

  if MsgBox(
       'Remove Ballest Practice Mode?' + #13#10 + #13#10 +
       'This removes only Practice Mode.' + #13#10 +
       'UE4SS and all other mods will be left untouched.',
       mbConfirmation,
       MB_YESNO
     ) <> IDYES then
    exit;

  BallestDir := FindBallestInstallDir;

  if BallestDir = '' then
  begin
    MsgBox(
      'Ballest of Them All could not be found automatically.' + #13#10 + #13#10 +
      'Practice Mode was not changed.',
      mbError,
      MB_OK
    );
    exit;
  end;

  ModDir := AddBackslash(BallestDir) + 'ue4ss\Mods\PracticeMode';
  SettingsPath := AddBackslash(BallestDir) + 'ue4ss\UE4SS-settings.ini';

  RestoreUE4SSWindowSettings(SettingsPath, ModDir);

  if DirExists(ModDir) then
  begin
    if not DelTree(ModDir, True, True, True) then
    begin
      MsgBox(
        'Practice Mode could not be removed.' + #13#10 + #13#10 +
        'Close Ballest and try again.',
        mbError,
        MB_OK
      );
      exit;
    end;
  end;

  RemoveOriginalUninstallRegistration;

  MsgBox(
    'Ballest Practice Mode has been removed.' + #13#10 + #13#10 +
    'UE4SS and your other mods were left untouched.',
    mbInformation,
    MB_OK
  );
end;
