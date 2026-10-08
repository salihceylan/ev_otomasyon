// Firmware NetLinkCore (src/NetLinkCore.h) + NetUtil::ApPolicy Ethernet girdisi + ApAccess 8 parametreli clientOnSoftAp JS portlarinin UYUMLULUK
// testi: firmware Unity testinin (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_net_link/test_main.cpp) simulatorun kullandigi ALT
// KUMESININ portu (Ethernet olay gecisleri, DNS ve MQTT arayuz degisimi simulatorde modellenmez; bkz. sim/fw/net_link.js).
import test from 'node:test';
import assert from 'node:assert/strict';
import { ethUp, requestViaEth, activeIf, netIfName, statusIp, apPolicyEthUp, NetIf } from '../sim/fw/net_link.js';
import { clientOnSoftAp, ipToU32 } from '../sim/fw/ap_access.js';
import { ApPolicy } from '../sim/fw/net_time.js';

const ip = (s) => ipToU32(s);
const MASK24 = ip('255.255.255.0');
const up = (a, mask = MASK24) => ({ started: true, link: true, hasIp: true, ip: ip(a), mask });

test('fw_net_link: Ethernet yokken her karar Wi-Fi-only davranisiyla ayni; etkin arayuz ve durum ip', () => {
  const none = { started: false, link: false, hasIp: false, ip: 0, mask: 0 };
  assert.equal(ethUp(none), false);
  for (const wifi of [false, true]) {
    assert.equal(statusIp(wifi, ip('192.168.1.20'), ethUp(none), 0, ip('192.168.4.1')), wifi ? ip('192.168.1.20') : ip('192.168.4.1'));
    assert.equal(netIfName(activeIf(wifi, ethUp(none))), wifi ? 'wifi' : 'none');
  }
  assert.equal(activeIf(true, true), NetIf.WIFI, 'Wi-Fi oncelikli');
  assert.equal(netIfName(activeIf(false, true)), 'eth');
  assert.equal(statusIp(false, 0, true, ip('192.168.10.57'), ip('192.168.4.1')), ip('192.168.10.57'));
  assert.equal(ethUp({ started: true, link: true, hasIp: true, ip: 0 }), false, 'adres 0: bagli degil');
  assert.equal(ethUp({ started: true, link: false, hasIp: true, ip: ip('192.168.10.57') }), false, 'kablo yok');
});

test('fw_net_link: istek Ethernet\'ten yalniz yerel uc Ethernet IP\'si iken (Unity: test_request_arrived_via_ethernet_only_when_local_ip_is_the_eth_ip)', () => {
  const none = { started: false, link: false, hasIp: false, ip: 0, mask: 0 };
  assert.equal(requestViaEth(none, ip('192.168.1.57')), false);
  assert.equal(requestViaEth(none, 0), false);
  const s = up('192.168.10.57');
  assert.equal(requestViaEth(s, ip('192.168.10.57')), true);
  assert.equal(requestViaEth(s, ip('192.168.1.20')), false, 'Wi-Fi STA IP\'sine geldi');
  assert.equal(requestViaEth(s, ip('192.168.4.1')), false, 'SoftAP\'e geldi');
  assert.equal(requestViaEth(s, 0), false);
  assert.equal(requestViaEth({ ...s, link: false }, ip('192.168.10.57')), false, 'kablo cekildi');
});

test('fw_net_link: SoftAP istemcisi Ethernet IP\'sine istek -> Ethernet SAYILMAZ; gercek Ethernet istemcisi etkilenmez (pano-3)', () => {
  const ethIp = ip('192.168.10.57');
  const apIp = ip('192.168.4.1');
  const s = up('192.168.10.57');
  const apClient = clientOnSoftAp(true, ip('192.168.4.2'), apIp, MASK24, 0, 0, ethIp, MASK24);
  assert.equal(apClient, true);
  assert.equal(requestViaEth(s, ethIp), true, 'eski olcut: yalniz yerel uc');
  assert.equal(requestViaEth(s, ethIp, apClient), false);
  const lanClient = clientOnSoftAp(true, ip('192.168.10.20'), apIp, MASK24, 0, 0, ethIp, MASK24);
  assert.equal(lanClient, false);
  assert.equal(requestViaEth(s, ethIp, lanClient), true);
  // LAN da 192.168.4.0/24 ise (AP alt agiyla cakisma) istemci AP sayilmaz: Ethernet karari eskisi gibi
  const o = up('192.168.4.57');
  const overlap = clientOnSoftAp(true, ip('192.168.4.20'), apIp, MASK24, 0, 0, ip('192.168.4.57'), MASK24);
  assert.equal(overlap, false);
  assert.equal(requestViaEth(o, ip('192.168.4.57'), overlap), true);
  assert.equal(requestViaEth(s, ip('192.168.1.20'), false), false);
  assert.equal(requestViaEth({ started: false, link: false, hasIp: false, ip: 0 }, ethIp, false), false);
});

// ---- Kurtarma AP penceresi + Ethernet (NetUtil::ApPolicy, v1.3.0) ----
class ApSim {
  constructor(allowed, staConfigured) {
    this.p = new ApPolicy();
    this.in = ApPolicy.makeIn();
    this.in.allowed = allowed;
    this.in.staConfigured = staConfigured;
    this.apOn = false;
    this.opens = 0;
    this.onMs = 0;
  }
  run(t0, t1) {
    for (let t = t0; t < t1; t += 250) {
      this.in.apActive = this.apOn;
      const o = this.p.update(t >>> 0, this.in);
      if (o.opened) this.opens++;
      if (o.startAp) this.apOn = true;
      if (o.stopAp) this.apOn = false;
      if (this.apOn) this.onMs += 250;
    }
  }
}
const MIN = 60000;

test('fw_net_link: provizyonlu yalniz-Ethernet kart kurtarma AP\'sini hic dongulemez; kayitli Wi-Fi dusukken Ethernet bagliysa tetik yok', () => {
  const a = new ApSim(true, false);
  a.in.ethUp = apPolicyEthUp(true, true);
  a.run(0, 180 * MIN);
  assert.deepEqual([a.opens, a.onMs, a.apOn], [0, 0, false]);
  const b = new ApSim(true, true);
  b.in.connected = false;
  b.in.ethUp = apPolicyEthUp(true, true);
  b.run(0, 120 * MIN);
  assert.equal(b.opens, 0);
});

test('fw_net_link: Ethernet yokken v1.2.1 dongusu; provizyonsuz kart kablo takiliyken de kurulum AP\'si acar', () => {
  const a = new ApSim(true, false);
  a.run(0, 60 * MIN);
  assert.ok(a.opens >= 2);
  const u = new ApSim(true, false);
  u.in.ethUp = apPolicyEthUp(true, false);
  assert.equal(u.in.ethUp, false);
  u.run(0, 1000);
  assert.deepEqual([u.apOn, u.opens], [true, 1]);
});

test('fw_net_link: acik pencere provizyonlu kartta Ethernet gelince 30 sn kararlilikta erken kapanir; kablo cekilince yeniden acilir', () => {
  const a = new ApSim(true, false);
  a.run(0, 2000);
  assert.equal(a.apOn, true);
  a.in.ethUp = apPolicyEthUp(true, true);
  a.run(2000, 2000 + 29000);
  assert.equal(a.apOn, true, '30 sn kararlilik dolmadi');
  a.run(31000, 31000 + 2000);
  assert.equal(a.apOn, false, 'kararli: pencere erken kapandi');
  a.run(33000, 33000 + 90 * MIN);
  assert.equal(a.apOn, false, 'yeniden acilmadi');
  a.in.ethUp = false;
  const t = 33000 + 90 * MIN;
  a.run(t, t + 2000);
  assert.equal(a.apOn, true);
});
