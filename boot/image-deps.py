#!/usr/bin/env python3
"""image-deps.py -- the package closure for a modus image, as tarballs.

  image-deps.py --out DIR [--root WORKSPACE] [--lock repos.lock] [--archives DIR ...]
                [--strict] NAME ...

For every NAME and, transitively, every system in its .asd's :depends-on:
  * a modus-lisp repo (a sibling checkout under --root that has NAME.asd) is
    archived with `git archive` at the commit repos.lock pins (HEAD if unlocked),
    so the bytes follow from the commit;
  * otherwise a Quicklisp release is looked up by system name in the --archives
    directories (~/quicklisp/dists/*/archives *.tgz, or a directory of *.tar such
    as modus/test/ladder/tars) and gunzipped to a plain .tar;
  * anything else is UNRESOLVED and listed (fatal with --strict).

Writes DIR/<name>.tar for each resolved system, named by the system name a
:depends-on uses (the bare image's ql:quickload fetches <name>.tar by that
name), and prints a JSON manifest: load order (dependencies first), per system
its source, commit, tar sha256 and size, and the unresolved names.

Dependency parsing is a tolerant regex over the .asd, not a Lisp reader: it reads
every :depends-on (...) list, strips #+/#- conditionals' bare feature tokens, and
accepts (:version "x" "1.0") and (:feature ...) forms by taking the system name.
Systems the bare image provides itself (see BUILTIN) are dropped from the order.
"""
import argparse, gzip, hashlib, io, json, os, re, subprocess, sys, tarfile, glob

# Systems that ship INSIDE the bare image (SBCL contribs the compat layer
# provides, or names the image's own runtime answers to); they are never fetched.
BUILTIN = {"sb-bsd-sockets", "sb-posix", "sb-rotate-byte", "sb-concurrency", "sb-introspect",
           "asdf", "uiop"}

def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()

def depends_on(asd_text, system):
    """Names in the :depends-on lists of the defsystem for SYSTEM (or all, if the
    file has one defsystem)."""
    text = re.sub(r";[^\n]*", "", asd_text)
    # isolate the defsystem for this name when there are several
    # (defsystem ...) or (asdf:defsystem ...): cl-marmot spells it the second way
    blocks = re.split(r"\((?:asdf:)?defsystem\s+", text, flags=re.I)[1:]
    chosen = [b for b in blocks if re.match(r'"?([^\s")]+)"?', b) and
              re.match(r'"?([^\s")]+)"?', b).group(1).lower().lstrip("#:") == system.lower()]
    if not chosen: chosen = blocks
    deps = []
    for b in chosen:
        b = re.split(r":components\b", b, flags=re.I)[0]   # not the per-file :depends-on inside :components
        for m in re.finditer(r":depends-on\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)", b, flags=re.I):
            body = m.group(1)
            body = re.sub(r"#[+-]\s*\(?[^\s()]*\)?", " ", body)   # feature conditionals
            for sub in re.finditer(r"\(([^()]*)\)", body):          # (:version "x" "1") / (:feature ...)
                toks = re.findall(r'"([^"]+)"|([A-Za-z0-9*+.:/_-]+)', sub.group(1))
                names = [a or b for a, b in toks if (a or b).lower() not in (":version", ":feature", ":require")]
                if names: deps.append(names[0] if sub.group(1).lower().startswith(":version") else names[-1])
            body = re.sub(r"\([^()]*\)", " ", body)
            for a, b in re.findall(r'"([^"]+)"|([A-Za-z0-9*+.:/_-]+)', body):
                n = (a or b).lstrip("#:")
                if n and not n.startswith(":"): deps.append(n)
    out = []
    for d in deps:
        d = d.lower()
        if d not in out: out.append(d)
    return out

def read_lock(path):
    pins = {}
    if path and os.path.exists(path):
        for line in open(path):
            line = line.split("#")[0].split()
            if len(line) >= 3: pins[line[0]] = line[2]
    return pins

def find_repo(root, name):
    d = os.path.join(root, name)
    if os.path.isfile(os.path.join(d, name + ".asd")): return d
    # a system named like a repo's secondary system: search sibling .asd files
    for asd in glob.glob(os.path.join(root, "*", name + ".asd")):
        return os.path.dirname(asd)
    return None

def find_archive(dirs, name):
    cands = []
    stems = [name] + ([name.split(".")[-1]] if "." in name else [])   # com.inuoe.jzon ships as jzon-vX.tgz
    for d in dirs:
      for name in stems:
        cands += glob.glob(os.path.join(d, name + ".tar"))
        cands += glob.glob(os.path.join(d, name + "-*.tgz")) + glob.glob(os.path.join(d, name + "-*.tar.gz"))
    # exact-name .tar first, then the newest looking tgz
    cands.sort(key=lambda p: (not p.endswith(".tar"), p))
    return cands[0] if cands else None

def asd_from_tar(path, name):
    with tarfile.open(path) as tf:
        for m in tf.getmembers():
            if m.name.endswith("/" + name + ".asd") or m.name == name + ".asd":
                return tf.extractfile(m).read().decode("utf-8", "replace")
    return ""

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True); ap.add_argument("--root", default=os.environ.get("KILN_ROOT", os.path.expanduser("~/modus-lisp")))
    ap.add_argument("--lock", default=None); ap.add_argument("--archives", action="append", default=[])
    ap.add_argument("--strict", action="store_true"); ap.add_argument("names", nargs="+")
    a = ap.parse_args()
    archives = a.archives + glob.glob(os.path.expanduser("~/quicklisp/dists/*/archives"))
    pins = read_lock(a.lock); os.makedirs(a.out, exist_ok=True)
    order, info, unresolved, seen, asds = [], {}, [], set(), {}
    def visit(name, via):
        # A SUB-SYSTEM (seal/http) lives in its base's repo and .asd: resolve the
        # base, then the sub-system's own :depends-on, and list it after them with
        # a copy of the base tarball at <base>/<sub>.tar -- the bare image installs
        # one SYSTEM per tarball, so cl-nostr's "seal/http" went missing when it
        # was folded into "seal" (seal.http:get-string, a reader error).
        full = name.lower(); base = full.split("/")[0]
        visit_base(base, via)
        if full == base or full in seen or base not in asds: return
        seen.add(full)
        for d in depends_on(asds[base], full):
            if d.lower() != base: visit(d, full)
        tar = os.path.join(a.out, full + ".tar")
        os.makedirs(os.path.dirname(tar), exist_ok=True)
        with open(os.path.join(a.out, base + ".tar"), "rb") as s, open(tar, "wb") as d: d.write(s.read())
        info[full] = dict(source=info[base]["source"], commit=info[base]["commit"], subsystem_of=base,
                          tar=full + ".tar", sha256=sha256(tar), bytes=os.path.getsize(tar))
        order.append(full)
    def visit_base(name, via):
        if name in seen or name in BUILTIN: return
        seen.add(name)
        repo = find_repo(a.root, name)
        if repo:
            head = subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"]).decode().strip()
            pin = pins.get(os.path.basename(repo)); note = None
            commit = pin or head
            if pin and subprocess.run(["git", "-C", repo, "cat-file", "-e", pin + "^{commit}"], capture_output=True).returncode != 0:
                # the lock names a commit this checkout has not fetched: say so and
                # archive what IS here, so the manifest never claims the pin.
                note = "lock pins %s, not present locally; archived HEAD" % pin; commit = head
            tar = os.path.join(a.out, name + ".tar")
            with open(tar, "wb") as f:
                subprocess.check_call(["git", "-C", repo, "archive", "--format=tar", "--prefix=%s/" % name, commit], stdout=f)
            asd = open(os.path.join(repo, name + ".asd")).read()
            info[name] = dict(source="modus-lisp/" + os.path.basename(repo), commit=commit, note=note)
        else:
            arc = find_archive(archives, name)
            if not arc:
                unresolved.append(dict(name=name, needed_by=via)); return
            tar = os.path.join(a.out, name + ".tar")
            if arc.endswith(".tar"):
                with open(arc, "rb") as s, open(tar, "wb") as d: d.write(s.read())
            else:
                with gzip.open(arc, "rb") as s, open(tar, "wb") as d: d.write(s.read())
            asd = asd_from_tar(tar, name)
            info[name] = dict(source=os.path.basename(arc), commit=None)
        asds[name] = asd
        deps = depends_on(asd, name)
        info[name].update(depends_on=deps)
        for d in deps: visit(d, name)
        info[name].update(tar=os.path.basename(tar), sha256=sha256(tar), bytes=os.path.getsize(tar))
        order.append(name)
    for n in a.names: visit(n, None)
    man = dict(order=order, systems=info, unresolved=unresolved)
    print(json.dumps(man, indent=1))
    if unresolved and a.strict: sys.exit(1)

if __name__ == "__main__": main()
