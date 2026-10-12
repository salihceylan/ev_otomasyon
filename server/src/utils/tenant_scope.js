'use strict';

// ==============================================================================
// AHBU Akilli Ev - Servis sorumlusu kapsami (kiracilik) yardimcilari
// ==============================================================================
//
// Tasarim: docs/superpowers/specs/2026-10-12-servis-kapsamli-super-yetki-design.md (§2, §4, §5). Migration 045.
//
//   KOK        : global rol super_user (her sey).
//   KIRACI     : global rol service_user; kapsami
//                  homes.service_owner_id = kullanici, device_inventory.service_owner_id = kullanici,
//                  sites.service_owner_id = kullanici ve turetilmis MUSTERI kapsami (servisin evlerinde uyesi olan ya da
//                  users.created_by_user_id = servis olan 'user' rollu kullanici).
//   NULL sahip : kok kapsami. Servis, sahipsiz (NULL) kayit uzerinde YONETIM yapamaz; yalniz "kok stogundaki"
//                (IN_STOCK, service_owner_id NULL) karti KURABILIR.
//
// Bu dosya SAF karar + kucuk sorgu yardimcilaridir; HTTP bilmez. Aktor bicimleri:
//   { userId, globalRole }  (routes/route_helpers.actorOf)      { id, role }  (req.user)
//   { type:'super_user'|'service_user'|'api_key', userId }      (req.inventoryActor)
// `actor` null/undefined = dahili cagri (rota katmani HER ZAMAN aktor gecirir) -> kok sayilir.
// Servis PIN oturumu hicbir zaman kok ya da kiraci DEGILDIR.

const ROOT = 'super_user';
const SERVICE = 'service_user';

function actorId(actor) {
  if (!actor || typeof actor !== 'object') return null;
  const id = actor.userId !== undefined && actor.userId !== null ? actor.userId : actor.id;
  return id ? String(id).toLowerCase() : null;
}

function actorRole(actor) {
  if (!actor || typeof actor !== 'object') return null;
  if (actor.isServiceSession === true || actor.is_service_session === true) return 'service_session';
  const r = actor.globalRole || actor.role || actor.type || null;
  return r;
}

/** Dahili cagri (aktor yok) ya da kok yonetici ya da kok-esdeger API anahtari. */
function isRoot(actor) {
  if (actor === null || actor === undefined) return true;
  const r = actorRole(actor);
  return r === ROOT || r === 'api_key';
}

/** Kapsamli servis sorumlusu (kiraci). */
function isService(actor) {
  return actorRole(actor) === SERVICE && actorId(actor) !== null;
}

function sameId(a, b) {
  return a !== null && a !== undefined && b !== null && b !== undefined && String(a).toLowerCase() === String(b).toLowerCase();
}

function run(q) {
  if (typeof q === 'function') return q;
  if (q && typeof q.query === 'function') return (text, params) => q.query(text, params);
  throw new TypeError('tenant_scope: q bir sorgu fonksiyonu ya da { query } olmali');
}

/** Evin servis sahibi: kullanici kimligi | null (kok) | undefined (ev yok). */
async function homeServiceOwner(q, homeId) {
  const r = await run(q)('SELECT service_owner_id FROM homes WHERE id = $1', [homeId]);
  const row = r && r.rows && r.rows[0];
  if (!row) return undefined;
  return row.service_owner_id || null;
}

/**
 * Ev kapsami: 'root' | 'tenant' | null (kapsam disi). Ev yoksa null.
 */
async function homeScope(q, actor, homeId) {
  if (isRoot(actor)) return 'root';
  if (!isService(actor)) return null;
  const owner = await homeServiceOwner(q, homeId);
  return owner && sameId(owner, actorId(actor)) ? 'tenant' : null;
}

/**
 * Kart kapsami. inv = { service_owner_id, status }.
 *   'root'       kok yonetici
 *   'tenant'     servisin KENDI stogundaki / kurdugu karti
 *   'root_stock' kok stogundaki (service_owner_id NULL) kart: servis YALNIZ kurabilir (yonetemez)
 *   null         baska servisin karti ya da servis icin sahipsiz/kurulu kok karti
 */
function inventoryScope(actor, inv) {
  if (isRoot(actor)) return 'root';
  if (!isService(actor) || !inv) return null;
  const owner = inv.service_owner_id || null;
  if (owner) return sameId(owner, actorId(actor)) ? 'tenant' : null;
  return inv.status === 'IN_STOCK' ? 'root_stock' : null;
}

/**
 * Karti KURMA (claim / pano degisimi) hakki var mi? Kok her karti; servis YALNIZ kendi stogundakini ya da kok stogundakini
 * (service_owner_id NULL); baska servisin stogundaki kart HAYIR. Kartin durumu (IN_STOCK vb.) ayrica denetlenir.
 */
function mayInstall(actor, inv) {
  if (isRoot(actor)) return true;
  if (!isService(actor) || !inv) return false;
  const owner = inv.service_owner_id || null;
  return owner === null || sameId(owner, actorId(actor));
}

/** Karti YONETME hakki (liste, askiya alma, etiket, PIN kilidi, silme, yerel anahtar)? Kok stogu yonetilemez. */
function mayManageCard(actor, inv) {
  const s = inventoryScope(actor, inv);
  return s === 'root' || s === 'tenant';
}

/** Site kapsami: 'root' | 'tenant' | null. site = { service_owner_id }. */
function siteScope(actor, site) {
  if (isRoot(actor)) return 'root';
  if (!isService(actor) || !site) return null;
  return site.service_owner_id && sameId(site.service_owner_id, actorId(actor)) ? 'tenant' : null;
}

/**
 * Musteri (kullanici) kapsami: kok -> herkes; servis -> kendisi ya da servisin evlerinde uyesi olan / servisin actigi
 * 'user' rollu kullanici.
 */
async function userInScope(q, actor, userId) {
  if (isRoot(actor)) return true;
  if (!isService(actor)) return false;
  if (sameId(userId, actorId(actor))) return true;
  const r = await run(q)(
    `SELECT 1
       FROM users u
      WHERE u.id = $2 AND u.role = 'user'
        AND (u.created_by_user_id = $1
             OR EXISTS (SELECT 1 FROM home_users hu JOIN homes h ON h.id = hu.home_id
                         WHERE hu.user_id = u.id AND h.service_owner_id = $1))`,
    [actorId(actor), userId]
  );
  return Boolean(r && r.rows && r.rows.length > 0);
}

/**
 * Musteri kapsam kosulu (liste sorgulari icin): u = kullanici tablosu takma adi, p = servis kullanici kimligi parametresi.
 * Kendi satiri dahildir.
 */
function customerScopeSql(u, p) {
  return `((${u}.role = 'user' AND (${u}.created_by_user_id = ${p}
            OR EXISTS (SELECT 1 FROM home_users sc_hu JOIN homes sc_h ON sc_h.id = sc_hu.home_id
                        WHERE sc_hu.user_id = ${u}.id AND sc_h.service_owner_id = ${p}))) OR ${u}.id = ${p})`;
}

module.exports = {
  ROOT,
  SERVICE,
  actorId,
  actorRole,
  isRoot,
  isService,
  sameId,
  homeServiceOwner,
  homeScope,
  inventoryScope,
  mayInstall,
  mayManageCard,
  siteScope,
  userInScope,
  customerScopeSql,
};
