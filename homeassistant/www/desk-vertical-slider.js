/**
 * desk-vertical-slider  —  捷昌升降桌专用竖向滑条卡片
 *
 * 为什么自己写：
 *   HA 内置 cover / tile 只有横向滑条，且带窗帘语义（device_class: shutter）。
 *   HACS 上的竖向 cover 卡片多数停在 2021 年，且无法控制发帧时机。
 *
 * 设计约束（来自控制盒实测）：
 *   - 手控器和控制盒同总线，**任何一帧都会点亮手控器屏幕**。
 *     所以拖动过程中只更新本地预览，松手才发一帧；绝不在 pointermove 里发命令。
 *   - 单步（0x01/0x02）是自停的，约 10–12 mm。重复发送会让行程叠加，
 *     因此长按只在 700 ms 后才补一步、间隔 2 s、最多 12 步，并在长按多步后松手时补一次急停兜底。
 *   - 所有运动统一走 script.desk_goto（它内部做了 851–1129 夹取）。
 *
 * 用法：
 *   type: custom:desk-vertical-slider
 *   entity: cover.desk
 *   track_height: 280
 */

const clampNum = (v, a, b) => Math.min(b, Math.max(a, v));

const CSS = `
  :host { display: block; }
  ha-card { padding: 14px; }
  .wrap {
    display: flex; gap: 14px; align-items: stretch;
    height: var(--track-h, 280px);
  }
  .track {
    position: relative; flex: 0 0 62px; width: 62px; height: 100%;
    border-radius: 31px; cursor: pointer; touch-action: none;
    background: var(--secondary-background-color, rgba(127,127,127,.14));
    border: 1px solid var(--divider-color, rgba(127,127,127,.22));
    overflow: hidden; box-sizing: border-box;
  }
  .fill {
    position: absolute; left: 0; right: 0; bottom: 0; height: 0;
    background: var(--primary-color, #03a9f4);
    opacity: .40;
    transition: height .18s ease-out;
  }
  .knob {
    position: absolute; left: 4px; right: 4px; height: 26px;
    bottom: 0; margin-bottom: -13px;
    border-radius: 9px;
    background: var(--card-background-color, #fff);
    border: 1px solid var(--divider-color, rgba(127,127,127,.32));
    box-shadow: 0 1px 5px rgba(0,0,0,.22);
    pointer-events: none; box-sizing: border-box;
    transition: bottom .18s ease-out;
  }
  .knob::after {
    content: ""; position: absolute; left: 50%; top: 50%;
    width: 22px; height: 2px; margin: -1px 0 0 -11px; border-radius: 2px;
    background: var(--secondary-text-color, #888); opacity: .55;
  }
  .side {
    flex: 1 1 auto; min-width: 0;
    display: flex; flex-direction: column;
  }
  .value {
    font-size: 34px; font-weight: 600; line-height: 1;
    letter-spacing: -.5px;
    color: var(--primary-text-color, #222);
  }
  .value small {
    font-size: 13px; font-weight: 500; margin-left: 4px;
    color: var(--secondary-text-color, #888); letter-spacing: 0;
  }
  .sub {
    font-size: 12px; margin-top: 7px; line-height: 1.4;
    color: var(--secondary-text-color, #888);
  }
  .pad {
    display: flex; flex-direction: column; gap: 8px;
    flex: 1 1 auto; margin-top: 12px; min-height: 0;
  }
  button {
    appearance: none; border: none; margin: 0; padding: 0;
    border-radius: 12px; flex: 1 1 0; min-height: 36px; height: auto;
    display: flex; align-items: center; justify-content: center;
    background: var(--secondary-background-color, rgba(127,127,127,.14));
    color: var(--primary-text-color, #222);
    cursor: pointer; touch-action: none;
    -webkit-user-select: none; user-select: none;
    -webkit-tap-highlight-color: transparent;
    transition: background .12s ease, transform .08s ease;
  }
  button:hover { background: var(--divider-color, rgba(127,127,127,.26)); }
  button.pressed, button:active {
    background: var(--primary-color, #03a9f4);
    color: var(--text-primary-color, #fff);
    transform: scale(.97);
  }
  button ha-icon { --mdc-icon-size: 26px; }
  button.pressed ha-icon, button:active ha-icon { color: var(--text-primary-color, #fff); }
  button.danger.pressed, button.danger:active { background: var(--error-color, #db4437); }
  .dead { opacity: .45; pointer-events: none; }
`;

class DeskVerticalSlider extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: "open" });
    this._config = null;
    this._hass = null;
    this._mounted = false;
    this._drag = false;
    this._preview = null;
    this._holdTimer = null;
    this._repTimer = null;
    this._repeatCount = 0;
    this._globalUp = null;
  }

  setConfig(config) {
    this._config = Object.assign(
      {
        entity: "cover.desk",
        height_entity: "sensor.desk_desk_height",
        min_entity: "sensor.desk_soft_min",
        max_entity: "sensor.desk_soft_max",
        moving_entity: "binary_sensor.desk_desk_moving",
        script: "script.desk_goto",
        step_up_entity: "button.desk_step_up",
        step_down_entity: "button.desk_step_down",
        stop_entity: "button.desk_emergency_stop",
        track_height: 280,
        hold_delay: 700,
        repeat_every: 2000,
        repeat_max: 12,
      },
      config || {}
    );
    if (this.isConnected) this._mount();
  }

  set hass(hass) {
    this._hass = hass;
    if (!this._mounted && this._config) this._mount();
    this._update();
  }

  get hass() {
    return this._hass;
  }

  getCardSize() {
    return 6;
  }

  static getStubConfig() {
    return { entity: "cover.desk", track_height: 280 };
  }

  disconnectedCallback() {
    this._clearTimers();
    if (this._globalUp) {
      window.removeEventListener("pointerup", this._globalUp);
      this._globalUp = null;
    }
    this._mounted = false;
  }

  // ---------------------------------------------------------------- mount
  _mount() {
    if (!this._config) return;
    this.shadowRoot.innerHTML = `
      <style>${CSS}</style>
      <ha-card>
        <div class="wrap">
          <div class="track" id="track">
            <div class="fill" id="fill"></div>
            <div class="knob" id="knob"></div>
          </div>
          <div class="side">
            <div class="head">
              <div class="value"><span id="val">--</span><small>mm</small></div>
              <div class="sub" id="sub"></div>
            </div>
            <div class="pad">
              <button id="up" aria-label="上升"></button>
              <button id="stop" class="danger" aria-label="急停"></button>
              <button id="down" aria-label="下降"></button>
            </div>
          </div>
        </div>
      </ha-card>`;

    const r = this.shadowRoot;
    const card = r.querySelector("ha-card");
    card.style.setProperty("--track-h", (this._config.track_height || 280) + "px");

    r.getElementById("up").innerHTML = '<ha-icon icon="mdi:arrow-up-bold"></ha-icon>';
    r.getElementById("down").innerHTML = '<ha-icon icon="mdi:arrow-down-bold"></ha-icon>';
    r.getElementById("stop").innerHTML = '<ha-icon icon="mdi:stop"></ha-icon>';

    this._bindTrack();
    this._bindStep("up", this._config.step_up_entity, +1);
    this._bindStep("down", this._config.step_down_entity, -1);
    this._bindStop();

    this._mounted = true;
    this._update();
  }

  // --------------------------------------------------------------- helpers
  _range() {
    const num = (id, fb) => {
      const s = this._hass && this._hass.states[id];
      if (!s) return fb;
      const v = parseFloat(s.state);
      return Number.isFinite(v) ? v : fb;
    };
    // 软限位 850 / 1130，实测端点各内缩 1 mm（控制盒死区）
    const lo = Math.round(num(this._config.min_entity, 850)) + 1;
    const hi = Math.round(num(this._config.max_entity, 1130)) - 1;
    return { min: lo, max: Math.max(hi, lo + 1) };
  }

  _height() {
    const s = this._hass && this._hass.states[this._config.height_entity];
    if (!s) return NaN;
    const v = parseFloat(s.state);
    return Number.isFinite(v) ? v : NaN;
  }

  _call(domain, service, data) {
    if (!this._hass) return;
    this._hass.callService(domain, service, data || {});
  }

  _goto(h) {
    const target = Math.round(h);
    const cur = this._height();
    if (Number.isFinite(cur) && Math.abs(cur - target) < 1) return; // 同高度不发帧
    const parts = String(this._config.script).split(".");
    const domain = parts[0] || "script";
    const service = parts[1] || "desk_goto";
    this._call(domain, service, { height: target });
  }

  _press(ent) {
    if (!ent) return;
    this._call("button", "press", { entity_id: ent });
  }

  _clearTimers() {
    if (this._holdTimer) clearTimeout(this._holdTimer);
    if (this._repTimer) clearInterval(this._repTimer);
    this._holdTimer = null;
    this._repTimer = null;
  }

  // ----------------------------------------------------------------- paint
  _paint(h, dragging) {
    const r = this.shadowRoot;
    const fill = r.getElementById("fill");
    const knob = r.getElementById("knob");
    const val = r.getElementById("val");
    const sub = r.getElementById("sub");
    if (!fill || !val) return;

    const { min, max } = this._range();
    fill.style.transition = dragging ? "none" : "";
    knob.style.transition = dragging ? "none" : "";

    if (!Number.isFinite(h)) {
      val.textContent = "--";
      fill.style.height = "0%";
      knob.style.bottom = "0%";
      sub.textContent = "实体不可用";
      return;
    }

    const ratio = clampNum((h - min) / (max - min), 0, 1);
    const pct = (ratio * 100).toFixed(2) + "%";
    fill.style.height = pct;
    knob.style.bottom = pct;
    val.textContent = String(Math.round(h));

    if (dragging) {
      sub.textContent = "松手移动到 " + Math.round(h) + " mm";
    } else {
      const mv = this._hass && this._hass.states[this._config.moving_entity];
      sub.textContent = mv && mv.state === "on" ? "运动中" : min + " – " + max + " mm";
    }
  }

  _update() {
    if (!this._mounted || !this._hass) return;
    if (!this._drag) this._paint(this._height(), false);
    const r = this.shadowRoot;
    const card = r.querySelector("ha-card");
    const s = this._hass.states[this._config.entity];
    const dead = !s || s.state === "unavailable";
    if (card) card.classList.toggle("dead", dead);
  }

  // ------------------------------------------------------------ track drag
  _bindTrack() {
    const track = this.shadowRoot.getElementById("track");
    if (!track) return;

    const at = (ev) => {
      const rect = track.getBoundingClientRect();
      const ratio = clampNum(1 - (ev.clientY - rect.top) / rect.height, 0, 1);
      const { min, max } = this._range();
      return Math.round(min + ratio * (max - min));
    };

    track.addEventListener("pointerdown", (ev) => {
      ev.preventDefault();
      this._drag = true;
      try { track.setPointerCapture(ev.pointerId); } catch (e) { /* ignore */ }
      this._preview = at(ev);
      this._paint(this._preview, true);
    });

    track.addEventListener("pointermove", (ev) => {
      if (!this._drag) return;
      ev.preventDefault();
      this._preview = at(ev);
      this._paint(this._preview, true);
    });

    const end = () => {
      if (!this._drag) return;
      this._drag = false;
      const h = this._preview;
      this._preview = null;
      if (Number.isFinite(h)) this._goto(h);
      this._paint(this._height(), false);
    };

    track.addEventListener("pointerup", end);
    track.addEventListener("pointercancel", end);
  }

  // ---------------------------------------------------------- step buttons
  _bindStep(btnId, entity, dir) {
    const btn = this.shadowRoot.getElementById(btnId);
    if (!btn || !entity) return;

    const down = (ev) => {
      ev.preventDefault();
      // 指针捕获：松手一定回到本按钮，不依赖 window 兜底
      try { btn.setPointerCapture(ev.pointerId); } catch (e) { /* ignore */ }
      btn.classList.add("pressed");
      this._press(entity);
      this._repeatCount = 1;
      this._clearTimers();

      this._holdTimer = setTimeout(() => {
        this._repTimer = setInterval(() => {
          if (this._repeatCount >= this._config.repeat_max) {
            this._clearTimers();
            return;
          }
          this._repeatCount++;
          this._press(entity);
        }, this._config.repeat_every);
      }, this._config.hold_delay);
    };

    const up = () => {
      if (!btn.classList.contains("pressed")) return;
      btn.classList.remove("pressed");
      const fired = this._repeatCount;
      this._clearTimers();
      this._repeatCount = 0;
      // 长按连发多步后，控制盒可能进入连续运行 —— 补一次急停兜底
      if (fired >= 3) this._press(this._config.stop_entity);
    };

    btn.addEventListener("pointerdown", down);
    btn.addEventListener("pointerup", up);
    btn.addEventListener("pointercancel", up);
    btn.addEventListener("pointerleave", up);
    btn.addEventListener("contextmenu", (e) => e.preventDefault());
  }

  _bindStop() {
    const btn = this.shadowRoot.getElementById("stop");
    if (!btn) return;
    btn.addEventListener("pointerdown", (ev) => {
      ev.preventDefault();
      btn.classList.add("pressed");
      this._clearTimers();
      this._press(this._config.stop_entity);
    });
    const up = () => btn.classList.remove("pressed");
    btn.addEventListener("pointerup", up);
    btn.addEventListener("pointercancel", up);
    btn.addEventListener("pointerleave", up);
    btn.addEventListener("contextmenu", (e) => e.preventDefault());
  }
}

if (!customElements.get("desk-vertical-slider")) {
  customElements.define("desk-vertical-slider", DeskVerticalSlider);
}

window.customCards = window.customCards || [];
if (!window.customCards.some((c) => c.type === "desk-vertical-slider")) {
  window.customCards.push({
    type: "desk-vertical-slider",
    name: "书桌竖向滑条",
    description: "竖向拖动设定高度（松手才执行），上下按钮单步 / 长按连续升降。",
  });
}
