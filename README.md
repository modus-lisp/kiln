# kiln

**A Common Lisp personal computer, fired into a container image.**

`kiln` takes the [modus-lisp](https://github.com/modus-lisp) workspace — a
from-scratch desktop environment, its window manager, its text rasterizer, its
TLS stack, its git, its browser — and turns it into one image you can start with
a single command. It runs on SBCL, in Docker, podman, or Apple's `container`,
and it puts a real OPEN LOOK desktop on your screen over VNC.

```sh
bin/kiln build      # once
bin/kiln vnc        # desktop on vnc://127.0.0.1:5901
```

A kiln is where you fire what you've shaped — the step that turns worked clay
into something that holds its form. The workspace is the clay; this is the
firing.

## What comes up

A wallpapered OPEN LOOK workspace with an Apps menu, served over RFB to any VNC
client. Inside it: a terminal on a real PTY, a web browser
([loom](https://github.com/modus-lisp/loom)), a file browser
([warren](https://github.com/modus-lisp/warren)), a Lisp listener, an inspector,
a debugger, a calculator, an image viewer. Text is anti-aliased and
gamma-correct via [scribe](https://github.com/modus-lisp/scribe); the display is
[glass](https://github.com/modus-lisp/glass), a clean-room RFB server with no
libvncserver and no X11 anywhere in the picture.

The desktop's own control socket is open on `4009`, so you can reach into a
*running* session without restarting it:

```sh
bin/kiln eval '(glass:perf-report)'
```

## The build bootstraps itself in Lisp

The part worth reading the Dockerfile for: **this image checks itself out of
GitHub using the org's own git implementation.**

[cairn](https://github.com/modus-lisp/cairn) is git in pure Common Lisp — the
object model, the pack format, delta resolution, the smart-HTTP transfer
protocol — cloning over HTTPS on [seal](https://github.com/modus-lisp/seal)'s
TLS 1.3, which runs on [natrium](https://github.com/modus-lisp/natrium)'s
crypto. So the clone travels `cairn → seal → natrium` and never leaves Lisp.
**There is no `git` binary in this image.**

cairn can't clone itself into existence, so exactly five repos arrive as
tarballs first — cairn, seal, conch, cram, natrium, a closure with no
third-party dependencies at all. From there Lisp takes over and clones the other
33, including a real checkout of cairn replacing the seed, each pinned to the
commit in [`repos.lock`](repos.lock):

```
seed.sh        5 tarballs, ~2 MB          the only non-Lisp fetch
clone-org.lisp 38 repos, cairn, 4 jobs    every one of them by cairn
build.lisp     load the world, dump core  so startup is ~1s, not ~1min
```

Under all of that, the image builds its own SBCL. Debian trixie ships 2.5.2,
and 2.5.2 cannot compile chord or stave — both hit `The value NIL is not of
type SB-KERNEL:CTYPE`, an internal compiler error rather than anything wrong
with their source. They build cleanly on 2.5.6, so kiln builds 2.5.6 in a
separate stage and copies just the compiler forward. `--build-arg
SBCL_VERSION=` moves it.

`repos.lock` is refreshed the same way — `bin/kiln lock` reads each repo's
`info/refs` through cairn, one HTTPS GET apiece. No GitHub API, no token, no
rate limit.

## Commands

| | |
|---|---|
| `kiln build` | build the image (first run compiles McCLIM — get a coffee) |
| `kiln run` | start the desktop, print its address |
| `kiln vnc` | start it if needed, then open a VNC client |
| `kiln stop` | stop and remove the container |
| `kiln status` | engine, image, container, ports |
| `kiln logs [-f]` | container logs |
| `kiln shell` | a bash prompt inside the running desktop |
| `kiln repl` | an SBCL REPL with the whole world already loaded |
| `kiln eval '(form)'` | evaluate in the **running** desktop, live |
| `kiln test` | glass's RFB self-test in a throwaway container |
| `kiln lock` | refresh `repos.lock` from the org's live refs |
| `kiln clean` | remove the container and the image |

The engine is auto-detected — Apple's `container` on macOS, else docker, else
podman — and `KILN_ENGINE` overrides it. `bin/kiln` starts Apple's system
service for you rather than telling you to.

## Without a container

The container buys isolation: the desktop's terminal is a root shell in a
throwaway filesystem, and the ports are the engine's to publish. `kiln local`
gives none of that — it is your user, your files, your ports. What it gives
instead is that there is nothing to reason about. One SBCL process in `ps`,
reading the checkouts in place, so an edit is live on the next start with no
image to rebuild.

```sh
bin/kiln local            # desktop + gateway on this machine
bin/kiln local --rebuild  # re-dump the core
```

It needs SBCL and a Quicklisp at `~/quicklisp` (McCLIM comes from there). The
first run dumps a core into `~/.kiln`; after that it starts in about a second.

`kiln bundle` packs the sources and a launcher into a folder you can move:

```sh
bin/kiln bundle --zip
```

38 repos, ~85 MB — version control, build artifacts and the external conformance
corpora (test262, wpt) are left out, since they are most of the bytes and none of
the desktop; `--full` keeps them. The bundle's `kiln-run` builds its core *in the
bundle*, from the bundle's own sources, so it works wherever you unpack it — the
wallpaper and fonts resolve to the copy sitting next to them. `repos.lock` travels
with it, recording the commit each repo came from.

## Ports

Every port is derived from `GLASS_DISPLAY` (default 1), X-style, so a second
desktop is one environment variable rather than an edited file:

| | port | display 1 |
|---|---|---|
| VNC / RFB | `5900 + N` | 5901 |
| session audio | `5910 + N` | 5911 |
| control + eval | `4008 + N` | 4009 |

```sh
GLASS_DISPLAY=2 KILN_NAME=kiln2 bin/kiln run    # a second desktop on 5902
```

Only the screen is published. glass binds the session audio and the control
socket to loopback *inside* the container — correctly, since the control socket
is an unauthenticated eval socket — so `kiln eval` reaches it by running in
there rather than through a forwarded port.

## Startup windows

The desktop comes up as a bare workspace; every app is one right-click away on
the root menu. `GLASS_APPS` opens windows at startup instead — a comma-separated
list of `terminal` or McCLIM frame-class names:

```sh
GLASS_APPS=terminal bin/kiln run
```

## How the image is laid out

```
/opt/modus-lisp/     all 38 repos, real cairn checkouts (commit, push, hack)
/opt/kiln/modus.core SBCL core with McCLIM + the desktop preloaded
/usr/local/bin/sbcl  the compiler kiln built for itself
/root/quicklisp/     the third-party half
/kiln/               repos.lock and the boot scripts
```

ASDF finds everything through one tree scan configured in
`/etc/common-lisp/source-registry.conf.d/`, so a bare `sbcl` in the container
can `(asdf:load-system :anything)` with no setup. The scan excludes `vendor` and
`deps`, because scribe carries cram and brotli-pure as submodules and modus
vendors its own chipz — without that, ASDF finds two of each, and modus's
vendored chipz would shadow the Quicklisp one that glass's self-test uses as an
*independent* inflate oracle.

The entry point is glass's own `backend/inspect/serve-desktop.lisp`, not a copy
of it. The core holds only *loaded systems*, so that file's `quickload` calls
return immediately and glass stays the single source of truth for what a desktop
is. kiln does not fork it.

## Honest limits

- **Not everything here is pure Lisp.** The modus-lisp stack is; McCLIM and its
  dependency tree come from Quicklisp and bring the usual ecosystem with them.
  The bootstrap story is about cairn and the org's own code, not about the image
  as a whole.
- **The voice and the ear are silent by default.**
  [chord](https://github.com/modus-lisp/chord) (TTS) and
  [stave](https://github.com/modus-lisp/stave) (a streaming Zipformer
  recognizer) are cloned and built, but their model files are not in any repo.
  Point `GLASS_VOICE` at a `.graph` and `GLASS_EARS` at the recognizer directory
  to wake them up. A silent desktop is a working desktop — the code is written
  to adapt, not to fail.
- **It runs as root**, which is ordinary for a single-user desktop image and
  means the desktop's terminal is a root shell *inside its own container*.
- **The build needs the network**, and reaches three places: Debian's mirrors,
  Quicklisp, and GitHub. Nothing here works air-gapped.
- **On Apple's `container`, guest DNS does not resolve** on a good number of
  Macs — the vmnet gateway is handed out as the resolver and does not answer.
  `bin/kiln` passes an explicit `--dns` (override with `KILN_DNS`) and installs
  the guest kernel on first use, so neither shows up as a mysterious failure
  halfway through a build.
- **VNC is open by default.** glass accepts any password unless
  `~/.glass-vnc-pass` exists. `kiln` publishes only to `127.0.0.1`; before you
  expose it anywhere else, put a password in that file.
- **`kiln lock` refreshes; it does not discover.** The repo list comes from
  `repos.lock`, not from the org listing, so a new repo is a deliberate one-line
  addition rather than something that appears overnight.

## Eventually

The point of this workspace is a Lisp machine on its own hardware —
[modus](https://github.com/modus-lisp/modus) is a bare-metal Lisp OS that boots
into a REPL with no operating system under it, and `glass/fb` is written to drop
onto it directly. kiln is the interim: the same desktop, on somebody else's
kernel, one command away.

MIT. Research / educational; **not audited**.
