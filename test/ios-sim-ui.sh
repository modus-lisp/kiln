#!/bin/sh
# ios-sim-ui.sh -- drive the booted iOS Simulator's UI and check what it shows.
#
#   kiln/test/ios-sim-ui.sh [UDID]       the booted simulator by default
#
# The helpers below are for a suite that calls them: tap LABEL, expect LABEL, expect_not LABEL,
# tap_at X Y, shot NAME.  A suite is a shell function named suite_NAME; the script runs the one given
# by SUITE (default: every suite_*).
#
# TAPS ARE HELD: `axe touch --down --up --delay 0.3`.  A quick `axe tap` does not register on the modus
# desk or on a native button in this app (memory: ios-sim-ui-testing).  LABELS come from the
# accessibility tree (`axe describe-ui`).  Native views have labels; desk windows draw their text into
# the framebuffer, so a desk step is a tap_at at a point read off a screenshot.
set -eu

UDID=${1:-$(xcrun simctl list devices booted | awk -F'[()]' '/Booted/ { print $2; exit }')}
[ -n "$UDID" ] || { echo "no booted simulator" >&2; exit 2; }
SHOTS=${SHOTS:-/tmp/ios-sim-ui}
mkdir -p "$SHOTS"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; shot "fail-$FAIL"; }
shot() { xcrun simctl io "$UDID" screenshot "$SHOTS/$1.png" >/dev/null 2>&1 || true; }

tree() { axe describe-ui --udid "$UDID"; }

# The centre of the element whose AXLabel is LABEL, in points: "X Y"; nothing if there is none.
center_of() {
  tree | python3 -c '
import json, sys
want = sys.argv[1]
def walk(node):
    if isinstance(node, dict):
        if node.get("AXLabel") == want and node.get("frame"):
            f = node["frame"]
            print(int(f["x"] + f["width"] / 2), int(f["y"] + f["height"] / 2))
            raise SystemExit(0)
        for child in node.get("children") or []:
            walk(child)
    elif isinstance(node, list):
        for child in node:
            walk(child)
walk(json.load(sys.stdin))
' "$1" 2>/dev/null || true
}

on_screen() { tree | grep -qF "\"AXLabel\" : \"$1\""; }

tap_at() {  # tap_at X Y: a held touch at a point, in points
  axe touch -x "$1" -y "$2" --down --up --delay 0.3 --udid "$UDID" >/dev/null
  sleep 1
}

tap() {  # tap LABEL: a held touch at the centre of the element labelled LABEL
  p=$(center_of "$1")
  if [ -z "$p" ]; then fail "tap: no element labelled '$1'"; return 1; fi
  tap_at "${p% *}" "${p#* }"
}

expect() {  # expect LABEL [SECONDS]: LABEL is on screen within SECONDS (default 5)
  i=0
  while [ "$i" -lt "${2:-5}" ]; do
    if on_screen "$1"; then ok "on screen: $1"; return 0; fi
    sleep 1
    i=$((i + 1))
  done
  fail "not on screen: $1"
  return 1
}

expect_not() {  # expect_not LABEL: LABEL is not on screen
  if on_screen "$1"; then fail "still on screen: $1"; return 1; fi
  ok "gone: $1"
}

swipe_points() {  # swipe_points X1 Y1 X2 Y2: a drag, in points (a slider moves by dragging)
  # a second, not half of one: a quicker drag does not scroll a UIScrollView (it does move a slider)
  axe swipe --start-x "$1" --start-y "$2" --end-x "$3" --end-y "$4" --duration 1.0 --udid "$UDID" >/dev/null
  sleep 1
}

# ---- the suites -------------------------------------------------------------------------------------

# The storybook (vessel/src/ios-storybook.lisp).  It must be open: the Actions grid's "storybook" opens
# it, and this suite checks it is there rather than driving the desk to it.  Coordinates are points on
# the iPhone 17 Pro simulator (402x874); the story buttons sit in a row at y 120-156.
suite_storybook() {
  expect "storybook" 5 || return 0
  expect "A plain label." 5
  tap "switch";    expect "off" 3
  tap_at 49 255;   expect "on" 3         # the switch's centre
  tap_at 49 255;   expect "off" 3
  tap "button";    expect "tapped 0 times" 3
  tap "tap me";    expect "tapped 1 times" 3
  tap "tap me";    expect "tapped 2 times" 3
  tap "slider";    expect "value 50" 3
  swipe_points 199 255 300 255; expect_not "value 50" 3    # from the thumb (at 50) to the right
  tap "stack";     expect "third" 3       # a stack lays its children out in a column
  tap "scroll";    expect "item 1" 3
  # the accessibility tree lists items below the fold too, so compare where item 30 is: below the scroll
  # view's bottom edge (y 760) before a drag up, and inside it after.  The drag comes before the text
  # story: a focused text field keeps the keyboard up, and the keyboard covers the scroll view's bottom.
  p=$(center_of "item 30"); by=${p#* }
  swipe_points 200 650 200 250
  p=$(center_of "item 30"); ay=${p#* }
  if [ "${by:-0}" -gt 760 ] && [ "${ay:-0}" -lt 760 ]; then ok "scrolled: item 30 at y $by, then $ay"
  else fail "scroll: item 30 at y $by, then $ay"; fi
  tap "image";     expect "star.fill" 3
  tap "text";      tap_at 199 218          # the field takes focus, and the keyboard comes up
  tap "H"; tap_at 300 618                  # the keys: H by its label, i at its place on the key row
  expect "Hi" 3                            # the field's text, mirrored by the story (keys are lowercase after the first)
  tap "done";    expect_not "shift" 3      # "done" gives the keyboard up: its "shift" key is gone (OPEN: it does not yet)
  shot storybook-done
  tap "close";     expect_not "storybook"
}

SUITE=${SUITE:-}
for name in $(sed -n 's/^suite_\([A-Za-z0-9_]*\)() {.*/\1/p' "$0"); do
  if [ -z "$SUITE" ] || [ "$SUITE" = "$name" ]; then
    echo "== suite $name"
    "suite_$name" || true
  fi
done

echo "== $PASS passed, $FAIL failed (screenshots in $SHOTS)"
[ "$FAIL" -eq 0 ]
