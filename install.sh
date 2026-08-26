#!/bin/sh
#
# Clean, build a release binary and install it.
#
# Everything the build produces is thrown away first, so this never reuses
# objects from a debug or test build: the version here is a "next" version, and
# configure turns debug on by default for those, which is not what should be
# installed.
#
# Usage:
#   sh ./install.sh                     # /usr/local, the autotools default
#   PREFIX=/usr sh ./install.sh         # somewhere else
#   JOBS=4 sh ./install.sh              # fewer compile jobs
#   CONFIGURE_ARGS="--disable-utf8proc" sh ./install.sh
#
# The install step is run with sudo when the target directory is not writable.

set -eu

ROOT=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

PREFIX=${PREFIX:-/usr/local}
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

say "cleaning"
if [ -f Makefile ]; then
	$MAKE distclean >/dev/null 2>&1 || true
fi
rm -f ./*.o compat/*.o tmux tmux.1.mdoc tmux.1.man
rm -f config.h config.log config.status .rake-configure-stamp

if [ ! -f configure ]; then
	say "generating configure"
	sh autogen.sh
fi

say "configuring with prefix $PREFIX"
# shellcheck disable=SC2086 # CONFIGURE_ARGS is a list of arguments on purpose.
./configure --prefix="$PREFIX" CFLAGS="$CFLAGS" $CONFIGURE_ARGS

say "building with $MAKE -j$JOBS"
$MAKE "-j$JOBS"

say "installing into $PREFIX"
as_root $MAKE install

say "installed: $(command -v "$PREFIX/bin/tmux")"
"$PREFIX/bin/tmux" -V
