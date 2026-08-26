#!/bin/sh
#
# Build a release binary in its own directory and install it.
#
# The build happens outside the source tree, in BUILD_DIR (release-build/ by
# default), for two reasons: the version here is a "next" version, so configure
# turns debug on by default, which is right for `rake tests` and wrong for
# something to actually use, and the install step may need sudo, which would
# otherwise leave root owned objects and generated man pages in the tree for
# every later unprivileged build to trip over.
#
# The directory is wiped first, so nothing is ever reused from an older build.
#
# Usage:
#   sh ./install.sh                     # /usr/local, the autotools default
#   PREFIX=/usr sh ./install.sh         # somewhere else
#   BUILD_DIR=/tmp/tmux sh ./install.sh # build somewhere else
#   JOBS=4 sh ./install.sh              # fewer compile jobs
#   CONFIGURE_ARGS="--disable-utf8proc" sh ./install.sh
#
# The install step is run with sudo when the target directory is not writable.

brew install jemalloc

set -eu

ROOT=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

PREFIX=${PREFIX:-/usr/local}
BUILD_DIR=${BUILD_DIR:-$ROOT/release-build}
CFLAGS=${CFLAGS:--O2}
CONFIGURE_ARGS=${CONFIGURE_ARGS:---disable-debug --enable-utf8proc}
MAKE=${MAKE:-$(command -v gmake >/dev/null 2>&1 && echo gmake || echo make)}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}

say() {
	printf '==> %s\n' "$*"
}

# sudo only when the install target is not writable, so an installation into a
# home directory does not ask for a password.
as_root() {
	dir=$PREFIX
	while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do
		dir=$(dirname "$dir")
	done

	if [ -w "$dir" ]; then
		"$@"
	elif command -v sudo >/dev/null 2>&1; then
		say "$1 needs root for $PREFIX, using sudo"
		sudo "$@"
	else
		printf 'cannot write to %s and sudo is not available\n' "$PREFIX" >&2
		exit 1
	fi
}

if [ "$BUILD_DIR" = "$ROOT" ]; then
	printf 'BUILD_DIR must not be the source tree: %s\n' "$ROOT" >&2
	exit 1
fi

if [ ! -f configure ]; then
	say "generating configure"
	sh autogen.sh
fi

say "clearing $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

say "configuring with prefix $PREFIX"
# shellcheck disable=SC2086 # CONFIGURE_ARGS is a list of arguments on purpose.
"$ROOT/configure" --prefix="$PREFIX" CFLAGS="$CFLAGS" $CONFIGURE_ARGS

say "building with $MAKE -j$JOBS"
$MAKE "-j$JOBS"

say "installing into $PREFIX"
as_root $MAKE install

say "installed: $(command -v "$PREFIX/bin/tmux")"
"$PREFIX/bin/tmux" -V
