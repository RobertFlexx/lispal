#!/bin/sh
set -eu
LFP=${1:-./bin/lfp}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BACKEND=

invoke() {
    if [ -n "$BACKEND" ]; then
        "$LFP" "$BACKEND" "$@"
    else
        "$LFP" "$@"
    fi
}

run() {
    name=$1
    expected=$2
    output=$(invoke "$ROOT/tests/$name.lfp")
    printf '%s\n' "$output" | grep -F "$expected" >/dev/null
    printf 'ok - %s %s\n' "${BACKEND#--}" "$name"
}

BACKENDS="--no-jit"
if "$LFP" --jit -e 'nil' >/dev/null 2>&1; then
    BACKENDS="$BACKENDS --jit"
fi

for BACKEND in $BACKENDS; do
    run smoke smoke-ok
    run control case-ok
    run pointer pointer-ok
    run fixed_array fixed-array-ok
    run subrange subrange-ok
    run with_record with-ok
    run typed_set typed-set-ok
    run lexer_math lexer-math-ok
    run backend_coverage backend-coverage-ok
    run functional functional-ok
    run runtime runtime-ok

    out=$(invoke -e '(+ 20 22)')
    [ "$out" = "42" ]
    printf 'ok - %s eval\n' "${BACKEND#--}"

    error=$(invoke -e '(/ 1 0)' 2>&1 || true)
    printf '%s\n' "$error" | grep -F 'division by zero' >/dev/null
    printf 'ok - %s errors\n' "${BACKEND#--}"

    overflow=$(invoke -e '(+ 9223372036854775807 1)' 2>&1 || true)
    printf '%s\n' "$overflow" | grep -F 'integer overflow' >/dev/null
    printf 'ok - %s overflow\n' "${BACKEND#--}"

    char_output=$(invoke -e '#\space')
    [ "$char_output" = '#\space' ]
    printf 'ok - %s character output\n' "${BACKEND#--}"
done

BACKEND=
printf '%s\n' "$(invoke --jit-status)" | grep -E 'auto|off|on|fallback|unavailable' >/dev/null
printf 'ok - jit status\n'

printf 'all tests passed\n'
