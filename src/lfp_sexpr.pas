unit lfp_sexpr;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Contnrs;

type
  ELfpSyntaxError = class(Exception);

  TLfpSourcePos = record
    FileName: string;
    Line: Integer;
    Column: Integer;
  end;

  TLfpTokenKind = (
    tkEOF,
    tkLParen,
    tkRParen,
    tkQuote,
    tkAtom,
    tkString,
    tkChar
  );

  TLfpToken = record
    Kind: TLfpTokenKind;
    Text: UnicodeString;
    Pos: TLfpSourcePos;
  end;

  TLfpNodeKind = (nkAtom, nkString, nkChar, nkList);

  TLfpNode = class
  private
    FKind: TLfpNodeKind;
    FText: UnicodeString;
    FChildren: TObjectList;
    FPos: TLfpSourcePos;
  public
    constructor CreateAtom(AKind: TLfpNodeKind; const AText: UnicodeString;
      const APos: TLfpSourcePos);
    constructor CreateList(const APos: TLfpSourcePos);
    destructor Destroy; override;
    procedure Add(Node: TLfpNode);
    function Count: Integer;
    function Child(Index: Integer): TLfpNode;
    function IsAtom(const S: UnicodeString): Boolean;
    function HeadIs(const S: UnicodeString): Boolean;
    function DebugString: string;
    property Kind: TLfpNodeKind read FKind;
    property Text: UnicodeString read FText;
    property Pos: TLfpSourcePos read FPos;
  end;

  TLfpLexer = class
  private
    FSource: UnicodeString;
    FFileName: string;
    FIndex: SizeInt;
    FLine: Integer;
    FColumn: Integer;
    FLength: SizeInt;
    function Current: WideChar;
    function Peek(Offset: SizeInt = 1): WideChar;
    procedure Advance;
    procedure SkipWhitespaceAndComments;
    procedure SkipLineComment;
    procedure SkipBraceComment;
    function ReadString: TLfpToken;
    function ReadChar: TLfpToken;
    function ReadAtom: TLfpToken;
    function Here: TLfpSourcePos;
    procedure SyntaxError(const Msg: string);
  public
    constructor Create(const ASource: UnicodeString; const AFileName: string);
    function NextToken: TLfpToken;
  end;

  TLfpParser = class
  private
    FLexer: TLfpLexer;
    FCurrent: TLfpToken;
    procedure Next;
    function ParseForm: TLfpNode;
    function ParseList: TLfpNode;
    function ParseQuote: TLfpNode;
    procedure ErrorAt(const Pos: TLfpSourcePos; const Msg: string);
  public
    constructor Create(const Source: UnicodeString; const FileName: string = '<string>');
    destructor Destroy; override;
    function ParseAll: TObjectList;
  end;

function LfpPosString(const Pos: TLfpSourcePos): string;

implementation

function LfpPosString(const Pos: TLfpSourcePos): string;
begin
  Result := Format('%s:%d:%d', [Pos.FileName, Pos.Line, Pos.Column]);
end;

constructor TLfpNode.CreateAtom(AKind: TLfpNodeKind; const AText: UnicodeString;
  const APos: TLfpSourcePos);
begin
  inherited Create;
  FKind := AKind;
  FText := AText;
  FPos := APos;
  FChildren := nil;
end;

constructor TLfpNode.CreateList(const APos: TLfpSourcePos);
begin
  inherited Create;
  FKind := nkList;
  FText := '';
  FPos := APos;
  FChildren := TObjectList.Create(True);
end;

destructor TLfpNode.Destroy;
begin
  FChildren.Free;
  inherited Destroy;
end;

procedure TLfpNode.Add(Node: TLfpNode);
begin
  if FKind <> nkList then
    raise Exception.Create('internal: Add called on non-list node');
  FChildren.Add(Node);
end;

function TLfpNode.Count: Integer;
begin
  if Assigned(FChildren) then Result := FChildren.Count else Result := 0;
end;

function TLfpNode.Child(Index: Integer): TLfpNode;
begin
  if not Assigned(FChildren) then
    raise Exception.Create('internal: Child called on non-list node');
  Result := TLfpNode(FChildren[Index]);
end;

function TLfpNode.IsAtom(const S: UnicodeString): Boolean;
begin
  Result := (FKind = nkAtom) and (CompareText(UTF8Encode(FText), UTF8Encode(S)) = 0);
end;

function TLfpNode.HeadIs(const S: UnicodeString): Boolean;
begin
  Result := (FKind = nkList) and (Count > 0) and Child(0).IsAtom(S);
end;

function TLfpNode.DebugString: string;
var
  I: Integer;
begin
  case FKind of
    nkAtom: Result := UTF8Encode(FText);
    nkString: Result := '"' + UTF8Encode(FText) + '"';
    nkChar: Result := '#\' + UTF8Encode(FText);
    nkList:
      begin
        Result := '(';
        for I := 0 to Count - 1 do
        begin
          if I > 0 then Result := Result + ' ';
          Result := Result + Child(I).DebugString;
        end;
        Result := Result + ')';
      end;
  else
    Result := '?';
  end;
end;

constructor TLfpLexer.Create(const ASource: UnicodeString; const AFileName: string);
begin
  inherited Create;
  FSource := ASource;
  FFileName := AFileName;
  FIndex := 1;
  FLine := 1;
  FColumn := 1;
  FLength := System.Length(FSource);

  if (FLength >= 2) and (FSource[1] = '#') and (FSource[2] = '!') then
    SkipLineComment;
end;

function TLfpLexer.Current: WideChar;
begin
  if FIndex > FLength then Result := #0 else Result := FSource[FIndex];
end;

function TLfpLexer.Peek(Offset: SizeInt): WideChar;
var
  P: SizeInt;
begin
  P := FIndex + Offset;
  if P > FLength then Result := #0 else Result := FSource[P];
end;

procedure TLfpLexer.Advance;
begin
  if FIndex > FLength then Exit;
  if FSource[FIndex] = #10 then
  begin
    Inc(FLine);
    FColumn := 1;
  end
  else
    Inc(FColumn);
  Inc(FIndex);
end;

function TLfpLexer.Here: TLfpSourcePos;
begin
  Result.FileName := FFileName;
  Result.Line := FLine;
  Result.Column := FColumn;
end;

procedure TLfpLexer.SyntaxError(const Msg: string);
begin
  raise ELfpSyntaxError.Create(LfpPosString(Here) + ': ' + Msg);
end;

procedure TLfpLexer.SkipLineComment;
begin
  while (Current <> #0) and (Current <> #10) do Advance;
  if Current = #10 then Advance;
end;

procedure TLfpLexer.SkipBraceComment;
begin
  Advance;
  while (Current <> #0) and (Current <> '}') do Advance;
  if Current = #0 then SyntaxError('unterminated { ... } comment');
  Advance;
end;

procedure TLfpLexer.SkipWhitespaceAndComments;
var
  Again: Boolean;
begin
  repeat
    Again := False;
    while Current in [' ', #9, #10, #13] do Advance;

    if Current = ';' then
    begin
      SkipLineComment;
      Again := True;
    end
    else if (Current = '/') and (Peek = '/') then
    begin
      SkipLineComment;
      Again := True;
    end
    else if Current = '{' then
    begin
      SkipBraceComment;
      Again := True;
    end;
  until not Again;
end;

function TLfpLexer.ReadString: TLfpToken;
var
  P: TLfpSourcePos;
  S: UnicodeString;
  C: WideChar;
begin
  P := Here;
  S := '';
  Advance;
  while Current <> #0 do
  begin
    C := Current;
    if C = '"' then
    begin
      Advance;
      Result.Kind := tkString;
      Result.Text := S;
      Result.Pos := P;
      Exit;
    end;
    if C = '\' then
    begin
      Advance;
      C := Current;
      case C of
        'n': S := S + #10;
        'r': S := S + #13;
        't': S := S + #9;
        '"': S := S + '"';
        '\': S := S + '\';
        '0': S := S + #0;
      else
        S := S + C;
      end;
      if Current <> #0 then Advance;
    end
    else
    begin
      S := S + C;
      Advance;
    end;
  end;
  raise ELfpSyntaxError.Create(LfpPosString(P) + ': unterminated string literal');
end;

function TLfpLexer.ReadChar: TLfpToken;
var
  P: TLfpSourcePos;
  S: UnicodeString;
begin
  P := Here;
  Advance;
  Advance;
  S := '';
  while not (Current in [#0, ' ', #9, #10, #13, '(', ')']) do
  begin
    S := S + Current;
    Advance;
  end;
  if S = '' then
    raise ELfpSyntaxError.Create(LfpPosString(P) + ': empty character literal');
  if CompareText(UTF8Encode(S), 'space') = 0 then S := ' '
  else if CompareText(UTF8Encode(S), 'newline') = 0 then S := #10
  else if CompareText(UTF8Encode(S), 'tab') = 0 then S := #9
  else if CompareText(UTF8Encode(S), 'null') = 0 then S := #0
  else if System.Length(S) <> 1 then
    raise ELfpSyntaxError.Create(LfpPosString(P) + ': invalid character literal #\' + UTF8Encode(S));
  Result.Kind := tkChar;
  Result.Text := S;
  Result.Pos := P;
end;

function TLfpLexer.ReadAtom: TLfpToken;
var
  P: TLfpSourcePos;
  S: UnicodeString;
begin
  P := Here;
  S := '';
  while not (Current in [#0, ' ', #9, #10, #13, '(', ')', ';', '"', '''']) do
  begin
    if (Current = '/') and (Peek = '/') then Break;
    if (Current = '{') then Break;
    S := S + Current;
    Advance;
  end;
  if S = '' then SyntaxError('unexpected character "' + UTF8Encode(Current) + '"');
  Result.Kind := tkAtom;
  Result.Text := S;
  Result.Pos := P;
end;

function TLfpLexer.NextToken: TLfpToken;
begin
  SkipWhitespaceAndComments;
  Result.Text := '';
  Result.Pos := Here;
  case Current of
    #0: Result.Kind := tkEOF;
    '(':
      begin
        Result.Kind := tkLParen;
        Advance;
      end;
    ')':
      begin
        Result.Kind := tkRParen;
        Advance;
      end;
    '''':
      begin
        Result.Kind := tkQuote;
        Advance;
      end;
    '"': Result := ReadString;
    '#':
      if Peek = '\' then Result := ReadChar else Result := ReadAtom;
  else
    Result := ReadAtom;
  end;
end;

constructor TLfpParser.Create(const Source: UnicodeString; const FileName: string);
begin
  inherited Create;
  FLexer := TLfpLexer.Create(Source, FileName);
  Next;
end;

destructor TLfpParser.Destroy;
begin
  FLexer.Free;
  inherited Destroy;
end;

procedure TLfpParser.Next;
begin
  FCurrent := FLexer.NextToken;
end;

procedure TLfpParser.ErrorAt(const Pos: TLfpSourcePos; const Msg: string);
begin
  raise ELfpSyntaxError.Create(LfpPosString(Pos) + ': ' + Msg);
end;

function TLfpParser.ParseList: TLfpNode;
var
  P: TLfpSourcePos;
begin
  P := FCurrent.Pos;
  Result := TLfpNode.CreateList(P);
  Next;
  try
    while FCurrent.Kind <> tkRParen do
    begin
      if FCurrent.Kind = tkEOF then
        ErrorAt(P, 'unterminated list');
      Result.Add(ParseForm);
    end;
    Next;
  except
    Result.Free;
    raise;
  end;
end;

function TLfpParser.ParseQuote: TLfpNode;
var
  P: TLfpSourcePos;
begin
  P := FCurrent.Pos;
  Next;
  if FCurrent.Kind = tkEOF then ErrorAt(P, 'quote without following form');
  Result := TLfpNode.CreateList(P);
  try
    Result.Add(TLfpNode.CreateAtom(nkAtom, 'quote', P));
    Result.Add(ParseForm);
  except
    Result.Free;
    raise;
  end;
end;

function TLfpParser.ParseForm: TLfpNode;
var
  T: TLfpToken;
begin
  T := FCurrent;
  case T.Kind of
    tkLParen: Exit(ParseList);
    tkRParen: ErrorAt(T.Pos, 'unexpected )');
    tkQuote: Exit(ParseQuote);
    tkAtom:
      begin
        Result := TLfpNode.CreateAtom(nkAtom, T.Text, T.Pos);
        Next;
      end;
    tkString:
      begin
        Result := TLfpNode.CreateAtom(nkString, T.Text, T.Pos);
        Next;
      end;
    tkChar:
      begin
        Result := TLfpNode.CreateAtom(nkChar, T.Text, T.Pos);
        Next;
      end;
    tkEOF: ErrorAt(T.Pos, 'unexpected end of file');
  else
    ErrorAt(T.Pos, 'invalid token');
    Result := nil;
  end;
end;

function TLfpParser.ParseAll: TObjectList;
begin
  Result := TObjectList.Create(True);
  try
    while FCurrent.Kind <> tkEOF do
      Result.Add(ParseForm);
  except
    Result.Free;
    raise;
  end;
end;

end.
