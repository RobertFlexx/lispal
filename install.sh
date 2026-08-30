#!/bin/sh
set -eu

make_command=${MAKE:-make}
destdir=${DESTDIR:-}
build=yes
check=no
action=install
jobs=
mode=

if [ "$(id -u)" -eq 0 ]; then
    prefix=${PREFIX:-/usr/local}
else
    if [ -n "${HOME:-}" ]; then
        prefix=${PREFIX:-$HOME/.local}
    else
        prefix=${PREFIX:-/usr/local}
    fi
fi

usage() {
    cat <<EOF
usage: ./install.sh [options]

  --user            install to ~/.local
  --system          install to /usr/local
  --prefix PATH     install somewhere else
  --destdir PATH    stage the install under PATH
  --jobs N          pass -jN to make
  --no-build        use an existing bin/ build
  --check           run the full test suite first
  --uninstall       remove the installed files
  -h, --help        show this help

without options, a normal user gets ~/.local and root gets /usr/local.
EOF
}

fail() {
    printf 'install: %s\n' "$*" >&2
    exit 2
}

need() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'install: missing required command: %s\n' "$1" >&2
        exit 127
    }
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --user)
            [ -n "${HOME:-}" ] || fail '--user needs HOME to be set'
            prefix=$HOME/.local
            mode=user
            shift
            ;;
        --system)
            prefix=/usr/local
            mode=system
            shift
            ;;
        --prefix)
            [ "$#" -ge 2 ] || fail '--prefix needs a path'
            prefix=$2
            mode=custom
            shift 2
            ;;
        --prefix=*)
            prefix=${1#*=}
            [ -n "$prefix" ] || fail '--prefix needs a path'
            mode=custom
            shift
            ;;
        --destdir)
            [ "$#" -ge 2 ] || fail '--destdir needs a path'
            destdir=$2
            shift 2
            ;;
        --destdir=*)
            destdir=${1#*=}
            shift
            ;;
        --jobs|-j)
            [ "$#" -ge 2 ] || fail "$1 needs a number"
            jobs=$2
            shift 2
            ;;
        -j[0-9]*)
            jobs=${1#-j}
            shift
            ;;
        --no-build)
            build=no
            shift
            ;;
        --check)
            check=yes
            shift
            ;;
        --uninstall)
            action=uninstall
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

case $prefix in
    /*) ;;
    *) fail '--prefix must be an absolute path' ;;
esac

if [ -n "$jobs" ]; then
    case $jobs in
        *[!0-9]*|'') fail '--jobs expects a positive integer' ;;
    esac
    [ "$jobs" -gt 0 ] || fail '--jobs expects a positive integer'
fi

need "$make_command"

if [ "$action" = uninstall ]; then
    printf 'removing lispal from %s%s\n' "$destdir" "$prefix"
    exec "$make_command" uninstall PREFIX="$prefix" DESTDIR="$destdir"
fi

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    if [ "$check" = yes ]; then
        fail 'run make check as your normal user, then install with sudo ./install.sh --no-build --system'
    fi
    if [ "$build" = yes ]; then
        if [ -x bin/lfp ] && [ -f bin/liblispal.so.1 ]; then
            build=no
            printf '%s\n' 'using the build already in bin/; not rebuilding it as root'
        else
            fail 'build as your normal user first, then run sudo ./install.sh --no-build --system'
        fi
    fi
fi

if [ "$build" = yes ] || [ "$check" = yes ]; then
    need fpc
fi
if [ "$check" = yes ]; then
    need cc
fi

make_args=
if [ -n "$jobs" ]; then
    make_args="-j$jobs"
fi

if [ "$check" = yes ]; then
    printf '%s\n' 'building and running the test suite'
    if [ -n "$make_args" ]; then
        "$make_command" "$make_args" check
    else
        "$make_command" check
    fi
elif [ "$build" = yes ]; then
    printf '%s\n' 'building lispal'
    if [ -n "$make_args" ]; then
        "$make_command" "$make_args" all
    else
        "$make_command" all
    fi
fi

[ -x bin/lfp ] || fail 'bin/lfp is missing; build the project first'
[ -f bin/liblispal.so.1 ] || fail 'bin/liblispal.so.1 is missing; build the project first'

printf 'installing lispal to %s%s\n' "$destdir" "$prefix"
"$make_command" install SKIP_BUILD=1 PREFIX="$prefix" DESTDIR="$destdir"

if [ -n "$destdir" ]; then
    printf '%s\n' 'staged install complete'
    exit 0
fi

printf 'installed: %s/bin/lfp\n' "$prefix"
printf 'rtl:       %s/lib/lfp/rtl\n' "$prefix"
case :${PATH:-}: in
    *:"$prefix/bin":*) ;;
    *)
        printf '\n%s\n' 'lfp is installed, but that bin directory is not in PATH yet.'
        printf 'add this to your shell profile:\n\n  export PATH="%s/bin:$PATH"\n' "$prefix"
        ;;
esac

if [ "$mode" = system ] || [ "$prefix" = /usr/local ]; then
    printf '\n%s\n' 'system install complete.'
fi
