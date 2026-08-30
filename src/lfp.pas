program lfp;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes,
  lfp_value, lfp_vm
  {$IFDEF UNIX}, Termio, BaseUnix{$ENDIF};

const
  LFP_VERSION = '1.0.0';
  REPL_HISTORY_LIMIT = 100;
  REPL_PASTE_START = #27'[200~';
  REPL_PASTE_END = #27'[201~';
  REPL_PASTE_ENABLE = #27'[?2004h';
  REPL_PASTE_DISABLE = #27'[?2004l';
  ANSI_RESET = #27'[0m';
  ANSI_BOLD_CYAN = #27'[1;36m';
  ANSI_DIM_CYAN = #27'[2;36m';
  ANSI_BOLD_GREEN = #27'[1;32m';
  ANSI_BOLD_RED = #27'[1;31m';

type
  TReplTerminal = record
    Active: Boolean;
    {$IFDEF UNIX}
    Original: TermIOS;
    {$ENDIF}
  end;

function ReplIsInteractive: Boolean;
begin
  {$IFDEF UNIX}
  Result := (Termio.IsATTY(Input) <> 0) and (Termio.IsATTY(Output) <> 0);
  {$ELSE}
  Result := IsConsole;
  {$ENDIF}
end;

function ReplUseStyle(Interactive: Boolean): Boolean;
begin
  {$IFDEF UNIX}
  Result := Interactive and (GetEnvironmentVariable('NO_COLOR') = '') and
    not SameText(GetEnvironmentVariable('TERM'), 'dumb');
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

procedure BeginReplTerminal(var Terminal: TReplTerminal; Interactive: Boolean);
{$IFDEF UNIX}
var
  Mode: TermIOS;
{$ENDIF}
begin
  Terminal.Active := False;
  {$IFDEF UNIX}
  if not Interactive then Exit;
  if Termio.TCGetAttr(0, Terminal.Original) <> 0 then Exit;
  Mode := Terminal.Original;
  Mode.c_lflag := Mode.c_lflag and
    not (Termio.ICANON or Termio.ECHO or Termio.ISIG);
  Mode.c_cc[Termio.VMIN] := 1;
  Mode.c_cc[Termio.VTIME] := 0;
  Terminal.Active := Termio.TCSetAttr(0, Termio.TCSANOW, Mode) = 0;
  {$ENDIF}
end;

procedure EndReplTerminal(var Terminal: TReplTerminal);
begin
  {$IFDEF UNIX}
  if Terminal.Active then
    Termio.TCSetAttr(0, Termio.TCSANOW, Terminal.Original);
  {$ENDIF}
  Terminal.Active := False;
end;

procedure WriteReplPrompt(Depth: Integer; Complete, Styled: Boolean);
begin
  if Styled then
  begin
    if (Depth = 0) and Complete then
      Write(ANSI_BOLD_CYAN, 'lfp', ANSI_RESET, ANSI_DIM_CYAN, '> ', ANSI_RESET)
    else
      Write(ANSI_DIM_CYAN, '...', Depth, '> ', ANSI_RESET);
  end
  else if (Depth = 0) and Complete then Write('lfp> ')
  else Write('...', Depth, '> ');
  Flush(Output);
end;

procedure WritePastePrompt(Styled: Boolean);
begin
  if Styled then Write(ANSI_DIM_CYAN, 'paste> ', ANSI_RESET)
  else Write('paste> ');
  Flush(Output);
end;

procedure WriteReplResult(const V: TLfpValue; Styled: Boolean);
begin
  if Styled then Writeln(ANSI_BOLD_GREEN, '=> ', ANSI_RESET, LfpValueInspect(V))
  else Writeln('=> ', LfpValueInspect(V));
end;

procedure WriteReplError(const Msg: string; Styled: Boolean);
begin
  if Styled then Writeln(StdErr, ANSI_BOLD_RED, 'repl: ', ANSI_RESET, Msg)
  else Writeln(StdErr, 'repl: ', Msg);
end;

procedure Banner;
begin
  Writeln('Lispal / LFP ', LFP_VERSION, ' (basically) Lisp Flavored Pascal');
  Writeln('bytecode VM + native JIT + embeddable scripting runtime');
end;

procedure Usage;
begin
  Banner;
  Writeln;
  Writeln('usage:');
  Writeln('  lfp script.lfp [args ...]');
  Writeln('  lfp script.lpas [args ...]');
  Writeln('  lfp -e "(writeln (+ 20 22))"');
  Writeln('  lfp --repl');
  Writeln('  lfp --dump-bytecode script.lfp');
  Writeln('  lfp --trace script.lfp');
  Writeln('  lfp --jit script.lfp');
  Writeln('  lfp --no-jit script.lfp');
  Writeln('  lfp --jit-status');
  Writeln('  lfp --version');
end;

procedure SourceBalance(const S: string; out Depth: Integer;
  out Complete: Boolean);
var
  I: Integer;
  InString, Escaped, InLineComment, InBraceComment: Boolean;
begin
  Depth := 0;
  InString := False;
  Escaped := False;
  InLineComment := False;
  InBraceComment := False;
  I := 1;
  while I <= Length(S) do
  begin
    if InLineComment then
    begin
      if S[I] = #10 then InLineComment := False;
      Inc(I);
      Continue;
    end;
    if InBraceComment then
    begin
      if S[I] = '}' then InBraceComment := False;
      Inc(I);
      Continue;
    end;
    if InString then
    begin
      if Escaped then Escaped := False
      else if S[I] = '\' then Escaped := True
      else if S[I] = '"' then InString := False;
      Inc(I);
      Continue;
    end;
    if S[I] = '"' then InString := True
    else if S[I] = '{' then InBraceComment := True
    else if S[I] = ';' then InLineComment := True
    else if (S[I] = '/') and (I < Length(S)) and (S[I + 1] = '/') then
    begin
      InLineComment := True;
      Inc(I);
    end
    else if S[I] = '(' then Inc(Depth)
    else if S[I] = ')' then Dec(Depth);
    Inc(I);
  end;
  Complete := not InString and not InBraceComment;
end;

procedure SetupArgs(Engine: TLfpEngine; FirstArg: Integer);
var
  A: TLfpArrayObject;
  I: Integer;
begin
  A := TLfpArrayObject(Engine.OwnObject(TLfpArrayObject.Create(0)));
  for I := FirstArg to ParamCount do
    A.Append(LfpString(UTF8Decode(ParamStr(I))));
  Engine.DefineGlobal('argv', 'Array', False, LfpObject(A), True);
  Engine.DefineGlobal('argc', 'Integer', False, LfpInt(A.Length), True);
end;

function ReplArg(const Line: string): string;
var
  T: string;
  P: Integer;
begin
  T := Trim(Line);
  P := 1;
  while (P <= Length(T)) and not (T[P] in [' ', #9]) do Inc(P);
  while (P <= Length(T)) and (T[P] in [' ', #9]) do Inc(P);
  if P > Length(T) then Exit('');
  Result := Trim(Copy(T, P, MaxInt));
  if (Length(Result) >= 2) and
     (((Result[1] = '"') and (Result[Length(Result)] = '"')) or
      ((Result[1] = '''') and (Result[Length(Result)] = ''''))) then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

function ReplCommandName(const Line: string): string;
var
  T: string;
  P: Integer;
begin
  T := Trim(Line);
  P := 1;
  while (P <= Length(T)) and not (T[P] in [' ', #9]) do Inc(P);
  Result := LowerCase(Copy(T, 1, P - 1));
end;

procedure AddReplHistory(History: TStrings; const Source: string);
begin
  if Trim(Source) = '' then Exit;
  if (History.Count = 0) or (History[History.Count - 1] <> Source) then
    History.Add(Source);
  while History.Count > REPL_HISTORY_LIMIT do History.Delete(0);
end;

function ReplHistoryPreview(const Source: string): string;
begin
  Result := StringReplace(Source, #13#10, '  ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '  ', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '  ', [rfReplaceAll]);
  Result := Trim(Result);
  if Length(Result) > 72 then Result := Copy(Result, 1, 69) + '...';
end;

procedure PrintReplHistory(History: TStrings; Count: Integer);
var
  I, First: Integer;
begin
  if History.Count = 0 then
  begin
    Writeln('(history is empty)');
    Exit;
  end;
  if (Count <= 0) or (Count > History.Count) then Count := History.Count;
  First := History.Count - Count;
  for I := First to History.Count - 1 do
    Writeln(Format('%4d  %s', [I + 1, ReplHistoryPreview(History[I])]));
end;

procedure AppendReplSource(var Source: string; const Line: string);
begin
  if Source <> '' then Source := Source + LineEnding;
  Source := Source + Line;
end;

function RemoveReplMarker(var Line: string; const Marker: string): Boolean;
var
  P: Integer;
begin
  Result := False;
  repeat
    P := Pos(Marker, Line);
    if P = 0 then Exit;
    Delete(Line, P, Length(Marker));
    Result := True;
  until False;
end;

{$IFDEF UNIX}
function ReadReplByte(out C: Char): Boolean;
begin
  Result := BaseUnix.fpRead(0, C, 1) = 1;
end;

procedure EchoReplByte(C: Char);
begin
  Write(C);
end;

function ReadBracketedPaste(out Source: string): Boolean;
var
  C: Char;
  Pending: string;
  LastWasNewline: Boolean;
begin
  Source := '';
  Pending := '';
  LastWasNewline := False;
  while ReadReplByte(C) do
  begin
    Pending := Pending + C;
    while (Pending <> '') and
          (Copy(REPL_PASTE_END, 1, Length(Pending)) <> Pending) do
    begin
      C := Pending[1];
      Delete(Pending, 1, 1);
      Source := Source + C;
      EchoReplByte(C);
      LastWasNewline := C in [#10, #13];
    end;
    if Pending = REPL_PASTE_END then
    begin
      if not LastWasNewline then Writeln;
      Flush(Output);
      Exit(True);
    end;
  end;
  Source := Source + Pending;
  if Pending <> '' then Write(Pending);
  if (Source <> '') and not LastWasNewline then Writeln;
  Flush(Output);
  Result := Source <> '';
end;

function ReadReplEscape(out SequenceText: string): Boolean;
var
  C: Char;
begin
  SequenceText := '';
  if not ReadReplByte(C) then Exit(False);
  SequenceText := C;
  if (C <> '[') and (C <> 'O') then Exit(True);
  repeat
    if not ReadReplByte(C) then Exit(True);
    SequenceText := SequenceText + C;
  until (Length(SequenceText) >= 2) and (Ord(C) >= 64) and (Ord(C) <= 126);
  Result := True;
end;

function SingleLineHistoryBefore(History: TStrings; Start: Integer): Integer;
begin
  Result := Start - 1;
  while Result >= 0 do
  begin
    if (Pos(#10, History[Result]) = 0) and (Pos(#13, History[Result]) = 0) then Exit;
    Dec(Result);
  end;
end;

function SingleLineHistoryAfter(History: TStrings; Start: Integer): Integer;
begin
  Result := Start + 1;
  while Result < History.Count do
  begin
    if (Pos(#10, History[Result]) = 0) and (Pos(#13, History[Result]) = 0) then Exit;
    Inc(Result);
  end;
end;

procedure RedrawReplInput(const Line: string; Depth: Integer;
  Complete, Styled, PastePrompt: Boolean);
begin
  Write(#13, #27'[2K');
  if PastePrompt then WritePastePrompt(Styled)
  else WriteReplPrompt(Depth, Complete, Styled);
  Write(Line);
  Flush(Output);
end;

procedure EraseLastReplCharacter(var Line: string);
var
  P: Integer;
begin
  if Line = '' then Exit;
  P := Length(Line);
  while (P > 1) and ((Ord(Line[P]) and $C0) = $80) do Dec(P);
  Delete(Line, P, Length(Line) - P + 1);
  Write(#8, ' ', #8);
  Flush(Output);
end;

function ReadInteractiveReplLine(out Line: string; out WasPaste: Boolean;
  History: TStrings; Depth: Integer; Complete, Styled,
  PastePrompt: Boolean): Boolean;
var
  C: Char;
  SequenceText, Draft: string;
  HistoryIndex, NextIndex: Integer;
begin
  Line := '';
  Draft := '';
  WasPaste := False;
  HistoryIndex := History.Count;
  while ReadReplByte(C) do
  begin
    case Ord(C) of
      3:
        begin
          Line := ':cancel';
          Writeln('^C');
          Exit(True);
        end;
      4:
        begin
          if Line = '' then
          begin
            Writeln;
            Exit(False);
          end;
          Writeln;
          Exit(True);
        end;
      8, 127: EraseLastReplCharacter(Line);
      9:
        begin
          Line := Line + '  ';
          Write('  ');
          Flush(Output);
        end;
      10, 13:
        begin
          Writeln;
          Exit(True);
        end;
      12:
        begin
          Write(#27'[2J', #27'[H');
          RedrawReplInput(Line, Depth, Complete, Styled, PastePrompt);
        end;
      21:
        begin
          Line := '';
          HistoryIndex := History.Count;
          RedrawReplInput(Line, Depth, Complete, Styled, PastePrompt);
        end;
      27:
        begin
          if not ReadReplEscape(SequenceText) then Continue;
          if SequenceText = '[200~' then
          begin
            WasPaste := True;
            Exit(ReadBracketedPaste(Line));
          end;
          if (SequenceText = '[A') or (SequenceText = 'OA') then
          begin
            NextIndex := SingleLineHistoryBefore(History, HistoryIndex);
            if NextIndex >= 0 then
            begin
              if HistoryIndex = History.Count then Draft := Line;
              HistoryIndex := NextIndex;
              Line := History[HistoryIndex];
              RedrawReplInput(Line, Depth, Complete, Styled, PastePrompt);
            end;
          end
          else if (SequenceText = '[B') or (SequenceText = 'OB') then
          begin
            NextIndex := SingleLineHistoryAfter(History, HistoryIndex);
            if NextIndex < History.Count then
            begin
              HistoryIndex := NextIndex;
              Line := History[HistoryIndex];
              RedrawReplInput(Line, Depth, Complete, Styled, PastePrompt);
            end
            else if HistoryIndex < History.Count then
            begin
              HistoryIndex := History.Count;
              Line := Draft;
              RedrawReplInput(Line, Depth, Complete, Styled, PastePrompt);
            end;
          end;
        end;
    else
      if Ord(C) >= 32 then
      begin
        Line := Line + C;
        Write(C);
        Flush(Output);
      end;
    end;
  end;
  if Line <> '' then
  begin
    Writeln;
    Exit(True);
  end;
  Result := False;
end;
{$ENDIF}

procedure EvalReplSource(E: TLfpEngine; var Source: string; History: TStrings;
  Styled: Boolean);
var
  V: TLfpValue;
begin
  if Trim(Source) = '' then
  begin
    Source := '';
    Exit;
  end;
  AddReplHistory(History, Source);
  try
    V := E.Eval(UTF8Decode(Source), '<repl>');
    WriteReplResult(V, Styled);
  except
    on X: Exception do WriteReplError(X.Message, Styled);
  end;
  Source := '';
end;

procedure ReplHelp;
begin
  Writeln('REPL commands:');
  Writeln('  :help                 show this help');
  Writeln('  :quit, :q             leave the REPL');
  Writeln('  :cancel               discard an unfinished multiline form');
  Writeln('  :paste                paste source; finish with :end');
  Writeln('  :history [N]          show recent submitted forms');
  Writeln('  :again [N]            evaluate a recent submitted form');
  Writeln('  :load FILE            evaluate a .lfp or .lpas file');
  Writeln('  :reset                reset variables, routines, units, and heap state');
  Writeln('  :globals              show globals and registered routines');
  Writeln('  :types                show built-in and user-defined types');
  Writeln('  :inspect NAME         inspect one global value');
  Writeln('  :last                 show the previous result');
  Writeln('  :trace [on|off]       toggle or set VM tracing');
  Writeln('  :jit [auto|on|off]    show or change JIT mode');
  Writeln('  :paths                show unit search paths');
  Writeln('  :pwd                  show the working directory');
  Writeln('  :cd DIR               change the working directory');
  Writeln('  :time FORM            evaluate one form and print elapsed time');
  Writeln('  :clear                clear an ANSI terminal');
  Writeln('  :version              show the Lispal version');
  Writeln;
  Writeln('Multiline forms are accepted automatically. :cancel works while a form is open.');
end;

procedure ResetReplEngine(var E: TLfpEngine; JitMode: TLfpJitMode);
var
  Fresh: TLfpEngine;
begin
  Fresh := TLfpEngine.Create;
  try
    Fresh.JitMode := JitMode;
  except
    Fresh.Free;
    raise;
  end;
  E.Free;
  E := Fresh;
end;

function HandleReplCommand(var E: TLfpEngine; const Line: string;
  var JitMode: TLfpJitMode; History: TStrings; Styled: Boolean;
  out WantQuit, WantPaste: Boolean): Boolean;
var
  Cmd, Arg: string;
  V: TLfpValue;
  HistoryIndex, HistoryCount: Integer;
  Started, Elapsed: QWord;
begin
  Result := False;
  WantQuit := False;
  WantPaste := False;
  if (Trim(Line) = '') or (Trim(Line)[1] <> ':') then Exit;
  Result := True;
  Cmd := ReplCommandName(Line);
  Arg := ReplArg(Line);

  if (Cmd = ':quit') or (Cmd = ':q') then
  begin
    WantQuit := True;
    Exit;
  end;
  if Cmd = ':help' then
  begin
    ReplHelp;
    Exit;
  end;
  if Cmd = ':paste' then
  begin
    if Arg <> '' then raise Exception.Create(':paste does not take an argument');
    WantPaste := True;
    Exit;
  end;
  if Cmd = ':history' then
  begin
    HistoryCount := 0;
    if (Arg <> '') and (not TryStrToInt(Arg, HistoryCount) or (HistoryCount < 1)) then
      raise Exception.Create(':history expects a positive number');
    PrintReplHistory(History, HistoryCount);
    Exit;
  end;
  if Cmd = ':again' then
  begin
    if History.Count = 0 then raise Exception.Create('history is empty');
    if Arg = '' then HistoryIndex := History.Count
    else if not TryStrToInt(Arg, HistoryIndex) then
      raise Exception.Create(':again expects a history number');
    if (HistoryIndex < 1) or (HistoryIndex > History.Count) then
      raise Exception.Create('history number out of range: ' + IntToStr(HistoryIndex));
    V := E.Eval(UTF8Decode(History[HistoryIndex - 1]), '<repl:again>');
    WriteReplResult(V, Styled);
    Exit;
  end;
  if Cmd = ':version' then
  begin
    Writeln('lfp ', LFP_VERSION);
    Exit;
  end;
  if Cmd = ':trace' then
  begin
    if Arg = '' then E.Trace := not E.Trace
    else if SameText(Arg, 'on') then E.Trace := True
    else if SameText(Arg, 'off') then E.Trace := False
    else raise Exception.Create(':trace expects on or off');
    Writeln('trace: ', LowerCase(BoolToStr(E.Trace, True)));
    Exit;
  end;
  if Cmd = ':jit' then
  begin
    if (Arg = '') or SameText(Arg, 'status') then
    begin
      Writeln(E.JitStatus);
      Exit;
    end;
    if SameText(Arg, 'auto') then JitMode := jmAuto
    else if SameText(Arg, 'on') then JitMode := jmOn
    else if SameText(Arg, 'off') then JitMode := jmOff
    else raise Exception.Create(':jit expects auto, on, or off');
    E.JitMode := JitMode;
    Writeln(E.JitStatus);
    Exit;
  end;
  if Cmd = ':reset' then
  begin
    ResetReplEngine(E, JitMode);
    Writeln('runtime reset');
    Exit;
  end;
  if Cmd = ':globals' then
  begin
    Writeln(E.GlobalsReport);
    Exit;
  end;
  if Cmd = ':types' then
  begin
    Writeln(E.TypesReport);
    Exit;
  end;
  if Cmd = ':paths' then
  begin
    Writeln(E.SearchPathsReport);
    Exit;
  end;
  if Cmd = ':last' then
  begin
    WriteReplResult(E.LastResult, Styled);
    Exit;
  end;
  if Cmd = ':inspect' then
  begin
    if Arg = '' then raise Exception.Create(':inspect needs a global name');
    if not E.HasGlobal(Arg) then raise Exception.Create('unknown global: ' + Arg);
    V := E.GetGlobal(Arg);
    Writeln(Arg, ' : ', LfpValueTypeName(V), ' = ', LfpValueInspect(V));
    Exit;
  end;
  if Cmd = ':load' then
  begin
    if Arg = '' then raise Exception.Create(':load needs a file name');
    V := E.EvalFile(Arg);
    WriteReplResult(V, Styled);
    Exit;
  end;
  if Cmd = ':pwd' then
  begin
    Writeln(GetCurrentDir);
    Exit;
  end;
  if Cmd = ':cd' then
  begin
    if Arg = '' then raise Exception.Create(':cd needs a directory');
    if not SetCurrentDir(Arg) then raise Exception.Create('cannot change directory to: ' + Arg);
    E.AddSearchPath(GetCurrentDir);
    Writeln(GetCurrentDir);
    Exit;
  end;
  if Cmd = ':time' then
  begin
    if Arg = '' then raise Exception.Create(':time needs a form');
    Started := GetTickCount64;
    V := E.Eval(UTF8Decode(Arg), '<repl:time>');
    Elapsed := GetTickCount64 - Started;
    WriteReplResult(V, Styled);
    Writeln('   ', Elapsed, ' ms');
    Exit;
  end;
  if Cmd = ':clear' then
  begin
    Write(#27'[2J'#27'[H');
    Exit;
  end;
  if Cmd = ':cancel' then Exit;
  raise Exception.Create('unknown REPL command: ' + Cmd + ' (try :help)');
end;

procedure RunRepl(JitMode: TLfpJitMode = jmAuto);
var
  E: TLfpEngine;
  History: TStringList;
  Terminal: TReplTerminal;
  Line, Source: string;
  Depth: Integer;
  Complete, WantQuit, WantPaste: Boolean;
  Interactive, Styled: Boolean;
  PasteMode, BracketedPaste, PastePromptPending: Boolean;
  PasteStarted, PasteEnded, WasPaste, HaveInput: Boolean;
begin
  E := TLfpEngine.Create;
  History := TStringList.Create;
  Interactive := ReplIsInteractive;
  Styled := ReplUseStyle(Interactive);
  BeginReplTerminal(Terminal, Interactive);
  try
    if Terminal.Active then
    begin
      Write(REPL_PASTE_ENABLE);
      Flush(Output);
    end;
    E.JitMode := JitMode;
    Banner;
    Writeln;
    Writeln('Type :help for commands, :quit when you''re done.');
    Writeln;
    Depth := 0;
    Complete := True;
    Source := '';
    PasteMode := False;
    BracketedPaste := False;
    PastePromptPending := False;
    while True do
    begin
      if Interactive then
      begin
        if PasteMode then
        begin
          if PastePromptPending then
          begin
            WritePastePrompt(Styled);
            PastePromptPending := False;
          end;
        end
        else WriteReplPrompt(Depth, Complete, Styled);
      end;
      WasPaste := False;
      if Terminal.Active then
      begin
        {$IFDEF UNIX}
        HaveInput := ReadInteractiveReplLine(Line, WasPaste, History, Depth,
          Complete, Styled, PasteMode);
        {$ELSE}
        HaveInput := False;
        {$ENDIF}
      end
      else if EOF(Input) then HaveInput := False
      else
      begin
        ReadLn(Line);
        HaveInput := True;
      end;

      if not HaveInput then
      begin
        if PasteMode and (Trim(Source) <> '') then
          EvalReplSource(E, Source, History, Styled)
        else if Trim(Source) <> '' then
          WriteReplError('discarded incomplete form at end of input', Styled);
        Break;
      end;

      if WasPaste then
      begin
        PasteStarted := True;
        PasteEnded := True;
      end
      else
      begin
        PasteStarted := RemoveReplMarker(Line, REPL_PASTE_START);
        PasteEnded := RemoveReplMarker(Line, REPL_PASTE_END);
      end;
      { The Crt input driver used by the runtime consumes the CSI portion of
        bracketed-paste markers on some Unix terminals and leaves the '~'. }
      if Interactive and not Terminal.Active and not PasteStarted and not PasteMode and
         (Line <> '') and (Line[1] = '~') then
      begin
        Delete(Line, 1, 1);
        PasteStarted := True;
      end;
      if Interactive and not Terminal.Active and
         (PasteStarted or (PasteMode and BracketedPaste)) and
         (Line <> '') and (Line[Length(Line)] = '~') then
      begin
        Delete(Line, Length(Line), 1);
        PasteEnded := True;
      end;
      if PasteStarted then
      begin
        PasteMode := True;
        BracketedPaste := True;
        PastePromptPending := False;
      end;

      if PasteMode then
      begin
        if not BracketedPaste and (Trim(Line) = ':cancel') then
        begin
          Source := '';
          PasteMode := False;
          PastePromptPending := False;
          Depth := 0;
          Complete := True;
          Writeln('cancelled');
          Continue;
        end;
        if not BracketedPaste and (Trim(Line) = ':end') then
        begin
          PasteMode := False;
          PastePromptPending := False;
          EvalReplSource(E, Source, History, Styled);
          Depth := 0;
          Complete := True;
          Continue;
        end;
        AppendReplSource(Source, Line);
        if PasteEnded then
        begin
          PasteMode := False;
          BracketedPaste := False;
          EvalReplSource(E, Source, History, Styled);
          Depth := 0;
          Complete := True;
        end;
        Continue;
      end;

      if (Trim(Line) = ':cancel') and ((Depth <> 0) or not Complete or (Source <> '')) then
      begin
        Source := '';
        Depth := 0;
        Complete := True;
        Writeln('cancelled');
        Continue;
      end;

      if (Depth = 0) and Complete and (Trim(Line) <> '') and (Trim(Line)[1] = ':') then
      begin
        try
          HandleReplCommand(E, Line, JitMode, History, Styled, WantQuit, WantPaste);
          if WantQuit then Break;
          if WantPaste then
          begin
            PasteMode := True;
            BracketedPaste := False;
            PastePromptPending := True;
            Writeln('Paste source, then enter :end on its own line. :cancel discards it.');
          end;
        except
          on X: Exception do WriteReplError(X.Message, Styled);
        end;
        Continue;
      end;

      AppendReplSource(Source, Line);
      SourceBalance(Source, Depth, Complete);
      if (Depth > 0) or not Complete then Continue;
      if Depth < 0 then
      begin
        WriteReplError('too many closing parentheses', Styled);
        Depth := 0;
        Complete := True;
        Source := '';
        Continue;
      end;
      if Trim(Source) = '' then
      begin
        Source := '';
        Continue;
      end;
      EvalReplSource(E, Source, History, Styled);
    end;
  finally
    if Terminal.Active then
    begin
      Write(REPL_PASTE_DISABLE, ANSI_RESET);
      Flush(Output);
    end;
    EndReplTerminal(Terminal);
    History.Free;
    E.Free;
  end;
end;

function ReadFileUtf8(const FileName: string): UnicodeString;
var
  S: TStringList;
begin
  S := TStringList.Create;
  try
    S.LoadFromFile(FileName);
    Result := UTF8Decode(S.Text);
  finally
    S.Free;
  end;
end;

function RunCommandLine: Integer;
var
  Engine: TLfpEngine;
  V: TLfpValue;
  Script, Source: string;
  I, FirstScriptArg: Integer;
  Dump, Trace, Repl, ShowJitStatus, ShowHelp, ShowVersion: Boolean;
  RequestedJitMode: TLfpJitMode;
begin
  Result := 0;
  if ParamCount = 0 then
  begin
    RunRepl;
    Exit(0);
  end;

  if (ParamStr(1) = '--version') or (ParamStr(1) = '-v') then
  begin
    Writeln('lfp ', LFP_VERSION);
    Exit(0);
  end;
  if (ParamStr(1) = '--help') or (ParamStr(1) = '-h') then
  begin
    Usage;
    Exit(0);
  end;
  Engine := TLfpEngine.Create;
  try
    try
      Dump := False;
      Trace := False;
      Repl := False;
      ShowJitStatus := False;
      ShowHelp := False;
      ShowVersion := False;
      RequestedJitMode := jmAuto;
      I := 1;
    while (I <= ParamCount) and (Copy(ParamStr(I), 1, 2) = '--') do
    begin
      if ParamStr(I) = '--dump-bytecode' then Dump := True
      else if ParamStr(I) = '--trace' then Trace := True
      else if ParamStr(I) = '--jit' then RequestedJitMode := jmOn
      else if ParamStr(I) = '--no-jit' then RequestedJitMode := jmOff
      else if ParamStr(I) = '--jit-status' then ShowJitStatus := True
      else if ParamStr(I) = '--repl' then Repl := True
      else if ParamStr(I) = '--help' then ShowHelp := True
      else if ParamStr(I) = '--version' then ShowVersion := True
      else if ParamStr(I) = '--' then
      begin
        Inc(I);
        Break;
      end
      else
      begin
        Writeln(StdErr, 'unknown option: ', ParamStr(I));
        Exit(2);
      end;
      Inc(I);
    end;
    Engine.Trace := Trace;
    Engine.JitMode := RequestedJitMode;

    if ShowHelp then
    begin
      Usage;
      Exit(0);
    end;
    if ShowVersion then
    begin
      Writeln('lfp ', LFP_VERSION);
      Exit(0);
    end;

    if ShowJitStatus then
    begin
      Writeln(Engine.JitStatus);
      if I > ParamCount then Exit(0);
    end;

    if Repl then
    begin
      if I <= ParamCount then
      begin
        Writeln(StdErr, '--repl does not accept a script');
        Exit(2);
      end;
      RunRepl(RequestedJitMode);
      Exit(0);
    end;

    if (I <= ParamCount) and (ParamStr(I) = '-e') then
    begin
      if I = ParamCount then
      begin
        Writeln(StdErr, '-e requires source text');
        Exit(2);
      end;
      Source := ParamStr(I + 1);
      SetupArgs(Engine, I + 2);
      if Dump then Writeln(Engine.Disassemble(UTF8Decode(Source), '<command-line>'))
      else
      begin
        V := Engine.Eval(UTF8Decode(Source), '<command-line>');
        if V.Kind <> vkNil then Writeln(LfpValueInspect(V));
      end;
      Exit(0);
    end;

    if I > ParamCount then
    begin
      Usage;
      Exit(2);
    end;

    Script := ParamStr(I);
    FirstScriptArg := I + 1;
    SetupArgs(Engine, FirstScriptArg);
    if Dump then
      Writeln(Engine.Disassemble(ReadFileUtf8(Script), ExpandFileName(Script)))
    else
      Engine.EvalFile(Script);
    except
      on H: ELfpHalt do Exit(H.ExitCode);
      on X: Exception do
      begin
        Writeln(StdErr, 'lfp: ', X.Message);
        Exit(1);
      end;
    end;
  finally
    Engine.Free;
  end;
end;

begin
  Halt(RunCommandLine);
end.
