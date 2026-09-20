#include "WebPortal.h"
#include "ConfigManager.h"
#include "SmartAutomation.h"
#include <WiFi.h>
#include <ArduinoJson.h>

static const char INDEX_HTML[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AHBU Akıllı Ev & Bina Kontrol</title>
<style>
:root {
  --bg: #0f172a; --card-bg: #1e293b; --card-border: #334155;
  --primary: #3b82f6; --primary-hover: #2563eb; --accent: #f59e0b;
  --text: #f8fafc; --text-muted: #94a3b8; --success: #10b981;
  --danger: #ef4444; --warning: #eab308;
}
* { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
body { background: var(--bg); color: var(--text); min-height: 100vh; padding-bottom: 40px; }
header { background: #0b1120; border-bottom: 1px solid var(--card-border); padding: 14px 20px; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; }
.logo-title { display: flex; align-items: center; gap: 10px; }
.logo-badge { background: linear-gradient(135deg, #3b82f6, #1d4ed8); padding: 6px 12px; border-radius: 8px; font-weight: bold; font-size: 14px; letter-spacing: 1px; }
.header-info { display: flex; gap: 12px; font-size: 13px; color: var(--text-muted); align-items: center; }
.nav-tabs { display: flex; background: #131d31; border-bottom: 1px solid var(--card-border); overflow-x: auto; padding: 0 10px; }
.nav-tab { padding: 14px 18px; color: var(--text-muted); font-size: 14px; font-weight: 600; cursor: pointer; border-bottom: 3px solid transparent; white-space: nowrap; transition: 0.2s; }
.nav-tab:hover { color: var(--text); }
.nav-tab.active { color: var(--primary); border-bottom-color: var(--primary); background: rgba(59, 130, 246, 0.08); }
.content-section { display: none; padding: 20px; max-width: 1100px; margin: 0 auto; }
.content-section.active { display: block; }
.section-title { font-size: 18px; margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; }
.quick-actions { display: flex; gap: 10px; margin-bottom: 20px; flex-wrap: wrap; }
.btn { padding: 10px 16px; border-radius: 8px; border: none; font-size: 14px; font-weight: 600; cursor: pointer; transition: 0.2s; display: inline-flex; align-items: center; gap: 6px; }
.btn-primary { background: var(--primary); color: white; }
.btn-primary:hover { background: var(--primary-hover); }
.btn-danger { background: var(--danger); color: white; }
.btn-danger:hover { background: #dc2626; }
.btn-secondary { background: #334155; color: white; }
.btn-secondary:hover { background: #475569; }
.btn-outline { background: transparent; border: 1px solid var(--card-border); color: var(--text); }
.btn-outline:hover { background: rgba(255,255,255,0.05); }
.cards-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px; margin-bottom: 24px; }
.card { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 14px; padding: 18px; display: flex; flex-direction: column; justify-content: space-between; gap: 14px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); }
.card-header { display: flex; justify-content: space-between; align-items: center; }
.card-title { font-size: 16px; font-weight: 600; }
.card-type-badge { font-size: 11px; padding: 4px 8px; border-radius: 6px; background: #0f172a; color: var(--text-muted); font-weight: 500; }
.status-indicator { display: inline-block; width: 10px; height: 10px; border-radius: 50%; background: #64748b; }
.status-indicator.on { background: var(--success); box-shadow: 0 0 8px var(--success); }
.status-indicator.moving { background: var(--accent); box-shadow: 0 0 8px var(--accent); animation: pulse 1s infinite; }
@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }
.switch-btn { width: 56px; height: 30px; background: #334155; border-radius: 15px; position: relative; cursor: pointer; transition: 0.3s; }
.switch-btn.on { background: var(--success); }
.switch-knob { width: 24px; height: 24px; background: white; border-radius: 50%; position: absolute; top: 3px; left: 3px; transition: 0.3s; }
.switch-btn.on .switch-knob { left: 29px; }
.shutter-controls { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px; }
.shutter-btn { padding: 10px 4px; font-size: 12px; font-weight: bold; border-radius: 8px; border: 1px solid var(--card-border); background: #0f172a; color: var(--text); cursor: pointer; text-align: center; }
.shutter-btn:hover { background: #334155; }
.shutter-btn.active { background: var(--accent); color: #000; border-color: var(--accent); }
.di-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(115px, 1fr)); gap: 10px; }
.di-pill { background: #0f172a; border: 1px solid var(--card-border); border-radius: 10px; padding: 10px; text-align: center; font-size: 13px; font-weight: 500; }
.di-pill.active { border-color: var(--success); background: rgba(16, 185, 129, 0.15); color: var(--success); font-weight: bold; }
table { width: 100%; border-collapse: collapse; margin-top: 10px; background: var(--card-bg); border-radius: 12px; overflow: hidden; }
th, td { padding: 12px 14px; text-align: left; border-bottom: 1px solid var(--card-border); font-size: 14px; }
th { background: #0b1120; color: var(--text-muted); font-size: 12px; text-transform: uppercase; }
input[type="text"], input[type="password"], select { background: #0f172a; border: 1px solid var(--card-border); color: var(--text); padding: 8px 12px; border-radius: 8px; font-size: 14px; width: 100%; }
input[type="text"]:focus, input[type="password"]:focus, select:focus { outline: none; border-color: var(--primary); }
.terminal-window { background: #000; border: 1px solid var(--card-border); border-radius: 10px; height: 320px; padding: 14px; font-family: monospace; font-size: 13px; color: #10b981; overflow-y: auto; white-space: pre-wrap; margin-bottom: 12px; }
.toast { position: fixed; bottom: 20px; right: 20px; background: var(--primary); color: white; padding: 12px 20px; border-radius: 10px; box-shadow: 0 10px 15px -3px rgba(0,0,0,0.3); font-weight: 600; display: none; z-index: 1000; }
.mode-cards-group { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 12px; margin-top: 6px; }
.mode-card { display: flex; flex-direction: column; padding: 12px 14px; border-radius: 10px; background: #0f172a; border: 1.5px solid var(--card-border); cursor: pointer; transition: all 0.2s ease; user-select: none; }
.mode-card:hover { border-color: rgba(96, 165, 250, 0.6); background: #131d31; }
.mode-card.selected { background: rgba(59, 130, 246, 0.12); border-color: var(--primary); box-shadow: 0 0 12px rgba(59, 130, 246, 0.25); }
.mode-card-header { display: flex; align-items: center; gap: 8px; font-weight: 700; font-size: 13.5px; color: var(--text); }
.mode-card-desc { font-size: 12px; color: var(--text-muted); margin-top: 6px; line-height: 1.4; }
.mode-card-wiring { font-size: 11px; color: #34d399; margin-top: 8px; padding-top: 6px; border-top: 1px dashed rgba(255, 255, 255, 0.1); line-height: 1.4; }
.pair-grid { display: grid; grid-template-columns: 2fr 1fr; gap: 16px; align-items: start; }
.grid-2col { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
@media (max-width: 720px) {
  .pair-grid, .grid-2col { grid-template-columns: 1fr !important; }
}
</style>
</head>
<body>

<header>
  <div class="logo-title">
    <div class="logo-badge">AHBU</div>
    <div>
      <h1 style="font-size: 18px; font-weight: 700;" id="hdrDevName">Akıllı Ev & Bina Kontrol</h1>
      <span style="font-size: 12px; color: var(--text-muted);">Waveshare ESP32-S3 Endüstriyel Pano Modülü</span>
    </div>
  </div>
  <div class="header-info">
    <span>🌐 IP: <b id="hdrIp">-</b></span>
    <span>📶 WiFi: <b id="hdrRssi">-</b></span>
    <span>⏱️ Uptime: <b id="hdrUptime">-</b></span>
  </div>
</header>

<div class="nav-tabs">
  <div class="nav-tab active" onclick="switchTab('control')">⚡ Kontrol</div>
  <div class="nav-tab" onclick="switchTab('config')">⚙️ Kanal Ayarları</div>
  <div class="nav-tab" onclick="switchTab('wifi')">📶 Wi-Fi & Ağ</div>
  <div class="nav-tab" onclick="switchTab('rs485')">📟 RS485 Terminal</div>
  <div class="nav-tab" onclick="switchTab('system')">ℹ️ Sistem</div>
</div>

<!-- ================= TAB 1: KONTROL ================= -->
<div id="tab-control" class="content-section active">
  <div class="quick-actions">
    <button class="btn btn-secondary" onclick="cmdAll('lightsoff')">💡 Tüm Işıkları Kapat</button>
    <button class="btn btn-secondary" onclick="cmdAll('shuttersdown')">🔽 Tüm Panjurları İndir</button>
    <button class="btn btn-secondary" onclick="cmdAll('shuttersup')">▲ Tüm Panjurları Kaldır</button>
    <button class="btn btn-outline" onclick="cmdAll('shuttersstop')">⏹ Panjurları Durdur</button>
  </div>

  <div class="section-title">
    <span>🎛️ Röle ve Cihaz Durumları</span>
    <span style="font-size: 13px; color: var(--text-muted);" id="liveStatusTxt">Canlı güncelleniyor</span>
  </div>

  <div class="cards-grid" id="relaysGrid"></div>

  <div class="section-title" style="margin-top: 10px;">
    <span>🔘 Dijital Girişler (8DI Duvar Butonları)</span>
    <span style="font-size: 12px; color: var(--text-muted);">DGND ile temas anında yeşile döner</span>
  </div>
  <div class="di-grid" id="diGrid"></div>
</div>

<!-- ================= TAB 2: KANAL AYARLARI ================= -->
<div id="tab-config" class="content-section">

  <!-- 📦 Ek Modül Kurulum Kartı -->
  <div class="card" style="background: var(--card-bg); border: 1.5px solid #3b82f6; border-radius: 14px; padding: 18px; margin-bottom: 24px; box-shadow: 0 4px 12px rgba(59, 130, 246, 0.15);">
    <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 12px; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 12px;">
      <div style="display: flex; align-items: center; gap: 12px;">
        <span style="font-size: 26px;">📦</span>
        <div>
          <div style="font-size: 15.5px; font-weight: 700; color: #60A5FA;">Harici Genişletme Modülü Kurulumu (RS485)</div>
          <div style="font-size: 12.5px; color: var(--text-muted);">Daire panosunda ilave röle ve giriş genişletme kartı kullanılacak mı?</div>
        </div>
      </div>
      <div style="display: flex; align-items: center; gap: 12px;">
        <span style="font-size: 13.5px; font-weight: 600; color: var(--text);">Ek modül kuracak mısınız?</span>
        <div class="switch-btn" id="swExtModule" onclick="toggleExtModule()">
          <div class="switch-knob"></div>
        </div>
      </div>
    </div>

    <div id="extModuleOptions" style="display: none; margin-top: 14px;">
      <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; align-items: center;">
        <div>
          <label style="font-size: 13px; font-weight: 600; color: var(--text-muted); display: block; margin-bottom: 6px;">Ek Modül Kaç Kanallı? (Piyasa Seçenekleri)</label>
          <select id="selExtChannels" onchange="onExtChannelsChange(this.value)">
            <option value="2">2 Kanallı Modül (+2 Röle / +2 DI - 1 Panjur)</option>
            <option value="4">4 Kanallı Modül (+4 Röle / +4 DI - 2 Panjur)</option>
            <option value="8" selected>8 Kanallı Modül (+8 Röle / +8 DI - 4 Panjur) [En Yaygın]</option>
            <option value="12">12 Kanallı Modül (+12 Röle / +12 DI - 6 Panjur)</option>
            <option value="16">16 Kanallı Modül (+16 Röle / +16 DI - 8 Panjur) [Yaygın]</option>
            <option value="24">24 Kanallı Modül (+24 Röle / +24 DI - 12 Panjur)</option>
            <option value="30">30 Kanallı Modül (+30 Röle / +30 DI - 15 Panjur)</option>
            <option value="32">32 Kanallı Modül (+32 Röle / +32 DI - 16 Panjur) [Maksimum]</option>
          </select>
        </div>
        <div>
          <label style="font-size: 13px; font-weight: 600; color: var(--text-muted); display: block; margin-bottom: 6px;">Modbus Slave ID (RS485 Adresi):</label>
          <input type="number" id="inpExtAddr" value="1" min="1" max="247" onchange="onExtAddressChange(this.value)" style="width: 100px; text-align: center; font-weight: bold;">
        </div>
        <div style="background: rgba(59, 130, 246, 0.1); border: 1px solid rgba(59, 130, 246, 0.3); border-radius: 10px; padding: 12px 14px; font-size: 12.5px; color: #93C5FD;">
          ⚡ <b>Toplam Sistem Kapasitesi:</b> <span id="lblTotalCapacity" style="font-weight: bold; color: #38BDF8;">16 Röle / 16 Giriş (8 Çift)</span>
        </div>
      </div>
    </div>
  </div>

  <div class="section-title">
    <span id="cfgRelayTitle">⚙️ Röle Çıkış Yapılandırması</span>
    <button class="btn btn-primary" onclick="saveRelayConfig()">💾 Röle Ayarlarını Kaydet</button>
  </div>
  <p style="font-size: 13px; color: var(--text-muted); margin-bottom: 16px;">
    Panjur motorları 2 röle (Yukarı + Aşağı) gerektirir ve donanımsal kilitlemeli birleşik grup olarak çalışır. Lamba veya kilit için münferit seçim yapabilirsiniz.
  </p>
  <div id="cfgRelayPairsContainer" style="display: flex; flex-direction: column; gap: 16px;"></div>

  <div class="section-title" style="margin-top: 36px;">
    <span id="cfgDITitle">🔘 Giriş Yapılandırması (Duvar Butonları & Sensörler)</span>
    <button class="btn btn-primary" onclick="saveDIConfig()">💾 Giriş Ayarlarını Kaydet</button>
  </div>
  <p style="font-size: 13px; color: var(--text-muted); margin-bottom: 16px;">
    Duvardaki buton tesisatınıza göre seçim yapın. Panjuru tek yaylı butonla bağlarsanız 2. klemens serbest kalır ve evdeki başka bir lamba/kapı için değerlendirilebilir.
  </p>
  <div id="cfgDIPairsContainer" style="display: flex; flex-direction: column; gap: 16px;"></div>
</div>

<!-- ================= TAB 3: WIFI & AG ================= -->
<div id="tab-wifi" class="content-section">
  <div class="card" style="max-width: 620px; margin: 0 auto;">
    
    <!-- Wi-Fi Bağlantı Durumu Kartı -->
    <div id="wifiStatusCard" style="margin-bottom: 22px; padding: 16px; border-radius: 12px; background: rgba(255, 255, 255, 0.03); border: 1px solid rgba(255, 255, 255, 0.08);">
      <div style="font-size: 13px; color: var(--text-muted);">Bağlantı durumu yükleniyor...</div>
    </div>

    <h3 style="font-size: 16px;">📶 Ev Wi-Fi Ağına Bağlan (Station Modu)</h3>
    <p style="font-size: 13px; color: var(--text-muted); margin-bottom: 14px;">Cihazın ev modemi üzerinden yerel ağa bağlanmasını sağlar. Böylece modeme bağlı tüm telefon ve bilgisayarlardan doğrudan erişebilirsiniz.</p>
    
    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px;">
      <label style="font-size: 13px; font-weight: 600;">📡 Çevredeki Wi-Fi Ağları:</label>
      <button class="btn btn-outline" style="padding: 4px 10px; font-size: 12px;" onclick="scanWifi(true)">🔄 Ağları Yenile</button>
    </div>
    <div>
      <select id="wifiScanSelect" onchange="selectScannedWifi()">
        <option value="">Ağlar yükleniyor...</option>
      </select>
      <span id="scanStatus" style="font-size: 12px; color: var(--text-muted); display: block; margin-top: 4px;"></span>
    </div>

    <div style="margin-top: 14px;">
      <label style="font-size: 13px; font-weight: 600; margin-bottom: 6px; display: block;">Seçilen Wi-Fi Adı (SSID):</label>
      <input type="text" id="wifiSsid" placeholder="Yukarıdaki listeden bir ağ seçin">
    </div>

    <div style="margin-top: 14px;">
      <label style="font-size: 13px; font-weight: 600; margin-bottom: 6px; display: block;">Wi-Fi Şifresi:</label>
      <input type="password" id="wifiPass" placeholder="Wi-Fi Şifreniz">
    </div>

    <div style="display: flex; gap: 10px; margin-top: 16px;">
      <button class="btn btn-primary" style="flex: 1; justify-content: center;" onclick="connectWifi()">Bağlan ve Kalıcı Kaydet</button>
      <button id="btnWifiDisconnect" class="btn btn-danger" style="display: none; padding: 10px 14px; font-size: 13px;" onclick="disconnectWifi()">Bağlantıyı Kes</button>
    </div>
  </div>
</div>

<!-- ================= TAB 4: RS485 ================= -->
<div id="tab-rs485" class="content-section">
  <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px;">
    <div style="display: flex; gap: 10px; align-items: center;">
      <span style="font-size: 14px; font-weight: 600;">Baud Rate:</span>
      <select id="rs485Baud" style="width: 120px;" onchange="changeRs485Baud()">
        <option value="9600">9600</option>
        <option value="19200">19200</option>
        <option value="38400">38400</option>
        <option value="115200">115200</option>
      </select>
    </div>
    <button class="btn btn-secondary" onclick="clearRs485Logs()">Temizle</button>
  </div>

  <div style="display: flex; gap: 8px; margin-bottom: 12px; flex-wrap: wrap;">
    <button class="btn btn-primary" onclick="scanRs485Module()">🔍 Harici 8-Kanal Röle Modülünü Tara</button>
    <button class="btn btn-secondary" onclick="controlExtRelay(1, 1, 2)">⚡ Modül Röle 1 Toggle</button>
    <button class="btn btn-secondary" onclick="controlExtRelay(1, 0, 1)">🟢 Modül Tümünü Aç</button>
    <button class="btn btn-secondary" onclick="controlExtRelay(1, 0, 0)">🔴 Modül Tümünü Kapat</button>
  </div>

  <div class="terminal-window" id="rs485Terminal">Terminal başlatılıyor...</div>

  <div style="display: flex; gap: 10px; flex-wrap: wrap;">
    <select id="rs485Format" style="width: 110px;">
      <option value="ascii">Metin (ASCII)</option>
      <option value="hex">HEX (Onyedi)</option>
    </select>
    <input type="text" id="rs485Input" placeholder="Gönderilecek veri (Örn: 01 03 00 00 00 02 C4 0B veya Ping)" style="flex: 1;">
    <button class="btn btn-primary" onclick="sendRs485()">Gönder</button>
  </div>
</div>

<!-- ================= TAB 5: SISTEM ================= -->
<div id="tab-system" class="content-section">
  <div class="card" style="max-width: 600px; margin: 0 auto; gap: 16px;">
    <h3 style="font-size: 16px;">ℹ️ Donanım ve Sistem Detayları</h3>
    <div style="font-size: 14px; line-height: 2;">
      <div><b>İşlemci:</b> ESP32-S3 (Xtensa LX7 Çift Çekirdek, 240 MHz)</div>
      <div><b>Flash Hafıza:</b> 16 MB QIO</div>
      <div><b>PSRAM:</b> 8 MB Octal</div>
      <div><b>AP Modu IP:</b> 192.168.4.1 (Varsayılan)</div>
      <div><b>Cihaz Adı:</b> <input type="text" id="sysDevName" style="width: 220px; display: inline-block; padding: 4px 8px;"></div>
    </div>
    <div style="display: flex; gap: 10px; margin-top: 10px;">
      <button class="btn btn-primary" onclick="saveDevName()">İsmi Güncelle</button>
      <button class="btn btn-secondary" onclick="rebootSystem()">🔄 Yeniden Başlat</button>
      <button class="btn btn-danger" onclick="resetSystem()">⚠️ Fabrika Ayarlarına Dön</button>
    </div>
  </div>
</div>

<div class="toast" id="toast">İşlem başarılı!</div>

<script>
let currentConfig = null;

function showToast(msg) {
  const t = document.getElementById('toast');
  t.innerText = msg;
  t.style.display = 'block';
  setTimeout(() => { t.style.display = 'none'; }, 2500);
}

function switchTab(tabId) {
  document.querySelectorAll('.nav-tab').forEach(t => t.classList.remove('active'));
  document.querySelectorAll('.content-section').forEach(s => s.classList.remove('active'));
  event.target.classList.add('active');
  document.getElementById('tab-' + tabId).classList.add('active');
  if (tabId === 'config') renderConfigTables();
  if (tabId === 'wifi') {
    scanWifi(false);
    fetchStatus();
  }
}

async function fetchStatus() {
  try {
    const res = await fetch('/api/status');
    const data = await res.json();
    
    document.getElementById('hdrDevName').innerText = data.device_name;
    document.getElementById('hdrIp').innerText = data.ip;
    document.getElementById('hdrRssi').innerText = data.wifi_rssi + ' dBm';
    
    const h = Math.floor(data.uptime_sec / 3600);
    const m = Math.floor((data.uptime_sec % 3600) / 60);
    const s = data.uptime_sec % 60;
    document.getElementById('hdrUptime').innerText = `${h}s ${m}d ${s}sn`;

    renderRelays(data);
    renderDIs(data.dis);
    renderWifiCard(data);
  } catch(e) {
    console.error("Durum alma hatasi:", e);
  }
}

function renderWifiCard(data) {
  const card = document.getElementById('wifiStatusCard');
  if (!card) return;

  const btnDisconnect = document.getElementById('btnWifiDisconnect');

  if (data.wifi_connected) {
    if (btnDisconnect) btnDisconnect.style.display = 'inline-flex';
    card.style.background = 'rgba(16, 185, 129, 0.08)';
    card.style.border = '1px solid rgba(16, 185, 129, 0.35)';
    card.innerHTML = `
      <div style="display: flex; align-items: flex-start; gap: 14px;">
        <div style="font-size: 28px; line-height: 1;">🟢</div>
        <div style="flex: 1;">
          <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 6px;">
            <div style="font-size: 15px; font-weight: 700; color: #10B981;">Modeme Bağlıyız (Ev Ağı Aktif)</div>
            <span style="background: rgba(16, 185, 129, 0.2); color: #34D399; font-size: 11px; padding: 2px 8px; border-radius: 12px; font-weight: 600;">ÇEVRİMİÇİ</span>
          </div>
          
          <div style="margin-top: 10px; font-size: 13px; line-height: 1.9; color: var(--text);">
            <div><b>Bağlı Bulunulan Ağ:</b> <span style="color: #60A5FA; font-weight: bold;">${data.wifi_sta_ssid || 'Bilinmiyor'}</span></div>
            <div><b>Cihazın IP Adresi:</b> <a href="http://${data.wifi_sta_ip}" target="_blank" style="color: #34D399; font-weight: bold; text-decoration: underline; background: rgba(16,185,129,0.15); padding: 2px 8px; border-radius: 6px;">http://${data.wifi_sta_ip}</a></div>
            <div><b>Sinyal Gücü:</b> <span style="font-weight: 600;">${data.wifi_sta_rssi} dBm</span> <span style="color: var(--text-muted); font-size: 12px;">(Çekim iyi)</span></div>
          </div>

          <div style="margin-top: 12px; padding: 10px 12px; background: rgba(0, 0, 0, 0.25); border-radius: 8px; font-size: 12px; color: var(--text-muted); border-left: 3px solid #10B981;">
            💡 <b>Başka bir ağa bağlanmak için:</b> Aşağıdaki listeden dilediğiniz yeni Wi-Fi ağını seçip şifresini yazarak <i>"Bağlan ve Kalıcı Kaydet"</i> butonuna tıklayabilirsiniz.
          </div>
        </div>
      </div>
    `;
  } else {
    if (btnDisconnect) btnDisconnect.style.display = 'none';
    card.style.background = 'rgba(245, 158, 11, 0.08)';
    card.style.border = '1px solid rgba(245, 158, 11, 0.35)';
    card.innerHTML = `
      <div style="display: flex; align-items: flex-start; gap: 14px;">
        <div style="font-size: 28px; line-height: 1;">📡</div>
        <div style="flex: 1;">
          <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 6px;">
            <div style="font-size: 15px; font-weight: 700; color: #F59E0B;">Yerel Erişim Noktası (AP Modu)</div>
            <span style="background: rgba(245, 158, 11, 0.2); color: #FBBF24; font-size: 11px; padding: 2px 8px; border-radius: 12px; font-weight: 600;">MODEME BAĞLI DEĞİL</span>
          </div>
          
          <div style="margin-top: 10px; font-size: 13px; line-height: 1.9; color: var(--text);">
            <div><b>Yayınlanan Wi-Fi:</b> <span style="font-weight: 600;">ESP32-S3-POE-ETH-8DI-8RO</span></div>
            <div><b>Mevcut Cihaz IP'si:</b> <span style="color: #F59E0B; font-weight: bold; background: rgba(245,158,11,0.15); padding: 2px 8px; border-radius: 6px;">192.168.4.1</span></div>
            <div><b>Durum:</b> Şu anda harici bir modeme bağlı değilsiniz; cihaz kendi Wi-Fi yayınıyla çalışıyor.</div>
          </div>

          <div style="margin-top: 12px; padding: 10px 12px; background: rgba(0, 0, 0, 0.25); border-radius: 8px; font-size: 12px; color: var(--text-muted); border-left: 3px solid #F59E0B;">
            👉 <b>Ev Ağına Bağlanmak İçin:</b> Aşağıdaki çevredeki ağlar listesinden ev Wi-Fi modeminizi seçin, şifrenizi girin ve <i>"Bağlan ve Kalıcı Kaydet"</i> butonuna tıklayın.
          </div>
        </div>
      </div>
    `;
  }
}

function getTotalRelayCount() {
  if (!currentConfig) return 8;
  return currentConfig.ext_module_enabled ? (8 + parseInt(currentConfig.ext_module_channels || 8)) : 8;
}

function ensureConfigArrays() {
  if (!currentConfig) return;
  if (!currentConfig.relays) currentConfig.relays = [];
  if (!currentConfig.dis) currentConfig.dis = [];
  const total = getTotalRelayCount();
  for (let i = 0; i < total; i++) {
    if (!currentConfig.relays[i]) {
      currentConfig.relays[i] = {
        id: i + 1,
        name: (i % 2 === 0) ? `Panjur ${Math.floor(i/2) + 1} (Yukari)` : `Panjur ${Math.floor(i/2) + 1} (Asagi)`,
        type: (i % 2 === 0) ? 1 : 2,
        runtime_sec: 20
      };
    }
    if (!currentConfig.dis[i]) {
      currentConfig.dis[i] = {
        id: i + 1,
        name: (i % 2 === 0) ? `Panjur ${Math.floor(i/2) + 1} Butonu` : `Giriş ${i + 1} (Boşta / Serbest)`,
        target_relay: (i % 2 === 0) ? (i + 1) : 0,
        mode: (i % 2 === 0) ? 2 : 0
      };
    }
  }
}

function updateExtModuleUI() {
  if (!currentConfig) return;
  const isEn = !!currentConfig.ext_module_enabled;
  const ch = parseInt(currentConfig.ext_module_channels || 8);
  const sw = document.getElementById('swExtModule');
  const opt = document.getElementById('extModuleOptions');
  const capLbl = document.getElementById('lblTotalCapacity');
  const selCh = document.getElementById('selExtChannels');
  const inpAddr = document.getElementById('inpExtAddr');
  const rTitle = document.getElementById('cfgRelayTitle');
  const dTitle = document.getElementById('cfgDITitle');

  if (sw) sw.classList.toggle('on', isEn);
  if (opt) opt.style.display = isEn ? 'block' : 'none';
  if (selCh) selCh.value = ch;
  if (inpAddr) inpAddr.value = currentConfig.ext_module_address || 1;

  const totalR = isEn ? (8 + ch) : 8;
  const totalP = totalR / 2;
  if (capLbl) capLbl.innerText = `${totalR} Röle / ${totalR} Giriş (${totalP} Çift)`;
  if (rTitle) rTitle.innerText = `⚙️ Röle Çıkış Yapılandırması (${totalR} Kanal - ${totalP} Çift)`;
  if (dTitle) dTitle.innerText = `🔘 Giriş Yapılandırması (${totalR} DI Duvar Butonları & Sensörler)`;
}

function toggleExtModule() {
  if (!currentConfig) return;
  currentConfig.ext_module_enabled = !currentConfig.ext_module_enabled;
  ensureConfigArrays();
  updateExtModuleUI();
  renderConfigTables();
}

function onExtChannelsChange(val) {
  if (!currentConfig) return;
  currentConfig.ext_module_channels = parseInt(val) || 8;
  ensureConfigArrays();
  updateExtModuleUI();
  renderConfigTables();
}

function onExtAddressChange(val) {
  if (!currentConfig) return;
  currentConfig.ext_module_address = parseInt(val) || 1;
}

function renderRelays(data) {
  const grid = document.getElementById('relaysGrid');
  grid.innerHTML = '';
  const numRelays = data.relays ? data.relays.length : 8;

  for (let i = 0; i < numRelays; i++) {
    const r = data.relays[i];
    if (!r) continue;
    
    // Eğer panjur çiftiyse ve ikinci kanalsa atla (çift kart olarak renderlanacak)
    if ((r.type === 1 || r.type === 2) && (i % 2 === 1)) {
      continue;
    }

    const isExt = (i >= 8);
    const modBadge = isExt ? `<span style="background: rgba(168, 85, 247, 0.15); color: #C084FC; font-size: 11px; padding: 2px 7px; border-radius: 6px; font-weight: 600;">📦 Ek Modül CH ${i - 7}</span>` : '';

    if (r.type === 1) { // Panjur Kartı
      const pairIdx = Math.floor(i / 2);
      const shutter = (data.shutters && data.shutters[pairIdx]) ? data.shutters[pairIdx] : { is_moving: false, dir: 0 };
      
      let stateBadge = `<span class="card-type-badge">⏹ Durdu</span>`;
      let indicatorClass = "status-indicator";
      if (shutter.is_moving) {
        indicatorClass += " moving";
        stateBadge = `<span class="card-type-badge" style="color: var(--accent); font-weight: bold;">` + 
          (shutter.dir === 1 ? '▲ Açılıyor...' : '▼ Kapanıyor...') + `</span>`;
      }

      grid.innerHTML += `
        <div class="card">
          <div class="card-header">
            <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">
              <span class="${indicatorClass}"></span>
              <span class="card-title">🪟 ${r.name.replace(/ \(Yukari\)/i, '')}</span>
              ${modBadge}
            </div>
            ${stateBadge}
          </div>
          <div class="shutter-controls">
            <button class="shutter-btn ${shutter.dir === 1 ? 'active' : ''}" onclick="cmdShutter(${pairIdx}, 'up')">▲ AÇ</button>
            <button class="shutter-btn" onclick="cmdShutter(${pairIdx}, 'stop')">⏹ DURDUR</button>
            <button class="shutter-btn ${shutter.dir === 2 ? 'active' : ''}" onclick="cmdShutter(${pairIdx}, 'down')">▼ KAPAT</button>
          </div>
        </div>
      `;
    } else { // Normal Lamba veya Darbe Rölesi
      const isLight = (r.type === 0);
      const icon = isLight ? '💡' : '⚡';
      const typeStr = isLight ? 'Aydınlatma' : 'Darbe (Tetik)';
      const onClass = r.state ? 'on' : '';
      
      grid.innerHTML += `
        <div class="card">
          <div class="card-header">
            <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">
              <span class="status-indicator ${onClass}"></span>
              <span class="card-title">${icon} ${r.name}</span>
              ${modBadge}
            </div>
            <span class="card-type-badge">${typeStr}</span>
          </div>
          <div style="display: flex; justify-content: space-between; align-items: center;">
            <span style="font-size: 13px; color: var(--text-muted);">Durum: <b>${r.state ? 'AÇIK' : 'KAPALI'}</b></span>
            ${isLight ? 
              `<div class="switch-btn ${onClass}" onclick="toggleRelay(${i})"><div class="switch-knob"></div></div>` :
              `<button class="btn btn-secondary" style="font-size: 12px; padding: 6px 12px;" onclick="triggerImpulse(${i})">⚡ Tetikle</button>`
            }
          </div>
        </div>
      `;
    }
  }
}

function renderDIs(dis) {
  const grid = document.getElementById('diGrid');
  grid.innerHTML = '';
  const numDIs = dis ? dis.length : 8;
  for (let i = 0; i < numDIs; i++) {
    const d = dis[i];
    if (!d) continue;
    const activeClass = d.state ? 'active' : '';
    const isExt = (i >= 8);
    grid.innerHTML += `
      <div class="di-pill ${activeClass}">
        <div style="display: flex; align-items: center; justify-content: center; gap: 4px;">
          <span>DI ${i + 1}</span>
          ${isExt ? `<span style="font-size: 10px; color: #C084FC;">(Ek)</span>` : ''}
        </div>
        <div style="font-size: 11px; opacity: 0.8; margin-top: 4px;">${d.state ? 'KAPALI (ON)' : 'AÇIK (OFF)'}</div>
      </div>
    `;
  }
}

async function toggleRelay(idx) {
  await fetch(`/api/relay?ch=${idx + 1}&cmd=toggle`, { method: 'POST' });
  fetchStatus();
}

async function triggerImpulse(idx) {
  await fetch(`/api/relay?ch=${idx + 1}&state=1`, { method: 'POST' });
  fetchStatus();
}

async function cmdShutter(pairIdx, action) {
  await fetch(`/api/relay?pair=${pairIdx}&cmd=${action}`, { method: 'POST' });
  fetchStatus();
}

async function cmdAll(cmd) {
  await fetch(`/api/all?cmd=${cmd}`, { method: 'POST' });
  showToast('Komut iletildi');
  fetchStatus();
}

async function loadConfig() {
  const res = await fetch('/api/config');
  currentConfig = await res.json();
  document.getElementById('sysDevName').value = currentConfig.device_name;
  document.getElementById('rs485Baud').value = currentConfig.rs485_baud;
  document.getElementById('wifiSsid').value = currentConfig.wifi_ssid;
  ensureConfigArrays();
  updateExtModuleUI();
  renderConfigTables();
}

function isPairShutter(p) {
  if (!currentConfig || !currentConfig.relays) return false;
  const r1 = p * 2, r2 = p * 2 + 1;
  if (!currentConfig.relays[r1] || !currentConfig.relays[r2]) return false;
  return (currentConfig.relays[r1].type === 1 || currentConfig.relays[r2].type === 2);
}

function getPairBaseName(p) {
  if (!currentConfig || !currentConfig.relays) return 'Panjur ' + (p + 1);
  const r1 = p * 2;
  if (!currentConfig.relays[r1]) return 'Panjur ' + (p + 1);
  return currentConfig.relays[r1].name.replace(/ \(Yukari\)| \(Asagi\)| Aydinlatma/gi, '').trim() || ('Panjur ' + (p + 1));
}

function setPairMode(p, toShutter) {
  if (!currentConfig) return;
  const r1 = p * 2, r2 = p * 2 + 1;
  const di1 = p * 2, di2 = p * 2 + 1;

  if (toShutter) {
    const baseName = getPairBaseName(p);
    currentConfig.relays[r1].type = 1;
    currentConfig.relays[r1].name = baseName + ' (Yukari)';
    currentConfig.relays[r2].type = 2;
    currentConfig.relays[r2].name = baseName + ' (Asagi)';
    if (!currentConfig.relays[r1].runtime_sec) currentConfig.relays[r1].runtime_sec = 20;
    currentConfig.relays[r2].runtime_sec = currentConfig.relays[r1].runtime_sec;

    currentConfig.dis[di1].name = baseName + ' Butonu';
    currentConfig.dis[di1].target_relay = r1 + 1;
    currentConfig.dis[di1].mode = 2; // DI_MODE_SHUTTER_STEP

    currentConfig.dis[di2].name = 'Giriş ' + (di2 + 1) + ' (Boşta / Serbest)';
    currentConfig.dis[di2].target_relay = 0; // Serbest
    currentConfig.dis[di2].mode = 0;
  } else {
    currentConfig.relays[r1].type = 0;
    currentConfig.relays[r1].name = 'Röle ' + (r1 + 1) + ' Aydınlatma';
    currentConfig.relays[r1].runtime_sec = 0;
    currentConfig.relays[r2].type = 0;
    currentConfig.relays[r2].name = 'Röle ' + (r2 + 1) + ' Aydınlatma';
    currentConfig.relays[r2].runtime_sec = 0;

    currentConfig.dis[di1].name = 'Giriş ' + (di1 + 1) + ' Butonu';
    currentConfig.dis[di1].target_relay = r1 + 1;
    currentConfig.dis[di1].mode = 0;

    currentConfig.dis[di2].name = 'Giriş ' + (di2 + 1) + ' Butonu';
    currentConfig.dis[di2].target_relay = r2 + 1;
    currentConfig.dis[di2].mode = 0;
  }
  renderConfigTables();
}

function setDIPairShutterWiring(p, wiringType) {
  if (!currentConfig) return;
  const di1 = p * 2, di2 = p * 2 + 1;
  const baseName = getPairBaseName(p);

  if (wiringType === 'single') {
    currentConfig.dis[di1].mode = 2; // DI_MODE_SHUTTER_STEP
    currentConfig.dis[di1].target_relay = di1 + 1;
    currentConfig.dis[di1].name = baseName + ' Butonu';

    currentConfig.dis[di2].target_relay = 0; // Serbest
    currentConfig.dis[di2].name = 'Giriş ' + (di2 + 1) + ' (Boşta / Serbest)';
    currentConfig.dis[di2].mode = 0;
  } else {
    currentConfig.dis[di1].mode = 3; // DI_MODE_SHUTTER_UP
    currentConfig.dis[di1].target_relay = di1 + 1;
    currentConfig.dis[di1].name = baseName + ' (Yukarı)';

    currentConfig.dis[di2].mode = 4; // DI_MODE_SHUTTER_DOWN
    currentConfig.dis[di2].target_relay = di1 + 2;
    currentConfig.dis[di2].name = baseName + ' (Aşağı)';
  }
  renderConfigTables();
}

function onPairNameInput(p, val) {
  if (!currentConfig) return;
  const r1 = p * 2, r2 = p * 2 + 1;
  const name = val.trim();
  currentConfig.relays[r1].name = name + ' (Yukari)';
  currentConfig.relays[r2].name = name + ' (Asagi)';
}

function onPairRuntimeInput(p, val) {
  if (!currentConfig) return;
  const num = parseInt(val) || 20;
  const r1 = p * 2, r2 = p * 2 + 1;
  currentConfig.relays[r1].runtime_sec = num;
  currentConfig.relays[r2].runtime_sec = num;
}

function onSingleNameInput(rIdx, val) {
  if (!currentConfig) return;
  currentConfig.relays[rIdx].name = val.trim();
}

function onSingleTypeChange(rIdx, val) {
  if (!currentConfig) return;
  const t = parseInt(val);
  currentConfig.relays[rIdx].type = t;
  if (t === 0) currentConfig.relays[rIdx].runtime_sec = 0;
  else if (t === 3 && !currentConfig.relays[rIdx].runtime_sec) currentConfig.relays[rIdx].runtime_sec = 500;
  renderConfigTables();
}

function onSingleRuntimeInput(rIdx, val) {
  if (!currentConfig) return;
  currentConfig.relays[rIdx].runtime_sec = parseInt(val) || 0;
}

function onFreeDITargetChange(diIdx, val) {
  if (!currentConfig) return;
  const targetId = parseInt(val);
  currentConfig.dis[diIdx].target_relay = targetId;
  currentConfig.dis[diIdx].mode = 0;
  if (targetId > 0) {
    currentConfig.dis[diIdx].name = currentConfig.relays[targetId - 1].name + ' Butonu';
  } else {
    currentConfig.dis[diIdx].name = 'Giriş ' + (diIdx + 1) + ' (Boşta / Serbest)';
  }
  renderConfigTables();
}

function renderRelayPairCard(p) {
  const r1 = p * 2, r2 = p * 2 + 1;
  const isShut = isPairShutter(p);
  const baseName = getPairBaseName(p);
  const runtime = currentConfig.relays[r1].runtime_sec || 20;
  const isExt = (p >= 4);

  let pairBadge = isExt ? 
    `<span style="background: rgba(168, 85, 247, 0.2); color: #C084FC; font-weight: 700; font-size: 13px; padding: 5px 12px; border-radius: 8px;">📦 Ek Modül - Çift ${p + 1} (Röle ${r1 + 1} & Röle ${r2 + 1}) [CH ${r1 - 7} & ${r2 - 7}]</span>` :
    `<span style="background: ${isShut ? 'rgba(59, 130, 246, 0.2)' : 'rgba(148, 163, 184, 0.15)'}; color: ${isShut ? '#60A5FA' : '#94a3b8'}; font-weight: 700; font-size: 13px; padding: 5px 12px; border-radius: 8px;">⚡ Ana Pano - Çift ${p + 1} (Röle ${r1 + 1} & Röle ${r2 + 1})</span>`;

  let pairHtml = `
    <div class="card" style="background: var(--card-bg); border: 1.5px solid ${isShut ? 'rgba(59, 130, 246, 0.45)' : 'var(--card-border)'}; border-radius: 14px; padding: 18px; gap: 14px;">
      <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 12px;">
        <div style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap;">
          ${pairBadge}
          <span style="font-size: 12.5px; color: var(--text-muted); font-weight: 600;">Çalışma Amacı:</span>
        </div>
        <div style="display: flex; gap: 6px; background: #0f172a; padding: 4px; border-radius: 10px; border: 1px solid var(--card-border);">
          <button type="button" class="btn ${isShut ? 'btn-primary' : 'btn-outline'}" style="padding: 6px 14px; font-size: 12.5px; border-radius: 7px;" onclick="setPairMode(${p}, true)">
            🪟 Panjur Motoru (Birleşik)
          </button>
          <button type="button" class="btn ${!isShut ? 'btn-primary' : 'btn-outline'}" style="padding: 6px 14px; font-size: 12.5px; border-radius: 7px;" onclick="setPairMode(${p}, false)">
            💡 Münferit / Ayrı Röleler
          </button>
        </div>
      </div>
  `;

  if (isShut) {
    pairHtml += `
      <div class="pair-grid">
        <div>
          <label style="font-size: 12.5px; color: var(--text-muted); font-weight: 600; display: block; margin-bottom: 6px;">🪟 Panjur Grubu Adı:</label>
          <input type="text" id="cfgPairName_${p}" value="${baseName}" placeholder="Örn: Panjur ${p + 1}" oninput="onPairNameInput(${p}, this.value)" style="font-size: 14.5px; font-weight: 600;">
          <div style="font-size: 12px; color: #60A5FA; margin-top: 8px; display: flex; align-items: center; gap: 14px; flex-wrap: wrap;">
            <span>▲ <b>Röle ${r1 + 1}:</b> Yukarı (Açma)</span>
            <span>▼ <b>Röle ${r2 + 1}:</b> Aşağı (Kapatma)</span>
            <span style="background: rgba(16, 185, 129, 0.15); color: #34D399; padding: 2px 8px; border-radius: 6px; font-size: 11px;">🔒 150ms Donanımsal Kilitlemeli</span>
          </div>
        </div>
        <div>
          <label style="font-size: 12.5px; color: var(--text-muted); font-weight: 600; display: block; margin-bottom: 6px;">Hareket Süresi (Motor Kapanma):</label>
          <div style="display: flex; align-items: center; gap: 8px;">
            <input type="number" id="cfgPairRuntime_${p}" value="${runtime}" oninput="onPairRuntimeInput(${p}, this.value)" style="width: 90px; text-align: center; font-weight: bold; font-size: 14.5px;">
            <span style="font-size: 13px; color: var(--text-muted);">saniye</span>
          </div>
          <div style="font-size: 11px; color: var(--text-muted); margin-top: 4px;">Süre dolunca motor otomatik durur.</div>
        </div>
      </div>
    `;
  } else {
    pairHtml += `
      <div class="grid-2col">
        <div style="background: #0f172a; padding: 14px; border-radius: 10px; border: 1px solid rgba(255,255,255,0.06); display: flex; flex-direction: column; gap: 10px;">
          <div style="display: flex; justify-content: space-between; align-items: center;">
            <span style="font-weight: 700; font-size: 13.5px; color: #93C5FD;">💡 Röle ${r1 + 1} (${isExt ? 'Ek Modül CH ' + (r1 - 7) : 'Pano Çıkışı'})</span>
            <span style="font-size: 11px; color: var(--text-muted);">Tekli Yük</span>
          </div>
          <input type="text" id="cfgRName_${r1}" value="${currentConfig.relays[r1].name}" oninput="onSingleNameInput(${r1}, this.value)" placeholder="Kanal Adı (Örn: Lamba ${r1 + 1})">
          <div style="display: flex; gap: 10px; align-items: center;">
            <div style="flex: 1;">
              <select id="cfgRType_${r1}" onchange="onSingleTypeChange(${r1}, this.value)">
                <option value="0" ${currentConfig.relays[r1].type===0?'selected':''}>💡 Normal Aydınlatma</option>
                <option value="3" ${currentConfig.relays[r1].type===3?'selected':''}>⚡ Darbe / Tetik (Kilit)</option>
              </select>
            </div>
            ${currentConfig.relays[r1].type === 3 ? `
              <div style="display: flex; align-items: center; gap: 6px; width: 115px;">
                <input type="number" id="cfgRRuntime_${r1}" value="${currentConfig.relays[r1].runtime_sec || 500}" oninput="onSingleRuntimeInput(${r1}, this.value)" placeholder="Süre" style="width: 75px; text-align: center;">
                <span style="font-size: 12px; color: var(--text-muted);">ms</span>
              </div>
            ` : `
              <input type="hidden" id="cfgRRuntime_${r1}" value="0">
            `}
          </div>
        </div>

        <div style="background: #0f172a; padding: 14px; border-radius: 10px; border: 1px solid rgba(255,255,255,0.06); display: flex; flex-direction: column; gap: 10px;">
          <div style="display: flex; justify-content: space-between; align-items: center;">
            <span style="font-weight: 700; font-size: 13.5px; color: #93C5FD;">💡 Röle ${r2 + 1} (${isExt ? 'Ek Modül CH ' + (r2 - 7) : 'Pano Çıkışı'})</span>
            <span style="font-size: 11px; color: var(--text-muted);">Tekli Yük</span>
          </div>
          <input type="text" id="cfgRName_${r2}" value="${currentConfig.relays[r2].name}" oninput="onSingleNameInput(${r2}, this.value)" placeholder="Kanal Adı (Örn: Lamba ${r2 + 1})">
          <div style="display: flex; gap: 10px; align-items: center;">
            <div style="flex: 1;">
              <select id="cfgRType_${r2}" onchange="onSingleTypeChange(${r2}, this.value)">
                <option value="0" ${currentConfig.relays[r2].type===0?'selected':''}>💡 Normal Aydınlatma</option>
                <option value="3" ${currentConfig.relays[r2].type===3?'selected':''}>⚡ Darbe / Tetik (Kilit)</option>
              </select>
            </div>
            ${currentConfig.relays[r2].type === 3 ? `
              <div style="display: flex; align-items: center; gap: 6px; width: 115px;">
                <input type="number" id="cfgRRuntime_${r2}" value="${currentConfig.relays[r2].runtime_sec || 500}" oninput="onSingleRuntimeInput(${r2}, this.value)" placeholder="Süre" style="width: 75px; text-align: center;">
                <span style="font-size: 12px; color: var(--text-muted);">ms</span>
              </div>
            ` : `
              <input type="hidden" id="cfgRRuntime_${r2}" value="0">
            `}
          </div>
        </div>
      </div>
    `;
  }
  pairHtml += `</div>`;
  return pairHtml;
}

function renderDIPairCard(p, totalRelays) {
  const di1 = p * 2, di2 = p * 2 + 1;
  const isShut = isPairShutter(p);
  const baseName = getPairBaseName(p);
  const isExt = (p >= 4);

  if (isShut) {
    const isSingle = (currentConfig.dis[di1].mode === 2 || currentConfig.dis[di2].mode !== 4);
    
    let freeRelayOptions = '';
    for (let r = 1; r <= totalRelays; r++) {
      if (r !== (p*2 + 1) && r !== (p*2 + 2)) {
        const rName = currentConfig.relays[r - 1].name;
        const sel = (currentConfig.dis[di2].target_relay === r) ? 'selected' : '';
        freeRelayOptions += `<option value="${r}" ${sel}>Röle ${r} (${rName})</option>`;
      }
    }

    let diBadge = isExt ?
      `<span style="background: rgba(168, 85, 247, 0.2); color: #C084FC; font-weight: 700; font-size: 13px; padding: 5px 12px; border-radius: 8px;">📦 Ek Modül - DI ${di1 + 1} & DI ${di2 + 1} [CH ${di1 - 7} & ${di2 - 7}]</span>` :
      `<span style="background: rgba(59, 130, 246, 0.2); color: #60A5FA; font-weight: 700; font-size: 13px; padding: 5px 12px; border-radius: 8px;">🔘 Ana Pano - DI ${di1 + 1} & DI ${di2 + 1}</span>`;

    return `
      <div class="card" style="background: var(--card-bg); border: 1.5px solid rgba(59, 130, 246, 0.4); border-radius: 14px; padding: 18px; gap: 14px;">
        <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 12px;">
          <div style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap;">
            ${diBadge}
            <span style="font-weight: 700; font-size: 14px; color: #F59E0B;">🪟 Hedef Panjur: ${baseName}</span>
          </div>
          <div style="font-size: 12px; color: var(--text-muted); font-weight: 600;">Duvardaki Tesisat Tipi:</div>
        </div>

        <!-- Tesisat Seçim Kartları -->
        <div class="grid-2col">
          <div class="mode-card ${isSingle ? 'selected' : ''}" onclick="setDIPairShutterWiring(${p}, 'single')">
            <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 6px;">
              <input type="radio" name="diWiring_${p}" value="single" ${isSingle ? 'checked' : ''} style="width:auto; margin:0;">
              <span style="font-weight: 700; font-size: 14px; color: #10B981;">🪟 1. Tesisat: Tek Butonla Kontrol (2 Kablo)</span>
            </div>
            <div style="font-size: 12px; color: var(--text-muted);">
              DI ${di1 + 1} tek yaylı butonla tüm panjuru yönetir. <b>DI ${di2 + 1} girişi boşa çıkar (serbest kalır).</b>
            </div>
          </div>

          <div class="mode-card ${!isSingle ? 'selected' : ''}" onclick="setDIPairShutterWiring(${p}, 'dual')">
            <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 6px;">
              <input type="radio" name="diWiring_${p}" value="dual" ${!isSingle ? 'checked' : ''} style="width:auto; margin:0;">
              <span style="font-weight: 700; font-size: 14px; color: #60A5FA;">⬆️⬇️ 2. Tesisat: Çift Tuşlu Anahtar (3 Kablo)</span>
            </div>
            <div style="font-size: 12px; color: var(--text-muted);">
              DI ${di1 + 1} Yukarı Aç, DI ${di2 + 1} Aşağı Kapat tuşu olarak iki ayrı klemens kullanılır.
            </div>
          </div>
        </div>

        ${isSingle ? `
          <!-- TEK BUTON SEÇİLDİĞİNDE -->
          <div class="grid-2col" style="margin-top: 4px;">
            <!-- DI 1: Panjur Butonu -->
            <div style="background: rgba(16, 185, 129, 0.06); border: 1px solid rgba(16, 185, 129, 0.25); border-radius: 10px; padding: 14px; display: flex; flex-direction: column; gap: 8px;">
              <div style="display: flex; justify-content: space-between; align-items: center;">
                <span style="font-weight: 700; font-size: 13.5px; color: #34D399;">🔘 DI ${di1 + 1} Panjur Butonu</span>
                <span style="background: rgba(16, 185, 129, 0.2); color: #34D399; font-size: 11px; padding: 2px 8px; border-radius: 6px; font-weight: bold;">Panjura Atandı</span>
              </div>
              <input type="text" id="cfgDIName_${di1}" value="${currentConfig.dis[di1].name}" oninput="currentConfig.dis[${di1}].name=this.value">
              <div style="font-size: 12px; color: var(--text-muted);">Çalışma: <b>Aç ➔ Dur ➔ Kapat ➔ Dur</b> döngüsü.</div>
              <div style="font-size: 11.5px; color: #34D399; margin-top: 4px;">🔌 <b>Bağlantı:</b> DGND ile DI ${di1 + 1} arasına 2 kablo ile yaylı anahtar bağlanır.</div>
            </div>

            <!-- DI 2: SERBEST / BOŞTA GİRİŞ -->
            <div style="background: rgba(59, 130, 246, 0.06); border: 1px dashed rgba(59, 130, 246, 0.4); border-radius: 10px; padding: 14px; display: flex; flex-direction: column; gap: 8px;">
              <div style="display: flex; justify-content: space-between; align-items: center;">
                <span style="font-weight: 700; font-size: 13.5px; color: #60A5FA;">🟢 DI ${di2 + 1} Girişi: SERBEST / BOŞTA</span>
                <span style="background: rgba(59, 130, 246, 0.2); color: #93C5FD; font-size: 11px; padding: 2px 8px; border-radius: 6px; font-weight: bold;">İsteğe Bağlı</span>
              </div>
              <div style="font-size: 12px; color: var(--text-muted); line-height: 1.4;">
                Panjur tek butonla yönetildiği için DI ${di2 + 1} klemensi <b>boştadır</b>. Dilerseniz başka bir aydınlatmaya atayabilirsiniz.
              </div>
              <div style="display: flex; align-items: center; gap: 8px; margin-top: 4px;">
                <span style="font-size: 12px; color: var(--text-muted); white-space: nowrap;">Tetikleyeceği Röle:</span>
                <select id="cfgDITarget_${di2}" onchange="onFreeDITargetChange(${di2}, this.value)">
                  <option value="0" ${currentConfig.dis[di2].target_relay === 0 ? 'selected' : ''}>-- Boşta (Röle Tetiklemez) --</option>
                  ${freeRelayOptions}
                </select>
              </div>
              ${currentConfig.dis[di2].target_relay > 0 ? `
                <div style="margin-top: 4px;">
                  <input type="text" id="cfgDIName_${di2}" value="${currentConfig.dis[di2].name}" oninput="currentConfig.dis[${di2}].name=this.value" placeholder="Buton Adı">
                  <div style="font-size: 11px; color: #34D399; margin-top: 4px;">🔌 DGND ile DI ${di2 + 1} arasına yaylı buton bağlanır.</div>
                </div>
              ` : ''}
            </div>
          </div>
        ` : `
          <!-- ÇİFT TUŞ SEÇİLDİĞİNDE -->
          <div class="grid-2col" style="margin-top: 4px;">
            <div style="background: rgba(59, 130, 246, 0.08); border: 1px solid rgba(59, 130, 246, 0.3); border-radius: 10px; padding: 14px; display: flex; flex-direction: column; gap: 8px;">
              <div style="display: flex; justify-content: space-between; align-items: center;">
                <span style="font-weight: 700; font-size: 13.5px; color: #60A5FA;">⬆️ DI ${di1 + 1}: YUKARI Açma Tuşu</span>
                <span style="background: rgba(59, 130, 246, 0.2); color: #93C5FD; font-size: 11px; padding: 2px 8px; border-radius: 6px; font-weight: bold;">Panjur Aç</span>
              </div>
              <input type="text" id="cfgDIName_${di1}" value="${currentConfig.dis[di1].name}" oninput="currentConfig.dis[${di1}].name=this.value">
              <div style="font-size: 12px; color: var(--text-muted);">Basınca yukarı açar, giderken basılırsa durdurur.</div>
            </div>

            <div style="background: rgba(245, 158, 11, 0.08); border: 1px solid rgba(245, 158, 11, 0.3); border-radius: 10px; padding: 14px; display: flex; flex-direction: column; gap: 8px;">
              <div style="display: flex; justify-content: space-between; align-items: center;">
                <span style="font-weight: 700; font-size: 13.5px; color: #F59E0B;">⬇️ DI ${di2 + 1}: AŞAĞI Kapatma Tuşu</span>
                <span style="background: rgba(245, 158, 11, 0.2); color: #FCD34D; font-size: 11px; padding: 2px 8px; border-radius: 6px; font-weight: bold;">Panjur Kapat</span>
              </div>
              <input type="text" id="cfgDIName_${di2}" value="${currentConfig.dis[di2].name}" oninput="currentConfig.dis[${di2}].name=this.value">
              <div style="font-size: 12px; color: var(--text-muted);">Basınca aşağı kapatır, inerken basılırsa durdurur.</div>
            </div>
          </div>
          <div style="font-size: 11.5px; color: #34D399; padding: 8px 12px; background: rgba(52, 211, 153, 0.08); border-radius: 8px;">
            🔌 <b>3 Kablolu Tesisat Bağlantısı:</b> Ortak uç <b>DGND</b>'ye, Yukarı tuşu <b>DI ${di1 + 1}</b>'e, Aşağı tuşu <b>DI ${di2 + 1}</b>'e bağlanır.
          </div>
        `}
      </div>
    `;
  } else {
    // Münferit Giriş Çifti
    return `
      <div class="card" style="background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 14px; padding: 18px; gap: 14px;">
        <div style="font-weight: 700; font-size: 13.5px; color: #94A3B8; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 10px;">
          🔘 Bağımsız Girişler: DI ${di1 + 1} ve DI ${di2 + 1} (${isExt ? 'Ek Modül' : 'Ana Pano'})
        </div>
        <div class="grid-2col">
          ${renderSingleDICard(di1, totalRelays)}
          ${renderSingleDICard(di2, totalRelays)}
        </div>
      </div>
    `;
  }
}

function renderConfigTables() {
  if (!currentConfig) return;

  const isExt = !!currentConfig.ext_module_enabled;
  const extCh = parseInt(currentConfig.ext_module_channels || 8);
  const totalRelays = getTotalRelayCount();
  const totalPairs = totalRelays / 2;

  // 1. Röle Çıkış Yapılandırması (Kanal Çiftleri)
  const rContainer = document.getElementById('cfgRelayPairsContainer');
  if (rContainer) {
    // Ana Modül Röleleri (0..3 çiftleri)
    let mainRelaysHtml = '';
    for (let p = 0; p < 4; p++) {
      mainRelaysHtml += renderRelayPairCard(p);
    }

    let fullRHtml = `
      <div style="background: rgba(30, 41, 59, 0.4); border: 1.5px solid rgba(59, 130, 246, 0.35); border-radius: 16px; padding: 20px; display: flex; flex-direction: column; gap: 16px;">
        <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 12px;">
          <div style="display: flex; align-items: center; gap: 10px;">
            <span style="font-size: 22px;">🏠</span>
            <div>
              <div style="font-size: 16px; font-weight: 700; color: #60A5FA;">Ana Cihaz Röle Çıkışları</div>
              <div style="font-size: 12px; color: var(--text-muted);">Yerel 8RO Pano Klemensleri (Röle 1 - 8)</div>
            </div>
          </div>
          <span style="background: rgba(59, 130, 246, 0.15); color: #93C5FD; font-size: 12px; padding: 4px 12px; border-radius: 8px; font-weight: 600;">8 Kanal / 4 Çift</span>
        </div>
        <div style="display: flex; flex-direction: column; gap: 14px;">
          ${mainRelaysHtml}
        </div>
      </div>
    `;

    // Ek Modül Röleleri (4..totalPairs-1 çiftleri)
    if (isExt && totalPairs > 4) {
      let extRelaysHtml = '';
      for (let p = 4; p < totalPairs; p++) {
        extRelaysHtml += renderRelayPairCard(p);
      }
      fullRHtml += `
        <div style="background: rgba(30, 41, 59, 0.4); border: 1.5px solid rgba(168, 85, 247, 0.45); border-radius: 16px; padding: 20px; display: flex; flex-direction: column; gap: 16px; margin-top: 10px;">
          <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 12px;">
            <div style="display: flex; align-items: center; gap: 10px;">
              <span style="font-size: 22px;">📦</span>
              <div>
                <div style="font-size: 16px; font-weight: 700; color: #C084FC;">Harici RS485 Ek Modül Röleleri</div>
                <div style="font-size: 12px; color: var(--text-muted);">RS485 Genişletme Kartı Çıkışları (Röle 9 - ${totalRelays}) • Slave ID: ${currentConfig.ext_module_address || 1}</div>
              </div>
            </div>
            <span style="background: rgba(168, 85, 247, 0.15); color: #E9D5FF; font-size: 12px; padding: 4px 12px; border-radius: 8px; font-weight: 600;">Ek ${extCh} Kanal / ${extCh / 2} Çift</span>
          </div>
          <div style="display: flex; flex-direction: column; gap: 14px;">
            ${extRelaysHtml}
          </div>
        </div>
      `;
    }
    rContainer.innerHTML = fullRHtml;
  }

  // 2. Giriş Yapılandırması (Kanal Çiftleri)
  const diContainer = document.getElementById('cfgDIPairsContainer');
  if (diContainer) {
    // Ana Modül Girişleri (0..3 çiftleri)
    let mainDIsHtml = '';
    for (let p = 0; p < 4; p++) {
      mainDIsHtml += renderDIPairCard(p, totalRelays);
    }

    let fullDIHtml = `
      <div style="background: rgba(30, 41, 59, 0.4); border: 1.5px solid rgba(59, 130, 246, 0.35); border-radius: 16px; padding: 20px; display: flex; flex-direction: column; gap: 16px;">
        <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 12px;">
          <div style="display: flex; align-items: center; gap: 10px;">
            <span style="font-size: 22px;">🏠</span>
            <div>
              <div style="font-size: 16px; font-weight: 700; color: #60A5FA;">Ana Cihaz Girişleri (Duvar Butonları)</div>
              <div style="font-size: 12px; color: var(--text-muted);">Yerel 8DI Duvar Butonu ve Sensör Klemensleri (DI 1 - 8)</div>
            </div>
          </div>
          <span style="background: rgba(59, 130, 246, 0.15); color: #93C5FD; font-size: 12px; padding: 4px 12px; border-radius: 8px; font-weight: 600;">8 Giriş / 4 Çift</span>
        </div>
        <div style="display: flex; flex-direction: column; gap: 14px;">
          ${mainDIsHtml}
        </div>
      </div>
    `;

    // Ek Modül Girişleri (4..totalPairs-1 çiftleri)
    if (isExt && totalPairs > 4) {
      let extDIsHtml = '';
      for (let p = 4; p < totalPairs; p++) {
        extDIsHtml += renderDIPairCard(p, totalRelays);
      }
      fullDIHtml += `
        <div style="background: rgba(30, 41, 59, 0.4); border: 1.5px solid rgba(168, 85, 247, 0.45); border-radius: 16px; padding: 20px; display: flex; flex-direction: column; gap: 16px; margin-top: 10px;">
          <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 12px;">
            <div style="display: flex; align-items: center; gap: 10px;">
              <span style="font-size: 22px;">📦</span>
              <div>
                <div style="font-size: 16px; font-weight: 700; color: #C084FC;">Harici RS485 Ek Modül Girişleri</div>
                <div style="font-size: 12px; color: var(--text-muted);">RS485 Genişletme Kartı Girişleri (DI 9 - DI ${totalRelays})</div>
              </div>
            </div>
            <span style="background: rgba(168, 85, 247, 0.15); color: #E9D5FF; font-size: 12px; padding: 4px 12px; border-radius: 8px; font-weight: 600;">Ek ${extCh} Giriş / ${extCh / 2} Çift</span>
          </div>
          <div style="display: flex; flex-direction: column; gap: 14px;">
            ${extDIsHtml}
          </div>
        </div>
      `;
    }
    diContainer.innerHTML = fullDIHtml;
  }
}

function renderSingleDICard(diIdx, totalRelays) {
  const d = currentConfig.dis[diIdx];
  if (!totalRelays) totalRelays = getTotalRelayCount();
  let targetOpts = '<option value="0" ' + (d.target_relay === 0 ? 'selected' : '') + '>-- Devre Dışı (Röle Tetiklemez) --</option>';
  for (let r = 1; r <= totalRelays; r++) {
    targetOpts += `<option value="${r}" ${d.target_relay === r ? 'selected' : ''}>Röle ${r} (${currentConfig.relays[r - 1].name})</option>`;
  }

  const targetType = (d.target_relay > 0) ? currentConfig.relays[d.target_relay - 1].type : -1;
  let typeInfo = '';
  if (d.target_relay === 0) {
    typeInfo = '<div style="font-size: 12px; color: var(--text-muted);">⚪ Boşta (Herhangi bir röleye bağlı değil)</div>';
  } else if (targetType === 0) {
    typeInfo = '<div style="font-size: 12px; color: #60A5FA;">💡 <b>Standart Lamba Butonu</b> (Bas-aç / bas-kapat). 🔌 DGND ile DI arasına bağlanır.</div>';
  } else if (targetType === 3) {
    typeInfo = '<div style="font-size: 12px; color: #F59E0B;">⚡ <b>Darbe / Tetik Butonu</b> (Kapı kilidi). 🔌 DGND ile DI arasına bağlanır.</div>';
  } else {
    typeInfo = '<div style="font-size: 12px; color: #10B981;">🪟 Panjur Kontrolü (Tek Buton Döngü: Aç-Dur-Kapat-Dur).</div>';
  }

  return `
    <div style="background: #0f172a; padding: 14px; border-radius: 10px; border: 1px solid rgba(255,255,255,0.06); display: flex; flex-direction: column; gap: 8px;">
      <div style="display: flex; justify-content: space-between; align-items: center;">
        <span style="font-weight: 700; font-size: 13.5px; color: #60A5FA;">🔘 DI ${diIdx + 1} Girişi</span>
        <span style="font-size: 11px; color: var(--text-muted);">Tekli Buton</span>
      </div>
      <input type="text" id="cfgDIName_${diIdx}" value="${d.name}" oninput="currentConfig.dis[${diIdx}].name=this.value" placeholder="Giriş Adı">
      <div style="display: flex; align-items: center; gap: 8px;">
        <span style="font-size: 12px; color: var(--text-muted); white-space: nowrap;">Tetikle:</span>
        <select id="cfgDITarget_${diIdx}" onchange="onSingleDITargetChange(${diIdx}, this.value)">${targetOpts}</select>
      </div>
      ${typeInfo}
    </div>
  `;
}

function onSingleDITargetChange(diIdx, val) {
  if (!currentConfig) return;
  const tId = parseInt(val);
  currentConfig.dis[diIdx].target_relay = tId;
  if (tId === 0) currentConfig.dis[diIdx].mode = 0;
  else {
    const tType = currentConfig.relays[tId - 1].type;
    if (tType === 1 || tType === 2) currentConfig.dis[diIdx].mode = 2;
    else if (tType === 3) currentConfig.dis[diIdx].mode = 1;
    else currentConfig.dis[diIdx].mode = 0;
  }
  renderConfigTables();
}

async function saveRelayConfig() {
  if (!currentConfig) return;
  const totalPairs = getTotalRelayCount() / 2;
  for (let p = 0; p < totalPairs; p++) {
    const r1 = p * 2, r2 = p * 2 + 1;
    if (isPairShutter(p)) {
      const elName = document.getElementById(`cfgPairName_${p}`);
      if (elName) {
        const val = elName.value.trim() || ('Panjur ' + (p + 1));
        currentConfig.relays[r1].name = val + ' (Yukari)';
        currentConfig.relays[r2].name = val + ' (Asagi)';
      }
      const elRt = document.getElementById(`cfgPairRuntime_${p}`);
      if (elRt) {
        const rt = parseInt(elRt.value) || 20;
        currentConfig.relays[r1].runtime_sec = rt;
        currentConfig.relays[r2].runtime_sec = rt;
      }
    } else {
      const elN1 = document.getElementById(`cfgRName_${r1}`);
      if (elN1) currentConfig.relays[r1].name = elN1.value.trim();
      const elT1 = document.getElementById(`cfgRType_${r1}`);
      if (elT1) currentConfig.relays[r1].type = parseInt(elT1.value);
      const elRt1 = document.getElementById(`cfgRRuntime_${r1}`);
      if (elRt1) currentConfig.relays[r1].runtime_sec = parseInt(elRt1.value) || 0;

      const elN2 = document.getElementById(`cfgRName_${r2}`);
      if (elN2) currentConfig.relays[r2].name = elN2.value.trim();
      const elT2 = document.getElementById(`cfgRType_${r2}`);
      if (elT2) currentConfig.relays[r2].type = parseInt(elT2.value);
      const elRt2 = document.getElementById(`cfgRRuntime_${r2}`);
      if (elRt2) currentConfig.relays[r2].runtime_sec = parseInt(elRt2.value) || 0;
    }
  }
  await postConfig();
}

async function saveDIConfig() {
  if (!currentConfig) return;
  const totalDIs = getTotalRelayCount();
  for (let i = 0; i < totalDIs; i++) {
    const elName = document.getElementById(`cfgDIName_${i}`);
    if (elName) currentConfig.dis[i].name = elName.value.trim();
  }
  await postConfig();
}

async function postConfig() {
  await fetch('/api/config', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(currentConfig)
  });
  showToast('Ayarlar NVS hafızasına kaydedildi!');
  fetchStatus();
}

async function scanWifi(forceRefresh = false) {
  const statusEl = document.getElementById('scanStatus');
  const sel = document.getElementById('wifiScanSelect');
  if (forceRefresh) {
    statusEl.innerText = 'Çevredeki ağlar taranıyor (lütfen 2-3 sn bekleyin)...';
    sel.innerHTML = '<option value="">🔄 Ağlar taranıyor...</option>';
  }

  try {
    let url = '/api/wifi/scan' + (forceRefresh ? '?refresh=1' : '');
    let res = await fetch(url);
    let data = await res.json();

    let attempts = 0;
    while (data.status === 'scanning' && attempts < 8) {
      await new Promise(r => setTimeout(r, 1200));
      attempts++;
      res = await fetch('/api/wifi/scan');
      data = await res.json();
    }

    if (data.status === 'done' && data.networks && data.networks.length > 0) {
      statusEl.innerText = `${data.networks.length} adet 2.4 GHz ağ bulundu:`;
      sel.innerHTML = '<option value="">-- Listeden Bir Ağ Seçin --</option>';
      data.networks.forEach(n => {
        sel.innerHTML += `<option value="${n.ssid}">📶 ${n.ssid} (${n.rssi} dBm ${n.enc ? '🔒' : '🔓'})</option>`;
      });
      const curSsid = document.getElementById('wifiSsid').value;
      if (curSsid) {
        for (let i = 0; i < sel.options.length; i++) {
          if (sel.options[i].value === curSsid) {
            sel.selectedIndex = i;
            break;
          }
        }
      }
    } else {
      statusEl.innerText = 'Ağ listelenemedi. Yenile butonuna basabilir veya doğrudan aşağıya yazabilirsiniz.';
    }
  } catch (e) {
    statusEl.innerText = 'Aşağıdaki kutuya doğrudan ev Wi-Fi adınızı yazabilirsiniz.';
  }
}

function selectScannedWifi() {
  const sel = document.getElementById('wifiScanSelect');
  if (sel.value) document.getElementById('wifiSsid').value = sel.value;
}

async function connectWifi() {
  const ssid = document.getElementById('wifiSsid').value;
  const pass = document.getElementById('wifiPass').value;
  if (!ssid) return alert("Lütfen Wi-Fi adı girin.");

  showToast('Modeme bağlanılıyor, lütfen bekleyin...');
  await fetch('/api/wifi/connect', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ssid: ssid, pass: pass })
  });
  setTimeout(fetchStatus, 3000);
  setTimeout(fetchStatus, 6000);
}

async function disconnectWifi() {
  if (!confirm("Cihazın modem bağlantısı kesilsin mi? (Yalnızca kendi AP yayını aktif kalacaktır)")) return;
  showToast('Modem bağlantısı kesiliyor...');
  await fetch('/api/wifi/disconnect', { method: 'POST' });
  setTimeout(fetchStatus, 1500);
}

async function refreshRs485Logs() {
  try {
    const res = await fetch('/api/rs485/logs');
    const text = await res.text();
    const term = document.getElementById('rs485Terminal');
    term.innerText = text || "Henüz veri akışı yok.";
    term.scrollTop = term.scrollHeight;
  } catch(e) {}
}

async function sendRs485() {
  const fmt = document.getElementById('rs485Format').value;
  const val = document.getElementById('rs485Input').value;
  if (!val) return;

  await fetch('/api/rs485/send', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ data: val, isHex: (fmt === 'hex') })
  });
  document.getElementById('rs485Input').value = '';
  refreshRs485Logs();
}

async function clearRs485Logs() {
  await fetch('/api/rs485/clear', { method: 'POST' });
  refreshRs485Logs();
}

async function changeRs485Baud() {
  const baud = document.getElementById('rs485Baud').value;
  await fetch('/api/rs485/baud', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ baud: parseInt(baud) })
  });
  showToast(`RS485 baud rate ${baud} olarak ayarlandı.`);
  refreshRs485Logs();
}

async function scanRs485Module() {
  showToast('Harici 8-kanal modül taranıyor...');
  try {
    const res = await fetch('/api/rs485/scan', { method: 'POST' });
    const data = await res.json();
    if (data.found) {
      showToast(`Modül Bulundu! Adres: ${data.slaveId}, Baud: ${data.baud}`);
    } else {
      showToast('Modülden yanıt alınamadı. A/B kablolarını ve beslemeyi kontrol edin.');
    }
  } catch (e) {
    showToast('Tarama hatası!');
  }
  refreshRs485Logs();
}

async function controlExtRelay(slaveId, channel, action) {
  try {
    const res = await fetch('/api/rs485/relay', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ slaveId, channel, action })
    });
    const data = await res.json();
    if (data.success) {
      showToast(`Modül Röle ${channel || 'Tümü'} komutu uygulandı.`);
    } else {
      showToast('Modülden onay yanıtı alınamadı!');
    }
  } catch(e) {
    showToast('İletişim hatası!');
  }
  refreshRs485Logs();
}

async function saveDevName() {
  const name = document.getElementById('sysDevName').value;
  currentConfig.device_name = name;
  await postConfig();
}

async function rebootSystem() {
  if (confirm("Cihaz yeniden başlatılsın mı?")) {
    await fetch('/api/system/reboot', { method: 'POST' });
    showToast("Cihaz yeniden başlatılıyor...");
  }
}

async function resetSystem() {
  if (confirm("Tüm ayarlar fabrika ayarlarına döndürülsün mü?")) {
    await fetch('/api/system/reset', { method: 'POST' });
    showToast("Fabrika ayarlarına dönüldü.");
    setTimeout(() => location.reload(), 2000);
  }
}

// Başlatıcı
fetchStatus();
loadConfig();
setInterval(fetchStatus, 1500);
setInterval(refreshRs485Logs, 2000);
</script>
</body>
</html>
)rawliteral";

WebPortal& WebPortal::instance() {
  static WebPortal instance;
  return instance;
}

WebPortal::WebPortal() : _server(80) {}

void WebPortal::begin() {
  setupRoutes();
  _server.begin();
  printf("WebPortal: Web sunucusu 80 portunda baslatildi.\r\n");
}

void WebPortal::loop() {
  _server.handleClient();
}

void WebPortal::setupRoutes() {
  _server.on("/", HTTP_GET, std::bind(&WebPortal::handleRoot, this));
  _server.on("/api/status", HTTP_GET, std::bind(&WebPortal::handleApiStatus, this));
  _server.on("/api/relay", HTTP_POST, std::bind(&WebPortal::handleApiRelay, this));
  _server.on("/api/all", HTTP_POST, std::bind(&WebPortal::handleApiAll, this));
  _server.on("/api/config", HTTP_GET, std::bind(&WebPortal::handleApiConfigGet, this));
  _server.on("/api/config", HTTP_POST, std::bind(&WebPortal::handleApiConfigSave, this));
  _server.on("/api/wifi/scan", HTTP_GET, std::bind(&WebPortal::handleApiWifiScan, this));
  _server.on("/api/wifi/connect", HTTP_POST, std::bind(&WebPortal::handleApiWifiConnect, this));
  _server.on("/api/wifi/disconnect", HTTP_POST, std::bind(&WebPortal::handleApiWifiDisconnect, this));
  _server.on("/api/rs485/send", HTTP_POST, std::bind(&WebPortal::handleApiRs485Send, this));
  _server.on("/api/rs485/logs", HTTP_GET, std::bind(&WebPortal::handleApiRs485Logs, this));
  _server.on("/api/rs485/clear", HTTP_POST, std::bind(&WebPortal::handleApiRs485Clear, this));
  _server.on("/api/rs485/baud", HTTP_POST, std::bind(&WebPortal::handleApiRs485Baud, this));
  _server.on("/api/rs485/scan", HTTP_POST, std::bind(&WebPortal::handleApiRs485Scan, this));
  _server.on("/api/rs485/relay", HTTP_POST, std::bind(&WebPortal::handleApiRs485Relay, this));
  _server.on("/api/system/reboot", HTTP_POST, std::bind(&WebPortal::handleApiReboot, this));
  _server.on("/api/system/reset", HTTP_POST, std::bind(&WebPortal::handleApiReset, this));
}

void WebPortal::storeScanResults(int n) {
  if (n <= 0) return;
  _cachedNetworks.clear();
  for (int i = 0; i < n && i < 25; i++) {
    String ssid = WiFi.SSID(i);
    if (ssid.length() == 0) continue;
    ScannedAp ap;
    ap.ssid = ssid;
    ap.rssi = WiFi.RSSI(i);
    ap.enc = (WiFi.encryptionType(i) != WIFI_AUTH_OPEN);
    _cachedNetworks.push_back(ap);
  }
}

void WebPortal::handleRoot() {
  _server.sendHeader("Cache-Control", "no-cache, no-store, must-revalidate");
  _server.sendHeader("Pragma", "no-cache");
  _server.sendHeader("Expires", "-1");
  _server.send_P(200, "text/html; charset=utf-8", INDEX_HTML);
}

void WebPortal::handleApiStatus() {
  DynamicJsonDocument doc(4096);
  auto& cfg = ConfigManager::instance().config;
  auto& autoMgr = SmartAutomation::instance();

  uint8_t totalR = cfg.totalRelays();
  uint8_t totalPairs = totalR / 2;
  uint8_t totalD = cfg.totalDIs();

  bool staConnected = (WiFi.status() == WL_CONNECTED);
  doc["device_name"] = cfg.device_name;
  doc["ip"] = staConnected ? WiFi.localIP().toString() : WiFi.softAPIP().toString();
  doc["wifi_rssi"] = staConnected ? WiFi.RSSI() : 0;
  doc["uptime_sec"] = millis() / 1000;
  doc["wifi_connected"] = staConnected;
  doc["wifi_sta_ssid"] = staConnected ? WiFi.SSID() : (cfg.wifi_sta_enabled ? String(cfg.wifi_ssid) : "");
  doc["wifi_sta_ip"] = staConnected ? WiFi.localIP().toString() : "";
  doc["wifi_sta_rssi"] = staConnected ? WiFi.RSSI() : 0;
  doc["wifi_ap_ip"] = WiFi.softAPIP().toString();
  doc["wifi_ap_ssid"] = "ESP32-S3-POE-ETH-8DI-8RO";

  doc["ext_module_enabled"] = cfg.ext_module_enabled;
  doc["ext_module_channels"] = cfg.ext_module_channels;
  doc["ext_module_address"] = cfg.ext_module_address;
  doc["total_relays"] = totalR;
  doc["total_dis"] = totalD;

  JsonArray rArr = doc.createNestedArray("relays");
  for (int i = 0; i < totalR; i++) {
    JsonObject r = rArr.createNestedObject();
    r["id"] = i + 1;
    r["name"] = cfg.relays[i].name;
    r["type"] = cfg.relays[i].type;
    r["state"] = autoMgr.getRelayState(i);
  }

  JsonArray sArr = doc.createNestedArray("shutters");
  for (int p = 0; p < totalPairs; p++) {
    JsonObject s = sArr.createNestedObject();
    ShutterState st = autoMgr.getShutterState(p);
    s["pair"] = p;
    s["is_moving"] = st.is_moving;
    s["dir"] = st.direction;
  }

  JsonArray dArr = doc.createNestedArray("dis");
  for (int i = 0; i < totalD; i++) {
    JsonObject d = dArr.createNestedObject();
    d["id"] = i + 1;
    d["name"] = cfg.dis[i].name;
    d["state"] = autoMgr.getDIState(i);
  }

  String json;
  serializeJson(doc, json);
  _server.send(200, "application/json", json);
}

void WebPortal::handleApiRelay() {
  auto& autoMgr = SmartAutomation::instance();
  uint8_t totalR = ConfigManager::instance().config.totalRelays();
  uint8_t totalPairs = totalR / 2;

  if (_server.hasArg("pair") && _server.hasArg("cmd")) {
    uint8_t pairIdx = _server.arg("pair").toInt();
    if (pairIdx < totalPairs) {
      String cmd = _server.arg("cmd");
      if (cmd == "up") autoMgr.shutterUp(pairIdx);
      else if (cmd == "down") autoMgr.shutterDown(pairIdx);
      else if (cmd == "stop") autoMgr.shutterStop(pairIdx);
      _server.send(200, "application/json", "{\"status\":\"ok\"}");
      return;
    }
  }

  if (_server.hasArg("ch")) {
    uint8_t ch = _server.arg("ch").toInt();
    if (ch >= 1 && ch <= totalR) {
      uint8_t rIdx = ch - 1;
      if (_server.hasArg("cmd") && _server.arg("cmd") == "toggle") {
        autoMgr.toggleRelay(rIdx);
      } else if (_server.hasArg("state")) {
        bool st = (_server.arg("state").toInt() == 1);
        autoMgr.setRelayState(rIdx, st);
      }
      _server.send(200, "application/json", "{\"status\":\"ok\"}");
      return;
    }
  }

  _server.send(400, "application/json", "{\"error\":\"Gecersiz parametre\"}");
}

void WebPortal::handleApiAll() {
  if (_server.hasArg("cmd")) {
    String cmd = _server.arg("cmd");
    auto& autoMgr = SmartAutomation::instance();
    if (cmd == "lightsoff") autoMgr.allLightsOff();
    else if (cmd == "shuttersdown") autoMgr.allShuttersDown();
    else if (cmd == "shuttersup") autoMgr.allShuttersUp();
    else if (cmd == "shuttersstop") autoMgr.allShuttersStop();
    _server.send(200, "application/json", "{\"status\":\"ok\"}");
    return;
  }
  _server.send(400, "application/json", "{\"error\":\"Eksik komut\"}");
}

void WebPortal::handleApiConfigGet() {
  DynamicJsonDocument doc(8192);
  auto& cfg = ConfigManager::instance().config;

  uint8_t totalR = cfg.totalRelays();
  uint8_t totalD = cfg.totalDIs();

  doc["device_name"] = cfg.device_name;
  doc["wifi_ssid"] = cfg.wifi_ssid;
  doc["wifi_sta_enabled"] = cfg.wifi_sta_enabled;
  doc["rs485_baud"] = cfg.rs485_baud;

  doc["ext_module_enabled"] = cfg.ext_module_enabled;
  doc["ext_module_channels"] = cfg.ext_module_channels;
  doc["ext_module_address"] = cfg.ext_module_address;
  doc["total_relays"] = totalR;
  doc["total_dis"] = totalD;

  JsonArray rArr = doc.createNestedArray("relays");
  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    JsonObject r = rArr.createNestedObject();
    r["id"] = i + 1;
    r["name"] = cfg.relays[i].name;
    r["type"] = cfg.relays[i].type;
    r["runtime_sec"] = cfg.relays[i].runtime_sec;
  }

  JsonArray dArr = doc.createNestedArray("dis");
  for (int i = 0; i < MAX_TOTAL_DIS; i++) {
    JsonObject d = dArr.createNestedObject();
    d["id"] = i + 1;
    d["name"] = cfg.dis[i].name;
    d["target_relay"] = cfg.dis[i].target_relay;
    d["mode"] = cfg.dis[i].mode;
  }

  String json;
  serializeJson(doc, json);
  _server.send(200, "application/json", json);
}

void WebPortal::handleApiConfigSave() {
  if (!_server.hasArg("plain")) {
    _server.send(400, "application/json", "{\"error\":\"Gövde bos\"}");
    return;
  }

  DynamicJsonDocument doc(4096);
  DeserializationError err = deserializeJson(doc, _server.arg("plain"));
  if (err) {
    _server.send(400, "application/json", "{\"error\":\"JSON ayrıştırma hatası\"}");
    return;
  }

  auto& cfg = ConfigManager::instance().config;

  if (doc.containsKey("device_name")) {
    strncpy(cfg.device_name, doc["device_name"], sizeof(cfg.device_name) - 1);
  }

  if (doc.containsKey("ext_module_enabled")) {
    cfg.ext_module_enabled = doc["ext_module_enabled"].as<bool>();
  }
  if (doc.containsKey("ext_module_channels")) {
    cfg.ext_module_channels = doc["ext_module_channels"].as<uint8_t>();
  }
  if (doc.containsKey("ext_module_address")) {
    cfg.ext_module_address = doc["ext_module_address"].as<uint8_t>();
  }

  if (doc.containsKey("relays")) {
    JsonArray rArr = doc["relays"];
    for (int i = 0; i < MAX_TOTAL_RELAYS && i < rArr.size(); i++) {
      JsonObject r = rArr[i];
      if (r.containsKey("name")) strncpy(cfg.relays[i].name, r["name"], sizeof(cfg.relays[i].name) - 1);
      if (r.containsKey("type")) cfg.relays[i].type = r["type"];
      if (r.containsKey("runtime_sec")) cfg.relays[i].runtime_sec = r["runtime_sec"];
    }
  }

  if (doc.containsKey("dis")) {
    JsonArray dArr = doc["dis"];
    for (int i = 0; i < MAX_TOTAL_DIS && i < dArr.size(); i++) {
      JsonObject d = dArr[i];
      if (d.containsKey("name")) strncpy(cfg.dis[i].name, d["name"], sizeof(cfg.dis[i].name) - 1);
      if (d.containsKey("target_relay")) cfg.dis[i].target_relay = d["target_relay"];
      if (d.containsKey("mode")) cfg.dis[i].mode = d["mode"];
    }
  }

  ConfigManager::instance().save();
  _server.send(200, "application/json", "{\"status\":\"ok\"}");
}

static bool _scanInProgress = false;
static uint32_t _scanStartTime = 0;

void WebPortal::handleApiWifiScan() {
  if (!(WiFi.getMode() & WIFI_MODE_STA)) {
    WiFi.mode(WIFI_AP_STA);
    delay(50);
  }

  bool forceRefresh = _server.hasArg("refresh");

  // Eğer zorunlu yenileme istenmediyse ve önbellekte ağlar varsa ANINDA DÖNDÜR!
  if (!forceRefresh && !_cachedNetworks.empty() && !_scanInProgress) {
    DynamicJsonDocument doc(2560);
    JsonObject root = doc.to<JsonObject>();
    root["status"] = "done";
    JsonArray arr = root.createNestedArray("networks");

    for (size_t i = 0; i < _cachedNetworks.size(); i++) {
      JsonObject net = arr.createNestedObject();
      net["ssid"] = _cachedNetworks[i].ssid;
      net["rssi"] = _cachedNetworks[i].rssi;
      net["enc"] = _cachedNetworks[i].enc;
    }

    String json;
    serializeJson(doc, json);
    _server.send(200, "application/json", json);
    return;
  }

  int16_t status = WiFi.scanComplete();

  if (!_scanInProgress) {
    WiFi.scanDelete();
    WiFi.scanNetworks(true, false, false, 300);
    _scanInProgress = true;
    _scanStartTime = millis();
    _server.send(200, "application/json", "{\"status\":\"scanning\"}");
    return;
  }

  // Halen taranıyor ve 4.5 saniye geçmemişse bekle
  if (status == WIFI_SCAN_RUNNING || (status < 0 && (millis() - _scanStartTime < 4500))) {
    _server.send(200, "application/json", "{\"status\":\"scanning\"}");
    return;
  }

  // Tarama tamamlandı
  _scanInProgress = false;
  if (status > 0) {
    storeScanResults(status);
  }
  WiFi.scanDelete();

  DynamicJsonDocument doc(2560);
  JsonObject root = doc.to<JsonObject>();
  root["status"] = "done";
  JsonArray arr = root.createNestedArray("networks");

  for (size_t i = 0; i < _cachedNetworks.size(); i++) {
    JsonObject net = arr.createNestedObject();
    net["ssid"] = _cachedNetworks[i].ssid;
    net["rssi"] = _cachedNetworks[i].rssi;
    net["enc"] = _cachedNetworks[i].enc;
  }

  String json;
  serializeJson(doc, json);
  _server.send(200, "application/json", json);
}

void WebPortal::handleApiWifiConnect() {
  if (!_server.hasArg("plain")) {
    _server.send(400, "application/json", "{\"error\":\"Gövde bos\"}");
    return;
  }

  DynamicJsonDocument doc(512);
  deserializeJson(doc, _server.arg("plain"));

  const char* ssid = doc["ssid"];
  const char* pass = doc["pass"];

  if (!ssid) {
    _server.send(400, "application/json", "{\"error\":\"SSID zorunludur\"}");
    return;
  }

  auto& cfg = ConfigManager::instance().config;
  strncpy(cfg.wifi_ssid, ssid, sizeof(cfg.wifi_ssid) - 1);
  if (pass) strncpy(cfg.wifi_pass, pass, sizeof(cfg.wifi_pass) - 1);
  else cfg.wifi_pass[0] = '\0';
  cfg.wifi_sta_enabled = true;
  ConfigManager::instance().save();

  WiFi.begin(cfg.wifi_ssid, cfg.wifi_pass);
  _server.send(200, "application/json", "{\"status\":\"connecting\"}");
}

void WebPortal::handleApiWifiDisconnect() {
  auto& cfg = ConfigManager::instance().config;
  cfg.wifi_sta_enabled = false;
  cfg.wifi_ssid[0] = '\0';
  cfg.wifi_pass[0] = '\0';
  ConfigManager::instance().save();
  WiFi.disconnect(true);
  _server.send(200, "application/json", "{\"status\":\"ok\"}");
}

void WebPortal::handleApiRs485Send() {
  if (!_server.hasArg("plain")) {
    _server.send(400, "application/json", "{\"error\":\"Gövde bos\"}");
    return;
  }

  DynamicJsonDocument doc(512);
  deserializeJson(doc, _server.arg("plain"));

  String data = doc["data"].as<String>();
  bool isHex = doc["isHex"] | false;

  bool ok = SmartAutomation::instance().rs485Send(data, isHex);
  _server.send(200, "application/json", ok ? "{\"status\":\"ok\"}" : "{\"error\":\"Gönderilemedi\"}");
}

void WebPortal::handleApiRs485Logs() {
  _server.send(200, "text/plain; charset=utf-8", SmartAutomation::instance().rs485GetLogs());
}

void WebPortal::handleApiRs485Clear() {
  SmartAutomation::instance().rs485ClearLogs();
  _server.send(200, "application/json", "{\"status\":\"ok\"}");
}

void WebPortal::handleApiRs485Baud() {
  if (!_server.hasArg("plain")) return;
  DynamicJsonDocument doc(256);
  deserializeJson(doc, _server.arg("plain"));
  uint32_t baud = doc["baud"] | 9600;

  ConfigManager::instance().config.rs485_baud = baud;
  ConfigManager::instance().save();
  SmartAutomation::instance().rs485Begin(baud);
  _server.send(200, "application/json", "{\"status\":\"ok\"}");
}

void WebPortal::handleApiRs485Scan() {
  auto res = SmartAutomation::instance().rs485ScanModule();
  DynamicJsonDocument doc(512);
  doc["found"] = res.found;
  doc["slaveId"] = res.slaveId;
  doc["baud"] = res.baud;
  doc["relayStatus"] = res.relayStatus;
  doc["rawHex"] = res.rawHex;
  doc["info"] = res.info;
  String out;
  serializeJson(doc, out);
  _server.send(200, "application/json", out);
}

void WebPortal::handleApiRs485Relay() {
  if (!_server.hasArg("plain")) {
    _server.send(400, "application/json", "{\"error\":\"Missing body\"}");
    return;
  }
  DynamicJsonDocument doc(256);
  deserializeJson(doc, _server.arg("plain"));
  uint8_t sid = doc["slaveId"] | 1;
  uint8_t ch = doc["channel"] | 1;
  uint8_t action = doc["action"] | 2; // 1: ON, 0: OFF, 2: TOGGLE
  String resp;
  bool ok = SmartAutomation::instance().rs485ControlExtRelay(sid, ch, action, &resp);
  DynamicJsonDocument respDoc(256);
  respDoc["success"] = ok;
  respDoc["responseHex"] = resp;
  String out;
  serializeJson(respDoc, out);
  _server.send(200, "application/json", out);
}

void WebPortal::handleApiReboot() {
  _server.send(200, "application/json", "{\"status\":\"rebooting\"}");
  delay(500);
  ESP.restart();
}

void WebPortal::handleApiReset() {
  ConfigManager::instance().resetToDefaults();
  ConfigManager::instance().save();
  _server.send(200, "application/json", "{\"status\":\"reset_ok\"}");
  delay(500);
  ESP.restart();
}

