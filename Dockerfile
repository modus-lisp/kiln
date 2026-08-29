# kiln — the modus-lisp personal desktop, fired into a container image.
#
# The interesting part of this build is that almost none of it is this file.
# After apt and Quicklisp, the image assembles itself in Common Lisp: five
# seed repos arrive as tarballs, and then *cairn* — the org's own from-scratch
# git implementation — clones the other 33 out of GitHub over seal's TLS.
# There is no `git` binary in this image.
#
#   docker build -t modus-lisp/kiln .
#   container build -t modus-lisp/kiln .        # Apple container, same file
#
# Layer order is chosen so the slow, rarely-invalidated work (apt, Quicklisp,
# McCLIM) sits below repos.lock, and bumping a pin only re-runs the clone and
# the final core dump.

# ---- stage 1: a newer SBCL than Debian ships ------------------------------
#
# Debian trixie has SBCL 2.5.2, and 2.5.2 cannot compile chord or stave — both
# die with "The value NIL is not of type SB-KERNEL:CTYPE", an internal compiler
# error, not a bug in their source.  They build cleanly on 2.5.6.  Since those
# two ARE the desktop's voice and its ear, the fix is a newer compiler rather
# than a shorter feature list.
#
# Built in its own stage so the final image gets the compiler without the
# toolchain that produced it.  Bootstrapped by Debian's own sbcl, which is what
# it is good for.
ARG SBCL_VERSION=2.5.6

FROM debian:trixie-slim AS sbcl
ARG SBCL_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
        sbcl curl ca-certificates build-essential zlib1g-dev libzstd-dev \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://github.com/sbcl/sbcl/archive/refs/tags/sbcl-${SBCL_VERSION}.tar.gz" \
      | tar -xz \
 && cd "sbcl-sbcl-${SBCL_VERSION}" \
 && sh make.sh --fancy --prefix=/usr/local \
 && INSTALL_ROOT=/usr/local sh install.sh \
 && cd / && rm -rf "/sbcl-sbcl-${SBCL_VERSION}"

# ---- stage 2: the desktop -------------------------------------------------

FROM debian:trixie-slim

LABEL org.opencontainers.image.title="kiln" \
      org.opencontainers.image.description="The modus-lisp desktop: a Common Lisp personal computer, on SBCL, in a container." \
      org.opencontainers.image.source="https://github.com/modus-lisp/kiln" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/kiln \
    MODUS_ORG=modus-lisp \
    MODUS_ROOT=/opt/modus-lisp \
    KILN_SEED=/opt/kiln-seed \
    KILN_LOCK=/kiln/repos.lock \
    KILN_CORE=/opt/kiln/modus.core \
    SBCL_HOME=/usr/local/lib/sbcl \
    LANG=C.UTF-8

# sbcl runs everything; curl fetches exactly two things (the seed tarballs and
# Quicklisp) and is then only a convenience.  The rest is what makes the
# desktop's own terminal emulator a useful place to be.
# The compiler from stage 1, without the toolchain that built it.
COPY --from=sbcl /usr/local/bin/sbcl /usr/local/bin/sbcl
COPY --from=sbcl /usr/local/lib/sbcl /usr/local/lib/sbcl

# No `sbcl` package here on purpose — /usr/local/bin/sbcl is the one we want,
# and Debian's would only shadow it depending on PATH order.  curl fetches
# exactly two things (the seed tarballs and Quicklisp); the rest is what makes
# the desktop's own terminal emulator a useful place to be.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates \
        bash coreutils procps less nano \
    && rm -rf /var/lib/apt/lists/*

RUN sbcl --version

# Every repo visible to ASDF, in one tree scan.  The exclusions matter: scribe
# carries deps/cram and deps/brotli-pure as submodules and modus vendors its own
# chipz, and without excluding those a scan finds two of each — and would let
# modus's vendored chipz shadow the Quicklisp one that glass's self-test uses as
# an *independent* inflate oracle.  Listing the VCS names too because naming
# :exclude at all replaces ASDF's defaults rather than adding to them.
RUN mkdir -p /etc/common-lisp/source-registry.conf.d \
 && printf '%s\n' \
      '(:exclude "vendor" "deps" ".git" ".hg" ".svn" "_darcs" "CVS")' \
      '(:tree "/opt/modus-lisp/")' \
      > /etc/common-lisp/source-registry.conf.d/50-modus-lisp.conf

# Quicklisp, and the third-party half of the desktop (McCLIM and friends).
# Above repos.lock on purpose: this is the slowest layer in the build and it has
# nothing to do with which commit any modus-lisp repo is pinned to.
RUN curl -fsSL -o /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp \
 && sbcl --non-interactive --disable-debugger \
         --load /tmp/quicklisp.lisp \
         --eval '(quicklisp-quickstart:install :path "/opt/quicklisp/")' \
 && rm /tmp/quicklisp.lisp

# --dynamic-space-size is a RUNTIME option and SBCL rejects it once toplevel
# options have started, so it has to come first.
RUN sbcl --dynamic-space-size 4096 --non-interactive --disable-debugger \
         --load /opt/quicklisp/setup.lisp \
         --eval '(handler-bind ((warning (function muffle-warning))) (ql:quickload (list :mcclim :mcclim-render :clim-examples :clim-listener :chipz)))'

# Make Quicklisp present for a bare `sbcl`, not just for scripts that load
# setup.lisp themselves.  glass's own run-tests.sh (which `kiln test` runs
# unmodified, because kiln does not fork glass) starts a plain sbcl and expects
# to find chipz — the independent inflate oracle its RFB self-test checks the
# ZRLE stream against.  Without this it cannot.
#
# Deliberately below the McCLIM layer so adding it does not recompile McCLIM,
# and harmless to the boot scripts: `sbcl --script` ignores the init file.
RUN printf '%s\n' \
      '(let ((ql #p"/opt/quicklisp/setup.lisp"))' \
      '  (when (probe-file ql) (load ql)))' \
      > /etc/sbclrc

# ---- from here down, everything is pinned by repos.lock -------------------

WORKDIR /kiln
COPY repos.lock ./
COPY boot/seed.sh boot/

# The seed: cairn + seal + conch + cram + natrium, as tarballs, because cairn
# cannot clone itself into existence.  Five repos with no third-party
# dependencies at all.
RUN sh boot/seed.sh

# And then Lisp takes over.  cairn clones all 38 repos — including a real
# checkout of cairn itself, replacing the seed, which is deleted in this same
# layer so it never reaches the image.
COPY boot/clone-org.lisp boot/
# --dynamic-space-size, because cairn holds a whole packfile in memory while it
# resolves deltas, and the biggest repos here (weft carries test vectors) have
# outgrown SBCL's default heap.  Four clones run at once, so the ceiling is per
# job and they share it.
RUN sbcl --dynamic-space-size 4096 --script boot/clone-org.lisp \
 && rm -rf "$KILN_SEED"

# Load the world and dump it, so `kiln run` starts in about a second.
COPY boot/build.lisp boot/
RUN sbcl --dynamic-space-size 4096 --script boot/build.lisp

# THE MODUS CLI — modus-lisp's own Lisp, hosted, as an ordinary ELF beside the
# SBCL core.  A second Lisp in the image is deliberate: it is the one this
# project is ultimately FOR, and having it here means `kiln modus' is a command
# rather than a build.  It is a static binary with no runtime dependency on
# SBCL — SBCL only cross-builds it, here, once.
#
# It does NOT run the desktop and is not meant to: the desktop is mcclim-glass,
# and modus has no McCLIM.  What it CAN do, as of this build, is run glass's RFB
# SERVER — modus grew native threads and sb-bsd-sockets, so the :glass system
# loads and `kiln modus-rfb PORT' serves a framebuffer to a real VNC client with
# glass's per-client reader and sender threads on modus's threads.
#
# BUILT ONCE, HERE, AND NEVER RELOADED.  The SBCL side loads changed systems
# over the core on every start, so editing a checkout is live; modus is a static
# ELF with its own compiler baked in, so editing the modus checkout changes
# nothing until this layer is rebuilt.  That is what `kiln build' is for, and
# MODUS_BIN in the entry point is the escape hatch for a hand-built one.
# MODUS_CLI_OUT is not optional: the build's default output path is the RELATIVE
# name "modus", so with WORKDIR /kiln it would land in /kiln and the test below
# would fail on a path that does not exist.  Name it outright.
RUN MODUS_CLI_OUT="$MODUS_ROOT/modus/modus" \
    sbcl --dynamic-space-size 4096 --script "$MODUS_ROOT/modus/mvm/build-generic-cli.lisp" \
 && test -x "$MODUS_ROOT/modus/modus" \
 && chmod a+rx "$MODUS_ROOT/modus/modus"

# THE WHOLE OF boot/, not a list of the files somebody remembered.
#
# This was a hand-maintained list and it drifted twice: boot/config.sh arrived with the
# .config reader and was never added, so the entrypoint died on its first line —
# `cannot open /kiln/boot/config.sh' — for every `kiln test' and every `kiln run' since;
# and boot/session.lisp arrived with session identity and was never added either, which
# is why a container reported "no identity".  Both are files the RUNTIME needs and
# neither is visible from here as anything but a name in a string.
#
# The list bought nothing.  It sits after every expensive step, so the layer it
# invalidates is the cheap one at the end, and the directory is a dozen small files.
# What it cost was a class of failure that only shows up when the image runs.
COPY boot/ boot/
RUN chmod +x boot/entrypoint.sh boot/seed.sh

# THE USER EVERYTHING RUNS AS.  Not a flag on one subcommand -- the fences are
# either the default or they are decoration, and what runs is the default.  The
# desktop used to be root on the argument that its terminal was a root shell in a
# throwaway filesystem; that terminal is a Unix artifact on the way out, and the
# listener that replaces it is inside this image rather than a process under it.
#
# The passwd entry and a real home are load-bearing: without them uid 1000 lands
# somewhere it cannot write and SBCL goes looking for a cache directory it cannot
# have -- which is exactly how this broke the first time it was tried.
RUN useradd -u 1000 -m -d /home/kiln -s /bin/bash kiln \
 && chmod -R a+rX /opt/modus-lisp /kiln /opt/quicklisp \
 && mkdir -p /home/kiln/.cache && chown -R 1000:1000 /home/kiln

# EVERY container gets a read-only rootfs, so nothing may assume it can write
# beside its source.  ASDF's default output is next to the .asd; send it to /tmp,
# which is the one place a fenced container always has (tmpfs, dies with it).
ENV ASDF_OUTPUT_TRANSLATIONS="/:/tmp/fasl/"

# The image runs as this user.  Not a flag on one subcommand: a container that is
# only unprivileged when invoked a particular way is a container that is
# privileged by default, and the default is what runs.
USER 1000:1000

# VNC / RFB, session audio, the control+eval socket (GLASS_DISPLAY=1), and the
# browser gateway.
EXPOSE 5901 5911 4009 8765 2222

ENV GLASS_DISPLAY=1
ENTRYPOINT ["/kiln/boot/entrypoint.sh"]
CMD ["desktop"]
