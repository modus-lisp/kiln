#!/usr/bin/env bash
# extra-ca-args.sh — what `bin/kiln container --extra-ca' hands the engine.
#
# A stand-in engine echoes its arguments instead of building, so this checks the
# decisions kiln makes before any build starts: the flag is parsed in both spellings,
# the CA reaches the engine only as the `extra_ca' secret, a bad path is refused
# before the engine is called, and everything else is passed through untouched.
# The build itself is t/extra-ca.sh.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KILN="$HERE/../bin/kiln"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kiln-extra-ca-args.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
rc=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; rc=1; }

cat > "$WORK/engine" <<'EOF'
#!/bin/sh
echo "ENGINE-ARGS: $* BUILDKIT=${DOCKER_BUILDKIT:-unset}"
EOF
chmod +x "$WORK/engine"

# A PEM that holds a certificate, for the flag to accept.  Its contents are never
# checked by this script, only that it is present and says what it is.
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$WORK/ca.pem"
printf 'not a certificate\n' > "$WORK/notca.txt"

run() { KILN_ENGINE="$WORK/engine" "$KILN" container "$@" 2>&1; }

out=$(run --extra-ca="$WORK/ca.pem" --no-cache)
case $out in
  *"--secret id=extra_ca,src=$WORK/ca.pem"*) ok "--extra-ca=PATH passes the CA as the extra_ca secret" ;;
  *) fail "--extra-ca=PATH did not reach the engine as a secret: $out" ;;
esac
case $out in
  *"--no-cache"*) ok "other arguments pass through untouched" ;;
  *) fail "--no-cache was dropped: $out" ;;
esac

out=$(run --extra-ca "$WORK/ca.pem")
case $out in
  *"--secret id=extra_ca,src=$WORK/ca.pem"*) ok "--extra-ca PATH (space form) is the same flag" ;;
  *) fail "space form not parsed: $out" ;;
esac

out=$(run)
case $out in
  *"--secret"*) fail "no flag, yet a secret was passed: $out" ;;
  *) ok "without the flag, no secret is passed" ;;
esac
case $out in
  *"ENGINE-ARGS: build"*"BUILDKIT=1"*) ok "without the flag, the build still runs, with BuildKit set" ;;
  *) fail "no build without the flag: $out" ;;
esac

out=$(run --extra-ca="$WORK/missing.pem")
if [ $? -ne 0 ] && [[ $out == *"is not a non-empty file"* ]] && [[ $out != *ENGINE-ARGS* ]]; then
  ok "a missing file is refused before the engine is called"
else fail "missing file not refused cleanly: $out"; fi

out=$(run --extra-ca="$WORK/notca.txt")
if [[ $out == *"holds no PEM certificate"* ]] && [[ $out != *ENGINE-ARGS* ]]; then
  ok "a file with no certificate is refused before the engine is called"
else fail "non-certificate not refused cleanly: $out"; fi

out=$(run --extra-ca)
if [[ $out == *"needs a PATH"* ]] && [[ $out != *ENGINE-ARGS* ]]; then
  ok "--extra-ca with no value is refused"
else fail "missing value not refused cleanly: $out"; fi

exit $rc
