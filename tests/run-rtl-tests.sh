#!/bin/sh
set -eu
LFP=${1:-./bin/lfp}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

sh "$ROOT/tests/check-rtl.sh"

run_backend() {
    backend=$1
    name=$2
    expected=$3
    output=$(LFP_PATH="$ROOT/rtl" "$LFP" "$backend" "$ROOT/tests/$name.lfp")
    printf '%s\n' "$output" | grep -F "$expected" >/dev/null
    printf 'ok - %s rtl %s\n' "${backend#--}" "$name"
}

backends="--no-jit"
if LFP_PATH="$ROOT/rtl" "$LFP" --jit -e 'nil' >/dev/null 2>&1; then
    backends="$backends --jit"
fi

for backend in $backends; do
    run_backend "$backend" rtl_all_units rtl-all-units-ok
    run_backend "$backend" rtl_smoke rtl-smoke-ok
    run_backend "$backend" rtl_case_import rtl-case-import-ok
    output=$(LFP_PATH="$ROOT/rtl" "$LFP" "$backend" "$ROOT/tests/rtl_getopts_short.lfp" -a -b value -coptional tail)
    printf '%s\n' "$output" | grep -F 'rtl-getopts-short-ok' >/dev/null
    printf 'ok - %s rtl getopts-short\n' "${backend#--}"
    output=$(LFP_PATH="$ROOT/rtl" "$LFP" "$backend" "$ROOT/tests/rtl_getopts_long.lfp" -verbose --output=name)
    printf '%s\n' "$output" | grep -F 'rtl-getopts-long-ok' >/dev/null
    printf 'ok - %s rtl getopts-long\n' "${backend#--}"
done

count=$(grep -hEi '^[[:space:]]*\((function|procedure)[[:space:]]+' "$ROOT"/rtl/*.lpas | wc -l | tr -d ' ')
[ "$count" -ge 700 ]
printf 'ok - rtl surface %s routines\n' "$count"

printf 'rtl tests passed\n'
