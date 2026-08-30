unit lfp_jit;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  ELfpJitError = class(Exception);

  TLfpJitBlockKind = (
    jbStep,
    jbJump,
    jbJumpFalse,
    jbJumpTrue,
    jbReturn
  );

  TLfpJitBlock = record
    Kind: TLfpJitBlockKind;
    Target: Integer;
    HandlerData: Pointer;
  end;

  TLfpJitBlockArray = array of TLfpJitBlock;
  TLfpJitHandler = function(Context: Pointer; InstructionIndex: LongInt;
    HandlerData: Pointer): LongInt; cdecl;
  TLfpJitEntry = function(Context: Pointer): LongInt; cdecl;

  TLfpJitCode = class
  private
    FMemory: Pointer;
    FSize: PtrUInt;
    FEntry: TLfpJitEntry;
  public
    constructor Create(const Blocks: TLfpJitBlockArray;
      Handler: TLfpJitHandler);
    destructor Destroy; override;
    function Execute(Context: Pointer): LongInt;
    property Size: PtrUInt read FSize;
  end;

function LfpJitSupported: Boolean;
function LfpJitPlatform: string;

implementation

{$if defined(linux) and defined(cpux86_64)}

uses
  BaseUnix;

const
  MAP_FAILED = Pointer(-1);

type
  TByteArray = array of Byte;
  TIntegerArray = array of Integer;

procedure EmitByte(var Code: TByteArray; Value: Byte);
var
  N: Integer;
begin
  N := Length(Code);
  SetLength(Code, N + 1);
  Code[N] := Value;
end;

procedure EmitInt32(var Code: TByteArray; Value: LongInt);
var
  I: Integer;
begin
  for I := 0 to 3 do
    EmitByte(Code, Byte((LongWord(Value) shr (I * 8)) and $ff));
end;

procedure EmitUInt64(var Code: TByteArray; Value: QWord);
var
  I: Integer;
begin
  for I := 0 to 7 do
    EmitByte(Code, Byte((Value shr (I * 8)) and $ff));
end;

procedure PatchRelative(var Code: TByteArray; DisplacementOffset,
  TargetOffset: Integer);
var
  I: Integer;
  Distance: LongInt;
begin
  Distance := TargetOffset - (DisplacementOffset + 4);
  for I := 0 to 3 do
    Code[DisplacementOffset + I] :=
      Byte((LongWord(Distance) shr (I * 8)) and $ff);
end;

procedure EmitCallHandler(var Code: TByteArray; InstructionIndex: Integer;
  HandlerData: Pointer; Handler: TLfpJitHandler);
begin
  EmitByte(Code, $4c); EmitByte(Code, $89); EmitByte(Code, $e7);
  EmitByte(Code, $be); EmitInt32(Code, InstructionIndex);
  EmitByte(Code, $48); EmitByte(Code, $ba);
  EmitUInt64(Code, QWord(PtrUInt(HandlerData)));
  EmitByte(Code, $48); EmitByte(Code, $b8);
  EmitUInt64(Code, QWord(PtrUInt(Pointer(Handler))));
  EmitByte(Code, $ff); EmitByte(Code, $d0);
end;

function LfpJitSupported: Boolean;
begin
  Result := True;
end;

function LfpJitPlatform: string;
begin
  Result := 'x86-64 linux';
end;

constructor TLfpJitCode.Create(const Blocks: TLfpJitBlockArray;
  Handler: TLfpJitHandler);
var
  Code: TByteArray;
  Offsets, ExitFixups, BranchFixups, BranchTargets: TIntegerArray;
  I, EpilogueOffset, FixupOffset, ErrorCode: Integer;
  TargetOffset: Integer;

  procedure AddExitFixup(Offset: Integer);
  var Count: Integer;
  begin
    Count := Length(ExitFixups);
    SetLength(ExitFixups, Count + 1);
    ExitFixups[Count] := Offset;
  end;

  procedure AddBranchFixup(Offset, Target: Integer);
  var Count: Integer;
  begin
    Count := Length(BranchFixups);
    SetLength(BranchFixups, Count + 1);
    SetLength(BranchTargets, Count + 1);
    BranchFixups[Count] := Offset;
    BranchTargets[Count] := Target;
  end;

  procedure EmitErrorBranch;
  begin
    EmitByte(Code, $85); EmitByte(Code, $c0);
    EmitByte(Code, $0f); EmitByte(Code, $88);
    FixupOffset := Length(Code);
    EmitInt32(Code, 0);
    AddExitFixup(FixupOffset);
  end;

begin
  inherited Create;
  if not Assigned(Handler) then
    raise ELfpJitError.Create('JIT handler callback is not assigned');
  if Length(Blocks) = 0 then
    raise ELfpJitError.Create('cannot JIT-compile an empty function');

  SetLength(Offsets, Length(Blocks));
  SetLength(Code, 0);
  EmitByte(Code, $f3); EmitByte(Code, $0f);
  EmitByte(Code, $1e); EmitByte(Code, $fa);
  EmitByte(Code, $41); EmitByte(Code, $54);
  EmitByte(Code, $49); EmitByte(Code, $89); EmitByte(Code, $fc);

  for I := 0 to High(Blocks) do
  begin
    if not Assigned(Blocks[I].HandlerData) then
      raise ELfpJitError.CreateFmt(
        'JIT instruction %d has no semantic handler', [I]);
    Offsets[I] := Length(Code);
    EmitCallHandler(Code, I, Blocks[I].HandlerData, Handler);
    case Blocks[I].Kind of
      jbStep:
        EmitErrorBranch;
      jbJump:
        begin
          EmitErrorBranch;
          EmitByte(Code, $e9);
          FixupOffset := Length(Code);
          EmitInt32(Code, 0);
          AddBranchFixup(FixupOffset, Blocks[I].Target);
        end;
      jbJumpFalse,
      jbJumpTrue:
        begin
          EmitErrorBranch;
          EmitByte(Code, $85); EmitByte(Code, $c0);
          EmitByte(Code, $0f);
          if Blocks[I].Kind = jbJumpFalse then EmitByte(Code, $84)
          else EmitByte(Code, $85);
          FixupOffset := Length(Code);
          EmitInt32(Code, 0);
          AddBranchFixup(FixupOffset, Blocks[I].Target);
        end;
      jbReturn:
        begin
          EmitByte(Code, $e9);
          FixupOffset := Length(Code);
          EmitInt32(Code, 0);
          AddExitFixup(FixupOffset);
        end;
    end;
  end;

  EpilogueOffset := Length(Code);
  EmitByte(Code, $41); EmitByte(Code, $5c);
  EmitByte(Code, $c3);

  for I := 0 to High(ExitFixups) do
    PatchRelative(Code, ExitFixups[I], EpilogueOffset);
  for I := 0 to High(BranchFixups) do
  begin
    if (BranchTargets[I] < 0) or (BranchTargets[I] > Length(Blocks)) then
      raise ELfpJitError.CreateFmt('invalid JIT branch target %d',
        [BranchTargets[I]]);
    if BranchTargets[I] = Length(Blocks) then TargetOffset := EpilogueOffset
    else TargetOffset := Offsets[BranchTargets[I]];
    PatchRelative(Code, BranchFixups[I], TargetOffset);
  end;

  FSize := Length(Code);
  FMemory := FpMMap(nil, FSize, PROT_READ or PROT_WRITE,
    MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
  if FMemory = MAP_FAILED then
  begin
    ErrorCode := fpgeterrno;
    FMemory := nil;
    raise ELfpJitError.CreateFmt(
      'mmap failed while allocating %d JIT bytes: %s',
      [FSize, SysErrorMessage(ErrorCode)]);
  end;
  Move(Code[0], FMemory^, FSize);
  if FpMProtect(FMemory, FSize, PROT_READ or PROT_EXEC) <> 0 then
  begin
    ErrorCode := fpgeterrno;
    FpMunmap(FMemory, FSize);
    FMemory := nil;
    raise ELfpJitError.Create('mprotect failed while enabling JIT code: ' +
      SysErrorMessage(ErrorCode));
  end;
  FEntry := TLfpJitEntry(FMemory);
end;

destructor TLfpJitCode.Destroy;
begin
  if Assigned(FMemory) then
    FpMunmap(FMemory, FSize);
  inherited Destroy;
end;

function TLfpJitCode.Execute(Context: Pointer): LongInt;
begin
  if not Assigned(FEntry) then
    raise ELfpJitError.Create('JIT code has no entry point');
  Result := FEntry(Context);
end;

{$else}

function LfpJitSupported: Boolean;
begin
  Result := False;
end;

function LfpJitPlatform: string;
begin
  Result := 'unsupported platform';
end;

constructor TLfpJitCode.Create(const Blocks: TLfpJitBlockArray;
  Handler: TLfpJitHandler);
begin
  inherited Create;
  raise ELfpJitError.Create('native JIT is not available on this platform');
end;

destructor TLfpJitCode.Destroy;
begin
  inherited Destroy;
end;

function TLfpJitCode.Execute(Context: Pointer): LongInt;
begin
  Result := -1;
  raise ELfpJitError.Create('native JIT is not available on this platform');
end;

{$endif}

end.
