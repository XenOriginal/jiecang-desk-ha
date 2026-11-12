#pragma once

// Protocol helpers for Jiecang JCB36NE3A-230 over the RJ11 "F"/dongle port.
// Verified against real hardware on 2026-11-09.
//
// Frame (we send) : F1 F1 CMD LEN PARAMS... CHK 7E
// Frame (box sends): F2 F2 CMD LEN PARAMS... CHK 7E
// CHK = (CMD + LEN + sum(PARAMS)) & 0xFF      <-- the two address bytes are NOT included
//
// Known traps baked into the helpers below:
//   * 0x7E is NOT escaped and may appear inside PARAMS (heights like 1150 mm encode to 04 7E).
//     Never split frames by scanning for 0x7E; use LEN, then verify CHK.
//   * Frame bytes must be written in one write_array() call, otherwise the box can see
//     a partial frame and silently drop it.

#include <cstddef>
#include <cstdint>
#include <vector>

#include "esphome/core/hal.h"
#include "esphome/components/uart/uart.h"

namespace desk {

// --- command bytes (dongle -> control box) ---
constexpr uint8_t CMD_STEP_UP   = 0x01;
constexpr uint8_t CMD_STEP_DOWN = 0x02;
constexpr uint8_t CMD_SAVE_1    = 0x03;
constexpr uint8_t CMD_SAVE_2    = 0x04;
constexpr uint8_t CMD_GOTO_1    = 0x05;
constexpr uint8_t CMD_GOTO_2    = 0x06;
constexpr uint8_t CMD_SETTINGS  = 0x07;  // returns height + all 4 presets
constexpr uint8_t CMD_UNITS     = 0x0E;
constexpr uint8_t CMD_LOW_POWER = 0x18;
constexpr uint8_t CMD_GOTO_ABS  = 0x1B;  // 2-byte big-endian mm
constexpr uint8_t CMD_VERSION   = 0x1C;
constexpr uint8_t CMD_LOCK      = 0x1F;
constexpr uint8_t CMD_LIMITS    = 0x20;
constexpr uint8_t CMD_SAVE_3    = 0x25;
constexpr uint8_t CMD_SAVE_4    = 0x26;
constexpr uint8_t CMD_GOTO_3    = 0x27;
constexpr uint8_t CMD_GOTO_4    = 0x28;
constexpr uint8_t CMD_STOP      = 0x2B;
constexpr uint8_t CMD_DUMP      = 0xFE;  // read whole settings block

// --- report bytes (control box -> dongle) ---
constexpr uint8_t REP_HEIGHT    = 0x01;  // LEN 3: [hi, lo, status]
constexpr uint8_t REP_RANGE     = 0x07;  // LEN 4
constexpr uint8_t REP_LIMITS    = 0x20;  // LEN 1: bit0 max set, bit4 min set
constexpr uint8_t REP_LIMIT_MAX = 0x21;  // LEN 2: big-endian mm
constexpr uint8_t REP_LIMIT_MIN = 0x22;  // LEN 2: big-endian mm
constexpr uint8_t REP_PRESET_1  = 0x25;  // LEN 2, big-endian mm
constexpr uint8_t REP_PRESET_2  = 0x26;
constexpr uint8_t REP_PRESET_3  = 0x27;
constexpr uint8_t REP_PRESET_4  = 0x28;

inline uint8_t checksum(const uint8_t *p, size_t n) {
  uint8_t cs = 0;
  for (size_t i = 0; i < n; i++) {
    cs = static_cast<uint8_t>(cs + p[i]);
  }
  return cs;
}

// payload = {CMD, LEN, PARAMS...}
inline void send(uart::UARTComponent *u, const std::vector<uint8_t> &payload) {
  if (u == nullptr || payload.size() < 2) {
    return;
  }
  std::vector<uint8_t> f;
  f.reserve(payload.size() + 4);
  f.push_back(0xF1);
  f.push_back(0xF1);
  for (uint8_t b : payload) {
    f.push_back(b);
  }
  f.push_back(checksum(payload.data(), payload.size()));
  f.push_back(0x7E);
  u->write_array(f.data(), f.size());
}

// Command with LEN = 0 (most of them).
inline void simple(uart::UARTComponent *u, uint8_t cmd) { send(u, {cmd, 0x00}); }

inline void goto_abs(uart::UARTComponent *u, uint16_t mm) {
  send(u, {CMD_GOTO_ABS, 0x02, static_cast<uint8_t>(mm >> 8), static_cast<uint8_t>(mm & 0xFF)});
}

inline uint16_t be16(const uint8_t *p) {
  return static_cast<uint16_t>((static_cast<uint16_t>(p[0]) << 8) | p[1]);
}

// -----------------------------------------------------------------------------
// Priming (预热帧)
//
// 这条总线上"安静之后的头一帧"会丢：2026-11-10 实测，空闲几分钟后按单步，
// 第 1 次无任何反应，第 2、3 次才动（1079 -> 1090 -> 1101）。
// 早期固件每 900ms 发一次 0x07，窗口从来没关上过，所以这个坑一直没露头；
// 改成"零后台流量"之后它立刻显形，而且更危险 —— 定点(0x1B)那一帧如果被收成
// 残帧，桌子会朝一个错误的目标跑（实测出现过 1129 -> 1079 的 50mm 过冲）。
//
// 所以每次真正下发命令前先发一帧 0x07 把总线"敲醒"，70ms 后再发真命令。
// 0x07 只读不动作，最坏情况是什么都不发生；它带来的副作用只是手控器屏幕
// 又亮一下，而这一刻本来就已经被我们接下来的操作点亮了。
//
// 对定点(goto)指令额外再补发一次（同样目标，幂等），把残帧概率压到最低。
// 单步(step)绝不可以重发：那会变成两倍行程。
// -----------------------------------------------------------------------------
inline void delay_ms(uint32_t ms) { esphome::delay(ms); }

inline void primed_simple(uart::UARTComponent *u, uint8_t cmd) {
  simple(u, CMD_SETTINGS);
  delay_ms(70);
  simple(u, cmd);
}

inline void primed_goto(uart::UARTComponent *u, uint16_t mm) {
  simple(u, CMD_SETTINGS);
  delay_ms(70);
  goto_abs(u, mm);
  delay_ms(80);
  goto_abs(u, mm);
}

// 只读命令（读设置/读限位）同样会丢，重复发一次即可，幂等。
inline void primed_read(uart::UARTComponent *u) {
  simple(u, CMD_SETTINGS);
  delay_ms(90);
  simple(u, CMD_SETTINGS);
}

}  // namespace desk
