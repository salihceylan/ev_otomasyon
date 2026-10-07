// sensors/ContactBus.h (firmware) BIREBIR JavaScript portu: kapi/pencere onayli seviye kenarlari icin cok tuketicili halka. SAF MANTIK.
// Faz 2 tasarimi F2.B.5 (F2-5): ilk gozlem kenar degildir; ok=false "bilinmeyen"; 16 yuvalik halka tasarsa en eski kenarlar duser;
// kenarlar olay kutusuna YAZILMAZ. zoneWindowOpenFor(): iklim cekirdeginin arabirimi (plan 3.2).
// Dogrulama: test/fw_contact_bus.test.js, firmware'in Unity testlerinin (test/test_contact_bus) BIREBIR portudur.
import { SensorKind, MAX_SENSORS } from './sensor_hub.js';

const u32 = (x) => x >>> 0;

export class ContactBus {
  static CAP = 16;

  constructor() {
    this.ring_ = new Array(ContactBus.CAP).fill(null);
    this.head_ = 0;
    this.reset();
  }

  reset() {
    this.known_ = new Array(MAX_SENSORS).fill(false);
    this.open_ = new Array(MAX_SENSORS).fill(false);
    this.kind_ = new Array(MAX_SENSORS).fill(0);
    this.zone_ = new Array(MAX_SENSORS).fill(0);
    this.since_ = new Array(MAX_SENSORS).fill(0);
  }

  /** @returns {{pos:number}} yeni okuyucu yalniz bundan sonraki kenarlari gorur */
  cursor() { return { pos: this.head_ }; }

  observe(slot, kind, zone, ok, open, nowMs) {
    if (slot >= MAX_SENSORS) return;
    if (kind !== SensorKind.DOOR && kind !== SensorKind.WINDOW) return;
    this.kind_[slot] = kind;
    this.zone_[slot] = zone;
    if (!ok) { this.known_[slot] = false; return; }
    if (!this.known_[slot]) { this.known_[slot] = true; this.open_[slot] = !!open; this.since_[slot] = u32(nowMs); return; }
    if (this.open_[slot] === !!open) return;
    this.open_[slot] = !!open;
    this.since_[slot] = u32(nowMs);
    this.ring_[this.head_ % ContactBus.CAP] = { slot, kind, zone, open: open ? 1 : 0, at_ms: u32(nowMs) };
    this.head_++;
  }

  /** Okuyucunun siradaki kenari; yoksa null. Tasmada okuyucu en eski kalan kenara atlar. */
  read(c) {
    if (this.head_ - c.pos > ContactBus.CAP) c.pos = this.head_ - ContactBus.CAP;
    if (c.pos === this.head_) return null;
    const e = this.ring_[c.pos % ContactBus.CAP];
    c.pos++;
    return { ...e };
  }

  head() { return this.head_; }
  dropped() { return this.head_ > ContactBus.CAP ? this.head_ - ContactBus.CAP : 0; }
  known(slot) { return slot < MAX_SENSORS && this.known_[slot]; }
  isOpen(slot) { return slot < MAX_SENSORS && this.known_[slot] && this.open_[slot]; }

  zoneWindowOpenFor(zone, nowMs, holdMs) {
    for (let i = 0; i < MAX_SENSORS; i++) {
      if (!this.known_[i] || !this.open_[i] || this.kind_[i] !== SensorKind.WINDOW || this.zone_[i] !== zone) continue;
      if (u32(u32(nowMs) - this.since_[i]) >= holdMs) return true;
    }
    return false;
  }
}

/** SensorHub'in bu turdaki onayli seviyeleri (yalniz kapi/pencere). */
export function feedContacts(hub, bus, nowMs) {
  for (let i = 0; i < hub.count(); i++) {
    const c = hub.config(i);
    if (c.kind !== SensorKind.DOOR && c.kind !== SensorKind.WINDOW) continue;
    bus.observe(i, c.kind, c.zone, hub.ok(i), hub.active(i), nowMs);
  }
}
