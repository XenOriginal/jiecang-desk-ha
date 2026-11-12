import machine
import time

u = machine.UART(1, baudrate=9600, tx=21, rx=20, timeout=20)
time.sleep_ms(150)

def parse(buf):
    """Split F2 F2 frames by LEN, verify CHK, return list of (cmd, params)."""
    out = []
    i = 0
    n = len(buf)
    while i + 5 <= n:
        if buf[i] != 0xF2 or buf[i + 1] != 0xF2:
            i += 1
            continue
        cmd = buf[i + 2]
        ln = buf[i + 3]
        total = 6 + ln
        if i + total > n:
            break
        body = buf[i + 2:i + 4 + ln]
        cs = 0
        for b in body:
            cs = (cs + b) & 0xFF
        ok = (cs == buf[i + total - 2]) and (buf[i + total - 1] == 0x7E)
        out.append((cmd, bytes(buf[i + 4:i + 4 + ln]), ok))
        i += total
    return out

def poll():
    u.read()
    t0 = time.ticks_us()
    u.write(bytes([0xF1, 0xF1, 0x07, 0x00, 0x07, 0x7E]))
    rx = bytearray()
    first = None
    while time.ticks_diff(time.ticks_us(), t0) < 400000:
        b = u.read(64)
        if b:
            if first is None:
                first = time.ticks_diff(time.ticks_us(), t0)
            rx += b
            if len(rx) >= 41:
                break
    return rx, first

lats = []
heights = []
bad = 0
for k in range(10):
    rx, first = poll()
    frames = parse(rx)
    h = None
    for cmd, p, ok in frames:
        if not ok:
            bad += 1
        if cmd == 0x01 and len(p) >= 2:
            h = (p[0] << 8) | p[1]
    if first:
        lats.append(first / 1000.0)
    heights.append(h)
    print("poll %2d  n=%3d  frames=%d  first=%.1fms  h=%s"
          % (k + 1, len(rx), len(frames), (first or 0) / 1000.0, h))
    time.sleep_ms(120)

print("LATENCY_MIN_MS %.1f" % min(lats))
print("LATENCY_MAX_MS %.1f" % max(lats))
print("BAD_CHECKSUMS", bad)
print("HEIGHTS", heights)
