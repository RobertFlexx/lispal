#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(cat "$ROOT/VERSION")

OLD_IFS=$IFS
IFS=.
set -- $VERSION
IFS=$OLD_IFS

if [ "$#" -ne 3 ]; then
    printf 'release metadata: VERSION must be major.minor.patch\n' >&2
    exit 1
fi

for PART in "$@"; do
    case $PART in
        ''|*[!0-9]*)
            printf 'release metadata: VERSION must contain only numeric components\n' >&2
            exit 1
            ;;
    esac
done

MAJOR=$1
MINOR=$2
PATCH=$3

require_line() {
    FILE=$1
    LINE=$2
    if ! grep -Fqx "$LINE" "$FILE"; then
        printf 'release metadata: missing %s in %s\n' "$LINE" "${FILE#"$ROOT"/}" >&2
        exit 1
    fi
}

require_text() {
    FILE=$1
    TEXT=$2
    if ! grep -Fq "$TEXT" "$FILE"; then
        printf 'release metadata: missing %s in %s\n' "$TEXT" "${FILE#"$ROOT"/}" >&2
        exit 1
    fi
}

require_line "$ROOT/src/lfp.pas" "  LFP_VERSION = '$VERSION';"
require_line "$ROOT/src/lfp_capi.pas" "  Result := '$VERSION';"
require_line "$ROOT/include/lispal.h" "#define LFP_VERSION_MAJOR $MAJOR"
require_line "$ROOT/include/lispal.h" "#define LFP_VERSION_MINOR $MINOR"
require_line "$ROOT/include/lispal.h" "#define LFP_VERSION_PATCH $PATCH"
require_line "$ROOT/lispal.pc" "Version: $VERSION"
require_text "$ROOT/tests/c_api.c" "strcmp(lfp_version(), \"$VERSION\")"

printf 'ok - release metadata %s\n' "$VERSION"
