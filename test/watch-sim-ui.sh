#!/bin/sh
# watch-sim-ui.sh -- drive the booted watch Simulator's storybook (vessel/src/watch-storybook.lisp) and check
# what it shows.  The app opens on the storybook: `kiln ios watch --install` puts it there.
#
#   kiln/test/watch-sim-ui.sh [UDID]       the booted watch by default
#
# The helpers are ios-sim-ui.sh's (tap, expect, tap_at, swipe_points ...).  Coordinates are points on a 46 mm
# watch (208 x 248).  LAUNCH=1 relaunches the app first; NO_RESTART=1 skips restarting the simulator.
set -eu
UDID=${1:-$(xcrun simctl list devices booted | awk -F'[()]' '/Watch/ { print $2; exit }')}
[ -n "$UDID" ] || { echo "no booted watch simulator" >&2; exit 2; }
SHOTS=${SHOTS:-/tmp/watch-sim-ui}
SIM_UI_LIB=1 . "$(dirname "$0")/ios-sim-ui.sh"
set +e   # a failed check is counted, and the suite goes on

# AXe loses the watch's accessibility automation after the app is reinstalled ("could not restore accessibility
# automation"), sometimes a minute into a run that began well; only a restart of the simulator brings it back.  So
# the suite starts from a restarted watch, unless NO_RESTART=1 (or AXe answers and the app was not just installed).
if [ -z "${NO_RESTART:-}" ] || axe describe-ui --udid "$UDID" 2>&1 | grep -q "could not restore"; then
  echo "(restarting the watch: AXe loses it after a reinstall)"
  xcrun simctl shutdown "$UDID"; xcrun simctl boot "$UDID"; sleep 25
  LAUNCH=1
fi
if [ -n "${LAUNCH:-}" ]; then
  xcrun simctl terminate "$UDID" org.modus-lisp.modus.watch >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" org.modus-lisp.modus.watch >/dev/null
  sleep 12
fi

# next STORY: step forward to the story titled STORY (at most 20 steps)
to_story() {
  i=0
  while [ "$i" -lt 20 ]; do
    on_screen "$1" && { ok "story: $1"; return 0; }
    p=$(center_of next); [ -n "$p" ] && tap_at "${p% *}" "${p#* }"
    i=$((i + 1))
  done
  fail "no story titled $1"
}

expect "prev" 10 || { echo "== the storybook is not open"; exit 1; }
expect "A plain label." 3

to_story "button";   expect "tapped 0 times" 3
tap "tap me";        expect "tapped 1 times" 3
tap "tap me";        expect "tapped 2 times" 3

to_story "switch";   expect "off" 3
tap_at 170 110;       expect "on" 3        # the toggle, on its right
tap_at 170 110;      expect "off" 3

to_story "slider";   expect "value 50" 3
tap_at 190 110;      expect "value 60" 3                    # a watch slider steps: its + end
tap_at 18 110;       expect "value 50" 3                    # and its - end

to_story "stepper";  expect "step 5" 3
tap_at 180 120;      expect "step 6" 3

to_story "progress"; expect "progress 30" 3
tap "more";          expect "progress 40" 3

to_story "gauge";    expect "gauge 40" 3
tap "fill";          expect "gauge 60" 3

to_story "picker";   expect "picked: none" 3
tap "pick blue";      expect "picked: blue" 3            # the wheel turned from code (AXe can neither drag a watch
                                                            # wheel nor turn the crown)
shot watch-picker

to_story "list";     expect "row 1" 3
tap "row 2";         expect "selected: row 2" 3

to_story "crown";    expect "crown 0" 3
# the Digital Crown: AXe has no crown, so this is the readout alone (OPEN: drive it with XCUITest's rotate)

to_story "alert";    expect "answer: none" 3
tap "ask";           expect "Really?" 5
tap "no";            expect "answer: no" 5

to_story "sheet";    expect "sheet: closed" 3
tap "open";          expect "in the sheet" 5
tap "shut";          expect "sheet: shut" 5

to_story "nav"
tap "navigate";      expect "go deeper" 5
tap "go deeper";     expect "the pushed page" 5
shot watch-nav
tap "Back";          expect "go deeper" 5                   # the navigation stack's back button
tap "Close";         expect "nav: closed" 5                 # the sheet's own close: a :dismiss event

to_story "tabs";     expect "tab 0" 3
tap "open tabs";     expect "first tab" 5
swipe_points 104 180 104 60; expect "tab 1" 5               # a vertical page: the next tab, a :select event
expect "second tab" 3
tap "Close";         expect_not "second tab" 5

to_story "date";     expect "date: unchanged" 3
shot watch-date

to_story "image"
expect "a symbol" 3

shot watch-done
echo "== $PASS passed, $FAIL failed (screenshots in $SHOTS)"
[ "$FAIL" = 0 ]
