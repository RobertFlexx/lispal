program embed_pascal;

{$mode objfpc}{$H+}

uses
  SysUtils, lfp_value, lfp_vm, lfp_embed;

function HostDouble(UserData: Pointer; Engine: TLfpEngine;
  const Args: TLfpValueArray): TLfpValue;
begin
  Result := LfpInt(LfpToInt(Args[0]) * 2);
end;

var
  L: TLispal;
  V: TLfpValue;
begin
  L := TLispal.Create;
  try
    L.JitMode := jmAuto;
    L.SetInteger('host-value', 21);
    L.RegisterFunction('host-double', @HostDouble, nil, 1, 1);
    V := L.Eval('(host-double host-value)');
    Writeln('result = ', LfpValueInspect(V));
  finally
    L.Free;
  end;
end.
