CLI="$HOME/.workbuddy/tools/sigrok-cli/sigrok-cli.exe"
BASE="$PWD/captures"
OUT="$BASE/run2"
mkdir -p "$OUT"
hit=0
n=0
for i in $(seq -w 1 120); do
  "$CLI" -d fx2lafw --config samplerate=200k --samples 400000 -C D0,D2,D3,D4,D7 -o "$OUT/c$i.sr" >/dev/null 2>&1
  if python "$BASE/analyze.py" "$OUT/c$i.sr" --quiet 2>/dev/null; then
    hit=$((hit+1))
    echo "hit $i (total $hit)"
  else
    rm -f "$OUT/c$i.sr"
  fi
  n=$i
done
echo "done chunks=$n hits=$hit"
