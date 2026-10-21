#!/usr/bin/env bash
# sync-test.sh — `kiln sync' against a fake org of local repos, every case it decides.
#
# The org is a directory of bare repositories, named by KILN_SYNC_LIST and cloned from
# KILN_SYNC_URL, so no network is used.  Each case is checked by what `kiln sync' PRINTS
# and by what it LEFT ON DISK -- a sync that reported "kept" and moved the branch anyway
# would pass on output alone.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KILN="$HERE/../bin/kiln"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kiln-sync-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
rc=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; rc=1; }
command -v git >/dev/null || { printf '  skip no git\n'; exit 0; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
g() { git -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }

# ---- the org: a bare repo per name, each with one commit ------------------------------
mkdir -p "$WORK/up" "$WORK/src"
for r in alpha bravo charlie delta echo foxtrot; do
  g init -q --bare "$WORK/up/$r"
  g clone -q "$WORK/up/$r" "$WORK/src/$r" 2>/dev/null
  echo one > "$WORK/src/$r/file"; g -C "$WORK/src/$r" add file
  g -C "$WORK/src/$r" commit -qm one; g -C "$WORK/src/$r" push -q origin main
done
upstream_commit() {  # NAME -> a new commit upstream
  echo "$2" >> "$WORK/src/$1/file"; g -C "$WORK/src/$1" commit -qam "$2"
  g -C "$WORK/src/$1" push -q origin main
}

# ---- the workspace, before: every state sync has to decide about ----------------------
ws=$WORK/ws; mkdir -p "$ws"
for r in bravo charlie delta echo foxtrot; do g clone -q "$WORK/up/$r" "$ws/$r"; done
upstream_commit bravo two                                  # behind: fast-forward
echo local-edit >> "$ws/delta/file"; upstream_commit delta two     # dirty and behind
echo mine > "$ws/echo/mine"; g -C "$ws/echo" add mine; g -C "$ws/echo" commit -qm mine
upstream_commit echo two                                   # diverged
g -C "$ws/foxtrot" checkout -q -b experiment               # a branch with no upstream
mkdir -p "$ws/golf"                                        # not a git checkout
g init -q "$ws/zulu"                                       # a repo the org does not have
printf '%s\n' alpha bravo charlie delta echo foxtrot golf > "$WORK/list"

delta_before=$(cat "$ws/delta/file"); echo_before=$(g -C "$ws/echo" rev-parse HEAD)

out=$(KILN_SYNC_LIST="$WORK/list" KILN_SYNC_URL="file://$WORK/up/" "$KILN" sync "$ws" --jobs=3 2>&1)
status=$?
line() { printf '%s\n' "$out" | grep -E "^ +$1 +$2( |$)"; }

[ $status = 0 ] && ok "exit 0 when nothing failed" || fail "exit $status: $out"
line cloned alpha >/dev/null && [ -f "$ws/alpha/file" ] \
  && ok "a missing repo is cloned" || fail "alpha not cloned: $out"
line updated bravo | grep -q "1 commit" \
  && [ "$(g -C "$ws/bravo" rev-parse HEAD)" = "$(g -C "$WORK/up/bravo" rev-parse main)" ] \
  && ok "a repo behind its upstream is fast-forwarded" || fail "bravo: $out"
line current charlie >/dev/null && ok "an up-to-date repo is left as it is" || fail "charlie: $out"
line kept delta | grep -q "uncommitted changes" && [ "$(cat "$ws/delta/file")" = "$delta_before" ] \
  && ok "uncommitted changes are left alone, and so is the branch" || fail "delta: $out"
line kept echo | grep -q "diverged: 1 local, 1 upstream" \
  && [ "$(g -C "$ws/echo" rev-parse HEAD)" = "$echo_before" ] \
  && ok "a diverged branch is left alone" || fail "echo: $out"
line kept foxtrot | grep -q "experiment has no upstream (on experiment; default is main)" \
  && [ "$(g -C "$ws/foxtrot" symbolic-ref --short HEAD)" = experiment ] \
  && ok "a local branch is left alone, and its name and the default are reported" || fail "foxtrot: $out"
line skipped golf | grep -q "not a git checkout" && ok "a directory that is not a checkout is skipped" \
  || fail "golf: $out"
printf '%s\n' "$out" | grep -q "not in the org list: zulu" && ok "a local repo the org lacks is named" \
  || fail "zulu not reported: $out"
printf '%s\n' "$out" | grep -q "1 cloned  1 updated  1 current  3 kept  1 skipped" \
  && ok "the summary counts each verdict" || fail "summary: $(printf '%s\n' "$out" | tail -1)"

# A second sync of the same tree changes nothing it already settled.
out=$(KILN_SYNC_LIST="$WORK/list" KILN_SYNC_URL="file://$WORK/up/" "$KILN" sync "$ws" 2>&1)
line current alpha >/dev/null && line current bravo >/dev/null \
  && ok "a second sync finds the cloned and updated repos current" || fail "second sync: $out"

# A repo that cannot be cloned is a failure, and the exit status says so.
printf 'hotel\n' >> "$WORK/list"
out=$(KILN_SYNC_LIST="$WORK/list" KILN_SYNC_URL="file://$WORK/up/" "$KILN" sync "$ws" 2>&1)
status=$?
[ $status != 0 ] && line failed hotel | grep -q "clone:" && [ ! -e "$ws/hotel" ] \
  && ok "a clone that fails is reported, exits non-zero, and leaves nothing behind" \
  || fail "hotel: exit $status: $out"

exit $rc
