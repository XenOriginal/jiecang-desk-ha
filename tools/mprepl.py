"""Minimal MicroPython raw-REPL driver for the desk bring-up.

    python mprepl.py probe
    python mprepl.py file <script.py>
    python mprepl.py run "<single line>"

The ESP32-C3 Super Mini exposes its console on the native USB-Serial-JTAG
peripheral (VID 303A:1001), so the CDC port is completely independent of the
hardware UART on IO20/IO21. DTR/RTS are held deasserted so that opening the
port never disturbs the chip.
"""

import sys
import time

import serial

PORT = "COM4"
BAUD = 115200


def open_port(port=PORT):
    s = serial.Serial(port, BAUD, timeout=0.05)
    try:
        s.dtr = False
        s.rts = False
    except Exception:
        pass
    time.sleep(0.2)
    return s


def drain(s, seconds=0.3):
    end = time.time() + seconds
    buf = bytearray()
    while time.time() < end:
        n = s.in_waiting
        if n:
            buf += s.read(n)
        else:
            time.sleep(0.01)
    return bytes(buf)


def read_until(s, marker, timeout):
    end = time.time() + timeout
    buf = bytearray()
    while time.time() < end:
        n = s.in_waiting
        if n:
            buf += s.read(n)
            if buf.endswith(marker):
                return bytes(buf)
        else:
            time.sleep(0.01)
    return bytes(buf)


def raw_exec(s, code, wait=5.0):
    """Execute code in the raw REPL. Returns (stdout, stderr)."""
    s.write(b"\x03")            # interrupt anything running
    time.sleep(0.12)
    drain(s, 0.2)
    s.write(b"\x01")            # enter raw REPL
    if b"raw REPL" not in read_until(s, b">", 1.5):
        # already in raw mode or a stale prompt: harmless, continue
        drain(s, 0.1)

    s.write(code.encode() + b"\x04")   # Ctrl-D executes the buffer

    buf = bytearray()
    end = time.time() + wait
    while time.time() < end:
        n = s.in_waiting
        if n:
            buf += s.read(n)
            # reply shape: "OK" out "\x04" err "\x04" ">"
            if buf.count(b"\x04") >= 2 and buf.rstrip(b"\r\n").endswith(b">"):
                break
        else:
            time.sleep(0.01)

    raw = bytes(buf)
    if raw.startswith(b"OK"):
        raw = raw[2:]
    parts = raw.split(b"\x04")
    out = parts[0].decode(errors="replace").strip()
    err = parts[1].decode(errors="replace").strip() if len(parts) > 1 else ""
    return out, err


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "probe"
    s = open_port()
    try:
        if cmd == "probe":
            s.write(b"\x03")
            time.sleep(0.2)
            print("banner:", repr(drain(s, 0.6)[:200]))
            out, err = raw_exec(
                s, "import sys;print(sys.implementation);print(sys.platform)")
            print("out:", out)
            if err:
                print("err:", err)
        elif cmd == "file":
            code = open(sys.argv[2], encoding="utf-8").read()
            out, err = raw_exec(s, code, wait=25.0)
            print(out)
            if err:
                print("--- stderr ---")
                print(err)
        elif cmd == "run":
            out, err = raw_exec(s, sys.argv[2], wait=10.0)
            print(out)
            if err:
                print("--- stderr ---")
                print(err)
    finally:
        try:
            s.write(b"\x02")   # leave raw REPL
        except Exception:
            pass
        time.sleep(0.1)
        s.close()


if __name__ == "__main__":
    main()
