#!/bin/sh
# entrypoint.sh — what `kiln run` actually starts inside the container.
#
# The default is the desktop.  The other subcommands exist because this image
# already contains the whole world compiled, and it would be silly to need a
# second one to get a REPL or run the gates.
set -eu

CORE=${KILN_CORE:-/opt/kiln/modus.core}
ROOT=${MODUS_ROOT:-/opt/modus-lisp}
DISPLAY_N=${GLASS_DISPLAY:-1}

# Every entry point runs from the saved core, so the McCLIM compile that the
# image build already paid for is never paid again.
lisp() { exec sbcl --core "$CORE" --control-stack-size 256 --dynamic-space-size "${KILN_HEAP:-4096}" "$@"; }

cmd=${1:-desktop}
[ $# -gt 0 ] && shift

case "$cmd" in
  desktop)
    # glass's own serve-desktop.lisp is the entry point, deliberately: kiln does
    # not reimplement what a desktop is, and this file stays correct as glass
    # changes.  Its quickload calls find everything already in the core.
    echo "kiln: glass desktop :$DISPLAY_N — VNC on $((5900 + DISPLAY_N)), audio $((5910 + DISPLAY_N)), control $((4008 + DISPLAY_N))"
    lisp --load "$ROOT/glass/backend/inspect/serve-desktop.lisp" "$@"
    ;;

  repl)
    # A plain REPL with the desktop's whole world already loaded.
    lisp "$@"
    ;;

  test)
    # glass's RFB self-test: draws a known pattern, reads it back through an
    # in-process client, asserts the pixels. Exits non-zero on any failure.
    exec sh "$ROOT/glass/run-tests.sh" "$@"
    ;;

  eval)
    # kiln eval '(+ 1 2)' — one form in the loaded image, printed.
    [ $# -gt 0 ] || { echo "kiln eval: needs a form" >&2; exit 2; }
    form=$1; shift
    lisp --non-interactive --disable-debugger --eval "(print $form)" "$@"
    ;;

  lock)
    # Refresh repos.lock against the org's live refs and print it to stdout.
    # Runs on a plain sbcl, not the core: the core has no cairn in it.
    exec sbcl --script /kiln/boot/lock.lisp "$@"
    ;;

  shell|sh)
    exec /bin/bash "$@"
    ;;

  version)
    echo "kiln — modus-lisp desktop image"
    sbcl --version
    echo "core:  $CORE"
    echo "repos: $(find "$ROOT" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ') checked out in $ROOT"
    ;;

  *)
    # Anything else: treat it as a command to run, so `kiln run ls /opt` works.
    exec "$cmd" "$@"
    ;;
esac
