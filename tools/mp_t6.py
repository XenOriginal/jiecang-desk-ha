import machine
import time

u = machine.UART(1, baudrate=9600, tx=21, rx=20, timeout=0)
time.sleep_ms(300)
u.write(bytes([0xF1, 0xF1, 0x02, 0x00, 0x02, 0x7E]))
time.sleep_ms(2200)
u.read()
u.write(bytes([0xF1, 0xF1, 0x07, 0x00, 0x07, 0x7E]))
rx = bytearray()
t0 = time.ticks_ms()
while time.ticks_diff(time.ticks_ms(), t0) < 400:
    b = u.read(64)
    if b:
        rx += b
i = 0
while i + 9 <= len(rx):
    if rx[i] == 0xF2 and rx[i + 1] == 0xF2 and rx[i + 2] == 0x01 and rx[i + 3] == 0x03:
        print("FINAL_HEIGHT", (rx[i + 4] << 8) | rx[i + 5])
        break
    i += 1
