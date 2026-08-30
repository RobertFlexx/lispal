#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

count=$(grep -hEi '^\s*\((function|procedure)\s+' "$ROOT"/rtl/*.lpas | wc -l | tr -d ' ')
[ "$count" -ge 700 ] || {
    printf 'rtl surface is too small: %s routines\n' "$count" >&2
    exit 1
}

if grep -hEi '\b(compat[0-9]+|stub|placeholder|dummy|todo|fixme)\b' "$ROOT"/rtl/*.lpas >/dev/null; then
    printf 'rtl contains filler or unfinished markers\n' >&2
    exit 1
fi

for file in "$ROOT"/rtl/*.lpas; do
    base=$(basename "$file" .lpas)
    grep -Ei "^[[:space:]]*\(unit[[:space:]]+$base([[:space:]]|$)" "$file" >/dev/null || {
        printf 'rtl unit/file mismatch: %s\n' "$file" >&2
        exit 1
    }
    duplicates=$(
        sed -nE 's/^[[:space:]]*\((function|procedure)[[:space:]]+([^[:space:]()]+).*/\2/p' "$file" |
        tr '[:upper:]' '[:lower:]' |
        sort |
        uniq -d
    )
    [ -z "$duplicates" ] || {
        printf 'duplicate declarations in %s:\n%s\n' "$file" "$duplicates" >&2
        exit 1
    }
done

ops=$(sed -nE 's/.*__rtl[[:space:]]+"([^"]+)".*/\1/p' "$ROOT"/rtl/*.lpas | sort -u)
for op in $ops; do
    grep -F "'$op'" "$ROOT/src/lfp_vm.pas" >/dev/null || {
        printf 'missing rtl backend operation: %s\n' "$op" >&2
        exit 1
    }
done

printf 'ok - rtl static audit: %s routines\n' "$count"
