#!/usr/bin/env bash
# run-tests.sh — everything that can be checked without building an image.
#
# The image gate (.github/workflows/image.yml) is the end-to-end proof and takes the
# better part of an hour.  This is the other half: the decisions kiln makes BEFORE
# anything starts — which config it read, which ports it derived, which flags it
# believed — none of which need a container, a display or a network, and all of which
# have shipped broken at least once.
#
#   t/run-tests.sh
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/.." && pwd)
rc=0
group() { printf '\n\033[1m%s\033[0m\n' "$1"; }

group "shell syntax"
for f in bin/kiln; do
  if bash -n "$ROOT/$f" 2>/dev/null; then printf '  ok   %s parses (bash)\n' "$f"
  else printf '  FAIL %s\n' "$f"; bash -n "$ROOT/$f"; rc=1; fi
done
# entrypoint.sh runs as /bin/sh — dash on Debian — so bashisms in it are a runtime
# failure inside the image and invisible here unless it is checked as sh.
for f in boot/entrypoint.sh boot/seed.sh; do
  [ -f "$ROOT/$f" ] || continue
  if sh -n "$ROOT/$f" 2>/dev/null; then printf '  ok   %s parses (sh, not bash)\n' "$f"
  else printf '  FAIL %s\n' "$f"; sh -n "$ROOT/$f"; rc=1; fi
done

group "lisp syntax"
if command -v sbcl >/dev/null; then
  for f in "$ROOT"/boot/*.lisp; do
    # *READ-SUPPRESS* checks structure without interning: these files name packages
    # (glass:, clim-glass:) that do not exist until an image has loaded them.
    if sbcl --noinform --non-interactive --eval "
        (handler-case (let ((*read-suppress* t))
                        (with-open-file (in \"$f\")
                          (loop for x = (read in nil :eof) until (eq x :eof))))
          (error (e) (format *error-output* \"~a~%\" e) (sb-ext:exit :code 1)))" 2>/dev/null
    then printf '  ok   %s parses\n' "boot/$(basename "$f")"
    else printf '  FAIL boot/%s\n' "$(basename "$f")"; rc=1; fi
  done
else
  printf '  skip no sbcl on PATH\n'
fi

group "the .config is read, and read correctly"
sh "$HERE/config-test.sh" || rc=1

group "a second desktop collides with the first on nothing"
bash "$HERE/ports-test.sh" || rc=1

group "boot decisions (flags, identity file, payload)"
if command -v sbcl >/dev/null; then
  sbcl --script "$HERE/one-test.lisp" || rc=1
else
  printf '  skip no sbcl on PATH\n'
fi

printf '\n'
[ "$rc" = 0 ] && printf '\033[32mall green\033[0m\n' || printf '\033[31mFAILURES\033[0m\n'
exit $rc
