import sys, zipfile, bisect

BAUDS = [9600, 19200, 38400, 115200]

def load(path):
    z = zipfile.ZipFile(path)
    names = z.namelist()
    meta = z.read('metadata').decode('utf-8', 'replace') if 'metadata' in names else ''
    logic = sorted(n for n in names if n.startswith('logic-'))
    data = b''.join(z.read(n) for n in logic)
    sr = 0
    for line in meta.splitlines():
        if line.startswith('samplerate='):
            raw = line.split('=', 1)[1].strip()
            num = ''
            for ch in raw:
                if ch.isdigit() or ch == '.':
                    num += ch
                elif num:
                    break
            mult = 1
            low = raw.lower()
            if 'k' in low:
                mult = 1000
            elif 'm' in low:
                mult = 1000000
            sr = int(float(num or 0) * mult)
    return data, sr

def transitions(data, ch):
    mask = 1 << ch
    prev = -1
    out = []
    for i, b in enumerate(data):
        v = 1 if (b & mask) else 0
        if v != prev:
            out.append((i, v))
            prev = v
    return out

def level_at(trans, pos):
    i = bisect.bisect_right([t[0] for t in trans], pos) - 1
    return trans[i][1] if i >= 0 else trans[0][1]

def uart_decode(data, sr, ch, baud):
    trans = transitions(data, ch)
    if len(trans) < 4:
        return []
    idxs = [t[0] for t in trans]
    bit = sr / float(baud)
    out = []
    k = 0
    while k < len(trans):
        pos, lvl = trans[k]
        if lvl != 0:
            k += 1
            continue
        start = pos
        val = 0
        ok = True
        for b in range(8):
            p = int(start + bit * (1.5 + b))
            if p >= len(data):
                ok = False
                break
            if level_at(trans, p):
                val |= (1 << b)
        sp = int(start + bit * 9.5)
        if ok and sp < len(data) and level_at(trans, sp) == 1:
            out.append((start, val))
            # jump past stop bit
            nxt = bisect.bisect_left(idxs, sp)
            k = max(k + 1, nxt)
        else:
            k += 1
    return out

def report(path, quiet=False):
    data, sr = load(path)
    if sr == 0:
        sr = 500000
    dur = len(data) / float(sr)
    hits = 0
    lines = []
    for ch in (0, 2, 3, 4, 7):
        trans = transitions(data, ch)
        if len(trans) < 2:
            if not quiet:
                lines.append("D%d: 无跳变 (静态 %s)" % (ch, "高" if level_at(trans, 0) else "低"))
            continue
        widths = [trans[i+1][0]-trans[i][0] for i in range(len(trans)-1)]
        minw = min(widths)
        if not quiet:
            lines.append("D%d: %d 次跳变, 最窄脉宽 %.1f us" % (ch, len(trans), minw*1e6/sr))
        if minw * 1e6 / sr > 2:
            for baud in BAUDS:
                if abs(minw - sr/float(baud)) < sr/float(baud) * 0.35:
                    bytes_ = uart_decode(data, sr, ch, baud)
                    if len(bytes_) >= 3:
                        hits += len(bytes_)
                        lines.append("  >>> D%d @ %d baud: %d 字节" % (ch, baud, len(bytes_)))
                        for pos, v in bytes_[:40]:
                            lines.append("      t=%8.4fs  0x%02X (%3d)" % (pos/float(sr), v, v))
                        break
    if not quiet:
        print("文件 %s | %.3f s | %d 样本 @ %d Hz" % (path.split('/')[-1], dur, len(data), sr))
        for l in lines:
            print(l)
        if hits == 0:
            print("  → 无有效串口帧")
    return hits

if __name__ == '__main__':
    quiet = '--quiet' in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    h = report(args[0], quiet)
    sys.exit(0 if h >= 3 else 1)
