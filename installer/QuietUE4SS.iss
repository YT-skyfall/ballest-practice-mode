// Shared UE4SS window-setting helpers.
// Included from PracticeMode.iss and PracticeMode-Uninstaller.iss inside [Code].

const
  QuietSettingsBackupName = 'ue4ss-window-settings.backup.ini';
  QuietMissingValue = '__PRACTICE_MODE_MISSING__';

function TryGetIniValue(
  const Lines: TArrayOfString;
  const SectionName, KeyName: string;
  var Value: string
): Boolean;
var
  I, P: Integer;
  S, LeftSide: string;
  InSection: Boolean;
begin
  Result := False;
  Value := '';
  InSection := False;

  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    S := Trim(Lines[I]);

    if (Length(S) >= 2) and
       (Copy(S, 1, 1) = '[') and
       (Copy(S, Length(S), 1) = ']') then
    begin
      InSection :=
        CompareText(
          Copy(S, 2, Length(S) - 2),
          SectionName
        ) = 0;
      continue;
    end;

    if InSection then
    begin
      P := Pos('=', S);

      if P > 0 then
      begin
        LeftSide := Trim(Copy(S, 1, P - 1));

        if CompareText(LeftSide, KeyName) = 0 then
        begin
          Value := Trim(Copy(S, P + 1, MaxInt));
          Result := True;
          exit;
        end;
      end;
    end;
  end;
end;

procedure InsertIniLine(
  var Lines: TArrayOfString;
  Index: Integer;
  const NewLine: string
);
var
  I, OldCount: Integer;
begin
  OldCount := GetArrayLength(Lines);

  if Index < 0 then
    Index := 0
  else if Index > OldCount then
    Index := OldCount;

  SetArrayLength(Lines, OldCount + 1);

  for I := OldCount downto Index + 1 do
    Lines[I] := Lines[I - 1];

  Lines[Index] := NewLine;
end;

procedure RemoveIniLine(
  var Lines: TArrayOfString;
  Index: Integer
);
var
  I, OldCount: Integer;
begin
  OldCount := GetArrayLength(Lines);

  if (Index < 0) or (Index >= OldCount) then
    exit;

  for I := Index to OldCount - 2 do
    Lines[I] := Lines[I + 1];

  SetArrayLength(Lines, OldCount - 1);
end;

procedure SetIniValue(
  var Lines: TArrayOfString;
  const SectionName, KeyName, NewValue: string
);
var
  I, P, SectionEnd: Integer;
  S, LeftSide: string;
  InSection, SectionFound: Boolean;
begin
  InSection := False;
  SectionFound := False;
  SectionEnd := GetArrayLength(Lines);

  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    S := Trim(Lines[I]);

    if (Length(S) >= 2) and
       (Copy(S, 1, 1) = '[') and
       (Copy(S, Length(S), 1) = ']') then
    begin
      if InSection then
      begin
        SectionEnd := I;
        break;
      end;

      InSection :=
        CompareText(
          Copy(S, 2, Length(S) - 2),
          SectionName
        ) = 0;

      if InSection then
        SectionFound := True;

      continue;
    end;

    if InSection then
    begin
      P := Pos('=', S);

      if P > 0 then
      begin
        LeftSide := Trim(Copy(S, 1, P - 1));

        if CompareText(LeftSide, KeyName) = 0 then
        begin
          Lines[I] := KeyName + ' = ' + NewValue;
          exit;
        end;
      end;
    end;
  end;

  if not SectionFound then
  begin
    if GetArrayLength(Lines) > 0 then
      InsertIniLine(Lines, GetArrayLength(Lines), '');

    InsertIniLine(
      Lines,
      GetArrayLength(Lines),
      '[' + SectionName + ']'
    );

    InsertIniLine(
      Lines,
      GetArrayLength(Lines),
      KeyName + ' = ' + NewValue
    );
    exit;
  end;

  InsertIniLine(
    Lines,
    SectionEnd,
    KeyName + ' = ' + NewValue
  );
end;

procedure RemoveIniKey(
  var Lines: TArrayOfString;
  const SectionName, KeyName: string
);
var
  I, P: Integer;
  S, LeftSide: string;
  InSection: Boolean;
begin
  InSection := False;
  I := 0;

  while I < GetArrayLength(Lines) do
  begin
    S := Trim(Lines[I]);

    if (Length(S) >= 2) and
       (Copy(S, 1, 1) = '[') and
       (Copy(S, Length(S), 1) = ']') then
    begin
      InSection :=
        CompareText(
          Copy(S, 2, Length(S) - 2),
          SectionName
        ) = 0;
      I := I + 1;
      continue;
    end;

    if InSection then
    begin
      P := Pos('=', S);

      if P > 0 then
      begin
        LeftSide := Trim(Copy(S, 1, P - 1));

        if CompareText(LeftSide, KeyName) = 0 then
        begin
          RemoveIniLine(Lines, I);
          exit;
        end;
      end;
    end;

    I := I + 1;
  end;
end;

function QuietSettingsBackupPath(const ModDir: string): string;
begin
  Result := AddBackslash(ModDir) + QuietSettingsBackupName;
end;

procedure BackupOriginalUE4SSWindowSettings(
  const SettingsPath, ModDir: string
);
var
  SettingsLines, BackupLines: TArrayOfString;
  Value, BackupPath: string;
begin
  BackupPath := QuietSettingsBackupPath(ModDir);

  if FileExists(BackupPath) or
     (not FileExists(SettingsPath)) then
    exit;

  if not LoadStringsFromFile(SettingsPath, SettingsLines) then
    exit;

  SetArrayLength(BackupLines, 4);
  BackupLines[0] := '[Debug]';

  if TryGetIniValue(SettingsLines, 'Debug', 'ConsoleEnabled', Value) then
    BackupLines[1] := 'ConsoleEnabled = ' + Value
  else
    BackupLines[1] := 'ConsoleEnabled = ' + QuietMissingValue;

  if TryGetIniValue(SettingsLines, 'Debug', 'GuiConsoleEnabled', Value) then
    BackupLines[2] := 'GuiConsoleEnabled = ' + Value
  else
    BackupLines[2] := 'GuiConsoleEnabled = ' + QuietMissingValue;

  if TryGetIniValue(SettingsLines, 'Debug', 'GuiConsoleVisible', Value) then
    BackupLines[3] := 'GuiConsoleVisible = ' + Value
  else
    BackupLines[3] := 'GuiConsoleVisible = ' + QuietMissingValue;

  SaveStringsToFile(BackupPath, BackupLines, False);
end;

procedure ApplyQuietUE4SSWindowSettings(
  const SettingsPath, ModDir: string
);
var
  Lines: TArrayOfString;
begin
  if not FileExists(SettingsPath) then
  begin
    Log(
      'UE4SS settings file was not found; window settings were not changed.'
    );
    exit;
  end;

  BackupOriginalUE4SSWindowSettings(SettingsPath, ModDir);

  if not LoadStringsFromFile(SettingsPath, Lines) then
  begin
    Log('Could not read UE4SS-settings.ini.');
    exit;
  end;

  SetIniValue(Lines, 'Debug', 'ConsoleEnabled', '0');
  SetIniValue(Lines, 'Debug', 'GuiConsoleEnabled', '1');
  SetIniValue(Lines, 'Debug', 'GuiConsoleVisible', '0');

  if SaveStringsToFile(SettingsPath, Lines, False) then
    Log('UE4SS debug windows configured to stay hidden on launch.')
  else
    Log('Could not save UE4SS window settings.');
end;

procedure RestoreUE4SSWindowSettings(
  const SettingsPath, ModDir: string
);
var
  Lines, BackupLines: TArrayOfString;
  BackupPath, CurrentValue, OriginalValue: string;
begin
  BackupPath := QuietSettingsBackupPath(ModDir);

  if (not FileExists(BackupPath)) or
     (not FileExists(SettingsPath)) then
    exit;

  if not LoadStringsFromFile(SettingsPath, Lines) then
    exit;

  if not LoadStringsFromFile(BackupPath, BackupLines) then
    exit;

  if TryGetIniValue(
       Lines,
       'Debug',
       'ConsoleEnabled',
       CurrentValue
     ) and
     (CurrentValue = '0') and
     TryGetIniValue(
       BackupLines,
       'Debug',
       'ConsoleEnabled',
       OriginalValue
     ) then
  begin
    if OriginalValue = QuietMissingValue then
      RemoveIniKey(Lines, 'Debug', 'ConsoleEnabled')
    else
      SetIniValue(
        Lines,
        'Debug',
        'ConsoleEnabled',
        OriginalValue
      );
  end;

  if TryGetIniValue(
       Lines,
       'Debug',
       'GuiConsoleEnabled',
       CurrentValue
     ) and
     (CurrentValue = '1') and
     TryGetIniValue(
       BackupLines,
       'Debug',
       'GuiConsoleEnabled',
       OriginalValue
     ) then
  begin
    if OriginalValue = QuietMissingValue then
      RemoveIniKey(Lines, 'Debug', 'GuiConsoleEnabled')
    else
      SetIniValue(
        Lines,
        'Debug',
        'GuiConsoleEnabled',
        OriginalValue
      );
  end;

  if TryGetIniValue(
       Lines,
       'Debug',
       'GuiConsoleVisible',
       CurrentValue
     ) and
     (CurrentValue = '0') and
     TryGetIniValue(
       BackupLines,
       'Debug',
       'GuiConsoleVisible',
       OriginalValue
     ) then
  begin
    if OriginalValue = QuietMissingValue then
      RemoveIniKey(Lines, 'Debug', 'GuiConsoleVisible')
    else
      SetIniValue(
        Lines,
        'Debug',
        'GuiConsoleVisible',
        OriginalValue
      );
  end;

  if SaveStringsToFile(SettingsPath, Lines, False) then
    Log('Restored the previous UE4SS debug-window settings.');
end;
