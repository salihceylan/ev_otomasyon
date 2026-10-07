#pragma once
// ============================================================================
// events/EventOutboxRtos.h - EventOutbox'ı (saf) FreeRTOS mutex'iyle saran ince katman [B16]. BAĞLAYICI.
//
// Üretici loopTask (SafetyManager: SafetyCore olayları), tüketici MqttTask (WP-F4: nextDue/toJson/markSent, event_ack).
// Kilit kısa tutulur: JSON üretimi kilit altında sabit arabelleğe yapılır, yayın kilit DIŞINDA yapılmalıdır.
// ============================================================================
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include "events/EventOutbox.h"

namespace safety {

class EventOutboxRtos {
public:
  EventOutboxRtos() : mux_(nullptr) {}

  void begin(uint32_t bootNonce) {
    if (!mux_) mux_ = xSemaphoreCreateMutex();
    Guard g(*this, portMAX_DELAY);
    box_.begin(bootNonce);
  }

  // RAII kilit. ok() false ise kilit alınamadı; box()'a dokunulmamalı.
  class Guard {
  public:
    Guard(EventOutboxRtos& o, TickType_t wait) : o_(o), ok_(o.mux_ && xSemaphoreTake(o.mux_, wait) == pdTRUE) {}
    ~Guard() { if (ok_) xSemaphoreGive(o_.mux_); }
    bool ok() const { return ok_; }
  private:
    EventOutboxRtos& o_;
    bool ok_;
  };

  // Kilit sahibi çağırır (Guard ok() iken).
  EventOutbox& box() { return box_; }

  uint32_t bootNonce() {
    Guard g(*this, pdMS_TO_TICKS(20));
    return g.ok() ? box_.bootNonce() : 0;
  }

  bool ack(const char* eid) {
    Guard g(*this, pdMS_TO_TICKS(20));
    return g.ok() && box_.ack(eid);
  }

private:
  SemaphoreHandle_t mux_;
  EventOutbox box_;
};

}  // namespace safety
