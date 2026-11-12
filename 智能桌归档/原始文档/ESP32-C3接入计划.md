# ESP32-C3 Super Mini 接入 HA 实施计划

> 前置条件：RJ11（F 口）协议已实测打通，`1B` 定点、`05/06/27/28` 记忆位、`2B` 急停全部可用，
> 记忆位已按行程四等分写入（851 / 943 / 1037 / 1129）。
> **2026-11-10 更新：ESP32-C3 与控制盒的串口链路已实测双向打通**（首字节 7.6 ms、41 字节 129 ms、
> 10/10 轮询零校验错误），见 3.7。前面最难的一步已经过了，剩下是固件与 HA 落地。
> 本文解决的是**把这套已验证的帧变成一块能长期挂在桌下、被 HA 和语音调用的接口**。

---

## 一、结论速览

| 问题 | 答案 |
|---|---|
| 用啥做接口 | ESPHome + 自写帧解析（约 60 行 C++），**不用**外部组件 |
| 板子 | ESP32-C3 Super Mini，只占 **2 个 GPIO**（IO20 / IO21） |
| 接哪个口 | RJ11（F 口）三根线：GND + pin3 + pin5 |
| 串口通不通 | ✅ **已实测双向打通**（3.7），无需电平转换、无需预热 |
| 现在到哪一步 | **固件已刷入并在跑**：YOUR_DEVICE_IP:6053，实体齐、数值对、按钮能动作（4.6）。剩 HA 接入 |
| 供电 | **独立 USB 5V**，只共地，绝不从 RJ11 的 pin4 取电 |
| HA 里长什么样 | 高度 sensor + 目标高度 number + 坐/站/急停 button + 可选 cover |
| 语音首选 | **HomeKit**（HA 的 HomeKit Bridge，全本地，Siri 能说"开到 70%"） |
| 米家 | **已排除**：只有 Matter 一条路、必须先有小米中枢网关、设备在米家里会变成"窗帘"。决策记录见第六节 |
| HA 侧要做什么 | 一个 package 文件：cover + 两个 script + 5 条自动化 + HomeKit 桥，见第五节 |

一句话：**这是一块"协议翻译器"，不是"控制器"**。所有运动安全（软起停、防撞、限位、闭环）仍然由控制盒负责，ESP32 只负责"读高度、发目标值"，所以它死机、掉线、重启都不会让桌子乱动。

---

## 二、引脚选型（已用 espboards.dev 的官方引脚表核对）

之前我按"GPIO4/GPIO5"设计的接法是**错的**，核对引脚表后改掉了：

| 板载标签 | GPIO | 官方标记 | 本方案 |
|---|---|---|---|
| `5V` | — | 电源 | USB 5V 输入 |
| `GND` | — | 地 | 与桌子共地 |
| `3V3` | — | 电源 | 备用（直连方案用不到） |
| `IO0` `IO1` `IO3` `IO10` | 0/1/3/10 | **完全安全**（无 strapping / flash / JTAG 职责） | 备用 |
| `IO2` | 2 | strapping（复位需拉高） | 不用 |
| `IO4` | 4 | bootstrapping + JTAG TMS + **FSPIHD（Quad-SPI 数据线）** | 不用 |
| `IO5` | 5 | bootstrapping + JTAG TDI + **FSPIWP** | 不用 |
| `IO6` | 6 | bootstrapping + JTAG TCK + **FSPICLK** | 不用 |
| `IO7` | 7 | bootstrapping + JTAG TDO + **FSPID** | 不用 |
| `IO8` | 8 | strapping（**复位必须为高**，否则可能无法启动）+ 板载蓝灯 | 不用 |
| `IO9` | 9 | strapping（**BOOT 键**，低电平进下载模式） | 不用 |
| `IO21` | 21 | UART0 **TXD** | → 盒子 RX（pin5） |
| `IO20` | 20 | UART0 **RXD** | ← 盒子 TX（pin3） |

**为什么最终选 IO20/IO21：** 它们是这块板子上唯一"专职串口、不承担任何启动职责"的引脚，丝印直接写着 `RX`/`TX`，接线时不可能搞错。IO4-IO7 虽然多数项目也在用，但官方表明确标注它们在 internal-flash 型号上兼作 Quad-SPI 数据线，一旦踩中就是"上电不启动"这种最难查的故障，没必要冒这个险。

**代价**：UART0 被协议占用，日志要改走 USB-Serial-JTAG（配置里已经写好 `logger: hardware_uart: USB_SERIAL_JTAG`），`esphome logs` 仍然走 USB-C 口。

**这块板子的真实短板是天线**：陶瓷天线 CrossAir CA-C03 为了做小，离地平面太近，Wi-Fi 距离和穿墙能力都偏弱。桌下又有金属桌架和电机，是典型的射频坟场。所以：

- 模块**别塞进金属桌架横梁里**，放在桌面下方靠外的塑料盒里；
- 天线那一端朝外、远离电机和金属；
- 如果频繁掉线，在馈电焊盘上焊一段 **31 mm 漆包线**做四分之一波长，实测能补 6-10 dB，这是这块板最有效的改造。

其余规格：ESP32-C3（RISC-V 160 MHz）、4 MB flash、400 KB SRAM、13 个可用 GPIO、6 路 ADC、原生 USB-CDC（刷机不用驱动）。

---

## 三、接线

### 3.1 接线表（已按实测确定）

| RJ11 pin | 功能 | 接到 | 中间加什么 |
|---|---|---|---|
| 1 | NC | — | — |
| 2 | GND | 板子 `GND` | 直连 |
| 3 | TX（盒 → 外） | `IO20`（RX） | **10 k 串联 + 20 k 下拉到 GND**（分压到 3.3 V） |
| 4 | VCC +5 V | **不接** | — |
| 5 | RX（外 → 盒） | `IO21`（TX） | **100 Ω 串联直连**（实测 3.3 V 逻辑，见 3.2） |
| 6 | GND | 与 pin2 同一根地 | 直连（双地，任选其一即可） |

`IO0/IO1/IO3/IO10` 全部空着，留给以后加 OLED 或 ToF 测距。

### 3.2 电压实测：pin5 = 3.3 V（含一个必须复核的前提）

2026-11-10 实测 **pin5 对 pin2 = 3.3 V** → 盒子 RX 是 3.3 V 逻辑，**不需要电平转换**，3.3 节的 BSS138 可以省掉。

但要先排除一个干扰：

> 测量时 **CH340 的 TX 还接在 pin5 上**。CH340 空闲时把 TX 驱动为高，这个高电平有可能本身就是 3.3 V（不少 CH340 模块的 IO 供电取自 USB 的 3.3 V 轨）。也就是说，量到的 3.3 V 有可能来自 CH340，而不是盒子自己的内部上拉。

所以**拔掉 CH340 的 TX 再量一次**（20 秒）：

| 复测结果 | 结论 | 怎么做 |
|---|---|---|
| 仍是 3.3 V | 盒子本身就是 3.3 V 逻辑 | `IO21 → 100 Ω → pin5`，收工（3.4 节） |
| 跳到 ≈5 V | 盒子的 RX 内部上拉到 5 V | 改用电平转换（3.3 节），否则 ESP32 复位/未供电时引脚会被 5 V 顶着 |

一个很强的旁证：**之前所有命令测试都是经 CH340 打进去的，全部成功**。不管那个高电平是 3.3 V 还是 5 V，盒子已经吃下过这个电平——所以"3.3 V 能发命令"在实践中是成立的。剩下的只是**保护 ESP32 引脚**的问题，不是"能不能通"的问题。

### 3.3 方案 A：BSS138 电平转换（仅在复测为 5 V 时才需要）

买一块 **4 通道 BSS138 双向电平转换模块**（2-3 元，淘宝搜"BSS138 I2C 电平转换"），只用其中 1 个通道：

```
           3.3V 侧 (LV)                5V 侧 (HV)
             3V3 ──┬── 10k ──┐              5V ──┬── 10k ──┐
                   │         │                   │         │
   IO21 (TX) ──────┼──── S ──┴── G(BSS138) ── D ┴─────────┴──── RJ11 pin5
                   │         (栅极接 3V3)
                  GND
```

- **栅极 G → 3V3**（固定偏置，不是接 GPIO）
- **源极 S → IO21**，并 10 k 上拉到 3V3
- **漏极 D → pin5**，并 10 k 上拉到 5V（模块自带，不用另加）

工作方式：IO21 拉低 → S 低 → BSS138 导通 → D 被拉到低；IO21 高 → 栅源电压为 0 → 截止 → D 由 10 k 上拉到 5V。**输入输出同相**，正好满足 UART 空闲高电平。

> ⚠️ **务必不要用"单管开漏"。** 原方案写的"GPIO → 1 kΩ → 2N7002 栅极，源极接地，漏极接线"**是反相的**——UART 空闲是高电平，GPIO 空闲高会让 MOS 导通、把线一直按在低电平（break 状态），盒子永远收不到有效数据，现象和"协议不支持"一模一样。要么用上面这种非反相的 BSS138，要么软件反相（ESPHome 里跨版本行为不一致，不推荐）。

### 3.4 方案 B：100 Ω 直连（本机采用）

`IO21 → 100 Ω → pin5`。串联电阻限流、抑制边沿振铃，不承担电平转换。

再加一只 **BAT54S**（SOT-23，1 元）做钳位，把 IO21 上的电压钉在 −0.3 V ~ 3.6 V：

```
   BAT54S：  1 脚 → GND      2 脚（中间）→ 信号线      3 脚 → 3V3
```

它只在"盒子里其实有 5 V 上拉、而 ESP32 处于复位/未供电的高阻态"这种边缘情况下救命——那几十毫秒里 5 V 会直接顶到 IO21 上。手头没有就先用纯 100 Ω，实测 3.3 V 的前提下风险很低，但既然是 1 块钱的事，建议装上。

### 3.5 供电与地

- 板子 `5V` 脚接**独立 USB 5V 电源**（手机充电头即可），不要从 RJ11 pin4 取电——那路 5 V 是喂 BLE 模组的，几十 mA 级，ESP32 Wi-Fi 发射峰值几百 mA，会把盒子拉进异常。
- **只共地**：充电头的 GND 与 RJ11 pin2 接在一起，这是信号参考，必须接。
- `5V` 脚旁边并 **100 µF 电解 + 100 nF 陶瓷**，抑制 Wi-Fi 发射瞬间的跌落。

### 3.6 接线时的三条硬规矩

1. **先拔掉 CH340 的 TX 线，并趁这个空档复测一次 pin5 电压**（见 3.2）。两个驱动器同时打一根线会互相打架；而且 CH340 接着时量到的电平可能不是盒子的。逻辑分析仪可以留着，高阻输入无所谓。
2. **先只接 GND + pin3**，跑通读数，再接 pin5。分两步走，出问题时能立刻定位是"读不到"还是"发不出"。
3. **断电再插拔。** RJ11 是弱电，但桌子的控制盒在上电状态下插拔瞬间可能有尖峰。

### 3.7 链路实测：已打通（2026-11-10）

按 3.4 的直连接法（`pin2→GND`、`pin3→IO20`、`pin5→IO21`，中间未加 100 Ω）实测通过，**双向都成立**：

| 项目 | 结果 |
|---|---|
| 空闲时 IO20 | 1.5 s 内 0 字节（盒子静止时确实静默） |
| 发 `F1 F1 07 00 07 7E` 后 | **41 字节 / 5 帧**，与 CH340 收到的完全一致 |
| 连续轮询 10 次 | 10/10 都是 41 字节、5 帧，**校验错误 0 次** |
| 首字节延迟 | **7.6 ms**（最小 7.59，最大 7.69） |
| 41 字节全部到齐 | **129 ms** |
| 回读内容 | 记忆位 851 / 943 / 1037 / 1129 mm，当前高度 851 mm |

三条结论，都会影响后面的固件写法：

1. **不需要电平转换、不需要预热。** 第一次发 `07` 就完整收到了。之前 PC 上那条"打开端口后第一帧必丢"**是 CH340 和 Windows 驱动层的现象，不是盒子的行为**——MCU 上没有这个问题。固件里的"首发重试"可以保留当保险，但不是必要条件。
2. **一次完整轮询占 129 ms 线路时间**（41 字节纯传输只需 43 ms，剩下是盒子帧间停顿）。所以轮询周期**不要小于 200 ms**，否则缓冲会持续堆积。想要更快，只用高度帧（`01`，是 5 帧里的最后一帧）或改运动中被动接收。
3. **`IO20/IO21` 与 USB-Serial-JTAG 控制台互不干扰。** 这一点很关键：调试输出全程走 USB，硬件串口完全归盒子用。

复跑方法：刷 MicroPython 后执行 `tools/mprepl.py file tools/mp_t2.py`（详见 4.5）。

### 3.8 WiFi：必须降发射功率，否则连不上（本机实测）

这是这套硬件最反直觉的一条，也是**上线前必须配好的一项**。

| 项目 | 实测值 |
|---|---|
| 2.4G SSID | `YOUR_2G_SSID`，信道 6，RSSI **-44 dBm**（很近） |
| 2.4G 安全模式 | `7` = **WPA2/WPA3 混合**（比 5G 那个纯 WPA3 更友好） |
| 5G SSID | `YOUR_5G_SSID`（ESP32 **没有 5 GHz 射频，连不上**） |
| 2.4G 密码 | 与 5G **相同**（用 PC 保存的 5G 密码直连成功） |

**默认发射功率下连接必失败。** 表现是反复 `AUTH_FAIL`（ESP-IDF reason 202），
不是"密码错"（1002）也不是"找不到 AP"（1003）——很容易被误判成密码问题，
从而白白去改密码。实测对比：

| 发射功率 | 结果 |
|---|---|
| 默认（约 20 dB） | ❌ 反复 `1001 CONNECTING` ↔ `202 AUTH_FAIL`，永远拿不到 IP |
| 8.5 dB | ✅ 一次成功，`1010 GOT_IP` |
| 5 dB / 2 dB | ✅ 同样稳定 |

原因：满功率发射瞬间的电流峰把 3V3 拉塌，WPA3 的 SAE 握手（CPU + 射频同时满载）
被打断，于是认证失败。降功率之后手到病除。

所以 `desk-c3.yaml` 里的 `output_power: 8.5dB` **不是优化项，是必需项**。
如果换成别的板子/别的电源后信号变差，按 `11dB` → `13dB` 逐级加回，但别直接上满。

硬件侧再补一手：`3V3` 与 `GND` 之间并 **100 µF 电解 + 100 nF 陶瓷**（越靠近模块越好），
能从根上压低这个电流跌落。现在这条只是软件绕过，电容是硬件保险。

**省电模式也会要命，不只是功率。** `power_save_mode: none` 会让射频持续常醒，
平均电流是 modem sleep 的好几倍。ESPHome 固件里实测：`none` + 8.5 dB 依然反复
`Auth Failed` / `Auth Expired`，改成 `light` 后一次连上。所以两项都要管，详见 4.6。

连通性实测（降功率后，MicroPython 环境）：

```
CONN True  IP YOUR_DEVICE_IP
TCP YOUR_HA_HOST:8123 (HA)     OK
TCP YOUR_HA_HOST:22   (gateway) OK
```

也就是说**设备到 HA 的网络路径已经打通**，剩下只是把固件换成 ESPHome 并接入。

---

## 四、固件

两个文件，直接放进 ESPHome 配置目录：`esphome/desk_proto.h` 和 `esphome/desk-c3.yaml`。

### 4.1 为什么不引用社区组件

Rocka84 那个 `jiecang_desk_controller` 组件是给 **HS 口**写的，它的分帧逻辑是"扫到 `0x7E` 就断帧"。而 F 口的 `0x7E` **不转义**，高度 1150 mm 会编码成 `04 7E`——这个坑我们在实测里已经撞到两次（校验和恰好等于 `0x7E`）。用它走 F 口会在特定高度上周期性丢帧，而且症状极具迷惑性：**换个高度就好了**。

所以固件里只做一件事：**按 LEN 算帧长，再校验 CHK**。

### 4.2 轮询策略（这是整套固件最关键的设计）

实测行为是：**盒子只在桌子动的时候说话**（约 4.4 Hz），静止时彻底静默。所以：

- **静止 → 必须轮询**：1.5 s 收不到帧就发一次 `07`，拿回高度 + 4 个记忆位。
- **运动中 → 绝对不能轮询**：`07` 会打断自驱运动（表现为每 400 ms 只走 10 mm）。

固件的写法是给"最近收到帧"和"最近发过运动命令"各记一个时间戳，两个条件都满足才轮询：

```cpp
if (now - last_rx > 1500 && now - last_poll > 700 && now - last_move_cmd > 3000) {
  desk::simple(id(desk_uart), desk::CMD_SETTINGS);
}
```

移动期间盒子自己会上报，所以这个抑制窗口正好落在"命令发出到盒子开始上报"的空档里，既不打断运动，也不会漏掉状态。

### 4.3 已经内建的其他坑

| 坑 | 固件怎么处理 |
|---|---|
| 校验和只算 `CMD+LEN+PARAMS`，不含 `F1 F1` | `desk::checksum()` 只对 payload 求和 |
| 端口刚开/模块刚启动，第一帧可能丢 | `on_boot` 延迟 2 s 后主动发一次 `07`。**实测 MCU 侧没有这个现象**（3.7），重试只是保险 |
| 刚停稳立刻发运动命令会被忽略 | 轮询抑制窗口 3 s，等于天然给了停稳时间 |
| `0x7E` 出现在载荷里 | 按 LEN 分帧 + 校验 CHK，不用终止符 |
| 帧被拆成两次读到 | 用 `std::vector` 累积缓冲，凑够 `6+LEN` 字节才解析 |
| 上电瞬间 IO 状态不确定 | IO20/IO21 不参与任何 strapping，UART 初始化后立即驱动为空闲高；开机的 ROM 日志乱码会被盒子当坏帧丢弃（成帧需要 `F1 F1` + 正确校验和，概率可忽略） |
| HA 重复写"相同"的目标值会被去重 | `Target Height` 不挂 `set_action`，另设无状态 `Apply Target` 按钮，原因见 5.3 |

### 4.4 关于 `friendly_name` 和实体 id

实体名故意用英文（`Desk Height` / `Target Height` / `Stand` …），因为中文名会让 HA 生成不可预测的 `entity_id`。想要中文显示，在 HA 界面里改名即可，`entity_id` 不会变。

### 4.5 烧写通道：USB-Serial-JTAG 的两个坑（已踩过）

这块板子没有 USB 转串口芯片，USB-C 直连 C3 的 **USB-Serial-JTAG**（设备显示为 `VID_303A:1001`，一个 CDC 串口 + 一个 JTAG 接口）。用它刷写有两个坑：

1. **必须加 `--no-stub`。** 默认会尝试上传 stub flasher 并失败，报 `Failed to start stub flasher. There was no response.`。加了 `--no-stub` 走 ROM 下载器就正常（1.6 MB 约 30 s，440 kbit/s）。
   ```
   python -m esptool --chip esp32c3 --port COM4 --no-stub \
       --before default-reset --after hard-reset write-flash 0x0 firmware.bin
   ```
2. **`--after hard-reset` 会让芯片卡在下载模式出不来。** DTR/RTS 在这块板上并没有接到 EN 引脚，所谓 hard reset 只是让 USB 外设自己复位，下载标志位还在，表现为反复打印 `rst:0x15 (USB_UART_CHIP_RESET)`、`boot:0x7 (DOWNLOAD)`、`waiting for download`。**只有 `--after watchdog-reset` 能真正退出**：
   ```
   python -m esptool --chip esp32c3 --port COM4 --no-stub \
       --before no-reset --after watchdog-reset read-mac
   ```
   之后启动模式变为 `boot:0xd (SPI_FAST_FLASH_BOOT)`，固件正常运行。真卡死了拔一下 USB 也能解决（上电复位）。

顺带一个判断技巧：`rst:` 后面是 `0x15 (USB_UART_CHIP_RESET)` 说明这次复位是 USB 外设触发的、软件可控；如果是 `0x03 (RTC_SW_SYS_RST)` 或 `0x0b`，才是真正的硬件复位。

> ESPHome 的 `esphome run` 内部也用 esptool，同样会遇到这两点。真刷不进去就手动刷，产物路径见下。

#### 最好用的刷写命令（本机实测，一次成功）

```bash
python -m esptool --chip esp32c3 --port COM4 --no-stub \
    --before usb-reset --after watchdog-reset \
    write-flash 0x0 .esphome/build/desk-c3/build/firmware.factory.bin
```

关键是 **`--before usb-reset`**：它会通过 USB-JTAG 接口把芯片复位进下载模式，
不需要按 BOOT、不需要 `machine.bootloader()`、也不需要拔插 USB。`--before default-reset`
在这块板上无效（DTR/RTS 没接 EN）。

产物位置（ESPHome 2026）：`.esphome/build/desk-c3/build/firmware.factory.bin`（整包，烧 0x0）
和 `firmware.ota.bin`（仅 OTA 用）。注意不是老版本的 `.pioenvs/`。

---

### 4.6 ESPHome 固件实测：已跑通（2026-11-10 21:00）

固件已在真机上跑起来，设备地址 **`YOUR_DEVICE_IP:6053`**，mDNS 名 `desk-c3.local`。

**最关键的一条：`power_save_mode` 必须是 `light`，不能用 `none`。**

用 `none` 时现象和 MicroPython 里那次一模一样——反复
`reason='Authentication Failed'` → `'Auth Expired'`，偶尔连上一次随即掉线。
原因还是电流：`none` 让射频持续常醒，平均电流是 modem sleep 的好几倍，
这块板的 3V3 余量根本不够，握手过程直接被拉塌。改成 `light` 后一次连上、再没掉过。

> 顺带一个约束：ESPHome 的 `output_power` 有下限 `cv.float_range(min=8.5, max=20.5)`，
> **8.5 dB 已经是最小值**，没法再往下压。所以真正解决问题的是省电模式，不是功率。
> 这也修正了 3.8 的结论——功率和省电模式**两个都要管**，只降功率不够。

实测拉到的实体与数值（全部正确）：

| 实体 | 值 |
|---|---|
| `Desk Height` | 851 mm |
| `Soft Min` / `Soft Max` | 850 / 1130 mm |
| `Preset 1..4` | 851 / 943 / 1037 / 1129 mm |
| `Desk Moving` | false |
| `Target Height` | 851 mm |

按钮闭环（全部经 API 触发，真实桌面动作）：

```
851（起始）→ 按 Step Up → 862 → 873 → 按 Step Down → 865 → 857 → 851
```

也就是说 **读、写、运动闭环全部通过 ESPHome 走通**，HA 侧只剩把集成加进去。

除 `power_save_mode` 外，这次还栽了三个纯软件坑（都已修好，写在这里省下一次踩）：

| 坑 | 现象 | 改法 |
|---|---|---|
| `api.encryption.key` 格式 | `Encryption key must be base64 and 32 bytes long` | 必须是 **base64 的 32 字节**，十六进制不行 |
| `binary_sensor.template` | `[update_interval] is an invalid option` | 新版不支持，改在 `interval: 200ms` 里 `publish_state()` |
| UART 读取 API | `'class IDFUARTComponent' has no member named 'read'` | 用 `available()` + `read_byte()`；`read()` 只在 `UARTDevice` 包装类上 |
| 编译环境 | `ERROR: MSys/Mingw is not supported`，框架安装失败 | **不能在 Git Bash 里编译**，ESP-IDF 见 `MSYSTEM` 环境变量就退出；要用系统自带终端 |

---

## 五、HA 里长什么样

### 5.1 实体清单

| 实体 | 来源 | 用途 |
|---|---|---|
| `sensor.desk_height` | 固件 | 实时高度（mm），静止时 900 ms 轮询一次 |
| `number.target_height` | 固件 | **纯数值框**，写它不会动桌子（原因见 5.3） |
| `button.apply_target` | 固件 | 把 `target_height` 发出去；无状态，每次必触发 |
| `button.stand` / `button.sit` | 固件 | 一键站 / 一键坐（走盒子记忆位 4 / 1） |
| `button.emergency_stop` | 固件 | 急停，连发 3 次 `2B` |
| `button.step_up` / `step_down` | 固件 | 微调一步（10-12 mm，自己会停） |
| `sensor.preset_1..4` | 固件 | 读回的记忆位，核对用 |
| `sensor.soft_min` / `soft_max` | 固件 | 软限位，cover 的百分比基准 |
| `binary_sensor.desk_moving` | 固件 | 800 ms 内高度变过 |
| `cover.desk` | HA 模板 | 0-100% 表达，给 HomeKit / 语音 / 前端滑杆 |
| `binary_sensor.desk_sitting` / `desk_standing` | HA 模板 | 按行程中点判定 |
| `sensor.desk_standing_today` | HA | 今日累计站立时长 |

### 5.2 三层结构

```
固件（协议翻译）  →  HA（语义与逻辑）  →  HomeKit（嘴）
只读高度/发目标值     mm↔%、坐站、计时、日历、离家      Siri / 家庭 App / 手表
```

固件里不含任何业务判断，HA 里不含任何协议细节。这样即使 HA 崩了、ESP32 挂了，手控器和桌子本身都照常用——这是整套方案最让人放心的地方。

### 5.3 必须绕开的一个坑：HA 的状态去重

`number.set_value` 写入与当前**相同**的值时，HA 不产生状态变化，ESPHome 就收不到指令。表现是：**连着说两次「坐下」，第二次毫无反应，而且没有任何报错。**

所以固件把 `target_height` 的 `set_action` 拿掉了（只当数值框），另给一个 `button.apply_target`。HA 侧统一走 `script.desk_goto`：

```yaml
- 写 number.target_height
- delay 200 ms        # 给 ESPHome 时间接收数值
- 按 button.apply_target
```

按钮是无状态的，永远会发帧，因此重复执行一定生效；而且一次命令只发一帧（不会因为 number 也带 `set_action` 而重复发两次 `1B`）。

### 5.4 配置怎么装

`homeassistant/desk.yaml` 是完整 package，含 `cover.desk`、两个 script、5 条自动化、HomeKit 桥。

```
/config/packages/desk.yaml
```

`configuration.yaml` 里需要有：

```yaml
homeassistant:
  packages: !include_dir_named packages
```

改完「开发者工具 → YAML → 检查配置」，通过再重启。

程序化调用：

```yaml
- action: script.desk_goto
  data:
    height: 1000
```

```yaml
- action: script.desk_go_preset
  data:
    which: 4       # 1=坐 2/3=三等分 4=站
```

#### 本机情况：HA 是 Docker（Core）版，跑在 YOUR_HA_HOST

**没有附加组件商店**，所以没有 ESPHome Device Builder，也没有 File Editor / Studio Code Server。
所有文件操作要么走宿主机 shell，要么走 Samba。下面是宿主机上的完整步骤（SSH 到 YOUR_HA_HOST 执行）：

```sh
# 1) 先找 HA 的配置目录挂在哪（容器名可能不叫 homeassistant，先 docker ps 看一眼）
docker ps --format '{{.Names}}\t{{.Image}}'
docker inspect <容器名> --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
# 输出里 Destination 为 /config 的那条，Source 就是配置目录，记作 $CFG
```

```sh
CFG=/your/ha/config          # 换成上一步拿到的路径
mkdir -p "$CFG/packages"
# 把本仓库的 homeassistant/desk.yaml 传上去（scp 或宿主机的编辑器）
# 然后确认 configuration.yaml 里有这一段（没有就加，注意不要重复定义 homeassistant:）
grep -A3 '^homeassistant:' "$CFG/configuration.yaml"
```

`configuration.yaml` 需要：

```yaml
homeassistant:
  packages: !include_dir_named packages
```

> ⚠️ 如果 `homeassistant:` 段已经存在，**只加 `packages:` 这一行**，不要整段替换，否则会把原有的 `time_zone`、`unit_system` 等设置冲掉。

```sh
# 2) 校验配置（比在 UI 里点更可靠，失败会直接打印哪一行错）
docker exec <容器名> python -m homeassistant --script check_config -c /config
# 3) 重启
docker restart <容器名>
```

重启后去「开发者工具 → 模板」核对实体 id（见本节开头的 6 个 id），不一致就全局替换。

两个和 Docker 相关的注意点：

- **网络模式**。ESPHome 设备靠 mDNS 自动发现，需要容器用 `network_mode: host`（OpenWrt 上跑 HA 基本都是这么配的）。**如果是 bridge 模式，别指望自动发现**——直接在 HA 里手动添加 ESPHome 集成，地址填 `YOUR_DEVICE_IP`（设备当前 DHCP 地址，见 3.8）。
- **固定 IP**。设备现在拿的是 DHCP `YOUR_DEVICE_IP`，重启路由器可能变。建议在 OpenWrt 的 DHCP 里给它绑定静态租约，否则 HA 里那条集成会时好时坏。ESPHome 侧也可以写死 `manual_ip`，但绑在路由器上更省事。

### 5.5 落地实录（2026-11-10 已完成）

实测环境：HA **2026.10.2**，容器名 `homeassistant`，`network_mode: host`，配置目录
**`/Lager/data/homeassistant`**（宿主机路径，容器内是 `/config`）。SSH `root@YOUR_HA_HOST` 用
`~/.ssh/openwrt_key` 直接登（ImmortalWrt 25.12-SNAPSHOT / x86_64）。

**做完的四件事：**

| 项目 | 结果 |
|---|---|
| ESPHome 集成 | 已添加，标题 `Desk`，host `YOUR_DEVICE_IP:6053` + noise_psk |
| package | `/config/packages/desk.yaml` + `configuration.yaml` 里插了 `homeassistant: packages:`（备份 `configuration.yaml.bak-desk-*`） |
| 静态租约 | `dhcp.@host[2]`：`AC:27:6E:5D:E5:20` → `YOUR_DEVICE_IP`（主机名 `desk-c3`） |
| 端到端 | `script.desk_goto 860` → 实测到 **859**（1mm 死区，与协议结论一致）→ cover 3% → 回 851 |

**实体 id 坑（必看）**：ESPHome 设备名是 `Desk`，而实体名里又写了 `Desk Height`，
于是自动派生成 **`sensor.desk_desk_height`**（双重前缀）。完整列表：

```
sensor.desk_desk_height         number.desk_target_height
button.desk_apply_target        button.desk_step_up / button.desk_step_down
button.desk_sit (记忆1)          button.desk_stand (记忆4)
button.desk_go_preset_2/3       button.desk_emergency_stop
binary_sensor.desk_desk_moving  sensor.desk_soft_min / sensor.desk_soft_max
sensor.desk_preset_1..4
```

`homeassistant/desk.yaml` 已按上表全部对齐（含 `person.you`），改完 `check_config`
返回 valid，重启后新实体一次到位：`cover.desk` / `binary_sensor.desk_sitting` /
`binary_sensor.desk_standing` / `sensor.desk_standing_today` + 4 条自动化（实体 id 是
中文别名 slug，如 `automation.sheng_jiang_zhuo_jiu_zuo_ti_xing`，按 `id:` 字段辨认更稳）。

**下次要程序化改 HA 时可以复用的一条路径**（无 UI 也能加集成）：

- 长期令牌的明文不落盘（`.storage/auth` 里只有 `jwt_key` + `token` 随机串），
  但可以现场签一个：`jwt.encode({"iss": <refresh_token.id>, "iat": now,
  "exp": now+1800}, <jwt_key>, algorithm="HS256")` —— HS256，`iss` 必须是令牌 id 而不是 "home-assistant"。
- 2026.10 起 config flow **不再走 WS**（`config_entries/flow` 会回 `unknown_command`），
  改成 REST：`POST /api/config/config_entries/flow` `{"handler":"esphome"}`，再
  `POST /api/config/config_entries/flow/{flow_id}` 提交。ESPHome 的第二步字段名是
  **`noise_psk`**（不是 `password`），传错直接 400。
- 校验 / 重启：`POST /api/config/core/check_config`、`POST /api/services/homeassistant/restart`。

**还没做**：HomeKit 桥（需要 iPhone 扫码，界面加 HomeKit Bridge 选 `cover.desk` 即可）；
硬件上补 100Ω 串阻并拆掉 CH340 的 TX。

### 5.6 静默化：撤掉轮询之后暴露的两个坑（2026-11-10 晚）

**起因**：手控器屏幕一直亮着。原因是固件每 900 ms 发一帧 `0x07` 请求设置 —— 手控器和
控制盒挂在同一条总线上，屏幕上的高度就是这条总线送来的，所以**总线上任何一帧都会
唤醒屏幕**，900 ms 的节奏正好一直给它的待机计时器续命。

**改法（当前固件）**：零后台流量。空闲时一帧不发；手控器动桌子时它和盒子之间的报文
照样从 RX 收到，直接解析；只在一次运动结束后补发一帧对齐静态信息；开机最多一次
（`substitutions.boot_sync` / `post_motion_sync` 都能单独关）。

改完立刻暴露了第二个坑 —— **"安静之后的头一帧会丢"**（这个现象我们早在 PC 端就记过，
只是被轮询掩盖了）：

| 现象 | 证据 |
|---|---|
| 空闲几分钟后按单步，第 1 次毫无反应 | 1079 → 1079 → 1090 → 1101（第 2、3 次才动） |
| 定点帧被收成残帧，桌子朝错误目标跑 | 目标 1120，实际从 1129 一路降到 1079 才停（50 mm 过冲） |

**修法**：每次真正下命令前先发一帧 `0x07` 当"热身"，70 ms 后再发真命令。
`0x07` 只读不动作，最坏情况是什么都不发生；对定点指令额外补发一次（同目标幂等），
把残帧概率压到最低；**单步指令绝不重发**，否则行程翻倍。

实测（`Rx Frames` 计数是诊断实体，空闲时必须不动）：

```
空闲 20s      frames 20 → 20        ✓ 零流量
空闲后单发单步 1101 → 1111          ✓ 第一帧不再丢
goto 1050     实测 1051，停稳后补抓校正为 1050   ✓ 无过冲
再空闲 15s    frames 67 → 67        ✓ 回到静默
```

### 5.7 改名「书桌」+ 归入书房（2026-11-10 晚）

书房区域本来就存在（`area_id = shu_fang`），设备那时叫 `Desk`、不属于任何区域。全部通过注册表接口改，**没有重刷固件**：

```python
# 设备：改名 + 归区
{"type": "config/device_registry/update", "device_id": "...",
 "name_by_user": "书桌", "area_id": "shu_fang"}
# 实体：只改显示名，entity_id 保持不变
{"type": "config/entity_registry/update", "entity_id": "sensor.desk_desk_height", "name": "高度"}
```

命名策略：24 个 ESPHome 实体的 `has_entity_name = True`，显示名 = **设备名 + 实体名**，所以实体只写后缀（`高度` / `上升一步` / `急停`），UI 里自然变成「书桌 · 高度」。没绑设备的 4 个模板实体（`cover.desk`、坐/站判定、今日站立）写全名并单独挂 `area_id`。

**这里有个必须知道的坑**：`has_entity_name = True` 的实体，`entity_id` 是按「设备名 + 实体名」自动生成的；把设备名从 `Desk` 改成中文后，HA **有可能重算 `entity_id`**，一旦改了就变成 `sensor.shu_zhuo_*` 之类，package 里所有引用同时失效。所以改之前先备份：

```sh
cp .storage/core.entity_registry{,.bak-desk}
cp .storage/core.device_registry{,.bak-desk}
```

改完立刻比对前后 `entity_id` 集合（本次 29 个实体漂移数为 0）。真飘了就在同一次 `entity_registry/update` 里带 `new_entity_id` 钉回原值。

另外两条：脚本用键名写法（`script: desk_goto:`）时，`alias` 可以随便改而 `entity_id` 不变；自动化的 `entity_id` 由 `alias` 的拼音 slug 生成（现在是 `automation.sheng_jiang_zhuo_*`，已经和「书桌」对不上，但被 `id:` 钉住了所以稳定，不影响功能）。

### 5.8 cover 卡片的三个坑（2026-11-10 深夜）

前端把升降桌当成 cover 后连踩三下，都是「数据没说错、语义说错了」：

| 现象 | 原因 | 修法 |
|---|---|---|
| 标题/按钮提示写着「窗帘」，上下箭头提示「打开窗帘」 | `template.cover` 上设了 `device_class: shutter`，前端按窗帘那套翻译 | **删掉 device_class**，改给 `icon: mdi:desk`，前端当普通 cover 处理 |
| 按上键报「1130 超出 851-1129 有效范围」，按下键报「850 …」 | `open/close` 直接拿 `sensor.desk_soft_max/min`（1130/850）当目标，而 `number` 实体有效区间是 851–1129（1mm 死区） | 端点各内缩 1mm：`soft_max - 1` / `soft_min + 1`；并在 `script.desk_goto` 里统一夹取，任何入口都不会再越界 |
| 滑条左边是高、右边是低 | 同上，`device_class` 让前端把位置按「开启度」反过来画 | 0% 锁死 = 851（坐），100% = 1129（站）；去掉 device_class 后前端按 0 在左绘制 |

`script.desk_goto` 的夹取模板（所有运动入口的唯一收敛点）：

```jinja
{% set lo = states('sensor.desk_soft_min') | float(850) + 1 %}
{% set hi = states('sensor.desk_soft_max') | float(1130) - 1 %}
{{ [[height | int(0), lo | int] | max, hi | int] | min }}
```

卡片侧另外两条经验：

1. `tile` 的 `cover-open-close` feature 按钮文案由前端按 cover 语义生成，改不了中文措辞；想要「上升/停止/下降」就自己放三张 tile，`tap_action` 里 `perform_action` 调 `cover.open_cover` / `cover.stop_cover` / `cover.close_cover`，`name` 随便写。
2. `state_content: ["current_position"]` 可以让 tile 只显示百分比，避免出现「已打开」这种对桌子没意义的词。

---

### 5.9 自写竖向滑条卡片 `desk-vertical-slider`（2026-11-10 深夜）

**为什么不用现成的**：HA 内置的 `cover` / `tile` 只有横向滑条，没有「竖条」这个控件；HACS 上几个竖向 cover 卡片基本停在 2021 年前后，对 2026.10 前端未必兼容，更关键的是它们无法控制**发帧时机**——而我们的手控器屏幕会被总线上任何一帧点亮（见 5.6）。

所以写了一个不依赖任何插件的单文件卡片：`/config/www/desk-vertical-slider.js`（约 410 行，`customElements.define("desk-vertical-slider")`）。

**结构**

```
┌─────────┬──────────────────┐
│         │   975 mm         │  ← 当前高度，直接读 sensor
│  竖条   │   851 – 1129 mm  │  ← 运动中时显示「运动中」
│ （填充  ├──────────────────┤
│   +手柄）│       ▲          │  ← 单步 / 长按连续
│         ├──────────────────┤
│         │       ■          │  ← 急停
│         ├──────────────────┤
│         │       ▼          │  ← 单步 / 长按连续
└─────────┴──────────────────┘
```

**三条设计约束（都来自实测）**

| 约束 | 实现 |
|---|---|
| 拖动不能发帧，否则手控器屏幕被持续点亮 | `pointermove` 只更新本地预览和文案「松手移动到 xxx mm」，`pointerup` 才发**一帧** `script.desk_goto` |
| 单步（0x01/0x02）是自停的 10–12mm，重发会叠行程 | 按下立即发一次；按住 700ms 后才开始每 2s 补一步，上限 12 步 |
| 连发可能让控制盒进入连续运行 | 已发 ≥3 步时松手，自动补一次 `button.desk_emergency_stop` 兜底 |

**实测数据**（无头 Edge + 合成 PointerEvent，不依赖真实 HA）

```
geometry        track 300px, fill 26.8%, knob 72.9%, 三键各 71px
drag → 顶       拖动中调用 0 次 → 松手 script.desk_goto {"height":1129}
drag → 底       拖动中调用 0 次 → 松手 script.desk_goto {"height":851}
drag → 中       拖动中调用 0 次 → 松手 script.desk_goto {"height":990}
长按 7.1s       上升 4 次 → 松手自动补 desk_emergency_stop
紧凑版 230px    三键各 48px，不溢出
```

**踩到的两个前端坑**

1. `setPointerCapture` 在合成事件上会抛 `InvalidPointerId`，必须 `try/catch`，否则拖动直接崩。
2. 不要用 `justify-content: space-between` 排版侧栏——按钮会堆在底部、中间留一大块空。正确做法是 `.pad { flex: 1 }` + `button { flex: 1 1 0; min-height: 36px }`，让三个键平分剩余高度，像真的升降桌面板；`min-height` 必须留够，否则 `track_height` 调小时按钮会被压到溢出卡片。

**部署方式**（新增卡片都要走这两步）

```bash
# 1. 文件放到 /config/www/（容器里就是 /local/）
cp desk-vertical-slider.js /Lager/data/homeassistant/www/

# 2. 注册资源（改文件后要改 ?v= 版本号，否则浏览器吃缓存）
#    WS: lovelace/resources/create  → {res_type:"module", url:"/local/xxx.js?v=1"}
#    WS: lovelace/resources/update  → resource_id + 新 url
```

卡片参数：

```yaml
type: custom:desk-vertical-slider
entity: cover.desk          # 可选，其余实体都从这一套默认值来
track_height: 300           # 竖条高度，概览里用的 230
hold_delay: 700             # 长按多久开始连发
repeat_every: 2000          # 连发间隔（必须 > 单步自停时间）
repeat_max: 12              # 连发上限
```

---

## 六、米家：已排除（决策记录）

**结论：不做。主线和唯一入口都是 HA，语音走 HomeKit。**

理由都是查证过的，不是偏好：

1. 小米官方的 Xiaomi Home 集成是**单向**的——只把米家设备拉进 HA，不能把 DIY 设备推进米家。个人拿不到米家开放平台资质，所以只剩 **Matter 一条路**。
2. 走 Matter 必须**已有小米中枢网关**。设备在米家里会被归类成「窗帘」（Matter 设备类型里没有升降桌），小爱播报是"正在打开窗帘"；跨品牌 Matter 设备通常只能当执行端，**不能当自动化触发条件**。
3. 你的智能逻辑（久坐计时、日历、站立统计、离家归位）本来就必须放在 HA——米家只看到一个百分比，做不了"读桌面高度"这种判断。既然决策中枢必然是 HA，把"嘴"也接在 HA 上最短。
4. 多一跳（HA → Matter Bridge → 中枢网关 → 米家 → 小爱）换来的唯一收益，是"能在米家 App 里看到一个叫窗帘的桌子"。

**如果以后确实想让小爱控制**（例如客厅已有小米音箱、不想为桌子再添 HomePod）：

| 前提 | 做法 | 成本 | 代价 |
|---|---|---|---|
| 已有小米中枢网关 | HA 装 Matter Hub 附加组件 → 把 `cover.desk` 加进去 → 米家 App 手动选「Matter 设备」扫码 | 1-2 小时 | 仍是"窗帘"语义；配网成功率一般 |
| 没有网关 | 巴法云把 HA 实体同步成米家里的虚设备 | 10 分钟，免费 | 依赖公网、延迟 1-3 s、稳定性差，只适合偶尔语音升一下 |

这两条都属于可选彩蛋，随时可以后加，不影响主线。

## 七、场景怎么落

| 场景 | 实现 | 关键点 |
|---|---|---|
| 久坐提醒 | `binary_sensor.desk_sitting` 的 `for: 00:45:00` | 桌子一升起来触发器自动复位，不用手动清计时器 |
| 久站提醒 | 同上，`desk_standing` + 1 小时 | |
| 番茄节奏 | script：站 25 min → 坐 5 min 循环 | 用 `delay` + `button.press` |
| 会议前自动站 | `calendar` 触发器，`offset: -00:01:00` | 加条件"当前是坐姿"，否则开会时来回动 |
| 站立时长统计 | `history_stats`，`binary_sensor.desk_standing` 的 on 时长 | |
| 下班/离家归位 | `person` 离开 10 分钟 → 按 `button.sit` | **别用"到家"触发升高**，会吓人 |
| 扫地机联动 | 扫地机启动 → 升到最高 | 反过来更好用：清空桌下 |
| 童锁 | 手控器上按，或发 `1F 01 01`（注意是 toggle 不是设值） | |

久坐计时想更准，再加一层"人在电脑前"的判断（HASS.Agent / 蓝牙信标 / 人体传感器），否则你出去开会那 45 分钟也会被算成久坐。

---

## 八、实施台阶（每步都有验收标准）

### Step 0 量电压（已测，只剩一次复测）
已实测 pin5 = 3.3 V，走 100 Ω 直连。**接 ESP32 前拔掉 CH340 的 TX 再量一次**：仍是 3.3 V 就按 3.4 节接；跳到 5 V 就改 3.3 节。

### Step 1 准备 ESPHome（20 分钟）
两条路，按你的 HA 安装方式选：

**A. HA 附加组件（推荐，HA OS / Supervised 才有）**
1. 设置 → 附加组件 → 商店 → 搜 **ESPHome Device Builder** → 安装 → 打开 Web UI；
2. 新建设备，把 `esphome/desk-c3.yaml` 和 `esphome/desk_proto.h` 两个文件放进同一目录；
3. 在该附加组件的 Secrets 里补四项：

```yaml
desk_api_key: "32位随机十六进制串"
desk_ota_password: "自己定一个"
wifi_ssid: "YOUR_5G_SSID"
wifi_password: "你的密码"
```

**B. PC 上跑 CLI**（HA 是纯 Docker / Core 版时）

```bash
pip install esphome -i https://mirrors.aliyun.com/pypi/simple
esphome run desk-c3.yaml
```

首次编译要下 platformio 工具链（约 5-10 分钟）。这个镜像源在本机实测可用（`pypi.tuna.tsinghua.edu.cn` 反而连不上）。

板子用 USB-C 直接插电脑即可烧录，**不需要 CH340**（C3 自带 USB-Serial-JTAG）。刷写时注意 4.5 节那两个坑：**要加 `--no-stub`，烧完用 `--after watchdog-reset` 才能退出下载模式。**

> 板子里现在装的是验证链路用的 MicroPython，刷 ESPHome 会直接覆盖掉，不用特意清理。

### Step 2 只读上线 —— ✅ 已完成（2026-11-10）
硬件链路已通（3.7），ESPHome 固件已刷入并在线（4.6），`Desk Height` 等实体数值全部正确。

接法：**GND + pin3→IO20**，pin5 可以一起接上（已验证安全）。

✅ 验收：HA 出现 `sensor.desk_height`；按手控器，数值 1 秒内跟上，误差 ≤1 mm；静止时不跳变。

一直 `unavailable` 的话，按顺序查：USB 日志（`logger: hardware_uart: USB_SERIAL_JTAG`，走 USB-C 口的 `esphome logs`）→ 电阻/接线 → GND 是否共地 → pin3 是否真的接在 IO20（**这两根最容易接反：盒子 TX 必须进 IO20，不是 IO21**）。

### Step 3 打通发送 —— ✅ 已完成（2026-11-10）
接线：`IO21 → pin5`（当前直连无电阻，建议补一只 100 Ω，见 3.4）。

✅ 验收已过：经 API 按 `Step Up` 851→862→873、按 `Step Down` →865→857→851，
每步都是一次约 10-12 mm 后自停。

### Step 4 HA 落地（40 分钟）
放 package → 检查配置 → 重启 → 按 `desk.yaml` 头部的模板核对实体 id。

✅ 验收：`cover.desk` 滑杆 0-100%；拖到 70% → 桌子走到约 1045 mm；「打开」到 1129，「关闭」到 851。

### Step 5 语音（30 分钟）
HomeKit Bridge 配好并配对（`homeassistant/desk.yaml` 末尾给了界面 / YAML 两种方式，二选一别混用）。

✅ 验收：对手表说「把升降桌开到 70%」→ 走到约 1045 mm。

### Step 6 场景（持续迭代）
先只开「久坐提醒」+「运动超时急停」，跑一周看误报率，再开日历和离家。

⚠️ 日历 / 离家两条默认引用了 `calendar.your_calendar` 和 `person.you`，**不改自己的实体会一直报错**，没准备好就先禁用这两条自动化。

## 九、这一步的 BOM

| 件 | 规格 | 数量 | 价格 |
|---|---|---|---|
| ESP32-C3 Super Mini | 已有 | 1 | — |
| 电阻 100 Ω | 1/4 W，串联限流 | 1 | 0.1 元 |
| BAT54S 钳位二极管 | SOT-23，保护 IO21 | 1 | 1 元 |
| （备）BSS138 模块 | 4 通道；仅当复测为 5 V 才需要 | 0-1 | 3 元 |
| 电阻 | 10 kΩ、20 kΩ（分压）各 1 | 2 | 0.5 元 |
| 电容 | 100 µF 电解 + 100 nF 陶瓷 | 2 | 1 元 |
| RJ11 6P6C 转接板 | 已有 | 1 | — |
| USB 5V 电源 | 手机充电头 | 1 | 已有 |
| 外壳 / 洞洞板 | | 1 | 10 元 |

合计约 **12 元**（不含已有的板子和转接板）。若复测为 5 V 逻辑，再加一块 3 元的 BSS138 模块。

---

## 十、风险清单

1. **天线是这块板最弱的一环。** 桌下金属多、电机干扰大，掉线优先怀疑这里，别先去怀疑协议。
2. **IO4-IO7 有 flash 职责。** 别因为"网上都这么接"就换过去，出现上电不启动会极难查。
3. **IO8 复位必须为高。** 拿它点灯会让板子偶尔进不了下载模式。
4. **哪天改回 5 V 逻辑，别用单管开漏。** 那是反相电路，现象是"完全没反应"，跟协议不通一模一样。本机 3.3 V 直连不涉及这个坑。
5. **两个 TX 不能并在一起。** 接 ESP32 前必须断开 CH340 的 TX。
6. **移动时不要轮询。** 轮询会让桌子变成"每 400 ms 走 10 mm"的龟速，很多人会误判成电机没劲。
7. **`0x7E` 不转义。** 任何"扫终止符"的实现都会在特定高度丢帧，且换个高度就好——极其难查。
8. **端点有 1 mm 死区。** 软下限 850 实际停 851、上限 1130 停 1129。写自动化时留 ±2 mm 容差，否则"是否到位"永远判 false。
9. **记忆位不跟随限位。** 改了软上下限，记忆位还是旧值，要重跑 `desk-presets.ps1 -Action apply`。
10. **别指望米家能当自动化触发条件。** 跨品牌 Matter 设备在米家通常是只读执行端。
11. **ESP32 掉了不影响用桌子。** 手控器永远优先、且是物理独立的一路，这是这套方案最让人放心的地方。
12. **`09` / `0A` 固件差异。** 本机是 `0A`，行为已验证。如果你换了控制盒，先跑一遍 `desk.ps1 -Cmd status` 复核，别假设命令集一样。

---

## 十一、照做清单与故障对照

### 11.1 开工前

- [ ] 量过 pin5、pin3 对 pin2 的空载电压（决定 TX 方案）
- [ ] 拔掉 CH340 的 TX（逻辑分析仪可留，高阻无妨）
- [ ] 准备独立 USB 5V（**不要**从 RJ11 pin4 取电）
- [ ] 拔掉 CH340 的 TX 后复测 pin5（仍为 3.3 V 才走直连）
- [ ] 100 Ω 电阻 + BAT54S 到手（BSS138 仅复测为 5 V 时才买）
- [ ] ESPHome 能编译（附加组件装好，或 PC CLI 跑通 `esphome version`）

### 11.2 故障对照表

| 现象 | 最可能原因 | 处理 |
|---|---|---|
| 实体一直 `unavailable` | 分压接反 / 没共地 | 量 IO20 空闲是否 3.3 V；确认 pin2 与 USB 电源 GND 相通 |
| 有应答但高度不更新 | `0x07` 打断了运动 | 看日志是否在运动期间仍发 `07`；3 s 抑制窗口是否生效 |
| 发命令完全没反应 | 两个 TX 打架 / 极性接反 | 确认 CH340 TX 已拔；量 pin5 空闲是否 5 V（是则需非反相电平转换） |
| 换某些高度就丢帧 | 用了"扫 `0x7E` 断帧"的实现 | 必须按 LEN 分帧再验 CHK（固件已做） |
| 到 851 / 1129 就停 | 软限位，不是故障 | 端点有 1 mm 死区，自动化留 ±2 mm 容差 |
| `cover.desk` 状态不跟随 | 实体 id 对不上 | 用 `desk.yaml` 头部的模板查真实 id，全局替换 |
| Wi-Fi 频繁掉线 | 陶瓷天线 + 桌下金属 | 移出金属横梁、天线端朝外；必要时焊 31 mm 漆包线 |
| 连续两条命令，第二条无效 | 命令落在"刚停稳"死区 | 固件 3 s 抑制已覆盖；自定义脚本里加 `delay: 1s` |

### 11.3 完工后要固化下来的三件事

1. `esphome/` 与 `homeassistant/` 两个目录进 git（`secrets.yaml` 不入库）；
2. 记下这台盒子的固件版本（`1C` → `0A`）和实测端点（851 / 1129）——换控制盒或改软限位时，先跑 `desk.ps1 -Cmd status` 复核，别假设命令集一样；
3. 手控器永远保留。它是物理独立的一路，ESP32 死机、HA 重启都不影响——这也是"改坏了也能还原"的底气。
