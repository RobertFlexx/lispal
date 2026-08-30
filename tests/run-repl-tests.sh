#!/bin/sh
set -eu
LFP=${1:-./bin/lfp}

out=$(printf '%s\n' '(+ 20' ' 22)' ':q' | "$LFP" --no-jit --repl 2>&1)
printf '%s\n' "$out" | grep -F '=> 42' >/dev/null
printf 'ok - repl multiline\n'

out=$(printf '%s\n' '(+ 1' ':cancel' '(+ 2 3)' ':q' | "$LFP" --no-jit --repl 2>&1)
printf '%s\n' "$out" | grep -F 'cancelled' >/dev/null
printf '%s\n' "$out" | grep -F '=> 5' >/dev/null
printf 'ok - repl cancel\n'

out=$(printf '%s\n' '(var (x Integer 7))' ':inspect x' ':types' ':globals' ':last' ':jit off' ':q' | "$LFP" --no-jit --repl 2>&1)
printf '%s\n' "$out" | grep -F 'x : integer = 7' >/dev/null || printf '%s\n' "$out" | grep -F 'x : Integer = 7' >/dev/null
printf '%s\n' "$out" | grep -F 'builtins:' >/dev/null
printf '%s\n' "$out" | grep -F 'off (bytecode interpreter)' >/dev/null
printf 'ok - repl commands\n'

out=$(printf '%s\n' ':paste' '(var (pasted Integer 40))' '(+ pasted 2)' ':end' ':inspect pasted' ':q' | "$LFP" --no-jit --repl 2>&1)
printf '%s\n' "$out" | grep -F '=> 42' >/dev/null
printf '%s\n' "$out" | grep -F 'pasted : Integer = 40' >/dev/null
printf 'ok - repl paste mode\n'

out=$(printf '\033[200~(+ 20\n 22)\033[201~\n:q\n' | "$LFP" --no-jit --repl 2>&1)
printf '%s\n' "$out" | grep -F '=> 42' >/dev/null
printf 'ok - repl bracketed paste\n'

out=$(printf '%s\n' '(+ 6 7)' ':history 1' ':again 1' ':q' | "$LFP" --no-jit --repl 2>&1)
printf '%s\n' "$out" | grep -F '   1  (+ 6 7)' >/dev/null
[ "$(printf '%s\n' "$out" | grep -cF '=> 13')" -eq 2 ]
printf 'ok - repl history\n'

printf 'repl tests passed\n'
