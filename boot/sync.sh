#!/usr/bin/env bash
# sync.sh — every repo in the org, as a working checkout, brought up to date.
#
#   kiln sync [DIR] [--locked] [--ssh] [--jobs=N]
#
# The workspace a person develops in: a directory holding a checkout of every repo the
# org has, beside kiln.  Missing ones are cloned; present ones are fetched and moved
# forward when that cannot lose anything, and left alone -- with the reason -- when it
# could.  This is not `kiln build': build fetches the pinned set into a fresh tree to
# make a core from it, with cairn; this keeps a live tree current, with git, for the
# person working in it.
#
# WHAT IT WILL NEVER DO: reset, stash, switch a branch, rebase, or delete.  A repo is
# fast-forwarded only when it is on a branch, that branch tracks one upstream, nothing
# tracked is modified, and the upstream contains everything local.  Anything else is a
# decision only the person can make, so it is reported and not made.
#
# Env (for tests, mostly): MODUS_ORG (modus-lisp), KILN_SYNC_LIST (a file of repo names,
# one per line, instead of asking the forge), KILN_SYNC_URL (clone URL prefix, default
# https://github.com/ORG/), KILN_LOCK (repos.lock, for --locked), GITHUB_TOKEN (sent to
# the API if set: a higher rate limit, and private repos).
set -uo pipefail

ORG=${MODUS_ORG:-modus-lisp}
DEST="" LOCKED=0 SSH=0 JOBS=${KILN_SYNC_JOBS:-8}
for a in "$@"; do
  case $a in
    --locked) LOCKED=1 ;;
    --ssh) SSH=1 ;;
    --jobs=*) JOBS=${a#*=} ;;
    -*) echo "kiln sync: unknown flag $a" >&2; exit 2 ;;
    *) [ -z "$DEST" ] && DEST=$a || { echo "kiln sync: one directory, not two" >&2; exit 2; } ;;
  esac
done
[ -n "$DEST" ] || { echo "kiln sync: no workspace directory" >&2; exit 2; }
command -v git >/dev/null || { echo "kiln sync: needs git" >&2; exit 2; }
[[ $JOBS =~ ^[0-9]+$ && $JOBS -ge 1 ]] || { echo "kiln sync: --jobs wants a positive number" >&2; exit 2; }
mkdir -p "$DEST" && DEST=$(cd "$DEST" && pwd)

if [ $SSH = 1 ]; then URL=${KILN_SYNC_URL:-git@github.com:$ORG/}
else URL=${KILN_SYNC_URL:-https://github.com/$ORG/}; fi

# ---- which repos ---------------------------------------------------------------------

list_org() {
  # One page of the org listing at a time.  `full_name' and not `name': a repo's JSON
  # also carries its licence's name, and that is not a repo.
  local page=1 got
  while :; do
    got=$(curl -fsS ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
            "https://api.github.com/orgs/$ORG/repos?per_page=100&type=all&page=$page") \
      || { echo "kiln sync: could not list github.com/$ORG (network, or the API rate limit)" >&2; return 1; }
    got=$(printf '%s\n' "$got" | grep -o "\"full_name\": *\"$ORG/[^\"]*\"" | sed 's/.*\/\([^"]*\)"$/\1/')
    [ -n "$got" ] || return 0
    printf '%s\n' "$got"
    page=$((page + 1))
  done
}

if [ -n "${KILN_SYNC_LIST:-}" ]; then
  repos=$(grep -v '^[[:space:]]*\(#\|$\)' "$KILN_SYNC_LIST")
elif [ $LOCKED = 1 ]; then
  repos=$(awk '!/^[[:space:]]*(#|$)/ { print $1 }' "${KILN_LOCK:?kiln sync: --locked needs KILN_LOCK}")
else
  repos=$(list_org) || exit 1
fi
repos=$(printf '%s\n' "$repos" | sort -u)
[ -n "$repos" ] || { echo "kiln sync: no repos to sync" >&2; exit 1; }

# ---- one repo --------------------------------------------------------------------------
#
# Prints exactly one line: VERDICT NAME DETAIL.  One line per repo, written with a single
# printf, so lines from parallel jobs do not interleave.

sync_one() {
  local name=$1 dir=$DEST/$1 out branch up ahead behind default note=""
  if [ ! -e "$dir" ]; then
    if out=$(git clone -q "$URL$name" "$dir" 2>&1); then
      printf 'cloned %s %s\n' "$name" "$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
    else
      printf 'failed %s clone: %s\n' "$name" "$(printf '%s' "$out" | tail -1)"
    fi
    return
  fi
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'skipped %s not a git checkout\n' "$name"; return
  fi
  if ! out=$(git -C "$dir" fetch -q --prune origin 2>&1); then
    printf 'failed %s fetch: %s\n' "$name" "$(printf '%s' "$out" | tail -1)"; return
  fi
  branch=$(git -C "$dir" symbolic-ref -q --short HEAD) \
    || { printf 'kept %s detached HEAD\n' "$name"; return; }
  default=$(git -C "$dir" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
  default=${default#origin/}
  [ -n "$default" ] && [ "$branch" != "$default" ] && note=" (on $branch; default is $default)"
  up=$(git -C "$dir" rev-parse -q --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
    || { printf 'kept %s %s has no upstream%s\n' "$name" "$branch" "$note"; return; }
  ahead=$(git -C "$dir" rev-list --count "$up..HEAD")
  behind=$(git -C "$dir" rev-list --count "HEAD..$up")
  if [ "$behind" = 0 ]; then
    if [ "$ahead" = 0 ]; then printf 'current %s%s\n' "$name" "$note"
    else printf 'current %s %s commit(s) not pushed%s\n' "$name" "$ahead" "$note"; fi
    return
  fi
  if [ "$ahead" != 0 ]; then
    printf 'kept %s diverged: %s local, %s upstream%s\n' "$name" "$ahead" "$behind" "$note"; return
  fi
  if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
    printf 'kept %s uncommitted changes, %s upstream commit(s) waiting%s\n' "$name" "$behind" "$note"; return
  fi
  if out=$(git -C "$dir" merge -q --ff-only "$up" 2>&1); then
    printf 'updated %s %s commit(s)%s\n' "$name" "$behind" "$note"
  else
    printf 'kept %s fast-forward refused: %s\n' "$name" "$(printf '%s' "$out" | tail -1)"
  fi
}
export -f sync_one
export DEST URL

results=$(printf '%s\n' "$repos" | xargs -P "$JOBS" -I{} bash -c 'sync_one "$1"' _ {} | sort -k1,1 -k2,2)

# ---- what happened -------------------------------------------------------------------

printf '%s\n' "$results" | awk '{ v=$1; $1=""; printf "  %-8s%s\n", v, $0 }'
extra=$(cd "$DEST" && for d in */; do d=${d%/}; [ -d "$d/.git" ] || continue
          printf '%s\n' "$repos" | grep -qx "$d" || printf '%s ' "$d"; done)
[ -n "$extra" ] && printf '  %-8s %s\n' "local" "not in the org list: $extra"
echo
for v in cloned updated current kept skipped failed; do
  n=$(printf '%s\n' "$results" | grep -c "^$v ")
  [ "$n" != 0 ] && printf '%s %s  ' "$n" "$v"
done
printf '\n'
printf '%s\n' "$results" | grep -q '^failed ' && exit 1
exit 0
