#!/usr/bin/env bash
# https-proxy.sh — what `--https-proxy' decides, without a network.
#
#   bin/kiln container --https-proxy=URL   what reaches the engine, and what is printed
#   boot/clone-org.lisp (INSTALL-PROXY)    what the clones are routed through, and what
#                                          is logged
#
# A proxy URL can carry credentials, so every check that prints anything also checks
# the password is not in it.  clone-org runs against an EMPTY lock, so it makes every
# decision it makes before its first clone and then has nothing to fetch.  The build
# itself, through a real proxy, is t/https-proxy-image.sh.
#
#   t/https-proxy.sh
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/.." && pwd)
KILN="$ROOT/bin/kiln"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kiln-https-proxy.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
rc=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; rc=1; }
group() { printf '\n\033[1m%s\033[0m\n' "$1"; }
SECRET=s3cret-do-not-print

group "bin/kiln container --https-proxy"
cat > "$WORK/engine" <<'EOF'
#!/bin/sh
echo "ENGINE-ARGS: $*"
EOF
chmod +x "$WORK/engine"
run() { KILN_ENGINE="$WORK/engine" "$KILN" container "$@" 2>&1; }

out=$(run --https-proxy=http://proxy.example:3128)
case $out in
  *"--build-arg HTTPS_PROXY=http://proxy.example:3128 --build-arg https_proxy=http://proxy.example:3128"*)
    ok "the proxy reaches the engine as both predefined proxy build args" ;;
  *) fail "proxy build args missing: $out" ;;
esac
case $out in *"https proxy: proxy.example:3128"*) ok "host and port are reported" ;;
  *) fail "no proxy report: $out" ;; esac

out=$(run --https-proxy "http://kiln:$SECRET@proxy.example:3128")
case $out in *"--build-arg HTTPS_PROXY=http://kiln:$SECRET@proxy.example:3128"*)
  ok "credentials reach the engine (the build needs them)" ;;
  *) fail "credentialled proxy not passed: $out" ;; esac
report=$(printf '%s\n' "$out" | grep -v '^ENGINE-ARGS:')
case $report in *"$SECRET"*) fail "kiln printed the proxy password: $report" ;;
  *) ok "kiln's own output never shows the password" ;; esac
case $report in *"with credentials, not shown"*) ok "and says that there are credentials" ;;
  *) fail "no credentials note: $report" ;; esac

out=$(run --https-proxy=https://proxy.example:3128)
if [[ $out == *"expected http://"* && $out != *ENGINE-ARGS* ]]; then ok "an https:// proxy URL is refused"
else fail "https:// proxy URL not refused: $out"; fi
out=$(run --https-proxy=http://proxy.example)
if [[ $out == *"expected http://"* && $out != *ENGINE-ARGS* ]]; then ok "a proxy URL with no port is refused"
else fail "port-less proxy URL not refused: $out"; fi
out=$(run --https-proxy)
if [[ $out == *"needs a URL"* && $out != *ENGINE-ARGS* ]]; then ok "--https-proxy with no value is refused"
else fail "missing value not refused: $out"; fi
out=$(run)
case $out in *HTTPS_PROXY*) fail "no flag, yet a proxy was passed: $out" ;;
  *) ok "without the flag, no proxy is passed" ;; esac

group "clone-org.lisp: where the clones go"
command -v sbcl >/dev/null || { printf '  skip no sbcl on PATH\n'; exit $rc; }
mkdir -p "$WORK/seed"
for r in cairn seal conch cram natrium cl-transport; do
  [ -d "$ROOT/../$r" ] || { printf '  skip no working copy of %s beside kiln\n' "$r"; exit $rc; }
  cp -r "$ROOT/../$r" "$WORK/seed/$r"
done
: > "$WORK/empty.lock"
clone() {
  OUT=$(env -u HTTPS_PROXY -u https_proxy -u KILN_EXTRA_CA "$@" KILN_SEED="$WORK/seed" \
        KILN_LOCK="$WORK/empty.lock" MODUS_ROOT="$WORK/root" \
        sbcl --script "$ROOT/boot/clone-org.lisp" 2>&1)
  STATUS=$?
}

clone
[ $STATUS = 0 ] && [[ $OUT == *"proxy: none, connecting directly"* ]] \
  && ok "no proxy: clones connect directly" || fail "no proxy: $STATUS $OUT"

clone HTTPS_PROXY=http://proxy.example:3128
if [ $STATUS = 0 ] && printf '%s\n' "$OUT" | grep -qx '@@ proxy http-connect proxy.example:3128'; then
  ok "HTTPS_PROXY: clones go through http-connect to host:port"
else fail "HTTPS_PROXY: $STATUS $OUT"; fi

clone https_proxy=http://proxy.example:3128
[ $STATUS = 0 ] && [[ $OUT == *"@@ proxy http-connect proxy.example:3128"* ]] \
  && ok "lowercase https_proxy is honoured too" || fail "https_proxy: $STATUS $OUT"

clone HTTPS_PROXY="http://kiln%40corp:$SECRET@proxy.example:3128/"
if [ $STATUS = 0 ] && [[ $OUT == *"@@ proxy http-connect proxy.example:3128 (with credentials)"* ]]; then
  ok "credentials: noted, with a percent-escaped user and a trailing slash"
else fail "credentialled proxy: $STATUS $OUT"; fi
case $OUT in *"$SECRET"*) fail "clone-org printed the proxy password" ;;
  *) ok "clone-org's output never shows the password" ;; esac

clone HTTPS_PROXY="https://kiln:$SECRET@proxy.example:3128"
if [ $STATUS != 0 ] && [[ $OUT == *"must be an http:// URL"* && $OUT != *"$SECRET"* ]]; then
  ok "an https:// proxy is refused, without quoting the URL"
else fail "https:// proxy: $STATUS $OUT"; fi

clone HTTPS_PROXY="http://kiln:$SECRET@proxy.example"
if [ $STATUS != 0 ] && [[ $OUT == *"must name a host and a port"* && $OUT != *"$SECRET"* ]]; then
  ok "a proxy with no port is refused, without quoting the URL"
else fail "port-less proxy: $STATUS $OUT"; fi

echo
[ $rc = 0 ] && echo "https-proxy: all checks passed" || echo "https-proxy: FAILED"
exit $rc
