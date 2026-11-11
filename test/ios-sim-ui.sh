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

# The centre of row N of the list: "X Y".  The accessibility tree also lists cells that are not laid out yet,
# and those sit at the list's origin (x 24); a laid-out row is inset 20 (x 44), so only those count.
row_center() {
  tree | python3 -c '
import json, sys
want = sys.argv[1]
def walk(node):
    if isinstance(node, dict):
        if node.get("AXLabel") == want and node.get("frame") and node["frame"]["x"] > 30:
            f = node["frame"]
            print(int(f["x"] + f["width"] / 2), int(f["y"] + f["height"] / 2))
            raise SystemExit(0)
        for child in node.get("children") or []:
            walk(child)
    elif isinstance(node, list):
        for child in node:
            walk(child)
walk(json.load(sys.stdin))
' "row $1" 2>/dev/null || true
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
  swipe_points 200 740 200 200             # a long drag: the deceleration varies, so a short one lands near the edge
  p=$(center_of "item 30"); ay=${p#* }
  if [ "${ay:-0}" -gt 760 ]; then swipe_points 200 740 200 200; p=$(center_of "item 30"); ay=${p#* }; fi   # fell short: one more
  if [ "${by:-0}" -gt 760 ] && [ "${ay:-0}" -lt 760 ]; then ok "scrolled: item 30 at y $by, then $ay"
  else fail "scroll: item 30 at y $by, then $ay"; fi
  tap "image";     expect "star.fill" 3
  tap "list";      expect "row 1" 3
  # cells are made as they scroll into view, and the accessibility tree lists the prefetched ones too,
  # so compare where row 18 is: below the list's bottom edge (y 760) before a drag up, inside it after
  # a row that is not in the tree yet is below the fold: a laid-out row inside the list is always listed
  p=$(row_center 18); ry=${p#* }
  # short drags, stopping as soon as row 18 is inside the list: one long drag can carry it past the top edge
  for i in 1 2 3 4; do
    p=$(row_center 18)
    if [ -n "$p" ] && [ "${p#* }" -lt 700 ]; then break; fi
    swipe_points 200 700 200 400
  done
  p=$(row_center 18); ry2=${p#* }
  if [ "${ry:-9999}" -gt 760 ] && [ "${ry2:-9999}" -lt 760 ]; then ok "rows scroll: row 18 at y ${ry:-absent}, then $ry2"
  else fail "rows: row 18 at y ${ry:-absent}, then ${ry2:-absent}"; fi
  expect "row 18" 3
  p=$(row_center 18); tap_at "${p% *}" "${p#* }"; expect "selected: row 18" 3   # a tap on a row is a select event with its index
  tap "text";      tap_at 199 218          # the field takes focus, and the keyboard comes up
  tap "H"; tap_at 300 618                  # the keys: H by its label, i at its place on the key row
  expect "Hi" 3                            # the field's text, mirrored by the story (keys are lowercase after the first)
  tap "done";    expect_not "shift" 3      # "done" gives the keyboard up: its "shift" key is gone (OPEN: it does not yet)
  shot storybook-done
  # the second page: "more" shows it, and "back" returns to the first
  tap "next";      expect "segment" 3
  tap "segment";   expect "selected: one" 3
  tap_at 199 216;  expect "selected: two" 3     # the middle segment: the control's centre, 16 below its top (200)
  tap "progress";  expect "spinning" 3
  tap "toggle";    expect "stopped" 3
  tap "toggle";    expect "spinning" 3
  tap "textview";  expect "chars: 34" 3         # the initial text: 22 + a newline + 11 characters
  tap "stepper";   expect "value 50" 3
  tap_at 94 216;   expect "value 51" 3          # the increment half: the stepper's centre (71 + 47/2, 200 + 32/2)
  tap_at 47 216;   expect "value 50" 3          # the decrement half
  tap "pages";     expect "page 1" 3
  tap "turn";      expect "page 2" 3            # the page control's own button (the shelf's is "next")
  tap "date";      expect "seconds: 1000000000" 3
  tap "hold";      expect "not held" 3
  axe touch -x 199 -y 230 --down --up --delay 1.0 --udid "$UDID" >/dev/null   # a hold of a second: a long press
  sleep 1
  expect "held" 3
  tap "alert";     expect "show alert" 3
  tap "show alert"; expect "Delete" 3          # the alert's buttons are on screen
  tap "Delete";    expect "chose: Delete" 3
  tap "tabs";      expect "tab: one" 3
  tap "two";       expect "tab: two" 3
  tap "refresh";   expect "refreshes: 0" 3
  # a pull sent as the refresh control sends it: a one-shot swipe does not start a pull in the simulator
  tap "pull";      expect "refreshes: 1" 3
  tap "next";      expect "show sheet" 3          # the third page
  tap "sheet";     expect "show sheet" 3
  tap "show sheet"; expect "Mail" 3              # the action sheet's buttons are on screen
  tap "Mail";      expect "chose: Mail" 3
  tap "toolbar";   expect "tapped: nothing" 3
  tap "bold";      expect "tapped: bold" 3
  tap "italic";    expect "tapped: italic" 3
  tap "search";    expect "put" 3
  tap "put";       expect "text: hello" 3
  tap "picker";    expect "colour: red" 3
  tap "select blue"; expect "colour: blue" 3     # the button selects the wheel's blue row, and the readout follows
  tap "blur";      expect "blurred" 3
  tap "pan";       expect "dragged: none" 3
  swipe_points 100 230 330 230                  # a horizontal drag across the label
  expect_not "dragged: none" 3
  tap "grid";      expect "tile 1" 3
  tap "tile 3";    expect "tile: 3" 3
  tap "menu";      expect "options" 3
  tap "options";   expect "paste" 3             # the menu's choices are on screen
  tap "paste";     expect "chose: paste" 3
  tap "color";     expect "color: #8A2BE2" 3
  tap "set green"; expect "color: #00FF00" 3
  tap "next";      expect "push" 3              # the fourth page, its navigation story first
  tap "nav";       expect "push" 3
  tap "push";      expect "adds: 0" 3
  tap "add";       expect "adds: 1" 3          # the right button of the pushed step
  tap "push";      expect "step 2" 3
  tap "pop";       expect "pops: 1" 3          # a pop from code: the bar's pop event follows
  tap "context";   expect "hold for a menu" 3
  axe touch -x 199 -y 230 --down --up --delay 1.0 --udid "$UDID" >/dev/null   # a long press opens the menu
  sleep 1
  tap "delete";    expect "menu: delete" 3
  tap "animate";   expect "move me" 3
  p=$(center_of "move me"); bx=${p% *}
  tap "move";      sleep 1
  p=$(center_of "move me"); ax=${p% *}
  if [ "${ax:-0}" -gt "${bx:-0}" ]; then ok "animated: move me from x $bx to x $ax"
  else fail "animate: move me at x $bx, then $ax"; fi
  tap "shapes";    expect "two shapes" 3
  tap "swipe";     expect "swipe me left" 3
  # the swipe recognizer is not exercised: AXe's one-shot swipe, at 0.1 to 1.0 s, does not register as a swipe
  # here (a slower drag starts a pan, which is tested).  A swipe needs a device or a different input path.
  tap "buzz";      expect "buzzed: none" 3
  tap "heavy";     expect "buzzed: heavy" 3      # the feedback itself is felt, not seen: the story reports the tap
  tap "a11y";      expect "custom name" 3        # the accessibility label, not the text, is in the tree
  tap "fade";      expect "fade it" 3           # the shelf's button opens the story; its own button is "fade it"
  expect "faded: no" 3                          # before the tap: the fade's completion follows it
  tap "fade it"
  sleep 1
  expect "faded: yes" 3                          # the fade's completion, a second after the tap
  tap "modal";     expect "open modal" 3
  tap "open modal"; expect "inside the sheet" 3
  tap "done";      expect "dismissed: yes" 3
  tap "share";     expect "share now" 3
  tap "share now"; expect "share: none yet" 3
  sleep 2
  # the share sheet is out of process, so its items are not in the tree: a tap on the dimmed screen above it
  # dismisses it, and its completion (no activity chosen) is the readout's change
  axe touch -x 200 -y 300 --down --up --delay 0.3 --udid "$UDID" >/dev/null
  sleep 2
  expect "shared: no" 3
  tap "next";      expect "page 1" 3             # the fifth page: the paging story first
  tap "paging";    expect "at page 1" 3
  # a drag left: the page scroll comes to rest on the next page; a short drag may not turn it, so retry
  for i in 1 2 3; do if on_screen "at page 2"; then break; fi; swipe_points 300 260 60 260; done
  expect "at page 2" 3
  tap "rows";      expect "mail 1" 3
  swipe_points 330 262 150 262                   # a drag left across a row reveals its swipe actions
  tap "archive";   expect "action: archive" 3
  tap "announce";  expect "announced: no" 3
  tap "say it";    expect "announced: yes" 3     # the announcement is spoken, not seen: the story reports it
  tap "tabctl";    expect "open tabs" 3
  tap "open tabs"; expect "home tab" 3           # a tab bar controller, shown as a sheet
  tap "search";    expect "search tab" 3        # its tab bar is the controller's own
  tap "dismiss";   expect "last tab: search" 3
  tap "navctl";    expect "open nav" 3
  tap "open nav";  expect "root view" 3          # a navigation controller, shown as a sheet
  tap "push view"; expect "second view" 3
  # the back button pops on a short press; a held one (the 0.3 s used elsewhere) opens its menu of earlier titles
  p=$(center_of "start"); axe touch -x "${p% *}" -y "${p#* }" --down --up --delay 0.05 --udid "$UDID" >/dev/null
  sleep 1
  expect "root view" 3
  tap "dismiss";   expect "closed: yes" 3
  tap "next";      expect "underlined text" 3    # the sixth page: attributed text first
  tap "dynamic";   expect "dynamic title" 3      # a text style that follows the user's text size
  tap "safe";      expect "inset ok" 3           # the top safe-area inset is not zero (the status bar, the notch)
  tap "parallax";  expect "parallax card" 3      # a parallax motion effect, which needs tilt to see
  tap "zoom";      expect "zoom: 100" 3          # its readout starts at 100%; pinching it needs two fingers
  tap "drawn";     expect "drawn" 3              # an image drawn in code: the shelf button is the check
  tap "sections";  expect "today" 3              # a section header
  tap "row 5";     expect "selected: 5" 3        # the row's number is its place in all the rows, across sections
  tap "pagevc";    expect "open pages" 3
  tap "open pages"; expect "pager 1" 3           # a page view controller, shown as a sheet
  for i in 1 2 3; do if on_screen "pager 2"; then break; fi; swipe_points 300 400 60 400; done   # a drag left turns the page
  expect "pager 2" 3
  tap "done pages"; expect "closed: yes" 3
  tap "file";      expect "file" 3               # a shape saved to a file and shown from it: the button is the check
  tap "next";      expect "edit rows" 3          # the seventh page: its first story, a list in editing mode
  tap "edit rows"; sleep 1
  expect "item 1" 3
  tap "editmenu";  expect "long press for edit menu" 3
  p=$(center_of "long press for edit menu"); axe touch -x "${p% *}" -y "${p#* }" --down --up --delay 1.0 --udid "$UDID" >/dev/null
  sleep 1
  tap "paste";     expect "edit: paste" 3       # an edit menu opened by a long press
  tap "popover";   expect "show popover" 3
  tap "show popover"; expect "in the popover" 3  # a popover: a sheet on a phone
  tap "done popover"; expect "popover: closed" 3
  tap "split";     expect "show split" 3
  tap "show split"; expect "secondary view" 3   # a split view: on a phone the secondary column shows first
  p=$(center_of "Back"); axe touch -x "${p% *}" -y "${p#* }" --down --up --delay 0.05 --udid "$UDID" >/dev/null   # a short press: held, it opens the menu
  sleep 1
  expect "primary view" 3                       # and Back shows the primary
  tap "done split"; expect "show split" 3       # which closes the sheet
  tap "dynamics";  expect "drop me" 3
  p=$(center_of "drop me"); dy=${p#* }
  tap "drop";      sleep 2                       # the fall runs on the animator: two seconds is ample
  p=$(center_of "drop me"); ey=${p#* }
  if [ "${ey:-0}" -gt "${dy:-0}" ]; then ok "fell: drop me from y $dy to y $ey"
  else fail "dynamics: drop me at y $dy, then $ey"; fi
  tap "keyboard";  expect "bottom field" 3
  p=$(center_of "bottom field"); ky=${p#* }
  tap "raise keyboard"; sleep 1                  # posts the keyboard's notification: the field lifts out of its way
  p=$(center_of "bottom field"); ry=${p#* }
  tap "lower keyboard"; sleep 1                  # and the keyboard going down returns it
  p=$(center_of "bottom field"); ly=${p#* }
  if [ "${ry:-9999}" -lt "${ky:-0}" ] && [ "${ly:-0}" -eq "${ky:-0}" ]; then ok "keyboard: field lifted from y $ky to y $ry, then back to $ly"
  else fail "keyboard: field at y $ky, raised to $ry, lowered to $ly"; fi
  tap "files";     expect "open files" 3
  tap "open files"; expect "Cancel" 3           # the system's document picker, over the app
  p=$(center_of "Cancel"); axe touch -x "${p% *}" -y "${p#* }" --down --up --delay 0.3 --udid "$UDID" >/dev/null
  sleep 1
  expect "open files" 3                         # its Cancel closes it
  tap "collection"; expect "alpha" 3            # a collection view of sections: the header is on screen
  tap "b2";        expect "tile: 5" 3           # the fifth tile of all six, in the beta section
  expect "beta" 3
  tap "photos";    expect "pick photo" 3
  # the system's photo picker is out of process: the accessibility tree does not list it (checked by a screenshot,
  # where it shows the library), so it is closed by its X, at the top left, and the story is back under it
  tap "pick photo"; sleep 2
  axe touch -x 38 -y 100 --down --up --delay 0.3 --udid "$UDID" >/dev/null
  sleep 1
  expect "pick photo" 3
  tap "next";      expect "A plain label." 3     # round to the first page
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
