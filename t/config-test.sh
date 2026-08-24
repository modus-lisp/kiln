#!/bin/sh
# config-test.sh — the .config is read at boot, and read correctly.
#
# This exists because the bug it covers was invisible: `kiln config' wrote
# /etc/kiln/config and nothing at boot ever opened it, so every setting in that file
# was decoration.  A box whose config plainly said KILN_NOSTR=y simply did not do it,
# which reads as a broken feature rather than an unread file.
#
# It sources the REAL boot/config.sh -- the same file the image and bin/kiln use.  It
# used to lift the function out of entrypoint.sh with awk, which worked but tested a
# text extraction as much as the code; giving the reader its own file made both callers
# and this test point at one thing.
set -eu
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
LIB="$HERE/../boot/config.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
fails=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n     want [%s] got [%s]\n' "$1" "$2" "$3"; fails=$((fails+1)); }

[ -f "$LIB" ] || { echo "  FAIL no $LIB"; exit 1; }
cp "$LIB" "$WORK/lib.sh"

mkdir -p "$WORK/etc"
cat > "$WORK/etc/config" <<'CFG'
# kiln configuration
KILN_NOSTR=y
# KILN_VNC is not set
GLASS_APPS=""
NOSTR_RELAYS="wss://a,wss://b"
KILN_SSH_PORT=2222
  INDENTED=nope
lowercase=nope
BAD-KEY=nope
CFG

probe() {  # probe VAR [preset-value]
  var=$1; preset=${2:-}
  # shellcheck disable=SC2016
  env -i KILN_ETC="$WORK/etc" ${preset:+"$var=$preset"} \
    sh -c '. '"$WORK"'/lib.sh; load_config; eval "v=\${'"$var"'-<unset>}"; printf %s "$v"'
}

r=$(probe KILN_NOSTR);    [ "$r" = y ] && ok "KEY=value is exported" || fail "KEY=value" y "$r"
r=$(probe KILN_VNC);      [ "$r" = "<unset>" ] && ok '"# KEY is not set" stays unset (a disabled bool is false)' \
                                               || fail "disabled bool" "<unset>" "$r"
r=$(probe GLASS_APPS);    [ "$r" = "<unset>" ] && ok 'KEY="" is not exported' || fail 'empty value' "<unset>" "$r"
r=$(probe NOSTR_RELAYS);  [ "$r" = "wss://a,wss://b" ] && ok "quotes are stripped, commas survive" \
                                               || fail "quoted value" "wss://a,wss://b" "$r"
r=$(probe KILN_SSH_PORT); [ "$r" = 2222 ] && ok "a number is a value like any other" || fail "number" 2222 "$r"

# THE PRECEDENCE RULE: a -e flag is this run's instruction, the file is a standing
# preference.  Getting this backwards would mean a flag on the command line is
# silently overridden by something written weeks ago.
r=$(probe KILN_SSH_PORT 2299)
[ "$r" = 2299 ] && ok "the environment wins over the file" || fail "env precedence" 2299 "$r"

# Not-a-key lines must not become variables.
r=$(probe INDENTED);  [ "$r" = "<unset>" ] && ok "an indented line is not a setting" || fail "indented" "<unset>" "$r"
r=$(probe lowercase); [ "$r" = "<unset>" ] && ok "a lowercase name is not a setting" || fail "lowercase" "<unset>" "$r"

[ "$fails" = 0 ] || exit 1
