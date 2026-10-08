// Firmware src/NetLinkCore.h JS portu -- ALT KUME (simulatorun kullandigi kararlar): Ethernet "bagli" karari, yerel API isteginin kablolu
// Ethernet'ten gelip gelmedigi (kullanici karari 2026-10-08 + pano-3), etkin arayuz adi ve tam durum "ip" alani. Olay gecisleri (ethApply),
// DNS/MQTT arayuz degisimi PORTLANMADI (simulator Ethernet suruculerini modellemez; bkz. lib/fwcheck.js).
// IPv4 adresleri firmware ile ayni uint32 gosterimindedir (ilk sekizli en dusuk bayt; ap_access.js ipToU32).

export const NetIf = Object.freeze({ NONE: 0, WIFI: 1, ETH: 2 });

export const netIfName = (i) => (i === NetIf.WIFI ? 'wifi' : i === NetIf.ETH ? 'eth' : 'none');

/** Ethernet bagli: surucu basladi + PHY baglantisi + DHCP adresi. s: {started, link, hasIp, ip} */
export function ethUp(s) {
  return !!(s && s.started && s.link && s.hasIp && (s.ip >>> 0) !== 0);
}

/**
 * Istek kablolu Ethernet'ten mi geldi? Yerel uc Ethernet IP'si VE (verildiyse) istemci SoftAP istemcisi DEGIL (pano-3: bir AP istemcisinin panonun
 * Ethernet IP'sine baglantisi "kablodan" sayilmaz; anahtarsiz yetki yalniz kablodan gelenler icindir).
 */
export function requestViaEth(s, localIp, remoteOnAp = false) {
  if (remoteOnAp) return false;
  const l = localIp >>> 0;
  return l !== 0 && ethUp(s) && l === (s.ip >>> 0);
}

export const activeIf = (wifiUp, ethIsUp) => (wifiUp ? NetIf.WIFI : ethIsUp ? NetIf.ETH : NetIf.NONE);

/**
 * Kurtarma AP politikasi Ethernet girdisi (NetUtil::ApPolicy In.ethUp): provizyonlu kartta Ethernet bagliyken ag "bagli" sayilir (pencere acilmaz /
 * acik pencere kararli baglantida kapanir); PROVIZYONSUZ kartta Ethernet sayilmaz (kurulum AP'si kablo takiliyken de acilir).
 */
export const apPolicyEthUp = (ethIsUp, provisioned) => !!(ethIsUp && provisioned);

/** Tam /api/status "ip": etkin arayuzun IP'si; ag yoksa AP IP'si. */
export function statusIp(wifiUp, wifiIp, ethIsUp, ethIp, apIp) {
  switch (activeIf(wifiUp, ethIsUp)) {
    case NetIf.WIFI: return wifiIp;
    case NetIf.ETH: return ethIp;
    default: return apIp;
  }
}
