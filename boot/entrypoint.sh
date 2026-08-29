#!/bin/sh
# entrypoint.sh — what `kiln run` actually starts inside the container.
#
# The default is the desktop.  The other subcommands exist because this image
# already contains the whole world compiled, and it would be silly to need a
# second one to get a REPL or run the gates.
set -eu

CORE=${KILN_CORE:-/opt/kiln/modus.core}
ROOT=${MODUS_ROOT:-/opt/modus-lisp}
DISPLAY_N=${GLASS_DISPLAY:-1}

# Every entry point runs from the saved core, so the McCLIM compile that the
# image build already paid for is never paid again.
lisp() { exec sbcl --core "$CORE" --control-stack-size 256 --dynamic-space-size "${KILN_HEAP:-4096}" "$@"; }

# modus-lisp's OWN Lisp, as the HOST rather than as a guest.  Everything above
# runs glass on SBCL; this runs it on modus.  There is no --core: modus does not
# save images, so every start pays its own compile of whatever it loads.
#
# A SEPARATE FUNCTION AND NOT A FLAG ON lisp(), because the two are not
# interchangeable — the core has McCLIM in it and modus has none, so the desktop
# cannot be served this way and must not silently try.
MODUS_BIN=${MODUS_BIN:-$ROOT/modus/modus}
modus_lisp() {
  [ -x "$MODUS_BIN" ] || { echo "kiln: no modus binary at $MODUS_BIN" >&2; exit 1; }
  exec "$MODUS_BIN" "$@"
}

# Is something LISTENING on this port, in this namespace?
#
# Not bash's /dev/tcp: this script is #!/bin/sh, which is dash on Debian, and
# dash has no such thing — the loop below silently never succeeded.  And not a
# connect test either, since a connect proves only that something accepted.
# /proc/net/tcp is the direct answer: state 0A is TCP_LISTEN.
port_listening() {
  awk -v p="$(printf '%04X' "$1")" \
      '$4 == "0A" && $2 ~ (":" p "$") { found = 1 } END { exit !found }' \
      /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# The .config, applied.  The reader lives in boot/config.sh because bin/kiln needs the
# same one -- see the note there.
. "$(dirname -- "$0")/config.sh"

load_config

# ---- where the sockets go ----------------------------------------------------
#
# The rootfs is read-only and $HOME is part of it, so glass's default (~/.glass/run)
# cannot be created and the desktop silently falls back to a PORT -- which on a box
# whose gateway is a thread of the desktop's own process is strictly worse: a loopback
# port is open to every uid in the container, a 0700 socket file is not.
#
# /tmp is the one writable place in this image (a 256M tmpfs), and runtime sockets
# belong on a tmpfs anyway -- none of this should survive a restart.
: "${GLASS_RUNTIME_DIR:=/tmp/glass}"
if mkdir -p "$GLASS_RUNTIME_DIR" 2>/dev/null; then
  chmod 700 "$GLASS_RUNTIME_DIR" 2>/dev/null || true
  export GLASS_RUNTIME_DIR
else
  echo "kiln: $GLASS_RUNTIME_DIR is not writable — the screen will use a port" >&2
fi

cmd=${1:-desktop}
[ $# -gt 0 ] && shift

case "$cmd" in
  desktop)
    # glass's own serve-desktop.lisp is the entry point, deliberately: kiln does
    # not reimplement what a desktop is, and this file stays correct as glass
    # changes.  Its quickload calls find everything already in the core.
    echo "kiln: glass desktop :$DISPLAY_N — VNC on $((5900 + DISPLAY_N)), audio $((5910 + DISPLAY_N)), control $((4008 + DISPLAY_N))"
    lisp --load "$ROOT/glass/backend/inspect/serve-desktop.lisp" "$@"
    ;;

  sshd)
    # From the CORE, not a bare sbcl: --script implies --no-userinit, so a plain
    # script sees no Quicklisp and cannot find jzon.  The core already has conch,
    # seal/http and jzon in it, which also makes this start instantly.
    exec sbcl --core "$CORE" --dynamic-space-size 1024 --script /kiln/boot/sshd.lisp
    ;;

  web)
    # The desktop AND the browser gateway, in one container.
    #
    # gateway.lisp (webrtc-data's demo) serves a noVNC page plus one POST /signal
    # for the SDP exchange, then pumps RFB bytes over a WebRTC data channel.  The
    # browser is the RFB client and glass is the RFB server; the gateway is
    # transparent between them.
    #
    # Worth knowing why this needs no TLS and no signalling server: kiln publishes
    # this port to the host's LOOPBACK, and http://localhost is a secure context —
    # verified in Safari, which allows RTCPeerConnection, data channels and even
    # getUserMedia there.  So the local path needs no certificate, no nsite, no
    # relay and no TURN.  The Nostr gateway beside this one is for when the box is
    # NOT the machine you are sitting at; that is a different problem.
    GW_PORT=${GW_PORT:-8765}
    # one.lisp made the gateway opt-in -- rightly, since a service that listens is
    # a thing to ask for.  `web' IS the asking: it is the mode whose whole point is
    # the browser client, and it was announcing a gateway it never started.
    KILN_GATEWAY=1
    export GW_PORT KILN_GATEWAY
    echo "kiln: desktop :$DISPLAY_N + web gateway on $GW_PORT (one image)"
    # The nostr gateway rides in the same image when the config asks for it; one.lisp
    # owns the decision and the identity check, this only says whether it was asked.
    case "${KILN_NOSTR:-}" in
      ''|0|n) echo "kiln: nostr signalling off (KILN_NOSTR in kiln config)" ;;
      *)      echo "kiln: nostr signalling on — reaching this box from away" ;;
    esac
    # The control plane comes up inside one.lisp, on a thread of the same image,
    # when the host mounted an identity for it.
    [ -f "${KILN_ETC:-/etc/kiln}/host_ed25519" ] && { KILN_SSHD=1; export KILN_SSHD; }
    exec sbcl --core "$CORE" --control-stack-size 256 \
         --dynamic-space-size "${KILN_HEAP:-4096}" --load /kiln/boot/one.lisp
    ;;

  repl)
    # A plain REPL with the desktop's whole world already loaded.
    lisp "$@"
    ;;

  modus)
    # modus-lisp's OWN Lisp, hosted: SBCL-faithful toplevel flags (--script,
    # --eval, --load, --non-interactive, --quit), its own self-hosted compiler
    # inside the image.  A REPL and a script runner.  It is NOT the desktop —
    # that is mcclim-glass, and modus has no McCLIM.  For glass's RFB server on
    # modus, see `modus-rfb' below.
    modus_lisp "$@"
    ;;

  modus-rfb)
    # glass's RFB SERVER — the :glass system and nothing above it — running on
    # MODUS instead of on SBCL.  Still not the desktop: mcclim-glass needs
    # McCLIM, sb-concurrency and glass/term, none of which modus has.
    #
    # THE PORT IS AN ARGUMENT AND HAS NO DEFAULT.  With no port this prints
    # usage and exits; it does not pick 5900 and it does not pick an ephemeral
    # one, because a VNC client has to be told a number in advance and a number
    # nobody chose is not one you can be told.  It binds 127.0.0.1 and there is
    # no argument that changes that — publishing a port is kiln's own plumbing,
    # one layer up, where it already is.
    #
    # STALENESS: the binary this runs is built ONCE, in the Dockerfile, from the
    # modus checkout as it stood at image build time.  Editing modus afterwards
    # changes nothing here until the image is rebuilt (`kiln container'), because —
    # unlike the SBCL side, where ASDF loads changed systems over the core on
    # every start — modus is a static ELF with its own compiler baked in and
    # nothing reloads it.  MODUS_BIN overrides the path for a hand-built one.
    port=${1:-}
    [ -n "$port" ] || { echo "usage: kiln run modus-rfb PORT" >&2; exit 2; }
    shift
    case "$port" in
      ''|*[!0-9]*) echo "kiln: modus-rfb: PORT must be a number" >&2; exit 2 ;;
    esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
      echo "kiln: modus-rfb: PORT out of range" >&2; exit 2; }
    echo "kiln: glass RFB on modus — 127.0.0.1:$port"
    MODUS_RFB_PORT=$port
    export MODUS_RFB_PORT
    modus_lisp --script /kiln/boot/modus-rfb.lisp "$@"
    ;;

  test)
    # glass's RFB self-test: draws a known pattern, reads it back through an
    # in-process client, asserts the pixels. Exits non-zero on any failure.
    exec sh "$ROOT/glass/run-tests.sh" "$@"
    ;;

  eval)
    # kiln eval '(+ 1 2)' — one form in the loaded image, printed.
    [ $# -gt 0 ] || { echo "kiln eval: needs a form" >&2; exit 2; }
    form=$1; shift
    lisp --non-interactive --disable-debugger --eval "(print $form)" "$@"
    ;;

  operandi)
    # The agent, in the same fenced container everything else runs in.  It used to
    # need a `kiln agent' invocation to get a non-root uid, dropped capabilities
    # and a read-only rootfs; those are what the image IS now, so this is just
    # another thing to run in it.
    #
    # Worth keeping in view: everything it reads reaches the inference provider in
    # the next request, so the mounts are the disclosure list.  The fences do not
    # cover the network -- a container here can reach the LAN.
    shift
    cd /work 2>/dev/null || cd /tmp
    exec sbcl --core "$CORE" --control-stack-size 256 \
         --dynamic-space-size "${KILN_HEAP:-4096}" \
         --load /opt/modus-lisp/operandi/bin/operandi.lisp "$@"
    ;;

  lock)
    # Refresh repos.lock against the org's live refs and print it to stdout.
    # Runs on a plain sbcl, not the core: the core has no cairn in it.
    exec sbcl --script /kiln/boot/lock.lisp "$@"
    ;;

  shell|sh)
    exec /bin/bash "$@"
    ;;

  version)
    echo "kiln — modus-lisp desktop image"
    sbcl --version
    echo "core:  $CORE"
    echo "repos: $(find "$ROOT" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ') checked out in $ROOT"
    ;;

  *)
    # Anything else: treat it as a command to run, so `kiln run ls /opt` works.
    exec "$cmd" "$@"
    ;;
esac
