import machine
import time

u = machine.UART(1, baudrate=9600, tx=21, rx=20, timeout=0)
time.sleep_ms(200)

def read_frames(ms=400):
    rx = bytearray()
    t0 = time.ticks_ms()
    while time.ticks_diff(time.ticks_ms(), t0) < ms:
        b = u.read(64)
        if b:
            rx += b
    return rx

def height():
    for _ in range(4):
        u.read()
        u.write(bytes([0xF1, 0xF1, 0x07, 0x00, 0x07, 0x7E]))
        buf = read_frames(400)
        i = 0
        while i + 9 <= len(buf):
            if buf[i] == 0xF2 and buf[i + 1] == 0xF2 and buf[i + 2] == 0x01 and buf[i + 3] == 0x03:
                return (buf[i + 4] << 8) | buf[i + 5]
            i += 1
        time.sleep_ms(100)
    return None

h0 = height()
print("H0", h0)

# step up (CMD 0x01)
u.write(bytes([0xF1, 0xF1, 0x01, 0x00, 0x01, 0x7E]))
time.sleep_ms(2200)
h1 = height()
print("H_UP", h1, "delta", (h1 - h0) if (h0 and h1) else None)

time.sleep_ms(900)

# step back down (CMD 0x02)
u.write(bytes([0xF1, 0xF1, 0x02, 0x00, 0x02, 0x7E]))
time.sleep_ms(2200)
h2 = height()
print("H_DOWN", h2, "delta_vs_start", (h2 - h0) if (h0 and h2) else None)
