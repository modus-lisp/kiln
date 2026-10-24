#!/usr/bin/env bash
# extra-ca.sh — `--extra-ca' against a network that intercepts TLS.
#
# Makes a throwaway CA, puts an interceptor that signs with it on the build's network,
# and then:
#   1. builds the sbcl stage WITHOUT the secret, which must fail at the SBCL download
#      with a certificate error.  That proves the interceptor is really in the path.
#   2. builds the whole image WITH the secret, which must succeed and log the trusted
#      CA's fingerprint.
#   3. checks the finished image's system bundle does NOT hold the throwaway CA, and
#      that it still holds the public roots.  The secret trusted the CA for the fetches
#      and nothing else.
#
# This is an image gate, not part of run-tests.sh: the full build takes the better
# part of an hour, and it needs docker with BuildKit and the ability to run a
# container on the default bridge.
#
#   t/extra-ca.sh [IMAGE-TAG]
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/.." && pwd)
TAG=${1:-kiln-extra-ca-test}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kiln-extra-ca.XXXXXX")
NAME="kiln-extra-ca-$$"
export DOCKER_BUILDKIT=1
rc=0
group() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; rc=1; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1
  docker rmi -f "$TAG-nosecret" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

command -v docker >/dev/null || { echo "extra-ca: needs docker"; exit 2; }
command -v openssl >/dev/null || { echo "extra-ca: needs openssl"; exit 2; }

group "throwaway CA and interceptor certificate"
mkdir -p "$WORK/mock"
cp "$HERE/extra-ca/interceptor.py" "$WORK/mock/"
cp /etc/ssl/certs/ca-certificates.crt "$WORK/mock/host-roots.pem"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" -out "$WORK/ca.pem" \
  -days 2 -subj "/CN=kiln test interceptor CA" 2>/dev/null
printf 'subjectAltName=DNS:github.com,DNS:codeload.github.com,DNS:beta.quicklisp.org\nbasicConstraints=CA:FALSE\n' > "$WORK/leaf.ext"
openssl req -newkey rsa:2048 -nodes -keyout "$WORK/mock/leaf.key" -out "$WORK/leaf.csr" \
  -subj "/CN=github.com" 2>/dev/null
openssl x509 -req -in "$WORK/leaf.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" -CAcreateserial \
  -out "$WORK/mock/leaf.pem" -days 2 -extfile "$WORK/leaf.ext" 2>/dev/null
openssl verify -CAfile "$WORK/ca.pem" "$WORK/mock/leaf.pem" >/dev/null && ok "leaf signed by the throwaway CA"

group "interceptor"
# The interceptor reaches the real hosts by their real addresses, pinned here, so it
# cannot resolve its own alias and loop.
hosts=()
for h in github.com codeload.github.com beta.quicklisp.org; do
  ip=$(getent hosts "$h" | awk '{print $1; exit}')
  [ -n "$ip" ] || { fail "cannot resolve $h on this host"; exit 1; }
  hosts+=(--add-host "$h:$ip")
done
docker run -d --name "$NAME" "${hosts[@]}" -e SSL_CERT_FILE=/mock/host-roots.pem \
  -v "$WORK/mock:/mock:ro" python:3.11-slim python3 -I /mock/interceptor.py >/dev/null || { fail "interceptor did not start"; exit 1; }
sleep 3
IP=$(docker inspect -f '{{with index .NetworkSettings.Networks "bridge"}}{{.IPAddress}}{{end}}' "$NAME")
[ -n "$IP" ] || { fail "interceptor has no bridge address"; exit 1; }
# The build's RUNs reach the same names through the interceptor.
build_hosts=(--add-host "github.com:$IP" --add-host "codeload.github.com:$IP" --add-host "beta.quicklisp.org:$IP")
ok "interceptor on $IP"

group "1. without --extra-ca: the SBCL download must be refused"
# --no-cache, as in step 2: the cache ignores secrets, so a cached sbcl stage from a
# build that had the CA would pass here without ever being refused.
if docker build --no-cache --target sbcl "${build_hosts[@]}" -t "$TAG-nosecret" "$ROOT" > "$WORK/nosecret.log" 2>&1; then
  fail "the build succeeded through an interceptor it should not trust"
elif grep -q "certificate problem" "$WORK/nosecret.log"; then
  ok "refused with a certificate error, as the interceptor should cause"
else
  fail "build failed, but not on the certificate: $(grep -m1 -i 'error' "$WORK/nosecret.log")"
fi

group "2. with --extra-ca: the whole image builds and logs the fingerprint"
# --no-cache: BuildKit does not key a cached RUN on its secret, so a cached layer from
# an earlier build would skip the very fetches this step is testing.
if docker build --no-cache --progress=plain --secret "id=extra_ca,src=$WORK/ca.pem" "${build_hosts[@]}" \
     -t "$TAG" "$ROOT" > "$WORK/build.log" 2>&1; then
  ok "image $TAG built"
else
  fail "build failed; see $WORK/build.log (kept)"
  trap - EXIT; docker rm -f "$NAME" >/dev/null 2>&1; exit 1
fi
if grep -Eq '@@ trust extra-ca [0-9a-f]{64}' "$WORK/build.log"; then
  ok "build logged the trusted CA: $(grep -Eo '@@ trust extra-ca [0-9a-f]{64}' "$WORK/build.log" | head -1)"
else
  fail "no '@@ trust extra-ca' line in the build log"
fi

group "3. the finished image does not trust the throwaway CA"
line=$(sed -n 2p "$WORK/ca.pem")
hits=$(docker run --rm --entrypoint sh "$TAG" -c "grep -cF '$line' /etc/ssl/certs/ca-certificates.crt")
if [ "$hits" = "0" ]; then ok "the throwaway CA is absent from the system bundle"
else fail "the throwaway CA is in the system bundle ($hits matches)"; fi
public=$(docker run --rm --entrypoint sh "$TAG" -c "grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt")
if [ "${public:-0}" -gt 100 ]; then ok "the public roots are still there ($public certificates)"
else fail "system bundle has $public certificates; expected the public set"; fi

if [ "$rc" = 0 ]; then echo; echo "extra-ca: all checks passed"; else echo; echo "extra-ca: FAILED"; fi
exit $rc
