unit lfp_embed;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, lfp_value, lfp_vm;

type
  TLispalNativeCallback = TLfpNativeCallback;

  TLispal = class
  private
    FEngine: TLfpEngine;
  public
    constructor Create;
    destructor Destroy; override;
    function Eval(const Source: UnicodeString;
      const FileName: string = '<embedded>'): TLfpValue;
    function EvalFile(const FileName: string): TLfpValue;
    procedure RegisterFunction(const Name: string; Callback: TLispalNativeCallback;
      UserData: Pointer = nil; MinArgs: Integer = 0; MaxArgs: Integer = -1);
    procedure SetValue(const Name, TypeName: string; const Value: TLfpValue);
    procedure SetInteger(const Name: string; Value: Int64);
    procedure SetReal(const Name: string; Value: Double);
    procedure SetBoolean(const Name: string; Value: Boolean);
    procedure SetString(const Name: string; const Value: UnicodeString);
    function GetValue(const Name: string): TLfpValue;
    function GetInteger(const Name: string): Int64;
    function GetReal(const Name: string): Double;
    function GetBoolean(const Name: string): Boolean;
    function GetString(const Name: string): UnicodeString;
    procedure AddSearchPath(const Path: string);
    procedure SetJitMode(Mode: TLfpJitMode);
    function GetJitMode: TLfpJitMode;
    function JitStatus: string;
    property Engine: TLfpEngine read FEngine;
    property JitMode: TLfpJitMode read GetJitMode write SetJitMode;
  end;

implementation

constructor TLispal.Create;
begin
  inherited Create;
  FEngine := TLfpEngine.Create;
end;

destructor TLispal.Destroy;
begin
  FEngine.Free;
  inherited Destroy;
end;

function TLispal.Eval(const Source: UnicodeString; const FileName: string): TLfpValue;
begin
  Result := FEngine.Eval(Source, FileName);
end;

function TLispal.EvalFile(const FileName: string): TLfpValue;
begin
  Result := FEngine.EvalFile(FileName);
end;

procedure TLispal.RegisterFunction(const Name: string;
  Callback: TLispalNativeCallback; UserData: Pointer; MinArgs, MaxArgs: Integer);
begin
  FEngine.RegisterNative(Name, Callback, UserData, MinArgs, MaxArgs);
end;

procedure TLispal.SetValue(const Name, TypeName: string; const Value: TLfpValue);
begin
  if FEngine.HasGlobal(Name) then
    FEngine.SetGlobal(Name, Value)
  else
    FEngine.DefineGlobal(Name, TypeName, True, Value);
end;

procedure TLispal.SetInteger(const Name: string; Value: Int64);
begin
  SetValue(Name, 'Integer', LfpInt(Value));
end;

procedure TLispal.SetReal(const Name: string; Value: Double);
begin
  SetValue(Name, 'Real', LfpReal(Value));
end;

procedure TLispal.SetBoolean(const Name: string; Value: Boolean);
begin
  SetValue(Name, 'Boolean', LfpBool(Value));
end;

procedure TLispal.SetString(const Name: string; const Value: UnicodeString);
begin
  SetValue(Name, 'String', LfpString(Value));
end;

function TLispal.GetValue(const Name: string): TLfpValue;
begin
  Result := FEngine.GetGlobal(Name);
end;

function TLispal.GetInteger(const Name: string): Int64;
var V: TLfpValue;
begin
  V := GetValue(Name);
  FEngine.RequireType(V, 'Integer', 'GetInteger(' + Name + ')');
  Result := V.IntValue;
end;

function TLispal.GetReal(const Name: string): Double;
var V: TLfpValue;
begin
  V := GetValue(Name);
  FEngine.RequireType(V, 'Real', 'GetReal(' + Name + ')');
  Result := LfpToReal(V);
end;

function TLispal.GetBoolean(const Name: string): Boolean;
var V: TLfpValue;
begin
  V := GetValue(Name);
  FEngine.RequireType(V, 'Boolean', 'GetBoolean(' + Name + ')');
  Result := V.BoolValue;
end;

function TLispal.GetString(const Name: string): UnicodeString;
var V: TLfpValue;
begin
  V := GetValue(Name);
  FEngine.RequireType(V, 'String', 'GetString(' + Name + ')');
  Result := V.StrValue;
end;

procedure TLispal.AddSearchPath(const Path: string);
begin
  FEngine.AddSearchPath(Path);
end;

procedure TLispal.SetJitMode(Mode: TLfpJitMode);
begin
  FEngine.JitMode := Mode;
end;

function TLispal.GetJitMode: TLfpJitMode;
begin
  Result := FEngine.JitMode;
end;

function TLispal.JitStatus: string;
begin
  Result := FEngine.JitStatus;
end;

end.
