CLI="$HOME/.workbuddy/tools/sigrok-cli/sigrok-cli.exe"
BASE="$PWD/captures"
OUT="$BASE/loop"
mkdir -p "$OUT"
found=0
for i in $(seq -w 1 150); do
  "$CLI" -d fx2lafw --config samplerate=500k --samples 600000 -C D0,D2,D3,D4,D7 -o "$OUT/c$i.sr" >/dev/null 2>&1
  if python "$BASE/analyze.py" "$OUT/c$i.sr" --quiet 2>/dev/null; then
    cp "$OUT/c$i.sr" "$BASE/HIT_$i.sr"
    echo "HIT chunk $i"
    found=1
    break
  fi
  rm -f "$OUT/c$i.sr"
done
echo "loop finished found=$found"
