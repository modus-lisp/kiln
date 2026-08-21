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
    HOME=/root \
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
         --eval '(quicklisp-quickstart:install :path "/root/quicklisp/")' \
 && rm /tmp/quicklisp.lisp

# --dynamic-space-size is a RUNTIME option and SBCL rejects it once toplevel
# options have started, so it has to come first.
RUN sbcl --dynamic-space-size 4096 --non-interactive --disable-debugger \
         --load /root/quicklisp/setup.lisp \
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
      '(let ((ql (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))' \
      '  (when (probe-file ql) (load ql)))' \
      > /root/.sbclrc

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
RUN sbcl --script boot/clone-org.lisp \
 && rm -rf "$KILN_SEED"

# Load the world and dump it, so `kiln run` starts in about a second.
COPY boot/build.lisp boot/
RUN sbcl --dynamic-space-size 4096 --script boot/build.lisp

COPY boot/entrypoint.sh boot/lock.lisp boot/sshd.lisp boot/config.lisp boot/one.lisp boot/
RUN chmod +x boot/entrypoint.sh boot/seed.sh

# A NON-ROOT USER FOR `kiln agent'.  The desktop still runs as root (its terminal
# is meant to be a root shell in a throwaway filesystem), but an agent driven by a
# model you did not write has no business being uid 0 even in here.  It needs a
# real passwd entry and a home: without one, --user 1000:1000 lands somewhere with
# no $HOME and SBCL goes looking for a cache directory it cannot have.
RUN useradd -u 1000 -m -s /bin/bash kiln \
 && chmod -R a+rX /opt/modus-lisp /kiln

# VNC / RFB, session audio, the control+eval socket (GLASS_DISPLAY=1), and the
# browser gateway.
EXPOSE 5901 5911 4009 8765 2222

ENV GLASS_DISPLAY=1
ENTRYPOINT ["/kiln/boot/entrypoint.sh"]
CMD ["desktop"]
