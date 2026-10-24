# ca.sh — the CA bundle a network fetch in this build should trust.
#
# `bin/kiln container --extra-ca=PATH' passes PATH to the build as the secret
# `extra_ca'.  When that secret is mounted, a fetch trusts the public roots PLUS
# its certificates; when it is not, a fetch trusts the public roots alone, which
# is what every build did before the flag existed.  The secret exists only for
# the RUN that mounts it, so it never reaches a layer, and nothing here writes
# into the system bundle.
#
# A RUN that fetches declares the mount and sources this file:
#
#     RUN --mount=type=secret,id=extra_ca,required=false \
#         . /kiln/boot/ca.sh \
#      && export CURL_CA_BUNDLE="$(kiln_ca)" \
#      && curl ... \
#      && rm -f /tmp/kiln-ca.pem
#
# CURL_CA_BUNDLE rather than --cacert, so every curl in the RUN trusts the same
# bundle -- including the one Quicklisp shells out to for its own downloads.

# KILN_EXTRA_CA_SECRET moves the secret's path, for t/extra-ca-trust.sh; in a build it is
# always the mount point.
#
# The public roots are wherever this system keeps them: Debian's path in the
# image, /etc/ssl/cert.pem when seed.sh runs on a Mac for `kiln build'.
kiln_system_ca() {
  for f in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem /etc/pki/tls/certs/ca-bundle.crt; do
    [ -s "$f" ] && { echo "$f"; return; }
  done
  echo "kiln: no system CA bundle found" >&2
  return 1
}

kiln_ca() {
  secret=${KILN_EXTRA_CA_SECRET:-/run/secrets/extra_ca}
  system=$(kiln_system_ca) || return 1
  if [ -s "$secret" ]; then
    cat "$system" "$secret" > /tmp/kiln-ca.pem
    echo /tmp/kiln-ca.pem
  else
    echo "$system"
  fi
}
