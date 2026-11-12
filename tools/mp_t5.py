import machine
import time

u = machine.UART(1, baudrate=9600, tx=21, rx=20, timeout=0)
time.sleep_ms(300)

def block(ms=400):
    rx = bytearray()
    t0 = time.ticks_ms()
    while time.ticks_diff(time.ticks_ms(), t0) < ms:
        b = u.read(64)
        if b:
            rx += b
    return rx

names = {0x25: "preset1", 0x26: "preset2", 0x27: "preset3", 0x28: "preset4"}
for k in range(3):
    u.read()
    u.write(bytes([0xF1, 0xF1, 0x07, 0x00, 0x07, 0x7E]))
    buf = block(400)
    i = 0
    out = []
    while i + 5 <= len(buf):
        if buf[i] != 0xF2 or buf[i + 1] != 0xF2:
            i += 1
            continue
        cmd = buf[i + 2]
        ln = buf[i + 3]
        total = 6 + ln
        if i + total > len(buf):
            break
        p = buf[i + 4:i + 4 + ln]
        if cmd == 0x01 and ln >= 2:
            out.append("height=%d" % ((p[0] << 8) | p[1]))
        elif cmd in names and ln >= 2:
            out.append("%s=%d" % (names[cmd], (p[0] << 8) | p[1]))
        i += total
    print("read %d: %s" % (k + 1, "  ".join(out)))
    time.sleep_ms(300)
