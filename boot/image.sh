#!/bin/bash
# image.sh -- `kiln image TARGET': an ATTESTABLE bare-metal modus image with packages.
#
# Two artifacts, both measurable, from a reproducible recipe:
#   the kernel    x64-uefi: generic.efi, the DDC'd bare x86-64 UEFI CL image (net +
#                 SSH; SNP mode by --snp) -- the hash an SNP launch measures via
#                 -kernel under the AmdSev OVMF.  zero2w: kernel8.img (+ .gz), the
#                 Pi 3B / Zero 2 W chainload image the board netboots to 0x300000.
#   modus.core    a save-and-die heap snapshot taken on THAT kernel under QEMU
#                 with the requested packages installed, restored at boot from RAM
#                 (x64 0x20000000, Pi 0x18000000) without a reload.  x64 fetches the
#                 tarballs over the guest network; the Pi has no NIC under QEMU, so
#                 they are placed in RAM by the loader.
# plus manifest.json: every hash, pin and flag that went into them.
#
#   kiln image x64-uefi|zero2w [--out=DIR] [--with=NAME ...] [--snp=0|test|1]
#              [--probe=FORM --expect=TEXT] [--reuse=FILE] [--ddc] [--strict] [--stage=HOST]
set -uo pipefail
ROOT=${KILN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}   # the modus-lisp workspace
KILN=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MODUS=${MODUS_SRC:-$ROOT/modus}
KILN_STATE_DIR=${KILN_STATE:-$HOME/.local/state/kiln}; mkdir -p "$KILN_STATE_DIR"
target=${1:-}; case $target in x64-uefi|zero2w|nitro) shift ;; rpi|pi|zero) target=zero2w; shift ;; x64|uefi) target=x64-uefi; shift ;; aws|enclave) target=nitro; shift ;;
  *) echo "kiln image: the first argument is the TARGET: x64-uefi, zero2w or nitro" >&2; exit 2 ;; esac
out=$ROOT/kiln-image-$target; withs=(); snp=0; probe=""; expect=""; image=""; ddc=""; strict=""; stage=""
for a in "$@"; do
  v=${a#*=}
  case $a in
    --out=*) out=$v ;; --with=*) withs+=("$v") ;; --snp=*) snp=$v ;; --probe=*) probe=$v ;; --expect=*) expect=$v ;;
    --reuse=*) image=$v ;; --ddc) ddc=1 ;; --strict) strict=--strict ;; --stage=*) stage=$v ;;
    *) echo "kiln image: unknown argument $a" >&2; exit 2 ;;
  esac
done
[ $target != x64-uefi ] && [ "$snp" != 0 ] && { echo "kiln image: --snp is x64-uefi only" >&2; exit 2; }
[ $target != x64-uefi ] && [ -n "$ddc" ] && { echo "kiln image: --ddc is x64-uefi only (test/run-uefi-ddc.sh)" >&2; exit 2; }
[ $target = nitro ] && [ -n "$probe" ] && { echo "kiln image: --probe needs an enclave to run in; nitro builds and measures only" >&2; exit 2; }
case $target in x64-uefi) kernel=generic.efi; qemu=qemu-system-x86_64 ;; zero2w) kernel=kernel8.img; qemu=qemu-system-aarch64 ;; nitro) kernel=modus; qemu="" ;; esac
say() { echo "[kiln image] $(date +%H:%M:%S) $*"; }
for tool in sbcl $qemu python3 $([ $target = x64-uefi ] && echo mformat) $([ $target = zero2w ] && echo gdb-multiarch) $([ $target = nitro ] && echo curl); do command -v $tool >/dev/null || { echo "kiln image: needs $tool" >&2; exit 2; }; done
[ -f "$MODUS/mvm/build-uefi-cl-repl.lisp" ] || { echo "kiln image: no modus checkout at $MODUS (MODUS_SRC=...)" >&2; exit 2; }
mkdir -p "$out/tars"; out=$(cd "$out" && pwd)

say "1. packages: ${withs[*]:-none}"
python3 "$KILN/boot/image-deps.py" --out "$out/tars" --root "$ROOT" --lock "$KILN/repos.lock" \
  --archives "$MODUS/test/ladder/tars" $strict "${withs[@]}" > "$out/packages.json" || { say "FAIL: unresolved dependencies (see $out/packages.json)"; exit 1; }
order=$(python3 -c "import json;print(' '.join(json.load(open('$out/packages.json'))['order']))")
unres=$(python3 -c "import json;print(' '.join(u['name'] for u in json.load(open('$out/packages.json'))['unresolved']))")
say "   load order: $order"; [ -n "$unres" ] && say "   UNRESOLVED (not in the image): $unres"

if [ -n "$image" ]; then say "2. kernel: reusing $image"; cp "$image" "$out/$kernel"
elif [ $target = x64-uefi ]; then
  say "2. SBCL build of the generic UEFI image (snp=$snp, net+ssh, 4 MB fetch buffer)"
  ( cd "$MODUS" && MODUS_UEFI_SNP=$snp MODUS_NET_BUILD=1 MODUS_SSH_BUILD=1 MODUS_NET_BUFSZ=4194304 \
      MODUS_CL_REPL_OUT="$out/$kernel" sbcl --dynamic-space-size 12288 --script mvm/build-uefi-cl-repl.lisp ) > "$out/build.log" 2>&1 \
    || { say "FAIL: build (see $out/build.log)"; exit 1; }
elif [ $target = nitro ]; then
  # The HOSTED static ELF: the enclave runs AWS's Linux kernel, and modus is its
  # one process (init execs /cmd).  No libc, no dynamic loader, nothing else in
  # the ramdisk but modus, the tarballs and the two files init reads.
  say "2. SBCL build of the hosted x86-64 CLI (the enclave's one process)"
  ( cd "$MODUS" && MODUS_CLI_OUT="$out/$kernel" sbcl --dynamic-space-size 12288 --script mvm/build-generic-cli.lisp ) > "$out/build.log" 2>&1 \
    || { say "FAIL: build (see $out/build.log)"; exit 1; }
else
  # The runbook's verified flag set (docs/reel-on-zero/BOARD-RUNBOOK.md 1): net +
  # SSH, NO boot-time auto-install pipeline (it poisons the Zero's NIC), the
  # chainload layout netboot's `go 0x300000' expects.
  say "2. SBCL build of the Zero 2 W kernel (net+ssh, noauto, chainload, 4 MB fetch buffer)"
  ( cd "$MODUS" && MODUS_NET_BUILD=1 MODUS_SSH_BUILD=1 MODUS_NET_NOAUTO=1 MODUS_RPI_CHAINLOAD=1 MODUS_NET_BUFSZ=4194304 \
      MODUS_CL_REPL_OUT="$out/$kernel" sbcl --dynamic-space-size 8192 --script mvm/build-rpi-cl-repl.lisp ) > "$out/build.log" 2>&1 \
    || { say "FAIL: build (see $out/build.log)"; exit 1; }
fi
[ $target = zero2w ] && { gzip -kf "$out/$kernel"; say "   $kernel.gz $(stat -c %s "$out/$kernel.gz") bytes (what travels over TFTP)"; }
say "   $kernel $(stat -c %s "$out/$kernel") bytes sha256 $(sha256sum "$out/$kernel" | cut -c1-16)"

if [ -n "$ddc" ]; then
  # THE PROVEN IMAGE IS THE SHIPPED IMAGE.  The DDC compares SBCL's static-
  # configuration build with modus-sh's two in-image compiles of the same
  # source; what it proves is THAT file, so generic.efi becomes it (the plain
  # build above is replaced), and the rig below runs on it.
  say "2b. DDC: modus-sh compiles the same source twice and must match SBCL; the match is what ships"
  ( cd "$MODUS" && MODUS_UEFI_SNP=$snp MODUS_NET_BUILD=1 MODUS_SSH_BUILD=1 MODUS_NET_BUFSZ=4194304 \
      MODUS_DDC_WORK="$out/ddc" test/run-uefi-ddc.sh ) > "$out/ddc.log" 2>&1 && say "   DDC PASS" || { say "FAIL: DDC (see $out/ddc.log)"; exit 1; }
  cp "$out/ddc/sbcl.efi" "$out/$kernel"; say "   $kernel := the DDC'd image, $(stat -c %s "$out/$kernel") bytes md5 $(md5sum "$out/$kernel" | cut -c1-32)"
fi

if [ $target = nitro ]; then
  # EIF = kernel + cmdline + init ramdisk (AWS's init + nsm.ko) + application
  # ramdisk (modus, the tarballs, /cmd, /env), measured into PCR0/1/2 by
  # eif_build (aws-nitro-enclaves-image-format), built from source here -- no
  # Docker and no nitro-cli; the ramdisks are deterministic cpio (mkcpio.py),
  # so the PCRs follow from the inputs.  The boot blobs are AWS's own, pinned by
  # sha256 in the manifest.  Packages are INSIDE the measured ramdisk and are
  # installed at start by the /cmd line (no save-and-die core here yet).
  BLOBS=${NITRO_BLOBS:-$KILN_STATE_DIR/nitro-blobs}; EIFB=${EIF_BUILD:-$KILN_STATE_DIR/cargo/bin/eif_build}
  say "3. enclave image (EIF) from AWS's boot blobs + eif_build"
  mkdir -p "$BLOBS"
  for f in bzImage bzImage.config cmdline init nsm.ko; do
    [ -s "$BLOBS/$f" ] || curl -sfL -o "$BLOBS/$f" "https://raw.githubusercontent.com/aws/aws-nitro-enclaves-cli/main/blobs/x86_64/$f" || { say "FAIL: fetching blob $f"; exit 1; }
  done
  [ -x "$EIFB" ] || { say "   building eif_build from source (cargo)"; cargo install -q --git https://github.com/aws/aws-nitro-enclaves-image-format --bin eif_build --root "$(dirname "$(dirname "$EIFB")")" > "$out/cargo.log" 2>&1 || { say "FAIL: eif_build (see $out/cargo.log)"; exit 1; }; }
  python3 "$MODUS/test/nitro/mkcpio.py" "$out/init.cpio" --file "$BLOBS/init:init" --file "$BLOBS/nsm.ko:nsm.ko:100644" > /dev/null
  # init reads /cmd as one argv entry PER LINE, so each --eval form is one line
  # whatever spaces it contains (splitting on spaces cut install-tarball's form
  # in two -> READER-ERROR on the first enclave boot that reached modus).
  argv=(/modus); tarargs=()
  for n in $order; do tarargs+=(--file "$out/tars/$n.tar:rootfs/tars/$n.tar:100644"); argv+=(--eval "(install-tarball \"/tars/$n.tar\")"); done
  argv+=(--eval "(handler-case (nsm-attest-selftest) (error (c) (format t \"NSM selftest: ~A~%\" c)))" --eval "(vsock-repl 5000)")
  printf '%s\n' "${argv[@]}" > "$out/cmd.txt"
  # AWS's init bind-mounts /rootfs, chroots into it and execs /cmd's argv there:
  # cmd and env live at the ramdisk root, EVERYTHING the program sees under
  # rootfs/ (plus the mount points init fills: dev, proc, sys, tmp, run -- its ops table).
  python3 "$MODUS/test/nitro/mkcpio.py" "$out/app.cpio" --file "$out/$kernel:rootfs/modus" "${tarargs[@]}" --file "$out/cmd.txt:cmd:100644" --text 'env:MODUS_NITRO=1' \
      --text 'rootfs/dev/.keep:' --text 'rootfs/proc/.keep:' --text 'rootfs/sys/.keep:' --text 'rootfs/tmp/.keep:' --text 'rootfs/run/.keep:' > /dev/null
  "$EIFB" --kernel "$BLOBS/bzImage" --kernel_config "$BLOBS/bzImage.config" --cmdline "$(cat "$BLOBS/cmdline")" \
      --ramdisk "$out/init.cpio" --ramdisk "$out/app.cpio" --output "$out/modus.eif" --name modus --version 0 \
      --build-time 2000-01-01T00:00:00Z --build-tool kiln --build-tool-version 0 --arch x86_64 > "$out/eif.log" 2>&1 \
    || { say "FAIL: eif_build (see $out/eif.log)"; exit 1; }
  python3 - "$out/eif.log" "$out/pcrs.json" <<'PY'
import sys, json, re
txt = open(sys.argv[1]).read(); pcrs = dict(re.findall(r'"(PCR\d)":\s*"([0-9a-f]+)"', txt))
json.dump(pcrs, open(sys.argv[2], "w"), indent=1); print("   " + " ".join(f"{k}={v[:16]}.." for k, v in pcrs.items()))
PY
  say "   $out/modus.eif $(stat -c %s "$out/modus.eif") bytes"
else
say "3. install under QEMU, save-and-die, dump the core, restore it"
loads=(); for n in $order; do loads+=("--load=$n"); done
rig=test/run-uefi-core.sh; [ $target = zero2w ] && rig=test/run-rpi-core.sh
( cd "$MODUS" && TARS="$out/tars" $rig "$out/$kernel" "$out/modus.core" "${loads[@]}" \
    ${probe:+"--probe=$probe"} ${expect:+"--expect=$expect"} ) > "$out/core.log" 2>&1; rc=$?
grep -a "^   core:\|^   probe reply\|^PASS\|^FAIL" "$out/core.log" | sed 's/^/   /'
[ $rc = 0 ] || { say "FAIL: core (see $out/core.log)"; exit 1; }
fi

say "4. manifest"
NITRO_BLOBS_DIR="${BLOBS:-}" python3 - "$out" "$snp" "$KILN" "$MODUS" "$probe" "$expect" "$ddc" "$target" "$kernel" <<'PY'
import json, sys, hashlib, subprocess, os, datetime
out, snp, kiln, modus, probe, expect, ddc, target, kernel = sys.argv[1:10]
def sha(p):
    h = hashlib.sha256(); h.update(open(p, "rb").read()); return h.hexdigest()
def rev(d): return subprocess.run(["git", "-C", d, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
if target == "x64-uefi":
    build = dict(MODUS_UEFI_SNP=snp, MODUS_NET_BUILD="1", MODUS_SSH_BUILD="1", MODUS_NET_BUFSZ="4194304", script="mvm/build-uefi-cl-repl.lisp")
    core_addr = "0x20000000"
    att = dict(measured_by="AmdSev OVMF -kernel generic.efi (kernel-hashes=on); the core is NOT inside the measured image: it is placed in RAM by the loader and its sha256 is pinned here",
               verify="test/snp/verify-report.py REPORT --measurement <launch digest of generic.efi> --hostkey-b64 <handshake key> --vcek VCEK.pem")
elif target == "nitro":
    build = dict(script="mvm/build-generic-cli.lisp", eif_build="aws-nitro-enclaves-image-format", ramdisks="test/nitro/mkcpio.py (deterministic newc)")
    core_addr = None
    blobs = {}
    bd = os.environ.get("NITRO_BLOBS_DIR")
    for f in ("bzImage", "bzImage.config", "cmdline", "init", "nsm.ko"):
        pth = os.path.join(bd, f) if bd else None
        if pth and os.path.exists(pth): blobs[f] = dict(bytes=os.path.getsize(pth), sha256=sha(pth))
    att = dict(measured_by="Nitro: PCR0 = the whole EIF, PCR1 = kernel + init ramdisk, PCR2 = the application ramdisk (modus + tarballs + /cmd + /env); from eif_build, see pcrs.json",
               verify="test/nitro/verify-attestation.py DOC.cose --pcr0 .. --pcr1 .. --pcr2 .. --nonce .. [--hostkey-b64 ..] (root: test/nitro/aws-nitro-root.pem)",
               enclave_memory="the hosted ELF maps two 896 MB semispaces plus 16 MB; give the enclave at least 2560 MB",
               network="vsock only: the /cmd line ends in (vsock-repl 5000); the parent forwards with vsock-proxy or socat",
               boot_blobs=blobs, pcrs=json.load(open(out+"/pcrs.json")))
else:
    build = dict(MODUS_NET_BUILD="1", MODUS_SSH_BUILD="1", MODUS_NET_NOAUTO="1", MODUS_RPI_CHAINLOAD="1", MODUS_NET_BUFSZ="4194304", script="mvm/build-rpi-cl-repl.lisp")
    core_addr = "0x18000000"
    att = dict(measured_by="no hardware root of trust on the Zero 2 W: a verifier pins these two hashes; U-Boot `tftpboot 0x18000000 modus.core; tftpboot 0x08000000 kernel8.img.gz; unzip 0x08000000 0x300000; go 0x300000' (scripts/netboot-core.py)",
               deploy="scp kernel8.img.gz + modus.core to modus-pi:/home/modus and sudo cp into /srv/tftp (docs/reel-on-zero/BOARD-RUNBOOK.md 2, 4)")
kfile = out + "/" + kernel
kern = dict(file=kernel, bytes=os.path.getsize(kfile), sha256=sha(kfile), md5=hashlib.md5(open(kfile,"rb").read()).hexdigest(), ddc="PASS" if ddc else "not run")
if os.path.exists(kfile + ".gz"): kern["gz"] = dict(file=kernel + ".gz", bytes=os.path.getsize(kfile + ".gz"), sha256=sha(kfile + ".gz"))
m = dict(
  target=target,
  produced=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
  kiln_commit=rev(kiln), modus_commit=rev(modus),
  build=build, kernel=kern,
  core=(dict(file="modus.core", bytes=os.path.getsize(out+"/modus.core"), sha256=sha(out+"/modus.core"), ram_address=core_addr,
             probe=probe, expect=expect, reproducible=False) if os.path.exists(out+"/modus.core") else None),
  eif=(dict(file="modus.eif", bytes=os.path.getsize(out+"/modus.eif"), sha256=sha(out+"/modus.eif")) if os.path.exists(out+"/modus.eif") else None),
  packages=json.load(open(out+"/packages.json")),
  attestation=att)
json.dump(m, open(out+"/manifest.json", "w"), indent=1)
print("   " + out + "/manifest.json")
PY
if [ -n "$stage" ]; then
  say "5. staging on $stage (runbook 2: /srv/tftp is root-owned, so sudo -n and ls the result)"
  files="$out/modus.core"; [ $target = zero2w ] && files="$files $out/$kernel.gz" || files="$files $out/$kernel"
  scp -q $files "$stage:/home/modus/" && ssh "$stage" 'for f in '"$(for f in $files; do basename $f; done | tr '\n' ' ')"'; do sudo -n cp /home/modus/$f /srv/tftp/ && sudo -n chown modus:modus /srv/tftp/$f; done; ls -la /srv/tftp/modus.core' \
    && say "   staged; netboot with: python3 netboot-core.py --img $kernel.gz --core modus.core" || { say "FAIL: staging"; exit 1; }
fi
[ $target = nitro ] && say "done: $out/modus.eif (manifest.json, pcrs.json)" || say "done: $out/$kernel + $out/modus.core (manifest.json)"
