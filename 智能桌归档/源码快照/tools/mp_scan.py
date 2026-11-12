import network
import time

def name(b):
    try:
        return b.decode()
    except Exception:
        return "".join(chr(c) if 32 <= c < 127 else "?" for c in b)

sta = network.WLAN(network.STA_IF)
sta.active(True)
time.sleep_ms(500)
res = sta.scan()
print("FOUND", len(res))
for r in res:
    print("|%-26s|ch=%-3d|rssi=%-4d|sec=%s|hid=%s"
          % (name(r[0]), r[2], r[3], r[4], r[5] if len(r) > 5 else "?"))
