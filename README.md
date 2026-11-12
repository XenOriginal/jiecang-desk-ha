# 工作区索引

智能书桌改造项目（捷昌 JCHT35K9 + JCB36NE3A-230 → ESP32-C3 → ESPHome → Home Assistant）。

## 从哪开始

**先读 [`智能桌归档/README.md`](智能桌归档/README.md)** —— 一页讲清做了什么、现在什么状态、每条线该看哪份文档。

## 目录

| 路径 | 是什么 |
|---|---|
| `智能桌归档/` | **结构化归档**：硬件接口、协议逆向、固件设计、HA 配置、运维、时间线 |
| 　`├ 源码快照/` | 固件 / HA / 工具脚本的冻结副本（含 SHA-256 清单） |
| 　`├ 抓包原始数据/` | 14 个 `.sr` 原始波形 |
| 　`├ 原始文档/` | 两份过程文档原文 |
| 　`└ 构建日志/` | 历次 ESPHome 编译输出 |
| `esphome/` | **工作副本**：`desk-c3.yaml`、`desk_proto.h`、`secrets.yaml`（不入库） |
| `homeassistant/` | **工作副本**：`desk.yaml`（package）、`www/desk-vertical-slider.js` |
| `tools/` | PC 端工具：`desk.ps1`、`desk-presets.ps1`、MicroPython 测试脚本 |
| `captures/` | 抓包脚本与原始 `.sr` |
| `升降桌智能化改造方案.md` | 早期方案（含 HS 口协议、路线对比、完整推导） |
| `ESP32-C3接入计划.md` | 实施计划（含逐条踩坑记录，807 行） |

## 工作副本 vs 归档快照

日常改动在 `esphome/` `homeassistant/` `tools/`。`智能桌归档/源码快照/` 只是某个时间点的冻结，
**不要在里面改**。改完跑：

```bash
bash 智能桌归档/工具/刷新快照.sh
```

## 三条不可忘的原则

1. **手控器永远保留** —— 拔掉我们的板子就回到原厂状态。
2. **移动中不要轮询** —— `0x07` 会打断自驱运动，表现为"每 400 ms 只走 10 mm"。
3. **`0x7E` 不转义** —— 必须按 `LEN` 算帧长再验 `CHK`，不能扫终止符。

---

## 关于这份仓库

发布版做过脱敏：Wi-Fi SSID、内网地址、个人实体 id 和本机绝对路径都换成了占位符
（`YOUR_2G_SSID` / `YOUR_HA_HOST` / `person.you` / `$HOME`）。

`secrets.yaml` **从未入库**。首次使用请复制模板再填自己的值：

```bash
cp esphome/secrets.example.yaml esphome/secrets.yaml
```

API 加密密钥必须是 base64 的 32 字节（十六进制不行）：

```bash
python -c "import base64,os;print(base64.b64encode(os.urandom(32)).decode())"
```

> 这套改造直接操作 220 V 升降桌的控制器。任何接线改动前先断电，量过电平再上手。
> 本项目按"原样提供"，不承担设备损坏或人身伤害的责任。
