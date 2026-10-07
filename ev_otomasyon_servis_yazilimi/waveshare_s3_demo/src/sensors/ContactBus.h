#pragma once
// ============================================================================
// sensors/ContactBus.h - Kapı/pencere kontaklarının onaylı seviye kenarları için çok tüketicili halka. SAF MANTIK (saat parametre).
//
// Tasarım: docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md "Faz 2 tasarımı" F2.B.5 (F2-5).
//  * Yazıcı tek: SafetyManager her loopTask turunda feedContacts(hub, bus) ile door/window sensörlerinin onaylı seviyesini verir; bus kenarı
//    kendisi bulur. İlk gözlem (açılış, yapılandırma değişimi, ok=false sonrası) kenar DEĞİLDİR; ok=false sensör "bilinmeyen"dir.
//  * Okuyucular (IntrusionCore'un ötesinde: ClimateCore plan 3.2, SceneEngine plan 5.2) kendi imleçleriyle (Cursor) okur; kilit yok: yazıcı
//    ve okuyucular aynı görevde. 16 yuvalık halka taşarsa en eski kenarlar düşer (seviye zaten state'tedir).
//  * Kenarlar olay kutusuna (ev/{t}/event) YAZILMAZ; bulut ve uygulama seviyeyi state.sensors[].active'ten okur.
//  * zoneWindowOpenFor(): iklim çekirdeğinin arabirimi (pencere hold_ms kesintisiz açıksa o bölgede ısıtma durur).
// Zaman karşılaştırmaları (uint32_t)(now - t) biçimindedir (millis() taşmasına dayanıklı).
// ============================================================================
#include "sensors/SensorHub.h"

namespace safety {

struct ContactEdge {
  uint8_t slot;      // sensör tablosundaki yuva (0 tabanlı)
  uint8_t kind;      // SensorKind::DOOR | WINDOW
  uint8_t zone;
  uint8_t open;      // 1: açıldı, 0: kapandı
  uint32_t at_ms;
};

class ContactBus {
public:
  enum : uint8_t { CAP = 16 };
  struct Cursor {
    uint32_t pos;
  };

  ContactBus() : head_(0) {
    memset(ring_, 0, sizeof(ring_));
    reset();
  }

  // Yapılandırma değişti (yuva anlamı değişebilir): seviyeler unutulur; halkadaki eski kenarlar okunabilir kalır.
  void reset() {
    memset(known_, 0, sizeof(known_));
    memset(open_, 0, sizeof(open_));
    memset(kind_, 0, sizeof(kind_));
    memset(zone_, 0, sizeof(zone_));
    memset(since_, 0, sizeof(since_));
  }

  // Yeni okuyucu yalnız bundan sonraki kenarları görür.
  Cursor cursor() const {
    Cursor c;
    c.pos = head_;
    return c;
  }

  void observe(uint8_t slot, uint8_t kind, uint8_t zone, bool ok, bool open, uint32_t now_ms) {
    if (slot >= MAX_SENSORS) return;
    if (kind != (uint8_t)SensorKind::DOOR && kind != (uint8_t)SensorKind::WINDOW) return;
    kind_[slot] = kind;
    zone_[slot] = zone;
    if (!ok) {
      known_[slot] = false;
      return;
    }
    if (!known_[slot]) {
      known_[slot] = true;
      open_[slot] = open;
      since_[slot] = now_ms;
      return;
    }
    if (open_[slot] == open) return;
    open_[slot] = open;
    since_[slot] = now_ms;
    ContactEdge& e = ring_[head_ % CAP];
    e.slot = slot;
    e.kind = kind;
    e.zone = zone;
    e.open = open ? 1 : 0;
    e.at_ms = now_ms;
    head_++;
  }

  // Okuyucunun sıradaki kenarı; yoksa false. Taşmada okuyucu en eski kalan kenara atlar.
  bool read(Cursor& c, ContactEdge& out) const {
    if ((uint32_t)(head_ - c.pos) > CAP) c.pos = head_ - CAP;
    if (c.pos == head_) return false;
    out = ring_[c.pos % CAP];
    c.pos++;
    return true;
  }

  uint32_t head() const { return head_; }
  uint32_t dropped() const { return head_ > CAP ? head_ - CAP : 0; }   // toplam düşen (halkanın üstüne yazılan) kenar
  bool known(uint8_t slot) const { return slot < MAX_SENSORS && known_[slot]; }
  bool isOpen(uint8_t slot) const { return slot < MAX_SENSORS && known_[slot] && open_[slot]; }

  // Bölgede en az bir pencere hold_ms boyunca kesintisiz açık mı (iklim arabirimi, plan 3.2).
  bool zoneWindowOpenFor(uint8_t zone, uint32_t now_ms, uint32_t hold_ms) const {
    for (uint8_t i = 0; i < MAX_SENSORS; i++) {
      if (!known_[i] || !open_[i] || kind_[i] != (uint8_t)SensorKind::WINDOW || zone_[i] != zone) continue;
      if ((uint32_t)(now_ms - since_[i]) >= hold_ms) return true;
    }
    return false;
  }

private:
  ContactEdge ring_[CAP];
  uint32_t head_;
  bool known_[MAX_SENSORS];
  bool open_[MAX_SENSORS];
  uint8_t kind_[MAX_SENSORS];
  uint8_t zone_[MAX_SENSORS];
  uint32_t since_[MAX_SENSORS];
};

// SensorHub'ın bu turdaki onaylı seviyelerini kapı/pencere için bus'a verir (diğer türler bus'ta yok sayılır).
inline void feedContacts(const SensorHub& hub, ContactBus& bus, uint32_t now_ms) {
  for (uint8_t i = 0; i < hub.count(); i++) {
    const SensorConfig& c = *hub.config(i);
    if (c.kind != (uint8_t)SensorKind::DOOR && c.kind != (uint8_t)SensorKind::WINDOW) continue;
    bus.observe(i, c.kind, c.zone, hub.ok(i), hub.active(i), now_ms);
  }
}

}  // namespace safety
