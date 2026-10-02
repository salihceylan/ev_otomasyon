// Sanal saatli "pano" test donanimi: ConfigManager + Automation (+ ek modul donanim modeli) + bagimsiz fiziksel gozlemci.
// Gercek zamanlayici YOKTUR: run(ms) ana donguyu 10 ms adimlarla surer (firmware testlerindeki Sim ile ayni yaklasim).
import { Automation, makeCommand, CmdSource } from '../sim/fw/automation.js';
import { ConfigManager, NvsImage } from '../sim/fw/config_manager.js';
import { PhysicalObserver } from '../sim/fw/observer.js';
import { CmdType } from '../sim/command_schema.js';

const u32 = (x) => x >>> 0;

export function makeExt(channels = 0) {
  return { present: channels > 0, address: 1, channels, coils: new Array(32).fill(false), rawDi: new Array(32).fill(false), failWrites: false };
}

export class Rig {
  /**
   * @param {object} [o]
   * @param {number} [o.t0]          baslangic millis() (tasma testi icin)
   * @param {number} [o.timeScale]
   * @param {NvsImage} [o.nvs]       ayni NVS ile yeniden baslatma testleri icin
   * @param {object} [o.ext]
   * @param {(cm:ConfigManager)=>void} [o.configure]
   * @param {boolean} [o.skipBootHold] baslangicta 500 ms bekleme penceresini gec
   */
  constructor({ t0 = 0, timeScale = 1, nvs = new NvsImage(null), ext = makeExt(0), configure = null, skipBootHold = true } = {}) {
    this.t = u32(t0);
    this.nvs = nvs;
    this.ext = ext;
    this.timeScale = timeScale;
    this.events = [];
    this.beeps = [];
    this.restarts = 0;
    this.preRestarts = 0;
    this.changed = 0;
    this.cm = new ConfigManager(nvs);
    this.cm.begin();
    if (configure) configure(this.cm);
    this.a = this.#makeAutomation();
    this.a.begin(this.t);
    this.observer = new PhysicalObserver();
    this.observer.boot(this.t);
    if (skipBootHold) this.run(500);
  }

  #makeAutomation() {
    return new Automation({
      config: this.cm,
      nvs: this.nvs,
      ext: this.ext,
      timeScale: this.timeScale,
      hooks: {
        event: (type, f) => this.events.push({ t: this.t, type, ...f }),
        beep: (ms, reason) => this.beeps.push({ t: this.t, ms, reason }),
        changed: () => { this.changed++; },
        preRestart: () => { this.preRestarts++; },
        restart: () => { this.restarts++; this.halted = true; },
      },
    });
  }

  /** Ayni NVS ile "elektrik gitti/geldi": yeni ConfigManager + Automation (RAM sifirlanir). */
  coldBoot({ keepTime = true } = {}) {
    if (!keepTime) this.t = 0;
    this.cm = new ConfigManager(this.nvs);
    this.cm.begin();
    this.halted = false;
    this.a = this.#makeAutomation();
    this.a.begin(this.t);
    this.observer.boot(this.t);
    this.run(10);   // ilk loop: anlik goruntu yayinlanir
    return this;
  }

  step(ms = 10) {
    this.t = u32(this.t + ms);
    if (this.halted) return;   // yeniden baslatma: cihaz kapali
    this.a.loop(this.t);
    const mask = PhysicalObserver.physicalMask(this.a, this.ext, this.cm.config.ext_module_enabled);
    this.observer.observe(this.t, mask, this.a.pairValid);
  }

  run(ms, stepMs = 10) {
    for (let done = 0; done < ms; done += stepMs) this.step(Math.min(stepMs, ms - done));
    return this;
  }

  runUntil(pred, maxMs = 60000, stepMs = 10) {
    for (let done = 0; done < maxMs; done += stepMs) {
      if (pred()) return true;
      this.step(stepMs);
    }
    return pred();
  }

  get snap() { return this.a.getSnapshot(); }

  relay(n) { return this.snap.relays[n - 1]; }

  shutter(pair) { return this.snap.shutters[pair - 1]; }

  di(n) { return this.snap.dis[n - 1]; }

  get violations() { return this.observer.violations; }

  cmd(type, index = 0, value = 0, id = '', source = CmdSource.MQTT) {
    const c = makeCommand(type, source, index, value);
    c.id = id;
    return this.a.post(c);
  }

  /** Duvar butonu: basis -> `holdMs` -> birakis (ham seviye + suzgec firmware dongusunde). */
  press(n, holdMs = 150) {
    this.a.setRawDi(n - 1, true);
    this.run(holdMs);
    this.a.setRawDi(n - 1, false);
    this.run(80);
  }

  eventsOf(type) { return this.events.filter((e) => e.type === type); }
}

export { CmdType, CmdSource, makeCommand, ConfigManager, NvsImage };
