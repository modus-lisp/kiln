#!/bin/sh
# seed.sh — the one non-Lisp step: fetch cairn and its dependency closure.
#
# cairn is a git implementation in Common Lisp, and it is what clones the other
# 33 repos (see clone-org.lisp).  But cairn has to arrive somehow, and it cannot
# clone itself, so exactly five repos are seeded here as plain tarballs:
#
#     cairn -> seal, conch, cram, natrium
#
# That closure has no third-party dependencies at all — no Quicklisp, no FFI,
# nothing outside SBCL's own sb-bsd-sockets/sb-posix.  Everything after this
# point travels over cairn's own smart-HTTP client on seal's TLS.
#
# Commits come from repos.lock, so the seed is pinned exactly like the rest.
set -eu

ORG=${MODUS_ORG:-modus-lisp}
DEST=${KILN_SEED:-/opt/kiln-seed}
LOCK=${KILN_LOCK:-/kiln/repos.lock}
SEED="cairn seal conch cram natrium"

mkdir -p "$DEST"

for repo in $SEED; do
  commit=$(awk -v r="$repo" '$1 == r { print $3 }' "$LOCK")
  [ -n "$commit" ] || { echo "seed: $repo not in $LOCK" >&2; exit 1; }

  echo "seed: $repo @ ${commit%"${commit#????????}"}"
  # --no-same-owner: the tarball's uid/gid are meaningless in the image.
  curl -fsSL "https://codeload.github.com/$ORG/$repo/tar.gz/$commit" \
    | tar -xzf - -C "$DEST" --no-same-owner
  # codeload names the directory <repo>-<commit>; ASDF wants it at <repo>.
  rm -rf "$DEST/$repo"
  mv "$DEST/$repo-$commit" "$DEST/$repo"
done

echo "seed: cairn closure in $DEST (discarded once cairn has cloned the org)"
