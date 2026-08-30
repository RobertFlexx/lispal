unit lfp_vm;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Contnrs, Math, DateUtils, StrUtils, Crt, Character,
  Dynlibs, Keyboard, Mouse, Printer, Sockets,
  lfp_value, lfp_sexpr, lfp_jit
  {$IFDEF UNIX}, BaseUnix, Unix, UnixCp{$ENDIF}
  {$IFDEF LINUX}, Linux{$ENDIF}
  {$IFDEF WINDOWS}, WinDirs{$ENDIF};

type
  ELfpCompileError = class(Exception);
  ELfpHalt = class(Exception)
  public
    ExitCode: Integer;
    constructor CreateCode(ACode: Integer);
  end;

  TLfpEngine = class;

  TLfpNativeCallback = function(UserData: Pointer; Engine: TLfpEngine;
    const Args: TLfpValueArray): TLfpValue;

  TLfpOpCode = (
    opPushConst,
    opPushNil,
    opPop,
    opDup,
    opDup2,
    opLoadGlobal,
    opStoreGlobal,
    opLoadLocal,
    opStoreLocal,
    opAdd,
    opSub,
    opMul,
    opDivReal,
    opDivInt,
    opMod,
    opNeg,
    opEq,
    opNe,
    opLt,
    opLe,
    opGt,
    opGe,
    opNot,
    opJump,
    opJumpFalse,
    opJumpTrue,
    opCall,
    opReturn,
    opMakeArray,
    opMakeSet,
    opIndexGet,
    opIndexSet,
    opFieldGet,
    opFieldSet,
    opNewPointer,
    opDeref,
    opSetDeref,
    opDisposePointer
  );

  TLfpInstruction = record
    Op: TLfpOpCode;
    A: Integer;
    B: Integer;
    Pos: TLfpSourcePos;
  end;

  TLfpInstructionArray = array of TLfpInstruction;

  TLfpJitMode = (jmAuto, jmOff, jmOn);

  TLfpBytecodeFunction = class(TLfpHeapObject)
  private
    FName: string;
    FCode: TLfpInstructionArray;
    FConstants: TLfpValueArray;
    FParamNames: TStringList;
    FParamTypes: TStringList;
    FLocalNames: TStringList;
    FLocalTypes: TStringList;
    FLocalMutable: TStringList;
    FReturnType: string;
    FIsProcedure: Boolean;
    FJitCode: TLfpJitCode;
  public
    constructor Create(const AName: string);
    destructor Destroy; override;
    function Emit(Op: TLfpOpCode; A: Integer; B: Integer;
      const Pos: TLfpSourcePos): Integer;
    procedure PatchA(Index, A: Integer);
    function AddConstant(const V: TLfpValue): Integer;
    function AddLocal(const AName, ATypeName: string; Mutable: Boolean = True): Integer;
    function FindLocal(const Name: string): Integer;
    function LocalType(Index: Integer): string;
    function LocalMutable(Index: Integer): Boolean;
    procedure AddParam(const AName, ATypeName: string);
    function TypeName: string; override;
    function Inspect: string; override;
    property Name: string read FName;
    property Code: TLfpInstructionArray read FCode;
    property Constants: TLfpValueArray read FConstants;
    property ParamNames: TStringList read FParamNames;
    property ParamTypes: TStringList read FParamTypes;
    property LocalNames: TStringList read FLocalNames;
    property ReturnTypeName: string read FReturnType write FReturnType;
    property IsProcedure: Boolean read FIsProcedure write FIsProcedure;
  end;

  TLfpNativeFunctionObject = class(TLfpHeapObject)
  private
    FName: string;
    FCallback: TLfpNativeCallback;
    FUserData: Pointer;
    FMinArgs: Integer;
    FMaxArgs: Integer;
  public
    constructor Create(const AName: string; ACallback: TLfpNativeCallback;
      AUserData: Pointer; AMinArgs, AMaxArgs: Integer);
    function Invoke(Engine: TLfpEngine; const Args: TLfpValueArray): TLfpValue;
    function TypeName: string; override;
    function Inspect: string; override;
    property Name: string read FName;
  end;

  TLfpEnumValueObject = class(TLfpHeapObject)
  private
    FEnumName: string;
    FMemberName: string;
    FOrdinal: Integer;
  public
    constructor Create(const AEnumName, AMemberName: string; AOrdinal: Integer);
    function TypeName: string; override;
    function Inspect: string; override;
    function ValueEquals(Other: TLfpHeapObject): Boolean; override;
    property EnumName: string read FEnumName;
    property MemberName: string read FMemberName;
    property Ordinal: Integer read FOrdinal;
  end;

  TLfpTypeDefKind = (tdAlias, tdRecord, tdEnum);

  TLfpTypeDef = class
  private
    FName: string;
    FKind: TLfpTypeDefKind;
  public
    constructor Create(const AName: string; AKind: TLfpTypeDefKind);
    property Name: string read FName;
    property Kind: TLfpTypeDefKind read FKind;
  end;

  TLfpAliasTypeDef = class(TLfpTypeDef)
  private
    FTarget: string;
  public
    constructor Create(const AName, ATarget: string);
    property Target: string read FTarget;
  end;

  TLfpRecordTypeDef = class(TLfpTypeDef)
  private
    FFields: TStringList;
    FFieldTypes: TStringList;
  public
    constructor Create(const AName: string);
    destructor Destroy; override;
    procedure AddField(const AName, ATypeName: string);
    property Fields: TStringList read FFields;
    property FieldTypes: TStringList read FFieldTypes;
  end;

  TLfpEnumTypeDef = class(TLfpTypeDef)
  private
    FMembers: TStringList;
  public
    constructor Create(const AName: string);
    destructor Destroy; override;
    procedure AddMember(const AName: string);
    property Members: TStringList read FMembers;
  end;

  TLfpRecordConstructorObject = class(TLfpHeapObject)
  private
    FTypeDef: TLfpRecordTypeDef;
  public
    constructor Create(ATypeDef: TLfpRecordTypeDef);
    function TypeName: string; override;
    function Inspect: string; override;
    property TypeDef: TLfpRecordTypeDef read FTypeDef;
  end;

  TLfpBinding = class
  public
    Name: string;
    DeclaredType: string;
    Mutable: Boolean;
    Value: TLfpValue;
    AliasTarget: TLfpBinding;
    constructor Create(const AName, AType: string; AMutable: Boolean;
      const AValue: TLfpValue);
  end;

  TLfpEngine = class
  private
    FGlobals: TStringList;
    FTypes: TStringList;
    FHeap: TObjectList;
    FSearchPaths: TStringList;
    FLoadedUnits: TStringList;
    FTrace: Boolean;
    FJitMode: TLfpJitMode;
    FJitUsable: Boolean;
    FJitMessage: string;
    FJitCompiledFunctions: QWord;
    FJitCompiledBytes: QWord;
    FJitExecutions: QWord;
    FLastResult: TLfpValue;
    FGetOptNextChar: LongInt;
    FGetOptFirstNonOpt: LongInt;
    FGetOptLastNonOpt: LongInt;
    FGetOptOrdering: Integer;
    FHeapTraceOutput: string;
    function GlobalBinding(const Name: string): TLfpBinding;
    function FindTypeDef(const Name: string): TLfpTypeDef;
    function DefaultValueForType(const TypeName: string): TLfpValue;
    function ExecuteFunction(Func: TLfpBytecodeFunction;
      const Args: TLfpValueArray): TLfpValue;
    function ExecuteCallable(const Callee: TLfpValue;
      const Args: TLfpValueArray): TLfpValue;
    function EnsureJitCode(Func: TLfpBytecodeFunction): Boolean;
    procedure SetJitMode(Mode: TLfpJitMode);
    procedure RegisterStandardLibrary;
    function ResolveUnitFile(const Name: string): string;
  public
    constructor Create;
    destructor Destroy; override;
    function OwnObject(Obj: TLfpHeapObject): TLfpHeapObject;
    procedure DefineGlobal(const Name, TypeName: string; Mutable: Boolean;
      const Value: TLfpValue; ReplaceExisting: Boolean = False);
    procedure DefineGlobalAlias(const Name: string; Target: TLfpBinding);
    function HasGlobal(const Name: string): Boolean;
    function GetGlobal(const Name: string): TLfpValue;
    procedure SetGlobal(const Name: string; const Value: TLfpValue);
    function ValueMatchesType(const V: TLfpValue; const TypeName: string): Boolean;
    procedure RequireType(const V: TLfpValue; const TypeName, Context: string);
    procedure RegisterNative(const Name: string; Callback: TLfpNativeCallback;
      UserData: Pointer = nil; MinArgs: Integer = 0; MaxArgs: Integer = -1);
    procedure AddSearchPath(const Path: string);
    procedure RegisterType(TypeDef: TLfpTypeDef);
    function Eval(const Source: UnicodeString;
      const FileName: string = '<string>'): TLfpValue;
    function EvalFile(const FileName: string): TLfpValue;
    function RequireUnit(const Name: string): TLfpValue;
    function Disassemble(const Source: UnicodeString;
      const FileName: string = '<string>'): string;
    function GlobalsReport: string;
    function TypesReport: string;
    function SearchPathsReport: string;
    function JitStatus: string;
    property Trace: Boolean read FTrace write FTrace;
    property JitMode: TLfpJitMode read FJitMode write SetJitMode;
    property JitCompiledFunctions: QWord read FJitCompiledFunctions;
    property JitCompiledBytes: QWord read FJitCompiledBytes;
    property JitExecutions: QWord read FJitExecutions;
    property LastResult: TLfpValue read FLastResult;
  end;

function LfpOpcodeName(Op: TLfpOpCode): string;

implementation

type
  TLfpIntBox = class
  public
    Value: Integer;
    constructor Create(AValue: Integer);
  end;

  TLfpLoopContext = class
  public
    BreakPatches: TList;
    ContinuePatches: TList;
    ContinueTarget: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  TLfpGotoPatch = class
  public
    Name: string;
    InstructionIndex: Integer;
    Pos: TLfpSourcePos;
  end;

  TLfpCompiler = class
  private
    FEngine: TLfpEngine;
    FFunction: TLfpBytecodeFunction;
    FTopLevel: Boolean;
    FLoops: TObjectList;
    FWithSlots: TList;
    FLabels: TStringList;
    FGotos: TObjectList;
    function Error(Node: TLfpNode; const Msg: string): Exception;
    function TypeSpec(Node: TLfpNode): string;
    function AddStringConstant(const S: UnicodeString): Integer;
    procedure EmitPushNil(Node: TLfpNode);
    procedure CompileAtom(Node: TLfpNode);
    procedure CompileList(Node: TLfpNode);
    procedure CompileBegin(Node: TLfpNode; StartAt: Integer = 1);
    procedure CompileIf(Node: TLfpNode);
    procedure CompileWhenUnless(Node: TLfpNode; IsUnless: Boolean);
    procedure CompileCond(Node: TLfpNode);
    procedure CompileLambda(Node: TLfpNode);
    procedure CompileWhile(Node: TLfpNode);
    procedure CompileRepeat(Node: TLfpNode);
    procedure CompileFor(Node: TLfpNode);
    procedure CompileCase(Node: TLfpNode);
    procedure CompileWith(Node: TLfpNode);
    procedure CompileVar(Node: TLfpNode; IsConst: Boolean);
    procedure CompileSet(Node: TLfpNode);
    procedure CompileIncDec(Node: TLfpNode; Delta: Integer);
    procedure CompileBoolean(Node: TLfpNode; IsAnd: Boolean);
    procedure CompileOperator(Node: TLfpNode; Op: TLfpOpCode; UnaryAllowed: Boolean = False);
    procedure CompileCall(Node: TLfpNode);
    procedure CompileAssignTarget(Target: TLfpNode; const Pos: TLfpSourcePos);
    procedure CompileLoadTarget(Target: TLfpNode);
    procedure CompileBreakContinue(Node: TLfpNode; IsBreak: Boolean);
    procedure CompileLabel(Node: TLfpNode);
    procedure CompileGoto(Node: TLfpNode);
    procedure ResolveGotos;
    function CurrentLoop: TLfpLoopContext;
    function CurrentWithSlot: Integer;
    function EnsureVariable(const Name, TypeName: string; Node: TLfpNode): Integer;
    function IsLocal(const Name: string; out Slot: Integer): Boolean;
  public
    constructor Create(Engine: TLfpEngine; Func: TLfpBytecodeFunction;
      TopLevel: Boolean);
    destructor Destroy; override;
    procedure Compile(Node: TLfpNode);
    procedure Finish;
  end;

function NodeAtomText(Node: TLfpNode; const What: string): string;
begin
  if Node = nil then
    raise ELfpCompileError.Create('expected ' + What);
  if Node.Kind <> nkAtom then
    raise ELfpCompileError.Create(LfpPosString(Node.Pos) + ': expected ' + What);
  Result := UTF8Encode(Node.Text);
end;

function ZeroSourcePos: TLfpSourcePos;
begin
  Result.FileName := '<generated>';
  Result.Line := 0;
  Result.Column := 0;
end;

function ReadTextFile(const FileName: string): UnicodeString;
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

function LfpOpcodeName(Op: TLfpOpCode): string;
begin
  case Op of
    opPushConst: Result := 'PUSH_CONST';
    opPushNil: Result := 'PUSH_NIL';
    opPop: Result := 'POP';
    opDup: Result := 'DUP';
    opDup2: Result := 'DUP2';
    opLoadGlobal: Result := 'LOAD_GLOBAL';
    opStoreGlobal: Result := 'STORE_GLOBAL';
    opLoadLocal: Result := 'LOAD_LOCAL';
    opStoreLocal: Result := 'STORE_LOCAL';
    opAdd: Result := 'ADD';
    opSub: Result := 'SUB';
    opMul: Result := 'MUL';
    opDivReal: Result := 'DIV_REAL';
    opDivInt: Result := 'DIV_INT';
    opMod: Result := 'MOD';
    opNeg: Result := 'NEG';
    opEq: Result := 'EQ';
    opNe: Result := 'NE';
    opLt: Result := 'LT';
    opLe: Result := 'LE';
    opGt: Result := 'GT';
    opGe: Result := 'GE';
    opNot: Result := 'NOT';
    opJump: Result := 'JUMP';
    opJumpFalse: Result := 'JUMP_FALSE';
    opJumpTrue: Result := 'JUMP_TRUE';
    opCall: Result := 'CALL';
    opReturn: Result := 'RETURN';
    opMakeArray: Result := 'MAKE_ARRAY';
    opMakeSet: Result := 'MAKE_SET';
    opIndexGet: Result := 'INDEX_GET';
    opIndexSet: Result := 'INDEX_SET';
    opFieldGet: Result := 'FIELD_GET';
    opFieldSet: Result := 'FIELD_SET';
    opNewPointer: Result := 'NEW_POINTER';
    opDeref: Result := 'DEREF';
    opSetDeref: Result := 'SET_DEREF';
    opDisposePointer: Result := 'DISPOSE_POINTER';
  else
    Result := '?';
  end;
end;

function CheckedIntAdd(A, B: Int64): Int64;
begin
  if ((B > 0) and (A > High(Int64) - B)) or
     ((B < 0) and (A < Low(Int64) - B)) then
    raise ELfpRuntimeError.Create('integer overflow');
  Result := A + B;
end;

function CheckedIntSub(A, B: Int64): Int64;
begin
  if ((B > 0) and (A < Low(Int64) + B)) or
     ((B < 0) and (A > High(Int64) + B)) then
    raise ELfpRuntimeError.Create('integer overflow');
  Result := A - B;
end;

function CheckedIntMul(A, B: Int64): Int64;
begin
  if (A = 0) or (B = 0) then Exit(0);
  if ((A = Low(Int64)) and (B = -1)) or
     ((B = Low(Int64)) and (A = -1)) then
    raise ELfpRuntimeError.Create('integer overflow');
  if A > 0 then
  begin
    if ((B > 0) and (A > High(Int64) div B)) or
       ((B < 0) and (B < Low(Int64) div A)) then
      raise ELfpRuntimeError.Create('integer overflow');
  end
  else
  begin
    if ((B > 0) and (A < Low(Int64) div B)) or
       ((B < 0) and (A < High(Int64) div B)) then
      raise ELfpRuntimeError.Create('integer overflow');
  end;
  Result := A * B;
end;

function CheckedIntNeg(A: Int64): Int64;
begin
  if A = Low(Int64) then
    raise ELfpRuntimeError.Create('integer overflow');
  Result := -A;
end;

function CheckedIntDiv(A, B: Int64): Int64;
begin
  if B = 0 then
    raise ELfpRuntimeError.Create('division by zero');
  if (A = Low(Int64)) and (B = -1) then
    raise ELfpRuntimeError.Create('integer overflow');
  Result := A div B;
end;

function CheckedIntMod(A, B: Int64): Int64;
begin
  if B = 0 then
    raise ELfpRuntimeError.Create('modulo by zero');
  if (A = Low(Int64)) and (B = -1) then Exit(0);
  Result := A mod B;
end;

constructor ELfpHalt.CreateCode(ACode: Integer);
begin
  ExitCode := ACode;
  inherited CreateFmt('program halted with exit code %d', [ACode]);
end;

constructor TLfpIntBox.Create(AValue: Integer);
begin
  inherited Create;
  Value := AValue;
end;

constructor TLfpLoopContext.Create;
begin
  inherited Create;
  BreakPatches := TList.Create;
  ContinuePatches := TList.Create;
  ContinueTarget := -1;
end;

destructor TLfpLoopContext.Destroy;
begin
  BreakPatches.Free;
  ContinuePatches.Free;
  inherited Destroy;
end;

constructor TLfpBytecodeFunction.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
  FParamNames := TStringList.Create;
  FParamNames.CaseSensitive := False;
  FParamTypes := TStringList.Create;
  FLocalNames := TStringList.Create;
  FLocalNames.CaseSensitive := False;
  FLocalTypes := TStringList.Create;
  FLocalMutable := TStringList.Create;
  FReturnType := 'Variant';
  FIsProcedure := False;
  FJitCode := nil;
end;

destructor TLfpBytecodeFunction.Destroy;
begin
  FJitCode.Free;
  FParamNames.Free;
  FParamTypes.Free;
  FLocalNames.Free;
  FLocalTypes.Free;
  FLocalMutable.Free;
  inherited Destroy;
end;

function TLfpBytecodeFunction.Emit(Op: TLfpOpCode; A: Integer; B: Integer;
  const Pos: TLfpSourcePos): Integer;
var
  N: Integer;
begin
  FreeAndNil(FJitCode);
  N := System.Length(FCode);
  SetLength(FCode, N + 1);
  FCode[N].Op := Op;
  FCode[N].A := A;
  FCode[N].B := B;
  FCode[N].Pos := Pos;
  Result := N;
end;

procedure TLfpBytecodeFunction.PatchA(Index, A: Integer);
begin
  if (Index < 0) or (Index > High(FCode)) then
    raise Exception.Create('internal: invalid bytecode patch index');
  FreeAndNil(FJitCode);
  FCode[Index].A := A;
end;

function TLfpBytecodeFunction.AddConstant(const V: TLfpValue): Integer;
var
  N: Integer;
begin
  N := System.Length(FConstants);
  SetLength(FConstants, N + 1);
  FConstants[N] := V;
  Result := N;
end;

function TLfpBytecodeFunction.AddLocal(const AName, ATypeName: string;
  Mutable: Boolean): Integer;
begin
  Result := FLocalNames.IndexOf(AName);
  if Result >= 0 then Exit;
  Result := FLocalNames.Count;
  FLocalNames.Add(AName);
  FLocalTypes.Add(ATypeName);
  if Mutable then FLocalMutable.Add('1') else FLocalMutable.Add('0');
end;

function TLfpBytecodeFunction.FindLocal(const Name: string): Integer;
begin
  Result := FLocalNames.IndexOf(Name);
end;

function TLfpBytecodeFunction.LocalType(Index: Integer): string;
begin
  if (Index < 0) or (Index >= FLocalTypes.Count) then Result := 'Variant'
  else Result := FLocalTypes[Index];
end;

function TLfpBytecodeFunction.LocalMutable(Index: Integer): Boolean;
begin
  if (Index < 0) or (Index >= FLocalMutable.Count) then Result := True
  else Result := FLocalMutable[Index] <> '0';
end;

procedure TLfpBytecodeFunction.AddParam(const AName, ATypeName: string);
begin
  FParamNames.Add(AName);
  FParamTypes.Add(ATypeName);
  AddLocal(AName, ATypeName);
end;

function TLfpBytecodeFunction.TypeName: string;
begin
  Result := 'function';
end;

function TLfpBytecodeFunction.Inspect: string;
begin
  Result := '<bytecode ' + FName + '>';
end;

constructor TLfpNativeFunctionObject.Create(const AName: string;
  ACallback: TLfpNativeCallback; AUserData: Pointer; AMinArgs, AMaxArgs: Integer);
begin
  inherited Create;
  FName := AName;
  FCallback := ACallback;
  FUserData := AUserData;
  FMinArgs := AMinArgs;
  FMaxArgs := AMaxArgs;
end;

function TLfpNativeFunctionObject.Invoke(Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  if System.Length(Args) < FMinArgs then
    raise ELfpRuntimeError.CreateFmt('%s expects at least %d argument(s), got %d',
      [FName, FMinArgs, System.Length(Args)]);
  if (FMaxArgs >= 0) and (System.Length(Args) > FMaxArgs) then
    raise ELfpRuntimeError.CreateFmt('%s expects at most %d argument(s), got %d',
      [FName, FMaxArgs, System.Length(Args)]);
  if not Assigned(FCallback) then
    raise ELfpRuntimeError.Create('native function has no callback: ' + FName);
  Result := FCallback(FUserData, Engine, Args);
end;

function TLfpNativeFunctionObject.TypeName: string;
begin
  Result := 'native-function';
end;

function TLfpNativeFunctionObject.Inspect: string;
begin
  Result := '<native ' + FName + '>';
end;

constructor TLfpEnumValueObject.Create(const AEnumName, AMemberName: string;
  AOrdinal: Integer);
begin
  inherited Create;
  FEnumName := AEnumName;
  FMemberName := AMemberName;
  FOrdinal := AOrdinal;
end;

function TLfpEnumValueObject.TypeName: string;
begin
  Result := FEnumName;
end;

function TLfpEnumValueObject.Inspect: string;
begin
  Result := FEnumName + '.' + FMemberName;
end;

function TLfpEnumValueObject.ValueEquals(Other: TLfpHeapObject): Boolean;
begin
  Result := (Other is TLfpEnumValueObject) and
    SameText(FEnumName, TLfpEnumValueObject(Other).EnumName) and
    (FOrdinal = TLfpEnumValueObject(Other).Ordinal);
end;

constructor TLfpTypeDef.Create(const AName: string; AKind: TLfpTypeDefKind);
begin
  inherited Create;
  FName := AName;
  FKind := AKind;
end;

constructor TLfpAliasTypeDef.Create(const AName, ATarget: string);
begin
  inherited Create(AName, tdAlias);
  FTarget := ATarget;
end;

constructor TLfpRecordTypeDef.Create(const AName: string);
begin
  inherited Create(AName, tdRecord);
  FFields := TStringList.Create;
  FFields.CaseSensitive := False;
  FFieldTypes := TStringList.Create;
end;

destructor TLfpRecordTypeDef.Destroy;
begin
  FFields.Free;
  FFieldTypes.Free;
  inherited Destroy;
end;

procedure TLfpRecordTypeDef.AddField(const AName, ATypeName: string);
begin
  if FFields.IndexOf(AName) >= 0 then
    raise ELfpCompileError.CreateFmt('duplicate field %s.%s', [Self.Name, AName]);
  FFields.Add(AName);
  FFieldTypes.Add(ATypeName);
end;

constructor TLfpEnumTypeDef.Create(const AName: string);
begin
  inherited Create(AName, tdEnum);
  FMembers := TStringList.Create;
  FMembers.CaseSensitive := False;
end;

destructor TLfpEnumTypeDef.Destroy;
begin
  FMembers.Free;
  inherited Destroy;
end;

procedure TLfpEnumTypeDef.AddMember(const AName: string);
begin
  if FMembers.IndexOf(AName) >= 0 then
    raise ELfpCompileError.CreateFmt('duplicate enum member %s.%s', [Self.Name, AName]);
  FMembers.Add(AName);
end;

constructor TLfpRecordConstructorObject.Create(ATypeDef: TLfpRecordTypeDef);
begin
  inherited Create;
  FTypeDef := ATypeDef;
end;

function TLfpRecordConstructorObject.TypeName: string;
begin
  Result := 'record-constructor';
end;

function TLfpRecordConstructorObject.Inspect: string;
begin
  Result := '<record-constructor ' + FTypeDef.Name + '>';
end;

constructor TLfpBinding.Create(const AName, AType: string; AMutable: Boolean;
  const AValue: TLfpValue);
begin
  inherited Create;
  Name := AName;
  DeclaredType := AType;
  Mutable := AMutable;
  Value := AValue;
  AliasTarget := nil;
end;

constructor TLfpCompiler.Create(Engine: TLfpEngine; Func: TLfpBytecodeFunction;
  TopLevel: Boolean);
begin
  inherited Create;
  FEngine := Engine;
  FFunction := Func;
  FTopLevel := TopLevel;
  FLoops := TObjectList.Create(True);
  FWithSlots := TList.Create;
  FLabels := TStringList.Create;
  FLabels.CaseSensitive := False;
  FLabels.Sorted := True;
  FLabels.Duplicates := dupError;
  FLabels.OwnsObjects := True;
  FGotos := TObjectList.Create(True);
end;

destructor TLfpCompiler.Destroy;
begin
  FGotos.Free;
  FLabels.Free;
  FWithSlots.Free;
  FLoops.Free;
  inherited Destroy;
end;

function TLfpCompiler.Error(Node: TLfpNode; const Msg: string): Exception;
begin
  Result := ELfpCompileError.Create(LfpPosString(Node.Pos) + ': ' + Msg);
end;

function TLfpCompiler.TypeSpec(Node: TLfpNode): string;
begin
  if Node.Kind = nkAtom then Result := UTF8Encode(Node.Text)
  else Result := Node.DebugString;
end;

function TLfpCompiler.AddStringConstant(const S: UnicodeString): Integer;
begin
  Result := FFunction.AddConstant(LfpString(S));
end;

procedure TLfpCompiler.EmitPushNil(Node: TLfpNode);
begin
  FFunction.Emit(opPushNil, 0, 0, Node.Pos);
end;

function ParseIntegerAtom(const S: string; out V: Int64): Boolean;
var
  Code: Integer;
  T: string;
begin
  T := S;
  if (Length(T) > 2) and (Copy(T, 1, 2) = '0x') then T := '$' + Copy(T, 3, MaxInt);
  Val(T, V, Code);
  Result := Code = 0;
end;

function ParseRealAtom(const S: string; out V: Double): Boolean;
var
  FS: TFormatSettings;
  T: string;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  T := S;
  Result := TryStrToFloat(T, V, FS) and
    ((Pos('.', T) > 0) or (Pos('e', LowerCase(T)) > 0));
end;

function QuoteNodeValue(Engine: TLfpEngine; Node: TLfpNode): TLfpValue;
var
  I: Integer;
  N: Int64;
  R: Double;
  S: string;
  A: TLfpArrayObject;
begin
  case Node.Kind of
    nkString:
      Exit(LfpString(Node.Text));
    nkChar:
      Exit(LfpChar(Node.Text[1]));
    nkAtom:
      begin
        S := UTF8Encode(Node.Text);
        if SameText(S, 'nil') then Exit(LfpNil);
        if SameText(S, 'true') then Exit(LfpBool(True));
        if SameText(S, 'false') then Exit(LfpBool(False));
        if ParseIntegerAtom(S, N) then Exit(LfpInt(N));
        if ParseRealAtom(S, R) then Exit(LfpReal(R));
        Exit(LfpString(Node.Text));
      end;
    nkList:
      begin
        A := TLfpArrayObject(Engine.OwnObject(TLfpArrayObject.Create(0)));
        for I := 0 to Node.Count - 1 do
          A.Append(QuoteNodeValue(Engine, Node.Child(I)));
        Exit(LfpObject(A));
      end;
  end;
  Result := LfpNil;
end;

procedure TLfpCompiler.CompileAtom(Node: TLfpNode);
var
  S: string;
  I: Int64;
  R: Double;
  Slot, C: Integer;
begin
  if Node.Kind = nkString then
  begin
    C := FFunction.AddConstant(LfpString(Node.Text));
    FFunction.Emit(opPushConst, C, 0, Node.Pos);
    Exit;
  end;
  if Node.Kind = nkChar then
  begin
    C := FFunction.AddConstant(LfpChar(Node.Text[1]));
    FFunction.Emit(opPushConst, C, 0, Node.Pos);
    Exit;
  end;

  S := UTF8Encode(Node.Text);
  if SameText(S, 'nil') then EmitPushNil(Node)
  else if SameText(S, 'true') then
    FFunction.Emit(opPushConst, FFunction.AddConstant(LfpBool(True)), 0, Node.Pos)
  else if SameText(S, 'false') then
    FFunction.Emit(opPushConst, FFunction.AddConstant(LfpBool(False)), 0, Node.Pos)
  else if ParseIntegerAtom(S, I) then
    FFunction.Emit(opPushConst, FFunction.AddConstant(LfpInt(I)), 0, Node.Pos)
  else if ParseRealAtom(S, R) then
    FFunction.Emit(opPushConst, FFunction.AddConstant(LfpReal(R)), 0, Node.Pos)
  else if IsLocal(S, Slot) then
    FFunction.Emit(opLoadLocal, Slot, 0, Node.Pos)
  else if (CurrentWithSlot >= 0) and not FEngine.HasGlobal(S) then
  begin
    FFunction.Emit(opLoadLocal, CurrentWithSlot, 0, Node.Pos);
    C := AddStringConstant(Node.Text);
    FFunction.Emit(opFieldGet, C, 0, Node.Pos);
  end
  else
  begin
    C := AddStringConstant(Node.Text);
    FFunction.Emit(opLoadGlobal, C, 0, Node.Pos);
  end;
end;

procedure TLfpCompiler.CompileBegin(Node: TLfpNode; StartAt: Integer);
var
  I: Integer;
begin
  if Node.Count <= StartAt then
  begin
    EmitPushNil(Node);
    Exit;
  end;
  for I := StartAt to Node.Count - 1 do
  begin
    Compile(Node.Child(I));
    if I < Node.Count - 1 then
      FFunction.Emit(opPop, 0, 0, Node.Child(I).Pos);
  end;
end;

procedure TLfpCompiler.CompileIf(Node: TLfpNode);
var
  JFalse, JEnd: Integer;
begin
  if (Node.Count < 3) or (Node.Count > 4) then
    raise Error(Node, '(if condition then [else]) expects 2 or 3 operands');
  Compile(Node.Child(1));
  JFalse := FFunction.Emit(opJumpFalse, -1, 0, Node.Pos);
  Compile(Node.Child(2));
  JEnd := FFunction.Emit(opJump, -1, 0, Node.Pos);
  FFunction.PatchA(JFalse, System.Length(FFunction.Code));
  if Node.Count = 4 then Compile(Node.Child(3)) else EmitPushNil(Node);
  FFunction.PatchA(JEnd, System.Length(FFunction.Code));
end;

procedure TLfpCompiler.CompileWhenUnless(Node: TLfpNode; IsUnless: Boolean);
var
  JSkip, JEnd, I: Integer;
begin
  if Node.Count < 3 then
  begin
    if IsUnless then
      raise Error(Node, '(unless condition body...) requires a body')
    else
      raise Error(Node, '(when condition body...) requires a body');
  end;
  Compile(Node.Child(1));
  if IsUnless then
    JSkip := FFunction.Emit(opJumpTrue, -1, 0, Node.Pos)
  else
    JSkip := FFunction.Emit(opJumpFalse, -1, 0, Node.Pos);
  for I := 2 to Node.Count - 1 do
  begin
    Compile(Node.Child(I));
    if I < Node.Count - 1 then
      FFunction.Emit(opPop, 0, 0, Node.Child(I).Pos);
  end;
  JEnd := FFunction.Emit(opJump, -1, 0, Node.Pos);
  FFunction.PatchA(JSkip, System.Length(FFunction.Code));
  EmitPushNil(Node);
  FFunction.PatchA(JEnd, System.Length(FFunction.Code));
end;

procedure TLfpCompiler.CompileCond(Node: TLfpNode);
var
  I, J, JNext, JEnd: Integer;
  Clause: TLfpNode;
  EndPatches: TList;
begin
  if Node.Count < 2 then
  begin
    EmitPushNil(Node);
    Exit;
  end;
  EndPatches := TList.Create;
  try
    for I := 1 to Node.Count - 1 do
    begin
      Clause := Node.Child(I);
      if (Clause.Kind <> nkList) or (Clause.Count < 2) then
        raise Error(Clause, 'cond clause must be (condition body...)');
      if Clause.Child(0).IsAtom('else') then
      begin
        if I <> Node.Count - 1 then
          raise Error(Clause, 'else must be the final cond clause');
        for J := 1 to Clause.Count - 1 do
        begin
          Compile(Clause.Child(J));
          if J < Clause.Count - 1 then
            FFunction.Emit(opPop, 0, 0, Clause.Child(J).Pos);
        end;
        JEnd := FFunction.Emit(opJump, -1, 0, Clause.Pos);
        EndPatches.Add(Pointer(PtrInt(JEnd)));
        Break;
      end;

      Compile(Clause.Child(0));
      JNext := FFunction.Emit(opJumpFalse, -1, 0, Clause.Pos);
      for J := 1 to Clause.Count - 1 do
      begin
        Compile(Clause.Child(J));
        if J < Clause.Count - 1 then
          FFunction.Emit(opPop, 0, 0, Clause.Child(J).Pos);
      end;
      JEnd := FFunction.Emit(opJump, -1, 0, Clause.Pos);
      EndPatches.Add(Pointer(PtrInt(JEnd)));
      FFunction.PatchA(JNext, System.Length(FFunction.Code));
    end;
    EmitPushNil(Node);
    for I := 0 to EndPatches.Count - 1 do
      FFunction.PatchA(PtrInt(EndPatches[I]), System.Length(FFunction.Code));
  finally
    EndPatches.Free;
  end;
end;

procedure TLfpCompiler.CompileLambda(Node: TLfpNode);
var
  Params, P: TLfpNode;
  F: TLfpBytecodeFunction;
  C: TLfpCompiler;
  I: Integer;
  LambdaName, ParamName, ParamType: string;
begin
  if Node.Count < 4 then
    raise Error(Node, '(lambda ((name Type) ...) ReturnType body...) expected');
  Params := Node.Child(1);
  if Params.Kind <> nkList then
    raise Error(Params, 'lambda parameter list must be a list');

  LambdaName := Format('<lambda@%s:%d:%d>',
    [Node.Pos.FileName, Node.Pos.Line, Node.Pos.Column]);
  F := TLfpBytecodeFunction(FEngine.OwnObject(TLfpBytecodeFunction.Create(LambdaName)));
  F.IsProcedure := False;
  F.ReturnTypeName := TypeSpec(Node.Child(2));

  for I := 0 to Params.Count - 1 do
  begin
    P := Params.Child(I);
    if (P.Kind <> nkList) or (P.Count <> 2) then
      raise Error(P, 'lambda parameter must be (name Type)');
    ParamName := NodeAtomText(P.Child(0), 'lambda parameter name');
    ParamType := TypeSpec(P.Child(1));
    F.AddParam(ParamName, ParamType);
  end;

  C := TLfpCompiler.Create(FEngine, F, False);
  try
    for I := 3 to Node.Count - 1 do
    begin
      C.Compile(Node.Child(I));
      if I < Node.Count - 1 then
        F.Emit(opPop, 0, 0, Node.Child(I).Pos);
    end;
    F.Emit(opReturn, 0, 0, Node.Pos);
    C.Finish;
  finally
    C.Free;
  end;

  FFunction.Emit(opPushConst, FFunction.AddConstant(LfpObject(F)), 0, Node.Pos);
end;

function TLfpCompiler.CurrentLoop: TLfpLoopContext;
begin
  if FLoops.Count = 0 then Result := nil
  else Result := TLfpLoopContext(FLoops[FLoops.Count - 1]);
end;

function TLfpCompiler.CurrentWithSlot: Integer;
begin
  if FWithSlots.Count = 0 then Result := -1
  else Result := PtrInt(FWithSlots[FWithSlots.Count - 1]);
end;

procedure TLfpCompiler.CompileWhile(Node: TLfpNode);
var
  LoopStart, JExit, I: Integer;
  Ctx: TLfpLoopContext;
begin
  if Node.Count < 3 then raise Error(Node, '(while condition body...) requires a body');
  LoopStart := System.Length(FFunction.Code);
  Compile(Node.Child(1));
  JExit := FFunction.Emit(opJumpFalse, -1, 0, Node.Pos);
  Ctx := TLfpLoopContext.Create;
  Ctx.ContinueTarget := LoopStart;
  FLoops.Add(Ctx);
  for I := 2 to Node.Count - 1 do
  begin
    Compile(Node.Child(I));
    FFunction.Emit(opPop, 0, 0, Node.Child(I).Pos);
  end;
  FFunction.Emit(opJump, LoopStart, 0, Node.Pos);
  FFunction.PatchA(JExit, System.Length(FFunction.Code));
  for I := 0 to Ctx.BreakPatches.Count - 1 do
    FFunction.PatchA(PtrInt(Ctx.BreakPatches[I]), System.Length(FFunction.Code));
  for I := 0 to Ctx.ContinuePatches.Count - 1 do
    FFunction.PatchA(PtrInt(Ctx.ContinuePatches[I]), Ctx.ContinueTarget);
  FLoops.Extract(Ctx);
  Ctx.Free;
  EmitPushNil(Node);
end;

procedure TLfpCompiler.CompileRepeat(Node: TLfpNode);
var
  UntilIndex, LoopStart, I: Integer;
  Ctx: TLfpLoopContext;
begin
  if Node.Count < 3 then
    raise Error(Node, '(repeat body... (until condition)) requires body and until');
  UntilIndex := Node.Count - 1;
  if not Node.Child(UntilIndex).HeadIs('until') or (Node.Child(UntilIndex).Count <> 2) then
    raise Error(Node.Child(UntilIndex), 'repeat must end with (until condition)');
  LoopStart := System.Length(FFunction.Code);
  Ctx := TLfpLoopContext.Create;
  FLoops.Add(Ctx);
  for I := 1 to UntilIndex - 1 do
  begin
    Compile(Node.Child(I));
    FFunction.Emit(opPop, 0, 0, Node.Child(I).Pos);
  end;
  Ctx.ContinueTarget := System.Length(FFunction.Code);
  Compile(Node.Child(UntilIndex).Child(1));
  FFunction.Emit(opJumpFalse, LoopStart, 0, Node.Pos);
  for I := 0 to Ctx.BreakPatches.Count - 1 do
    FFunction.PatchA(PtrInt(Ctx.BreakPatches[I]), System.Length(FFunction.Code));
  for I := 0 to Ctx.ContinuePatches.Count - 1 do
    FFunction.PatchA(PtrInt(Ctx.ContinuePatches[I]), Ctx.ContinueTarget);
  FLoops.Extract(Ctx);
  Ctx.Free;
  EmitPushNil(Node);
end;

function TLfpCompiler.IsLocal(const Name: string; out Slot: Integer): Boolean;
begin
  Slot := FFunction.FindLocal(Name);
  Result := Slot >= 0;
end;

function TLfpCompiler.EnsureVariable(const Name, TypeName: string;
  Node: TLfpNode): Integer;
begin
  if FTopLevel then
  begin
    if not FEngine.HasGlobal(Name) then
      FEngine.DefineGlobal(Name, TypeName, True, FEngine.DefaultValueForType(TypeName));
    Result := -1;
  end
  else
    Result := FFunction.AddLocal(Name, TypeName);
end;

procedure TLfpCompiler.CompileFor(Node: TLfpNode);
var
  Spec: TLfpNode;
  Name, Direction: string;
  Slot, TempEnd, LoopStart, JExit, I, C: Integer;
  Ctx: TLfpLoopContext;
  IsDown: Boolean;
begin
  if Node.Count < 3 then raise Error(Node, '(for (i start to end) body...) expected');
  Spec := Node.Child(1);
  if (Spec.Kind <> nkList) or (Spec.Count <> 4) then
    raise Error(Spec, 'for spec must be (name start to|downto end)');
  Name := NodeAtomText(Spec.Child(0), 'for variable');
  Direction := NodeAtomText(Spec.Child(2), 'to or downto');
  IsDown := SameText(Direction, 'downto');
  if not IsDown and not SameText(Direction, 'to') then
    raise Error(Spec.Child(2), 'expected to or downto');

  Slot := FFunction.FindLocal(Name);
  if (Slot < 0) and not FTopLevel and not FEngine.HasGlobal(Name) then
    Slot := EnsureVariable(Name, 'Integer', Node);
  if FTopLevel and not FEngine.HasGlobal(Name) then
    EnsureVariable(Name, 'Integer', Node);

  Compile(Spec.Child(1));
  if Slot >= 0 then FFunction.Emit(opStoreLocal, Slot, 0, Spec.Pos)
  else
  begin
    C := AddStringConstant(UTF8Decode(Name));
    FFunction.Emit(opStoreGlobal, C, 0, Spec.Pos);
  end;
  FFunction.Emit(opPop, 0, 0, Spec.Pos);

  TempEnd := FFunction.AddLocal('$for_end_' + IntToStr(System.Length(FFunction.Code)), 'Variant');
  Compile(Spec.Child(3));
  FFunction.Emit(opStoreLocal, TempEnd, 0, Spec.Child(3).Pos);
  FFunction.Emit(opPop, 0, 0, Spec.Child(3).Pos);

  LoopStart := System.Length(FFunction.Code);
  if Slot >= 0 then FFunction.Emit(opLoadLocal, Slot, 0, Spec.Pos)
  else FFunction.Emit(opLoadGlobal, AddStringConstant(UTF8Decode(Name)), 0, Spec.Pos);
  FFunction.Emit(opLoadLocal, TempEnd, 0, Spec.Pos);
  if IsDown then FFunction.Emit(opGe, 0, 0, Spec.Pos)
  else FFunction.Emit(opLe, 0, 0, Spec.Pos);
  JExit := FFunction.Emit(opJumpFalse, -1, 0, Spec.Pos);

  Ctx := TLfpLoopContext.Create;
  FLoops.Add(Ctx);
  for I := 2 to Node.Count - 1 do
  begin
    Compile(Node.Child(I));
    FFunction.Emit(opPop, 0, 0, Node.Child(I).Pos);
  end;
  Ctx.ContinueTarget := System.Length(FFunction.Code);

  if Slot >= 0 then FFunction.Emit(opLoadLocal, Slot, 0, Spec.Pos)
  else FFunction.Emit(opLoadGlobal, AddStringConstant(UTF8Decode(Name)), 0, Spec.Pos);
  FFunction.Emit(opPushConst, FFunction.AddConstant(LfpInt(1)), 0, Spec.Pos);
  if IsDown then FFunction.Emit(opSub, 0, 0, Spec.Pos)
  else FFunction.Emit(opAdd, 0, 0, Spec.Pos);
  if Slot >= 0 then FFunction.Emit(opStoreLocal, Slot, 0, Spec.Pos)
  else FFunction.Emit(opStoreGlobal, AddStringConstant(UTF8Decode(Name)), 0, Spec.Pos);
  FFunction.Emit(opPop, 0, 0, Spec.Pos);
  FFunction.Emit(opJump, LoopStart, 0, Node.Pos);

  FFunction.PatchA(JExit, System.Length(FFunction.Code));
  for I := 0 to Ctx.BreakPatches.Count - 1 do
    FFunction.PatchA(PtrInt(Ctx.BreakPatches[I]), System.Length(FFunction.Code));
  for I := 0 to Ctx.ContinuePatches.Count - 1 do
    FFunction.PatchA(PtrInt(Ctx.ContinuePatches[I]), Ctx.ContinueTarget);
  FLoops.Extract(Ctx);
  Ctx.Free;
  EmitPushNil(Node);
end;

procedure TLfpCompiler.CompileCase(Node: TLfpNode);
var
  Temp, I, J, NextCase, EndJump, BodyStart: Integer;
  Clause, Labels: TLfpNode;
  EndPatches, MatchPatches: TList;
  IsElse: Boolean;
begin
  if Node.Count < 3 then raise Error(Node, '(case expression clauses...) expected');
  Temp := FFunction.AddLocal('$case_' + IntToStr(System.Length(FFunction.Code)), 'Variant');
  Compile(Node.Child(1));
  FFunction.Emit(opStoreLocal, Temp, 0, Node.Child(1).Pos);
  FFunction.Emit(opPop, 0, 0, Node.Child(1).Pos);

  EndPatches := TList.Create;
  MatchPatches := TList.Create;
  try
    for I := 2 to Node.Count - 1 do
    begin
      Clause := Node.Child(I);
      if (Clause.Kind <> nkList) or (Clause.Count < 2) then
        raise Error(Clause, 'case clause must be (label body...) or ((labels...) body...)');
      IsElse := Clause.Child(0).IsAtom('else');
      NextCase := -1;
      MatchPatches.Clear;

      if not IsElse then
      begin
        Labels := Clause.Child(0);
        if Labels.Kind = nkList then
        begin
          if Labels.Count = 0 then raise Error(Labels, 'empty case label list');
          for J := 0 to Labels.Count - 1 do
          begin
            FFunction.Emit(opLoadLocal, Temp, 0, Clause.Pos);
            Compile(Labels.Child(J));
            FFunction.Emit(opEq, 0, 0, Clause.Pos);
            MatchPatches.Add(Pointer(PtrInt(
              FFunction.Emit(opJumpTrue, -1, 0, Clause.Pos))));
          end;
        end
        else
        begin
          FFunction.Emit(opLoadLocal, Temp, 0, Clause.Pos);
          Compile(Labels);
          FFunction.Emit(opEq, 0, 0, Clause.Pos);
          MatchPatches.Add(Pointer(PtrInt(
            FFunction.Emit(opJumpTrue, -1, 0, Clause.Pos))));
        end;
        NextCase := FFunction.Emit(opJump, -1, 0, Clause.Pos);
        BodyStart := System.Length(FFunction.Code);
        for J := 0 to MatchPatches.Count - 1 do
          FFunction.PatchA(PtrInt(MatchPatches[J]), BodyStart);
      end;

      for J := 1 to Clause.Count - 1 do
      begin
        Compile(Clause.Child(J));
        if J < Clause.Count - 1 then FFunction.Emit(opPop, 0, 0, Clause.Pos);
      end;
      EndJump := FFunction.Emit(opJump, -1, 0, Clause.Pos);
      EndPatches.Add(Pointer(PtrInt(EndJump)));
      if NextCase >= 0 then
        FFunction.PatchA(NextCase, System.Length(FFunction.Code));
      if IsElse then Break;
    end;

    EmitPushNil(Node);
    for I := 0 to EndPatches.Count - 1 do
      FFunction.PatchA(PtrInt(EndPatches[I]), System.Length(FFunction.Code));
  finally
    MatchPatches.Free;
    EndPatches.Free;
  end;
end;

procedure TLfpCompiler.CompileWith(Node: TLfpNode);
var
  TempSlot, I: Integer;
begin
  if Node.Count < 3 then
    raise Error(Node, '(with record-expression body...) requires a body');
  TempSlot := FFunction.AddLocal('$with_' + IntToStr(System.Length(FFunction.Code)), 'Variant');
  Compile(Node.Child(1));
  FFunction.Emit(opStoreLocal, TempSlot, 0, Node.Child(1).Pos);
  FFunction.Emit(opPop, 0, 0, Node.Child(1).Pos);
  FWithSlots.Add(Pointer(PtrInt(TempSlot)));
  try
    for I := 2 to Node.Count - 1 do
    begin
      Compile(Node.Child(I));
      if I < Node.Count - 1 then
        FFunction.Emit(opPop, 0, 0, Node.Child(I).Pos);
    end;
  finally
    FWithSlots.Delete(FWithSlots.Count - 1);
  end;
end;

procedure TLfpCompiler.CompileVar(Node: TLfpNode; IsConst: Boolean);
var
  I, Slot, C: Integer;
  D: TLfpNode;
  Name, TName: string;
begin
  if Node.Count < 2 then
  begin
    EmitPushNil(Node);
    Exit;
  end;
  for I := 1 to Node.Count - 1 do
  begin
    D := Node.Child(I);
    if (D.Kind <> nkList) or (D.Count < 2) or (D.Count > 3) then
      raise Error(D, 'declaration must be (name Type [initial-value])');
    Name := NodeAtomText(D.Child(0), 'variable name');
    TName := TypeSpec(D.Child(1));
    if FTopLevel then
    begin
      if FEngine.HasGlobal(Name) then
        raise Error(D, 'duplicate global declaration: ' + Name);
      FEngine.DefineGlobal(Name, TName, not IsConst, FEngine.DefaultValueForType(TName));
      if D.Count = 3 then Compile(D.Child(2))
      else FFunction.Emit(opPushConst,
        FFunction.AddConstant(FEngine.DefaultValueForType(TName)), 0, D.Pos);
      C := AddStringConstant(UTF8Decode(Name));
      FFunction.Emit(opStoreGlobal, C, 1, D.Pos);
      FFunction.Emit(opPop, 0, 0, D.Pos);
    end
    else
    begin
      if FFunction.FindLocal(Name) >= 0 then
        raise Error(D, 'duplicate local declaration: ' + Name);
      Slot := FFunction.AddLocal(Name, TName, not IsConst);
      if D.Count = 3 then Compile(D.Child(2))
      else FFunction.Emit(opPushConst,
        FFunction.AddConstant(FEngine.DefaultValueForType(TName)), 0, D.Pos);
      FFunction.Emit(opStoreLocal, Slot, 1, D.Pos);
      FFunction.Emit(opPop, 0, 0, D.Pos);
    end;
  end;
  EmitPushNil(Node);
end;

procedure TLfpCompiler.CompileLoadTarget(Target: TLfpNode);
var
  Name: string;
  Slot, C: Integer;
begin
  if Target.Kind = nkAtom then
  begin
    Name := UTF8Encode(Target.Text);
    if IsLocal(Name, Slot) then FFunction.Emit(opLoadLocal, Slot, 0, Target.Pos)
    else if (CurrentWithSlot >= 0) and not FEngine.HasGlobal(Name) then
    begin
      FFunction.Emit(opLoadLocal, CurrentWithSlot, 0, Target.Pos);
      C := AddStringConstant(Target.Text);
      FFunction.Emit(opFieldGet, C, 0, Target.Pos);
    end
    else
    begin
      C := AddStringConstant(Target.Text);
      FFunction.Emit(opLoadGlobal, C, 0, Target.Pos);
    end;
    Exit;
  end;
  if Target.HeadIs('field') and (Target.Count = 3) then
  begin
    Compile(Target.Child(1));
    if Target.Child(2).Kind <> nkAtom then raise Error(Target.Child(2), 'field name must be an atom');
    C := AddStringConstant(Target.Child(2).Text);
    FFunction.Emit(opFieldGet, C, 0, Target.Pos);
    Exit;
  end;
  if Target.HeadIs('index') and (Target.Count = 3) then
  begin
    Compile(Target.Child(1));
    Compile(Target.Child(2));
    FFunction.Emit(opIndexGet, 0, 0, Target.Pos);
    Exit;
  end;
  if Target.HeadIs('deref') and (Target.Count = 2) then
  begin
    Compile(Target.Child(1));
    FFunction.Emit(opDeref, 0, 0, Target.Pos);
    Exit;
  end;
  raise Error(Target, 'invalid assignment target');
end;

procedure TLfpCompiler.CompileAssignTarget(Target: TLfpNode; const Pos: TLfpSourcePos);
var
  Name: string;
  Slot, C: Integer;
begin
  if Target.Kind = nkAtom then
  begin
    Name := UTF8Encode(Target.Text);
    if IsLocal(Name, Slot) then FFunction.Emit(opStoreLocal, Slot, 0, Pos)
    else
    begin
      C := AddStringConstant(Target.Text);
      FFunction.Emit(opStoreGlobal, C, 0, Pos);
    end;
    Exit;
  end;

  raise Error(Target, 'complex assignment target used in invalid context');
end;

procedure TLfpCompiler.CompileSet(Node: TLfpNode);
var
  Target: TLfpNode;
  C: Integer;
begin
  if Node.Count <> 3 then raise Error(Node, '(set! target value) expected');
  Target := Node.Child(1);
  if Target.Kind = nkAtom then
  begin
    if (FFunction.FindLocal(UTF8Encode(Target.Text)) < 0) and
       (not FEngine.HasGlobal(UTF8Encode(Target.Text))) and
       (CurrentWithSlot >= 0) then
    begin
      FFunction.Emit(opLoadLocal, CurrentWithSlot, 0, Target.Pos);
      Compile(Node.Child(2));
      C := AddStringConstant(Target.Text);
      FFunction.Emit(opFieldSet, C, 0, Node.Pos);
    end
    else
    begin
      Compile(Node.Child(2));
      CompileAssignTarget(Target, Node.Pos);
    end;
    Exit;
  end;
  if Target.HeadIs('field') and (Target.Count = 3) then
  begin
    Compile(Target.Child(1));
    Compile(Node.Child(2));
    if Target.Child(2).Kind <> nkAtom then raise Error(Target.Child(2), 'field name must be atom');
    C := AddStringConstant(Target.Child(2).Text);
    FFunction.Emit(opFieldSet, C, 0, Node.Pos);
    Exit;
  end;
  if Target.HeadIs('index') and (Target.Count = 3) then
  begin
    Compile(Target.Child(1));
    Compile(Target.Child(2));
    Compile(Node.Child(2));
    FFunction.Emit(opIndexSet, 0, 0, Node.Pos);
    Exit;
  end;
  if Target.HeadIs('deref') and (Target.Count = 2) then
  begin
    Compile(Target.Child(1));
    Compile(Node.Child(2));
    FFunction.Emit(opSetDeref, 0, 0, Node.Pos);
    Exit;
  end;
  raise Error(Target, 'invalid set! target');
end;

procedure TLfpCompiler.CompileIncDec(Node: TLfpNode; Delta: Integer);
var
  Name: string;
  C: Integer;

  procedure CompileAmountAndOperator;
  begin
    if Node.Count = 3 then Compile(Node.Child(2))
    else FFunction.Emit(opPushConst,
      FFunction.AddConstant(LfpInt(1)), 0, Node.Pos);
    if Delta > 0 then FFunction.Emit(opAdd, 0, 0, Node.Pos)
    else FFunction.Emit(opSub, 0, 0, Node.Pos);
  end;

begin
  if (Node.Count < 2) or (Node.Count > 3) then
    raise Error(Node, '(inc target [amount]) or (dec target [amount]) expected');
  if Node.Child(1).Kind = nkAtom then
  begin
    Name := UTF8Encode(Node.Child(1).Text);
    if (FFunction.FindLocal(Name) < 0) and (not FEngine.HasGlobal(Name)) and
       (CurrentWithSlot >= 0) then
    begin
      FFunction.Emit(opLoadLocal, CurrentWithSlot, 0, Node.Pos);
      FFunction.Emit(opDup, 0, 0, Node.Pos);
      C := AddStringConstant(Node.Child(1).Text);
      FFunction.Emit(opFieldGet, C, 0, Node.Pos);
      CompileAmountAndOperator;
      FFunction.Emit(opFieldSet, C, 0, Node.Pos);
      Exit;
    end;
    CompileLoadTarget(Node.Child(1));
    CompileAmountAndOperator;
    CompileAssignTarget(Node.Child(1), Node.Pos);
    Exit;
  end;

  if Node.Child(1).HeadIs('field') and (Node.Child(1).Count = 3) then
  begin
    if Node.Child(1).Child(2).Kind <> nkAtom then
      raise Error(Node.Child(1).Child(2), 'field name must be atom');
    Compile(Node.Child(1).Child(1));
    FFunction.Emit(opDup, 0, 0, Node.Pos);
    C := AddStringConstant(Node.Child(1).Child(2).Text);
    FFunction.Emit(opFieldGet, C, 0, Node.Pos);
    CompileAmountAndOperator;
    FFunction.Emit(opFieldSet, C, 0, Node.Pos);
    Exit;
  end;

  if Node.Child(1).HeadIs('index') and (Node.Child(1).Count = 3) then
  begin
    Compile(Node.Child(1).Child(1));
    Compile(Node.Child(1).Child(2));
    FFunction.Emit(opDup2, 0, 0, Node.Pos);
    FFunction.Emit(opIndexGet, 0, 0, Node.Pos);
    CompileAmountAndOperator;
    FFunction.Emit(opIndexSet, 0, 0, Node.Pos);
    Exit;
  end;

  if Node.Child(1).HeadIs('deref') and (Node.Child(1).Count = 2) then
  begin
    Compile(Node.Child(1).Child(1));
    FFunction.Emit(opDup, 0, 0, Node.Pos);
    FFunction.Emit(opDeref, 0, 0, Node.Pos);
    CompileAmountAndOperator;
    FFunction.Emit(opSetDeref, 0, 0, Node.Pos);
    Exit;
  end;

  raise Error(Node.Child(1), 'invalid inc/dec target');
end;

procedure TLfpCompiler.CompileBoolean(Node: TLfpNode; IsAnd: Boolean);
var
  I, J: Integer;
  Patches: TList;
begin
  if Node.Count = 1 then
  begin
    FFunction.Emit(opPushConst, FFunction.AddConstant(LfpBool(IsAnd)), 0, Node.Pos);
    Exit;
  end;
  Patches := TList.Create;
  try
    for I := 1 to Node.Count - 1 do
    begin
      Compile(Node.Child(I));
      if I < Node.Count - 1 then
      begin
        FFunction.Emit(opDup, 0, 0, Node.Pos);
        if IsAnd then J := FFunction.Emit(opJumpFalse, -1, 0, Node.Pos)
        else J := FFunction.Emit(opJumpTrue, -1, 0, Node.Pos);
        Patches.Add(Pointer(PtrInt(J)));
        FFunction.Emit(opPop, 0, 0, Node.Pos);
      end;
    end;
    for I := 0 to Patches.Count - 1 do
      FFunction.PatchA(PtrInt(Patches[I]), System.Length(FFunction.Code));
  finally
    Patches.Free;
  end;
end;

procedure TLfpCompiler.CompileOperator(Node: TLfpNode; Op: TLfpOpCode;
  UnaryAllowed: Boolean);
var
  I: Integer;
begin
  if Node.Count < 2 then raise Error(Node, 'operator requires operand(s)');
  if (Node.Count = 2) and UnaryAllowed then
  begin
    Compile(Node.Child(1));
    if Op = opSub then FFunction.Emit(opNeg, 0, 0, Node.Pos)
    else FFunction.Emit(Op, 0, 0, Node.Pos);
    Exit;
  end;
  if Node.Count < 3 then raise Error(Node, 'binary operator requires two operands');
  Compile(Node.Child(1));
  for I := 2 to Node.Count - 1 do
  begin
    Compile(Node.Child(I));
    FFunction.Emit(Op, 0, 0, Node.Pos);
  end;
end;

procedure TLfpCompiler.CompileCall(Node: TLfpNode);
var
  I: Integer;
begin
  if Node.Count = 0 then raise Error(Node, 'cannot call empty list');
  Compile(Node.Child(0));
  for I := 1 to Node.Count - 1 do Compile(Node.Child(I));
  FFunction.Emit(opCall, Node.Count - 1, 0, Node.Pos);
end;

procedure TLfpCompiler.CompileBreakContinue(Node: TLfpNode; IsBreak: Boolean);
var
  Ctx: TLfpLoopContext;
  J: Integer;
begin
  Ctx := CurrentLoop;
  if not Assigned(Ctx) then
    raise Error(Node, 'break/continue used outside loop');
  J := FFunction.Emit(opJump, -1, 0, Node.Pos);
  if IsBreak then Ctx.BreakPatches.Add(Pointer(PtrInt(J)))
  else Ctx.ContinuePatches.Add(Pointer(PtrInt(J)));
  EmitPushNil(Node);
end;

procedure TLfpCompiler.CompileLabel(Node: TLfpNode);
var
  Name: string;
begin
  if Node.Count <> 2 then raise Error(Node, '(label name) expected');
  Name := NodeAtomText(Node.Child(1), 'label name');
  if FLabels.IndexOf(Name) >= 0 then raise Error(Node, 'duplicate label: ' + Name);
  FLabels.AddObject(Name, TLfpIntBox.Create(System.Length(FFunction.Code)));
  EmitPushNil(Node);
end;

procedure TLfpCompiler.CompileGoto(Node: TLfpNode);
var
  Name: string;
  P: TLfpGotoPatch;
begin
  if Node.Count <> 2 then raise Error(Node, '(goto label) expected');
  Name := NodeAtomText(Node.Child(1), 'label name');
  P := TLfpGotoPatch.Create;
  P.Name := Name;
  P.InstructionIndex := FFunction.Emit(opJump, -1, 0, Node.Pos);
  P.Pos := Node.Pos;
  FGotos.Add(P);
  EmitPushNil(Node);
end;

procedure TLfpCompiler.ResolveGotos;
var
  I, L: Integer;
  P: TLfpGotoPatch;
begin
  for I := 0 to FGotos.Count - 1 do
  begin
    P := TLfpGotoPatch(FGotos[I]);
    L := FLabels.IndexOf(P.Name);
    if L < 0 then
      raise ELfpCompileError.Create(LfpPosString(P.Pos) + ': unknown label: ' + P.Name);
    FFunction.PatchA(P.InstructionIndex, TLfpIntBox(FLabels.Objects[L]).Value);
  end;
end;

procedure TLfpCompiler.CompileList(Node: TLfpNode);
var
  Head: string;
  I: Integer;
  C: Integer;
begin
  if Node.Count = 0 then
  begin
    EmitPushNil(Node);
    Exit;
  end;
  if Node.Child(0).Kind <> nkAtom then
  begin
    CompileCall(Node);
    Exit;
  end;
  Head := LowerCase(UTF8Encode(Node.Child(0).Text));

  if (Head = 'begin') or (Head = 'do') or (Head = 'progn') then CompileBegin(Node)
  else if Head = 'if' then CompileIf(Node)
  else if Head = 'when' then CompileWhenUnless(Node, False)
  else if Head = 'unless' then CompileWhenUnless(Node, True)
  else if Head = 'cond' then CompileCond(Node)
  else if Head = 'lambda' then CompileLambda(Node)
  else if Head = 'while' then CompileWhile(Node)
  else if Head = 'repeat' then CompileRepeat(Node)
  else if Head = 'for' then CompileFor(Node)
  else if Head = 'case' then CompileCase(Node)
  else if Head = 'with' then CompileWith(Node)
  else if Head = 'var' then CompileVar(Node, False)
  else if Head = 'const' then CompileVar(Node, True)
  else if (Head = 'set!') or (Head = ':=') then CompileSet(Node)
  else if Head = 'inc' then CompileIncDec(Node, 1)
  else if Head = 'dec' then CompileIncDec(Node, -1)
  else if Head = 'and' then CompileBoolean(Node, True)
  else if Head = 'or' then CompileBoolean(Node, False)
  else if Head = 'not' then
  begin
    if Node.Count <> 2 then raise Error(Node, 'not expects one operand');
    Compile(Node.Child(1));
    FFunction.Emit(opNot, 0, 0, Node.Pos);
  end
  else if Head = '+' then CompileOperator(Node, opAdd)
  else if Head = '-' then CompileOperator(Node, opSub, True)
  else if Head = '*' then CompileOperator(Node, opMul)
  else if Head = '/' then CompileOperator(Node, opDivReal)
  else if Head = 'div' then CompileOperator(Node, opDivInt)
  else if Head = 'mod' then CompileOperator(Node, opMod)
  else if Head = '=' then CompileOperator(Node, opEq)
  else if (Head = '<>') or (Head = '!=') then CompileOperator(Node, opNe)
  else if Head = '<' then CompileOperator(Node, opLt)
  else if Head = '<=' then CompileOperator(Node, opLe)
  else if Head = '>' then CompileOperator(Node, opGt)
  else if Head = '>=' then CompileOperator(Node, opGe)
  else if Head = 'array' then
  begin
    for I := 1 to Node.Count - 1 do Compile(Node.Child(I));
    FFunction.Emit(opMakeArray, Node.Count - 1, 0, Node.Pos);
  end
  else if Head = 'set' then
  begin
    for I := 1 to Node.Count - 1 do Compile(Node.Child(I));
    FFunction.Emit(opMakeSet, Node.Count - 1, 0, Node.Pos);
  end
  else if Head = 'index' then
  begin
    if Node.Count <> 3 then raise Error(Node, '(index array index) expected');
    Compile(Node.Child(1)); Compile(Node.Child(2));
    FFunction.Emit(opIndexGet, 0, 0, Node.Pos);
  end
  else if Head = 'field' then
  begin
    if Node.Count <> 3 then raise Error(Node, '(field record name) expected');
    if Node.Child(2).Kind <> nkAtom then raise Error(Node.Child(2), 'field name must be atom');
    Compile(Node.Child(1));
    C := AddStringConstant(Node.Child(2).Text);
    FFunction.Emit(opFieldGet, C, 0, Node.Pos);
  end
  else if Head = 'new' then
  begin
    if Node.Count = 1 then EmitPushNil(Node)
    else if Node.Count = 2 then Compile(Node.Child(1))
    else raise Error(Node, '(new [initial-value]) expected');
    FFunction.Emit(opNewPointer, 0, 0, Node.Pos);
  end
  else if Head = 'deref' then
  begin
    if Node.Count <> 2 then raise Error(Node, '(deref pointer) expected');
    Compile(Node.Child(1));
    FFunction.Emit(opDeref, 0, 0, Node.Pos);
  end
  else if Head = 'dispose' then
  begin
    if Node.Count <> 2 then raise Error(Node, '(dispose pointer) expected');
    Compile(Node.Child(1));
    FFunction.Emit(opDisposePointer, 0, 0, Node.Pos);
  end
  else if (Head = 'return') or (Head = 'exit') then
  begin
    if Node.Count = 1 then EmitPushNil(Node)
    else if Node.Count = 2 then Compile(Node.Child(1))
    else raise Error(Node, '(return [value]) expected');
    FFunction.Emit(opReturn, 0, 0, Node.Pos);
  end
  else if Head = 'break' then CompileBreakContinue(Node, True)
  else if Head = 'continue' then CompileBreakContinue(Node, False)
  else if Head = 'label' then CompileLabel(Node)
  else if Head = 'goto' then CompileGoto(Node)
  else if Head = 'quote' then
  begin
    if Node.Count <> 2 then raise Error(Node, 'quote expects one form');
    FFunction.Emit(opPushConst,
      FFunction.AddConstant(QuoteNodeValue(FEngine, Node.Child(1))), 0, Node.Pos);
  end
  else if (Head = 'function') or (Head = 'procedure') or (Head = 'type') or
          (Head = 'uses') or (Head = 'interface') or (Head = 'implementation') or
          (Head = 'export') then
    EmitPushNil(Node)
  else
    CompileCall(Node);
end;

procedure TLfpCompiler.Compile(Node: TLfpNode);
begin
  if Node.Kind = nkList then CompileList(Node) else CompileAtom(Node);
end;

procedure TLfpCompiler.Finish;
begin
  ResolveGotos;
end;

function NativeWrite(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  I: Integer;
begin
  for I := 0 to High(Args) do Write(UTF8Encode(LfpValueAsString(Args[I])));
  Result := LfpNil;
end;

function NativeWriteln(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  I: Integer;
begin
  for I := 0 to High(Args) do Write(UTF8Encode(LfpValueAsString(Args[I])));
  System.Writeln;
  Result := LfpNil;
end;

function NativeReadln(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  S: string;
begin
  if Length(Args) > 0 then Write(UTF8Encode(LfpValueAsString(Args[0])));
  System.ReadLn(S);
  Result := LfpString(UTF8Decode(S));
end;

function NativeLength(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  case Args[0].Kind of
    vkString, vkChar: Result := LfpInt(System.Length(Args[0].StrValue));
    vkObject:
      if Args[0].ObjValue is TLfpArrayObject then
        Result := LfpInt(TLfpArrayObject(Args[0].ObjValue).Length)
      else if Args[0].ObjValue is TLfpSetObject then
        Result := LfpInt(TLfpSetObject(Args[0].ObjValue).Count)
      else
        raise ELfpRuntimeError.Create('length expects string, array, or set');
  else
    raise ELfpRuntimeError.Create('length expects string, array, or set');
  end;
end;

function NativeLow(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  if (Args[0].Kind = vkObject) and (Args[0].ObjValue is TLfpArrayObject) then
    Result := LfpInt(TLfpArrayObject(Args[0].ObjValue).LowerBound)
  else if Args[0].Kind in [vkString, vkChar] then
    Result := LfpInt(1)
  else
    raise ELfpRuntimeError.Create('low expects an array or string');
end;

function NativeHigh(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  if (Args[0].Kind = vkObject) and (Args[0].ObjValue is TLfpArrayObject) then
    Result := LfpInt(TLfpArrayObject(Args[0].ObjValue).UpperBound)
  else if Args[0].Kind in [vkString, vkChar] then
    Result := LfpInt(System.Length(Args[0].StrValue))
  else
    raise ELfpRuntimeError.Create('high expects an array or string');
end;

function NativeStr(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  Result := LfpString(LfpValueAsString(Args[0]));
end;

function NativeInt(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  X: Int64;
begin
  case Args[0].Kind of
    vkInteger: Result := Args[0];
    vkReal: Result := LfpInt(LfpToInt(Args[0]));
    vkBoolean: if Args[0].BoolValue then Result := LfpInt(1) else Result := LfpInt(0);
    vkChar: Result := LfpInt(Ord(Args[0].StrValue[1]));
    vkString:
      if TryStrToInt64(UTF8Encode(Args[0].StrValue), X) then Result := LfpInt(X)
      else raise ELfpRuntimeError.Create('cannot convert string to Integer');
  else
    raise ELfpRuntimeError.Create('cannot convert ' + LfpValueTypeName(Args[0]) + ' to Integer');
  end;
end;

function NativeReal(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  X: Double;
  FS: TFormatSettings;
begin
  if LfpIsNumeric(Args[0]) then Exit(LfpReal(LfpToReal(Args[0])));
  if Args[0].Kind = vkString then
  begin
    FS := DefaultFormatSettings; FS.DecimalSeparator := '.';
    if TryStrToFloat(UTF8Encode(Args[0].StrValue), X, FS) then Exit(LfpReal(X));
  end;
  raise ELfpRuntimeError.Create('cannot convert ' + LfpValueTypeName(Args[0]) + ' to Real');
end;

function NativeBool(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  Result := LfpBool(LfpTruthy(Args[0]));
end;

function NativeOrd(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  if (Args[0].Kind = vkObject) and (Args[0].ObjValue is TLfpEnumValueObject) then
    Result := LfpInt(TLfpEnumValueObject(Args[0].ObjValue).Ordinal)
  else Result := LfpInt(LfpToInt(Args[0]));
end;

function NativeChr(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  CodePoint: Int64;
begin
  CodePoint := LfpToInt(Args[0]);
  if (CodePoint < 0) or (CodePoint > Ord(High(WideChar))) then
    raise ELfpRuntimeError.Create('chr argument is outside char range');
  Result := LfpChar(WideChar(CodePoint));
end;

function NativeAbs(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  if Args[0].Kind = vkInteger then
  begin
    if Args[0].IntValue < 0 then
      Result := LfpInt(CheckedIntNeg(Args[0].IntValue))
    else
      Result := Args[0];
  end
  else Result := LfpReal(System.Abs(LfpToReal(Args[0])));
end;

function NativeSqr(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  if Args[0].Kind = vkInteger then
    Result := LfpInt(CheckedIntMul(Args[0].IntValue, Args[0].IntValue))
  else Result := LfpReal(Sqr(LfpToReal(Args[0])));
end;

function NativeOdd(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  Result := LfpBool((LfpToInt(Args[0]) and 1) <> 0);
end;

function NativeSqrt(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  Result := LfpReal(System.Sqrt(LfpToReal(Args[0])));
end;

function NativeSin(UserData: Pointer; Engine: TLfpEngine; const Args: TLfpValueArray): TLfpValue;
begin Result := LfpReal(System.Sin(LfpToReal(Args[0]))); end;
function NativeCos(UserData: Pointer; Engine: TLfpEngine; const Args: TLfpValueArray): TLfpValue;
begin Result := LfpReal(System.Cos(LfpToReal(Args[0]))); end;
function NativeTan(UserData: Pointer; Engine: TLfpEngine; const Args: TLfpValueArray): TLfpValue;
begin Result := LfpReal(Math.Tan(LfpToReal(Args[0]))); end;
function NativeArcTan(UserData: Pointer; Engine: TLfpEngine; const Args: TLfpValueArray): TLfpValue;
begin Result := LfpReal(System.ArcTan(LfpToReal(Args[0]))); end;
function NativeLn(UserData: Pointer; Engine: TLfpEngine; const Args: TLfpValueArray): TLfpValue;
begin Result := LfpReal(System.Ln(LfpToReal(Args[0]))); end;
function NativeExp(UserData: Pointer; Engine: TLfpEngine; const Args: TLfpValueArray): TLfpValue;
begin Result := LfpReal(System.Exp(LfpToReal(Args[0]))); end;
function NativeRound(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  if Args[0].Kind = vkInteger then Exit(Args[0]);
  LfpToInt(Args[0]);
  Result := LfpInt(System.Round(Args[0].RealValue));
end;

function NativeTrunc(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  if Args[0].Kind = vkInteger then Exit(Args[0]);
  Result := LfpInt(LfpToInt(Args[0]));
end;

function NativeRandomize(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  System.Randomize;
  Result := LfpNil;
end;

function NativeRandom(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  if Length(Args) = 0 then Result := LfpReal(System.Random)
  else Result := LfpInt(System.Random(LongInt(LfpToInt(Args[0]))));
end;

function NativeMin(UserData: Pointer; Engine: TLfpEngine; const Args: TLfpValueArray): TLfpValue;
var I: Integer; X: Double; IntValue: Int64; AllInt: Boolean;
begin
  AllInt := True;
  for I := 0 to High(Args) do
    AllInt := AllInt and (Args[I].Kind = vkInteger);
  if AllInt then
  begin
    IntValue := Args[0].IntValue;
    for I := 1 to High(Args) do
      if Args[I].IntValue < IntValue then IntValue := Args[I].IntValue;
    Result := LfpInt(IntValue);
  end
  else
  begin
    X := LfpToReal(Args[0]);
    for I := 1 to High(Args) do X := Math.Min(X, LfpToReal(Args[I]));
    Result := LfpReal(X);
  end;
end;

function NativeMax(UserData: Pointer; Engine: TLfpEngine; const Args: TLfpValueArray): TLfpValue;
var I: Integer; X: Double; IntValue: Int64; AllInt: Boolean;
begin
  AllInt := True;
  for I := 0 to High(Args) do
    AllInt := AllInt and (Args[I].Kind = vkInteger);
  if AllInt then
  begin
    IntValue := Args[0].IntValue;
    for I := 1 to High(Args) do
      if Args[I].IntValue > IntValue then IntValue := Args[I].IntValue;
    Result := LfpInt(IntValue);
  end
  else
  begin
    X := LfpToReal(Args[0]);
    for I := 1 to High(Args) do X := Math.Max(X, LfpToReal(Args[I]));
    Result := LfpReal(X);
  end;
end;

function EnumStep(Engine: TLfpEngine; const V: TLfpValue; Delta: Integer): TLfpValue;
var
  EV: TLfpEnumValueObject;
  D: TLfpTypeDef;
  ED: TLfpEnumTypeDef;
  N: Integer;
begin
  EV := TLfpEnumValueObject(V.ObjValue);
  D := Engine.FindTypeDef(EV.EnumName);
  if not Assigned(D) or (D.Kind <> tdEnum) then
    raise ELfpRuntimeError.Create('enum type metadata not found: ' + EV.EnumName);
  ED := TLfpEnumTypeDef(D);
  N := EV.Ordinal + Delta;
  if (N < 0) or (N >= ED.Members.Count) then
    raise ELfpRuntimeError.CreateFmt('%s successor/predecessor out of range', [EV.EnumName]);
  Result := Engine.GetGlobal(ED.Members[N]);
end;

function NativePred(UserData: Pointer; Engine: TLfpEngine; const Args: TLfpValueArray): TLfpValue;
begin
  if Args[0].Kind = vkChar then
  begin
    if Ord(Args[0].StrValue[1]) = 0 then
      raise ELfpRuntimeError.Create('char predecessor out of range');
    Result := LfpChar(WideChar(Ord(Args[0].StrValue[1]) - 1));
  end
  else if (Args[0].Kind = vkObject) and (Args[0].ObjValue is TLfpEnumValueObject) then
    Result := EnumStep(Engine, Args[0], -1)
  else
    Result := LfpInt(CheckedIntSub(LfpToInt(Args[0]), 1));
end;

function NativeSucc(UserData: Pointer; Engine: TLfpEngine; const Args: TLfpValueArray): TLfpValue;
begin
  if Args[0].Kind = vkChar then
  begin
    if Ord(Args[0].StrValue[1]) = Ord(High(WideChar)) then
      raise ELfpRuntimeError.Create('char successor out of range');
    Result := LfpChar(WideChar(Ord(Args[0].StrValue[1]) + 1));
  end
  else if (Args[0].Kind = vkObject) and (Args[0].ObjValue is TLfpEnumValueObject) then
    Result := EnumStep(Engine, Args[0], 1)
  else
    Result := LfpInt(CheckedIntAdd(LfpToInt(Args[0]), 1));
end;

function NativeInclude(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  if (Args[0].Kind <> vkObject) or not (Args[0].ObjValue is TLfpSetObject) then
    raise ELfpRuntimeError.Create('include expects a set as first argument');
  Engine.RequireType(Args[1], TLfpSetObject(Args[0].ObjValue).ElementType,
    'include set element');
  TLfpSetObject(Args[0].ObjValue).IncludeValue(Args[1]);
  Result := Args[0];
end;

function NativeExclude(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  if (Args[0].Kind <> vkObject) or not (Args[0].ObjValue is TLfpSetObject) then
    raise ELfpRuntimeError.Create('exclude expects a set as first argument');
  Engine.RequireType(Args[1], TLfpSetObject(Args[0].ObjValue).ElementType,
    'exclude set element');
  TLfpSetObject(Args[0].ObjValue).ExcludeValue(Args[1]);
  Result := Args[0];
end;

function NativeIn(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  if (Args[1].Kind <> vkObject) or not (Args[1].ObjValue is TLfpSetObject) then
    raise ELfpRuntimeError.Create('in expects a set as second argument');
  Engine.RequireType(Args[0], TLfpSetObject(Args[1].ObjValue).ElementType,
    'set membership');
  Result := LfpBool(TLfpSetObject(Args[1].ObjValue).Contains(Args[0]));
end;

function NativeAppend(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  if (Args[0].Kind <> vkObject) or not (Args[0].ObjValue is TLfpArrayObject) then
    raise ELfpRuntimeError.Create('append expects an array');
  if not SameText(TLfpArrayObject(Args[0].ObjValue).ElementType, 'Variant') then
    raise ELfpRuntimeError.Create('cannot append to a fixed typed Pascal array');
  Engine.RequireType(Args[1], TLfpArrayObject(Args[0].ObjValue).ElementType,
    'append element');
  TLfpArrayObject(Args[0].ObjValue).Append(Args[1]);
  Result := Args[0];
end;


function SequenceArray(const V: TLfpValue; const Context: string): TLfpArrayObject;
begin
  if (V.Kind <> vkObject) or not (V.ObjValue is TLfpArrayObject) then
    raise ELfpRuntimeError.Create(Context + ' expects an array/list');
  Result := TLfpArrayObject(V.ObjValue);
end;

function NativeList(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  A: TLfpArrayObject;
  I: Integer;
begin
  A := TLfpArrayObject(Engine.OwnObject(TLfpArrayObject.Create(0)));
  for I := 0 to High(Args) do A.Append(Args[I]);
  Result := LfpObject(A);
end;

function NativeFirst(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var A: TLfpArrayObject;
begin
  A := SequenceArray(Args[0], 'first');
  if A.Length = 0 then Exit(LfpNil);
  Result := A.GetItem(A.LowerBound);
end;

function NativeRest(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  A, R: TLfpArrayObject;
  I: SizeInt;
begin
  A := SequenceArray(Args[0], 'rest');
  R := TLfpArrayObject(Engine.OwnObject(TLfpArrayObject.Create(0)));
  for I := 1 to A.Length - 1 do
    R.Append(A.GetItem(A.LowerBound + I));
  Result := LfpObject(R);
end;

function NativeLast(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var A: TLfpArrayObject;
begin
  A := SequenceArray(Args[0], 'last');
  if A.Length = 0 then Exit(LfpNil);
  Result := A.GetItem(A.UpperBound);
end;

function NativeNth(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  A: TLfpArrayObject;
  N: Int64;
begin
  A := SequenceArray(Args[1], 'nth');
  N := LfpToInt(Args[0]);
  if (N < 0) or (N >= A.Length) then
    raise ELfpRuntimeError.CreateFmt('nth index %d out of range 0..%d',
      [N, A.Length - 1]);
  Result := A.GetItem(A.LowerBound + N);
end;

function NativeReverse(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  A, R: TLfpArrayObject;
  I: SizeInt;
begin
  A := SequenceArray(Args[0], 'reverse');
  R := TLfpArrayObject(Engine.OwnObject(TLfpArrayObject.Create(0)));
  for I := A.Length - 1 downto 0 do
    R.Append(A.GetItem(A.LowerBound + I));
  Result := LfpObject(R);
end;

function NativeApply(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  A: TLfpArrayObject;
  CallArgs: TLfpValueArray;
  I: SizeInt;
begin
  A := SequenceArray(Args[1], 'apply');
  SetLength(CallArgs, A.Length);
  for I := 0 to A.Length - 1 do
    CallArgs[I] := A.GetItem(A.LowerBound + I);
  Result := Engine.ExecuteCallable(Args[0], CallArgs);
end;

function NativeMap(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  A, R: TLfpArrayObject;
  CallArgs: TLfpValueArray;
  I: SizeInt;
begin
  A := SequenceArray(Args[1], 'map');
  R := TLfpArrayObject(Engine.OwnObject(TLfpArrayObject.Create(0)));
  SetLength(CallArgs, 1);
  for I := 0 to A.Length - 1 do
  begin
    CallArgs[0] := A.GetItem(A.LowerBound + I);
    R.Append(Engine.ExecuteCallable(Args[0], CallArgs));
  end;
  Result := LfpObject(R);
end;

function NativeFilter(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  A, R: TLfpArrayObject;
  CallArgs: TLfpValueArray;
  V: TLfpValue;
  I: SizeInt;
begin
  A := SequenceArray(Args[1], 'filter');
  R := TLfpArrayObject(Engine.OwnObject(TLfpArrayObject.Create(0)));
  SetLength(CallArgs, 1);
  for I := 0 to A.Length - 1 do
  begin
    V := A.GetItem(A.LowerBound + I);
    CallArgs[0] := V;
    if LfpTruthy(Engine.ExecuteCallable(Args[0], CallArgs)) then R.Append(V);
  end;
  Result := LfpObject(R);
end;

function NativeFoldl(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  A: TLfpArrayObject;
  CallArgs: TLfpValueArray;
  Acc: TLfpValue;
  I: SizeInt;
begin
  A := SequenceArray(Args[2], 'foldl');
  Acc := Args[1];
  SetLength(CallArgs, 2);
  for I := 0 to A.Length - 1 do
  begin
    CallArgs[0] := Acc;
    CallArgs[1] := A.GetItem(A.LowerBound + I);
    Acc := Engine.ExecuteCallable(Args[0], CallArgs);
  end;
  Result := Acc;
end;

function NativeForEach(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var
  A: TLfpArrayObject;
  CallArgs: TLfpValueArray;
  I: SizeInt;
begin
  A := SequenceArray(Args[1], 'foreach');
  SetLength(CallArgs, 1);
  for I := 0 to A.Length - 1 do
  begin
    CallArgs[0] := A.GetItem(A.LowerBound + I);
    Engine.ExecuteCallable(Args[0], CallArgs);
  end;
  Result := LfpNil;
end;

function NativeConcat(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var I: Integer; S: UnicodeString;
begin
  S := '';
  for I := 0 to High(Args) do S := S + LfpValueAsString(Args[I]);
  Result := LfpString(S);
end;

function NativeUpper(UserData: Pointer; Engine: TLfpEngine; const Args: TLfpValueArray): TLfpValue;
begin Result := LfpString(UTF8Decode(UpperCase(UTF8Encode(LfpValueAsString(Args[0]))))); end;
function NativeLower(UserData: Pointer; Engine: TLfpEngine; const Args: TLfpValueArray): TLfpValue;
begin Result := LfpString(UTF8Decode(LowerCase(UTF8Encode(LfpValueAsString(Args[0]))))); end;

function NativeCopy(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var S: UnicodeString; Start, Count: Int64;
begin
  S := LfpValueAsString(Args[0]); Start := LfpToInt(Args[1]); Count := LfpToInt(Args[2]);
  Result := LfpString(System.Copy(S, Start, Count));
end;

function NativePos(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  Result := LfpInt(System.Pos(LfpValueAsString(Args[0]), LfpValueAsString(Args[1])));
end;

function NativeAssert(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var Msg: string;
begin
  if not LfpTruthy(Args[0]) then
  begin
    if Length(Args) > 1 then Msg := UTF8Encode(LfpValueAsString(Args[1])) else Msg := 'assertion failed';
    raise ELfpRuntimeError.Create(Msg);
  end;
  Result := LfpNil;
end;

function NativeHalt(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
var Code: Integer;
begin
  if Length(Args) = 0 then Code := 0 else Code := LfpToInt(Args[0]);
  Result := LfpNil;
  raise ELfpHalt.CreateCode(Code);
end;

function NativeTypeOf(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  Result := LfpString(UTF8Decode(LfpValueTypeName(Args[0])));
end;

function RtlStringArg(const Args: TLfpValueArray; Index: Integer): string;
begin
  if Index > High(Args) then raise ELfpRuntimeError.Create('__rtl: missing argument');
  Result := UTF8Encode(LfpValueAsString(Args[Index]));
end;

function RtlIntArg(const Args: TLfpValueArray; Index: Integer): Int64;
begin
  if Index > High(Args) then raise ELfpRuntimeError.Create('__rtl: missing argument');
  Result := LfpToInt(Args[Index]);
end;

function RtlOrdinalArg(const Args: TLfpValueArray; Index: Integer): Int64;
begin
  if Index > High(Args) then raise ELfpRuntimeError.Create('__rtl: missing argument');
  if (Args[Index].Kind = vkObject) and (Args[Index].ObjValue is TLfpEnumValueObject) then
    Exit(TLfpEnumValueObject(Args[Index].ObjValue).Ordinal);
  Result := LfpToInt(Args[Index]);
end;

function RtlRealArg(const Args: TLfpValueArray; Index: Integer): Double;
begin
  if Index > High(Args) then raise ELfpRuntimeError.Create('__rtl: missing argument');
  Result := LfpToReal(Args[Index]);
end;

function RtlBoolArg(const Args: TLfpValueArray; Index: Integer): Boolean;
begin
  if Index > High(Args) then raise ELfpRuntimeError.Create('__rtl: missing argument');
  Result := LfpTruthy(Args[Index]);
end;

function RtlArrayFromStrings(Engine: TLfpEngine; Values: TStrings): TLfpValue;
var
  A: TLfpArrayObject;
  I: Integer;
begin
  A := TLfpArrayObject(Engine.OwnObject(TLfpArrayObject.Create(0)));
  for I := 0 to Values.Count - 1 do A.Append(LfpString(UTF8Decode(Values[I])));
  Result := LfpObject(A);
end;

function RtlCompare(const A, B: string): Integer;
begin
  if A < B then Result := -1
  else if A > B then Result := 1
  else Result := 0;
end;

function RtlReverse(const S: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := Length(S) downto 1 do Result := Result + S[I];
end;

function RtlLastPos(const Needle, Haystack: UnicodeString; StartAt: Integer): Integer;
var
  I, N: Integer;
begin
  Result := 0;
  N := Length(Needle);
  if N = 0 then Exit;
  if (StartAt <= 0) or (StartAt > Length(Haystack)) then StartAt := Length(Haystack);
  if StartAt > Length(Haystack) - N + 1 then StartAt := Length(Haystack) - N + 1;
  for I := StartAt downto 1 do
    if Copy(Haystack, I, N) = Needle then Exit(I);
end;

function RtlStringOfChar(C: WideChar; Count: Integer): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  if Count < 0 then Count := 0;
  for I := 1 to Count do Result := Result + C;
end;

function RtlArrayStat(const V: TLfpValue; const Op: string): TLfpValue;
var
  A: TLfpArrayObject;
  I: Int64;
  X, Sum, SumSq, MinV, MaxV, MeanV, TotalVar: Double;
  N: Int64;
begin
  if (V.Kind <> vkObject) or not (V.ObjValue is TLfpArrayObject) then
    raise ELfpRuntimeError.Create('__rtl: expected array');
  A := TLfpArrayObject(V.ObjValue);
  N := A.Length;
  if N = 0 then
  begin
    if (Op = 'sum') or (Op = 'sumsq') then Exit(LfpReal(0));
    raise ELfpRuntimeError.Create('__rtl: empty array');
  end;
  Sum := 0;
  SumSq := 0;
  MinV := LfpToReal(A.GetItem(A.LowerBound));
  MaxV := MinV;
  for I := A.LowerBound to A.UpperBound do
  begin
    X := LfpToReal(A.GetItem(I));
    Sum := Sum + X;
    SumSq := SumSq + X * X;
    if X < MinV then MinV := X;
    if X > MaxV then MaxV := X;
  end;
  if Op = 'sum' then Exit(LfpReal(Sum));
  if Op = 'sumsq' then Exit(LfpReal(SumSq));
  if Op = 'mean' then Exit(LfpReal(Sum / N));
  if Op = 'min' then Exit(LfpReal(MinV));
  if Op = 'max' then Exit(LfpReal(MaxV));
  MeanV := Sum / N;
  TotalVar := 0;
  for I := A.LowerBound to A.UpperBound do
  begin
    X := LfpToReal(A.GetItem(I)) - MeanV;
    TotalVar := TotalVar + X * X;
  end;
  if Op = 'totalvariance' then Exit(LfpReal(TotalVar));
  if Op = 'popnvariance' then Exit(LfpReal(TotalVar / N));
  if Op = 'popnstddev' then Exit(LfpReal(Sqrt(Max(0.0, TotalVar / N))));
  if Op = 'variance' then
  begin
    if N < 2 then Exit(LfpReal(0));
    Exit(LfpReal(TotalVar / (N - 1)));
  end;
  if Op = 'stddev' then
  begin
    if N < 2 then Exit(LfpReal(0));
    Exit(LfpReal(Sqrt(Max(0.0, TotalVar / (N - 1)))));
  end;
  Result := LfpNil;
end;

function RtlValueArray(const V: TLfpValue): TLfpArrayObject;
begin
  if (V.Kind <> vkObject) or not (V.ObjValue is TLfpArrayObject) then
    raise ELfpRuntimeError.Create('__rtl: expected array');
  Result := TLfpArrayObject(V.ObjValue);
end;

function RtlCharSet(const S: string): TSysCharSet;
var
  I: Integer;
begin
  Result := [];
  for I := 1 to Length(S) do Include(Result, S[I]);
end;

function RtlJoinArray(const V: TLfpValue; const Delimiter: UnicodeString): UnicodeString;
var
  A: TLfpArrayObject;
  I: Int64;
begin
  A := RtlValueArray(V);
  Result := '';
  for I := A.LowerBound to A.UpperBound do
  begin
    if I > A.LowerBound then Result := Result + Delimiter;
    Result := Result + LfpValueAsString(A.GetItem(I));
  end;
end;

function RtlArrayIndex(const V: TLfpValue; const Needle: UnicodeString;
  CaseSensitive: Boolean): Int64;
var
  A: TLfpArrayObject;
  I: Int64;
  S: UnicodeString;
begin
  A := RtlValueArray(V);
  for I := A.LowerBound to A.UpperBound do
  begin
    S := LfpValueAsString(A.GetItem(I));
    if CaseSensitive then
    begin
      if S = Needle then Exit(I - A.LowerBound);
    end
    else if CompareText(UTF8Encode(S), UTF8Encode(Needle)) = 0 then
      Exit(I - A.LowerBound);
  end;
  Result := -1;
end;

function RtlBaseToInt(const S: string; Base: Integer): Int64;
var
  I, D, Sign: Integer;
  C: Char;
begin
  if (Base < 2) or (Base > 36) then
    raise ELfpRuntimeError.Create('__rtl: base must be 2..36');
  I := 1;
  Sign := 1;
  if (Length(S) > 0) and (S[1] = '-') then begin Sign := -1; Inc(I); end;
  Result := 0;
  while I <= Length(S) do
  begin
    C := UpCase(S[I]);
    if (C >= '0') and (C <= '9') then D := Ord(C) - Ord('0')
    else if (C >= 'A') and (C <= 'Z') then D := Ord(C) - Ord('A') + 10
    else raise ELfpRuntimeError.Create('invalid digit in ' + S);
    if D >= Base then raise ELfpRuntimeError.Create('digit outside base in ' + S);
    Result := Result * Base + D;
    Inc(I);
  end;
  Result := Result * Sign;
end;

function RtlIntToBase(Value: Int64; Base, MinDigits: Integer): string;
const
  Digits = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
var
  Negative: Boolean;
  U: QWord;
begin
  if (Base < 2) or (Base > 36) then
    raise ELfpRuntimeError.Create('__rtl: base must be 2..36');
  Negative := Value < 0;
  if Negative then U := QWord(-(Value + 1)) + 1 else U := QWord(Value);
  Result := '';
  repeat
    Result := Digits[(U mod QWord(Base)) + 1] + Result;
    U := U div QWord(Base);
  until U = 0;
  while Length(Result) < MinDigits do Result := '0' + Result;
  if Negative then Result := '-' + Result;
end;

function RtlWildcardMatch(const Text, Pattern: string; IgnoreCase: Boolean): Boolean;
var
  T, P, Star, Mark: Integer;
  A, B: Char;
begin
  T := 1;
  P := 1;
  Star := 0;
  Mark := 0;
  while T <= Length(Text) do
  begin
    if P <= Length(Pattern) then
    begin
      A := Text[T];
      B := Pattern[P];
      if IgnoreCase then begin A := UpCase(A); B := UpCase(B); end;
      if (B = '?') or (A = B) then begin Inc(T); Inc(P); Continue; end;
      if B = '*' then begin Star := P; Inc(P); Mark := T; Continue; end;
    end;
    if Star <> 0 then begin P := Star + 1; Inc(Mark); T := Mark; Continue; end;
    Exit(False);
  end;
  while (P <= Length(Pattern)) and (Pattern[P] = '*') do Inc(P);
  Result := P > Length(Pattern);
end;

function RtlSoundexPacked(const S: string): Int64;
var
  X: string;
  I: Integer;
begin
  X := StrUtils.Soundex(S);
  Result := 0;
  for I := 1 to Length(X) do Result := Result * 256 + Ord(X[I]);
end;

function RtlSoundexUnpack(Value: Int64; Count: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Count do
  begin
    Result := Chr(Value and $FF) + Result;
    Value := Value shr 8;
  end;
end;


function TryNativeRtlTopoff(Engine: TLfpEngine; const Op: string;
  const Args: TLfpValueArray; out V: TLfpValue): Boolean;
var
  P: Pointer;
  Addr: Sockets.in_addr;
  H: Dynlibs.TLibHandle;
  S, T: string;
begin
  Result := True;

  if Op = 'dyn_loadlibrary' then
    V := LfpInt(Int64(PtrUInt(Dynlibs.LoadLibrary(RtlStringArg(Args, 1)))))
  else if Op = 'dyn_safeloadlibrary' then
    V := LfpInt(Int64(PtrUInt(Dynlibs.SafeLoadLibrary(RtlStringArg(Args, 1)))))
  else if Op = 'dyn_unloadlibrary' then
  begin
    H := Dynlibs.TLibHandle(PtrUInt(RtlIntArg(Args, 1)));
    V := LfpBool(Dynlibs.UnloadLibrary(H));
  end
  else if Op = 'dyn_getprocedureaddress' then
  begin
    H := Dynlibs.TLibHandle(PtrUInt(RtlIntArg(Args, 1)));
    P := Dynlibs.GetProcedureAddress(H, RtlStringArg(Args, 2));
    if P = nil then V := LfpNil
    else V := LfpObject(Engine.OwnObject(TLfpPointerObject.Create(LfpInt(Int64(PtrUInt(P))))));
  end
  else if Op = 'dyn_getloaderrorstr' then
    V := LfpString(UTF8Decode(Dynlibs.GetLoadErrorStr))

  else if Op = 'crt_textmode' then
  begin
    Crt.TextMode(Byte(RtlIntArg(Args, 1)));
    V := LfpNil;
  end
  else if Op = 'crt_cursorbig' then begin Crt.CursorBig; V := LfpNil; end
  else if Op = 'crt_cursoroff' then begin Crt.CursorOff; V := LfpNil; end
  else if Op = 'crt_cursoron' then begin Crt.CursorOn; V := LfpNil; end
  else if Op = 'crt_delline' then begin Crt.DelLine; V := LfpNil; end
  else if Op = 'crt_insline' then begin Crt.InsLine; V := LfpNil; end
  else if Op = 'crt_window' then
  begin
    Crt.Window(Byte(RtlIntArg(Args, 1)), Byte(RtlIntArg(Args, 2)),
      Byte(RtlIntArg(Args, 3)), Byte(RtlIntArg(Args, 4)));
    V := LfpNil;
  end

  else if Op = 'kbd_init' then begin Keyboard.InitKeyboard; V := LfpNil; end
  else if Op = 'kbd_done' then begin Keyboard.DoneKeyboard; V := LfpNil; end
  else if Op = 'kbd_getevent' then V := LfpInt(Keyboard.GetKeyEvent)
  else if Op = 'kbd_pollevent' then V := LfpInt(Keyboard.PollKeyEvent)
  else if Op = 'kbd_pollshift' then V := LfpInt(Keyboard.PollShiftStateEvent)
  else if Op = 'kbd_putevent' then begin Keyboard.PutKeyEvent(Keyboard.TKeyEvent(RtlIntArg(Args, 1))); V := LfpNil; end
  else if Op = 'kbd_translate' then V := LfpInt(Keyboard.TranslateKeyEvent(Keyboard.TKeyEvent(RtlIntArg(Args, 1))))
  else if Op = 'kbd_translateunicode' then V := LfpInt(Keyboard.TranslateKeyEventUniCode(Keyboard.TKeyEvent(RtlIntArg(Args, 1))))
  else if Op = 'kbd_char' then V := LfpChar(WideChar(Keyboard.GetKeyEventChar(Keyboard.TKeyEvent(RtlIntArg(Args, 1)))))
  else if Op = 'kbd_unicode' then V := LfpInt(Keyboard.GetKeyEventUniCode(Keyboard.TKeyEvent(RtlIntArg(Args, 1))))
  else if Op = 'kbd_code' then V := LfpInt(Keyboard.GetKeyEventCode(Keyboard.TKeyEvent(RtlIntArg(Args, 1))))
  else if Op = 'kbd_flags' then V := LfpInt(Keyboard.GetKeyEventFlags(Keyboard.TKeyEvent(RtlIntArg(Args, 1))))
  else if Op = 'kbd_shift' then V := LfpInt(Keyboard.GetKeyEventShiftState(Keyboard.TKeyEvent(RtlIntArg(Args, 1))))
  else if Op = 'kbd_isfunction' then V := LfpBool(Keyboard.IsFunctionKey(Keyboard.TKeyEvent(RtlIntArg(Args, 1))))
  else if Op = 'kbd_keypressed' then V := LfpBool(Keyboard.KeyPressed)
  else if Op = 'kbd_eventtostring' then V := LfpString(UTF8Decode(Keyboard.KeyEventToString(Keyboard.TKeyEvent(RtlIntArg(Args, 1)))))
  else if Op = 'kbd_functionname' then V := LfpString(UTF8Decode(Keyboard.FunctionKeyName(Word(RtlIntArg(Args, 1)))))
  else if Op = 'kbd_shifttostring' then V := LfpString(UTF8Decode(Keyboard.ShiftStateToString(Keyboard.TKeyEvent(RtlIntArg(Args, 1)), RtlBoolArg(Args, 2))))

  else if Op = 'mouse_init' then begin Mouse.InitMouse; V := LfpNil; end
  else if Op = 'mouse_done' then begin Mouse.DoneMouse; V := LfpNil; end
  else if Op = 'mouse_detect' then V := LfpInt(Mouse.DetectMouse)
  else if Op = 'mouse_show' then begin Mouse.ShowMouse; V := LfpNil; end
  else if Op = 'mouse_hide' then begin Mouse.HideMouse; V := LfpNil; end
  else if Op = 'mouse_x' then V := LfpInt(Mouse.GetMouseX)
  else if Op = 'mouse_y' then V := LfpInt(Mouse.GetMouseY)
  else if Op = 'mouse_buttons' then V := LfpInt(Mouse.GetMouseButtons)
  else if Op = 'mouse_setxy' then begin Mouse.SetMouseXY(Word(RtlIntArg(Args, 1)), Word(RtlIntArg(Args, 2))); V := LfpNil; end

  else if Op = 'printer_init' then begin Printer.InitPrinter(RtlStringArg(Args, 1)); V := LfpNil; end
  else if Op = 'printer_available' then V := LfpBool(Printer.IsLstAvailable)

  else if Op = 'socket_create' then V := LfpInt(Sockets.fpSocket(LongInt(RtlIntArg(Args, 1)), LongInt(RtlIntArg(Args, 2)), LongInt(RtlIntArg(Args, 3))))
  else if Op = 'socket_listen' then V := LfpInt(Sockets.fpListen(LongInt(RtlIntArg(Args, 1)), LongInt(RtlIntArg(Args, 2))))
  else if Op = 'socket_shutdown' then V := LfpInt(Sockets.fpShutdown(LongInt(RtlIntArg(Args, 1)), LongInt(RtlIntArg(Args, 2))))
  else if Op = 'socket_close' then V := LfpInt(Sockets.CloseSocket(LongInt(RtlIntArg(Args, 1))))
  else if Op = 'socket_htonl' then V := LfpInt(Int64(Sockets.htonl(LongWord(RtlIntArg(Args, 1)))))
  else if Op = 'socket_htons' then V := LfpInt(Sockets.htons(Word(RtlIntArg(Args, 1))))
  else if Op = 'socket_ntohl' then V := LfpInt(Int64(Sockets.ntohl(LongWord(RtlIntArg(Args, 1)))))
  else if Op = 'socket_ntohs' then V := LfpInt(Sockets.ntohs(Word(RtlIntArg(Args, 1))))
  else if Op = 'socket_strtohost' then begin Addr := Sockets.StrToHostAddr(RtlStringArg(Args, 1)); V := LfpInt(Int64(Addr.s_addr)); end
  else if Op = 'socket_strtonet' then begin Addr := Sockets.StrToNetAddr(RtlStringArg(Args, 1)); V := LfpInt(Int64(Addr.s_addr)); end
  else if Op = 'socket_hosttostr' then begin Addr.s_addr := LongWord(RtlIntArg(Args, 1)); V := LfpString(UTF8Decode(Sockets.HostAddrToStr(Addr))); end
  else if Op = 'socket_nettostr' then begin Addr.s_addr := LongWord(RtlIntArg(Args, 1)); V := LfpString(UTF8Decode(Sockets.NetAddrToStr(Addr))); end

  {$IFDEF WINDOWS}
  else if Op = 'windirs_special' then V := LfpString(UTF8Decode(WinDirs.GetWindowsSpecialDir(LongInt(RtlIntArg(Args, 1)), RtlBoolArg(Args, 2))))
  else if Op = 'windirs_special_unicode' then V := LfpString(WinDirs.GetWindowsSpecialDirUnicode(LongInt(RtlIntArg(Args, 1)), RtlBoolArg(Args, 2)))
  else if Op = 'windirs_system' then V := LfpString(UTF8Decode(WinDirs.GetWindowsSystemDirectory))
  else if Op = 'windirs_system_unicode' then V := LfpString(WinDirs.GetWindowsSystemDirectoryUnicode)
  {$ENDIF}

  {$IFDEF LINUX}
  else if Op = 'linux_epoll_create' then V := LfpInt(Linux.epoll_create(LongInt(RtlIntArg(Args, 1))))
  else if Op = 'linux_fdatasync' then V := LfpInt(Linux.fdatasync(LongInt(RtlIntArg(Args, 1))))
  else if Op = 'linux_inotify_init' then V := LfpInt(Linux.inotify_init)
  else if Op = 'linux_inotify_init1' then V := LfpInt(Linux.inotify_init1(LongInt(RtlIntArg(Args, 1))))
  else if Op = 'linux_inotify_add_watch' then
  begin
    S := RtlStringArg(Args, 2);
    V := LfpInt(Linux.inotify_add_watch(LongInt(RtlIntArg(Args, 1)), PChar(S), LongWord(RtlIntArg(Args, 3))));
  end
  else if Op = 'linux_inotify_rm_watch' then V := LfpInt(Linux.inotify_rm_watch(LongInt(RtlIntArg(Args, 1)), LongInt(RtlIntArg(Args, 2))))
  else if Op = 'linux_sched_yield' then begin Linux.sched_yield; V := LfpInt(0); end
  else if Op = 'linux_setreuid' then V := LfpInt(Linux.setreuid(BaseUnix.TUid(RtlIntArg(Args, 1)), BaseUnix.TUid(RtlIntArg(Args, 2))))
  else if Op = 'linux_setregid' then V := LfpInt(Linux.setregid(BaseUnix.TGid(RtlIntArg(Args, 1)), BaseUnix.TGid(RtlIntArg(Args, 2))))
  {$ENDIF}

  {$IFDEF UNIX}
  else if Op = 'unix_access' then V := LfpInt(BaseUnix.FpAccess(RtlStringArg(Args, 1), LongInt(RtlIntArg(Args, 2))))
  else if Op = 'unix_alarm' then V := LfpInt(BaseUnix.FpAlarm(LongWord(RtlIntArg(Args, 1))))
  else if Op = 'unix_chdir' then V := LfpInt(BaseUnix.FpChdir(RtlStringArg(Args, 1)))
  else if Op = 'unix_chmod' then V := LfpInt(BaseUnix.FpChmod(RtlStringArg(Args, 1), BaseUnix.TMode(RtlIntArg(Args, 2))))
  else if Op = 'unix_chown' then V := LfpInt(BaseUnix.FpChown(RtlStringArg(Args, 1), BaseUnix.TUid(RtlIntArg(Args, 2)), BaseUnix.TGid(RtlIntArg(Args, 3))))
  else if Op = 'unix_close' then V := LfpInt(BaseUnix.FpClose(LongInt(RtlIntArg(Args, 1))))
  else if Op = 'unix_dup' then V := LfpInt(BaseUnix.FpDup(LongInt(RtlIntArg(Args, 1))))
  else if Op = 'unix_dup2' then V := LfpInt(BaseUnix.FpDup2(LongInt(RtlIntArg(Args, 1)), LongInt(RtlIntArg(Args, 2))))
  else if Op = 'unix_ftruncate' then V := LfpInt(BaseUnix.FpFtruncate(LongInt(RtlIntArg(Args, 1)), BaseUnix.TOff(RtlIntArg(Args, 2))))
  else if Op = 'unix_getcwd' then V := LfpString(UTF8Decode(BaseUnix.FpGetcwd))
  else if Op = 'unix_getegid' then V := LfpInt(BaseUnix.FpGetegid)
  else if Op = 'unix_geteuid' then V := LfpInt(BaseUnix.FpGeteuid)
  else if Op = 'unix_getgid' then V := LfpInt(BaseUnix.FpGetgid)
  else if Op = 'unix_getpgrp' then V := LfpInt(BaseUnix.FpGetpgrp)
  else if Op = 'unix_getpid' then V := LfpInt(BaseUnix.FpGetpid)
  else if Op = 'unix_getppid' then V := LfpInt(BaseUnix.FpGetppid)
  else if Op = 'unix_getuid' then V := LfpInt(BaseUnix.FpGetuid)
  else if Op = 'unix_geterrno' then V := LfpInt(BaseUnix.fpgeterrno)
  else if Op = 'unix_seterrno' then begin BaseUnix.fpseterrno(LongInt(RtlIntArg(Args, 1))); V := LfpNil; end
  else if Op = 'unix_kill' then V := LfpInt(BaseUnix.FpKill(BaseUnix.TPid(RtlIntArg(Args, 1)), LongInt(RtlIntArg(Args, 2))))
  else if Op = 'unix_link' then V := LfpInt(BaseUnix.FpLink(RtlStringArg(Args, 1), RtlStringArg(Args, 2)))
  else if Op = 'unix_lseek' then V := LfpInt(BaseUnix.FpLseek(LongInt(RtlIntArg(Args, 1)), BaseUnix.TOff(RtlIntArg(Args, 2)), LongInt(RtlIntArg(Args, 3))))
  else if Op = 'unix_mkdir' then V := LfpInt(BaseUnix.FpMkdir(RtlStringArg(Args, 1), BaseUnix.TMode(RtlIntArg(Args, 2))))
  else if Op = 'unix_mkfifo' then V := LfpInt(BaseUnix.FpMkfifo(RtlStringArg(Args, 1), BaseUnix.TMode(RtlIntArg(Args, 2))))
  else if Op = 'unix_nice' then V := LfpInt(BaseUnix.fpNice(LongInt(RtlIntArg(Args, 1))))
  else if Op = 'unix_open' then V := LfpInt(BaseUnix.FpOpen(RtlStringArg(Args, 1), LongInt(RtlIntArg(Args, 2)), BaseUnix.TMode(RtlIntArg(Args, 3))))
  else if Op = 'unix_rename' then V := LfpInt(BaseUnix.FpRename(RtlStringArg(Args, 1), RtlStringArg(Args, 2)))
  else if Op = 'unix_rmdir' then V := LfpInt(BaseUnix.FpRmdir(RtlStringArg(Args, 1)))
  else if Op = 'unix_symlink' then
  begin
    S := RtlStringArg(Args, 1);
    T := RtlStringArg(Args, 2);
    V := LfpInt(BaseUnix.fpSymlink(PChar(S), PChar(T)));
  end
  else if Op = 'unix_umask' then V := LfpInt(BaseUnix.FpUmask(BaseUnix.TMode(RtlIntArg(Args, 1))))
  else if Op = 'unix_unlink' then V := LfpInt(BaseUnix.FpUnlink(RtlStringArg(Args, 1)))
  else if Op = 'unix_system' then V := LfpInt(Unix.fpSystem(RtlStringArg(Args, 1)))
  else if Op = 'unix_fsearch' then V := LfpString(UTF8Decode(Unix.FSearch(RtlStringArg(Args, 1), RtlStringArg(Args, 2))))
  else if Op = 'unix_hostname' then V := LfpString(UTF8Decode(Unix.GetHostName))
  {$PUSH}
  {$WARN SYMBOL_DEPRECATED OFF}
  else if Op = 'unix_domainname' then V := LfpString(UTF8Decode(Unix.GetDomainName))
  {$POP}
  else if Op = 'unix_timezonefile' then V := LfpString(UTF8Decode(Unix.GetTimezoneFile))
  else if Op = 'unix_localtoepoch' then V := LfpInt(DateUtils.DateTimeToUnix(RtlRealArg(Args, 1), False))
  else if Op = 'unix_universaltoepoch' then V := LfpInt(DateUtils.DateTimeToUnix(RtlRealArg(Args, 1), True))
  else if Op = 'unix_epochtolocal' then V := LfpReal(DateUtils.UnixToDateTime(RtlIntArg(Args, 1), False))
  else if Op = 'unix_epochtouniversal' then V := LfpReal(DateUtils.UnixToDateTime(RtlIntArg(Args, 1), True))
  else if Op = 'unix_fsync' then V := LfpInt(Unix.fpfsync(LongInt(RtlIntArg(Args, 1))))
  else if Op = 'unix_waitprocess' then V := LfpInt(Unix.WaitProcess(LongInt(RtlIntArg(Args, 1))))
  else if Op = 'unix_wifstopped' then V := LfpBool(Unix.WIFSTOPPED(LongInt(RtlIntArg(Args, 1))))
  else if Op = 'unix_w_exitcode' then V := LfpInt(Unix.W_EXITCODE(LongInt(RtlIntArg(Args, 1)), LongInt(RtlIntArg(Args, 2))))
  else if Op = 'unix_w_stopcode' then V := LfpInt(Unix.W_STOPCODE(LongInt(RtlIntArg(Args, 1))))
  else if Op = 'unixcp_getbyname' then V := LfpInt(UnixCp.GetCodepageByName(RtlStringArg(Args, 1)))
  else if Op = 'unixcp_getsystem' then V := LfpInt(UnixCp.GetSystemCodepage)
  else if Op = 'unixcp_getdata' then V := LfpInt(UnixCp.GetCodepageData(Word(RtlIntArg(Args, 1))))
  {$ENDIF}
  {$IFNDEF WINDOWS}
  else if Copy(Op, 1, 8) = 'windirs_' then
    raise ELfpRuntimeError.Create('WinDirs unit is only available on Windows')
  {$ENDIF}
  {$IFNDEF LINUX}
  else if Copy(Op, 1, 6) = 'linux_' then
    raise ELfpRuntimeError.Create('Linux unit is only available on Linux')
  {$ENDIF}
  {$IFNDEF UNIX}
  else if (Copy(Op, 1, 5) = 'unix_') or (Copy(Op, 1, 7) = 'unixcp_') then
    raise ELfpRuntimeError.Create('Unix RTL unit is only available on Unix-like systems')
  {$ENDIF}
  else
  begin
    Result := False;
    V := LfpNil;
  end;
end;

function RtlBase64Encode(const S: UnicodeString): UnicodeString;
const
  Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  I, N, B1, B2, B3: Integer;
begin
  Result := '';
  I := 1;
  N := Length(S);
  while I <= N do
  begin
    if Ord(S[I]) > 255 then
      raise ELfpRuntimeError.Create('Base64 string contains a character outside the byte range');
    B1 := Ord(S[I]);
    if I + 1 <= N then
    begin
      if Ord(S[I + 1]) > 255 then
        raise ELfpRuntimeError.Create('Base64 string contains a character outside the byte range');
      B2 := Ord(S[I + 1]);
    end
    else B2 := -1;
    if I + 2 <= N then
    begin
      if Ord(S[I + 2]) > 255 then
        raise ELfpRuntimeError.Create('Base64 string contains a character outside the byte range');
      B3 := Ord(S[I + 2]);
    end
    else B3 := -1;
    Result := Result + UnicodeString(Alphabet[(B1 shr 2) + 1]);
    if B2 >= 0 then
      Result := Result + UnicodeString(Alphabet[(((B1 and 3) shl 4) or (B2 shr 4)) + 1])
    else
      Result := Result + UnicodeString(Alphabet[((B1 and 3) shl 4) + 1]);
    if B2 < 0 then
      Result := Result + '=='
    else if B3 < 0 then
      Result := Result + UnicodeString(Alphabet[((B2 and 15) shl 2) + 1]) + '='
    else
      Result := Result + UnicodeString(Alphabet[(((B2 and 15) shl 2) or (B3 shr 6)) + 1]) +
        UnicodeString(Alphabet[(B3 and 63) + 1]);
    Inc(I, 3);
  end;
end;

function RtlBase64Digit(C: Char): Integer;
begin
  case C of
    'A'..'Z': Result := Ord(C) - Ord('A');
    'a'..'z': Result := Ord(C) - Ord('a') + 26;
    '0'..'9': Result := Ord(C) - Ord('0') + 52;
    '+': Result := 62;
    '/': Result := 63;
  else
    Result := -1;
  end;
end;

function RtlBase64Decode(const Input: UnicodeString; Strict: Boolean): UnicodeString;
var
  Clean: string;
  I, N, Pad, D1, D2, D3, D4, B: Integer;
  C: WideChar;
begin
  Clean := '';
  for I := 1 to Length(Input) do
  begin
    C := Input[I];
    if Ord(C) > 127 then
    begin
      if Strict then raise ELfpRuntimeError.Create('invalid Base64 character');
      Continue;
    end;
    if C = '=' then
    begin
      Clean := Clean + '=';
      if not Strict then Break;
    end
    else if RtlBase64Digit(Char(C)) >= 0 then
      Clean := Clean + Char(C)
    else if Strict then
      raise ELfpRuntimeError.Create('invalid Base64 character');
  end;
  if Strict and ((Length(Clean) mod 4) <> 0) then
    raise ELfpRuntimeError.Create('strict Base64 input length must be a multiple of 4');
  if not Strict then
    while (Length(Clean) mod 4) <> 0 do Clean := Clean + '=';
  Result := '';
  I := 1;
  N := Length(Clean);
  while I <= N do
  begin
    if I + 1 > N then Break;
    D1 := RtlBase64Digit(Clean[I]);
    D2 := RtlBase64Digit(Clean[I + 1]);
    if (D1 < 0) or (D2 < 0) then
      raise ELfpRuntimeError.Create('invalid Base64 quartet');
    Pad := 0;
    if (I + 2 > N) or (Clean[I + 2] = '=') then begin D3 := 0; Inc(Pad); end
    else begin D3 := RtlBase64Digit(Clean[I + 2]); if D3 < 0 then raise ELfpRuntimeError.Create('invalid Base64 quartet'); end;
    if (I + 3 > N) or (Clean[I + 3] = '=') then begin D4 := 0; Inc(Pad); end
    else begin D4 := RtlBase64Digit(Clean[I + 3]); if D4 < 0 then raise ELfpRuntimeError.Create('invalid Base64 quartet'); end;
    if Strict then
    begin
      if Pad > 2 then raise ELfpRuntimeError.Create('invalid Base64 padding');
      if (Pad > 0) and (I + 3 <> N) then raise ELfpRuntimeError.Create('Base64 padding is only valid at the end');
      if (Clean[I + 2] = '=') and (Clean[I + 3] <> '=') then raise ELfpRuntimeError.Create('invalid Base64 padding');
    end;
    B := (D1 shl 2) or (D2 shr 4);
    Result := Result + WideChar(B and 255);
    if Clean[I + 2] <> '=' then
    begin
      B := ((D2 and 15) shl 4) or (D3 shr 2);
      Result := Result + WideChar(B and 255);
    end;
    if Clean[I + 3] <> '=' then
    begin
      B := ((D3 and 3) shl 6) or D4;
      Result := Result + WideChar(B and 255);
    end;
    Inc(I, 4);
  end;
end;

function RtlUriHex(N: Byte): Char;
begin
  if N < 10 then Result := Chr(Ord('0') + N)
  else Result := Chr(Ord('A') + N - 10);
end;

function RtlUriEncodePart(const S: UnicodeString; AllowSlash: Boolean): string;
var
  U: RawByteString;
  I: Integer;
  B: Byte;
  C: Char;
begin
  U := UTF8Encode(S);
  Result := '';
  for I := 1 to Length(U) do
  begin
    B := Ord(U[I]);
    C := Char(B);
    if (C in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~']) or
       (AllowSlash and (C = '/')) then
      Result := Result + C
    else
      Result := Result + '%' + RtlUriHex(B shr 4) + RtlUriHex(B and 15);
  end;
end;

function RtlUriHexValue(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
  else
    Result := -1;
  end;
end;

function RtlUriDecodePart(const S: string): UnicodeString;
var
  B: RawByteString;
  I, H1, H2: Integer;
begin
  B := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '%') and (I + 2 <= Length(S)) then
    begin
      H1 := RtlUriHexValue(S[I + 1]);
      H2 := RtlUriHexValue(S[I + 2]);
      if (H1 >= 0) and (H2 >= 0) then
      begin
        B := B + Char((H1 shl 4) or H2);
        Inc(I, 3);
        Continue;
      end;
    end;
    B := B + S[I];
    Inc(I);
  end;
  Result := UTF8Decode(B);
end;

function RtlUriIsScheme(const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if S = '' then Exit;
  if not (S[1] in ['A'..'Z', 'a'..'z']) then Exit;
  for I := 2 to Length(S) do
    if not (S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '-', '.']) then Exit;
  Result := True;
end;

function RtlUriRecord(Engine: TLfpEngine; const Source: UnicodeString;
  DecodeParts: Boolean; const DefaultProtocol: string; DefaultPort: Int64): TLfpValue;
var
  S, Work, Authority, UserInfo, HostPort, Proto, UserName, Password, Host,
    PathPart, Document, Params, Bookmark: string;
  P, Q, SlashPos, ColonPos: Integer;
  Port: Int64;
  HasAuthority: Boolean;
  Values: TLfpValueArray;
  Ctor: TLfpValue;
  function Dec(const X: string): UnicodeString;
  begin
    if DecodeParts then Result := RtlUriDecodePart(X) else Result := UTF8Decode(X);
  end;
begin
  S := UTF8Encode(Source);
  Work := S;
  Proto := '';
  UserName := '';
  Password := '';
  Host := '';
  PathPart := '';
  Document := '';
  Params := '';
  Bookmark := '';
  Port := DefaultPort;
  HasAuthority := False;

  P := Pos('#', Work);
  if P > 0 then begin Bookmark := Copy(Work, P + 1, MaxInt); Work := Copy(Work, 1, P - 1); end;
  P := Pos('?', Work);
  if P > 0 then begin Params := Copy(Work, P + 1, MaxInt); Work := Copy(Work, 1, P - 1); end;

  ColonPos := Pos(':', Work);
  SlashPos := Pos('/', Work);
  if (ColonPos > 0) and ((SlashPos = 0) or (ColonPos < SlashPos)) and RtlUriIsScheme(Copy(Work, 1, ColonPos - 1)) then
  begin
    Proto := Copy(Work, 1, ColonPos - 1);
    Delete(Work, 1, ColonPos);
  end
  else Proto := DefaultProtocol;

  if Copy(Work, 1, 2) = '//' then
  begin
    HasAuthority := True;
    Delete(Work, 1, 2);
    P := Pos('/', Work);
    if P > 0 then begin Authority := Copy(Work, 1, P - 1); Work := Copy(Work, P, MaxInt); end
    else begin Authority := Work; Work := ''; end;
    P := LastDelimiter('@', Authority);
    if P > 0 then
    begin
      UserInfo := Copy(Authority, 1, P - 1);
      HostPort := Copy(Authority, P + 1, MaxInt);
      Q := Pos(':', UserInfo);
      if Q > 0 then begin UserName := Copy(UserInfo, 1, Q - 1); Password := Copy(UserInfo, Q + 1, MaxInt); end
      else UserName := UserInfo;
    end
    else HostPort := Authority;
    if Copy(HostPort, 1, 1) = '[' then
    begin
      P := Pos(']', HostPort);
      if P > 0 then
      begin
        Host := Copy(HostPort, 1, P);
        if (P < Length(HostPort)) and (HostPort[P + 1] = ':') then
          if not TryStrToInt64(Copy(HostPort, P + 2, MaxInt), Port) then Port := DefaultPort;
      end
      else Host := HostPort;
    end
    else
    begin
      P := LastDelimiter(':', HostPort);
      if (P > 0) and (Pos(':', Copy(HostPort, 1, P - 1)) = 0) then
      begin
        Host := Copy(HostPort, 1, P - 1);
        if not TryStrToInt64(Copy(HostPort, P + 1, MaxInt), Port) then
        begin
          Host := HostPort;
          Port := DefaultPort;
        end;
      end
      else Host := HostPort;
    end;
  end;

  if Work <> '' then
  begin
    P := LastDelimiter('/', Work);
    if P > 0 then begin PathPart := Copy(Work, 1, P); Document := Copy(Work, P + 1, MaxInt); end
    else Document := Work;
  end;

  SetLength(Values, 10);
  Values[0] := LfpString(Dec(Proto));
  Values[1] := LfpString(Dec(UserName));
  Values[2] := LfpString(Dec(Password));
  Values[3] := LfpString(Dec(Host));
  Values[4] := LfpInt(Port);
  Values[5] := LfpString(Dec(PathPart));
  Values[6] := LfpString(Dec(Document));
  Values[7] := LfpString(Dec(Params));
  Values[8] := LfpString(Dec(Bookmark));
  Values[9] := LfpBool(HasAuthority);
  Ctor := Engine.GetGlobal('TURI');
  Result := Engine.ExecuteCallable(Ctor, Values);
end;

function RtlUriEncodeRecord(const V: TLfpValue): UnicodeString;
var
  R: TLfpRecordObject;
  Proto, UserName, Password, Host, PathPart, Document, Params, Bookmark: UnicodeString;
  Port: Int64;
  HasAuthority: Boolean;
  S: string;
begin
  if (V.Kind <> vkObject) or not (V.ObjValue is TLfpRecordObject) then
    raise ELfpRuntimeError.Create('EncodeURI expects TURI');
  R := TLfpRecordObject(V.ObjValue);
  Proto := LfpValueAsString(R.GetField('Protocol'));
  UserName := LfpValueAsString(R.GetField('Username'));
  Password := LfpValueAsString(R.GetField('Password'));
  Host := LfpValueAsString(R.GetField('Host'));
  Port := LfpToInt(R.GetField('Port'));
  PathPart := LfpValueAsString(R.GetField('Path'));
  Document := LfpValueAsString(R.GetField('Document'));
  Params := LfpValueAsString(R.GetField('Params'));
  Bookmark := LfpValueAsString(R.GetField('Bookmark'));
  HasAuthority := LfpTruthy(R.GetField('HasAuthority'));
  S := '';
  if Proto <> '' then S := S + UTF8Encode(Proto) + ':';
  if HasAuthority or (Host <> '') then
  begin
    S := S + '//';
    if UserName <> '' then
    begin
      S := S + RtlUriEncodePart(UserName, False);
      if Password <> '' then S := S + ':' + RtlUriEncodePart(Password, False);
      S := S + '@';
    end;
    S := S + UTF8Encode(Host);
    if Port <> 0 then S := S + ':' + IntToStr(Port);
  end;
  S := S + RtlUriEncodePart(PathPart, True) + RtlUriEncodePart(Document, False);
  if Params <> '' then S := S + '?' + RtlUriEncodePart(Params, False);
  if Bookmark <> '' then S := S + '#' + RtlUriEncodePart(Bookmark, False);
  Result := UTF8Decode(S);
end;

function RtlFilenameToUri(const FileName: UnicodeString; EncodePath: Boolean): UnicodeString;
var
  P: UnicodeString;
  S: string;
  {$IFDEF WINDOWS}
  I: Integer;
  {$ENDIF}
begin
  P := FileName;
  {$IFDEF WINDOWS}
  for I := 1 to Length(P) do
    if P[I] = '\' then P[I] := '/';
  {$ENDIF}
  if EncodePath then S := RtlUriEncodePart(P, True) else S := UTF8Encode(P);
  if (S <> '') and (S[1] <> '/') and not ((Length(S) >= 2) and (S[2] = ':')) then
    S := '/' + S;
  Result := UTF8Decode('file://' + S);
end;

function TryNativeRtlExtended(Engine: TLfpEngine; const Op: string;
  const Args: TLfpValueArray; out V: TLfpValue): Boolean;
var
  A, B, S, T: string;
  I, J, K: Int64;
  R: Double;
  Arr: TLfpArrayObject;
  CS: TSysCharSet;
  DT: TDateTime;
  Fmt: TFormatSettings;
begin
  Result := True;
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';

  if Op = 'datetostr' then V := LfpString(UTF8Decode(SysUtils.DateToStr(RtlRealArg(Args,1), Fmt)))
  else if Op = 'timetostr' then V := LfpString(UTF8Decode(SysUtils.TimeToStr(RtlRealArg(Args,1), Fmt)))
  else if Op = 'datetimetostr' then V := LfpString(UTF8Decode(SysUtils.DateTimeToStr(RtlRealArg(Args,1), Fmt)))
  else if Op = 'formatdatetime' then V := LfpString(UTF8Decode(SysUtils.FormatDateTime(RtlStringArg(Args,1), RtlRealArg(Args,2), Fmt)))
  else if Op = 'strtodate' then V := LfpReal(SysUtils.StrToDate(RtlStringArg(Args,1), Fmt))
  else if Op = 'strtotime' then V := LfpReal(SysUtils.StrToTime(RtlStringArg(Args,1), Fmt))
  else if Op = 'strtodatetime' then V := LfpReal(SysUtils.StrToDateTime(RtlStringArg(Args,1), Fmt))
  else if Op = 'strtodatedef' then begin if not SysUtils.TryStrToDate(RtlStringArg(Args,1), DT, Fmt) then DT := RtlRealArg(Args,2); V := LfpReal(DT); end
  else if Op = 'strtotimedef' then begin if not SysUtils.TryStrToTime(RtlStringArg(Args,1), DT, Fmt) then DT := RtlRealArg(Args,2); V := LfpReal(DT); end
  else if Op = 'strtodatetimedef' then begin if not SysUtils.TryStrToDateTime(RtlStringArg(Args,1), DT, Fmt) then DT := RtlRealArg(Args,2); V := LfpReal(DT); end
  else if Op = 'trystrtodate' then V := LfpBool(SysUtils.TryStrToDate(RtlStringArg(Args,1), DT, Fmt))
  else if Op = 'trystrtotime' then V := LfpBool(SysUtils.TryStrToTime(RtlStringArg(Args,1), DT, Fmt))
  else if Op = 'trystrtodatetime' then V := LfpBool(SysUtils.TryStrToDateTime(RtlStringArg(Args,1), DT, Fmt))
  else if Op = 'trystrtoint' then V := LfpBool(TryStrToInt64(RtlStringArg(Args,1), I))
  else if Op = 'trystrtofloat' then V := LfpBool(TryStrToFloat(RtlStringArg(Args,1), R, Fmt))
  else if Op = 'trystrtobool' then begin S := LowerCase(Trim(RtlStringArg(Args,1))); V := LfpBool((S='true') or (S='false') or (S='1') or (S='0') or (S='yes') or (S='no') or (S='on') or (S='off')); end
  else if Op = 'inttohex' then V := LfpString(UTF8Decode(IntToHex(RtlIntArg(Args,1), RtlIntArg(Args,2))))
  else if Op = 'hextoint' then V := LfpInt(RtlBaseToInt(StringReplace(RtlStringArg(Args,1), '$', '', []), 16))
  else if Op = 'basetoint' then V := LfpInt(RtlBaseToInt(RtlStringArg(Args,1), RtlIntArg(Args,2)))
  else if Op = 'inttobase' then V := LfpString(UTF8Decode(RtlIntToBase(RtlIntArg(Args,1), RtlIntArg(Args,3), RtlIntArg(Args,2))))
  else if Op = 'isvalidident' then begin S := RtlStringArg(Args,1); if S='' then V:=LfpBool(False) else begin V:=LfpBool((S[1]='_') or (S[1] in ['A'..'Z','a'..'z'])); if V.BoolValue then for I:=2 to Length(S) do if not (S[I] in ['A'..'Z','a'..'z','0'..'9','_']) then begin V:=LfpBool(False); Break; end; end; end
  else if Op = 'dodirseparators' then begin S:=RtlStringArg(Args,1); for I:=1 to Length(S) do if S[I] in ['/', '\'] then S[I]:=DirectorySeparator; V:=LfpString(UTF8Decode(S)); end
  else if Op = 'concatpaths' then V := LfpString(RtlJoinArray(Args[1], UTF8Decode(DirectorySeparator)))
  else if Op = 'extractrelativepath' then V := LfpString(UTF8Decode(SysUtils.ExtractRelativePath(RtlStringArg(Args,1), RtlStringArg(Args,2))))
  else if Op = 'applicationname' then V := LfpString(UTF8Decode(ChangeFileExt(ExtractFileName(ParamStr(0)), '')))
  else if Op = 'modulename' then V := LfpString(UTF8Decode(ExpandFileName(ParamStr(0))))
  else if Op = 'compiledarch' then
  begin
    {$IFDEF CPUX86_64} V := LfpString('x86_64'); {$ELSE}
    {$IFDEF CPUAARCH64} V := LfpString('aarch64'); {$ELSE}
    {$IFDEF CPUI386} V := LfpString('i386'); {$ELSE}
    V := LfpString('unknown'); {$ENDIF}{$ENDIF}{$ENDIF}
  end
  else if Op = 'compiledplatform' then
  begin
    {$IFDEF WINDOWS} V := LfpString('windows'); {$ELSE}
    {$IFDEF DARWIN} V := LfpString('darwin'); {$ELSE}
    {$IFDEF LINUX} V := LfpString('linux'); {$ELSE}
    V := LfpString('unknown'); {$ENDIF}{$ENDIF}{$ENDIF}
  end
  else if Op = 'getappconfigdir' then begin if RtlBoolArg(Args,1) then S:=GetTempDir else S:=GetAppConfigDir(False); V:=LfpString(UTF8Decode(S)); end
  else if Op = 'getappconfigfile' then begin if RtlBoolArg(Args,1) then S:=GetTempDir else S:=GetAppConfigDir(False); S:=IncludeTrailingPathDelimiter(S)+ChangeFileExt(ExtractFileName(ParamStr(0)),'.cfg'); V:=LfpString(UTF8Decode(S)); end
  else if Op = 'tempfilename' then V := LfpString(UTF8Decode(SysUtils.GetTempFileName(RtlStringArg(Args,1), RtlStringArg(Args,2))))
  else if Op = 'fileage' then begin I:=SysUtils.FileAge(RtlStringArg(Args,1)); if I=-1 then V:=LfpReal(0) else V:=LfpReal(SysUtils.FileDateToDateTime(I)); end
  else if Op = 'fileattr' then V := LfpInt(SysUtils.FileGetAttr(RtlStringArg(Args,1)))
  else if Op = 'lastoserror' then V := LfpInt(SysUtils.GetLastOSError)
  else if Op = 'strerror' then V := LfpString(UTF8Decode(SysUtils.SysErrorMessage(RtlIntArg(Args,1))))
  else if Op = 'dosversion' then V := LfpInt($0700)

  else if Op = 'matcharray' then V := LfpBool(RtlArrayIndex(Args[2], LfpValueAsString(Args[1]), RtlBoolArg(Args,3)) >= 0)
  else if Op = 'indexarray' then V := LfpInt(RtlArrayIndex(Args[2], LfpValueAsString(Args[1]), RtlBoolArg(Args,3)))
  else if Op = 'joinarray' then V := LfpString(RtlJoinArray(Args[1], LfpValueAsString(Args[2])))
  else if Op = 'indexofname' then begin Arr:=RtlValueArray(Args[1]); S:=RtlStringArg(Args,2); J:=-1; for I:=Arr.LowerBound to Arr.UpperBound do begin A:=UTF8Encode(LfpValueAsString(Arr.GetItem(I))); K:=Pos('=',A); if K>0 then A:=Copy(A,1,K-1); if CompareText(Trim(A),S)=0 then begin J:=I-Arr.LowerBound; Break; end; end; V:=LfpInt(J); end
  else if Op = 'valuefromindex' then begin Arr:=RtlValueArray(Args[1]); I:=RtlIntArg(Args,2)+Arr.LowerBound; A:=UTF8Encode(LfpValueAsString(Arr.GetItem(I))); J:=Pos('=',A); if J>0 then A:=Copy(A,J+1,MaxInt) else A:=''; V:=LfpString(UTF8Decode(A)); end
  else if Op = 'securecompare' then begin A:=RtlStringArg(Args,1); B:=RtlStringArg(Args,2); J:=Length(A) xor Length(B); K:=Max(Length(A),Length(B)); for I:=1 to K do begin if I<=Length(A) then S:=A[I] else S:=#0; if I<=Length(B) then T:=B[I] else T:=#0; J:=J or (Ord(S[1]) xor Ord(T[1])); end; V:=LfpBool(J=0); end
  else if Op = 'stuffstring' then V := LfpString(UTF8Decode(StrUtils.StuffString(RtlStringArg(Args,1), RtlIntArg(Args,2), RtlIntArg(Args,3), RtlStringArg(Args,4))))
  else if Op = 'naturalcompare' then V := LfpInt(StrUtils.NaturalCompareText(RtlStringArg(Args,1), RtlStringArg(Args,2)))
  else if Op = 'deletechars' then begin S:=RtlStringArg(Args,1); CS:=RtlCharSet(RtlStringArg(Args,2)); T:=''; for I:=1 to Length(S) do if not (S[I] in CS) then T:=T+S[I]; V:=LfpString(UTF8Decode(T)); end
  else if Op = 'collapsespaces' then begin S:=Trim(RtlStringArg(Args,1)); while Pos('  ',S)>0 do S:=StringReplace(S,'  ',' ',[rfReplaceAll]); V:=LfpString(UTF8Decode(S)); end
  else if Op = 'tabtospace' then begin S:=RtlStringArg(Args,1); V:=LfpString(UTF8Decode(StringReplace(S,#9,StringOfChar(' ',RtlIntArg(Args,2)),[rfReplaceAll]))); end
  else if Op = 'npos' then begin A:=RtlStringArg(Args,1); B:=RtlStringArg(Args,2); J:=0; K:=0; for I:=1 to RtlIntArg(Args,3) do begin K:=Pos(A,Copy(B,J+1,MaxInt)); if K=0 then begin J:=0; Break; end; J:=J+K; end; V:=LfpInt(J); end
  else if Op = 'trimleftset' then begin S:=RtlStringArg(Args,1); CS:=RtlCharSet(RtlStringArg(Args,2)); I:=1; while (I<=Length(S)) and (S[I] in CS) do Inc(I); V:=LfpString(UTF8Decode(Copy(S,I,MaxInt))); end
  else if Op = 'trimrightset' then begin S:=RtlStringArg(Args,1); CS:=RtlCharSet(RtlStringArg(Args,2)); I:=Length(S); while (I>0) and (S[I] in CS) do Dec(I); V:=LfpString(UTF8Decode(Copy(S,1,I))); end
  else if Op = 'trimset' then begin S:=RtlStringArg(Args,1); CS:=RtlCharSet(RtlStringArg(Args,2)); I:=1; while (I<=Length(S)) and (S[I] in CS) do Inc(I); J:=Length(S); while (J>=I) and (S[J] in CS) do Dec(J); V:=LfpString(UTF8Decode(Copy(S,I,J-I+1))); end
  else if Op = 'posset' then begin S:=RtlStringArg(Args,2); CS:=RtlCharSet(RtlStringArg(Args,1)); J:=0; for I:=Max(1,RtlIntArg(Args,3)) to Length(S) do if S[I] in CS then begin J:=I; Break; end; V:=LfpInt(J); end
  else if Op = 'propercase' then V := LfpString(UTF8Decode(StrUtils.AnsiProperCase(RtlStringArg(Args,1), RtlCharSet(RtlStringArg(Args,2)))))
  else if Op = 'wordcount' then V := LfpInt(StrUtils.WordCount(RtlStringArg(Args,1), RtlCharSet(RtlStringArg(Args,2))))
  else if Op = 'wordposition' then V := LfpInt(StrUtils.WordPosition(RtlIntArg(Args,1), RtlStringArg(Args,2), RtlCharSet(RtlStringArg(Args,3))))
  else if Op = 'extractword' then V := LfpString(UTF8Decode(StrUtils.ExtractWord(RtlIntArg(Args,1), RtlStringArg(Args,2), RtlCharSet(RtlStringArg(Args,3)))))
  else if Op = 'iswordpresent' then V := LfpBool(StrUtils.IsWordPresent(RtlStringArg(Args,1), RtlStringArg(Args,2), RtlCharSet(RtlStringArg(Args,3))))
  else if Op = 'iswild' then V := LfpBool(RtlWildcardMatch(RtlStringArg(Args,1), RtlStringArg(Args,2), RtlBoolArg(Args,3)))
  else if Op = 'findpart' then begin A:=RtlStringArg(Args,1); B:=RtlStringArg(Args,2); J:=0; for I:=1 to Length(B) do if RtlWildcardMatch(Copy(B,I,MaxInt),A,False) then begin J:=I; Break; end; V:=LfpInt(J); end
  else if Op = 'xorstring' then begin A:=RtlStringArg(Args,1); B:=RtlStringArg(Args,2); if A='' then V:=LfpString(UTF8Decode(B)) else begin S:=''; for I:=1 to Length(B) do S:=S+Chr(Ord(B[I]) xor Ord(A[((I-1) mod Length(A))+1])); V:=LfpString(UTF8Decode(S)); end; end
  else if Op = 'xorencode' then V := LfpString(UTF8Decode(StrUtils.XorEncode(RtlStringArg(Args,1), RtlStringArg(Args,2))))
  else if Op = 'xordecode' then V := LfpString(UTF8Decode(StrUtils.XorDecode(RtlStringArg(Args,1), RtlStringArg(Args,2))))
  else if Op = 'numb2usa' then V := LfpString(UTF8Decode(StrUtils.Numb2USA(RtlStringArg(Args,1))))
  else if Op = 'inttoroman' then V := LfpString(UTF8Decode(StrUtils.IntToRoman(RtlIntArg(Args,1))))
  else if Op = 'romantoint' then V := LfpInt(StrUtils.RomanToInt(RtlStringArg(Args,1)))
  else if Op = 'romantointdef' then begin try I:=StrUtils.RomanToInt(RtlStringArg(Args,1)); except I:=RtlIntArg(Args,2); end; V:=LfpInt(I); end
  else if Op = 'soundex' then V := LfpString(UTF8Decode(StrUtils.Soundex(RtlStringArg(Args,1), RtlIntArg(Args,2))))
  else if Op = 'soundexint' then V := LfpInt(RtlSoundexPacked(RtlStringArg(Args,1)))
  else if Op = 'decodesoundex' then V := LfpString(UTF8Decode(RtlSoundexUnpack(RtlIntArg(Args,1), RtlIntArg(Args,2))))

  else if Op = 'weeksinyear' then V := LfpInt(DateUtils.WeeksInAYear(RtlIntArg(Args,1)))
  else if Op = 'startofaweek' then V := LfpReal(DateUtils.StartOfAWeek(RtlIntArg(Args,1), RtlIntArg(Args,2)))
  else if Op = 'encodedateday' then V := LfpReal(DateUtils.EncodeDateDay(RtlIntArg(Args,1), RtlIntArg(Args,2)))
  else if Op = 'encodedateweek' then V := LfpReal(DateUtils.EncodeDateWeek(RtlIntArg(Args,1), RtlIntArg(Args,2)))
  else if Op = 'centuryof' then begin I := DateUtils.YearOf(RtlRealArg(Args,1)); V := LfpInt(((I - 1) div 100) + 1); end
  else if Op = 'yearofthecentury' then begin I := DateUtils.YearOf(RtlRealArg(Args,1)); V := LfpInt(((I - 1) mod 100) + 1); end
  else if Op = 'yearofthedecade' then begin I := DateUtils.YearOf(RtlRealArg(Args,1)); V := LfpInt(I mod 10); end
  else if Op = 'decadeof' then begin I := DateUtils.YearOf(RtlRealArg(Args,1)); V := LfpInt(I div 10); end
  else if Op = 'decadeofthecentury' then begin I := DateUtils.YearOf(RtlRealArg(Args,1)); V := LfpInt((I div 10) mod 10); end
  else if Op = 'eraof' then V := LfpInt(1)
  else if Op = 'julian' then V := LfpReal(DateUtils.DateTimeToJulianDate(RtlRealArg(Args,1)))
  else if Op = 'fromjulian' then V := LfpReal(DateUtils.JulianDateToDateTime(RtlRealArg(Args,1)))
  else if Op = 'modifiedjulian' then V := LfpReal(DateUtils.DateTimeToModifiedJulianDate(RtlRealArg(Args,1)))
  else if Op = 'frommodifiedjulian' then V := LfpReal(DateUtils.ModifiedJulianDateToDateTime(RtlRealArg(Args,1)))

  else if Op = 'ishexdigit' then begin S:=UpperCase(RtlStringArg(Args,1)); V:=LfpBool((S<>'') and (S[1] in ['0'..'9','A'..'F'])); end
  else if Op = 'ispunctuation' then begin S:=RtlStringArg(Args,1); V:=LfpBool((S<>'') and (S[1] in ['!'..'/',':'..'@','['..'`','{'..'~'])); end
  else if Op = 'issymbol' then begin S:=RtlStringArg(Args,1); V:=LfpBool((S<>'') and (S[1] in ['#','$','+','<','=','>','^','`','|','~'])); end


  else if Op = 'ansiout' then begin S:=RtlStringArg(Args,1); Write(S); V:=LfpNil; end
  else if Op = 'clrscr' then begin Crt.ClrScr; V:=LfpNil; end
  else if Op = 'clreol' then begin Crt.ClrEol; V:=LfpNil; end
  else if Op = 'normvideo' then begin Crt.NormVideo; V:=LfpNil; end
  else if Op = 'lowvideo' then begin Crt.LowVideo; V:=LfpNil; end
  else if Op = 'highvideo' then begin Crt.HighVideo; V:=LfpNil; end
  else if Op = 'gotoxy' then begin Crt.GotoXY(Byte(RtlIntArg(Args,1)), Byte(RtlIntArg(Args,2))); V:=LfpNil; end
  else if Op = 'textcolor' then begin Crt.TextColor(Byte(RtlIntArg(Args,1))); V:=LfpNil; end
  else if Op = 'textbackground' then begin Crt.TextBackground(Byte(RtlIntArg(Args,1))); V:=LfpNil; end
  else if Op = 'beepfreq' then begin Crt.Sound(Word(RtlIntArg(Args,1))); V:=LfpNil; end
  else if Op = 'nosound' then begin Crt.NoSound; V:=LfpNil; end
  else if Op = 'wherex' then V:=LfpInt(Crt.WhereX)
  else if Op = 'wherey' then V:=LfpInt(Crt.WhereY)
  else if Op = 'keypressed' then V:=LfpBool(Crt.KeyPressed)
  else if Op = 'readkey' then begin S:=Crt.ReadKey; V:=LfpString(UTF8Decode(S)); end

  else
  begin
    Result := False;
    V := LfpNil;
  end;
end;

function RtlGetOptArgv(Engine: TLfpEngine): TLfpArrayObject;
var
  V: TLfpValue;
begin
  Result := nil;
  if not Engine.HasGlobal('argv') then Exit;
  V := Engine.GetGlobal('argv');
  if (V.Kind = vkObject) and (V.ObjValue is TLfpArrayObject) then
    Result := TLfpArrayObject(V.ObjValue);
end;

function RtlGetOptArgCount(Engine: TLfpEngine): LongInt;
var
  A: TLfpArrayObject;
begin
  A := RtlGetOptArgv(Engine);
  if Assigned(A) then Result := A.Length else Result := 0;
end;

function RtlGetOptArg(Engine: TLfpEngine; Index: LongInt): UnicodeString;
var
  A: TLfpArrayObject;
begin
  Result := '';
  if Index <= 0 then Exit;
  A := RtlGetOptArgv(Engine);
  if not Assigned(A) then Exit;
  if Index > A.Length then Exit;
  Result := LfpValueAsString(A.GetItem(A.LowerBound + Index - 1));
end;

procedure RtlSetGetOptArg(Engine: TLfpEngine; Index: LongInt;
  const Value: UnicodeString);
var
  A: TLfpArrayObject;
begin
  if Index <= 0 then Exit;
  A := RtlGetOptArgv(Engine);
  if not Assigned(A) or (Index > A.Length) then Exit;
  A.SetItem(A.LowerBound + Index - 1, LfpString(Value));
end;

procedure RtlGetOptSetGlobal(Engine: TLfpEngine; const Name: string;
  const Value: TLfpValue);
begin
  if Engine.HasGlobal(Name) then Engine.SetGlobal(Name, Value);
end;

function RtlGetOptGlobalInt(Engine: TLfpEngine; const Name: string;
  DefaultValue: Int64): Int64;
begin
  if Engine.HasGlobal(Name) then Result := LfpToInt(Engine.GetGlobal(Name))
  else Result := DefaultValue;
end;

function RtlGetOptGlobalBool(Engine: TLfpEngine; const Name: string;
  DefaultValue: Boolean): Boolean;
begin
  if Engine.HasGlobal(Name) then Result := LfpTruthy(Engine.GetGlobal(Name))
  else Result := DefaultValue;
end;

procedure RtlGetOptExchange(Engine: TLfpEngine; OptInd: LongInt);
var
  Bottom, Middle, Top, I, L: LongInt;
  Temp: UnicodeString;
begin
  Bottom := Engine.FGetOptFirstNonOpt;
  Middle := Engine.FGetOptLastNonOpt;
  Top := OptInd;
  while (Top > Middle) and (Middle > Bottom) do
  begin
    if Top - Middle > Middle - Bottom then
    begin
      L := Middle - Bottom;
      for I := 0 to L - 1 do
      begin
        Temp := RtlGetOptArg(Engine, Bottom + I);
        RtlSetGetOptArg(Engine, Bottom + I,
          RtlGetOptArg(Engine, Top - (Middle - Bottom) + I));
        RtlSetGetOptArg(Engine, Top - (Middle - Bottom) + I, Temp);
      end;
      Dec(Top, L);
    end
    else
    begin
      L := Top - Middle;
      for I := 0 to L - 1 do
      begin
        Temp := RtlGetOptArg(Engine, Bottom + I);
        RtlSetGetOptArg(Engine, Bottom + I, RtlGetOptArg(Engine, Middle + I));
        RtlSetGetOptArg(Engine, Middle + I, Temp);
      end;
      Inc(Bottom, L);
    end;
  end;
  Engine.FGetOptFirstNonOpt := Engine.FGetOptFirstNonOpt +
    OptInd - Engine.FGetOptLastNonOpt;
  Engine.FGetOptLastNonOpt := OptInd;
end;

procedure RtlGetOptInit(Engine: TLfpEngine; var OptString: UnicodeString);
var
  C: WideChar;
begin
  RtlGetOptSetGlobal(Engine, 'OptArg', LfpString(''));
  RtlGetOptSetGlobal(Engine, 'OptInd', LfpInt(1));
  RtlGetOptSetGlobal(Engine, 'OptOpt', LfpChar('?'));
  Engine.FGetOptFirstNonOpt := 1;
  Engine.FGetOptLastNonOpt := 1;
  Engine.FGetOptNextChar := 0;
  Engine.FGetOptOrdering := 1;
  if OptString = '' then Exit;
  C := OptString[1];
  if C = '-' then
  begin
    Engine.FGetOptOrdering := 2;
    Delete(OptString, 1, 1);
  end
  else if C = '+' then
  begin
    Engine.FGetOptOrdering := 0;
    Delete(OptString, 1, 1);
  end;
end;

function RtlGetOptRecordField(R: TLfpRecordObject; const Name: string): TLfpValue;
begin
  if not R.HasField(Name) then
    raise ELfpRuntimeError.Create('GetOpts.TOption is missing field ' + Name);
  Result := R.GetField(Name);
end;

function RtlGetOptInternal(Engine: TLfpEngine; OptString: UnicodeString;
  LongOpts: TLfpArrayObject; LongInd: TLfpPointerObject): WideChar;
var
  OptInd, NrArgs, EndOpt, Temp, OptionIndex, IndFound, I: LongInt;
  CurrentArg, OptName, Name, ArgValue: UnicodeString;
  C, ReturnChar: WideChar;
  Found, Exact, Ambig: Boolean;
  FoundRecord, R: TLfpRecordObject;
  HasArg: Int64;
  V, FlagV, ValueV: TLfpValue;
begin
  RtlGetOptSetGlobal(Engine, 'OptArg', LfpString(''));
  OptInd := RtlGetOptGlobalInt(Engine, 'OptInd', 0);
  if OptInd = 0 then
  begin
    RtlGetOptInit(Engine, OptString);
    OptInd := 1;
  end;
  NrArgs := RtlGetOptArgCount(Engine) + 1;
  CurrentArg := RtlGetOptArg(Engine, OptInd);

  if Engine.FGetOptNextChar = 0 then
  begin
    if Engine.FGetOptOrdering = 1 then
    begin
      if (Engine.FGetOptFirstNonOpt <> Engine.FGetOptLastNonOpt) and
         (Engine.FGetOptLastNonOpt <> OptInd) then
        RtlGetOptExchange(Engine, OptInd)
      else if Engine.FGetOptLastNonOpt <> OptInd then
        Engine.FGetOptFirstNonOpt := OptInd;
      while (OptInd < NrArgs) and
            ((CurrentArg = '') or (CurrentArg[1] <> '-') or (Length(CurrentArg) = 1)) do
      begin
        Inc(OptInd);
        CurrentArg := RtlGetOptArg(Engine, OptInd);
      end;
      Engine.FGetOptLastNonOpt := OptInd;
    end;

    CurrentArg := RtlGetOptArg(Engine, OptInd);
    if (OptInd <> NrArgs) and (CurrentArg = '--') then
    begin
      Inc(OptInd);
      if (Engine.FGetOptFirstNonOpt <> Engine.FGetOptLastNonOpt) and
         (Engine.FGetOptLastNonOpt <> OptInd) then
        RtlGetOptExchange(Engine, OptInd)
      else if Engine.FGetOptFirstNonOpt = Engine.FGetOptLastNonOpt then
        Engine.FGetOptFirstNonOpt := OptInd;
      Engine.FGetOptLastNonOpt := NrArgs;
      OptInd := NrArgs;
    end;

    if OptInd >= NrArgs then
    begin
      if Engine.FGetOptFirstNonOpt <> Engine.FGetOptLastNonOpt then
        OptInd := Engine.FGetOptFirstNonOpt;
      RtlGetOptSetGlobal(Engine, 'OptInd', LfpInt(OptInd));
      Exit(WideChar(255));
    end;

    CurrentArg := RtlGetOptArg(Engine, OptInd);
    if (CurrentArg = '') or (CurrentArg[1] <> '-') or (Length(CurrentArg) = 1) then
    begin
      if Engine.FGetOptOrdering = 0 then
      begin
        RtlGetOptSetGlobal(Engine, 'OptInd', LfpInt(OptInd));
        Exit(WideChar(255));
      end;
      RtlGetOptSetGlobal(Engine, 'OptArg', LfpString(CurrentArg));
      Inc(OptInd);
      RtlGetOptSetGlobal(Engine, 'OptInd', LfpInt(OptInd));
      Exit(#0);
    end;

    Engine.FGetOptNextChar := 2;
    if Assigned(LongOpts) and (Length(CurrentArg) > 1) and
       (CurrentArg[1] = '-') and (CurrentArg[2] = '-') then
      Inc(Engine.FGetOptNextChar);
  end;

  CurrentArg := RtlGetOptArg(Engine, OptInd);
  if Assigned(LongOpts) then
  begin
    EndOpt := Pos('=', CurrentArg);
    if EndOpt = 0 then EndOpt := Length(CurrentArg) + 1;
    OptName := Copy(CurrentArg, Engine.FGetOptNextChar,
      EndOpt - Engine.FGetOptNextChar);
    Found := False;
    Exact := False;
    Ambig := False;
    FoundRecord := nil;
    IndFound := 0;
    OptionIndex := 0;
    for I := 0 to LongOpts.Length - 1 do
    begin
      V := LongOpts.GetItem(LongOpts.LowerBound + I);
      if (V.Kind <> vkObject) or not (V.ObjValue is TLfpRecordObject) then
        raise ELfpRuntimeError.Create('GetLongOpts expects an array of TOption records');
      R := TLfpRecordObject(V.ObjValue);
      Name := LfpValueAsString(RtlGetOptRecordField(R, 'Name'));
      if Name = '' then Break;
      if Pos(OptName, Name) <> 0 then
      begin
        if Length(OptName) = Length(Name) then
        begin
          Found := True;
          Exact := True;
          FoundRecord := R;
          IndFound := OptionIndex;
          Break;
        end
        else if not Found then
        begin
          Found := True;
          FoundRecord := R;
          IndFound := OptionIndex;
        end
        else
          Ambig := True;
      end;
      Inc(OptionIndex);
    end;

    if Ambig and not Exact then
    begin
      if RtlGetOptGlobalBool(Engine, 'OptErr', True) then
        WriteLn('lfp: option "', UTF8Encode(OptName), '" is ambiguous');
      Engine.FGetOptNextChar := 0;
      Inc(OptInd);
      RtlGetOptSetGlobal(Engine, 'OptInd', LfpInt(OptInd));
      Exit('?');
    end;

    if Found and Assigned(FoundRecord) then
    begin
      Inc(OptInd);
      HasArg := LfpToInt(RtlGetOptRecordField(FoundRecord, 'Has_arg'));
      if EndOpt <= Length(CurrentArg) then
      begin
        if HasArg > 0 then
          RtlGetOptSetGlobal(Engine, 'OptArg',
            LfpString(Copy(CurrentArg, EndOpt + 1, Length(CurrentArg) - EndOpt)))
        else
        begin
          if RtlGetOptGlobalBool(Engine, 'OptErr', True) then
            WriteLn('lfp: option "', UTF8Encode(Name), '" does not allow an argument');
          Engine.FGetOptNextChar := 0;
          RtlGetOptSetGlobal(Engine, 'OptInd', LfpInt(OptInd));
          Exit('?');
        end;
      end
      else if HasArg = 1 then
      begin
        if OptInd < NrArgs then
        begin
          RtlGetOptSetGlobal(Engine, 'OptArg', LfpString(RtlGetOptArg(Engine, OptInd)));
          Inc(OptInd);
        end
        else
        begin
          if RtlGetOptGlobalBool(Engine, 'OptErr', True) then
            WriteLn('lfp: option ', UTF8Encode(Name), ' requires an argument');
          Engine.FGetOptNextChar := 0;
          RtlGetOptSetGlobal(Engine, 'OptInd', LfpInt(OptInd));
          if (OptString <> '') and (OptString[1] = ':') then Exit(':') else Exit('?');
        end;
      end;
      Engine.FGetOptNextChar := 0;
      RtlGetOptSetGlobal(Engine, 'OptInd', LfpInt(OptInd));
      if Assigned(LongInd) then LongInd.Assign(LfpInt(IndFound + 1));
      FlagV := RtlGetOptRecordField(FoundRecord, 'Flag');
      ValueV := RtlGetOptRecordField(FoundRecord, 'Value');
      if (FlagV.Kind = vkObject) and (FlagV.ObjValue is TLfpPointerObject) then
      begin
        TLfpPointerObject(FlagV.ObjValue).Assign(ValueV);
        Exit(#0);
      end;
      if (ValueV.Kind <> vkChar) or (ValueV.StrValue = '') then
        raise ELfpRuntimeError.Create('GetOpts.TOption Value must be a Char');
      Exit(ValueV.StrValue[1]);
    end;

    if ((Length(CurrentArg) > 1) and (CurrentArg[2] = '-')) or
       (Pos(CurrentArg[Engine.FGetOptNextChar], OptString) = 0) then
    begin
      if RtlGetOptGlobalBool(Engine, 'OptErr', True) then
        WriteLn('lfp: unrecognized option "', UTF8Encode(CurrentArg), '"');
      Engine.FGetOptNextChar := 0;
      Inc(OptInd);
      RtlGetOptSetGlobal(Engine, 'OptInd', LfpInt(OptInd));
      Exit('?');
    end;
  end;

  if (Engine.FGetOptNextChar <= 0) or
     (Engine.FGetOptNextChar > Length(CurrentArg)) then
  begin
    Engine.FGetOptNextChar := 0;
    Inc(OptInd);
    RtlGetOptSetGlobal(Engine, 'OptInd', LfpInt(OptInd));
    Exit('?');
  end;

  C := CurrentArg[Engine.FGetOptNextChar];
  Temp := Pos(C, OptString);
  Inc(Engine.FGetOptNextChar);
  if Engine.FGetOptNextChar > Length(CurrentArg) then
  begin
    Inc(OptInd);
    Engine.FGetOptNextChar := 0;
  end;

  if (Temp = 0) or (C = ':') then
  begin
    if RtlGetOptGlobalBool(Engine, 'OptErr', True) then
      WriteLn('lfp: illegal option -- ', UTF8Encode(UnicodeString(C)));
    RtlGetOptSetGlobal(Engine, 'OptOpt', LfpChar(C));
    RtlGetOptSetGlobal(Engine, 'OptInd', LfpInt(OptInd));
    Exit('?');
  end;

  ReturnChar := OptString[Temp];
  if (Length(OptString) > Temp) and (OptString[Temp + 1] = ':') then
  begin
    if (Length(OptString) > Temp + 1) and (OptString[Temp + 2] = ':') then
    begin
      if Engine.FGetOptNextChar > 0 then
      begin
        RtlGetOptSetGlobal(Engine, 'OptArg',
          LfpString(Copy(CurrentArg, Engine.FGetOptNextChar,
            Length(CurrentArg) - Engine.FGetOptNextChar + 1)));
        Inc(OptInd);
        Engine.FGetOptNextChar := 0;
      end
      else if OptInd <> NrArgs then
      begin
        ArgValue := RtlGetOptArg(Engine, OptInd);
        if (ArgValue <> '') and (ArgValue[1] = '-') then ArgValue := ''
        else Inc(OptInd);
        RtlGetOptSetGlobal(Engine, 'OptArg', LfpString(ArgValue));
        Engine.FGetOptNextChar := 0;
      end;
    end
    else
    begin
      if Engine.FGetOptNextChar > 0 then
      begin
        RtlGetOptSetGlobal(Engine, 'OptArg',
          LfpString(Copy(CurrentArg, Engine.FGetOptNextChar,
            Length(CurrentArg) - Engine.FGetOptNextChar + 1)));
        Inc(OptInd);
      end
      else if OptInd = NrArgs then
      begin
        if RtlGetOptGlobalBool(Engine, 'OptErr', True) then
          WriteLn('lfp: option requires an argument -- ', UTF8Encode(ReturnChar));
        RtlGetOptSetGlobal(Engine, 'OptOpt', LfpChar(ReturnChar));
        if (OptString <> '') and (OptString[1] = ':') then ReturnChar := ':'
        else ReturnChar := '?';
      end
      else
      begin
        RtlGetOptSetGlobal(Engine, 'OptArg', LfpString(RtlGetOptArg(Engine, OptInd)));
        Inc(OptInd);
      end;
      Engine.FGetOptNextChar := 0;
    end;
  end;

  RtlGetOptSetGlobal(Engine, 'OptInd', LfpInt(OptInd));
  Result := ReturnChar;
end;


function RtlHttpEncode(const S: UnicodeString): UnicodeString;
const
  Allowed: set of Char = ['A'..'Z', 'a'..'z', '*', '@', '.', '_', '-',
    '0'..'9', '$', '!', '''', '(', ')'];
var
  U, O: RawByteString;
  I: Integer;
  C: Char;
begin
  U := UTF8Encode(S);
  O := '';
  for I := 1 to Length(U) do
  begin
    C := U[I];
    if C in Allowed then
      O := O + C
    else if C = ' ' then
      O := O + '+'
    else
      O := O + '%' + RtlUriHex(Ord(C) shr 4) + RtlUriHex(Ord(C) and 15);
  end;
  Result := UTF8Decode(O);
end;

function RtlHttpDecode(const S: UnicodeString): UnicodeString;
var
  U, O: RawByteString;
  I, H1, H2: Integer;
begin
  U := UTF8Encode(S);
  O := '';
  I := 1;
  while I <= Length(U) do
  begin
    if U[I] = '+' then
    begin
      O := O + ' ';
      Inc(I);
    end
    else if U[I] = '%' then
    begin
      if (I < Length(U)) and (U[I + 1] = '%') then
      begin
        O := O + '%';
        Inc(I, 2);
      end
      else if I + 2 <= Length(U) then
      begin
        H1 := RtlUriHexValue(U[I + 1]);
        H2 := RtlUriHexValue(U[I + 2]);
        if (H1 >= 0) and (H2 >= 0) then
          O := O + Char((H1 shl 4) or H2)
        else
          O := O + ' ';
        Inc(I, 3);
      end
      else
      begin
        O := O + ' ';
        Inc(I);
      end;
    end
    else
    begin
      O := O + U[I];
      Inc(I);
    end;
  end;
  Result := UTF8Decode(O);
end;

function RtlHttpHeaderName(Index: Int64): UnicodeString;
const
  Names: array[0..47] of string = (
    '', 'Accept', 'Accept-Charset', 'Accept-Encoding', 'Accept-Language',
    'Accept-Ranges', 'Age', 'Allow', 'Authorization', 'Cache-Control',
    'Connection', 'Content-Encoding', 'Content-Language', 'Content-Length',
    'Content-Location', 'Content-MD5', 'Content-Range', 'Content-Type', 'Date',
    'ETag', 'Expires', 'Expect', 'From', 'Host', 'If-Match',
    'If-Modified-Since', 'If-None-Match', 'If-Range', 'If-Unmodified-Since',
    'Last-Modified', 'Location', 'Max-Forwards', 'Pragma',
    'Proxy-Authenticate', 'Proxy-Authorization', 'Range', 'Referer',
    'Retry-After', 'Server', 'TE', 'Trailer', 'Transfer-Encoding', 'Upgrade',
    'User-Agent', 'Vary', 'Via', 'Warning', 'WWW-Authenticate');
begin
  if (Index < Low(Names)) or (Index > High(Names)) then Exit('');
  Result := UTF8Decode(Names[Index]);
end;

procedure RtlHeapTraceWrite(Engine: TLfpEngine; const Text: string);
var
  F: TextFile;
begin
  if Engine.FHeapTraceOutput = '' then
    WriteLn(StdErr, Text)
  else
  begin
    AssignFile(F, Engine.FHeapTraceOutput);
    if FileExists(Engine.FHeapTraceOutput) then Append(F) else Rewrite(F);
    try
      WriteLn(F, Text);
    finally
      CloseFile(F);
    end;
  end;
end;

procedure RtlHeapTraceDump(Engine: TLfpEngine);
var
  I, PointerCount, AliveCount, DisposedCount: Integer;
  O: TObject;
begin
  PointerCount := 0;
  AliveCount := 0;
  DisposedCount := 0;
  for I := 0 to Engine.FHeap.Count - 1 do
  begin
    O := Engine.FHeap[I];
    if O is TLfpPointerObject then
    begin
      Inc(PointerCount);
      if TLfpPointerObject(O).Alive then Inc(AliveCount) else Inc(DisposedCount);
    end;
  end;
  RtlHeapTraceWrite(Engine, Format(
    'Heap dump: managed objects=%d, pointers=%d, alive=%d, disposed=%d',
    [Engine.FHeap.Count, PointerCount, AliveCount, DisposedCount]));
end;

function NativeRtl(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
const
  UnicodeCategoryNames: array[0..29] of string = (
    'ucUppercaseLetter', 'ucLowercaseLetter', 'ucTitlecaseLetter',
    'ucModifierLetter', 'ucOtherLetter', 'ucNonSpacingMark',
    'ucCombiningMark', 'ucEnclosingMark', 'ucDecimalNumber',
    'ucLetterNumber', 'ucOtherNumber', 'ucConnectPunctuation',
    'ucDashPunctuation', 'ucOpenPunctuation', 'ucClosePunctuation',
    'ucInitialPunctuation', 'ucFinalPunctuation', 'ucOtherPunctuation',
    'ucMathSymbol', 'ucCurrencySymbol', 'ucModifierSymbol', 'ucOtherSymbol',
    'ucSpaceSeparator', 'ucLineSeparator', 'ucParagraphSeparator',
    'ucControl', 'ucFormat', 'ucSurrogate', 'ucPrivateUse', 'ucUnassigned');
  HttpHeaderMemberNames: array[0..47] of string = (
    'hhUnknown', 'hhAccept', 'hhAcceptCharset', 'hhAcceptEncoding',
    'hhAcceptLanguage', 'hhAcceptRanges', 'hhAge', 'hhAllow',
    'hhAuthorization', 'hhCacheControl', 'hhConnection', 'hhContentEncoding',
    'hhContentLanguage', 'hhContentLength', 'hhContentLocation', 'hhContentMD5',
    'hhContentRange', 'hhContentType', 'hhDate', 'hhETag', 'hhExpires',
    'hhExpect', 'hhFrom', 'hhHost', 'hhIfMatch', 'hhIfModifiedSince',
    'hhIfNoneMatch', 'hhIfRange', 'hhIfUnModifiedSince', 'hhLastModified',
    'hhLocation', 'hhMaxForwards', 'hhPragma', 'hhProxyAuthenticate',
    'hhProxyAuthorization', 'hhRange', 'hhReferer', 'hhRetryAfter', 'hhServer',
    'hhTE', 'hhTrailer', 'hhTransferEncoding', 'hhUpgrade', 'hhUserAgent',
    'hhVary', 'hhVia', 'hhWarning', 'hhWWWAuthenticate');
var
  Op, A, B, S: string;
  U: UnicodeString;
  I, J: Int64;
  R, R2: Double;
  Arr: TLfpArrayObject;
  FS: TFileStream;
  SL: TStringList;
  Ch, Ch2: WideChar;
  Fmt: TFormatSettings;
begin
  if Length(Args) < 1 then raise ELfpRuntimeError.Create('__rtl expects an operation');
  Op := LowerCase(RtlStringArg(Args, 0));
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';

  if Op = 'http_encode' then Exit(LfpString(RtlHttpEncode(LfpValueAsString(Args[1]))));
  if Op = 'http_decode' then Exit(LfpString(RtlHttpDecode(LfpValueAsString(Args[1]))));
  if Op = 'http_headername' then Exit(LfpString(RtlHttpHeaderName(RtlIntArg(Args, 1))));
  if Op = 'http_headertype' then
  begin
    A := RtlStringArg(Args, 1);
    I := 47;
    while (I > 0) and not SameText(UTF8Encode(RtlHttpHeaderName(I)), A) do Dec(I);
    Exit(LfpObject(Engine.OwnObject(TLfpEnumValueObject.Create(
      'THeader', HttpHeaderMemberNames[I], I))));
  end;
  if Op = 'base64_encode' then Exit(LfpString(RtlBase64Encode(LfpValueAsString(Args[1]))));
  if Op = 'base64_decode' then Exit(LfpString(RtlBase64Decode(LfpValueAsString(Args[1]), RtlBoolArg(Args, 2))));
  if Op = 'uri_parse' then Exit(RtlUriRecord(Engine, LfpValueAsString(Args[1]), RtlBoolArg(Args, 2), '', 0));
  if Op = 'uri_encode' then Exit(LfpString(RtlUriEncodeRecord(Args[1])));
  if Op = 'uri_filename' then Exit(LfpString(RtlFilenameToUri(LfpValueAsString(Args[1]), RtlBoolArg(Args, 2))));
  if Op = 'uri_isabsolute' then begin A := RtlStringArg(Args, 1); I := Pos(':', A); if I <= 1 then Exit(LfpBool(False)); Exit(LfpBool(RtlUriIsScheme(Copy(A, 1, I - 1)))); end;
  if Op = 'heaptrc_checkpointer' then
  begin
    if (Args[1].Kind <> vkObject) or not (Args[1].ObjValue is TLfpPointerObject) then
      raise ELfpRuntimeError.Create('invalid pointer');
    if not TLfpPointerObject(Args[1].ObjValue).Alive then
      raise ELfpRuntimeError.Create('invalid or disposed pointer');
    Exit(LfpNil);
  end;
  if Op = 'heaptrc_dumpheap' then begin RtlHeapTraceDump(Engine); Exit(LfpNil); end;
  if Op = 'heaptrc_setoutput' then begin Engine.FHeapTraceOutput := RtlStringArg(Args, 1); Exit(LfpNil); end;
  if Op = 'getopts_getopt' then Exit(LfpChar(RtlGetOptInternal(
    Engine, LfpValueAsString(Args[1]), nil, nil)));
  if Op = 'getopts_getlongopts' then
  begin
    if (Args[2].Kind <> vkObject) or not (Args[2].ObjValue is TLfpArrayObject) then
      raise ELfpRuntimeError.Create('GetLongOpts expects an array of TOption records');
    if (Args[3].Kind <> vkObject) or not (Args[3].ObjValue is TLfpPointerObject) then
      raise ELfpRuntimeError.Create('GetLongOpts expects LongInd as a pointer cell');
    Exit(LfpChar(RtlGetOptInternal(Engine, LfpValueAsString(Args[1]),
      TLfpArrayObject(Args[2].ObjValue), TLfpPointerObject(Args[3].ObjValue))));
  end;
  if Op = 'comparestr' then Exit(LfpInt(RtlCompare(RtlStringArg(Args, 1), RtlStringArg(Args, 2))));
  if Op = 'comparetext' then Exit(LfpInt(RtlCompare(LowerCase(RtlStringArg(Args, 1)), LowerCase(RtlStringArg(Args, 2)))));
  if Op = 'trim' then Exit(LfpString(UTF8Decode(Trim(RtlStringArg(Args, 1)))));
  if Op = 'trimleft' then Exit(LfpString(UTF8Decode(TrimLeft(RtlStringArg(Args, 1)))));
  if Op = 'trimright' then Exit(LfpString(UTF8Decode(TrimRight(RtlStringArg(Args, 1)))));
  if Op = 'uppercase' then Exit(LfpString(UTF8Decode(UpperCase(RtlStringArg(Args, 1)))));
  if Op = 'lowercase' then Exit(LfpString(UTF8Decode(LowerCase(RtlStringArg(Args, 1)))));
  if Op = 'quotedstr' then Exit(LfpString(UTF8Decode(QuotedStr(RtlStringArg(Args, 1)))));
  if Op = 'dequotedstr' then Exit(LfpString(UTF8Decode(AnsiDequotedStr(RtlStringArg(Args, 1), ''''))));
  if Op = 'containsstr' then Exit(LfpBool(Pos(RtlStringArg(Args, 2), RtlStringArg(Args, 1)) > 0));
  if Op = 'containstext' then Exit(LfpBool(Pos(LowerCase(RtlStringArg(Args, 2)), LowerCase(RtlStringArg(Args, 1))) > 0));
  if Op = 'startsstr' then begin A := RtlStringArg(Args, 1); B := RtlStringArg(Args, 2); Exit(LfpBool(Copy(B, 1, Length(A)) = A)); end;
  if Op = 'startstext' then begin A := LowerCase(RtlStringArg(Args, 1)); B := LowerCase(RtlStringArg(Args, 2)); Exit(LfpBool(Copy(B, 1, Length(A)) = A)); end;
  if Op = 'endsstr' then begin A := RtlStringArg(Args, 1); B := RtlStringArg(Args, 2); Exit(LfpBool((Length(A) <= Length(B)) and (Copy(B, Length(B)-Length(A)+1, Length(A)) = A))); end;
  if Op = 'endstext' then begin A := LowerCase(RtlStringArg(Args, 1)); B := LowerCase(RtlStringArg(Args, 2)); Exit(LfpBool((Length(A) <= Length(B)) and (Copy(B, Length(B)-Length(A)+1, Length(A)) = A))); end;
  if Op = 'replacestr' then Exit(LfpString(UTF8Decode(StringReplace(RtlStringArg(Args, 1), RtlStringArg(Args, 2), RtlStringArg(Args, 3), [rfReplaceAll]))));
  if Op = 'replacetext' then Exit(LfpString(UTF8Decode(StringReplace(RtlStringArg(Args, 1), RtlStringArg(Args, 2), RtlStringArg(Args, 3), [rfReplaceAll, rfIgnoreCase]))));
  if Op = 'reverse' then Exit(LfpString(RtlReverse(LfpValueAsString(Args[1]))));
  if Op = 'dupestring' then Exit(LfpString(UTF8Decode(DupeString(RtlStringArg(Args, 1), RtlIntArg(Args, 2)))));
  if Op = 'leftstr' then Exit(LfpString(Copy(LfpValueAsString(Args[1]), 1, RtlIntArg(Args, 2))));
  if Op = 'rightstr' then begin S := RtlStringArg(Args, 1); I := RtlIntArg(Args, 2); if I < 0 then I := 0; if I > Length(S) then I := Length(S); Exit(LfpString(UTF8Decode(Copy(S, Length(S)-I+1, I)))); end;
  if Op = 'midstr' then Exit(LfpString(Copy(LfpValueAsString(Args[1]), RtlIntArg(Args, 2), RtlIntArg(Args, 3))));
  if Op = 'posex' then begin A := RtlStringArg(Args, 1); B := RtlStringArg(Args, 2); I := RtlIntArg(Args, 3); if I < 1 then I := 1; J := Pos(A, Copy(B, I, MaxInt)); if J > 0 then J := J + I - 1; Exit(LfpInt(J)); end;
  if Op = 'rpos' then Exit(LfpInt(RtlLastPos(LfpValueAsString(Args[1]), LfpValueAsString(Args[2]), Length(LfpValueAsString(Args[2])))));
  if Op = 'rposex' then Exit(LfpInt(RtlLastPos(LfpValueAsString(Args[1]), LfpValueAsString(Args[2]), RtlIntArg(Args, 3))));
  if Op = 'stringofchar' then begin S := RtlStringArg(Args, 1); if S = '' then Ch := #0 else Ch := UTF8Decode(S)[1]; Exit(LfpString(RtlStringOfChar(Ch, RtlIntArg(Args, 2)))); end;
  if Op = 'padleft' then begin S := RtlStringArg(Args, 1); I := RtlIntArg(Args, 2); if Length(S) < I then S := StringOfChar(' ', I-Length(S)) + S; Exit(LfpString(UTF8Decode(S))); end;
  if Op = 'padright' then begin S := RtlStringArg(Args, 1); I := RtlIntArg(Args, 2); if Length(S) < I then S := S + StringOfChar(' ', I-Length(S)); Exit(LfpString(UTF8Decode(S))); end;
  if Op = 'padcenter' then begin S := RtlStringArg(Args, 1); I := RtlIntArg(Args, 2); if Length(S) < I then begin J := (I-Length(S)) div 2; S := StringOfChar(' ', J) + S + StringOfChar(' ', I-Length(S)-J); end; Exit(LfpString(UTF8Decode(S))); end;
  if Op = 'lastdelimiter' then begin A := RtlStringArg(Args, 1); B := RtlStringArg(Args, 2); J := 0; for I := Length(B) downto 1 do if Pos(B[I], A) > 0 then begin J := I; Break; end; Exit(LfpInt(J)); end;

  if Op = 'inttostr' then Exit(LfpString(UTF8Decode(IntToStr(RtlIntArg(Args, 1)))));
  if Op = 'uinttostr' then Exit(LfpString(UTF8Decode(UIntToStr(QWord(RtlIntArg(Args, 1))))));
  if Op = 'floattostr' then Exit(LfpString(UTF8Decode(FloatToStr(RtlRealArg(Args, 1), Fmt))));
  if Op = 'booltostr' then begin if RtlBoolArg(Args, 1) then S := 'True' else S := 'False'; Exit(LfpString(UTF8Decode(S))); end;
  if Op = 'strtoint' then begin if not TryStrToInt64(RtlStringArg(Args, 1), I) then raise ELfpRuntimeError.Create('invalid integer: ' + RtlStringArg(Args, 1)); Exit(LfpInt(I)); end;
  if Op = 'strtointdef' then begin if not TryStrToInt64(RtlStringArg(Args, 1), I) then I := RtlIntArg(Args, 2); Exit(LfpInt(I)); end;
  if Op = 'strtofloat' then begin if not TryStrToFloat(RtlStringArg(Args, 1), R, Fmt) then raise ELfpRuntimeError.Create('invalid float: ' + RtlStringArg(Args, 1)); Exit(LfpReal(R)); end;
  if Op = 'strtofloatdef' then begin if not TryStrToFloat(RtlStringArg(Args, 1), R, Fmt) then R := RtlRealArg(Args, 2); Exit(LfpReal(R)); end;
  if Op = 'strtobool' then begin A := LowerCase(Trim(RtlStringArg(Args, 1))); if (A='true') or (A='1') or (A='yes') or (A='on') then Exit(LfpBool(True)); if (A='false') or (A='0') or (A='no') or (A='off') then Exit(LfpBool(False)); raise ELfpRuntimeError.Create('invalid boolean: ' + A); end;
  if Op = 'formatfloat' then Exit(LfpString(UTF8Decode(FormatFloat(RtlStringArg(Args, 1), RtlRealArg(Args, 2), Fmt))));

  if Op = 'fileexists' then Exit(LfpBool(FileExists(RtlStringArg(Args, 1))));
  if Op = 'directoryexists' then Exit(LfpBool(DirectoryExists(RtlStringArg(Args, 1))));
  if Op = 'createdir' then Exit(LfpBool(CreateDir(RtlStringArg(Args, 1))));
  if Op = 'forcedirectories' then Exit(LfpBool(ForceDirectories(RtlStringArg(Args, 1))));
  if Op = 'removedir' then Exit(LfpBool(RemoveDir(RtlStringArg(Args, 1))));
  if Op = 'deletefile' then Exit(LfpBool(DeleteFile(RtlStringArg(Args, 1))));
  if Op = 'renamefile' then Exit(LfpBool(RenameFile(RtlStringArg(Args, 1), RtlStringArg(Args, 2))));
  if Op = 'filesize' then begin FS := TFileStream.Create(RtlStringArg(Args, 1), fmOpenRead or fmShareDenyNone); try Exit(LfpInt(FS.Size)); finally FS.Free; end; end;
  if Op = 'getfileasstring' then begin SL := TStringList.Create; try SL.LoadFromFile(RtlStringArg(Args, 1)); Exit(LfpString(UTF8Decode(SL.Text))); finally SL.Free; end; end;
  if Op = 'expandfilename' then Exit(LfpString(UTF8Decode(ExpandFileName(RtlStringArg(Args, 1)))));
  if Op = 'extractfilepath' then Exit(LfpString(UTF8Decode(ExtractFilePath(RtlStringArg(Args, 1)))));
  if Op = 'extractfiledir' then Exit(LfpString(UTF8Decode(ExtractFileDir(RtlStringArg(Args, 1)))));
  if Op = 'extractfilename' then Exit(LfpString(UTF8Decode(ExtractFileName(RtlStringArg(Args, 1)))));
  if Op = 'extractfileext' then Exit(LfpString(UTF8Decode(ExtractFileExt(RtlStringArg(Args, 1)))));
  if Op = 'changefileext' then Exit(LfpString(UTF8Decode(ChangeFileExt(RtlStringArg(Args, 1), RtlStringArg(Args, 2)))));
  if Op = 'includetrailingpathdelimiter' then Exit(LfpString(UTF8Decode(IncludeTrailingPathDelimiter(RtlStringArg(Args, 1)))));
  if Op = 'excludetrailingpathdelimiter' then Exit(LfpString(UTF8Decode(ExcludeTrailingPathDelimiter(RtlStringArg(Args, 1)))));
  if Op = 'getcurrentdir' then Exit(LfpString(UTF8Decode(GetCurrentDir)));
  if Op = 'setcurrentdir' then Exit(LfpBool(SetCurrentDir(RtlStringArg(Args, 1))));
  if Op = 'gettempdir' then Exit(LfpString(UTF8Decode(GetTempDir)));
  if Op = 'getuserdir' then Exit(LfpString(UTF8Decode(GetUserDir)));
  if Op = 'getenvironmentvariable' then Exit(LfpString(UTF8Decode(GetEnvironmentVariable(RtlStringArg(Args, 1)))));
  if Op = 'getenvironmentvariablecount' then Exit(LfpInt(GetEnvironmentVariableCount));
  if Op = 'getenvironmentstring' then Exit(LfpString(UTF8Decode(GetEnvironmentString(RtlIntArg(Args, 1)))));
  if Op = 'filesearch' then Exit(LfpString(UTF8Decode(FileSearch(RtlStringArg(Args, 1), RtlStringArg(Args, 2)))));
  if Op = 'diskfree' then Exit(LfpInt(DiskFree(RtlIntArg(Args, 1))));
  if Op = 'disksize' then Exit(LfpInt(DiskSize(RtlIntArg(Args, 1))));
  if Op = 'sleep' then begin Sleep(RtlIntArg(Args, 1)); Exit(LfpNil); end;
  if Op = 'gettickcount64' then Exit(LfpInt(Int64(GetTickCount64)));
  if Op = 'executeprocess' then Exit(LfpInt(ExecuteProcess(RtlStringArg(Args, 1), RtlStringArg(Args, 2), [])));

  if Op = 'date' then Exit(LfpReal(Date));
  if Op = 'time' then Exit(LfpReal(Time));
  if Op = 'nowdatetime' then Exit(LfpReal(Now));
  if Op = 'currentyear' then Exit(LfpInt(CurrentYear));
  if Op = 'encodedate' then Exit(LfpReal(EncodeDate(RtlIntArg(Args,1), RtlIntArg(Args,2), RtlIntArg(Args,3))));
  if Op = 'encodetime' then Exit(LfpReal(EncodeTime(RtlIntArg(Args,1), RtlIntArg(Args,2), RtlIntArg(Args,3), RtlIntArg(Args,4))));
  if Op = 'encodedatetime' then Exit(LfpReal(EncodeDateTime(RtlIntArg(Args,1), RtlIntArg(Args,2), RtlIntArg(Args,3), RtlIntArg(Args,4), RtlIntArg(Args,5), RtlIntArg(Args,6), RtlIntArg(Args,7))));
  if Op = 'yearof' then Exit(LfpInt(YearOf(RtlRealArg(Args,1))));
  if Op = 'monthof' then Exit(LfpInt(MonthOf(RtlRealArg(Args,1))));
  if Op = 'dayof' then Exit(LfpInt(DayOf(RtlRealArg(Args,1))));
  if Op = 'hourof' then Exit(LfpInt(HourOf(RtlRealArg(Args,1))));
  if Op = 'minuteof' then Exit(LfpInt(MinuteOf(RtlRealArg(Args,1))));
  if Op = 'secondof' then Exit(LfpInt(SecondOf(RtlRealArg(Args,1))));
  if Op = 'millisecondof' then Exit(LfpInt(MilliSecondOf(RtlRealArg(Args,1))));
  if Op = 'dayoftheweek' then Exit(LfpInt(DayOfTheWeek(RtlRealArg(Args,1))));
  if Op = 'dayoftheyear' then Exit(LfpInt(DayOfTheYear(RtlRealArg(Args,1))));
  if Op = 'weekoftheyear' then Exit(LfpInt(WeekOfTheYear(RtlRealArg(Args,1))));
  if Op = 'weekofthemonth' then Exit(LfpInt(WeekOfTheMonth(RtlRealArg(Args,1))));
  if Op = 'daysinamonth' then Exit(LfpInt(DaysInAMonth(RtlIntArg(Args,1), RtlIntArg(Args,2))));
  if Op = 'daysinayear' then Exit(LfpInt(DaysInAYear(RtlIntArg(Args,1))));
  if Op = 'isleapyear' then Exit(LfpBool(IsLeapYear(RtlIntArg(Args,1))));
  if Op = 'dateof' then Exit(LfpReal(DateOf(RtlRealArg(Args,1))));
  if Op = 'timeofday' then Exit(LfpReal(TimeOf(RtlRealArg(Args,1))));
  if Op = 'incday' then Exit(LfpReal(IncDay(RtlRealArg(Args,1), RtlIntArg(Args,2))));
  if Op = 'incweek' then Exit(LfpReal(IncWeek(RtlRealArg(Args,1), RtlIntArg(Args,2))));
  if Op = 'incmonth' then Exit(LfpReal(IncMonth(RtlRealArg(Args,1), RtlIntArg(Args,2))));
  if Op = 'incyear' then Exit(LfpReal(IncYear(RtlRealArg(Args,1), RtlIntArg(Args,2))));
  if Op = 'inchour' then Exit(LfpReal(IncHour(RtlRealArg(Args,1), RtlIntArg(Args,2))));
  if Op = 'incminute' then Exit(LfpReal(IncMinute(RtlRealArg(Args,1), RtlIntArg(Args,2))));
  if Op = 'incsecond' then Exit(LfpReal(IncSecond(RtlRealArg(Args,1), RtlIntArg(Args,2))));
  if Op = 'incmillisecond' then Exit(LfpReal(IncMilliSecond(RtlRealArg(Args,1), RtlIntArg(Args,2))));
  if Op = 'daysbetween' then Exit(LfpInt(DaysBetween(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'weeksbetween' then Exit(LfpInt(WeeksBetween(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'monthsbetween' then Exit(LfpInt(MonthsBetween(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'yearsbetween' then Exit(LfpInt(YearsBetween(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'hoursbetween' then Exit(LfpInt(HoursBetween(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'minutesbetween' then Exit(LfpInt(MinutesBetween(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'secondsbetween' then Exit(LfpInt(SecondsBetween(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'millisecondsbetween' then Exit(LfpInt(MilliSecondsBetween(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'dayspan' then Exit(LfpReal(DaySpan(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'weekspan' then Exit(LfpReal(WeekSpan(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'monthspan' then Exit(LfpReal(MonthSpan(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'yearspan' then Exit(LfpReal(YearSpan(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'hourspan' then Exit(LfpReal(HourSpan(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'minutespan' then Exit(LfpReal(MinuteSpan(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'secondspan' then Exit(LfpReal(SecondSpan(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'millisecondspan' then Exit(LfpReal(MilliSecondSpan(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'datetounix' then Exit(LfpInt(DateTimeToUnix(RtlRealArg(Args,1))));
  if Op = 'unixtodate' then Exit(LfpReal(UnixToDateTime(RtlIntArg(Args,1))));
  if Op = 'localtouniversal' then Exit(LfpReal(DateUtils.LocalTimeToUniversal(RtlRealArg(Args,1))));
  if Op = 'universaltolocal' then Exit(LfpReal(DateUtils.UniversalTimeToLocal(RtlRealArg(Args,1))));
  if Op = 'nowutc' then Exit(LfpReal(DateUtils.LocalTimeToUniversal(Now)));
  if Op = 'datetoiso8601' then Exit(LfpString(UTF8Decode(DateToISO8601(RtlRealArg(Args,1), False))));
  if Op = 'iso8601todate' then Exit(LfpReal(ISO8601ToDate(RtlStringArg(Args,1), False)));
  if Op = 'comparedate' then Exit(LfpInt(CompareDate(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'comparetime' then Exit(LfpInt(CompareTime(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'comparedatetime' then Exit(LfpInt(CompareDateTime(RtlRealArg(Args,1), RtlRealArg(Args,2))));

  if Op = 'arccos' then Exit(LfpReal(Math.ArcCos(RtlRealArg(Args,1))));
  if Op = 'arcsin' then Exit(LfpReal(Math.ArcSin(RtlRealArg(Args,1))));
  if Op = 'arctan2' then Exit(LfpReal(Math.ArcTan2(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'cosh' then Exit(LfpReal(Math.Cosh(RtlRealArg(Args,1))));
  if Op = 'sinh' then Exit(LfpReal(Math.Sinh(RtlRealArg(Args,1))));
  if Op = 'tanh' then Exit(LfpReal(Math.Tanh(RtlRealArg(Args,1))));
  if Op = 'arccosh' then Exit(LfpReal(Math.ArcCosh(RtlRealArg(Args,1))));
  if Op = 'arcsinh' then Exit(LfpReal(Math.ArcSinh(RtlRealArg(Args,1))));
  if Op = 'arctanh' then Exit(LfpReal(Math.ArcTanh(RtlRealArg(Args,1))));
  if Op = 'power' then Exit(LfpReal(Math.Power(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'log10' then Exit(LfpReal(Math.Log10(RtlRealArg(Args,1))));
  if Op = 'log2' then Exit(LfpReal(Math.Log2(RtlRealArg(Args,1))));
  if Op = 'logn' then Exit(LfpReal(Math.LogN(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'floor' then Exit(LfpInt(Math.Floor(RtlRealArg(Args,1))));
  if Op = 'ceil' then Exit(LfpInt(Math.Ceil(RtlRealArg(Args,1))));
  if Op = 'floor64' then Exit(LfpInt(Math.Floor64(RtlRealArg(Args,1))));
  if Op = 'ceil64' then Exit(LfpInt(Math.Ceil64(RtlRealArg(Args,1))));
  if Op = 'frac' then Exit(LfpReal(Frac(RtlRealArg(Args,1))));
  if Op = 'intpart' then Exit(LfpReal(Int(RtlRealArg(Args,1))));
  if Op = 'hypot' then Exit(LfpReal(Math.Hypot(RtlRealArg(Args,1), RtlRealArg(Args,2))));
  if Op = 'degtorad' then Exit(LfpReal(Math.DegToRad(RtlRealArg(Args,1))));
  if Op = 'radtodeg' then Exit(LfpReal(Math.RadToDeg(RtlRealArg(Args,1))));
  if Op = 'sign' then begin R := RtlRealArg(Args,1); if R < 0 then I := -1 else if R > 0 then I := 1 else I := 0; Exit(LfpInt(I)); end;
  if Op = 'infinity' then Exit(LfpReal(Math.Infinity));
  if Op = 'neginfinity' then Exit(LfpReal(-Math.Infinity));
  if Op = 'nan' then Exit(LfpReal(Math.NaN));
  if Op = 'isnan' then Exit(LfpBool(Math.IsNan(RtlRealArg(Args,1))));
  if Op = 'isinfinite' then Exit(LfpBool(Math.IsInfinite(RtlRealArg(Args,1))));
  if Op = 'samevalue' then begin R := RtlRealArg(Args,1); R2 := RtlRealArg(Args,2); if Length(Args) > 3 then Exit(LfpBool(Abs(R-R2) <= Abs(RtlRealArg(Args,3)))) else Exit(LfpBool(SameValue(R,R2))); end;
  if Op = 'iszero' then begin R := RtlRealArg(Args,1); if Length(Args) > 2 then Exit(LfpBool(Abs(R) <= Abs(RtlRealArg(Args,2)))) else Exit(LfpBool(IsZero(R))); end;
  if Op = 'sum' then Exit(RtlArrayStat(Args[1], 'sum'));
  if Op = 'sumsq' then Exit(RtlArrayStat(Args[1], 'sumsq'));
  if Op = 'mean' then Exit(RtlArrayStat(Args[1], 'mean'));
  if Op = 'minvalue' then Exit(RtlArrayStat(Args[1], 'min'));
  if Op = 'maxvalue' then Exit(RtlArrayStat(Args[1], 'max'));
  if Op = 'variance' then Exit(RtlArrayStat(Args[1], 'variance'));
  if Op = 'stddev' then Exit(RtlArrayStat(Args[1], 'stddev'));
  if Op = 'totalvariance' then Exit(RtlArrayStat(Args[1], 'totalvariance'));
  if Op = 'popnvariance' then Exit(RtlArrayStat(Args[1], 'popnvariance'));
  if Op = 'popnstddev' then Exit(RtlArrayStat(Args[1], 'popnstddev'));

  if Copy(Op, 1, 5) = 'math_' then
  begin
    if Op = 'math_clearexceptions' then begin Math.ClearExceptions; Exit(LfpNil); end;
    if Op = 'math_comparevalue' then Exit(LfpInt(Math.CompareValue(RtlRealArg(Args,1), RtlRealArg(Args,2))));
    if Op = 'math_cosecant' then Exit(LfpReal(Math.Cosecant(RtlRealArg(Args,1))));
    if Op = 'math_cotan' then Exit(LfpReal(Math.Cotan(RtlRealArg(Args,1))));
    if Op = 'math_cycletorad' then Exit(LfpReal(Math.CycleToRad(RtlRealArg(Args,1))));
    if Op = 'math_degnormalize' then Exit(LfpReal(Math.DegNormalize(RtlRealArg(Args,1))));
    if Op = 'math_degtograd' then Exit(LfpReal(Math.DegToGrad(RtlRealArg(Args,1))));
    if Op = 'math_fmod' then Exit(LfpReal(Math.FMod(RtlRealArg(Args,1), RtlRealArg(Args,2))));
    if Op = 'math_gradtodeg' then Exit(LfpReal(Math.GradToDeg(RtlRealArg(Args,1))));
    if Op = 'math_gradtorad' then Exit(LfpReal(Math.GradToRad(RtlRealArg(Args,1))));
    if Op = 'math_intpower' then Exit(LfpReal(Math.IntPower(RtlRealArg(Args,1), RtlIntArg(Args,2))));
    if Op = 'math_iszero' then Exit(LfpBool(Math.IsZero(RtlRealArg(Args,1))));
    if Op = 'math_ldexp' then Exit(LfpReal(Math.Ldexp(RtlRealArg(Args,1), RtlIntArg(Args,2))));
    if Op = 'math_lnxp1' then Exit(LfpReal(Math.LnXP1(RtlRealArg(Args,1))));
    if Op = 'math_radtocycle' then Exit(LfpReal(Math.RadToCycle(RtlRealArg(Args,1))));
    if Op = 'math_radtograd' then Exit(LfpReal(Math.RadToGrad(RtlRealArg(Args,1))));
    if Op = 'math_randg' then Exit(LfpReal(Math.RandG(RtlRealArg(Args,1), RtlRealArg(Args,2))));
    if Op = 'math_randomrange' then Exit(LfpInt(Math.RandomRange(RtlIntArg(Args,1), RtlIntArg(Args,2))));
    if Op = 'math_roundto' then Exit(LfpReal(Math.RoundTo(RtlRealArg(Args,1), RtlIntArg(Args,2))));
    if Op = 'math_secant' then Exit(LfpReal(Math.Secant(RtlRealArg(Args,1))));
    if Op = 'math_sign' then Exit(LfpInt(Math.Sign(RtlRealArg(Args,1))));
    if Op = 'math_simpleroundto' then Exit(LfpReal(Math.SimpleRoundTo(RtlRealArg(Args,1), RtlIntArg(Args,2))));
    if Op = 'math_tan' then Exit(LfpReal(Math.Tan(RtlRealArg(Args,1))));
    if Op = 'math_futurevalue' then Exit(LfpReal(Math.FutureValue(RtlRealArg(Args,1), RtlIntArg(Args,2), RtlRealArg(Args,3), RtlRealArg(Args,4), Math.TPaymentTime(RtlOrdinalArg(Args,5)))));
    if Op = 'math_payment' then Exit(LfpReal(Math.Payment(RtlRealArg(Args,1), RtlIntArg(Args,2), RtlRealArg(Args,3), RtlRealArg(Args,4), Math.TPaymentTime(RtlOrdinalArg(Args,5)))));
    if Op = 'math_presentvalue' then Exit(LfpReal(Math.PresentValue(RtlRealArg(Args,1), RtlIntArg(Args,2), RtlRealArg(Args,3), RtlRealArg(Args,4), Math.TPaymentTime(RtlOrdinalArg(Args,5)))));
    if Op = 'math_interestrate' then Exit(LfpReal(Math.InterestRate(RtlIntArg(Args,1), RtlRealArg(Args,2), RtlRealArg(Args,3), RtlRealArg(Args,4), Math.TPaymentTime(RtlOrdinalArg(Args,5)))));
    if Op = 'math_numberofperiods' then Exit(LfpReal(Math.NumberOfPeriods(RtlRealArg(Args,1), RtlRealArg(Args,2), RtlRealArg(Args,3), RtlRealArg(Args,4), Math.TPaymentTime(RtlOrdinalArg(Args,5)))));
    if Op = 'math_randomfrom' then
    begin
      Arr := RtlValueArray(Args[1]);
      if Arr.Length = 0 then raise ELfpRuntimeError.Create('RandomFrom: empty array');
      Exit(Arr.GetItem(Arr.LowerBound + Math.RandomRange(0, Arr.Length)));
    end;
    if (Op = 'math_sumint') or (Op = 'math_minintvalue') or (Op = 'math_maxintvalue') then
    begin
      Arr := RtlValueArray(Args[1]);
      if Arr.Length = 0 then raise ELfpRuntimeError.Create(Op + ': empty array');
      I := LfpToInt(Arr.GetItem(Arr.LowerBound));
      if Op = 'math_sumint' then
      begin
        I := 0;
        for J := Arr.LowerBound to Arr.UpperBound do I := CheckedIntAdd(I, LfpToInt(Arr.GetItem(J)));
      end
      else if Op = 'math_minintvalue' then
      begin
        for J := Arr.LowerBound + 1 to Arr.UpperBound do if LfpToInt(Arr.GetItem(J)) < I then I := LfpToInt(Arr.GetItem(J));
      end
      else
      begin
        for J := Arr.LowerBound + 1 to Arr.UpperBound do if LfpToInt(Arr.GetItem(J)) > I then I := LfpToInt(Arr.GetItem(J));
      end;
      Exit(LfpInt(I));
    end;
  end;

  if Copy(Op, 1, 5) = 'char_' then
  begin
    if Op = 'char_fromutf32' then Exit(LfpString(Character.ConvertFromUtf32(Cardinal(RtlIntArg(Args,1)))));
    U := LfpValueAsString(Args[1]);
    if U = '' then raise ELfpRuntimeError.Create(Op + ': empty string has no character');
    Ch := U[1];
    if Op = 'char_toutf32' then Exit(LfpInt(Character.ConvertToUtf32(U, 1)));
    if Op = 'char_numericvalue' then Exit(LfpReal(Character.GetNumericValue(Ch)));
    if Op = 'char_category' then
    begin
      I := Ord(Character.GetUnicodeCategory(Ch));
      if (I < Low(UnicodeCategoryNames)) or (I > High(UnicodeCategoryNames)) then I := High(UnicodeCategoryNames);
      Exit(LfpObject(Engine.OwnObject(TLfpEnumValueObject.Create('TUnicodeCategory', UnicodeCategoryNames[I], I))));
    end;
    if Op = 'char_iscontrol' then Exit(LfpBool(Character.IsControl(Ch)));
    if Op = 'char_isdigit' then Exit(LfpBool(Character.IsDigit(Ch)));
    if Op = 'char_ishighsurrogate' then Exit(LfpBool(Character.IsHighSurrogate(Ch)));
    if Op = 'char_isletter' then Exit(LfpBool(Character.IsLetter(Ch)));
    if Op = 'char_isletterordigit' then Exit(LfpBool(Character.IsLetterOrDigit(Ch)));
    if Op = 'char_islower' then Exit(LfpBool(Character.IsLower(Ch)));
    if Op = 'char_islowsurrogate' then Exit(LfpBool(Character.IsLowSurrogate(Ch)));
    if Op = 'char_isnumber' then Exit(LfpBool(Character.IsNumber(Ch)));
    if Op = 'char_ispunctuation' then Exit(LfpBool(Character.IsPunctuation(Ch)));
    if Op = 'char_isseparator' then Exit(LfpBool(Character.IsSeparator(Ch)));
    if Op = 'char_issurrogate' then Exit(LfpBool(Character.IsSurrogate(Ch)));
    if Op = 'char_issurrogatepair' then
    begin
      U := LfpValueAsString(Args[2]);
      if U = '' then Exit(LfpBool(False));
      Ch2 := U[1];
      Exit(LfpBool(Character.IsSurrogatePair(Ch, Ch2)));
    end;
    if Op = 'char_issymbol' then Exit(LfpBool(Character.IsSymbol(Ch)));
    if Op = 'char_isupper' then Exit(LfpBool(Character.IsUpper(Ch)));
    if Op = 'char_iswhitespace' then Exit(LfpBool(Character.IsWhiteSpace(Ch)));
    if Op = 'char_tolower' then Exit(LfpString(Character.ToLower(Ch)));
    if Op = 'char_toupper' then Exit(LfpString(Character.ToUpper(Ch)));
  end;

  if Op = 'splitstring' then begin SL := TStringList.Create; try S := RtlStringArg(Args,2); if S = '' then begin SL.Add(RtlStringArg(Args,1)); Exit(RtlArrayFromStrings(Engine, SL)); end; SL.StrictDelimiter := False; SL.Delimiter := S[1]; SL.DelimitedText := RtlStringArg(Args,1); Exit(RtlArrayFromStrings(Engine, SL)); finally SL.Free; end; end;

  if TryNativeRtlTopoff(Engine, Op, Args, Result) then Exit;
  if TryNativeRtlExtended(Engine, Op, Args, Result) then Exit;
  raise ELfpRuntimeError.Create('unknown RTL operation: ' + Op);
end;

function NativeNow(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  Result := LfpReal(Now);
end;

constructor TLfpEngine.Create;
var
  ExeDir, EnvPath: string;
  EnvParts: TStringList;
  I: Integer;
begin
  inherited Create;
  FGlobals := TStringList.Create;
  FGlobals.CaseSensitive := False;
  FGlobals.Sorted := True;
  FGlobals.Duplicates := dupError;
  FGlobals.OwnsObjects := True;
  FTypes := TStringList.Create;
  FTypes.CaseSensitive := False;
  FTypes.Sorted := True;
  FTypes.Duplicates := dupError;
  FTypes.OwnsObjects := True;
  FHeap := TObjectList.Create(True);
  FSearchPaths := TStringList.Create;
  FLoadedUnits := TStringList.Create;
  FLoadedUnits.CaseSensitive := False;
  FLoadedUnits.Sorted := True;
  FLoadedUnits.Duplicates := dupIgnore;
  FTrace := False;
  FJitMode := jmAuto;
  FJitUsable := LfpJitSupported;
  if FJitUsable then FJitMessage := LfpJitPlatform
  else FJitMessage := 'native JIT is not available on ' + LfpJitPlatform;
  FJitCompiledFunctions := 0;
  FJitCompiledBytes := 0;
  FJitExecutions := 0;
  FLastResult := LfpNil;
  FGetOptNextChar := 0;
  FGetOptFirstNonOpt := 1;
  FGetOptLastNonOpt := 1;
  FGetOptOrdering := 1;
  FHeapTraceOutput := '';
  AddSearchPath('.');
  AddSearchPath(IncludeTrailingPathDelimiter(GetCurrentDir) + 'rtl');
  ExeDir := ExtractFileDir(ExpandFileName(ParamStr(0)));
  AddSearchPath(ExpandFileName(IncludeTrailingPathDelimiter(ExeDir) + '..' + DirectorySeparator + 'rtl'));
  AddSearchPath(ExpandFileName(IncludeTrailingPathDelimiter(ExeDir) + '..' + DirectorySeparator + 'lib' + DirectorySeparator + 'lfp' + DirectorySeparator + 'rtl'));
  if GetEnvironmentVariable('HOME') <> '' then
    AddSearchPath(IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.local' + DirectorySeparator + 'lib' + DirectorySeparator + 'lfp' + DirectorySeparator + 'rtl');
  AddSearchPath('/usr/local/lib/lfp/rtl');
  AddSearchPath('/usr/lib/lfp/rtl');
  EnvPath := GetEnvironmentVariable('LFP_PATH');
  if EnvPath <> '' then
  begin
    EnvParts := TStringList.Create;
    try
      EnvParts.Delimiter := PathSeparator;
      EnvParts.StrictDelimiter := True;
      EnvParts.DelimitedText := EnvPath;
      for I := 0 to EnvParts.Count - 1 do
        if Trim(EnvParts[I]) <> '' then AddSearchPath(Trim(EnvParts[I]));
    finally
      EnvParts.Free;
    end;
  end;
  RegisterStandardLibrary;
  if ResolveUnitFile('System') <> '' then RequireUnit('System');
end;

destructor TLfpEngine.Destroy;
begin
  FLoadedUnits.Free;
  FSearchPaths.Free;
  FGlobals.Free;
  FTypes.Free;
  FHeap.Free;
  inherited Destroy;
end;

function TLfpEngine.OwnObject(Obj: TLfpHeapObject): TLfpHeapObject;
begin
  FHeap.Add(Obj);
  Result := Obj;
end;

function TLfpEngine.GlobalBinding(const Name: string): TLfpBinding;
var I: Integer;
begin
  I := FGlobals.IndexOf(Name);
  if I < 0 then Result := nil else Result := TLfpBinding(FGlobals.Objects[I]);
end;

function TLfpEngine.FindTypeDef(const Name: string): TLfpTypeDef;
var I: Integer;
begin
  I := FTypes.IndexOf(Name);
  if I < 0 then Result := nil else Result := TLfpTypeDef(FTypes.Objects[I]);
end;

procedure TLfpEngine.DefineGlobal(const Name, TypeName: string; Mutable: Boolean;
  const Value: TLfpValue; ReplaceExisting: Boolean);
var I: Integer; B: TLfpBinding;
begin
  I := FGlobals.IndexOf(Name);
  if I >= 0 then
  begin
    if not ReplaceExisting then raise ELfpCompileError.Create('duplicate global: ' + Name);
    B := TLfpBinding(FGlobals.Objects[I]);
    B.DeclaredType := TypeName; B.Mutable := Mutable; B.Value := Value;
    Exit;
  end;
  if not ValueMatchesType(Value, TypeName) then
    raise ELfpRuntimeError.CreateFmt('initial value for %s does not match %s', [Name, TypeName]);
  FGlobals.AddObject(Name, TLfpBinding.Create(Name, TypeName, Mutable, Value));
end;

procedure TLfpEngine.DefineGlobalAlias(const Name: string; Target: TLfpBinding);
var
  B: TLfpBinding;
begin
  if not Assigned(Target) then
    raise ELfpRuntimeError.Create('cannot alias missing global: ' + Name);
  while Assigned(Target.AliasTarget) do Target := Target.AliasTarget;
  B := TLfpBinding.Create(Name, Target.DeclaredType, Target.Mutable, Target.Value);
  B.AliasTarget := Target;
  FGlobals.AddObject(Name, B);
end;

function TLfpEngine.HasGlobal(const Name: string): Boolean;
begin
  Result := FGlobals.IndexOf(Name) >= 0;
end;

function TLfpEngine.GetGlobal(const Name: string): TLfpValue;
var B: TLfpBinding;
begin
  B := GlobalBinding(Name);
  if not Assigned(B) then raise ELfpRuntimeError.Create('unknown identifier: ' + Name);
  while Assigned(B.AliasTarget) do B := B.AliasTarget;
  Result := B.Value;
end;

procedure TLfpEngine.SetGlobal(const Name: string; const Value: TLfpValue);
var B: TLfpBinding;
begin
  B := GlobalBinding(Name);
  if not Assigned(B) then raise ELfpRuntimeError.Create('assignment to undeclared variable: ' + Name);
  while Assigned(B.AliasTarget) do B := B.AliasTarget;
  if not B.Mutable then raise ELfpRuntimeError.Create('cannot assign to constant: ' + Name);
  RequireType(Value, B.DeclaredType, 'assignment to ' + Name);
  B.Value := Value;
end;

function TryParseSetType(const TypeName: string; out ElemType: string): Boolean;
var
  T, Body: string;
  Parts: TStringList;
begin
  Result := False;
  ElemType := 'Variant';
  T := Trim(TypeName);
  if (Length(T) < 10) or (T[1] <> '(') or (T[Length(T)] <> ')') then Exit;
  Body := Copy(T, 2, Length(T) - 2);
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ' ';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Body;
    if (Parts.Count <> 2) or not SameText(Parts[0], 'set-of') then Exit;
    ElemType := Parts[1];
    Result := True;
  finally
    Parts.Free;
  end;
end;

function TryParseSubrangeType(const TypeName: string; out Lo, Hi: Int64): Boolean;
var
  T, Body: string;
  Parts: TStringList;
begin
  Result := False;
  Lo := 0;
  Hi := -1;
  T := Trim(TypeName);
  if (Length(T) < 12) or (T[1] <> '(') or (T[Length(T)] <> ')') then Exit;
  Body := Copy(T, 2, Length(T) - 2);
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ' ';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Body;
    if (Parts.Count <> 3) or not SameText(Parts[0], 'subrange') then Exit;
    if not TryStrToInt64(Parts[1], Lo) then Exit;
    if not TryStrToInt64(Parts[2], Hi) then Exit;
    Result := Hi >= Lo;
  finally
    Parts.Free;
  end;
end;

function TryParseFixedArrayType(const TypeName: string; out Lo, Hi: Int64;
  out ElemType: string): Boolean;
var
  T, Body: string;
  Parts: TStringList;
begin
  Result := False;
  Lo := 0;
  Hi := -1;
  ElemType := 'Variant';
  T := Trim(TypeName);
  if (Length(T) < 9) or (T[1] <> '(') or (T[Length(T)] <> ')') then Exit;
  Body := Copy(T, 2, Length(T) - 2);
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ' ';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Body;
    if (Parts.Count <> 4) or not SameText(Parts[0], 'array') then Exit;
    if not TryStrToInt64(Parts[1], Lo) then Exit;
    if not TryStrToInt64(Parts[2], Hi) then Exit;
    if Hi < Lo then Exit;
    ElemType := Parts[3];
    Result := True;
  finally
    Parts.Free;
  end;
end;

function TLfpEngine.DefaultValueForType(const TypeName: string): TLfpValue;
var
  T: string;
  D: TLfpTypeDef;
  Lo, Hi, I: Int64;
  ElemType: string;
  Arr: TLfpArrayObject;
begin
  T := LowerCase(Trim(TypeName));
  if (T = 'integer') or (T = 'int64') or (T = 'longint') or (T = 'byte') or
     (T = 'word') or (T = 'cardinal') then Result := LfpInt(0)
  else if (T = 'real') or (T = 'double') or (T = 'single') then Result := LfpReal(0.0)
  else if T = 'boolean' then Result := LfpBool(False)
  else if T = 'string' then Result := LfpString('')
  else if T = 'char' then Result := LfpChar(#0)
  else if TryParseSubrangeType(TypeName, Lo, Hi) then Result := LfpInt(Lo)
  else if (T = 'pointer') or (Pos('(pointer', T) = 1) then Result := LfpNil
  else if TryParseFixedArrayType(TypeName, Lo, Hi, ElemType) then
  begin
    Arr := TLfpArrayObject(OwnObject(TLfpArrayObject.Create(SizeInt(Hi - Lo + 1), Lo, ElemType)));
    for I := Lo to Hi do Arr.SetItem(I, DefaultValueForType(ElemType));
    Result := LfpObject(Arr);
  end
  else if T = 'array' then
    Result := LfpObject(OwnObject(TLfpArrayObject.Create(0)))
  else if TryParseSetType(TypeName, ElemType) then
    Result := LfpObject(OwnObject(TLfpSetObject.Create(ElemType)))
  else if T = 'set' then
    Result := LfpObject(OwnObject(TLfpSetObject.Create))
  else
  begin
    D := FindTypeDef(TypeName);
    if Assigned(D) and (D.Kind = tdAlias) then Result := DefaultValueForType(TLfpAliasTypeDef(D).Target)
    else Result := LfpNil;
  end;
end;

function TLfpEngine.ValueMatchesType(const V: TLfpValue; const TypeName: string): Boolean;
var
  T: string;
  D: TLfpTypeDef;
  Lo, Hi, I: Int64;
  ElemType: string;
  Arr: TLfpArrayObject;
begin
  T := LowerCase(Trim(TypeName));
  if (T = '') or (T = 'variant') or (T = 'any') then Exit(True);
  if T = 'integer' then Exit(V.Kind = vkInteger);
  if T = 'int64' then Exit(V.Kind = vkInteger);
  if T = 'longint' then Exit(V.Kind = vkInteger);
  if T = 'byte' then Exit((V.Kind = vkInteger) and (V.IntValue >= 0) and (V.IntValue <= 255));
  if T = 'word' then Exit((V.Kind = vkInteger) and (V.IntValue >= 0) and (V.IntValue <= 65535));
  if T = 'cardinal' then Exit((V.Kind = vkInteger) and (V.IntValue >= 0));
  if (T = 'real') or (T = 'double') or (T = 'single') then Exit(LfpIsNumeric(V));
  if T = 'boolean' then Exit(V.Kind = vkBoolean);
  if T = 'string' then Exit(V.Kind = vkString);
  if T = 'char' then Exit(V.Kind = vkChar);
  if TryParseSubrangeType(TypeName, Lo, Hi) then
    Exit((V.Kind = vkInteger) and (V.IntValue >= Lo) and (V.IntValue <= Hi));
  if (T = 'pointer') or (Pos('(pointer', T) = 1) then
    Exit((V.Kind = vkNil) or ((V.Kind = vkObject) and (V.ObjValue is TLfpPointerObject)));
  if TryParseFixedArrayType(TypeName, Lo, Hi, ElemType) then
  begin
    if (V.Kind <> vkObject) or not (V.ObjValue is TLfpArrayObject) then Exit(False);
    Arr := TLfpArrayObject(V.ObjValue);
    if (Arr.LowerBound <> Lo) or (Arr.UpperBound <> Hi) then Exit(False);
    for I := Arr.LowerBound to Arr.UpperBound do
      if not ValueMatchesType(Arr.GetItem(I), ElemType) then Exit(False);
    Arr.ElementType := ElemType;
    Exit(True);
  end;
  if T = 'array' then
    Exit((V.Kind = vkObject) and (V.ObjValue is TLfpArrayObject));
  if TryParseSetType(TypeName, ElemType) then
  begin
    if (V.Kind <> vkObject) or not (V.ObjValue is TLfpSetObject) then Exit(False);
    for I := 0 to TLfpSetObject(V.ObjValue).Count - 1 do
      if not ValueMatchesType(TLfpSetObject(V.ObjValue).ItemAt(I), ElemType) then Exit(False);
    TLfpSetObject(V.ObjValue).ElementType := ElemType;
    Exit(True);
  end;
  if T = 'set' then
    Exit((V.Kind = vkObject) and (V.ObjValue is TLfpSetObject));

  D := FindTypeDef(TypeName);
  if Assigned(D) then
  begin
    if D.Kind = tdAlias then Exit(ValueMatchesType(V, TLfpAliasTypeDef(D).Target));
    if V.Kind = vkNil then Exit(True);
    Exit((V.Kind = vkObject) and SameText(V.ObjValue.TypeName, D.Name));
  end;
  Result := (V.Kind = vkNil) or ((V.Kind = vkObject) and SameText(V.ObjValue.TypeName, TypeName));
end;

procedure TLfpEngine.RequireType(const V: TLfpValue; const TypeName,
  Context: string);
begin
  if not ValueMatchesType(V, TypeName) then
    raise ELfpRuntimeError.CreateFmt('%s: expected %s, got %s',
      [Context, TypeName, LfpValueTypeName(V)]);
end;

procedure TLfpEngine.RegisterNative(const Name: string; Callback: TLfpNativeCallback;
  UserData: Pointer; MinArgs: Integer; MaxArgs: Integer);
var O: TLfpNativeFunctionObject;
begin
  O := TLfpNativeFunctionObject(OwnObject(TLfpNativeFunctionObject.Create(Name,
    Callback, UserData, MinArgs, MaxArgs)));
  DefineGlobal(Name, 'Variant', False, LfpObject(O), True);
end;

procedure TLfpEngine.AddSearchPath(const Path: string);
var P: string;
begin
  P := ExpandFileName(Path);
  if FSearchPaths.IndexOf(P) < 0 then FSearchPaths.Add(P);
end;

procedure TLfpEngine.RegisterType(TypeDef: TLfpTypeDef);
var I: Integer;
begin
  I := FTypes.IndexOf(TypeDef.Name);
  if I >= 0 then
  begin
    TypeDef.Free;
    raise ELfpCompileError.Create('duplicate type: ' + FTypes[I]);
  end;
  FTypes.AddObject(TypeDef.Name, TypeDef);
end;

procedure TLfpEngine.RegisterStandardLibrary;
begin
  RegisterNative('write', @NativeWrite, nil, 0, -1);
  RegisterNative('writeln', @NativeWriteln, nil, 0, -1);
  RegisterNative('readln', @NativeReadln, nil, 0, 1);
  RegisterNative('length', @NativeLength, nil, 1, 1);
  RegisterNative('low', @NativeLow, nil, 1, 1);
  RegisterNative('high', @NativeHigh, nil, 1, 1);
  RegisterNative('str', @NativeStr, nil, 1, 1);
  RegisterNative('integer', @NativeInt, nil, 1, 1);
  RegisterNative('real', @NativeReal, nil, 1, 1);
  RegisterNative('boolean', @NativeBool, nil, 1, 1);
  RegisterNative('ord', @NativeOrd, nil, 1, 1);
  RegisterNative('chr', @NativeChr, nil, 1, 1);
  RegisterNative('abs', @NativeAbs, nil, 1, 1);
  RegisterNative('sqr', @NativeSqr, nil, 1, 1);
  RegisterNative('sqrt', @NativeSqrt, nil, 1, 1);
  RegisterNative('odd', @NativeOdd, nil, 1, 1);
  RegisterNative('sin', @NativeSin, nil, 1, 1);
  RegisterNative('cos', @NativeCos, nil, 1, 1);
  RegisterNative('tan', @NativeTan, nil, 1, 1);
  RegisterNative('arctan', @NativeArcTan, nil, 1, 1);
  RegisterNative('ln', @NativeLn, nil, 1, 1);
  RegisterNative('exp', @NativeExp, nil, 1, 1);
  RegisterNative('round', @NativeRound, nil, 1, 1);
  RegisterNative('trunc', @NativeTrunc, nil, 1, 1);
  RegisterNative('randomize', @NativeRandomize, nil, 0, 0);
  RegisterNative('random', @NativeRandom, nil, 0, 1);
  RegisterNative('min', @NativeMin, nil, 1, -1);
  RegisterNative('max', @NativeMax, nil, 1, -1);
  RegisterNative('pred', @NativePred, nil, 1, 1);
  RegisterNative('succ', @NativeSucc, nil, 1, 1);
  RegisterNative('include', @NativeInclude, nil, 2, 2);
  RegisterNative('exclude', @NativeExclude, nil, 2, 2);
  RegisterNative('in', @NativeIn, nil, 2, 2);
  RegisterNative('append', @NativeAppend, nil, 2, 2);
  RegisterNative('list', @NativeList, nil, 0, -1);
  RegisterNative('first', @NativeFirst, nil, 1, 1);
  RegisterNative('head', @NativeFirst, nil, 1, 1);
  RegisterNative('rest', @NativeRest, nil, 1, 1);
  RegisterNative('tail', @NativeRest, nil, 1, 1);
  RegisterNative('last', @NativeLast, nil, 1, 1);
  RegisterNative('nth', @NativeNth, nil, 2, 2);
  RegisterNative('reverse', @NativeReverse, nil, 1, 1);
  RegisterNative('apply', @NativeApply, nil, 2, 2);
  RegisterNative('map', @NativeMap, nil, 2, 2);
  RegisterNative('filter', @NativeFilter, nil, 2, 2);
  RegisterNative('foldl', @NativeFoldl, nil, 3, 3);
  RegisterNative('foreach', @NativeForEach, nil, 2, 2);
  RegisterNative('concat', @NativeConcat, nil, 0, -1);
  RegisterNative('uppercase', @NativeUpper, nil, 1, 1);
  RegisterNative('lowercase', @NativeLower, nil, 1, 1);
  RegisterNative('copy', @NativeCopy, nil, 3, 3);
  RegisterNative('pos', @NativePos, nil, 2, 2);
  RegisterNative('assert', @NativeAssert, nil, 1, 2);
  RegisterNative('halt', @NativeHalt, nil, 0, 1);
  RegisterNative('typeof', @NativeTypeOf, nil, 1, 1);
  RegisterNative('now', @NativeNow, nil, 0, 0);
  RegisterNative('__rtl', @NativeRtl, nil, 1, -1);
  DefineGlobal('pi', 'Real', False, LfpReal(3.14159265358979323846), True);
end;

function TLfpEngine.ExecuteCallable(const Callee: TLfpValue;
  const Args: TLfpValueArray): TLfpValue;
var
  R: TLfpRecordObject;
  C: TLfpRecordConstructorObject;
  D: TLfpRecordTypeDef;
  I: Integer;
begin
  if (Callee.Kind <> vkObject) or not Assigned(Callee.ObjValue) then
    raise ELfpRuntimeError.Create('attempt to call non-callable ' + LfpValueTypeName(Callee));
  if Callee.ObjValue is TLfpBytecodeFunction then
    Exit(ExecuteFunction(TLfpBytecodeFunction(Callee.ObjValue), Args));
  if Callee.ObjValue is TLfpNativeFunctionObject then
    Exit(TLfpNativeFunctionObject(Callee.ObjValue).Invoke(Self, Args));
  if Callee.ObjValue is TLfpRecordConstructorObject then
  begin
    C := TLfpRecordConstructorObject(Callee.ObjValue);
    D := C.TypeDef;
    if Length(Args) > D.Fields.Count then
      raise ELfpRuntimeError.CreateFmt('%s constructor expects at most %d values, got %d',
        [D.Name, D.Fields.Count, Length(Args)]);
    R := TLfpRecordObject(OwnObject(TLfpRecordObject.Create(D.Name)));
    for I := 0 to D.Fields.Count - 1 do
    begin
      if I <= High(Args) then
      begin
        RequireType(Args[I], D.FieldTypes[I], D.Name + '.' + D.Fields[I]);
        R.DefineField(D.Fields[I], Args[I]);
      end
      else
        R.DefineField(D.Fields[I], DefaultValueForType(D.FieldTypes[I]));
    end;
    Exit(LfpObject(R));
  end;
  raise ELfpRuntimeError.Create('object is not callable: ' + Callee.ObjValue.Inspect);
end;

function CompareIntegerReal(I: Int64; R: Double): Integer;
const
  Int64UpperExclusive = 9223372036854775808.0;
  Int64LowerInclusive = -9223372036854775808.0;
var
  Truncated: Int64;
begin
  if IsNan(R) then
    raise ELfpRuntimeError.Create('nan is not order-comparable');
  if R >= Int64UpperExclusive then Exit(-1);
  if R < Int64LowerInclusive then Exit(1);
  Truncated := Trunc(R);
  if I < Truncated then Exit(-1);
  if I > Truncated then Exit(1);
  if R > Truncated then Exit(-1);
  if R < Truncated then Exit(1);
  Result := 0;
end;

function CompareValues(const A, B: TLfpValue): Integer;
var
  RA, RB: Double;
  SA, SB: UnicodeString;
begin
  if (A.Kind = vkInteger) and (B.Kind = vkInteger) then
  begin
    if A.IntValue < B.IntValue then Exit(-1)
    else if A.IntValue > B.IntValue then Exit(1)
    else Exit(0);
  end;
  if (A.Kind = vkInteger) and (B.Kind = vkReal) then
    Exit(CompareIntegerReal(A.IntValue, B.RealValue));
  if (A.Kind = vkReal) and (B.Kind = vkInteger) then
    Exit(-CompareIntegerReal(B.IntValue, A.RealValue));
  if (A.Kind = vkReal) and (B.Kind = vkReal) then
  begin
    RA := LfpToReal(A); RB := LfpToReal(B);
    if IsNan(RA) or IsNan(RB) then
      raise ELfpRuntimeError.Create('nan is not order-comparable');
    if RA < RB then Exit(-1) else if RA > RB then Exit(1) else Exit(0);
  end;
  if (A.Kind in [vkString, vkChar]) and (B.Kind in [vkString, vkChar]) then
  begin
    SA := A.StrValue; SB := B.StrValue;
    if SA < SB then Exit(-1) else if SA > SB then Exit(1) else Exit(0);
  end;
  if (A.Kind = vkObject) and (B.Kind = vkObject) and
     (A.ObjValue is TLfpEnumValueObject) and (B.ObjValue is TLfpEnumValueObject) and
     SameText(TLfpEnumValueObject(A.ObjValue).EnumName, TLfpEnumValueObject(B.ObjValue).EnumName) then
  begin
    Result := TLfpEnumValueObject(A.ObjValue).Ordinal - TLfpEnumValueObject(B.ObjValue).Ordinal;
    Exit;
  end;
  raise ELfpRuntimeError.CreateFmt('values of type %s and %s are not order-comparable',
    [LfpValueTypeName(A), LfpValueTypeName(B)]);
end;

function AddValues(const A, B: TLfpValue): TLfpValue;
begin
  if (A.Kind = vkString) or (B.Kind = vkString) then
    Exit(LfpString(LfpValueAsString(A) + LfpValueAsString(B)));
  if not LfpIsNumeric(A) or not LfpIsNumeric(B) then
    raise ELfpRuntimeError.Create('+ expects numbers or strings');
  if (A.Kind = vkInteger) and (B.Kind = vkInteger) then
    Result := LfpInt(CheckedIntAdd(A.IntValue, B.IntValue))
  else Result := LfpReal(LfpToReal(A) + LfpToReal(B));
end;

type
  TLfpExecutionFrame = class
  private
    FEngine: TLfpEngine;
    FFunc: TLfpBytecodeFunction;
    FStack: TLfpValueArray;
    FLocals: TLfpValueArray;
    FSP: Integer;
    FResult: TLfpValue;
    FReturned: Boolean;
    FRunningJit: Boolean;
    FFailed: Boolean;
    FHalted: Boolean;
    FErrorMessage: string;
    FHaltCode: Integer;
    procedure Push(const Value: TLfpValue);
    function Pop: TLfpValue;
    function Peek: TLfpValue;
    function IsSetValue(const Value: TLfpValue): Boolean;
    function SetSubset(const Left, Right: TLfpValue): Boolean;
    function SetBinary(const Left, Right: TLfpValue; Mode: Char): TLfpValue;
    procedure Finish;
    procedure StoreError(InstructionIndex: Integer; E: Exception);
    function InstructionAt(InstructionIndex: Integer): TLfpInstruction;
    procedure TraceInstruction(InstructionIndex: Integer;
      const Inst: TLfpInstruction);
  public
    constructor Create(Engine: TLfpEngine; Func: TLfpBytecodeFunction;
      const Args: TLfpValueArray);
    function Step(InstructionIndex: Integer): Integer;
    function RunInterpreter: TLfpValue;
    function RunJit(Code: TLfpJitCode): TLfpValue;
  end;

  TLfpVmOpHandler = function(Frame: TLfpExecutionFrame;
    const Inst: TLfpInstruction): Integer;

var
  VmOpHandlers: array[TLfpOpCode] of TLfpVmOpHandler;

constructor TLfpExecutionFrame.Create(Engine: TLfpEngine;
  Func: TLfpBytecodeFunction; const Args: TLfpValueArray);
var
  I: Integer;
begin
  inherited Create;
  FEngine := Engine;
  FFunc := Func;
  if Length(Args) <> Func.ParamNames.Count then
    raise ELfpRuntimeError.CreateFmt('%s expects %d argument(s), got %d',
      [Func.Name, Func.ParamNames.Count, Length(Args)]);
  SetLength(FLocals, Func.LocalNames.Count);
  for I := 0 to High(FLocals) do FLocals[I] := LfpNil;
  for I := 0 to High(Args) do
  begin
    Engine.RequireType(Args[I], Func.ParamTypes[I],
      Func.Name + ' argument ' + Func.ParamNames[I]);
    FLocals[I] := Args[I];
  end;
  SetLength(FStack, 32);
  FSP := 0;
  FResult := LfpNil;
  FReturned := False;
end;

procedure TLfpExecutionFrame.Push(const Value: TLfpValue);
begin
  if FSP >= Length(FStack) then
  begin
    if Length(FStack) < 16 then SetLength(FStack, 16)
    else SetLength(FStack, Length(FStack) * 2);
  end;
  FStack[FSP] := Value;
  Inc(FSP);
end;

function TLfpExecutionFrame.Pop: TLfpValue;
begin
  if FSP <= 0 then
    raise ELfpRuntimeError.Create('internal VM stack underflow');
  Dec(FSP);
  Result := FStack[FSP];
  FStack[FSP] := LfpNil;
end;

function TLfpExecutionFrame.Peek: TLfpValue;
begin
  if FSP <= 0 then
    raise ELfpRuntimeError.Create('internal VM stack underflow');
  Result := FStack[FSP - 1];
end;

function TLfpExecutionFrame.IsSetValue(const Value: TLfpValue): Boolean;
begin
  Result := (Value.Kind = vkObject) and (Value.ObjValue is TLfpSetObject);
end;

function TLfpExecutionFrame.SetSubset(const Left, Right: TLfpValue): Boolean;
var
  LeftSet, RightSet: TLfpSetObject;
  I: SizeInt;
begin
  if not IsSetValue(Left) or not IsSetValue(Right) then Exit(False);
  LeftSet := TLfpSetObject(Left.ObjValue);
  RightSet := TLfpSetObject(Right.ObjValue);
  for I := 0 to LeftSet.Count - 1 do
    if not RightSet.Contains(LeftSet.ItemAt(I)) then Exit(False);
  Result := True;
end;

function TLfpExecutionFrame.SetBinary(const Left, Right: TLfpValue;
  Mode: Char): TLfpValue;
var
  LeftSet, RightSet, OutputSet: TLfpSetObject;
  I: SizeInt;
  Value: TLfpValue;
begin
  if not IsSetValue(Left) or not IsSetValue(Right) then
    raise ELfpRuntimeError.Create('set operator requires two sets');
  LeftSet := TLfpSetObject(Left.ObjValue);
  RightSet := TLfpSetObject(Right.ObjValue);
  if SameText(LeftSet.ElementType, RightSet.ElementType) then
    OutputSet := TLfpSetObject(FEngine.OwnObject(
      TLfpSetObject.Create(LeftSet.ElementType)))
  else
    OutputSet := TLfpSetObject(FEngine.OwnObject(
      TLfpSetObject.Create('Variant')));
  case Mode of
    '+':
      begin
        for I := 0 to LeftSet.Count - 1 do
          OutputSet.IncludeValue(LeftSet.ItemAt(I));
        for I := 0 to RightSet.Count - 1 do
          OutputSet.IncludeValue(RightSet.ItemAt(I));
      end;
    '-':
      for I := 0 to LeftSet.Count - 1 do
      begin
        Value := LeftSet.ItemAt(I);
        if not RightSet.Contains(Value) then OutputSet.IncludeValue(Value);
      end;
    '*':
      for I := 0 to LeftSet.Count - 1 do
      begin
        Value := LeftSet.ItemAt(I);
        if RightSet.Contains(Value) then OutputSet.IncludeValue(Value);
      end;
  else
    raise ELfpRuntimeError.Create('internal: unknown set operation');
  end;
  Result := LfpObject(OutputSet);
end;

procedure TLfpExecutionFrame.Finish;
begin
  if FReturned then Exit;
  if FSP > 0 then FResult := Pop else FResult := LfpNil;
  if FFunc.IsProcedure then FResult := LfpNil
  else FEngine.RequireType(FResult, FFunc.ReturnTypeName,
    'return from ' + FFunc.Name);
  FReturned := True;
end;

procedure TLfpExecutionFrame.StoreError(InstructionIndex: Integer;
  E: Exception);
var
  Inst: TLfpInstruction;
begin
  if (InstructionIndex >= 0) and (InstructionIndex < Length(FFunc.Code)) then
  begin
    Inst := FFunc.Code[InstructionIndex];
    FErrorMessage := Format('%s:%d:%d in %s: %s',
      [Inst.Pos.FileName, Inst.Pos.Line, Inst.Pos.Column, FFunc.Name, E.Message]);
  end
  else
    FErrorMessage := E.Message;
  FFailed := True;
end;

function TLfpExecutionFrame.InstructionAt(
  InstructionIndex: Integer): TLfpInstruction;
begin
  if (InstructionIndex < 0) or (InstructionIndex >= Length(FFunc.Code)) then
    raise ELfpRuntimeError.CreateFmt('invalid instruction index %d',
      [InstructionIndex]);
  Result := FFunc.Code[InstructionIndex];
end;

procedure TLfpExecutionFrame.TraceInstruction(InstructionIndex: Integer;
  const Inst: TLfpInstruction);
var
  Backend: string;
begin
  if FEngine.FTrace then
  begin
    if FRunningJit then Backend := 'jit' else Backend := 'vm';
    Writeln(Format('[lfp %s] %s:%d  %4d %-16s %d',
      [Backend, FFunc.Name, Inst.Pos.Line, InstructionIndex,
       LfpOpcodeName(Inst.Op), Inst.A]));
  end;
end;

function VmPushConst(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
begin
  Frame.Push(Frame.FFunc.Constants[Inst.A]);
  Result := 0;
end;

function VmPushNil(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
begin
  Frame.Push(LfpNil);
  Result := 0;
end;

function VmPop(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
begin
  Frame.Pop;
  Result := 0;
end;

function VmDup(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
begin
  Frame.Push(Frame.Peek);
  Result := 0;
end;

function VmDup2(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
begin
  if Frame.FSP < 2 then
    raise ELfpRuntimeError.Create('internal VM stack underflow');
  A := Frame.FStack[Frame.FSP - 2];
  B := Frame.FStack[Frame.FSP - 1];
  Frame.Push(A);
  Frame.Push(B);
  Result := 0;
end;

function VmLoadGlobal(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  Name: string;
begin
  Name := UTF8Encode(Frame.FFunc.Constants[Inst.A].StrValue);
  Frame.Push(Frame.FEngine.GetGlobal(Name));
  Result := 0;
end;

function VmStoreGlobal(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  Name: string;
  Value: TLfpValue;
  Binding: TLfpBinding;
begin
  Name := UTF8Encode(Frame.FFunc.Constants[Inst.A].StrValue);
  Value := Frame.Pop;
  Binding := Frame.FEngine.GlobalBinding(Name);
  if not Assigned(Binding) then
    raise ELfpRuntimeError.Create('assignment to undeclared variable: ' + Name);
  while Assigned(Binding.AliasTarget) do Binding := Binding.AliasTarget;
  if (not Binding.Mutable) and (Inst.B = 0) then
    raise ELfpRuntimeError.Create('cannot assign to constant: ' + Name);
  Frame.FEngine.RequireType(Value, Binding.DeclaredType,
    'assignment to ' + Name);
  Binding.Value := Value;
  Frame.Push(Value);
  Result := 0;
end;

function VmLoadLocal(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
begin
  Frame.Push(Frame.FLocals[Inst.A]);
  Result := 0;
end;

function VmStoreLocal(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  Value: TLfpValue;
  TypeName: string;
begin
  Value := Frame.Pop;
  if (not Frame.FFunc.LocalMutable(Inst.A)) and (Inst.B = 0) then
    raise ELfpRuntimeError.Create('cannot assign to local constant: ' +
      Frame.FFunc.LocalNames[Inst.A]);
  TypeName := Frame.FFunc.LocalType(Inst.A);
  Frame.FEngine.RequireType(Value, TypeName,
    'assignment to local ' + Frame.FFunc.LocalNames[Inst.A]);
  Frame.FLocals[Inst.A] := Value;
  Frame.Push(Value);
  Result := 0;
end;

function VmAdd(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
begin
  B := Frame.Pop;
  A := Frame.Pop;
  if (A.Kind = vkInteger) and (B.Kind = vkInteger) then
    Frame.Push(LfpInt(CheckedIntAdd(A.IntValue, B.IntValue)))
  else if Frame.IsSetValue(A) and Frame.IsSetValue(B) then
    Frame.Push(Frame.SetBinary(A, B, '+'))
  else
    Frame.Push(AddValues(A, B));
  Result := 0;
end;

function VmSub(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
begin
  B := Frame.Pop;
  A := Frame.Pop;
  if (A.Kind = vkInteger) and (B.Kind = vkInteger) then
    Frame.Push(LfpInt(CheckedIntSub(A.IntValue, B.IntValue)))
  else if Frame.IsSetValue(A) and Frame.IsSetValue(B) then
    Frame.Push(Frame.SetBinary(A, B, '-'))
  else
    Frame.Push(LfpReal(LfpToReal(A) - LfpToReal(B)));
  Result := 0;
end;

function VmMul(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
begin
  B := Frame.Pop;
  A := Frame.Pop;
  if (A.Kind = vkInteger) and (B.Kind = vkInteger) then
    Frame.Push(LfpInt(CheckedIntMul(A.IntValue, B.IntValue)))
  else if Frame.IsSetValue(A) and Frame.IsSetValue(B) then
    Frame.Push(Frame.SetBinary(A, B, '*'))
  else
    Frame.Push(LfpReal(LfpToReal(A) * LfpToReal(B)));
  Result := 0;
end;

function VmDivReal(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
  Divisor: Double;
begin
  B := Frame.Pop;
  A := Frame.Pop;
  Divisor := LfpToReal(B);
  if Divisor = 0 then
    raise ELfpRuntimeError.Create('division by zero');
  Frame.Push(LfpReal(LfpToReal(A) / Divisor));
  Result := 0;
end;

function VmDivInt(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
begin
  B := Frame.Pop;
  A := Frame.Pop;
  Frame.Push(LfpInt(CheckedIntDiv(LfpToInt(A), LfpToInt(B))));
  Result := 0;
end;

function VmMod(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
begin
  B := Frame.Pop;
  A := Frame.Pop;
  Frame.Push(LfpInt(CheckedIntMod(LfpToInt(A), LfpToInt(B))));
  Result := 0;
end;

function VmNeg(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A: TLfpValue;
begin
  A := Frame.Pop;
  if A.Kind = vkInteger then Frame.Push(LfpInt(CheckedIntNeg(A.IntValue)))
  else Frame.Push(LfpReal(-LfpToReal(A)));
  Result := 0;
end;

function VmEq(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
begin
  B := Frame.Pop;
  A := Frame.Pop;
  if (A.Kind = vkInteger) and (B.Kind = vkInteger) then
    Frame.Push(LfpBool(A.IntValue = B.IntValue))
  else
    Frame.Push(LfpBool(LfpValueEqual(A, B)));
  Result := 0;
end;

function VmNe(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
begin
  B := Frame.Pop;
  A := Frame.Pop;
  if (A.Kind = vkInteger) and (B.Kind = vkInteger) then
    Frame.Push(LfpBool(A.IntValue <> B.IntValue))
  else
    Frame.Push(LfpBool(not LfpValueEqual(A, B)));
  Result := 0;
end;

function VmLt(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
begin
  B := Frame.Pop;
  A := Frame.Pop;
  if (A.Kind = vkInteger) and (B.Kind = vkInteger) then
    Frame.Push(LfpBool(A.IntValue < B.IntValue))
  else if Frame.IsSetValue(A) and Frame.IsSetValue(B) then
    Frame.Push(LfpBool(Frame.SetSubset(A, B) and not LfpValueEqual(A, B)))
  else
    Frame.Push(LfpBool(CompareValues(A, B) < 0));
  Result := 0;
end;

function VmLe(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
begin
  B := Frame.Pop;
  A := Frame.Pop;
  if (A.Kind = vkInteger) and (B.Kind = vkInteger) then
    Frame.Push(LfpBool(A.IntValue <= B.IntValue))
  else if Frame.IsSetValue(A) and Frame.IsSetValue(B) then
    Frame.Push(LfpBool(Frame.SetSubset(A, B)))
  else
    Frame.Push(LfpBool(CompareValues(A, B) <= 0));
  Result := 0;
end;

function VmGt(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
begin
  B := Frame.Pop;
  A := Frame.Pop;
  if (A.Kind = vkInteger) and (B.Kind = vkInteger) then
    Frame.Push(LfpBool(A.IntValue > B.IntValue))
  else if Frame.IsSetValue(A) and Frame.IsSetValue(B) then
    Frame.Push(LfpBool(Frame.SetSubset(B, A) and not LfpValueEqual(A, B)))
  else
    Frame.Push(LfpBool(CompareValues(A, B) > 0));
  Result := 0;
end;

function VmGe(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
begin
  B := Frame.Pop;
  A := Frame.Pop;
  if (A.Kind = vkInteger) and (B.Kind = vkInteger) then
    Frame.Push(LfpBool(A.IntValue >= B.IntValue))
  else if Frame.IsSetValue(A) and Frame.IsSetValue(B) then
    Frame.Push(LfpBool(Frame.SetSubset(B, A)))
  else
    Frame.Push(LfpBool(CompareValues(A, B) >= 0));
  Result := 0;
end;

function VmNot(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
begin
  Frame.Push(LfpBool(not LfpTruthy(Frame.Pop)));
  Result := 0;
end;

function VmJump(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
begin
  Result := 0;
end;

function VmJumpFalse(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
begin
  if LfpTruthy(Frame.Pop) then Result := 1 else Result := 0;
end;

function VmJumpTrue(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
begin
  if LfpTruthy(Frame.Pop) then Result := 1 else Result := 0;
end;

function VmCall(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  Callee: TLfpValue;
  Args: TLfpValueArray;
  I: Integer;
begin
  SetLength(Args, Inst.A);
  for I := Inst.A - 1 downto 0 do Args[I] := Frame.Pop;
  Callee := Frame.Pop;
  Frame.Push(Frame.FEngine.ExecuteCallable(Callee, Args));
  Result := 0;
end;

function VmReturn(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
begin
  Frame.Finish;
  Result := 0;
end;

function VmMakeArray(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  ArrayObject: TLfpArrayObject;
  I: Integer;
begin
  ArrayObject := TLfpArrayObject(Frame.FEngine.OwnObject(
    TLfpArrayObject.Create(Inst.A)));
  for I := Inst.A - 1 downto 0 do ArrayObject.SetItem(I, Frame.Pop);
  Frame.Push(LfpObject(ArrayObject));
  Result := 0;
end;

function VmMakeSet(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  SetObject: TLfpSetObject;
  Args: TLfpValueArray;
  I: Integer;
begin
  SetObject := TLfpSetObject(Frame.FEngine.OwnObject(TLfpSetObject.Create));
  SetLength(Args, Inst.A);
  for I := Inst.A - 1 downto 0 do Args[I] := Frame.Pop;
  for I := 0 to High(Args) do SetObject.IncludeValue(Args[I]);
  Frame.Push(LfpObject(SetObject));
  Result := 0;
end;

function VmIndexGet(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B: TLfpValue;
  I: Int64;
begin
  B := Frame.Pop;
  A := Frame.Pop;
  if (A.Kind = vkObject) and (A.ObjValue is TLfpArrayObject) then
    Frame.Push(TLfpArrayObject(A.ObjValue).GetItem(LfpToInt(B)))
  else if A.Kind = vkString then
  begin
    I := LfpToInt(B);
    if (I < 1) or (I > Length(A.StrValue)) then
      raise ELfpRuntimeError.Create('string index out of range');
    Frame.Push(LfpChar(A.StrValue[I]));
  end
  else
    raise ELfpRuntimeError.Create('index expects array or string');
  Result := 0;
end;

function VmIndexSet(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, B, Value: TLfpValue;
  ArrayObject: TLfpArrayObject;
begin
  Value := Frame.Pop;
  B := Frame.Pop;
  A := Frame.Pop;
  if (A.Kind <> vkObject) or not (A.ObjValue is TLfpArrayObject) then
    raise ELfpRuntimeError.Create('indexed assignment requires array');
  ArrayObject := TLfpArrayObject(A.ObjValue);
  Frame.FEngine.RequireType(Value, ArrayObject.ElementType,
    'array element assignment');
  ArrayObject.SetItem(LfpToInt(B), Value);
  Frame.Push(Value);
  Result := 0;
end;

function VmFieldGet(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A: TLfpValue;
  Name: string;
  RecordObject: TLfpRecordObject;
begin
  A := Frame.Pop;
  if (A.Kind <> vkObject) or not (A.ObjValue is TLfpRecordObject) then
    raise ELfpRuntimeError.Create('field access requires record');
  RecordObject := TLfpRecordObject(A.ObjValue);
  Name := UTF8Encode(Frame.FFunc.Constants[Inst.A].StrValue);
  Frame.Push(RecordObject.GetField(Name));
  Result := 0;
end;

function VmFieldSet(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, Value: TLfpValue;
  Name: string;
  FieldIndex: Integer;
  RecordObject: TLfpRecordObject;
  RecordType: TLfpRecordTypeDef;
  TypeDef: TLfpTypeDef;
begin
  Value := Frame.Pop;
  A := Frame.Pop;
  if (A.Kind <> vkObject) or not (A.ObjValue is TLfpRecordObject) then
    raise ELfpRuntimeError.Create('field assignment requires record');
  RecordObject := TLfpRecordObject(A.ObjValue);
  Name := UTF8Encode(Frame.FFunc.Constants[Inst.A].StrValue);
  TypeDef := Frame.FEngine.FindTypeDef(RecordObject.RecordTypeName);
  if Assigned(TypeDef) and (TypeDef.Kind = tdRecord) then
  begin
    RecordType := TLfpRecordTypeDef(TypeDef);
    FieldIndex := RecordType.Fields.IndexOf(Name);
    if FieldIndex < 0 then
      raise ELfpRuntimeError.CreateFmt('%s has no field "%s"',
        [RecordObject.RecordTypeName, Name]);
    Frame.FEngine.RequireType(Value, RecordType.FieldTypes[FieldIndex],
      RecordObject.RecordTypeName + '.' + Name);
  end;
  RecordObject.SetField(Name, Value);
  Frame.Push(Value);
  Result := 0;
end;

function VmNewPointer(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  PointerObject: TLfpPointerObject;
begin
  PointerObject := TLfpPointerObject(Frame.FEngine.OwnObject(
    TLfpPointerObject.Create(Frame.Pop)));
  Frame.Push(LfpObject(PointerObject));
  Result := 0;
end;

function VmDeref(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A: TLfpValue;
begin
  A := Frame.Pop;
  if (A.Kind <> vkObject) or not (A.ObjValue is TLfpPointerObject) then
    raise ELfpRuntimeError.Create('deref expects pointer');
  Frame.Push(TLfpPointerObject(A.ObjValue).Dereference);
  Result := 0;
end;

function VmSetDeref(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A, Value: TLfpValue;
begin
  Value := Frame.Pop;
  A := Frame.Pop;
  if (A.Kind <> vkObject) or not (A.ObjValue is TLfpPointerObject) then
    raise ELfpRuntimeError.Create('pointer assignment expects pointer');
  TLfpPointerObject(A.ObjValue).Assign(Value);
  Frame.Push(Value);
  Result := 0;
end;

function VmDisposePointer(Frame: TLfpExecutionFrame;
  const Inst: TLfpInstruction): Integer;
var
  A: TLfpValue;
begin
  A := Frame.Pop;
  if (A.Kind <> vkObject) or not (A.ObjValue is TLfpPointerObject) then
    raise ELfpRuntimeError.Create('dispose expects pointer');
  TLfpPointerObject(A.ObjValue).DisposePointer;
  Frame.Push(LfpNil);
  Result := 0;
end;

procedure InitializeVmOpHandlers;
begin
  if Assigned(VmOpHandlers[opPushConst]) then Exit;
  VmOpHandlers[opPushConst] := @VmPushConst;
  VmOpHandlers[opPushNil] := @VmPushNil;
  VmOpHandlers[opPop] := @VmPop;
  VmOpHandlers[opDup] := @VmDup;
  VmOpHandlers[opDup2] := @VmDup2;
  VmOpHandlers[opLoadGlobal] := @VmLoadGlobal;
  VmOpHandlers[opStoreGlobal] := @VmStoreGlobal;
  VmOpHandlers[opLoadLocal] := @VmLoadLocal;
  VmOpHandlers[opStoreLocal] := @VmStoreLocal;
  VmOpHandlers[opAdd] := @VmAdd;
  VmOpHandlers[opSub] := @VmSub;
  VmOpHandlers[opMul] := @VmMul;
  VmOpHandlers[opDivReal] := @VmDivReal;
  VmOpHandlers[opDivInt] := @VmDivInt;
  VmOpHandlers[opMod] := @VmMod;
  VmOpHandlers[opNeg] := @VmNeg;
  VmOpHandlers[opEq] := @VmEq;
  VmOpHandlers[opNe] := @VmNe;
  VmOpHandlers[opLt] := @VmLt;
  VmOpHandlers[opLe] := @VmLe;
  VmOpHandlers[opGt] := @VmGt;
  VmOpHandlers[opGe] := @VmGe;
  VmOpHandlers[opNot] := @VmNot;
  VmOpHandlers[opJump] := @VmJump;
  VmOpHandlers[opJumpFalse] := @VmJumpFalse;
  VmOpHandlers[opJumpTrue] := @VmJumpTrue;
  VmOpHandlers[opCall] := @VmCall;
  VmOpHandlers[opReturn] := @VmReturn;
  VmOpHandlers[opMakeArray] := @VmMakeArray;
  VmOpHandlers[opMakeSet] := @VmMakeSet;
  VmOpHandlers[opIndexGet] := @VmIndexGet;
  VmOpHandlers[opIndexSet] := @VmIndexSet;
  VmOpHandlers[opFieldGet] := @VmFieldGet;
  VmOpHandlers[opFieldSet] := @VmFieldSet;
  VmOpHandlers[opNewPointer] := @VmNewPointer;
  VmOpHandlers[opDeref] := @VmDeref;
  VmOpHandlers[opSetDeref] := @VmSetDeref;
  VmOpHandlers[opDisposePointer] := @VmDisposePointer;
end;

function TLfpExecutionFrame.Step(InstructionIndex: Integer): Integer;
var
  Inst: TLfpInstruction;
  Handler: TLfpVmOpHandler;
begin
  Inst := InstructionAt(InstructionIndex);
  TraceInstruction(InstructionIndex, Inst);
  Handler := VmOpHandlers[Inst.Op];
  if not Assigned(Handler) then
    raise ELfpRuntimeError.CreateFmt('no VM handler for opcode %s',
      [LfpOpcodeName(Inst.Op)]);
  Result := Handler(Self, Inst);
end;

function TLfpExecutionFrame.RunInterpreter: TLfpValue;
var
  IP, Branch: Integer;
  Inst: TLfpInstruction;
begin
  FRunningJit := False;
  IP := 0;
  while IP < Length(FFunc.Code) do
  begin
    Inst := FFunc.Code[IP];
    try
      Branch := Step(IP);
    except
      on E: ELfpHalt do raise;
      on E: Exception do
        raise ELfpRuntimeError.CreateFmt('%s:%d:%d in %s: %s',
          [Inst.Pos.FileName, Inst.Pos.Line, Inst.Pos.Column,
           FFunc.Name, E.Message]);
    end;
    case Inst.Op of
      opJump: IP := Inst.A;
      opJumpFalse:
        if Branch = 0 then IP := Inst.A else Inc(IP);
      opJumpTrue:
        if Branch <> 0 then IP := Inst.A else Inc(IP);
      opReturn: Exit(FResult);
    else
      Inc(IP);
    end;
  end;
  Finish;
  Result := FResult;
end;

function JitExecuteHandler(Context: Pointer; InstructionIndex: LongInt;
  HandlerData: Pointer): LongInt; cdecl;
var
  Frame: TLfpExecutionFrame;
  Inst: TLfpInstruction;
  Handler: TLfpVmOpHandler;
begin
  Frame := TLfpExecutionFrame(Context);
  try
    Inst := Frame.InstructionAt(InstructionIndex);
    Frame.TraceInstruction(InstructionIndex, Inst);
    Handler := TLfpVmOpHandler(HandlerData);
    if not Assigned(Handler) then
      raise ELfpRuntimeError.CreateFmt(
        'no JIT handler for opcode %s', [LfpOpcodeName(Inst.Op)]);
    Result := Handler(Frame, Inst);
  except
    on E: ELfpHalt do
    begin
      Frame.FHalted := True;
      Frame.FHaltCode := E.ExitCode;
      Result := -1;
    end;
    on E: Exception do
    begin
      Frame.StoreError(InstructionIndex, E);
      Result := -1;
    end;
  end;
end;

function TLfpExecutionFrame.RunJit(Code: TLfpJitCode): TLfpValue;
begin
  FRunningJit := True;
  FFailed := False;
  FHalted := False;
  Code.Execute(Self);
  if FHalted then raise ELfpHalt.CreateCode(FHaltCode);
  if FFailed then raise ELfpRuntimeError.Create(FErrorMessage);
  if not FReturned then Finish;
  Result := FResult;
end;

function TLfpEngine.EnsureJitCode(Func: TLfpBytecodeFunction): Boolean;
var
  Blocks: TLfpJitBlockArray;
  I: Integer;
begin
  if Assigned(Func.FJitCode) then Exit(True);
  if not FJitUsable then
  begin
    if FJitMode = jmOn then raise ELfpJitError.Create(FJitMessage);
    Exit(False);
  end;
  SetLength(Blocks, Length(Func.Code));
  for I := 0 to High(Func.Code) do
  begin
    Blocks[I].Target := Func.Code[I].A;
    Blocks[I].HandlerData := Pointer(VmOpHandlers[Func.Code[I].Op]);
    case Func.Code[I].Op of
      opJump: Blocks[I].Kind := jbJump;
      opJumpFalse: Blocks[I].Kind := jbJumpFalse;
      opJumpTrue: Blocks[I].Kind := jbJumpTrue;
      opReturn: Blocks[I].Kind := jbReturn;
    else
      Blocks[I].Kind := jbStep;
    end;
  end;
  try
    Func.FJitCode := TLfpJitCode.Create(Blocks, @JitExecuteHandler);
    Inc(FJitCompiledFunctions);
    Inc(FJitCompiledBytes, Func.FJitCode.Size);
    Result := True;
  except
    on E: Exception do
    begin
      FJitUsable := False;
      FJitMessage := E.Message;
      if FJitMode = jmOn then
        raise ELfpJitError.Create('JIT unavailable: ' + E.Message);
      Result := False;
    end;
  end;
end;

function TLfpEngine.ExecuteFunction(Func: TLfpBytecodeFunction;
  const Args: TLfpValueArray): TLfpValue;
var
  Frame: TLfpExecutionFrame;
begin
  Frame := TLfpExecutionFrame.Create(Self, Func, Args);
  try
    if (FJitMode <> jmOff) and EnsureJitCode(Func) then
    begin
      Inc(FJitExecutions);
      Result := Frame.RunJit(Func.FJitCode)
    end
    else
      Result := Frame.RunInterpreter;
  finally
    Frame.Free;
  end;
end;

function TLfpEngine.GlobalsReport: string;
var
  I: Integer;
  B: TLfpBinding;
  Mutability: string;
begin
  Result := '';
  for I := 0 to FGlobals.Count - 1 do
  begin
    B := TLfpBinding(FGlobals.Objects[I]);
    if B.Mutable then Mutability := 'var' else Mutability := 'const';
    Result := Result + Format('%-9s %-24s : %-14s %s',
      [Mutability, B.Name, B.DeclaredType, LfpValueInspect(GetGlobal(B.Name))]);
    if I < FGlobals.Count - 1 then Result := Result + LineEnding;
  end;
end;

function TLfpEngine.TypesReport: string;
var
  I: Integer;
  D: TLfpTypeDef;
  KindName: string;
begin
  Result := 'builtins: Integer Int64 LongInt Byte Word Cardinal Real Double Single Boolean String Char Pointer Variant Array Set';
  for I := 0 to FTypes.Count - 1 do
  begin
    D := TLfpTypeDef(FTypes.Objects[I]);
    case D.Kind of
      tdAlias: KindName := 'alias';
      tdRecord: KindName := 'record';
      tdEnum: KindName := 'enum';
    else
      KindName := 'type';
    end;
    Result := Result + LineEnding + Format('%-8s %s', [KindName, D.Name]);
  end;
end;

function TLfpEngine.SearchPathsReport: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FSearchPaths.Count - 1 do
  begin
    Result := Result + FSearchPaths[I];
    if I < FSearchPaths.Count - 1 then Result := Result + LineEnding;
  end;
end;

function TLfpEngine.JitStatus: string;
var
  Stats: string;
begin
  Stats := Format('; %s function(s), %s byte(s), %s execution(s)',
    [UIntToStr(FJitCompiledFunctions), UIntToStr(FJitCompiledBytes),
     UIntToStr(FJitExecutions)]);
  case FJitMode of
    jmOff: Result := 'off (bytecode interpreter)' + Stats;
    jmOn:
      if FJitUsable then Result := 'on (' + FJitMessage + ')' + Stats
      else Result := 'unavailable (' + FJitMessage + ')' + Stats;
    jmAuto:
      if FJitUsable then Result := 'auto (' + FJitMessage + ')' + Stats
      else Result := 'auto fallback (' + FJitMessage + ')' + Stats;
  end;
end;

procedure TLfpEngine.SetJitMode(Mode: TLfpJitMode);
begin
  if (Mode = jmOn) and not FJitUsable then
    raise ELfpJitError.Create('JIT unavailable: ' + FJitMessage);
  FJitMode := Mode;
end;

function TypeNodeText(N: TLfpNode): string;
begin
  if N.Kind = nkAtom then Result := UTF8Encode(N.Text) else Result := N.DebugString;
end;

procedure RegisterTopLevelTypes(Engine: TLfpEngine; Forms: TObjectList);
var
  I, J, K: Integer;
  N, D, P: TLfpNode;
  Head, Name, TName: string;
  RT: TLfpRecordTypeDef;
  ET: TLfpEnumTypeDef;
  AT: TLfpAliasTypeDef;
  Ctor: TLfpRecordConstructorObject;
  EnumV: TLfpEnumValueObject;
begin
  for I := 0 to Forms.Count - 1 do
  begin
    N := TLfpNode(Forms[I]);
    if (N.Kind <> nkList) or (N.Count = 0) or (N.Child(0).Kind <> nkAtom) then Continue;
    Head := LowerCase(UTF8Encode(N.Child(0).Text));
    if Head <> 'type' then Continue;
    for J := 1 to N.Count - 1 do
    begin
      D := N.Child(J);
      if (D.Kind <> nkList) or (D.Count < 2) then
        raise ELfpCompileError.Create(LfpPosString(D.Pos) + ': malformed type declaration');
      if D.Child(0).IsAtom('record') then
      begin
        Name := NodeAtomText(D.Child(1), 'record name');
        RT := TLfpRecordTypeDef.Create(Name);
        for K := 2 to D.Count - 1 do
        begin
          P := D.Child(K);
          if (P.Kind <> nkList) or (P.Count <> 2) then
            raise ELfpCompileError.Create(LfpPosString(P.Pos) + ': record field must be (name Type)');
          RT.AddField(NodeAtomText(P.Child(0), 'field name'), TypeNodeText(P.Child(1)));
        end;
        Engine.RegisterType(RT);
        Ctor := TLfpRecordConstructorObject(Engine.OwnObject(TLfpRecordConstructorObject.Create(RT)));
        Engine.DefineGlobal(Name, 'Variant', False, LfpObject(Ctor), True);
      end
      else if D.Child(0).IsAtom('enum') then
      begin
        Name := NodeAtomText(D.Child(1), 'enum name');
        ET := TLfpEnumTypeDef.Create(Name);
        for K := 2 to D.Count - 1 do ET.AddMember(NodeAtomText(D.Child(K), 'enum member'));
        Engine.RegisterType(ET);
        for K := 0 to ET.Members.Count - 1 do
        begin
          EnumV := TLfpEnumValueObject(Engine.OwnObject(TLfpEnumValueObject.Create(Name, ET.Members[K], K)));
          Engine.DefineGlobal(ET.Members[K], Name, False, LfpObject(EnumV), True);
        end;
      end
      else
      begin
        Name := NodeAtomText(D.Child(0), 'type name');
        if D.Count <> 2 then
          raise ELfpCompileError.Create(LfpPosString(D.Pos) + ': alias type must be (Name TargetType)');
        TName := TypeNodeText(D.Child(1));
        AT := TLfpAliasTypeDef.Create(Name, TName);
        Engine.RegisterType(AT);
      end;
    end;
  end;
end;

procedure PredeclareRoutines(Engine: TLfpEngine; Forms: TObjectList;
  RoutineNodes: TList; RoutineFuncs: TList);
var
  I, J: Integer;
  N, Params, P: TLfpNode;
  Head, Name, TName: string;
  F: TLfpBytecodeFunction;
begin
  for I := 0 to Forms.Count - 1 do
  begin
    N := TLfpNode(Forms[I]);
    if (N.Kind <> nkList) or (N.Count = 0) or (N.Child(0).Kind <> nkAtom) then Continue;
    Head := LowerCase(UTF8Encode(N.Child(0).Text));
    if (Head <> 'function') and (Head <> 'procedure') then Continue;
    if N.Count < 4 then raise ELfpCompileError.Create(LfpPosString(N.Pos) + ': malformed routine');
    Name := NodeAtomText(N.Child(1), 'routine name');
    Params := N.Child(2);
    if Params.Kind <> nkList then raise ELfpCompileError.Create(LfpPosString(Params.Pos) + ': parameter list must be a list');
    F := TLfpBytecodeFunction(Engine.OwnObject(TLfpBytecodeFunction.Create(Name)));
    F.IsProcedure := Head = 'procedure';
    if F.IsProcedure then F.ReturnTypeName := 'Variant'
    else
    begin
      if N.Count < 5 then raise ELfpCompileError.Create(LfpPosString(N.Pos) + ': function requires return type and body');
      F.ReturnTypeName := TypeNodeText(N.Child(3));
    end;
    for J := 0 to Params.Count - 1 do
    begin
      P := Params.Child(J);
      if (P.Kind <> nkList) or (P.Count <> 2) then
        raise ELfpCompileError.Create(LfpPosString(P.Pos) + ': parameter must be (name Type)');
      TName := TypeNodeText(P.Child(1));
      F.AddParam(NodeAtomText(P.Child(0), 'parameter name'), TName);
    end;
    Engine.DefineGlobal(Name, 'Variant', False, LfpObject(F), True);
    RoutineNodes.Add(N);
    RoutineFuncs.Add(F);
  end;
end;

procedure CompileRoutineBodies(Engine: TLfpEngine; RoutineNodes, RoutineFuncs: TList);
var
  I, J, BodyStart: Integer;
  N: TLfpNode;
  F: TLfpBytecodeFunction;
  C: TLfpCompiler;
begin
  for I := 0 to RoutineNodes.Count - 1 do
  begin
    N := TLfpNode(RoutineNodes[I]);
    F := TLfpBytecodeFunction(RoutineFuncs[I]);
    if F.IsProcedure then BodyStart := 3 else BodyStart := 4;
    C := TLfpCompiler.Create(Engine, F, False);
    try
      if N.Count <= BodyStart then F.Emit(opPushNil, 0, 0, N.Pos)
      else
        for J := BodyStart to N.Count - 1 do
        begin
          C.Compile(N.Child(J));
          if J < N.Count - 1 then F.Emit(opPop, 0, 0, N.Child(J).Pos);
        end;
      F.Emit(opReturn, 0, 0, N.Pos);
      C.Finish;
    finally
      C.Free;
    end;
  end;
end;

function FlattenProgramForms(Forms: TObjectList; out Borrowed: Boolean): TObjectList;
var
  N: TLfpNode;
  I: Integer;
begin
  Borrowed := False;
  if Forms.Count = 1 then
  begin
    N := TLfpNode(Forms[0]);
    if N.HeadIs('program') or N.HeadIs('unit') then
    begin
      Result := TObjectList.Create(False);
      Borrowed := True;
      for I := 2 to N.Count - 1 do Result.Add(N.Child(I));
      Exit;
    end;
  end;
  Result := Forms;
end;

procedure ProcessUses(Engine: TLfpEngine; Forms: TObjectList);
var I, J: Integer; N: TLfpNode; Name: string;
begin
  for I := 0 to Forms.Count - 1 do
  begin
    N := TLfpNode(Forms[I]);
    if not N.HeadIs('uses') then Continue;
    for J := 1 to N.Count - 1 do
    begin
      if N.Child(J).Kind in [nkAtom, nkString] then Name := UTF8Encode(N.Child(J).Text)
      else raise ELfpCompileError.Create(LfpPosString(N.Child(J).Pos) + ': uses item must be name or string');
      Engine.RequireUnit(Name);
    end;
  end;
end;

function CompileSourceToMain(Engine: TLfpEngine; const Source: UnicodeString;
  const FileName: string): TLfpBytecodeFunction;
var
  P: TLfpParser;
  Parsed, Forms, TempForms: TObjectList;
  Borrowed: Boolean;
  RNodes, RFuncs: TList;
  C: TLfpCompiler;
  I: Integer;
  Main: TLfpBytecodeFunction;
begin
  P := TLfpParser.Create(Source, FileName);
  Parsed := nil; Forms := nil; TempForms := nil;
  RNodes := TList.Create; RFuncs := TList.Create;
  try
    Parsed := P.ParseAll;
    Forms := FlattenProgramForms(Parsed, Borrowed);
    if Borrowed then TempForms := Forms;
    ProcessUses(Engine, Forms);
    RegisterTopLevelTypes(Engine, Forms);
    PredeclareRoutines(Engine, Forms, RNodes, RFuncs);
    CompileRoutineBodies(Engine, RNodes, RFuncs);

    Main := TLfpBytecodeFunction(Engine.OwnObject(TLfpBytecodeFunction.Create('<main>')));
    Main.ReturnTypeName := 'Variant';
    C := TLfpCompiler.Create(Engine, Main, True);
    try
      if Forms.Count = 0 then Main.Emit(opPushNil, 0, 0, ZeroSourcePos)
      else
      begin
        for I := 0 to Forms.Count - 1 do
        begin
          C.Compile(TLfpNode(Forms[I]));
          if I < Forms.Count - 1 then Main.Emit(opPop, 0, 0, TLfpNode(Forms[I]).Pos);
        end;
      end;
      Main.Emit(opReturn, 0, 0, ZeroSourcePos);
      C.Finish;
    finally
      C.Free;
    end;
    Result := Main;
  finally
    RFuncs.Free; RNodes.Free;
    TempForms.Free;
    Parsed.Free;
    P.Free;
  end;
end;

function TLfpEngine.Eval(const Source: UnicodeString; const FileName: string): TLfpValue;
var Main: TLfpBytecodeFunction; Empty: TLfpValueArray;
begin
  Main := CompileSourceToMain(Self, Source, FileName);
  SetLength(Empty, 0);
  FLastResult := ExecuteFunction(Main, Empty);
  Result := FLastResult;
end;

function TLfpEngine.EvalFile(const FileName: string): TLfpValue;
var Ext, Full: string;
begin
  Full := ExpandFileName(FileName);
  if not FileExists(Full) then raise ELfpRuntimeError.Create('file not found: ' + FileName);
  Ext := LowerCase(ExtractFileExt(Full));
  if (Ext <> '.lfp') and (Ext <> '.lpas') then
    raise ELfpRuntimeError.Create('Lispal source must use .lfp or .lpas: ' + FileName);
  AddSearchPath(ExtractFileDir(Full));
  Result := Eval(ReadTextFile(Full), Full);
end;

function FindCaseInsensitiveFile(const Candidate: string): string;
var
  DirName, BaseName: string;
  SR: TSearchRec;
begin
  if FileExists(Candidate) then Exit(ExpandFileName(Candidate));
  DirName := ExtractFileDir(Candidate);
  if DirName = '' then DirName := '.';
  if not DirectoryExists(DirName) then Exit('');
  BaseName := ExtractFileName(Candidate);
  if FindFirst(IncludeTrailingPathDelimiter(DirName) + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if SameText(SR.Name, BaseName) then
        Exit(ExpandFileName(IncludeTrailingPathDelimiter(DirName) + SR.Name));
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  Result := '';
end;

function TryUnitNameAtPath(const SearchPath, UnitName: string): string;
var
  Base, Dotted: string;
begin
  Base := IncludeTrailingPathDelimiter(SearchPath) + UnitName;
  if ExtractFileExt(Base) <> '' then
  begin
    Result := FindCaseInsensitiveFile(Base);
    if Result <> '' then Exit;
  end
  else
  begin
    Result := FindCaseInsensitiveFile(Base + '.lfp');
    if Result <> '' then Exit;
    Result := FindCaseInsensitiveFile(Base + '.lpas');
    if Result <> '' then Exit;
  end;
  Dotted := StringReplace(UnitName, '.', DirectorySeparator, [rfReplaceAll]);
  if Dotted <> UnitName then
  begin
    Base := IncludeTrailingPathDelimiter(SearchPath) + Dotted;
    Result := FindCaseInsensitiveFile(Base + '.lfp');
    if Result <> '' then Exit;
    Result := FindCaseInsensitiveFile(Base + '.lpas');
    if Result <> '' then Exit;
    Dotted := Copy(UnitName, LastDelimiter('.', UnitName) + 1, MaxInt);
    Base := IncludeTrailingPathDelimiter(SearchPath) + Dotted;
    Result := FindCaseInsensitiveFile(Base + '.lfp');
    if Result <> '' then Exit;
    Result := FindCaseInsensitiveFile(Base + '.lpas');
    if Result <> '' then Exit;
  end;
  Result := '';
end;

function TLfpEngine.ResolveUnitFile(const Name: string): string;
var
  I: Integer;
  N: string;
begin
  N := FindCaseInsensitiveFile(Name);
  if N <> '' then Exit(N);
  for I := 0 to FSearchPaths.Count - 1 do
  begin
    N := TryUnitNameAtPath(FSearchPaths[I], Name);
    if N <> '' then Exit(N);
  end;
  Result := '';
end;

procedure CollectUnitDeclarations(const Source: UnicodeString; const FileName: string;
  Globals, TypeNames: TStrings; out DeclaredUnitName: string);
var
  P: TLfpParser;
  Parsed, Forms, TempForms: TObjectList;
  Borrowed: Boolean;
  I, J, K: Integer;
  N, D: TLfpNode;
  Head, Name: string;
begin
  DeclaredUnitName := ChangeFileExt(ExtractFileName(FileName), '');
  P := TLfpParser.Create(Source, FileName);
  Parsed := nil;
  Forms := nil;
  TempForms := nil;
  try
    Parsed := P.ParseAll;
    if Parsed.Count = 1 then
    begin
      N := TLfpNode(Parsed[0]);
      if N.HeadIs('unit') and (N.Count >= 2) and (N.Child(1).Kind = nkAtom) then
        DeclaredUnitName := UTF8Encode(N.Child(1).Text);
    end;
    Forms := FlattenProgramForms(Parsed, Borrowed);
    if Borrowed then TempForms := Forms;
    for I := 0 to Forms.Count - 1 do
    begin
      N := TLfpNode(Forms[I]);
      if (N.Kind <> nkList) or (N.Count = 0) or (N.Child(0).Kind <> nkAtom) then Continue;
      Head := LowerCase(UTF8Encode(N.Child(0).Text));
      if (Head = 'function') or (Head = 'procedure') then
      begin
        if (N.Count > 1) and (N.Child(1).Kind = nkAtom) then
          Globals.Add(UTF8Encode(N.Child(1).Text));
      end
      else if Head = 'var' then
      begin
        for J := 1 to N.Count - 1 do
        begin
          D := N.Child(J);
          if (D.Kind = nkList) and (D.Count > 0) and (D.Child(0).Kind = nkAtom) then
            Globals.Add(UTF8Encode(D.Child(0).Text));
        end;
      end
      else if Head = 'const' then
      begin
        for J := 1 to N.Count - 1 do
        begin
          D := N.Child(J);
          if (D.Kind = nkList) and (D.Count > 0) and (D.Child(0).Kind = nkAtom) then
            Globals.Add(UTF8Encode(D.Child(0).Text));
        end;
      end
      else if Head = 'type' then
      begin
        for J := 1 to N.Count - 1 do
        begin
          D := N.Child(J);
          if (D.Kind <> nkList) or (D.Count < 2) then Continue;
          if D.Child(0).IsAtom('record') or D.Child(0).IsAtom('enum') then
          begin
            if D.Child(1).Kind <> nkAtom then Continue;
            Name := UTF8Encode(D.Child(1).Text);
            TypeNames.Add(Name);
            if D.Child(0).IsAtom('record') then Globals.Add(Name)
            else
              for K := 2 to D.Count - 1 do
                if D.Child(K).Kind = nkAtom then Globals.Add(UTF8Encode(D.Child(K).Text));
          end
          else if D.Child(0).Kind = nkAtom then
            TypeNames.Add(UTF8Encode(D.Child(0).Text));
        end;
      end;
    end;
  finally
    TempForms.Free;
    Parsed.Free;
    P.Free;
  end;
end;

procedure QualifyUnitExports(Engine: TLfpEngine; const UnitName: string;
  Globals, TypeNames: TStrings);
var
  I: Integer;
  Name, QName: string;
  B: TLfpBinding;
begin
  for I := 0 to Globals.Count - 1 do
  begin
    Name := Globals[I];
    B := Engine.GlobalBinding(Name);
    if not Assigned(B) then Continue;
    QName := UnitName + '.' + Name;
    if B.Mutable then Engine.DefineGlobalAlias(QName, B)
    else Engine.DefineGlobal(QName, B.DeclaredType, False, B.Value, True);
  end;
  for I := 0 to TypeNames.Count - 1 do
  begin
    Name := TypeNames[I];
    if Pos('.', Name) > 0 then Continue;
    QName := UnitName + '.' + Name;
    if not Assigned(Engine.FindTypeDef(QName)) and Assigned(Engine.FindTypeDef(Name)) then
      Engine.RegisterType(TLfpAliasTypeDef.Create(QName, Name));
  end;
end;

function TLfpEngine.RequireUnit(const Name: string): TLfpValue;
var
  FileName, Key, Source, DeclaredUnitName: string;
  LoadedIndex: Integer;
  Globals, TypeNames: TStringList;
begin
  FileName := ResolveUnitFile(Name);
  if FileName = '' then raise ELfpRuntimeError.Create('cannot find unit: ' + Name);
  Key := LowerCase(FileName);
  if FLoadedUnits.IndexOf(Key) >= 0 then Exit(LfpNil);
  FLoadedUnits.Add(Key);
  Globals := TStringList.Create;
  TypeNames := TStringList.Create;
  try
    Globals.CaseSensitive := False;
    Globals.Sorted := True;
    Globals.Duplicates := dupIgnore;
    TypeNames.CaseSensitive := False;
    TypeNames.Sorted := True;
    TypeNames.Duplicates := dupIgnore;
    Source := UTF8Encode(ReadTextFile(FileName));
    CollectUnitDeclarations(UTF8Decode(Source), FileName, Globals, TypeNames, DeclaredUnitName);
    try
      Result := EvalFile(FileName);
      QualifyUnitExports(Self, DeclaredUnitName, Globals, TypeNames);
    except
      LoadedIndex := FLoadedUnits.IndexOf(Key);
      if LoadedIndex >= 0 then FLoadedUnits.Delete(LoadedIndex);
      raise;
    end;
  finally
    TypeNames.Free;
    Globals.Free;
  end;
end;

function TLfpEngine.Disassemble(const Source: UnicodeString;
  const FileName: string): string;
var
  Main: TLfpBytecodeFunction;
  I: Integer;
  Inst: TLfpInstruction;
begin
  Main := CompileSourceToMain(Self, Source, FileName);
  Result := 'function ' + Main.Name + LineEnding;
  for I := 0 to High(Main.Code) do
  begin
    Inst := Main.Code[I];
    Result := Result + Format('%4d  %-16s %6d %6d', [I, LfpOpcodeName(Inst.Op), Inst.A, Inst.B]);
    if Inst.Op = opPushConst then Result := Result + '  ; ' + LfpValueInspect(Main.Constants[Inst.A]);
    if Inst.Op in [opLoadGlobal, opStoreGlobal, opFieldGet, opFieldSet] then
      Result := Result + '  ; ' + UTF8Encode(Main.Constants[Inst.A].StrValue);
    Result := Result + LineEnding;
  end;
end;

initialization
  InitializeVmOpHandlers;

end.
