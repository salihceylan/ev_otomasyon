#pragma once
// ============================================================================
// safety/SafetyCfgEdit.h - Güvenlik yapılandırmasının tek öğeli yaması ve "gevşetme" kuralı. SAF MANTIK.
//
// Tasarım §4.1-4.2, karar 7.2b-7 (WP-F4/F5):
//  * Her değişiklik yolu (LAN POST /api/safety/config, bulut sys cfg_patch, seri CLI) aynı yamayı (CfgEdit) üretir: tek öğe eklenir,
//    değiştirilir ya da silinir. Sonrasında yönetici validate(system, safety), kilitli bölge kuralı (touchesLockedZones), rev++,
//    NVS ve loopTask uygulamasını yapar (SafetyManager::submitEdit).
//  * isLoosening(): LAN'dan (yerel anahtar) yalnız ekleme/sıkılaştırma yapılabilir; politika kapatma, eylemci/tehlike sensörü silme,
//    tür/akışkan/kip/röle değişimi, bölge daraltma, NC->NO, onay süresini uzatma, kuruluk süresini kısaltma, siren süresini kısaltma,
//    geri bildirim kaldırma ve fanı ex-proof işaretleme GEVŞETMEDİR (karar 7.2b-7). Gevşetme yalnız seri CLI (fiziksel erişim) ya da
//    bulutta owner/servis rolüyle yapılır.
//  * actuatorIdentityMap(): çalışırken yamada eylemcilerin çalışma durumu kimliğe göre taşınır (inceleme turu EM-2/EM-3).
//  * remapActPos(): eylemci silinince sonraki eylemcilerin act_pos bitleri kayar; çalışırken EKLENEN vana için konum o anki röle
//    seviyesinden benimsenir (yapılandırma vanayı kendiliğinden açıp kapatmaz). İki röleli ve gaz vanası benimsenmez.
// ============================================================================
#include <stdint.h>
#include <string.h>
#include "safety/SafetyConfig.h"

namespace safety {

enum class EditOp : uint8_t {
  NONE = 0, SET_SENSOR = 1, SET_ACTUATOR = 2, SET_POLICY = 3, SET_ZONE = 4, SET_LIGHT = 5, DEL_SENSOR = 6, DEL_ACTUATOR = 7
};

struct CfgEdit {
  EditOp op;
  SensorConfig sens;          // SET_SENSOR: tam öğe; DEL_SENSOR: yalnız src + index
  ActuatorConfig act;         // SET_ACTUATOR: tam öğe
  uint8_t actIndex;           // SET/DEL_ACTUATOR: 0 tabanlı (a<n> = n-1); 0xFF = yeni (sona ekle)
  uint8_t hasPolicyOn;
  uint8_t policyOn;
  uint8_t hasDryHold;
  uint32_t dryHoldMs;
  uint8_t zoneId;             // SET_ZONE: 1..4
  char zoneName[ZONE_NAME_LEN];
  uint8_t lightRelay;         // SET_LIGHT: 1..40
  LightOpt light;
};

inline void editInit(CfgEdit& e) {
  memset(&e, 0, sizeof(e));
  e.actIndex = 0xFF;
}

inline uint16_t removeBit16(uint16_t bits, uint8_t idx) {
  if (idx >= 16) return bits;
  const uint16_t low = (uint16_t)(bits & ((1u << idx) - 1u));
  const uint16_t high = (uint16_t)((bits >> (idx + 1)) << idx);
  return (uint16_t)(low | high);
}

// cur'a yamayı uygular, sonucu out'a yazar (rev değişmez). removedAct: silinen eylemcinin indeksi, yoksa -1.
inline CfgErr applyEdit(const SafetyConfig& cur, const CfgEdit& e, SafetyConfig& out, int8_t& removedAct) {
  out = cur;
  removedAct = -1;
  switch (e.op) {
    case EditOp::SET_SENSOR: {
      for (uint8_t i = 0; i < out.nSens; i++) {
        if (out.sens[i].src == e.sens.src && out.sens[i].index == e.sens.index) {
          out.sens[i] = e.sens;
          return CfgErr::OK;
        }
      }
      if (out.nSens >= MAX_SENSORS) return CfgErr::FULL;
      out.sens[out.nSens++] = e.sens;
      return CfgErr::OK;
    }
    case EditOp::DEL_SENSOR: {
      for (uint8_t i = 0; i < out.nSens; i++) {
        if (out.sens[i].src != e.sens.src || out.sens[i].index != e.sens.index) continue;
        for (uint8_t j = i; j + 1 < out.nSens; j++) out.sens[j] = out.sens[j + 1];
        out.nSens--;
        memset(&out.sens[out.nSens], 0, sizeof(SensorConfig));
        return CfgErr::OK;
      }
      return CfgErr::NOT_FOUND;
    }
    case EditOp::SET_ACTUATOR: {
      if (e.actIndex < out.nAct) {
        out.act[e.actIndex] = e.act;
        return CfgErr::OK;
      }
      if (e.actIndex != 0xFF && e.actIndex != out.nAct) return CfgErr::NOT_FOUND;
      if (out.nAct >= MAX_ACTUATORS) return CfgErr::FULL;
      out.act[out.nAct++] = e.act;
      return CfgErr::OK;
    }
    case EditOp::DEL_ACTUATOR: {
      if (e.actIndex >= out.nAct) return CfgErr::NOT_FOUND;
      for (uint8_t j = e.actIndex; j + 1 < out.nAct; j++) out.act[j] = out.act[j + 1];
      out.nAct--;
      memset(&out.act[out.nAct], 0, sizeof(ActuatorConfig));
      removedAct = (int8_t)e.actIndex;
      return CfgErr::OK;
    }
    case EditOp::SET_POLICY:
      if (!e.hasPolicyOn && !e.hasDryHold) return CfgErr::BAD_EDIT;
      if (e.hasPolicyOn) out.pol.policy_on = e.policyOn ? 1 : 0;
      if (e.hasDryHold) out.pol.dry_hold_ms = e.dryHoldMs;
      return CfgErr::OK;
    case EditOp::SET_ZONE:
      if (e.zoneId < 1 || e.zoneId > MAX_ZONES) return CfgErr::BAD_EDIT;
      memcpy(out.zones[e.zoneId - 1].name, e.zoneName, ZONE_NAME_LEN);
      out.zones[e.zoneId - 1].name[ZONE_NAME_LEN - 1] = '\0';
      return CfgErr::OK;
    case EditOp::SET_LIGHT:
      if (e.lightRelay < 1 || e.lightRelay > MAX_RELAYS) return CfgErr::BAD_EDIT;
      out.light[e.lightRelay - 1] = e.light;
      return CfgErr::OK;
    default:
      return CfgErr::BAD_EDIT;
  }
}

// Kalıcı DI kullanım geçmişi (NVS "ahbu_latch/di_hist"; inceleme turu 2 FW2-2): uygulanmış bir yapılandırmada herhangi bir satırın (sensör,
// kumanda rolü, vana geri bildirim girişi) kullandığı kablolu DI'ler (bit = DI-1). Köprü yuvaları girmez. Yönetici her uygulamada bu maskeyi
// birleştirir (yalnız büyür; fabrika sıfırlaması "ahbu_latch"ı silmez).
inline uint64_t diUseMask(const SafetyConfig& c) {
  uint64_t m = 0;
  for (uint8_t i = 0; i < c.nSens && i < MAX_SENSORS; i++) {
    const SensorConfig& s = c.sens[i];
    if (s.src == (uint8_t)SensorSrc::DI && s.index >= 1 && s.index <= MAX_DI) m |= 1ULL << (s.index - 1);
  }
  for (uint8_t i = 0; i < c.nAct && i < MAX_ACTUATORS; i++) {
    const uint8_t d = c.act[i].fb_di;
    if (d >= 1 && d <= MAX_DI) m |= 1ULL << (d - 1);
  }
  return m;
}

// Karar 7.2b-7: b, a'ya göre emniyeti azaltıyor mu? (LAN'dan yalnız ekleme/sıkılaştırma.)
// İnceleme turu (entegrasyon): mevcut bir sensör/rol satırını GAS_RESET'e çevirmek (ör. kapı kontağı: her kapı açılışında gaz vanası
// açılırdı) ya da mevcut GAS_RESET satırının bölgesini değiştirmek gevşetmedir [EM-6]; boş girişe YENİ GAS_RESET eklemek (sihirbaz akışı)
// değildir. Yeni eklenen eylemci satırında fanın ex-proof işareti de gevşetmedir [EM-7].
// İnceleme turu 2 FW2-2: silme ve ekleme ayrı yamalarda geldiğinde tek adımlık kural aşılmasın diye, a'da karşılığı olmayan YENİ GAS_RESET
// satırı, DI'si kalıcı kullanım geçmişinde (diHist, diUseMask) ise gevşetmedir: kapı kontağını silip aynı girişe GAS_RESET eklemek ya da
// GAS_RESET'i silip başka bölgeyle yeniden eklemek LAN'dan yapılamaz. Hiç kullanılmamış girişe yeni GAS_RESET (sihirbaz) serbesttir.
inline bool isLoosening(const SafetyConfig& a, const SafetyConfig& b, uint64_t diHist = 0) {
  if (a.pol.policy_on && !b.pol.policy_on) return true;
  if (b.pol.dry_hold_ms < a.pol.dry_hold_ms) return true;
  for (uint8_t j = 0; j < b.nSens; j++) {
    const SensorConfig& t = b.sens[j];
    if (t.kind != (uint8_t)SensorKind::GAS_RESET) continue;
    bool existed = false;
    for (uint8_t i = 0; i < a.nSens; i++) {
      const SensorConfig& s = a.sens[i];
      if (s.src != t.src || s.index != t.index) continue;
      existed = true;
      if (s.kind != t.kind || s.zone != t.zone) return true;
    }
    if (!existed && t.src == (uint8_t)SensorSrc::DI && t.index >= 1 && t.index <= MAX_DI && (diHist & (1ULL << (t.index - 1)))) return true;
  }
  for (uint8_t i = 0; i < a.nSens; i++) {
    const SensorConfig& s = a.sens[i];
    if (hazardOf(s.kind) == 0) continue;                       // kapı/pencere/hareket ve yerel kumanda rolleri bu modülde emniyet sürmez
    const SensorConfig* t = nullptr;
    for (uint8_t j = 0; j < b.nSens && !t; j++) {
      if (b.sens[j].src == s.src && b.sens[j].index == s.index) t = &b.sens[j];
    }
    if (!t) return true;
    if (t->kind != s.kind || t->zone != s.zone) return true;
    if ((s.flags & ~t->flags) & (SF_REACT | SF_FAULT_CLOSE)) return true;
    if (t->confirm_ms > s.confirm_ms) return true;
    if (s.active_open && !t->active_open) return true;
  }
  for (uint8_t i = 0; i < a.nAct; i++) {
    if (i >= b.nAct) return true;
    const ActuatorConfig& x = a.act[i];
    const ActuatorConfig& y = b.act[i];
    if (y.relay != x.relay || y.relay2 != x.relay2 || y.kind != x.kind || y.close_mode != x.close_mode || y.medium != x.medium) return true;
    if (x.zone_mask & ~y.zone_mask) return true;
    if (x.fb_di != 0 && (y.fb_di != x.fb_di || y.fb_closed_active != x.fb_closed_active || y.fb_timeout_s > x.fb_timeout_s)) return true;
    if (x.kind == (uint8_t)ActKind::SIREN && y.run_limit_s < x.run_limit_s) return true;
    if ((y.aflags & AF_FAN_EXPROOF) && !(x.aflags & AF_FAN_EXPROOF)) return true;
  }
  for (uint8_t i = a.nAct; i < b.nAct; i++) {
    if (b.act[i].kind == (uint8_t)ActKind::FAN && (b.act[i].aflags & AF_FAN_EXPROOF)) return true;
  }
  return false;
}

// Çalışırken yama (inceleme turu EM-2/EM-3): yeni tablodaki her eylemcinin eski tablodaki karşılığı (yoksa -1). Kimlik: aynı röle(ler), tür,
// kip, akışkan ve geri bildirim girişi (bölge/ad/süre değişimi kimliği bozmaz). ActuatorCore::reconfigure ve SafetyCore::reconfigured çalışma
// durumunu (konum, arıza, darbe, siren bütçesi, elle açık, kullanıcı susturması) bu eşlemeyle taşır. Her eski satır en çok bir kez eşlenir.
inline void actuatorIdentityMap(const SafetyConfig& oldC, const SafetyConfig& newC, int8_t map[MAX_ACTUATORS]) {
  bool used[MAX_ACTUATORS];
  memset(used, 0, sizeof(used));
  for (uint8_t j = 0; j < MAX_ACTUATORS; j++) map[j] = -1;
  for (uint8_t j = 0; j < newC.nAct && j < MAX_ACTUATORS; j++) {
    const ActuatorConfig& y = newC.act[j];
    for (uint8_t i = 0; i < oldC.nAct && i < MAX_ACTUATORS; i++) {
      const ActuatorConfig& x = oldC.act[i];
      if (used[i] || x.relay != y.relay || x.relay2 != y.relay2 || x.kind != y.kind || x.close_mode != y.close_mode ||
          x.medium != y.medium || x.fb_di != y.fb_di || x.fb_closed_active != y.fb_closed_active) {
        continue;
      }
      used[i] = true;
      map[j] = (int8_t)i;
      break;
    }
  }
}

// act_pos bitlerinin yeni tabloya taşınması. Eşleşme: aynı röle(ler), tür, kip ve akışkan. Eşleşmeyen (yeni) su vanası için konum o anki
// röle seviyesinden benimsenir (curLevels: bit = röle-1); iki röleli vana ve gaz vanası benimsenmez (gaz her zaman kapalı başlar).
inline void remapActPos(const SafetyConfig& oldC, uint16_t oldOpen, uint16_t oldKnown, const SafetyConfig& newC, uint64_t curLevels,
                        uint16_t& newOpen, uint16_t& newKnown) {
  newOpen = 0;
  newKnown = 0;
  for (uint8_t j = 0; j < newC.nAct && j < MAX_ACTUATORS; j++) {
    const ActuatorConfig& y = newC.act[j];
    if (!isValve(y)) continue;
    const uint16_t bj = (uint16_t)(1u << j);
    bool matched = false;
    for (uint8_t i = 0; i < oldC.nAct && i < MAX_ACTUATORS && !matched; i++) {
      const ActuatorConfig& x = oldC.act[i];
      if (x.relay != y.relay || x.relay2 != y.relay2 || x.kind != y.kind || x.close_mode != y.close_mode || x.medium != y.medium) continue;
      matched = true;
      if (oldKnown & (1u << i)) {
        newKnown = (uint16_t)(newKnown | bj);
        if (oldOpen & (1u << i)) newOpen = (uint16_t)(newOpen | bj);
      }
    }
    if (matched || isPulseValve(y) || isGasValve(y)) continue;
    const bool level = (curLevels & relayBit(y.relay)) != 0;
    newKnown = (uint16_t)(newKnown | bj);
    if (level == relayLevelFor(y, false)) newOpen = (uint16_t)(newOpen | bj);
  }
}

}  // namespace safety
