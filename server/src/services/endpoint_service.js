const db = require('../db');
const deviceService = require('./device_service');

class EndpointService {
  async getEndpointsByHome(homeId) {
    const numericHomeId = parseInt(homeId, 10);
    if (isNaN(numericHomeId)) {
      return [];
    }
    const res = await db.query(
      `SELECT e.*, d.mac_address, d.device_uuid, COALESCE(d.is_online, false) as device_online
       FROM endpoints e
       LEFT JOIN devices d ON e.device_id = d.id
       WHERE e.home_id = $1
       ORDER BY e.channel_index ASC`,
      [numericHomeId]
    );
    return res.rows;
  }

  async updateEndpoint(homeId, endpointId, { name, room, type, shutter_duration_sec }) {
    const res = await db.query(
      `UPDATE endpoints
       SET name = COALESCE($1, name),
           room = COALESCE($2, room),
           type = COALESCE($3, type),
           shutter_duration_sec = COALESCE($4, shutter_duration_sec),
           updated_at = CURRENT_TIMESTAMP
       WHERE id = $5 AND home_id = $6
       RETURNING *`,
      [name, room, type, shutter_duration_sec, endpointId, homeId]
    );

    if (res.rows.length === 0) {
      const err = new Error('Kontrol noktasi bulunamadi');
      err.statusCode = 404;
      throw err;
    }
    return res.rows[0];
  }

  async controlEndpoint(homeId, endpointId, commandData) {
    const epRes = await db.query(
      'SELECT * FROM endpoints WHERE id = $1 AND home_id = $2',
      [endpointId, homeId]
    );

    if (epRes.rows.length === 0) {
      const err = new Error('Kontrol noktasi bulunamadi');
      err.statusCode = 404;
      throw err;
    }

    const endpoint = epRes.rows[0];
    let mqttPayload = {};

    if (endpoint.type === 'shutter') {
      const pair = endpoint.shutter_pair_index || Math.ceil(endpoint.channel_index / 2);
      if (commandData.pos !== undefined) {
        mqttPayload = { shutter: pair, pos: parseInt(commandData.pos, 10) };
      } else if (commandData.cmd) {
        mqttPayload = { shutter: pair, cmd: commandData.cmd }; // 'up', 'down', 'stop', 'step'
      }
    } else {
      // Normal lamba / priz / darbe
      if (commandData.cmd === 'toggle') {
        mqttPayload = { relay: endpoint.channel_index, cmd: 'toggle' };
      } else if (commandData.state !== undefined) {
        mqttPayload = { relay: endpoint.channel_index, state: commandData.state === true || commandData.state === 'true' };
      }
    }

    return await deviceService.sendCommand(homeId, endpoint.device_id, mqttPayload);
  }
}

module.exports = new EndpointService();

