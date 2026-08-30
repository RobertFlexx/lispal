library lispal;

{$mode objfpc}{$H+}

uses
  SysUtils, lfp_value, lfp_vm, lfp_embed;

type
  PLfpDouble = ^Double;
  PLfpLongBool = ^LongBool;
  PLispalHandle = ^TLispalHandle;
  TLispalHandle = record
    Runtime: TLispal;
    LastError: AnsiString;
    LastResult: AnsiString;
  end;

function ValidHandle(H: Pointer): PLispalHandle; inline;
begin
  Result := PLispalHandle(H);
end;

function lfp_create: Pointer; cdecl;
var
  H: PLispalHandle;
begin
  Result := nil;
  H := nil;
  try
    New(H);
    H^.Runtime := nil;
    H^.Runtime := TLispal.Create;
    H^.LastError := '';
    H^.LastResult := '';
    Result := H;
  except
    if Assigned(H) then
    begin
      H^.Runtime.Free;
      Dispose(H);
    end;
  end;
end;

procedure lfp_destroy(Handle: Pointer); cdecl;
var
  H: PLispalHandle;
begin
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  try
    H^.Runtime.Free;
  finally
    H^.Runtime := nil;
    Dispose(H);
  end;
end;

function lfp_eval(Handle: Pointer; Source, FileName: PChar): PChar; cdecl;
var
  H: PLispalHandle;
  V: TLfpValue;
  F: string;
begin
  Result := nil;
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  H^.LastError := '';
  H^.LastResult := '';
  try
    if FileName = nil then F := '<c-api>' else F := StrPas(FileName);
    if Source = nil then
      raise Exception.Create('source is null');
    V := H^.Runtime.Eval(UTF8Decode(StrPas(Source)), F);
    H^.LastResult := LfpValueInspect(V);
    Result := PChar(H^.LastResult);
  except
    on E: Exception do
    begin
      H^.LastError := E.Message;
      Result := nil;
    end;
  end;
end;

function lfp_eval_file(Handle: Pointer; FileName: PChar): PChar; cdecl;
var
  H: PLispalHandle;
  V: TLfpValue;
begin
  Result := nil;
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  H^.LastError := '';
  H^.LastResult := '';
  try
    if FileName = nil then
      raise Exception.Create('file name is null');
    V := H^.Runtime.EvalFile(StrPas(FileName));
    H^.LastResult := LfpValueInspect(V);
    Result := PChar(H^.LastResult);
  except
    on E: Exception do
    begin
      H^.LastError := E.Message;
      Result := nil;
    end;
  end;
end;

function lfp_last_error(Handle: Pointer): PChar; cdecl;
var
  H: PLispalHandle;
begin
  if Handle = nil then Exit(nil);
  H := ValidHandle(Handle);
  Result := PChar(H^.LastError);
end;

function lfp_set_integer(Handle: Pointer; Name: PChar; Value: Int64): LongBool; cdecl;
var
  H: PLispalHandle;
begin
  Result := False;
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  H^.LastError := '';
  try
    if Name = nil then raise Exception.Create('name is null');
    H^.Runtime.SetInteger(StrPas(Name), Value);
    Result := True;
  except
    on E: Exception do H^.LastError := E.Message;
  end;
end;

function lfp_get_integer(Handle: Pointer; Name: PChar; Value: PInt64): LongBool; cdecl;
var
  H: PLispalHandle;
begin
  Result := False;
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  H^.LastError := '';
  try
    if Name = nil then raise Exception.Create('name is null');
    if Value = nil then raise Exception.Create('output value is null');
    Value^ := H^.Runtime.GetInteger(StrPas(Name));
    Result := True;
  except
    on E: Exception do H^.LastError := E.Message;
  end;
end;


function lfp_set_real(Handle: Pointer; Name: PChar; Value: Double): LongBool; cdecl;
var
  H: PLispalHandle;
begin
  Result := False;
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  H^.LastError := '';
  try
    if Name = nil then raise Exception.Create('name is null');
    H^.Runtime.SetReal(StrPas(Name), Value);
    Result := True;
  except
    on E: Exception do H^.LastError := E.Message;
  end;
end;

function lfp_get_real(Handle: Pointer; Name: PChar; Value: PLfpDouble): LongBool; cdecl;
var
  H: PLispalHandle;
begin
  Result := False;
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  H^.LastError := '';
  try
    if Name = nil then raise Exception.Create('name is null');
    if Value = nil then raise Exception.Create('output value is null');
    Value^ := H^.Runtime.GetReal(StrPas(Name));
    Result := True;
  except
    on E: Exception do H^.LastError := E.Message;
  end;
end;

function lfp_set_boolean(Handle: Pointer; Name: PChar; Value: LongBool): LongBool; cdecl;
var
  H: PLispalHandle;
begin
  Result := False;
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  H^.LastError := '';
  try
    if Name = nil then raise Exception.Create('name is null');
    H^.Runtime.SetBoolean(StrPas(Name), Value);
    Result := True;
  except
    on E: Exception do H^.LastError := E.Message;
  end;
end;

function lfp_get_boolean(Handle: Pointer; Name: PChar; Value: PLfpLongBool): LongBool; cdecl;
var
  H: PLispalHandle;
begin
  Result := False;
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  H^.LastError := '';
  try
    if Name = nil then raise Exception.Create('name is null');
    if Value = nil then raise Exception.Create('output value is null');
    Value^ := H^.Runtime.GetBoolean(StrPas(Name));
    Result := True;
  except
    on E: Exception do H^.LastError := E.Message;
  end;
end;

function lfp_get_string(Handle: Pointer; Name: PChar): PChar; cdecl;
var
  H: PLispalHandle;
begin
  Result := nil;
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  H^.LastError := '';
  H^.LastResult := '';
  try
    if Name = nil then raise Exception.Create('name is null');
    H^.LastResult := UTF8Encode(H^.Runtime.GetString(StrPas(Name)));
    Result := PChar(H^.LastResult);
  except
    on E: Exception do H^.LastError := E.Message;
  end;
end;

function lfp_add_search_path(Handle: Pointer; Path: PChar): LongBool; cdecl;
var
  H: PLispalHandle;
begin
  Result := False;
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  H^.LastError := '';
  try
    if Path = nil then raise Exception.Create('path is null');
    H^.Runtime.AddSearchPath(StrPas(Path));
    Result := True;
  except
    on E: Exception do H^.LastError := E.Message;
  end;
end;

function lfp_set_string(Handle: Pointer; Name, Value: PChar): LongBool; cdecl;
var
  H: PLispalHandle;
begin
  Result := False;
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  H^.LastError := '';
  try
    if Name = nil then raise Exception.Create('name is null');
    if Value = nil then raise Exception.Create('value is null');
    H^.Runtime.SetString(StrPas(Name), UTF8Decode(StrPas(Value)));
    Result := True;
  except
    on E: Exception do H^.LastError := E.Message;
  end;
end;

function lfp_set_jit(Handle: Pointer; Mode: LongInt): LongBool; cdecl;
var
  H: PLispalHandle;
begin
  Result := False;
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  H^.LastError := '';
  try
    case Mode of
      -1: H^.Runtime.JitMode := jmAuto;
       0: H^.Runtime.JitMode := jmOff;
       1: H^.Runtime.JitMode := jmOn;
    else
      raise Exception.Create('JIT mode must be -1 (auto), 0 (off), or 1 (on)');
    end;
    Result := True;
  except
    on E: Exception do H^.LastError := E.Message;
  end;
end;

function lfp_jit_status(Handle: Pointer): PChar; cdecl;
var
  H: PLispalHandle;
begin
  Result := nil;
  if Handle = nil then Exit;
  H := ValidHandle(Handle);
  H^.LastError := '';
  try
    H^.LastResult := H^.Runtime.JitStatus;
    Result := PChar(H^.LastResult);
  except
    on E: Exception do H^.LastError := E.Message;
  end;
end;

function lfp_version: PChar; cdecl;
begin
  Result := '1.0.0';
end;

exports
  lfp_create,
  lfp_destroy,
  lfp_eval,
  lfp_eval_file,
  lfp_last_error,
  lfp_set_integer,
  lfp_get_integer,
  lfp_set_real,
  lfp_get_real,
  lfp_set_boolean,
  lfp_get_boolean,
  lfp_set_string,
  lfp_get_string,
  lfp_add_search_path,
  lfp_set_jit,
  lfp_jit_status,
  lfp_version;

begin
end.
