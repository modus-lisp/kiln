#!/usr/bin/env python3
"""The Zero as the T420's USB keyboard and mouse: boot reports written to the HID gadget
(setup-gadget.sh: /dev/hidg0 a keyboard, /dev/hidg1 a mouse with a wheel), which the T420's
desk binds beside the disk (vessel src/t420-usb-disk.lisp).

  t4hid.py type 'TEXT'            keys for TEXT (\\n is Return; US layout)
  t4hid.py key NAME [NAME ...]    ret esc tab bksp del up down left right home end pgup pgdn f1..f12,
                                  or a character; ctrl+x / shift+x / alt+x combine
  t4hid.py move DX DY             relative motion (+Y is down)
  t4hid.py goto X Y               to the corner first (the desk clamps there), then to X Y
  t4hid.py click [left|right|middle] [X Y]   (also: double)
  t4hid.py down [BUTTON] / up
  t4hid.py drag X1 Y1 X2 Y2 [BUTTON]
  t4hid.py scroll N               the wheel: N > 0 up, N < 0 down

A boot mouse is relative and the desk adds no acceleration, so GOTO is exact.  A report waits
until the T420 takes it; if nothing takes it for 2 s (no desk running, or the desk did not bind
the device) this says so and stops.
"""
import os, select, sys, time

KBD, MOUSE = '/dev/hidg0', '/dev/hidg1'
BUTTONS = {'left': 1, 'right': 2, 'middle': 4}
CORNER = 3000          # more than the screen's width: any pointer ends at 0,0

K = {}
for i, c in enumerate('abcdefghijklmnopqrstuvwxyz'): K[c] = (0, 0x04 + i)
for i, c in enumerate('1234567890'): K[c] = (0, 0x1E + i)
for c, u in ((' ', 0x2C), ('\n', 0x28), ('-', 0x2D), ('=', 0x2E), ('[', 0x2F), (']', 0x30), ('\\', 0x31),
             (';', 0x33), ("'", 0x34), ('`', 0x35), (',', 0x36), ('.', 0x37), ('/', 0x38), ('\t', 0x2B)):
    K[c] = (0, u)
for c, base in (('!', '1'), ('@', '2'), ('#', '3'), ('$', '4'), ('%', '5'), ('^', '6'), ('&', '7'), ('*', '8'),
                ('(', '9'), (')', '0'), ('_', '-'), ('+', '='), ('{', '['), ('}', ']'), ('|', '\\'),
                (':', ';'), ('"', "'"), ('~', '`'), ('<', ','), ('>', '.'), ('?', '/')):
    K[c] = (2, K[base][1])
for c in 'abcdefghijklmnopqrstuvwxyz':
    K[c.upper()] = (2, K[c][1])
NAMED = {'ret': 0x28, 'enter': 0x28, 'esc': 0x29, 'bksp': 0x2A, 'tab': 0x2B, 'space': 0x2C,
         'del': 0x4C, 'home': 0x4A, 'end': 0x4D, 'pgup': 0x4B, 'pgdn': 0x4E,
         'right': 0x4F, 'left': 0x50, 'down': 0x51, 'up': 0x52}
NAMED.update({'f%d' % i: 0x3A + i - 1 for i in range(1, 13)})
MODS = {'ctrl': 1, 'shift': 2, 'alt': 4, 'gui': 8}

_fds = {}


def send(dev, report):
    fd = _fds.get(dev)
    if fd is None:
        fd = _fds[dev] = os.open(dev, os.O_WRONLY | os.O_NONBLOCK)
    end = time.time() + 2
    while True:
        try:
            os.write(fd, bytes(report))
            break
        except BlockingIOError:
            left = end - time.time()
            if left <= 0 or not select.select([], [fd], [], left)[1]:
                sys.exit('%s: the T420 is not taking reports (no desk, or the device is not bound)' % dev)
    # the next write waits for this report to be taken, so pace nothing else here


def key(mod, usage):
    send(KBD, [mod, 0, usage, 0, 0, 0, 0, 0])
    send(KBD, [0] * 8)


def key_named(spec):
    mod, name = 0, spec
    while '+' in name and name.split('+', 1)[0] in MODS:
        m, name = name.split('+', 1)
        mod |= MODS[m]
    if name in NAMED:
        key(mod, NAMED[name])
    else:
        m, u = K[name]
        key(mod | m, u)


def mouse(buttons, dx=0, dy=0, wheel=0):
    send(MOUSE, [buttons, dx & 255, dy & 255, wheel & 255])


def move(dx, dy, buttons=0):
    while dx or dy:
        sx, sy = max(-127, min(127, dx)), max(-127, min(127, dy))
        mouse(buttons, sx, sy)
        dx, dy = dx - sx, dy - sy


def goto(x, y, buttons=0):
    move(-CORNER, -CORNER, buttons)
    move(x, y, buttons)


def main(a):
    if not a or a[0] in ('-h', '--help'):
        print(__doc__)
        return
    cmd, rest = a[0], a[1:]
    if cmd == 'type':
        for ch in rest[0].encode().decode('unicode_escape'):
            key(*K[ch])
    elif cmd == 'key':
        for spec in rest:
            key_named(spec)
    elif cmd == 'move':
        move(int(rest[0]), int(rest[1]))
    elif cmd == 'goto':
        goto(int(rest[0]), int(rest[1]))
    elif cmd in ('click', 'double'):
        b = BUTTONS[rest[0]] if rest and rest[0] in BUTTONS else 1
        xy = [int(v) for v in rest if v.lstrip('-').isdigit()]
        if xy:
            goto(*xy)
        for _ in range(2 if cmd == 'double' else 1):
            mouse(b)
            mouse(0)
    elif cmd == 'down':
        mouse(BUTTONS[rest[0]] if rest else 1)
    elif cmd == 'up':
        mouse(0)
    elif cmd == 'drag':
        x1, y1, x2, y2 = (int(v) for v in rest[:4])
        b = BUTTONS[rest[4]] if len(rest) > 4 else 1
        goto(x1, y1)
        mouse(b)
        # in steps a window manager sees as a drag, not one jump
        steps = max(1, max(abs(x2 - x1), abs(y2 - y1)) // 16)
        px, py = x1, y1
        for i in range(1, steps + 1):
            nx, ny = x1 + (x2 - x1) * i // steps, y1 + (y2 - y1) * i // steps
            move(nx - px, ny - py, b)
            px, py = nx, ny
        mouse(0)
    elif cmd == 'scroll':
        n = int(rest[0])
        for _ in range(abs(n)):
            mouse(0, 0, 0, 1 if n > 0 else -1)
    else:
        sys.exit('unknown command: ' + cmd)


if __name__ == '__main__':
    main(sys.argv[1:])
