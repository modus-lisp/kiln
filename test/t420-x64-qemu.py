#!/usr/bin/env python3
"""t420-x64-qemu.py DISK [--log-lba=SECTOR] [--keep] -- boot a `kiln t420 --x64` disk under QEMU
and OVMF and check that the desk is up and usable, with nobody watching.

What a T420 would do, as far as an emulator can: the desk disk boots through OVMF (the image,
then \\CORE.BIN restored), an e1000 gives it a network, and a second, scratch USB disk on an ICH9
EHCI at 00:1a.0 -- the T420's boot-disk controller -- is the disk the desk takes with its own
driver (vessel src/t420-usb-disk.lisp): its log and its command channel (src/t420.lisp) are the
harness's only way in besides the PS/2 keyboard and mouse (QMP input) and the screen (QMP
screendump).  The checks:

  control  the channel's answer to (+ 40 2) is compared against 43 and must be REJECTED: the
           harness reads a real answer back, not just the fact that one came
  idle     the desk logs that it reached its first idle
  channel  (+ 40 2) through the command channel answers 42
  screen   the desk owns the screen: the channel reports the GOP size it took
  clock    the Clock window's pixels change over three seconds
  menu     a right click on the desktop changes the screen (the Workspace menu)
  terminal Terminal opened from that menu, (setq *smoke* (* 6 7)) typed and entered, and the
           channel then reads *SMOKE* as 42: keyboard, Terminal and evaluation together

Exit 0 when every check passes.  The desk's log region must be where the disk's core says
(kiln t420's --log-lba; this script's default is kiln's, 262144).  Needs qemu-system-x86_64 and
OVMF (OVMF_CODE / OVMF_VARS override the Debian paths).  QEMU_MEM (MB, default 1024) and
QEMU_CPU (default SandyBridge, the T420's) vary the machine; SMOKE_IDLE_S (default 600) bounds
the wait for the desk.  Scratch files go beside DISK.
"""
import json, os, shutil, socket, struct, subprocess, sys, tempfile, time

DISK = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else sys.exit(__doc__)
LOG_LBA = 262144
KEEP = False
for a in sys.argv[2:]:
    if a.startswith('--log-lba='):
        LOG_LBA = int(a.split('=', 1)[1])
    elif a == '--keep':
        KEEP = True
CMD_LBA = LOG_LBA + 2560
OVMF_CODE = os.environ.get('OVMF_CODE', '/usr/share/OVMF/OVMF_CODE.fd')
OVMF_VARS = os.environ.get('OVMF_VARS', '/usr/share/OVMF/OVMF_VARS.fd')

work = tempfile.mkdtemp(prefix='t420-x64-qemu-', dir=os.path.dirname(os.path.abspath(DISK)))
usb = os.path.join(work, 'usb.img')
with open(usb, 'wb') as f:                      # sparse, a partition table's signature, room for the log
    f.truncate((CMD_LBA + 64) * 512)
    f.seek(510); f.write(b'\x55\xaa')
shutil.copy(OVMF_VARS, os.path.join(work, 'vars.fd'))
sock = os.path.join(work, 'qmp.sock')
qemu = subprocess.Popen(
    ['qemu-system-x86_64', '-m', os.environ.get('QEMU_MEM', '1024'), '-cpu', os.environ.get('QEMU_CPU', 'SandyBridge'),
     '-drive', 'if=pflash,format=raw,readonly=on,file=' + OVMF_CODE,
     '-drive', 'if=pflash,format=raw,file=' + os.path.join(work, 'vars.fd'),
     '-drive', 'file=%s,format=raw,snapshot=on' % os.path.abspath(DISK),
     '-display', 'none', '-vga', 'std', '-serial', 'file:' + os.path.join(work, 'serial.log'),
     '-no-reboot', '-device', 'e1000,netdev=n0', '-netdev', 'user,id=n0',
     '-device', 'ich9-usb-ehci1,id=ehci,addr=1a.0',
     '-drive', 'if=none,id=ud,file=%s,format=raw' % usb,
     '-device', 'usb-storage,bus=ehci.0,drive=ud',
     '-qmp', 'unix:%s,server,nowait' % sock],
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

class Stop(Exception):
    pass

results = []
def check(name, ok, detail=''):
    results.append(ok)
    print('%-8s %s  %s' % (name, 'PASS' if ok else 'FAIL', detail), flush=True)

# ---- the disk: the desk's log and command channel ----
def log_text():
    with open(usb, 'rb') as f:
        f.seek(LOG_LBA * 512); h = f.read(16)
        if h[:5] != b'T4LOG':
            return ''
        n = struct.unpack('<I', h[8:12])[0]
        f.seek((LOG_LBA + 1) * 512)
        return f.read(n).decode('latin-1')
seq = [100]
def channel(form, timeout=60):
    """FORM evaluated by the desk; its logged answer (the text after =>), or None."""
    seq[0] += 1; n = seq[0]; text = form.encode()
    with open(usb, 'r+b') as f:
        f.seek(CMD_LBA * 512)
        f.write(b'T4CMD\0\0\0' + struct.pack('<II', n, len(text)) + text)
    end = time.time() + timeout
    while time.time() < end:
        for line in log_text().splitlines():
            if line.startswith('cmd %d => ' % n):
                return line.split(' => ', 1)[1].strip()
            if line.startswith('cmd %d error' % n):
                return 'ERROR ' + line
        time.sleep(1)
    return None

# ---- QMP: input and screen ----
qmp_f = None
def qmp(cmd, args=None):
    global qmp_f
    if qmp_f is None:
        for _ in range(100):
            try:
                s = socket.socket(socket.AF_UNIX); s.connect(sock); break
            except OSError:
                time.sleep(0.2)
        qmp_f = s.makefile('rw'); qmp_f.readline()
        qmp('qmp_capabilities')
    qmp_f.write(json.dumps({'execute': cmd, 'arguments': args or {}}) + '\n'); qmp_f.flush()
    while True:
        r = json.loads(qmp_f.readline())
        if 'return' in r or 'error' in r:
            return r
def rel(dx, dy):
    while dx or dy:
        sx = max(-40, min(40, dx)); sy = max(-40, min(40, dy))
        qmp('input-send-event', {'events': [{'type': 'rel', 'data': {'axis': 'x', 'value': sx}},
                                            {'type': 'rel', 'data': {'axis': 'y', 'value': sy}}]})
        dx -= sx; dy -= sy; time.sleep(0.03)
def click(x, y, button='left'):
    # from the corner every time: PS/2 motion is relative, and a sum of steps drifts
    rel(-3000, -3000); rel(x, y)
    for down in (True, False):
        qmp('input-send-event', {'events': [{'type': 'btn', 'data': {'down': down, 'button': button}}]})
        time.sleep(0.1)
KEYS = {' ': ['spc'], '(': ['shift', '9'], ')': ['shift', '0'], '*': ['shift', '8'],
        '-': ['minus'], '+': ['shift', 'equal']}
def type_text(s):
    for ch in s:
        keys = KEYS.get(ch, [ch.lower()])
        qmp('send-key', {'keys': [{'type': 'qcode', 'data': k} for k in keys]}); time.sleep(0.05)
    qmp('send-key', {'keys': [{'type': 'qcode', 'data': 'ret'}]})
def screen():
    p = os.path.join(work, 'shot.ppm'); qmp('screendump', {'filename': p})
    with open(p, 'rb') as f:
        data = f.read()
    # P6, width height, maxval, then RGB
    parts = data.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]
def region(shot, x0, y0, x1, y1):
    w, h, px = shot
    return b''.join(px[(y * w + x0) * 3:(y * w + x1) * 3] for y in range(y0, min(y1, h)))

try:
    # control first: an answer compared against the wrong value must not pass
    end = time.time() + float(os.environ.get('SMOKE_IDLE_S', '600'))
    idle = False
    while time.time() < end and qemu.poll() is None:
        if 'first idle' in log_text():
            idle = True; break
        time.sleep(3)
    check('idle', idle, '' if idle else 'no "first idle" in the desk log; serial: %s' % os.path.join(work, 'serial.log'))
    if not idle:
        raise Stop        # (not SystemExit: inside this try it became exit status 0 -- a failed run
                          # reported success, caught by the no-core control)
    a = channel('(+ 40 2)')
    check('control', a is not None and a != '43', 'the answer %r is not taken for 43' % a)
    check('channel', a == '42', 'answer %r' % a)
    s = channel('(list *t4-w* *t4-h*)')
    check('screen', s is not None and s.startswith('(') and s != '(0 0)', 'GOP %s' % s)
    c1 = region(screen(), 40, 60, 300, 170); end = time.time() + 20
    while True:                                          # a second's tick, given 20 s on a busy host
        time.sleep(2); c2 = region(screen(), 40, 60, 300, 170)
        if c2 != c1 or time.time() > end: break
    check('clock', c1 != c2, 'the Clock region changed' if c1 != c2 else 'the Clock region did not change')
    before = screen()
    click(400, 400, 'right'); time.sleep(2)
    after = screen()
    menu = region(before, 400, 400, 510, 540) != region(after, 400, 400, 510, 540)
    check('menu', menu, 'the Workspace menu' if menu else 'nothing appeared at the right click')
    # Terminal, the menu's third item.  Polled, not slept: on a loaded host the window took
    # 6 s to appear and keys typed before it has the focus go nowhere.
    w0 = region(screen(), 300, 200, 900, 700)
    click(438, 470)
    end = time.time() + 60
    while time.time() < end and region(screen(), 300, 200, 900, 700) == w0:
        time.sleep(2)
    time.sleep(3)
    type_text('(setq *smoke* (* 6 7))')
    end = time.time() + 60; t = None
    while time.time() < end:
        t = channel('*smoke*')
        if t == '42': break
        time.sleep(3)
    check('terminal', t == '42', '*SMOKE* read back as %r' % t)
except Stop:
    pass
finally:
    qemu.kill(); qemu.wait()
    if not KEEP:
        shutil.rmtree(work, ignore_errors=True)
    else:
        print('kept', work)

ok = bool(results) and all(results)
print('t420-x64-qemu: %s (%d of %d)' % ('PASS' if ok else 'FAIL', sum(results), len(results)))
sys.exit(0 if ok else 1)
