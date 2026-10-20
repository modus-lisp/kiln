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

kiln_ca() {
  if [ -s /run/secrets/extra_ca ]; then
    cat /etc/ssl/certs/ca-certificates.crt /run/secrets/extra_ca > /tmp/kiln-ca.pem
    echo /tmp/kiln-ca.pem
  else
    echo /etc/ssl/certs/ca-certificates.crt
  fi
}
