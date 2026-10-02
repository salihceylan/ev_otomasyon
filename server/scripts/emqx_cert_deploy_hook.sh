#!/bin/sh
# ==============================================================================
# AHBU Akilli Ev - EMQX TLS sertifikasi dagitim kancasi (certbot --deploy-hook)   [WP-C, plan C5]
# ==============================================================================
# Neden: EMQX kapsayicisi root DEGIL calisir ve tum /etc/letsencrypt dizinini GOREMEZ. Certbot
# yeni sertifika aldiginda yalnizca ILGILI sertifika + anahtar, EMQX_CERT_DIR dizinine kopyalanir
# (docker-compose.yml bu dizini kapsayiciya SALT-OKUNUR baglar) ve yalnizca EMQX'in TLS
# dinleyicisi yeniden baslatilir. Diger servislere (nginx, uretimdeki kapi sistemi, Mosquitto)
# DOKUNULMAZ.
#
# KURULUM (sunucuda, root):
#   install -m 0755 scripts/emqx_cert_deploy_hook.sh /etc/letsencrypt/renewal-hooks/deploy/ev-emqx-cert.sh
#   # ortam: EMQX_CERT_DIR (zorunlu), EV_DOMAIN, EMQX_UID/EMQX_GID (kapsayici kullanicisi; varsayilan 1000)
#   # ILK kopyalama icin elle: RENEWED_LINEAGE=/etc/letsencrypt/live/<alan> EMQX_CERT_DIR=<dizin> sh ev-emqx-cert.sh
#
# !! Bu betik EMQX/Docker olmayan bir makinede yazildi; hazirlik ortaminda denenmelidir.
#    `emqx ctl listeners restart ssl:default` komutunun 5.8'deki tam adi dogrulanmalidir; basarisizsa
#    betik uyari verir ve EMQX'i yeniden baslatmaz (kapsayiciyi elle yeniden baslatin).

set -eu

: "${RENEWED_LINEAGE:?RENEWED_LINEAGE tanimli degil (certbot deploy-hook ortami)}"
: "${EMQX_CERT_DIR:?EMQX_CERT_DIR tanimli degil}"

EV_DOMAIN="${EV_DOMAIN:-evotomasyon.gudeteknoloji.com.tr}"
EMQX_UID="${EMQX_UID:-1000}"
EMQX_GID="${EMQX_GID:-1000}"
EMQX_CONTAINER="${EMQX_CONTAINER:-ev_otomasyon_emqx}"

# Certbot butun lineage'lar icin cagirir; yalnizca bizim alan adimiz.
case " ${RENEWED_DOMAINS:-$EV_DOMAIN} " in
  *" ${EV_DOMAIN} "*) ;;
  *) echo "[ev-emqx-cert] ${EV_DOMAIN} yenilenmedi; atlandi."; exit 0 ;;
esac

[ -r "${RENEWED_LINEAGE}/fullchain.pem" ] || { echo "[ev-emqx-cert] ${RENEWED_LINEAGE}/fullchain.pem okunamiyor" >&2; exit 1; }
[ -r "${RENEWED_LINEAGE}/privkey.pem" ]   || { echo "[ev-emqx-cert] ${RENEWED_LINEAGE}/privkey.pem okunamiyor" >&2; exit 1; }

umask 077
install -d -m 0750 -o "${EMQX_UID}" -g "${EMQX_GID}" "${EMQX_CERT_DIR}"

# Atomik degistirme: once gecici dosya, sonra mv (EMQX yarim yazilmis dosya gormesin)
install -m 0644 -o "${EMQX_UID}" -g "${EMQX_GID}" "${RENEWED_LINEAGE}/fullchain.pem" "${EMQX_CERT_DIR}/fullchain.pem.new"
install -m 0600 -o "${EMQX_UID}" -g "${EMQX_GID}" "${RENEWED_LINEAGE}/privkey.pem"   "${EMQX_CERT_DIR}/privkey.pem.new"
mv -f "${EMQX_CERT_DIR}/fullchain.pem.new" "${EMQX_CERT_DIR}/fullchain.pem"
mv -f "${EMQX_CERT_DIR}/privkey.pem.new"   "${EMQX_CERT_DIR}/privkey.pem"
echo "[ev-emqx-cert] sertifika ${EMQX_CERT_DIR} dizinine kopyalandi."

# Yalnizca EMQX'in TLS dinleyicisini yenile (kapsayici calismiyorsa sessizce gec).
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx "${EMQX_CONTAINER}"; then
  if docker exec "${EMQX_CONTAINER}" /opt/emqx/bin/emqx ctl listeners restart ssl:default >/dev/null 2>&1; then
    echo "[ev-emqx-cert] EMQX ssl:default dinleyicisi yeniden baslatildi."
  else
    echo "[ev-emqx-cert] UYARI: dinleyici yeniden baslatilamadi; EMQX'i elle yeniden baslatin: docker restart ${EMQX_CONTAINER}" >&2
  fi
else
  echo "[ev-emqx-cert] EMQX kapsayicisi (${EMQX_CONTAINER}) calismiyor; yeniden baslatma atlandi."
fi
