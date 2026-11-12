import machine
import time

u = machine.UART(1, baudrate=9600, tx=21, rx=20, timeout=0)
time.sleep_ms(150)
u.read()

def measure():
    t0 = time.ticks_us()
    u.write(bytes([0xF1, 0xF1, 0x07, 0x00, 0x07, 0x7E]))
    first = None
    rx = bytearray()
    while time.ticks_diff(time.ticks_us(), t0) < 500000:
        b = u.read(64)
        if b:
            if first is None:
                first = time.ticks_diff(time.ticks_us(), t0)
            rx += b
            if len(rx) >= 41:
                break
    total = time.ticks_diff(time.ticks_us(), t0)
    return first, total, len(rx)

res = []
for k in range(8):
    f, t, n = measure()
    res.append((f or 0, t, n))
    print("try %d  first=%.2fms  complete=%.2fms  n=%d"
          % (k + 1, (f or 0) / 1000.0, t / 1000.0, n))
    time.sleep_ms(150)

firsts = [r[0] for r in res]
print("FIRST_MIN_MS %.2f" % (min(firsts) / 1000.0))
print("FIRST_MAX_MS %.2f" % (max(firsts) / 1000.0))
print("TOTAL_AVG_MS %.2f" % (sum(r[1] for r in res) / len(res) / 1000.0))
