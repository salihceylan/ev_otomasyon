const mqtt = require('mqtt');
const db = require('./db');
require('dotenv').config();

class MqttBridge {
  constructor() {
    this.client = null;
    this.connected = false;
  }

  init() {
    const host = process.env.MQTT_HOST || '127.0.0.1';
    const port = process.env.MQTT_PORT || 1884;
    const url = `mqtt://${host}:${port}`;

    console.log(`[MQTT-BRIDGE] Broker baglantisi baslatiliyor: ${url} (Kullanici: ${process.env.MQTT_USER})...`);

    this.client = mqtt.connect(url, {
      username: process.env.MQTT_USER,
      password: process.env.MQTT_PASS,
      clientId: `ev_backend_bridge_${Math.random().toString(16).substring(2, 8)}`,
      clean: true,
      reconnectPeriod: 3000,
    });

    this.client.on('connect', () => {
      this.connected = true;
      console.log('[MQTT-BRIDGE] EMQX Broker baglantisi BASARILI (Port 1884)!');

      // Tum evlerin status ve state konularini dinle
      this.client.subscribe(['ev/+/status', 'ev/+/state'], (err) => {
        if (err) {
          console.error('[MQTT-BRIDGE] Konu dinleme hatasi:', err.message);
        } else {
          console.log('[MQTT-BRIDGE] Dinlenen konular: ev/+/status, ev/+/state');
        }
      });
    });

    this.client.on('message', (topic, payload) => {
      this.handleIncomingMessage(topic, payload.toString());
    });

    this.client.on('error', (err) => {
      console.error('[MQTT-BRIDGE] Broker hatasi:', err.message);
    });

    this.client.on('offline', () => {
      this.connected = false;
      console.warn('[MQTT-BRIDGE] Broker cevrildisi!');
    });
  }

  async handleIncomingMessage(topic, message) {
    try {
      const parts = topic.split('/');
      if (parts.length < 3) return;

      const homeUsername = parts[1]; // ornek: home_101
      const subTopic = parts[2];     // status veya state

      if (subTopic === 'status') {
        const isOnline = (message.trim().toLowerCase() === 'online');
        console.log(`[MQTT-BRIDGE] Cihaz Durumu [${homeUsername}]: ${message} (Online=${isOnline})`);

        // Veritabaninda cihazin online durumunu guncelle
        await db.query(
          `UPDATE devices d 
           SET is_online = $1, last_seen_at = CURRENT_TIMESTAMP 
           FROM homes h 
           WHERE d.home_id = h.id AND h.mqtt_username = $2`,
          [isOnline, homeUsername]
        );
      } else if (subTopic === 'state') {
        let stateData;
        try {
          stateData = JSON.parse(message);
        } catch (e) {
          return;
        }

        // Cihaz telemetrisini guncelle (IP, Uptime)
        if (stateData.ip) {
          await db.query(
            `UPDATE devices d 
             SET ip_address = $1, is_online = TRUE, last_seen_at = CURRENT_TIMESTAMP 
             FROM homes h 
             WHERE d.home_id = h.id AND h.mqtt_username = $2`,
            [stateData.ip, homeUsername]
          );
        }

        // Role durumlarini endpoints tablosuna isle
        if (Array.isArray(stateData.relays)) {
          for (const r of stateData.relays) {
            await db.query(
              `UPDATE endpoints e 
               SET current_state = $1, updated_at = CURRENT_TIMESTAMP 
               FROM homes h 
               WHERE e.home_id = h.id AND h.mqtt_username = $2 AND e.channel_index = $3`,
              [r.state === true, homeUsername, r.id]
            );
          }
        }

        // Panjur pozisyonlarini endpoints tablosuna isle
        if (Array.isArray(stateData.shutters)) {
          for (const s of stateData.shutters) {
            await db.query(
              `UPDATE endpoints e 
               SET current_position = $1, updated_at = CURRENT_TIMESTAMP 
               FROM homes h 
               WHERE e.home_id = h.id AND h.mqtt_username = $2 AND e.shutter_pair_index = $3`,
              [s.pos, homeUsername, s.pair]
            );
          }
        }
      }
    } catch (err) {
      console.error('[MQTT-BRIDGE] Mesaj isleme hatasi:', err.message);
    }
  }

  publishCommand(homeUsername, commandObj) {
    return new Promise((resolve, reject) => {
      if (!this.connected || !this.client) {
        return reject(new Error('MQTT Broker baglantisi aktif degil'));
      }

      const topic = `ev/${homeUsername}/cmd`;
      const payload = JSON.stringify(commandObj);

      this.client.publish(topic, payload, { qos: 1 }, (err) => {
        if (err) {
          console.error(`[MQTT-BRIDGE] Komut yayinlama hatasi [${topic}]:`, err.message);
          return reject(err);
        }
        console.log(`[MQTT-BRIDGE] Komut gonderildi [${topic}]: ${payload}`);
        resolve({ topic, payload });
      });
    });
  }

  /**
   * Belirtilen topic'e doğrudan publish et (cron job ve zamanlı kurallar için)
   */
  publishToTopic(topic, payloadObj) {
    return new Promise((resolve, reject) => {
      if (!this.connected || !this.client) {
        return reject(new Error('MQTT Broker bağlantısı aktif değil'));
      }
      const payload = typeof payloadObj === 'string' ? payloadObj : JSON.stringify(payloadObj);
      this.client.publish(topic, payload, { qos: 1 }, (err) => {
        if (err) {
          console.error(`[MQTT-BRIDGE] publishToTopic hatası [${topic}]:`, err.message);
          return reject(err);
        }
        console.log(`[MQTT-BRIDGE] Topic'e gönderildi [${topic}]: ${payload}`);
        resolve({ topic, payload });
      });
    });
  }

  isConnected() {
    return this.connected;
  }
}

const mqttBridge = new MqttBridge();
module.exports = mqttBridge;

