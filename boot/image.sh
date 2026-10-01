#!/bin/bash
# image.sh -- `kiln image': an ATTESTABLE bare-metal modus image with packages.
#
# Two artifacts, both measurable, from a reproducible recipe:
#   generic.efi   the DDC'd bare x86-64 UEFI CL image (net + SSH; SNP mode by --snp),
#                 built by SBCL from the modus checkout -- its hash is the one
#                 an SNP launch measures via -kernel under the AmdSev OVMF;
#   modus.core    a save-and-die heap snapshot taken on THAT image under QEMU
#                 after ql:quickload of the requested packages (served from
#                 tarballs this script derives from pinned commits / Quicklisp
#                 releases), restored at boot from RAM (0x20000000) without reload.
# plus manifest.json: every hash, pin and flag that went into them.
#
#   kiln image [--out=DIR] [--with=NAME ...] [--snp=0|test|1] [--probe=FORM --expect=TEXT]
#              [--image=FILE] [--ddc] [--strict]
set -uo pipefail
ROOT=${KILN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}   # the modus-lisp workspace
KILN=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MODUS=${MODUS_SRC:-$ROOT/modus}
out=$ROOT/kiln-image; withs=(); snp=0; probe=""; expect=""; image=""; ddc=""; strict=""
for a in "$@"; do
  v=${a#*=}
  case $a in
    --out=*) out=$v ;; --with=*) withs+=("$v") ;; --snp=*) snp=$v ;; --probe=*) probe=$v ;; --expect=*) expect=$v ;;
    --image=*) image=$v ;; --ddc) ddc=1 ;; --strict) strict=--strict ;;
    *) echo "kiln image: unknown argument $a" >&2; exit 2 ;;
  esac
done
say() { echo "[kiln image] $(date +%H:%M:%S) $*"; }
for tool in sbcl qemu-system-x86_64 mformat python3; do command -v $tool >/dev/null || { echo "kiln image: needs $tool" >&2; exit 2; }; done
[ -f "$MODUS/mvm/build-uefi-cl-repl.lisp" ] || { echo "kiln image: no modus checkout at $MODUS (MODUS_SRC=...)" >&2; exit 2; }
mkdir -p "$out/tars"; out=$(cd "$out" && pwd)

say "1. packages: ${withs[*]:-none}"
python3 "$KILN/boot/image-deps.py" --out "$out/tars" --root "$ROOT" --lock "$KILN/repos.lock" \
  --archives "$MODUS/test/ladder/tars" $strict "${withs[@]}" > "$out/packages.json" || { say "FAIL: unresolved dependencies (see $out/packages.json)"; exit 1; }
order=$(python3 -c "import json;print(' '.join(json.load(open('$out/packages.json'))['order']))")
unres=$(python3 -c "import json;print(' '.join(u['name'] for u in json.load(open('$out/packages.json'))['unresolved']))")
say "   load order: $order"; [ -n "$unres" ] && say "   UNRESOLVED (not in the image): $unres"

if [ -n "$image" ]; then say "2. image: reusing $image"; cp "$image" "$out/generic.efi"
else
  say "2. SBCL build of the generic image (snp=$snp, net+ssh, 4 MB fetch buffer)"
  ( cd "$MODUS" && MODUS_UEFI_SNP=$snp MODUS_NET_BUILD=1 MODUS_SSH_BUILD=1 MODUS_NET_BUFSZ=4194304 \
      MODUS_CL_REPL_OUT="$out/generic.efi" sbcl --dynamic-space-size 12288 --script mvm/build-uefi-cl-repl.lisp ) > "$out/build.log" 2>&1 \
    || { say "FAIL: build (see $out/build.log)"; exit 1; }
fi
say "   $(stat -c %s "$out/generic.efi") bytes sha256 $(sha256sum "$out/generic.efi" | cut -c1-16)"

if [ -n "$ddc" ]; then
  say "2b. DDC: modus-sh compiles the same source twice and must match SBCL"
  ( cd "$MODUS" && MODUS_UEFI_SNP=$snp MODUS_NET_BUILD=1 MODUS_SSH_BUILD=1 MODUS_NET_BUFSZ=4194304 \
      MODUS_DDC_WORK="$out/ddc" test/run-uefi-ddc.sh ) > "$out/ddc.log" 2>&1 && say "   DDC PASS" || { say "FAIL: DDC (see $out/ddc.log)"; exit 1; }
fi

say "3. quickload under QEMU, save-and-die, dump the core, restore it"
loads=(); for n in $order; do loads+=("--load=$n"); done
( cd "$MODUS" && TARS="$out/tars" test/run-uefi-core.sh "$out/generic.efi" "$out/modus.core" "${loads[@]}" \
    ${probe:+--probe=$probe} ${expect:+--expect=$expect} ) > "$out/core.log" 2>&1; rc=$?
grep -a "^   core:\|^   probe reply\|^PASS\|^FAIL" "$out/core.log" | sed 's/^/   /'
[ $rc = 0 ] || { say "FAIL: core (see $out/core.log)"; exit 1; }

say "4. manifest"
python3 - "$out" "$snp" "$KILN" "$MODUS" "$probe" "$expect" "$ddc" <<'PY'
import json, sys, hashlib, subprocess, os, datetime
out, snp, kiln, modus, probe, expect, ddc = sys.argv[1:8]
def sha(p):
    h = hashlib.sha256(); h.update(open(p, "rb").read()); return h.hexdigest()
def rev(d): return subprocess.run(["git", "-C", d, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
m = dict(
  produced=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
  kiln_commit=rev(kiln), modus_commit=rev(modus),
  build=dict(MODUS_UEFI_SNP=snp, MODUS_NET_BUILD="1", MODUS_SSH_BUILD="1", MODUS_NET_BUFSZ="4194304", script="mvm/build-uefi-cl-repl.lisp"),
  generic_efi=dict(file="generic.efi", bytes=os.path.getsize(out+"/generic.efi"), sha256=sha(out+"/generic.efi"),
                   md5=hashlib.md5(open(out+"/generic.efi","rb").read()).hexdigest(), ddc="PASS" if ddc else "not run"),
  core=dict(file="modus.core", bytes=os.path.getsize(out+"/modus.core"), sha256=sha(out+"/modus.core"), ram_address="0x20000000",
            probe=probe, expect=expect),
  packages=json.load(open(out+"/packages.json")),
  attestation=dict(measured_by="AmdSev OVMF -kernel generic.efi (kernel-hashes=on); the core is NOT yet inside the measured image: it is placed in RAM by the loader and its sha256 is pinned here",
                   verify="test/snp/verify-report.py REPORT --measurement <launch digest of generic.efi> --hostkey-b64 <handshake key> --vcek VCEK.pem"))
json.dump(m, open(out+"/manifest.json", "w"), indent=1)
print("   " + out + "/manifest.json")
PY
say "done: $out/generic.efi + $out/modus.core (manifest.json)"
