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

# WHEN THE FETCH FAILS, SAY WHAT IT USUALLY MEANS.
#
# This is the first step that needs the network, so a container with no route out
# fails HERE — twelve steps into a build, as `curl: (6) Could not resolve host'.
# That message sends people after DNS, and DNS is usually not the problem: on
# Apple's container the guests lose outbound networking altogether (they cannot
# reach a nameserver's IP either), and the fix is to restart the container
# SERVICE.  Restarting the builder is the near-miss that looks right and is not:
# /etc/resolv.conf inside the build really does change and every hostname still
# fails, after about twenty seconds each — and a slow failure is the tell, because
# a bad resolver fails fast while an unreachable network waits.
#
# ON THE FAILURE PATH AND NOT BEFORE IT.  A preflight would put a network
# round-trip in front of every cold build to explain a failure that happens
# rarely, and it cannot see more than the real fetch already sees.  This costs
# nothing when the network is fine, which is nearly always.
net_help() {
  echo "seed: this container cannot reach the network." >&2
  echo "seed:" >&2
  echo "seed:   Check whether it is routing at all before blaming DNS:" >&2
  echo "seed:       container run --rm debian:trixie-slim \\" >&2
  echo "seed:           sh -c '>/dev/tcp/1.1.1.1/443 && echo up'" >&2
  echo "seed:" >&2
  echo "seed:   If that fails too, the container service has lost its NAT." >&2
  echo "seed:   Restarting the SERVICE fixes it (restarting the builder does not):" >&2
  echo "seed:       container system stop && container system start" >&2
  echo "seed:" >&2
  echo "seed:   If routing works and only names fail, it is DNS after all:" >&2
  echo "seed:       KILN_DNS=1.1.1.1 bin/kiln build" >&2
}

for repo in $SEED; do
  commit=$(awk -v r="$repo" '$1 == r { print $3 }' "$LOCK")
  [ -n "$commit" ] || { echo "seed: $repo not in $LOCK" >&2; exit 1; }

  echo "seed: $repo @ ${commit%"${commit#????????}"}"
  # TO A FILE, NOT DOWN A PIPE.  `curl | tar' reports TAR's status and not curl's, so a
  # fetch that failed is announced by whatever tar makes of an empty stream — which on
  # GNU tar is an error and on bsdtar is silence and a zero exit.  The build then walks
  # on to the mv below and fails there instead, about a missing directory.  Two lines and
  # a temp file buy an exact answer to "did the download work", which is the question the
  # whole of the diagnosis below hangs off.
  tmp="$DEST/.$repo.tar.gz"
  if ! curl -fsSL -o "$tmp" "https://codeload.github.com/$ORG/$repo/tar.gz/$commit"; then
    rm -f "$tmp"
    # One probe, only now that something has already gone wrong, to answer the question
    # curl's own message gets wrong: is this DNS, or is there no route at all?
    if curl -fsS --max-time 10 -o /dev/null -I "https://codeload.github.com/" 2>/dev/null
    then echo "seed: could not fetch $repo, though the network is reachable." >&2
    else net_help
    fi
    exit 1
  fi
  # --no-same-owner: the tarball's uid/gid are meaningless in the image.
  tar -xzf "$tmp" -C "$DEST" --no-same-owner
  rm -f "$tmp"
  # codeload names the directory <repo>-<commit>; ASDF wants it at <repo>.
  rm -rf "$DEST/$repo"
  mv "$DEST/$repo-$commit" "$DEST/$repo"
done

echo "seed: cairn closure in $DEST (discarded once cairn has cloned the org)"
