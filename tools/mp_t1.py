import machine
import time

# IO20 = control box TX -> our RX ; IO21 = our TX -> control box RX
u = machine.UART(1, baudrate=9600, tx=21, rx=20, timeout=50)
print("UART:", u)
time.sleep_ms(150)
u.read()

# 1) listen while idle (the box normally stays silent until polled)
idle = bytearray()
t0 = time.ticks_ms()
while time.ticks_diff(time.ticks_ms(), t0) < 1500:
    b = u.read(64)
    if b:
        idle += b
print("IDLE_BYTES", len(idle), idle.hex())

# 2) poll: F1 F1 07 00 07 7E  (CMD_SETTINGS -> box replies with presets + height)
u.write(bytes([0xF1, 0xF1, 0x07, 0x00, 0x07, 0x7E]))

rx = bytearray()
t0 = time.ticks_ms()
while time.ticks_diff(time.ticks_ms(), t0) < 900:
    b = u.read(64)
    if b:
        rx += b
print("REPLY_BYTES", len(rx), rx.hex())
