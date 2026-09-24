const express = require('express');
const cors = require('cors');
require('dotenv').config();

const db = require('./db');
const mqttBridge = require('./mqtt_bridge');

const authRoutes = require('./routes/auth_routes');
const deviceRoutes = require('./routes/device_routes');
const serviceRoutes = require('./routes/service_routes');
const endpointRoutes = require('./routes/endpoint_routes');
const inventoryRoutes = require('./routes/inventory_routes');
const invitationRoutes = require('./routes/invitation_routes');
const transferRoutes = require('./routes/transfer_routes');
const scheduledRulesRoutes = require('./routes/scheduled_rules_routes');
const adminRoutes = require('./routes/admin_routes');

const app = express();
const PORT = process.env.PORT || 5000;

// Middlewares
app.use(cors());
app.use(express.json());

// Saglik Kontrolu (Health Check)
app.get('/health', async (req, res) => {
  let dbStatus = 'down';
  try {
    const dbRes = await db.query('SELECT NOW() as time');
    if (dbRes.rows.length > 0) dbStatus = 'healthy';
  } catch (e) {
    dbStatus = 'error: ' + e.message;
  }

  const mqttStatus = mqttBridge.isConnected() ? 'healthy' : 'disconnected';

  res.status(dbStatus === 'healthy' ? 200 : 503).json({
    status: dbStatus === 'healthy' ? 'healthy' : 'degraded',
    service: 'AHBU Ev Otomasyonu Backend API',
    version: '1.0.0',
    timestamp: new Date().toISOString(),
    components: {
      database: dbStatus,
      mqtt_bridge: mqttStatus,
    },
  });
});

const { authenticateToken } = require('./middlewares/auth_middleware');
const authService = require('./services/auth_service');
const { successResponse, errorResponse } = require('./utils/helpers');

// API Rotalari
app.use('/api/auth', authRoutes);
app.use('/api/v1/auth', authRoutes);
app.use('/api/devices', deviceRoutes);
app.use('/api/v1/devices', deviceRoutes);

// Ev Listesi (GET /api/homes ve GET /api/v1/homes)
const handleGetHomes = async (req, res) => {
  try {
    const result = await authService.getProfile(req.user.id);
    return successResponse(res, result.homes);
  } catch (err) {
    return errorResponse(res, err.message, 500);
  }
};
app.get('/api/homes', authenticateToken, handleGetHomes);
app.get('/api/v1/homes', authenticateToken, handleGetHomes);

app.use('/api/homes/:home_id', serviceRoutes);
app.use('/api/v1/homes/:home_id', serviceRoutes);
app.use('/api/homes/:home_id/endpoints', endpointRoutes);
app.use('/api/v1/homes/:home_id/endpoints', endpointRoutes);
app.use('/api/v1/admin/inventory', inventoryRoutes);
app.use('/api/admin/inventory', inventoryRoutes);
app.use('/api/v1/admin', adminRoutes);
app.use('/api/admin', adminRoutes);
app.use('/api/v1', invitationRoutes);
app.use('/api', invitationRoutes);
app.use('/api/v1', transferRoutes);
app.use('/api', transferRoutes);
app.use('/api/homes', scheduledRulesRoutes);
app.use('/api/v1/homes', scheduledRulesRoutes);

// Global 404
app.use('*', (req, res) => {
  res.status(404).json({ success: false, message: 'Istenen API ucu bulunamadi' });
});

// Global Hata Yakalayici
app.use((err, req, res, next) => {
  console.error('[GLOBAL-ERROR]', err);
  res.status(err.statusCode || 500).json({
    success: false,
    message: err.message || 'Sunucu hatasi meydana geldi',
  });
});

// Sunucuyu Baslat
app.listen(PORT, '0.0.0.0', () => {
  console.log(`\r\n==================================================`);
  console.log(`  AHBU Akilli Ev API Sunucusu Calisiyor (Port ${PORT})`);
  console.log(`  Saglik Kontrolu: http://127.0.0.1:${PORT}/health`);
  console.log(`==================================================\r\n`);

  // MQTT Koprusunu Baslat
  mqttBridge.init();

  // Zamanli Otomasyon Kural Motoru — her dakika calisir
  let cronScheduler = null;
  try {
    const cron = require('node-cron');
    const scheduledRulesService = require('./services/scheduled_rules_service');

    cronScheduler = cron.schedule('* * * * *', async () => {
      try {
        const rules = await scheduledRulesService.getRulesDueNow();
        if (rules.length === 0) return;

        console.log(`[CRON] ${rules.length} zamanli kural tetikleniyor...`);
        for (const rule of rules) {
          if (!rule.home_mqtt_username) continue;
          const topic = `ev/${rule.home_mqtt_username}/cmd`;

          const payload = {
            source: 'scheduled_rule',
            rule_id: rule.id,
            channel: rule.channel,
            channel_type: rule.channel_type,
            action: rule.action,
          };

          try {
            await mqttBridge.publishToTopic(topic, payload);
            console.log(`[CRON] Kural #${rule.id} → ${topic} | ch:${rule.channel} ${rule.action}`);
          } catch (pubErr) {
            console.error(`[CRON] Kural #${rule.id} MQTT hatasi:`, pubErr.message);
          }
        }
      } catch (cronErr) {
        console.error('[CRON] Zamanlı kural motoru hatası:', cronErr.message);
      }
    });

    console.log('  Zamanli Kural Motoru (CRON): Her dakika aktif');
  } catch (cronLoadErr) {
    console.warn('  [UYARI] node-cron yuklenemedi, zamanli kurallar pasif:', cronLoadErr.message);
    console.warn('  Yuklemek icin: npm install node-cron');
  }
});

