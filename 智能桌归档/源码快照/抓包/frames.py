"""把 .sr 抓包解成 F2F2 帧表，并给出高度字段的候选解释。"""
import sys, os, glob
from analyze import load, uart_decode

HDR = (0xF2, 0xF2)


def frames_of(path):
    data, sr = load(path)
    if sr == 0:
        sr = 500000
    # 盒子的 TX 在 pin3 = D2
    byts = uart_decode(data, sr, 2, 9600)
    vals = [v for _, v in byts]
    out = []
    i = 0
    while i + 8 < len(vals):
        if vals[i] == HDR[0] and vals[i + 1] == HDR[1]:
            ln = vals[i + 3]
            total = 6 + ln
            if i + total - 1 < len(vals) and vals[i + total - 1] == 0x7E:
                body = vals[i + 2:i + 4 + ln]          # cmd, len, payload...
                if sum(body) & 0xFF == vals[i + total - 2]:
                    out.append((byts[i][0] / float(sr), body))
                    i += total
                    continue
        i += 1
    return out


def main(paths):
    rows = []
    for p in paths:
        base = os.path.basename(p)
        for t, body in frames_of(p):
            rows.append((base, t, body))
    if not rows:
        print("没有解析到合法帧")
        return 1
    print("%-12s %8s  %-22s  %s" % ("file", "t(s)", "cmd len payload", "候选:BE(p0,p1) BE(p1,p2)"))
    for base, t, body in rows:
        cmd, ln = body[0], body[1]
        pay = body[2:]
        a = (pay[0] << 8 | pay[1]) if len(pay) >= 2 else 0
        b = (pay[1] << 8 | pay[2]) if len(pay) >= 3 else 0
        print("%-12s %8.4f  cmd=%02X len=%d %s  A=%d B=%d"
              % (base, t, cmd, ln, " ".join("%02X" % x for x in pay), a, b))
    print("\n共 %d 帧" % len(rows))
    # 去重统计 payload 第 2 字节（疑似高度高位/低位）的变化范围
    return 0


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args:
        args = sorted(glob.glob('run2/*.sr'))
    sys.exit(main(args))
