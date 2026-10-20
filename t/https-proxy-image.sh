#!/usr/bin/env bash
# https-proxy-image.sh — `kiln container' on a network with no direct route out.
#
# The network a corporate build meets: GitHub cannot be reached directly, the only
# way out is an HTTP proxy that tunnels with CONNECT and wants credentials, and TLS
# behind it is intercepted.  So the build needs BOTH --https-proxy and --extra-ca.
#
#   1. without --https-proxy the sbcl stage must fail: direct is really closed.
#   2. with both flags, through bin/kiln itself, the whole image builds; the build log
#      names the proxy and the trusted CA, and the proxy saw authenticated tunnels to
#      every forge host the build uses.
#   3. the image keeps nothing of either: no password and no proxy setting in its
#      history or its environment, and no throwaway CA in its system bundle.
#
# Direct is closed by pointing github.com and codeload.github.com at 127.0.0.1 for the
# build's RUNs.  beta.quicklisp.org is left alone: Quicklisp's dists are plain HTTP,
# which this flag does not cover (and the https bootstrap goes through the proxy).
#
# An image gate: the full build takes the better part of an hour, and needs docker with
# BuildKit and the default bridge.
#
#   t/https-proxy-image.sh [IMAGE-TAG]
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/.." && pwd)
TAG=${1:-kiln-https-proxy-test}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kiln-https-proxy-image.XXXXXX")
ICPT="kiln-icpt-$$"; PRX="kiln-proxy-$$"
PASSWORD="pw-$$-not-for-the-image"
export DOCKER_BUILDKIT=1
rc=0
group() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; rc=1; }
cleanup() {
  docker rm -f "$ICPT" "$PRX" >/dev/null 2>&1
  docker rmi -f "$TAG-direct" >/dev/null 2>&1
  [ "${KEEP:-}" ] || rm -rf "$WORK"
}
trap cleanup EXIT
command -v docker >/dev/null && command -v openssl >/dev/null || { echo "needs docker and openssl"; exit 2; }

group "the network: a throwaway CA, an interceptor, and a CONNECT proxy in front of it"
mkdir -p "$WORK/mock"
cp "$HERE/extra-ca/interceptor.py" "$HERE/extra-ca/connect_proxy.py" "$WORK/mock/"
cp /etc/ssl/certs/ca-certificates.crt "$WORK/mock/host-roots.pem"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" -out "$WORK/ca.pem" \
  -days 2 -subj "/CN=kiln test interceptor CA" 2>/dev/null
printf 'subjectAltName=DNS:github.com,DNS:codeload.github.com,DNS:beta.quicklisp.org\nbasicConstraints=CA:FALSE\n' > "$WORK/leaf.ext"
openssl req -newkey rsa:2048 -nodes -keyout "$WORK/mock/leaf.key" -out "$WORK/leaf.csr" -subj "/CN=github.com" 2>/dev/null
openssl x509 -req -in "$WORK/leaf.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" -CAcreateserial \
  -out "$WORK/mock/leaf.pem" -days 2 -extfile "$WORK/leaf.ext" 2>/dev/null
real=()
for h in github.com codeload.github.com beta.quicklisp.org; do
  ip=$(getent hosts "$h" | awk '{print $1; exit}'); [ -n "$ip" ] || { fail "cannot resolve $h"; exit 1; }
  real+=(--add-host "$h:$ip")
done
docker run -d --name "$ICPT" "${real[@]}" -e SSL_CERT_FILE=/mock/host-roots.pem \
  -v "$WORK/mock:/mock:ro" python:3.11-slim python3 -I /mock/interceptor.py >/dev/null
sleep 3
ICPT_IP=$(docker inspect -f '{{with index .NetworkSettings.Networks "bridge"}}{{.IPAddress}}{{end}}' "$ICPT")
# The proxy reaches the forge only through the interceptor: TLS behind it is intercepted.
docker run -d --name "$PRX" --add-host "github.com:$ICPT_IP" --add-host "codeload.github.com:$ICPT_IP" \
  --add-host "beta.quicklisp.org:$ICPT_IP" -v "$WORK/mock:/mock:ro" \
  python:3.11-slim python3 -u /mock/connect_proxy.py 3128 >/dev/null
sleep 3
PRX_IP=$(docker inspect -f '{{with index .NetworkSettings.Networks "bridge"}}{{.IPAddress}}{{end}}' "$PRX")
[ -n "$ICPT_IP" ] && [ -n "$PRX_IP" ] && ok "interceptor $ICPT_IP, proxy $PRX_IP" || { fail "network did not start"; exit 1; }
closed=(--add-host "github.com:127.0.0.1" --add-host "codeload.github.com:127.0.0.1")

group "1. without --https-proxy: direct is closed, so the sbcl stage must fail"
if docker build --no-cache --target sbcl --secret "id=extra_ca,src=$WORK/ca.pem" "${closed[@]}" \
     -t "$TAG-direct" "$ROOT" > "$WORK/direct.log" 2>&1; then
  fail "the build reached the forge with no proxy: direct is not closed"
elif grep -q "Failed to connect\|Couldn't connect\|Connection refused" "$WORK/direct.log"; then
  ok "refused at the connect, as a closed network should be"
else fail "failed, but not at the connect: $(grep -m1 -i error "$WORK/direct.log")"; fi

group "2. with --https-proxy and --extra-ca, through bin/kiln: the whole image builds"
PROXY_URL="http://kiln:$PASSWORD@$PRX_IP:3128"
if KILN_ENGINE=docker KILN_IMAGE="$TAG" "$ROOT/bin/kiln" container \
     --extra-ca="$WORK/ca.pem" --https-proxy="$PROXY_URL" \
     --no-cache --progress=plain "${closed[@]}" > "$WORK/build.log" 2>&1; then
  ok "image $TAG built"
else
  fail "build failed; log kept at $WORK/build.log"; KEEP=1; exit 1
fi
grep -q "@@ proxy http-connect $PRX_IP:3128 (with credentials)" "$WORK/build.log" \
  && ok "the clones went through the proxy, and the log says so" || fail "no proxy line in the build log"
grep -Eq '@@ trust extra-ca [0-9a-f]{64}' "$WORK/build.log" \
  && ok "the trusted CA is logged" || fail "no trust line in the build log"
docker logs "$PRX" > "$WORK/proxy.log" 2>&1
want="auth Basic $(printf 'kiln:%s' "$PASSWORD" | base64 -w0)"
for h in github.com codeload.github.com beta.quicklisp.org; do
  if grep -q "^tunnel $h:443 $want\$" "$WORK/proxy.log"; then ok "the proxy saw authenticated tunnels to $h"
  else fail "no authenticated tunnel to $h in the proxy's log"; fi
done
if grep -q "noauth" "$WORK/proxy.log"; then fail "a tunnel arrived without credentials"
else ok "every tunnel carried credentials"; fi

group "3. the image keeps none of it"
hist=$(docker history --no-trunc "$TAG" 2>&1)
case $hist in *"$PASSWORD"*|*"$PRX_IP"*) fail "the proxy URL is in the image history" ;;
  *) ok "no proxy URL or password in the image history" ;; esac
envs=$(docker inspect -f '{{json .Config.Env}}' "$TAG")
case $envs in *PROXY*|*proxy*) fail "a proxy variable is in the image environment: $envs" ;;
  *) ok "no proxy variable in the image environment" ;; esac
grep -c "$PASSWORD" "$WORK/build.log" | grep -qx 0 \
  && ok "the password does not appear in the build log" || fail "the build log shows the password"
line=$(sed -n 2p "$WORK/ca.pem")
hits=$(docker run --rm --entrypoint sh "$TAG" -c "grep -cF '$line' /etc/ssl/certs/ca-certificates.crt")
[ "$hits" = 0 ] && ok "the throwaway CA is absent from the system bundle" || fail "the CA is in the bundle"

echo
[ $rc = 0 ] && echo "https-proxy-image: all checks passed" || echo "https-proxy-image: FAILED"
exit $rc
