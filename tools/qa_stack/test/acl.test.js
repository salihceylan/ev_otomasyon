// EMQX topic filtresi eslesmesi ve ACL degerlendirmesi (CONTRACTS §2.2).
import test from 'node:test';
import assert from 'node:assert/strict';
import { topicMatchesFilter, filterCoveredByRule, evaluateAcl } from '../lib/acl.js';

test('topicMatchesFilter: tam eslesme, + ve # joker karakterleri', () => {
  const T = [
    ['ev/h_1/state', 'ev/h_1/state', true],
    ['ev/h_1/state', 'ev/h_2/state', false],
    ['ev/h_1/state', 'ev/+/state', true],
    ['ev/h_1/x/state', 'ev/+/state', false],
    ['ev/state', 'ev/+/state', false],
    ['ev/h_1/state', 'ev/#', true],
    ['ev', 'ev/#', true],            // a/# ust seviyeyi de eslestirir
    ['ev/', 'ev/#', true],
    ['x/ev', 'ev/#', false],
    ['ev/h_1/state', '#', true],
    ['a//b', 'a/+/b', true],         // bos seviye + ile eslesir
    ['a/b', 'a/b/', false],
    ['a/b/c', 'a/b', false],
    ['a', 'a/b', false],
  ];
  for (const [topic, filter, expected] of T) {
    assert.equal(topicMatchesFilter(topic, filter), expected, `${topic} ~ ${filter}`);
  }
});

test('topicMatchesFilter: $ ile baslayan konulari ilk seviye joker eslestirmez', () => {
  assert.equal(topicMatchesFilter('$SYS/x', '#'), false);
  assert.equal(topicMatchesFilter('$SYS/x', '+/x'), false);
  assert.equal(topicMatchesFilter('$SYS/x', '$SYS/#'), true);
  assert.equal(topicMatchesFilter('$SYS/x', '$SYS/x'), true);
});

test('topicMatchesFilter: gecersiz filtre/konu eslesmez', () => {
  assert.equal(topicMatchesFilter('a/b', 'a/#/b'), false);
  assert.equal(topicMatchesFilter('a/b', 'a/b#'), false);
  assert.equal(topicMatchesFilter('a/+', 'a/+'), false, 'yayin konusunda joker olmaz');
  assert.equal(topicMatchesFilter('', '#'), false);
  assert.equal(topicMatchesFilter('a', ''), false);
});

test('filterCoveredByRule: abonelik filtresi kural filtresinin alt kumesi mi', () => {
  const T = [
    ['ev/h_1/state', 'ev/h_1/state', true],
    ['ev/h_1/state', 'ev/h_1/+', true],
    ['ev/h_1/state', 'ev/h_1/#', true],
    ['ev/h_1/state', 'ev/#', true],
    ['ev/h_1/state', '#', true],
    ['ev/+/state', 'ev/h_1/state', false],   // joker abonelik, tekil kuraldan genis
    ['ev/+/state', 'ev/+/state', true],
    ['ev/+/state', 'ev/#', true],
    ['ev/h_1/#', 'ev/h_1/+', false],
    ['ev/h_1/#', 'ev/h_1/#', true],
    ['#', 'ev/#', false],
    ['#', '#', true],
    ['ev/h_1', 'ev/h_1/#', true],            // a/# 'a' seviyesini de kapsar
    ['ev/h_1/cmd', 'ev/h_1/state', false],
    ['$SYS/x', '#', false],
    ['ev/h_1/state/x', 'ev/h_1/state', false],
  ];
  for (const [sub, rule, expected] of T) {
    assert.equal(filterCoveredByRule(sub, rule), expected, `${sub} ⊆ ${rule}`);
  }
});

test('evaluateAcl: kural yoksa deny (zero trust)', () => {
  const r = evaluateAcl([], { action: 'subscribe', topic: 'ev/h_1/state' });
  assert.equal(r.allowed, false);
  assert.equal(r.reason, 'no_rules');
});

test('evaluateAcl: allow eslesmesi ve eylem ayrimi', () => {
  const rules = [
    { permission: 'allow', action: 'subscribe', topic: 'ev/h_1/state' },
    { permission: 'allow', action: 'publish', topic: 'ev/h_1/status' },
  ];
  assert.equal(evaluateAcl(rules, { action: 'subscribe', topic: 'ev/h_1/state' }).allowed, true);
  assert.equal(evaluateAcl(rules, { action: 'publish', topic: 'ev/h_1/state' }).allowed, false, 'yalniz sub izni var');
  assert.equal(evaluateAcl(rules, { action: 'publish', topic: 'ev/h_1/status' }).allowed, true);
  assert.equal(evaluateAcl(rules, { action: 'subscribe', topic: 'ev/h_1/status' }).allowed, false, 'yalniz pub izni var');
  assert.equal(evaluateAcl(rules, { action: 'subscribe', topic: 'ev/h_2/state' }).reason, 'no_match');
});

test('evaluateAcl: action=all hem yayini hem aboneligi kapsar', () => {
  const rules = [{ permission: 'allow', action: 'all', topic: 'ev/h_1/#' }];
  assert.equal(evaluateAcl(rules, { action: 'publish', topic: 'ev/h_1/cmd' }).allowed, true);
  assert.equal(evaluateAcl(rules, { action: 'subscribe', topic: 'ev/h_1/cmd' }).allowed, true);
  assert.equal(evaluateAcl(rules, { action: 'subscribe', topic: 'ev/#' }).allowed, false, 'daha genis abonelik reddedilir');
});

test('evaluateAcl: deny onceliklidir (sirasi fark etmez)', () => {
  const allowThenDeny = [
    { permission: 'allow', action: 'all', topic: 'ev/h_1/#' },
    { permission: 'deny', action: 'publish', topic: 'ev/h_1/cmd' },
  ];
  const denyThenAllow = [...allowThenDeny].reverse();
  for (const rules of [allowThenDeny, denyThenAllow]) {
    const pub = evaluateAcl(rules, { action: 'publish', topic: 'ev/h_1/cmd' });
    assert.equal(pub.allowed, false);
    assert.equal(pub.reason, 'deny_rule');
    assert.equal(evaluateAcl(rules, { action: 'subscribe', topic: 'ev/h_1/cmd' }).allowed, true, 'deny yalniz publish');
    assert.equal(evaluateAcl(rules, { action: 'publish', topic: 'ev/h_1/state' }).allowed, true);
  }
});

test('evaluateAcl: ${username} yer tutucusu GENISLETILMEZ', () => {
  const rules = [{ permission: 'allow', action: 'all', topic: 'ev/${username}/state' }];
  assert.equal(evaluateAcl(rules, { action: 'publish', topic: 'ev/alice/state' }).allowed, false);
});

test('evaluateAcl: yayin konusunda joker karakter reddedilir; bilinmeyen izin/eylem yok sayilir', () => {
  const rules = [
    { permission: 'allow', action: 'all', topic: 'ev/#' },
    { permission: 'maybe', action: 'all', topic: '#' },
    { permission: 'allow', action: 'pubsub', topic: '#' },
  ];
  assert.equal(evaluateAcl(rules, { action: 'publish', topic: 'ev/+/cmd' }).allowed, false);
  assert.equal(evaluateAcl(rules, { action: 'publish', topic: 'other/x' }).allowed, false, 'bilinmeyen izin/eylem kurallari etkisiz');
  assert.equal(evaluateAcl(rules, { action: 'publish', topic: 'ev/h/cmd' }).allowed, true);
});
