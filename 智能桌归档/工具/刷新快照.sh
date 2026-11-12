#!/usr/bin/env bash
# 刷新「智能桌归档/源码快照」并重建 MANIFEST.md
#
# 用法：bash 智能桌归档/工具/刷新快照.sh
# 只读工作副本，不改动它们。secrets.yaml 永不归档。

set -uo pipefail

ARC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$ARC/.." && pwd)"
SNAP="$ARC/源码快照"

echo "工作区: $ROOT"
echo "归档区: $ARC"
echo

# --- 清空旧的快照内容（保留 secrets.example.yaml 由脚本重建） ---------------
rm -rf "$SNAP/esphome"/*.yaml "$SNAP/esphome"/*.h 2>/dev/null
mkdir -p "$SNAP/esphome" "$SNAP/homeassistant/www" "$SNAP/tools" "$SNAP/抓包"

copy() {   # copy <src> <dst>
  if [ -f "$1" ]; then
    cp -f "$1" "$2" && echo "  + ${1#$ROOT/}"
  else
    echo "  ! 缺失: $1"
  fi
}

echo "[固件]"
copy "$ROOT/esphome/desk-c3.yaml"        "$SNAP/esphome/desk-c3.yaml"
copy "$ROOT/esphome/desk_proto.h"        "$SNAP/esphome/desk_proto.h"
copy "$ROOT/esphome/desk-lightbar-c3.yaml" "$SNAP/esphome/desk-lightbar-c3.yaml"

echo "[HA]"
copy "$ROOT/homeassistant/desk.yaml"     "$SNAP/homeassistant/desk.yaml"
copy "$ROOT/homeassistant/www/desk-vertical-slider.js" "$SNAP/homeassistant/www/desk-vertical-slider.js"

echo "[工具]"
for f in "$ROOT"/tools/*.ps1 "$ROOT"/tools/*.py; do
  [ -f "$f" ] && cp -f "$f" "$SNAP/tools/" && echo "  + tools/$(basename "$f")"
done

echo "[抓包脚本]"
for f in "$ROOT"/captures/*.py "$ROOT"/captures/*.sh; do
  [ -f "$f" ] && cp -f "$f" "$SNAP/抓包/" && echo "  + captures/$(basename "$f")"
done

echo "[原始文档]"
mkdir -p "$ARC/原始文档"
for f in "$ROOT/升降桌智能化改造方案.md" "$ROOT/ESP32-C3接入计划.md"; do
  [ -f "$f" ] && cp -f "$f" "$ARC/原始文档/" && echo "  + $(basename "$f")"
done

# --- 重建 MANIFEST -----------------------------------------------------------
MAN="$ARC/MANIFEST.md"
{
  echo "# 快照清单"
  echo
  echo "> 自动生成，勿手改。刷新时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "> 校验算法：SHA-256（前 16 位），用于确认「归档内容 == 工作副本」。"
  echo
  echo "| 文件 | 大小 | SHA-256(16) |"
  echo "|---|---|---|"
  cd "$SNAP" || exit 1
  find . -type f \( -name '*.yaml' -o -name '*.h' -o -name '*.js' -o -name '*.ps1' -o -name '*.py' -o -name '*.sh' \) \
    | sort | while read -r f; do
      size=$(wc -c < "$f" | tr -d ' ')
      hash=$(sha256sum "$f" | cut -c1-16)
      echo "| \`${f#./}\` | ${size} B | \`${hash}\` |"
    done
} > "$MAN"

echo
echo "完成。清单: $MAN"
echo "共 $(grep -c '^| `' "$MAN") 个文件。"
