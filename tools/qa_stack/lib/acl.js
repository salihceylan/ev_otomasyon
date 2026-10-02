// MQTT topic filtre eslesmesi ve ACL degerlendirmesi (EMQX davranisi taklidi, CONTRACTS §2.2).
//
// Kurallar (mqtt_acl satirlari): { permission: 'allow'|'deny', action: 'publish'|'subscribe'|'all', topic }
//  - deny ONCELIKLIDIR: eslesen herhangi bir deny varsa sonuc deny.
//  - Eslesen allow yoksa deny (zero trust).
//  - ${username} / %u gibi yer tutucular GENISLETILMEZ (kurallar somut konular icerir).
//  - Yayin: konu adi, kural filtresiyle MQTT kurallarina gore eslesir.
//  - Abonelik: abonelik FILTRESI kural filtresinin alt kumesi olmalidir (ev/+/state aboneligi,
//    "ev/h_1/state" kuralindan genis oldugu icin reddedilir; "ev/#" kurali onu kapsar).

/** Joker karakterler yalnizca tam seviye olarak ve # yalnizca sonda gecerlidir. */
export function isValidFilter(filter) {
  if (typeof filter !== 'string' || filter.length === 0) return false;
  const words = filter.split('/');
  for (let i = 0; i < words.length; i++) {
    const w = words[i];
    if (w === '#') {
      if (i !== words.length - 1) return false;
    } else if (w.includes('#') || (w.includes('+') && w !== '+')) {
      return false;
    }
  }
  return true;
}

export function isValidTopicName(name) {
  return typeof name === 'string' && name.length > 0 && !name.includes('+') && !name.includes('#');
}

const startsWithWildcard = (firstWord) => firstWord === '+' || firstWord === '#';

/** Yayin konusu (ad) bir filtreyle eslesiyor mu? */
export function topicMatchesFilter(topic, filter) {
  if (!isValidTopicName(topic) || !isValidFilter(filter)) return false;
  const t = topic.split('/');
  const f = filter.split('/');
  if (t[0].startsWith('$') && startsWithWildcard(f[0])) return false; // [MQTT-4.7.2-1]
  for (let i = 0; i < f.length; i++) {
    if (f[i] === '#') return true;
    if (i >= t.length) return false;
    if (f[i] === '+') continue;
    if (f[i] !== t[i]) return false;
  }
  return t.length === f.length;
}

/** Abonelik filtresi (sub), kural filtresinin (rule) kapsadigi konularin alt kumesi mi? */
export function filterCoveredByRule(sub, rule) {
  if (!isValidFilter(sub) || !isValidFilter(rule)) return false;
  const s = sub.split('/');
  const r = rule.split('/');
  if (s[0].startsWith('$') && startsWithWildcard(r[0])) return false;
  for (let i = 0; i < r.length; i++) {
    if (r[i] === '#') return true;
    if (i >= s.length) return false;
    if (s[i] === '#') return false;   // abonelik daha derin seviyeleri de kapsar, kural kapsamaz
    if (r[i] === '+') continue;
    if (s[i] === '+') return false;   // abonelik, tekil kural kelimesinden genis
    if (s[i] !== r[i]) return false;
  }
  return s.length === r.length;
}

function actionApplies(ruleAction, action) {
  const a = String(ruleAction ?? '').trim().toLowerCase();
  return a === 'all' || a === action;
}

/**
 * @param {{permission:string, action:string, topic:string}[]} rules
 * @param {{action:'publish'|'subscribe', topic:string}} req
 * @returns {{allowed:boolean, reason:string, rule?:object}}
 */
export function evaluateAcl(rules, { action, topic }) {
  const match = action === 'subscribe' ? filterCoveredByRule : topicMatchesFilter;
  let allowRule = null;
  for (const rule of rules || []) {
    const perm = String(rule.permission ?? '').trim().toLowerCase();
    if (perm !== 'allow' && perm !== 'deny') continue;
    if (!actionApplies(rule.action, action)) continue;
    if (!match(topic, rule.topic)) continue;
    if (perm === 'deny') return { allowed: false, reason: 'deny_rule', rule };
    if (!allowRule) allowRule = rule;
  }
  if (allowRule) return { allowed: true, reason: 'allow_rule', rule: allowRule };
  return { allowed: false, reason: !rules || rules.length === 0 ? 'no_rules' : 'no_match' };
}
