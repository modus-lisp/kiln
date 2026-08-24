#!/usr/bin/env bash
# ports-test.sh — a second desktop collides with the first on nothing.
#
# Three of the five ports came off GLASS_DISPLAY and two did not, so the documented
# recipe for a second desktop produced one that fought the first for 8765 and 2222 —
# and `kiln run', finding a container already named `kiln', reported success about
# somebody else's desktop.  The invariant is: change GLASS_DISPLAY, change everything
# that is published or named.
#
# The expressions are lifted from bin/kiln rather than restated here, so this cannot
# quietly keep passing against a copy.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KILN="$HERE/../bin/kiln"
fails=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n     want [%s] got [%s]\n' "$1" "$2" "$3"; fails=$((fails+1)); }

derive() {  # derive DISPLAY -> "name vnc audio ctrl gw ssh"
  GLASS_DISPLAY=$1 bash -c '
    set -eu
    GLASS_DISPLAY=${GLASS_DISPLAY:-1}
    eval "$(grep -E "^(DISPLAY_N|NAME|VNC_PORT|AUDIO_PORT|CTRL_PORT|GW_PORT|SSH_PORT)=" "'"$KILN"'")"
    printf "%s %s %s %s %s %s" "$NAME" "$VNC_PORT" "$AUDIO_PORT" "$CTRL_PORT" "$GW_PORT" "$SSH_PORT"'
}

# Display 1 must keep every number it has ever had: this change must not move a
# published port under somebody who has been typing localhost:8765 for months.
r=$(derive 1)
[ "$r" = "kiln 5901 5911 4009 8765 2222" ] \
  && ok "display 1 is unchanged (kiln 5901 5911 4009 8765 2222)" \
  || fail "display 1" "kiln 5901 5911 4009 8765 2222" "$r"

r=$(derive 2)
[ "$r" = "kiln2 5902 5912 4010 8766 2223" ] \
  && ok "display 2 moves ALL five and the name" \
  || fail "display 2" "kiln2 5902 5912 4010 8766 2223" "$r"

# The real invariant, stated as one: nothing published by display 1 is published by
# display 2.  Written as a set comparison so a sixth port added later is covered too.
a=$(derive 1); b=$(derive 2)
dupes=$(printf '%s\n%s\n' "$(echo "$a" | tr ' ' '\n')" "$(echo "$b" | tr ' ' '\n')" | sort | uniq -d)
[ -z "$dupes" ] && ok "two displays share no port and no name" \
                || fail "collision between displays" "(nothing shared)" "$dupes"

[ "$fails" = 0 ] || exit 1
