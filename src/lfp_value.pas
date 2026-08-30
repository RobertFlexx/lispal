unit lfp_value;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Contnrs, Math;

type
  ELfpRuntimeError = class(Exception);

  TLfpHeapObject = class;

  TLfpValueKind = (
    vkNil,
    vkInteger,
    vkReal,
    vkBoolean,
    vkString,
    vkChar,
    vkObject
  );

  TLfpValue = record
    Kind: TLfpValueKind;
    IntValue: Int64;
    RealValue: Double;
    BoolValue: Boolean;
    StrValue: UnicodeString;
    ObjValue: TLfpHeapObject;
  end;

  TLfpValueArray = array of TLfpValue;

  TLfpValueBox = class
  public
    Value: TLfpValue;
    constructor Create(const AValue: TLfpValue);
  end;

  TLfpHeapObject = class
  public
    function TypeName: string; virtual;
    function Inspect: string; virtual;
    function ValueEquals(Other: TLfpHeapObject): Boolean; virtual;
  end;

  TLfpArrayObject = class(TLfpHeapObject)
  private
    FItems: TLfpValueArray;
    FLowerBound: Int64;
    FElementType: string;
  public
    constructor Create(ALength: SizeInt; ALowerBound: Int64 = 0;
      const AElementType: string = 'Variant');
    function Length: SizeInt;
    function LowerBound: Int64;
    function UpperBound: Int64;
    function GetItem(Index: Int64): TLfpValue;
    procedure SetItem(Index: Int64; const V: TLfpValue);
    procedure Append(const V: TLfpValue);
    function TypeName: string; override;
    function Inspect: string; override;
    property Items: TLfpValueArray read FItems write FItems;
    property ElementType: string read FElementType write FElementType;
  end;

  TLfpSetObject = class(TLfpHeapObject)
  private
    FItems: TLfpValueArray;
    FElementType: string;
  public
    constructor Create(const AElementType: string = 'Variant');
    function Contains(const V: TLfpValue): Boolean;
    procedure IncludeValue(const V: TLfpValue);
    procedure ExcludeValue(const V: TLfpValue);
    function Count: SizeInt;
    function ItemAt(Index: SizeInt): TLfpValue;
    function TypeName: string; override;
    function Inspect: string; override;
    property Items: TLfpValueArray read FItems;
    property ElementType: string read FElementType write FElementType;
  end;

  TLfpRecordObject = class(TLfpHeapObject)
  private
    FRecordTypeName: string;
    FFields: TStringList;
  public
    constructor Create(const ATypeName: string);
    destructor Destroy; override;
    procedure DefineField(const Name: string; const InitialValue: TLfpValue);
    function HasField(const Name: string): Boolean;
    function GetField(const Name: string): TLfpValue;
    procedure SetField(const Name: string; const V: TLfpValue);
    function TypeName: string; override;
    function Inspect: string; override;
    property RecordTypeName: string read FRecordTypeName;
  end;

  TLfpPointerObject = class(TLfpHeapObject)
  private
    FAlive: Boolean;
    FValue: TLfpValue;
  public
    constructor Create(const InitialValue: TLfpValue);
    procedure DisposePointer;
    function Dereference: TLfpValue;
    procedure Assign(const V: TLfpValue);
    function TypeName: string; override;
    function Inspect: string; override;
    property Alive: Boolean read FAlive;
  end;

function LfpNil: TLfpValue;
function LfpInt(V: Int64): TLfpValue;
function LfpReal(V: Double): TLfpValue;
function LfpBool(V: Boolean): TLfpValue;
function LfpString(const V: UnicodeString): TLfpValue;
function LfpChar(V: WideChar): TLfpValue;
function LfpObject(V: TLfpHeapObject): TLfpValue;

function LfpValueTypeName(const V: TLfpValue): string;
function LfpValueInspect(const V: TLfpValue): string;
function LfpValueAsString(const V: TLfpValue): UnicodeString;
function LfpIsNumeric(const V: TLfpValue): Boolean;
function LfpToReal(const V: TLfpValue): Double;
function LfpToInt(const V: TLfpValue): Int64;
function LfpTruthy(const V: TLfpValue): Boolean;
function LfpValueEqual(const A, B: TLfpValue): Boolean;

implementation

function EscapeString(const S: UnicodeString): UnicodeString;
var
  I: SizeInt;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
      #0: Result := Result + '\0';
    else
      Result := Result + S[I];
    end;
end;

function RealEqualsInteger(R: Double; I: Int64): Boolean;
const
  Int64UpperExclusive = 9223372036854775808.0;
  Int64LowerInclusive = -9223372036854775808.0;
begin
  if IsNan(R) or IsInfinite(R) or (R < Int64LowerInclusive) or
     (R >= Int64UpperExclusive) or (Frac(R) <> 0.0) then
    Exit(False);
  Result := Trunc(R) = I;
end;

function FloatToLfpString(Value: Double): string;
var
  Settings: TFormatSettings;
begin
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Result := FloatToStr(Value, Settings);
end;

constructor TLfpValueBox.Create(const AValue: TLfpValue);
begin
  inherited Create;
  Value := AValue;
end;

function TLfpHeapObject.TypeName: string;
begin
  Result := 'object';
end;

function TLfpHeapObject.Inspect: string;
begin
  Result := '<' + TypeName + '>';
end;

function TLfpHeapObject.ValueEquals(Other: TLfpHeapObject): Boolean;
begin
  Result := Self = Other;
end;

constructor TLfpArrayObject.Create(ALength: SizeInt; ALowerBound: Int64;
  const AElementType: string);
var
  I: SizeInt;
begin
  inherited Create;
  if ALength < 0 then
    raise ELfpRuntimeError.Create('array length cannot be negative');
  FLowerBound := ALowerBound;
  FElementType := AElementType;
  SetLength(FItems, ALength);
  for I := 0 to High(FItems) do
    FItems[I] := LfpNil;
end;

function TLfpArrayObject.Length: SizeInt;
begin
  Result := System.Length(FItems);
end;

function TLfpArrayObject.LowerBound: Int64;
begin
  Result := FLowerBound;
end;

function TLfpArrayObject.UpperBound: Int64;
begin
  Result := FLowerBound + System.Length(FItems) - 1;
end;

function TLfpArrayObject.GetItem(Index: Int64): TLfpValue;
var
  Physical: Int64;
begin
  Physical := Index - FLowerBound;
  if (Physical < 0) or (Physical >= System.Length(FItems)) then
    raise ELfpRuntimeError.CreateFmt('array index %d out of range %d..%d',
      [Index, LowerBound, UpperBound]);
  Result := FItems[Physical];
end;

procedure TLfpArrayObject.SetItem(Index: Int64; const V: TLfpValue);
var
  Physical: Int64;
begin
  Physical := Index - FLowerBound;
  if (Physical < 0) or (Physical >= System.Length(FItems)) then
    raise ELfpRuntimeError.CreateFmt('array index %d out of range %d..%d',
      [Index, LowerBound, UpperBound]);
  FItems[Physical] := V;
end;

procedure TLfpArrayObject.Append(const V: TLfpValue);
var
  N: SizeInt;
begin
  N := System.Length(FItems);
  SetLength(FItems, N + 1);
  FItems[N] := V;
end;

function TLfpArrayObject.TypeName: string;
begin
  Result := 'array';
end;

function TLfpArrayObject.Inspect: string;
var
  I: SizeInt;
begin
  Result := '[';
  for I := 0 to High(FItems) do
  begin
    if I > 0 then Result := Result + ', ';
    Result := Result + LfpValueInspect(FItems[I]);
  end;
  Result := Result + ']';
end;

constructor TLfpSetObject.Create(const AElementType: string);
begin
  inherited Create;
  FElementType := AElementType;
end;

function TLfpSetObject.Contains(const V: TLfpValue): Boolean;
var
  I: SizeInt;
begin
  for I := 0 to High(FItems) do
    if LfpValueEqual(FItems[I], V) then
      Exit(True);
  Result := False;
end;

procedure TLfpSetObject.IncludeValue(const V: TLfpValue);
var
  N: SizeInt;
begin
  if Contains(V) then Exit;
  N := System.Length(FItems);
  SetLength(FItems, N + 1);
  FItems[N] := V;
end;

procedure TLfpSetObject.ExcludeValue(const V: TLfpValue);
var
  I, J, N: SizeInt;
begin
  N := System.Length(FItems);
  for I := 0 to N - 1 do
    if LfpValueEqual(FItems[I], V) then
    begin
      for J := I to N - 2 do
        FItems[J] := FItems[J + 1];
      SetLength(FItems, N - 1);
      Exit;
    end;
end;

function TLfpSetObject.Count: SizeInt;
begin
  Result := System.Length(FItems);
end;

function TLfpSetObject.ItemAt(Index: SizeInt): TLfpValue;
begin
  if (Index < 0) or (Index >= System.Length(FItems)) then
    raise ELfpRuntimeError.Create('set item index out of range');
  Result := FItems[Index];
end;

function TLfpSetObject.TypeName: string;
begin
  Result := 'set';
end;

function TLfpSetObject.Inspect: string;
var
  I: SizeInt;
begin
  Result := '{';
  for I := 0 to High(FItems) do
  begin
    if I > 0 then Result := Result + ', ';
    Result := Result + LfpValueInspect(FItems[I]);
  end;
  Result := Result + '}';
end;

constructor TLfpRecordObject.Create(const ATypeName: string);
begin
  inherited Create;
  FRecordTypeName := ATypeName;
  FFields := TStringList.Create;
  FFields.CaseSensitive := False;
  FFields.Sorted := True;
  FFields.Duplicates := dupError;
  FFields.OwnsObjects := True;
end;

destructor TLfpRecordObject.Destroy;
begin
  FFields.Free;
  inherited Destroy;
end;

procedure TLfpRecordObject.DefineField(const Name: string; const InitialValue: TLfpValue);
begin
  FFields.AddObject(Name, TLfpValueBox.Create(InitialValue));
end;

function TLfpRecordObject.HasField(const Name: string): Boolean;
begin
  Result := FFields.IndexOf(Name) >= 0;
end;

function TLfpRecordObject.GetField(const Name: string): TLfpValue;
var
  I: Integer;
begin
  I := FFields.IndexOf(Name);
  if I < 0 then
    raise ELfpRuntimeError.CreateFmt('%s has no field "%s"', [FRecordTypeName, Name]);
  Result := TLfpValueBox(FFields.Objects[I]).Value;
end;

procedure TLfpRecordObject.SetField(const Name: string; const V: TLfpValue);
var
  I: Integer;
begin
  I := FFields.IndexOf(Name);
  if I < 0 then
    raise ELfpRuntimeError.CreateFmt('%s has no field "%s"', [FRecordTypeName, Name]);
  TLfpValueBox(FFields.Objects[I]).Value := V;
end;

function TLfpRecordObject.TypeName: string;
begin
  Result := FRecordTypeName;
end;

function TLfpRecordObject.Inspect: string;
var
  I: Integer;
begin
  Result := '(' + FRecordTypeName;
  for I := 0 to FFields.Count - 1 do
    Result := Result + ' (' + FFields[I] + ' ' +
      LfpValueInspect(TLfpValueBox(FFields.Objects[I]).Value) + ')';
  Result := Result + ')';
end;

constructor TLfpPointerObject.Create(const InitialValue: TLfpValue);
begin
  inherited Create;
  FAlive := True;
  FValue := InitialValue;
end;

procedure TLfpPointerObject.DisposePointer;
begin
  if not FAlive then
    raise ELfpRuntimeError.Create('pointer has already been disposed');
  FAlive := False;
  FValue := LfpNil;
end;

function TLfpPointerObject.Dereference: TLfpValue;
begin
  if not FAlive then
    raise ELfpRuntimeError.Create('dereference of disposed pointer');
  Result := FValue;
end;

procedure TLfpPointerObject.Assign(const V: TLfpValue);
begin
  if not FAlive then
    raise ELfpRuntimeError.Create('assignment through disposed pointer');
  FValue := V;
end;

function TLfpPointerObject.TypeName: string;
begin
  Result := 'pointer';
end;

function TLfpPointerObject.Inspect: string;
begin
  if FAlive then
    Result := '<pointer ' + LfpValueInspect(FValue) + '>'
  else
    Result := '<disposed-pointer>';
end;

function LfpNil: TLfpValue;
begin
  Result.Kind := vkNil;
  Result.IntValue := 0;
  Result.RealValue := 0.0;
  Result.BoolValue := False;
  Result.StrValue := '';
  Result.ObjValue := nil;
end;

function LfpInt(V: Int64): TLfpValue;
begin
  Result := LfpNil;
  Result.Kind := vkInteger;
  Result.IntValue := V;
end;

function LfpReal(V: Double): TLfpValue;
begin
  Result := LfpNil;
  Result.Kind := vkReal;
  Result.RealValue := V;
end;

function LfpBool(V: Boolean): TLfpValue;
begin
  Result := LfpNil;
  Result.Kind := vkBoolean;
  Result.BoolValue := V;
end;

function LfpString(const V: UnicodeString): TLfpValue;
begin
  Result := LfpNil;
  Result.Kind := vkString;
  Result.StrValue := V;
end;

function LfpChar(V: WideChar): TLfpValue;
begin
  Result := LfpNil;
  Result.Kind := vkChar;
  Result.StrValue := V;
end;

function LfpObject(V: TLfpHeapObject): TLfpValue;
begin
  Result := LfpNil;
  Result.Kind := vkObject;
  Result.ObjValue := V;
end;

function LfpValueTypeName(const V: TLfpValue): string;
begin
  case V.Kind of
    vkNil: Result := 'nil';
    vkInteger: Result := 'Integer';
    vkReal: Result := 'Real';
    vkBoolean: Result := 'Boolean';
    vkString: Result := 'String';
    vkChar: Result := 'Char';
    vkObject:
      if Assigned(V.ObjValue) then Result := V.ObjValue.TypeName
      else Result := 'nil-object';
  else
    Result := 'unknown';
  end;
end;

function LfpValueInspect(const V: TLfpValue): string;
begin
  case V.Kind of
    vkNil: Result := 'nil';
    vkInteger: Result := IntToStr(V.IntValue);
    vkReal: Result := FloatToLfpString(V.RealValue);
    vkBoolean:
      if V.BoolValue then Result := 'true' else Result := 'false';
    vkString: Result := '"' + UTF8Encode(EscapeString(V.StrValue)) + '"';
    vkChar:
      if V.StrValue = ' ' then Result := '#\space'
      else if V.StrValue = #10 then Result := '#\newline'
      else if V.StrValue = #9 then Result := '#\tab'
      else if V.StrValue = #0 then Result := '#\null'
      else Result := '#\' + UTF8Encode(V.StrValue);
    vkObject:
      if Assigned(V.ObjValue) then Result := V.ObjValue.Inspect
      else Result := 'nil';
  else
    Result := '<unknown>';
  end;
end;

function LfpValueAsString(const V: TLfpValue): UnicodeString;
begin
  case V.Kind of
    vkNil: Result := 'nil';
    vkInteger: Result := UTF8Decode(IntToStr(V.IntValue));
    vkReal: Result := UTF8Decode(FloatToLfpString(V.RealValue));
    vkBoolean:
      if V.BoolValue then Result := 'true' else Result := 'false';
    vkString, vkChar: Result := V.StrValue;
    vkObject:
      if Assigned(V.ObjValue) then Result := UTF8Decode(V.ObjValue.Inspect)
      else Result := 'nil';
  else
    Result := '';
  end;
end;

function LfpIsNumeric(const V: TLfpValue): Boolean;
begin
  Result := V.Kind in [vkInteger, vkReal];
end;

function LfpToReal(const V: TLfpValue): Double;
begin
  case V.Kind of
    vkInteger: Result := V.IntValue;
    vkReal: Result := V.RealValue;
  else
    raise ELfpRuntimeError.CreateFmt('expected numeric value, got %s', [LfpValueTypeName(V)]);
  end;
end;

function LfpToInt(const V: TLfpValue): Int64;
const
  Int64UpperExclusive = 9223372036854775808.0;
  Int64LowerInclusive = -9223372036854775808.0;
begin
  case V.Kind of
    vkInteger: Result := V.IntValue;
    vkReal:
      begin
        if IsNan(V.RealValue) or IsInfinite(V.RealValue) or
           (V.RealValue < Int64LowerInclusive) or
           (V.RealValue >= Int64UpperExclusive) then
          raise ELfpRuntimeError.Create('real value is outside integer range');
        Result := Trunc(V.RealValue);
      end;
    vkChar:
      if V.StrValue <> '' then Result := Ord(V.StrValue[1])
      else Result := 0;
  else
    raise ELfpRuntimeError.CreateFmt('expected integer-compatible value, got %s', [LfpValueTypeName(V)]);
  end;
end;

function LfpTruthy(const V: TLfpValue): Boolean;
begin
  case V.Kind of
    vkNil: Result := False;
    vkBoolean: Result := V.BoolValue;
    vkInteger: Result := V.IntValue <> 0;
    vkReal: Result := V.RealValue <> 0.0;
    vkString, vkChar: Result := V.StrValue <> '';
    vkObject: Result := Assigned(V.ObjValue);
  else
    Result := False;
  end;
end;

function LfpValueEqual(const A, B: TLfpValue): Boolean;
var
  I: SizeInt;
begin
  if (A.Kind = vkInteger) and (B.Kind = vkInteger) then
    Exit(A.IntValue = B.IntValue);
  if (A.Kind = vkReal) and (B.Kind = vkReal) then
    Exit(A.RealValue = B.RealValue);
  if (A.Kind = vkInteger) and (B.Kind = vkReal) then
    Exit(RealEqualsInteger(B.RealValue, A.IntValue));
  if (A.Kind = vkReal) and (B.Kind = vkInteger) then
    Exit(RealEqualsInteger(A.RealValue, B.IntValue));
  if A.Kind <> B.Kind then Exit(False);
  case A.Kind of
    vkNil: Result := True;
    vkInteger: Result := A.IntValue = B.IntValue;
    vkReal: Result := A.RealValue = B.RealValue;
    vkBoolean: Result := A.BoolValue = B.BoolValue;
    vkString, vkChar: Result := A.StrValue = B.StrValue;
    vkObject:
      begin
        if (A.ObjValue is TLfpSetObject) and (B.ObjValue is TLfpSetObject) then
        begin
          if TLfpSetObject(A.ObjValue).Count <> TLfpSetObject(B.ObjValue).Count then
            Exit(False);
          for I := 0 to TLfpSetObject(A.ObjValue).Count - 1 do
            if not TLfpSetObject(B.ObjValue).Contains(
              TLfpSetObject(A.ObjValue).ItemAt(I)) then Exit(False);
          Result := True;
        end
        else if not Assigned(A.ObjValue) then
          Result := not Assigned(B.ObjValue)
        else
          Result := A.ObjValue.ValueEquals(B.ObjValue);
      end;
  else
    Result := False;
  end;
end;

end.
