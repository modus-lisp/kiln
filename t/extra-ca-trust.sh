#!/usr/bin/env bash
# extra-ca-trust.sh — the trust decisions a build makes, without a network.
#
# Two places decide what an --extra-ca build trusts:
#   boot/ca.sh        which CA bundle a fetching RUN uses (kiln_ca)
#   boot/clone-org.lisp  what the clones trust, and what it reports (INSTALL-TRUST)
# Both are checked here.  clone-org runs against an EMPTY lock, so it makes every
# decision it makes before its first clone and then has nothing to fetch.  Needs a
# Linux CA bundle at /etc/ssl/certs/ca-certificates.crt, sbcl, and openssl.
#
#   t/extra-ca-trust.sh
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kiln-extra-ca-trust.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
rc=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; rc=1; }
skip() { printf '  skip %s\n' "$1"; exit 0; }

command -v sbcl >/dev/null || skip "no sbcl on PATH"
command -v openssl >/dev/null || skip "no openssl on PATH"
[ -s /etc/ssl/certs/ca-certificates.crt ] || skip "no CA bundle at /etc/ssl/certs/ca-certificates.crt"

# Two throwaway CAs, as PEM.
for n in 1 2; do
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/k$n" -out "$WORK/ca$n.pem" \
    -days 2 -subj "/CN=kiln trust test $n" 2>/dev/null
done

group() { printf '\n\033[1m%s\033[0m\n' "$1"; }

group "ca.sh: which bundle a fetching RUN trusts"
. "$ROOT/boot/ca.sh"
export KILN_EXTRA_CA_SECRET="$WORK/absent"
[ "$(kiln_ca)" = /etc/ssl/certs/ca-certificates.crt ] \
  && ok "no secret: the public bundle, untouched" || fail "no secret did not give the public bundle"
: > "$WORK/empty"
export KILN_EXTRA_CA_SECRET="$WORK/empty"
[ "$(kiln_ca)" = /etc/ssl/certs/ca-certificates.crt ] \
  && ok "an empty secret counts as no secret" || fail "an empty secret was used"
cp "$WORK/ca1.pem" "$WORK/secret"
export KILN_EXTRA_CA_SECRET="$WORK/secret"
bundle=$(kiln_ca)
want=$(( $(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt) + 1 ))
got=$(grep -c 'BEGIN CERTIFICATE' "$bundle")
[ "$bundle" != /etc/ssl/certs/ca-certificates.crt ] && [ "$got" = "$want" ] \
  && ok "a secret: the public roots plus the CA ($got certificates)" \
  || fail "a secret gave $got certificates, expected $want from $bundle"
rm -f /tmp/kiln-ca.pem

group "clone-org.lisp: what the clones trust, and what it reports"
# A seed of the five repos cairn needs, from the working copies beside this one.
mkdir -p "$WORK/seed"
for r in cairn seal conch cram natrium; do
  [ -d "$ROOT/../$r" ] || skip "no working copy of $r beside kiln"
  cp -r "$ROOT/../$r" "$WORK/seed/$r"
done
: > "$WORK/empty.lock"
clone() {  # clone [env assignments...] -> sets OUT and STATUS
  OUT=$(env -u KILN_EXTRA_CA "$@" KILN_SEED="$WORK/seed" KILN_LOCK="$WORK/empty.lock" \
        MODUS_ROOT="$WORK/root" sbcl --script "$ROOT/boot/clone-org.lisp" 2>&1)
  STATUS=$?
}

clone
[ $STATUS = 0 ] && case $OUT in *"trust: system roots only"*) ok "no CA: reports system roots only";; *) fail "no CA: $OUT";; esac || fail "no CA: exit $STATUS"

clone KILN_EXTRA_CA="$WORK/absent.pem"
[ $STATUS != 0 ] && case $OUT in *"does not exist"*) ok "a missing KILN_EXTRA_CA is refused";; *) fail "missing file: $OUT";; esac || fail "missing file was accepted"

printf 'not a certificate\n' > "$WORK/notca.txt"
clone KILN_EXTRA_CA="$WORK/notca.txt"
[ $STATUS != 0 ] && case $OUT in *"holds no certificates"*) ok "a file with no certificate is refused";; *) fail "non-PEM: $OUT";; esac || fail "non-PEM file was accepted"

clone KILN_EXTRA_CA="$WORK/ca1.pem"
fp1=$(openssl x509 -in "$WORK/ca1.pem" -outform DER | sha256sum | cut -d' ' -f1)
if [ $STATUS = 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^@@ trust extra-ca ')" = 1 ] \
   && printf '%s\n' "$OUT" | grep -q "^@@ trust extra-ca $fp1\$"; then
  ok "one CA: logged once, by the SHA-256 of its DER"
else fail "one CA: expected @@ trust extra-ca $fp1; got: $OUT"; fi

cat "$WORK/ca1.pem" "$WORK/ca2.pem" > "$WORK/two.pem"
clone KILN_EXTRA_CA="$WORK/two.pem"
n=$(printf '%s\n' "$OUT" | grep -c '^@@ trust extra-ca ')
fp2=$(openssl x509 -in "$WORK/ca2.pem" -outform DER | sha256sum | cut -d' ' -f1)
if [ $STATUS = 0 ] && [ "$n" = 2 ] && printf '%s\n' "$OUT" | grep -q "^@@ trust extra-ca $fp2\$"; then
  ok "two CAs: each logged, the second included"
else fail "two CAs: logged $n lines"; fi

clone KILN_EXTRA_CA="$WORK/ca1.pem"
[ $STATUS = 0 ] && case $OUT in *"0 repos checked out"*) ok "an empty lock clones nothing and exits 0";; *) fail "empty lock: $OUT";; esac || fail "empty lock: exit $STATUS"

echo
[ $rc = 0 ] && echo "extra-ca-trust: all checks passed" || echo "extra-ca-trust: FAILED"
exit $rc
