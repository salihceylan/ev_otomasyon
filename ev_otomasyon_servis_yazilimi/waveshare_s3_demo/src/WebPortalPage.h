#pragma once
// ============================================================================
// WebPortalPage.h - Gomulu web arayuzu (tek sayfa, GET /).
//
// Bu dosyanin kaynagi WebPortal.cpp'den ayrilmistir; arayuz mantigi (JS) bu dosyadadir.
// v1.1.2: yalniz metin duzeltmesi. Anahtar ipuclari artik dogru yeri soyler (anahtar etikette ve uygulamada
// gosterilmez; kurulumda fabrika/servis araci verir) ve provizyon formuna "sunucuya kayitli panoda kullanmayin"
// uyarisi eklendi (bu formla belirlenen anahtari sunucu bilmez). Gorunum, JS mantigi, id/sinif adlari 1.1.1 ile ayni.
// v1.1.1 gorunum: "Neon Glass" (cam kartlar, hap dugmeler, orb durum noktalari; koyu + acik tema
// [prefers-color-scheme], prefers-reduced-motion, :focus-visible halkalari, >=44 px dokunma hedefi). Dis kaynak YOK
// (CSP: default-src 'none'; style-src/script-src 'unsafe-inline'; img-src data:); eski tarayici (iOS 12+/Chrome 80+) icin
// color-mix/:has/inset/container query kullanilmaz; JS'in kullandigi id/sinif/data-* adlari degismedi.
// Guvenlik tasarimi (CONTRACTS Bolum 3, 3d):
//  - Kimlik: sayfa anahtarsiz yuklenir; JS cihaz anahtarini ister ve her istekte "X-Device-Key" basligiyla
//    gonderir. Anahtar KALICI saklanir (v1.1.1): localStorage 'ahbu_key' (bu cihaz-sayfasi kaynagina [http://<pano ip>]
//    ozel; localStorage yoksa sessionStorage, o da yoksa bellek). Her acilista kayitli anahtar GET /api/auth/check ile
//    dogrulanip otomatik giris yapilir; yalniz cihazin KABUL ETTIGI anahtar yazilir. 401 (yanlis/eski anahtar, cihaz
//    sifirlandi) -> kayitli anahtar hemen silinir ve anahtar kutusu cikar (yanlis anahtari yoklamayla tekrarlamak
//    cihazda IP kilidini [5 hata -> 60 sn] tetiklerdi). Basliktaki "Cikis" dugmesi anahtari bu tarayicidan siler
//    (ortak telefon); AP kaynakli anahtarsiz modda gizlidir. Provizyonsuz cihazda kurulum (factory/init) formu cikar.
//  - AP KAYNAKLI (anahtarsiz) kurulum modu: istemci panonun kurtarma agindaysa cihaz GET /api/wifi/status'u anahtarsiz
//    acar; bu modda yalniz "Wi-Fi (Station)" sekmesi calisir (ag listesi, karekod, bagla + sonucu /api/wifi/status ile
//    bekle). Diger sekmeler "Bu islem icin cihaz anahtari gerekir" kutusu gosterir; sayfa ustunde "Kurulum modu (AP)"
//    bandi cikar. Karari cihaz verir (ApAccess.h); sayfa yalnizca ucun 200/401 yanitini yorumlar.
//  - Dis kaynakli HER metin (SSID, kanal/giris/cihaz adi, IP) esc() ile kacirilir ya da DOM API
//    (textContent/value) ile basilir; saklı XSS yoktur.
//  - Yolda-istek kilidi (ayni dugmeye cift basis), gizli sekmede yoklama yok, hatada geri cekilme.
//  - Komutlar idempotenttir (state=0/1); "toggle" gonderilmez.
// ============================================================================
static const char INDEX_HTML[] PROGMEM = R"rawliteral(<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="color-scheme" content="dark light">
<meta name="theme-color" content="#0B1120" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#F4F7FC" media="(prefers-color-scheme: light)">
<title>AHBU Akıllı Ev &amp; Bina Kontrol</title>
<link rel="icon" type="image/png" href="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACQAAAAkCAIAAABuYg/PAAABCGlDQ1BJQ0MgUHJvZmlsZQAAeJxjYGA8wQAELAYMDLl5JUVB7k4KEZFRCuwPGBiBEAwSk4sLGHADoKpv1yBqL+viUYcLcKakFicD6Q9ArFIEtBxopAiQLZIOYWuA2EkQtg2IXV5SUAJkB4DYRSFBzkB2CpCtkY7ETkJiJxcUgdT3ANk2uTmlyQh3M/Ck5oUGA2kOIJZhKGYIYnBncAL5H6IkfxEDg8VXBgbmCQixpJkMDNtbGRgkbiHEVBYwMPC3MDBsO48QQ4RJQWJRIliIBYiZ0tIYGD4tZ2DgjWRgEL7AwMAVDQsIHG5TALvNnSEfCNMZchhSgSKeDHkMyQx6QJYRgwGDIYMZAKbWPz9HbOBQAAALM0lEQVR42k2Xa4xd11XH19pn73PuPffOfXnGM+NHHDseOzNx6jycJg1pkyiKilqB8gWJDyCBgaZQVQhSBVWgIj4gykOi/UCpqOADfGgrKC2KqKqobQJpipKmThvHdm1nnNhje5733pn7OI+914MPdybKPls6WtLR+Z//OltrrR/+6KcXjTGICAC4t4wxAAigxhhARACEyRMAqAoAAKgAigAAiAKqoqCqoACgqiKiqqq7IQCIiEXESbAnicYYREAAYyJERARENAAKinuioKC4F6qKokYAiqKgygBoooiYAeB9MQCwk9vEmUE0iIFZdOIQDCKiQQMIoIgGEQEBYXcpKkwuAAVVEVUWFRJrwLlIVJn5fT92oqQALoqYuV9Kbaq1r9OpVp2NwEQQRYAIBsEAGATzvhKA7m1REAUREAFmKArpdnvdfr+RGOdsIJqoWBVVhDiOssKvDfmuY8eI5fv/+/qVq9eCL6MPLOtcHLu0WqmmVVQYZ1mW5yEQE7GIsqgqi8RJcvLk8UceeiCtNy9fuTrXcNXElSEAgFWAyCARX9sYnTxx95vnL/3NX33RDzfvPHygllYjE0XWmshG1lpnYxfHSSV2MQCUZV6WOQViYhURFWEmCoPR+Fv/tlbbd/BP/vTziwvHLly4cPeBVoSGQPCVNy4kzr1zq5t25rM8/8M/+P2P3r/wzDO/2my04sTFLrbO7TqLTGSjyEYuQlFlUiIKxCICAMJCTCGEoiiGg8ELL3z3hz+5+OWvfLVRrw03by0cms6Dj85+6jNMfGNzNHvg0Ff+4at3tOzZ3/4tZhUVEVBVZiYiIibiQGwQjh2crafJ2kavKLksvQ/ee/Y+lKX3PvgyiOJDHz6zefPGq2+c//gvf3xtbb1dcwhoAHRclC5Jtnq9m8tXnnrqiZ3hkFUmp1FEmFlEEAHRVCvx0vHDaT1tNqbuXTxaTVxkokZ96q4j80cPzx2Y2wcAaFCEu73+k09+dPX6O5tbWzZJRlmJAgZUi6JUwOFg0Gqk9al6IC8qJEzMxMwiAECCzkanTtwJxv7e8186+9wXieXUySOREZRw8eLbz33u+e1eryzzEEhEgvfVWtpq1ne2+4gmLws1apjEF56IVSSOY2YJnilMMqeBgdSWZK0x9917or89ePYL//x/b1x6+aWfPf+33x5k4UOLJ2v1ar8/Hva2trr99fWNcTbyIQQiQIzjhIiZqMgKIjIUyHvPRKIqokXhg9+VKj0JpCS1SmLP3L+0cvPWZz77ude+++9nPvaxp88+99pPbvz6p/94dWdr8fid3hdzM+2sKLazYlT4IlAg9qVXERZh5rIsvQ+GiDz5QESBAcD7wlPpA5NX1YonV6/yh+9buHTpytnf/ezyhQu/9PD90r+xc+OtJ5+Yh+nec3/3599/+XUGvN0bkajE9SJKSoWSKC9LFp6YCRSYyBCREFOgEIiZi7L0nkKpRNF47Fupf+CeI6++fv5Tz/5Rb2P9gQcXmknpZLBv8HYULjz22MPv/PDyc5//s/WtblLvcKC4PQvtWTI2EJXeq3AgCj6ICDEbVQDAQFQSMbMvKXhWhcLnM51o4c793/re63/59Z9J7a7jH3rw+NOP11oHMjuNnU6xM+4vN5/6tWcVtn88PPf4Jx998PTpE3ONyMbqEmIJpRfR0vvCl6qqIgZUAYGYvQ+gMPlbRZl32snMTPsb3/z2X3/hL/Ib1xYefWb61CfeXZvhw48UBJzIsYfvssXqYPPSwice0dHO17705f/8r+90nNnvez4bB2FPXlQKXxalnxRSO6nHnkgQWZiZAGSqZvOs/Nd/+toPXnyx0Z5ZrPWmuu+2o/rGrUvXA8H22k6vuLpZaWPsXKV3s2c2umHo/+Uf//76u9cef+rpSjHMisL7oEzeEyiJRqpqRURFvaegKizMGspsbTVvNBunT9+z+u6VbCezWG0enN0adl13OQt55LUSZGVQDKpJ1Kb06HzV2KX5DVc/dOqeE5sbW9vb24FDYFGFoixBGSQREcsgCup9KJhEYTgYvLN2y6VNl1SXFhcOLT30zptv1w6dygi61970YqaCX5ypm7TZXe0PObRhWKtNgdns3Lu/uu/ujN25n7/MPpRjmJ0/IMqF9ygMUAHda55F6XOvwjwcDtfXt1b7Wa1zZG5me1BoppVB56hxld7WdqtFt8fieZjWOTXa4h3ZgbVXx2PSrTKaDYOV4ubN0YX+7Z0pPdxotpmoKEqzOzKoBVZQ8CEUpbCIJ2q05qtzS5h2PK1XuX+wWfbO/beqa9YwVvXgrvXGyY4/c7ixkOqVuYM4AnmvqI+7HOXcpOOn7s1n/ei2MJEw5XkeGzPpQVZVFZSIQmBUMZFLW62AXBYrWeYpBC4y6p+rpZWZdlIqTldjkvFqHraGeRRcc0z97ahy/KnhzZsgt1JPo9uhYpvNNmIQEQ5liZEVVVAwkzSS5+A9ABg0xoCVbqKb4+HAt7C6NJeh3N4udjJvHWyG0Rjy1lSyOdKf3uLrG7XujT4HL7W2Fy0zD5kzZG1k0RgR8d5TIABQEDsZvwKF4L0CgKjRQjgIjbOxmznkDhzft7E84m6Z25pQWPzIjOep8Fbe2/YrRezSJ+Dwa92VV4b9ZHo2LYpSCcQJAAqzMPuisAlOZiyroKIqRORLYRImEaBQUCjA4fqQln90sXn3r+zfzqYXDt3++ff656/5aoW8aTu8Y3/Td88d+QhsXe3YeGmcjJPxeRQmHwMgiChoWRTO2MkYaUEVAIhCCIEp+FCwaqAyhKAi+dbBytRCtroxHJVbRXnU0O1y6t3L2zOHlvYfPlC79Iom7q2X1ht5GBcbtipQldhVQggGkZkkEAeapBFArSqICAdWZlUNHEQkhKAsNrYOpscb1Y6sp7PzWKwUxU77wfkT043a9NK+pcdkuJqNbk2pbSSC2RrYJoolIhOCMREHImJR0L1tAcEgqDAaE0IoiwKNURZhGg3LhYPjuMn11jFxVefziqvHszVfLa1NiG7N3Xd3mc+NxuOQF4FlHOjqtfciMMwiAhyCKGAUizIqgIAFVGcNsK/WmzbtZKNRvdFU1UDky+L68uVao5PdWI5sBCCVCuIyuYoN4XI+yFFtmZexNaqKCC6KinEWV2txrCaCUZ7ZdCZtzMJ4NXaRgloRjZ1tVd3N4Wjh3jM333qpXmcA+PTv/Ea320sq1TsOH7qy/N7lq9dVaPHknZU03t7ZbjUbzanG5saW98GXHo1JK5V+f+c3l05udvtf/48XqpUkL/jE6Uez0XA2tZXYiaidHMrjR2auv/YLSOzskZPlYG2qnl78xRVfhp3BcGXldl74bDwaDIeVBNa21mZm9u3sbG+sbzXqU8yaxMn16yvBh4MH51/6nx+72CWxVTQH7loyGGi8trC4sAs+3/jOi3meDwc7l66unF/eAGMsMoe8yDJjDKJhZhMZ56wxACLWIRqjoMLCpBRkj1EAAFgkMqZSrWrkSCIVWTw6vXj0cHtfJ62nFgEMIKiZ69RD8Cubo6wUxqqrVQAAEZxBABBVVrDOCCKgTljNRODiXRqbFCSLAAClolVTsTDXqc8208hZYxAVrCogmjh2SaUyVYnarow5QGxFJwRoEBX30OyDBAiggKgKoCoCAKiqqjL5RA1ZjNis1CvVWhzHiKiiFgGiyLjYVdO01WqHwLq1kedjFAFAExmDZvLyCRfu6uyBk6qqKIoAoqqwiIqIQpy46enpdmdfLU1j54wxgGDRIBp0zqVpVUURMakko2xcFqUIfwBE95gTYZf9YLfiTQzppGWpIKJzrlarNepTjUajWqvY2KIxgPD/xMf0FbvfHQIAAAAASUVORK5CYII=">
<style>
/* AHBU "Neon Glass" (cihaz sayfasi). Tek dosya: dis font/CDN/resim YOK (cihaz cevrimdisi AP'de calisir). Renkler belirteclerden gelir. */
:root{
color-scheme:dark light;
--bg0:#0B1120;--bg1:#0E1830;--g1:rgba(37,99,235,.22);--g2:rgba(6,182,212,.14);
--surf:rgba(255,255,255,.06);--surf2:rgba(255,255,255,.10);--inset:rgba(2,6,18,.30);--rim:rgba(255,255,255,.14);--hi:rgba(255,255,255,.09);
--shadow:0 14px 30px -16px rgba(0,0,0,.8);--glow:.6;
--ctl:#8393B1;--field:rgba(2,6,18,.55);--swoff:rgba(255,255,255,.12);--swa:#FFC24D;--swb:#F59E0B;--knob:#E2E8F0;--knob-on:#0B1120;--baroff:rgba(255,255,255,.28);
--text:#EEF3FB;--muted:#B0BED3;--faint:#9CABC2;
--t-sky:#93C5FD;--t-cyan:#67E8F9;--t-emerald:#6EE7B7;--t-amber:#FFD36B;--t-rose:#FDA4AF;--t-violet:#D8B4FE;
--k-sky:59,130,246;--k-cyan:6,182,212;--k-emerald:16,185,129;--k-amber:245,158,11;--k-rose:244,63,94;--k-violet:168,85,247;--k-slate:148,163,184;
--ap:.16;--ab:.40;--focus:#67E8F9;--ink:#04141B;
--p1:#2563EB;--p2:#0E7490;--d1:#E11D48;--d2:#BE123C;--ul1:#60A5FA;--ul2:#22D3EE;
}
@media (prefers-color-scheme:light){:root{
--bg0:#F4F7FC;--bg1:#E6EDF7;--g1:rgba(37,99,235,.10);--g2:rgba(6,182,212,.09);
--surf:rgba(255,255,255,.88);--surf2:rgba(15,23,42,.05);--inset:rgba(15,23,42,.045);--rim:rgba(15,23,42,.13);--hi:rgba(255,255,255,.9);
--shadow:0 12px 26px -16px rgba(15,23,42,.38);--glow:.32;
--ctl:#64748B;--field:#FFFFFF;--swoff:rgba(15,23,42,.14);--swa:#C2610A;--swb:#9A4A00;--knob:#64748B;--knob-on:#FFFFFF;--baroff:rgba(15,23,42,.24);
--text:#0E1A2E;--muted:#475569;--faint:#5E6C84;
--t-sky:#1C45C4;--t-cyan:#0B6A83;--t-emerald:#046C4E;--t-amber:#8A4300;--t-rose:#A30D31;--t-violet:#6D28D9;
--ap:.12;--ab:.38;--focus:#1D4ED8;--ul1:#1D4ED8;--ul2:#0891B2;
}}

/* ---- temel ---- */
*,*::before,*::after{box-sizing:border-box}
*{margin:0;padding:0}
html{-webkit-text-size-adjust:100%;text-size-adjust:100%}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,"Noto Sans",sans-serif;font-size:15px;line-height:1.5;color:var(--text);min-height:100vh;padding-bottom:40px;overflow-x:hidden;-webkit-font-smoothing:antialiased;background-color:var(--bg0);background-image:radial-gradient(780px 440px at 100% -10%,var(--g1),transparent 70%),radial-gradient(640px 400px at -8% 0,var(--g2),transparent 70%),linear-gradient(180deg,var(--bg0),var(--bg1));background-repeat:no-repeat}
button,input,select,textarea{font-family:inherit;color:inherit}
button{-webkit-tap-highlight-color:transparent}
img{display:block}
a{color:var(--t-sky)}
:focus{outline:3px solid var(--focus);outline-offset:2px}
:focus:not(:focus-visible){outline:none}
.nav-tab:focus,.net-row:focus{outline-offset:-3px}
@keyframes rise{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}
@keyframes orb{50%{opacity:.55;transform:scale(.86)}}

/* ---- ust bilgi ---- */
header{display:flex;flex-wrap:wrap;align-items:center;gap:10px 12px;padding:14px 16px;border-bottom:1px solid var(--rim);background:linear-gradient(180deg,var(--hi),transparent)}
.logo-title{display:flex;align-items:center;gap:12px;flex:1 1 220px;min-width:0}
.app-head{min-width:0}
.logo-img{width:44px;height:44px;flex:none;border-radius:14px;box-shadow:0 0 0 1px var(--rim),0 6px 20px -4px rgba(var(--k-sky),var(--glow))}
.app-title{font-size:18px;font-weight:800;line-height:1.25;letter-spacing:-.01em;word-break:break-word;overflow-wrap:anywhere}
.app-sub{display:block;font-size:12px;color:var(--muted)}
.header-info{display:flex;flex-wrap:wrap;gap:8px;flex:1 1 100%}
.header-info>span{display:inline-block;padding:6px 12px;border-radius:999px;border:1px solid var(--rim);background:var(--inset);font-size:12.5px;color:var(--muted);white-space:nowrap}
.header-info b{color:var(--text);font-variant-numeric:tabular-nums}
.ap-banner{display:none;padding:11px 16px;border-bottom:1px solid rgba(var(--k-amber),.55);background:rgba(var(--k-amber),.16);color:var(--t-amber);font-size:13.5px;font-weight:700;text-align:center;line-height:1.5}

/* ---- sekmeler ---- */
.nav-tabs{display:flex;gap:4px;padding:8px 12px 0;overflow-x:auto;-webkit-overflow-scrolling:touch;scrollbar-width:none;border-bottom:1px solid var(--rim);background:var(--surf)}
.nav-tabs::-webkit-scrollbar{display:none}
.nav-tab{flex:none;display:inline-flex;align-items:center;min-height:46px;padding:0 16px;border:0;border-radius:14px 14px 0 0;background:transparent;color:var(--muted);font-size:14px;font-weight:700;white-space:nowrap;cursor:pointer;transition:color .15s,background-color .15s}
.nav-tab:hover{color:var(--text);background:var(--surf2)}
.nav-tab.active{color:var(--t-cyan);background-color:rgba(var(--k-cyan),.10);background-image:linear-gradient(90deg,var(--ul1),var(--ul2));background-repeat:no-repeat;background-size:100% 3px;background-position:0 100%}
body.ap-mode .nav-tab:not([data-tab="wifi"]):not(.active){color:var(--faint)}
.content-section{display:none;max-width:1100px;margin:0 auto;padding:18px 16px 28px}
.content-section.active{display:block;animation:rise .28s ease both}
body.ap-mode .content-section:not(#tab-wifi){display:none !important}

/* ---- tipografi ve yerlesim ---- */
.section-title{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:6px 14px;margin:4px 0 14px;font-size:17px;font-weight:800;letter-spacing:-.01em}
.card-h{font-size:16px;font-weight:800;line-height:1.35}
.fw{font-weight:700}
.hl{font-size:14px;font-weight:800}
.hl-muted{font-size:13.5px;font-weight:800;color:var(--muted)}
.muted{font-size:13px;line-height:1.5;color:var(--muted)}
.muted:empty{display:none}
.note{font-size:12.5px;line-height:1.5;color:var(--muted);font-weight:500;letter-spacing:0}
.hint{font-size:13px;line-height:1.55;color:var(--muted)}
.mb{margin-bottom:16px}
.lbl{display:block;margin-bottom:6px;font-size:13px;font-weight:700;color:var(--muted)}
.lbl-sm{font-size:12.5px;font-weight:700;color:var(--muted)}
.row{display:flex;align-items:center;gap:8px;flex-wrap:wrap;min-width:0}
.row2{display:flex;align-items:center;gap:8px}
.row2>span,.row2>button{flex:none}
.row-between{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap}
.stack>*+*{margin-top:16px}
.sep{border-top:1px solid var(--rim);padding-top:14px}
.sep>*+*{margin-top:8px}
.sys-list{font-size:14px;line-height:2}

/* ---- dugmeler (yuvarlak hap) ---- */
.btn{display:inline-flex;align-items:center;justify-content:center;min-height:44px;padding:10px 18px;border:1px solid transparent;border-radius:999px;font-size:14px;font-weight:700;line-height:1.25;text-align:center;color:var(--text);cursor:pointer;transition:transform .12s ease,filter .15s ease,background-color .15s ease}
.btn:active{transform:scale(.97)}
.btn[disabled]{opacity:.55;cursor:not-allowed}
.btn-primary{color:#fff;background:linear-gradient(135deg,var(--p1),var(--p2));box-shadow:inset 0 1px 0 rgba(255,255,255,.3),0 10px 22px -10px rgba(var(--k-sky),.85)}
.btn-danger{color:#fff;background:linear-gradient(135deg,var(--d1),var(--d2));box-shadow:inset 0 1px 0 rgba(255,255,255,.28),0 10px 22px -10px rgba(var(--k-rose),.8)}
.btn-secondary{background:var(--surf2);border-color:var(--rim)}
.btn-outline{background:transparent;border:1.5px solid var(--ctl)}
.btn-sm{padding:8px 14px;font-size:13px}
.btn-block{width:100%}
@media (hover:hover){.btn-primary:hover,.btn-danger:hover{filter:brightness(1.12)}.btn-secondary:hover,.btn-outline:hover{background:var(--surf2)}.net-row:hover{filter:brightness(1.1)}}
.quick-actions{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-bottom:20px}
.seg{display:flex;flex-wrap:wrap;gap:6px;padding:4px;border-radius:999px;border:1px solid var(--rim);background:var(--field)}

/* ---- kartlar (cam) ---- */
.card{display:flex;flex-direction:column;justify-content:space-between;min-width:0;padding:16px;border-radius:20px;border:1px solid var(--rim);background:var(--surf);box-shadow:inset 0 1px 0 var(--hi),var(--shadow)}
.card>*+*{margin-top:14px}
.card-narrow{width:100%;max-width:640px;margin-left:auto;margin-right:auto}
.card.is-on{border-color:rgba(var(--k-amber),.6);background-image:radial-gradient(120% 100% at 0 0,rgba(var(--k-amber),.16),transparent 62%);box-shadow:inset 0 1px 0 var(--hi),0 14px 34px -14px rgba(var(--k-amber),var(--glow))}
.card.is-moving{border-color:rgba(var(--k-cyan),.6);background-image:radial-gradient(120% 100% at 0 0,rgba(var(--k-cyan),.16),transparent 62%);box-shadow:inset 0 1px 0 var(--hi),0 14px 34px -14px rgba(var(--k-cyan),var(--glow))}
.cards-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:14px;margin-bottom:24px}
.card-header{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px}
.card-title{font-size:16px;font-weight:800;word-break:break-word;overflow-wrap:anywhere}
.card-type-badge{display:inline-block;padding:3px 10px;border-radius:999px;border:1px solid var(--rim);background:var(--inset);color:var(--muted);font-size:12px;font-weight:700}
.card-type-badge.mv{border-color:rgba(var(--k-cyan),.55);background:rgba(var(--k-cyan),.14);color:var(--t-cyan)}
.pill{--k:var(--k-slate);--t:var(--muted);display:inline-block;max-width:100%;padding:3px 10px;border-radius:999px;border:1px solid rgba(var(--k),var(--ab));background:rgba(var(--k),var(--ap));color:var(--t);font-size:12px;font-weight:700;line-height:1.45;text-align:left}
.pill-lg{padding:5px 12px;font-size:13px}
.pill-live::before{content:"";display:inline-block;width:8px;height:8px;margin-right:6px;border-radius:50%;background:radial-gradient(circle at 35% 30%,#fff,rgb(var(--k)) 55%);box-shadow:0 0 8px 1px rgba(var(--k),.8)}
.tile{--k:var(--k-slate);--t:var(--t-sky);display:flex;flex-direction:column;min-width:0;padding:14px;border-radius:16px;border:1px solid var(--rim);background:var(--inset)}
.tile>*+*{margin-top:10px}
.tile.dash{border-style:dashed}
.tile-head{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:6px}
.tile-title{font-size:13.5px;font-weight:800;color:var(--t)}
.callout{--k:var(--k-slate);--t:var(--muted);padding:10px 12px;border-radius:12px;border:1px solid rgba(var(--k),.3);background:rgba(var(--k),.08);color:var(--t);font-size:12.5px;line-height:1.55}
.card.is-shutter{border-color:rgba(var(--k-sky),.5)}
.cfg-head{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:10px;padding-bottom:12px;border-bottom:1px solid var(--rim)}
.ext-card{border-color:rgba(var(--k-sky),.55);margin-bottom:24px}
.ext-title{font-size:15.5px;font-weight:800;color:var(--t-sky)}
.ext-ico{font-size:26px;line-height:1}
.ext-q{font-size:13.5px;font-weight:700}
.ext-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px;align-items:center}
#extModuleOptions{margin-top:14px}
.secbox{display:flex;flex-direction:column;padding:18px;border-radius:24px;border:1.5px solid rgba(var(--k),.4);background:rgba(var(--k),.05)}
.secbox>*+*{margin-top:16px}
.sec-head{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:10px;padding-bottom:12px;border-bottom:1px solid var(--rim)}
.sec-id{display:flex;align-items:center;gap:12px;min-width:0}
.sec-ico{display:flex;align-items:center;justify-content:center;flex:none;width:44px;height:44px;border-radius:50%;font-size:21px;line-height:1;background:radial-gradient(circle at 32% 26%,rgba(255,255,255,.6),rgba(var(--k),.5) 40%,rgba(var(--k),.2) 100%);box-shadow:inset 0 -4px 8px rgba(0,0,0,.18),0 6px 18px -4px rgba(var(--k),var(--glow))}
.sec-title{font-size:16px;font-weight:800;color:var(--t)}
.sec-sub{font-size:12px;color:var(--muted)}
.sec-body{display:flex;flex-direction:column}
.sec-body>*+*{margin-top:14px}
.hint-row{display:flex;align-items:center;flex-wrap:wrap;gap:6px 14px;margin-top:8px;font-size:12px}
.pair-grid{display:grid;grid-template-columns:2fr 1fr;gap:16px;align-items:start}
.grid-2col{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.pair-grid>*,.grid-2col>*{min-width:0}
.mode-card{display:flex;flex-direction:column;min-width:0;padding:12px 14px;border-radius:16px;border:1.5px solid var(--ctl);background:var(--inset);cursor:pointer;transition:border-color .2s,background-color .2s;-webkit-user-select:none;user-select:none}
.mode-card>*+*{margin-top:6px}
.mode-card.selected{border-color:var(--t-sky);background:rgba(var(--k-sky),.14)}
.mc-head{display:flex;align-items:center;gap:8px}

/* ---- durum noktasi (orb), anahtar, panjur dugmeleri ---- */
.status-indicator{display:inline-block;flex:none;width:14px;height:14px;border-radius:50%;background:radial-gradient(circle at 34% 28%,#fff 0,#CBD5E1 20%,#64748B 56%,#334155 100%);box-shadow:inset 0 -2px 3px rgba(0,0,0,.35),0 0 0 1px var(--rim)}
.status-indicator.on{background:radial-gradient(circle at 34% 28%,#fff 0,#FFD36B 24%,#FFB020 58%,#E07A00 100%);box-shadow:inset 0 -2px 3px rgba(120,53,15,.4),0 0 0 3px rgba(var(--k-amber),.22),0 0 14px 2px rgba(var(--k-amber),var(--glow))}
.status-indicator.moving{background:radial-gradient(circle at 34% 28%,#fff 0,#A5F3FC 24%,#22D3EE 58%,#0E7490 100%);box-shadow:inset 0 -2px 3px rgba(8,51,68,.4),0 0 0 3px rgba(var(--k-cyan),.22),0 0 14px 2px rgba(var(--k-cyan),var(--glow));animation:orb 1.1s ease-in-out infinite}
.switch-btn{position:relative;display:block;flex:none;width:60px;height:34px;border:1px solid var(--ctl);border-radius:999px;background:var(--swoff);cursor:pointer;transition:background .25s,box-shadow .25s,border-color .25s}
.switch-btn::after{content:"";position:absolute;top:-6px;right:-4px;bottom:-6px;left:-4px}
.switch-knob{position:absolute;top:3px;left:3px;width:26px;height:26px;border-radius:50%;background:var(--knob);box-shadow:inset 0 1px 1px rgba(255,255,255,.55),0 2px 6px rgba(0,0,0,.4);transition:left .25s cubic-bezier(.3,.9,.3,1)}
.switch-btn.on{border-color:transparent;background:linear-gradient(135deg,var(--swa),var(--swb));box-shadow:0 0 16px -2px rgba(var(--k-amber),var(--glow))}
.switch-btn.on .switch-knob{left:29px;background:var(--knob-on)}
.shutter-controls{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
.shutter-btn{--k:var(--k-slate);--t:var(--text);min-height:46px;padding:8px 4px;border:1.5px solid var(--t);border-radius:999px;background:rgba(var(--k),.12);color:var(--t);font-size:12.5px;font-weight:800;letter-spacing:.02em;text-align:center;cursor:pointer;transition:transform .12s ease,background-color .15s ease}
.shutter-btn:active{transform:scale(.96)}
.shutter-btn.s-up{--k:var(--k-emerald);--t:var(--t-emerald);--f1:#6EE7B7;--f2:#10B981}
.shutter-btn.s-stop{--k:var(--k-rose);--t:var(--t-rose)}
.shutter-btn.s-down{--k:var(--k-sky);--t:var(--t-sky);--f1:#93C5FD;--f2:#3B82F6}
.shutter-btn.active{border-color:transparent;color:var(--ink);background:linear-gradient(135deg,var(--f1,#fff),var(--f2,#cbd5e1));box-shadow:inset 0 1px 0 rgba(255,255,255,.55),0 8px 20px -8px rgba(var(--k),.9)}
.di-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(100px,1fr));gap:10px}
.di-pill{display:flex;flex-direction:column;align-items:center;min-width:0;padding:10px 6px;border-radius:16px;border:1px solid var(--rim);background:var(--surf);text-align:center;font-size:13px;font-weight:700}
.di-pill.active{border-color:rgba(var(--k-emerald),.65);background:rgba(var(--k-emerald),.14);color:var(--t-emerald);box-shadow:0 0 18px -6px rgba(var(--k-emerald),var(--glow))}
.di-line>*+*{margin-left:4px}
.di-ext{font-size:11px;color:var(--t-violet)}
.di-state{margin-top:2px;font-size:11.5px;font-weight:600;color:var(--muted)}
.di-pill.active .di-state{color:var(--t-emerald)}

/* ---- form ---- */
input[type="text"],input[type="password"],input[type="number"],select{width:100%;min-height:44px;padding:10px 14px;border:1.5px solid var(--ctl);border-radius:12px;background-color:var(--field);color:var(--text);font-size:16px;line-height:1.3}
select{padding-right:38px;-webkit-appearance:none;appearance:none;background-image:linear-gradient(45deg,transparent 50%,currentColor 50%),linear-gradient(135deg,currentColor 50%,transparent 50%);background-position:calc(100% - 20px) 50%,calc(100% - 14px) 50%;background-size:6px 6px,6px 6px;background-repeat:no-repeat}
input[type="text"]:focus,input[type="password"]:focus,input[type="number"]:focus,select:focus{outline:none;border-color:var(--focus);box-shadow:0 0 0 3px rgba(var(--k-cyan),.38)}
select option{background-color:var(--bg1);color:var(--text)}
::placeholder{color:var(--faint);opacity:1}
input[type="checkbox"],input[type="radio"]{flex:none;width:22px;height:22px;margin:0;accent-color:#2563EB}
input.inp-num{width:92px;flex:none;text-align:center;font-weight:800}
input.inp-strong{font-weight:700}
.row2>select,.row2>input{flex:1 1 auto;width:auto;min-width:0}
.sys-list input{display:inline-block;width:100%;max-width:240px;padding:6px 12px;vertical-align:middle}
.chk{display:flex;align-items:center;gap:10px;min-height:44px;font-size:13px;color:var(--muted);cursor:pointer}
.rt-box{display:flex;align-items:center;gap:6px;flex:none}
.err-banner{display:none;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:10px;margin-bottom:14px;padding:12px 14px;border-radius:14px;border:1px solid rgba(var(--k-rose),.5);background:rgba(var(--k-rose),.14);color:var(--t-rose);font-size:13px}
.terminal-window{height:320px;max-height:55vh;margin-bottom:12px;padding:14px;overflow-y:auto;border-radius:16px;border:1px solid var(--rim);background:#050A14;color:#6EE7B7;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px;line-height:1.5;white-space:pre-wrap;word-break:break-word;overflow-wrap:anywhere}
.rs-bar{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:10px;margin-bottom:12px}
.rs-tools{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:12px}
.rs-send{display:flex;flex-wrap:wrap;gap:10px}
.rs-bar select,.rs-send select{width:130px}
.rs-send input{flex:1 1 180px;width:auto;min-width:0}
.secret-box{padding:12px;border-radius:14px;border:1.5px dashed var(--t-amber);background:var(--field);font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px;line-height:1.7;word-break:break-all;overflow-wrap:anywhere;-webkit-user-select:all;user-select:all}

/* ---- Wi-Fi ---- */
.wifi-card{padding:16px;border-radius:18px;border:1px solid var(--rim);background:var(--inset)}
.wifi-card.ok{--k:var(--k-emerald);--t:var(--t-emerald);border-color:rgba(var(--k-emerald),.45);background:rgba(var(--k-emerald),.10)}
.wifi-card.ap{--k:var(--k-amber);--t:var(--t-amber);border-color:rgba(var(--k-amber),.5);background:rgba(var(--k-amber),.10)}
.wst{display:flex;align-items:flex-start;gap:14px}
.wst-ico{flex:none;font-size:28px;line-height:1}
.wst-body{flex:1;min-width:0}
.wst-head{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:6px}
.wst-title{font-size:15px;font-weight:800;color:var(--t)}
.wst-lines{margin-top:10px;font-size:13.5px;line-height:1.9;word-break:break-word;overflow-wrap:anywhere}
.wst-ssid{font-weight:800;color:var(--t-sky)}
.chip-ip{display:inline-block;padding:2px 10px;border-radius:8px;background:rgba(var(--k),.16);color:var(--t);font-weight:800;word-break:break-word;overflow-wrap:anywhere}
a.chip-ip{text-decoration:underline}
.wst-tip{margin-top:12px;padding:10px 12px;border-radius:12px;border-left:3px solid var(--t);background:var(--inset);font-size:12.5px;line-height:1.55;color:var(--muted)}
.net-list{display:flex;flex-direction:column;max-height:320px;margin-top:4px;overflow-y:auto;-webkit-overflow-scrolling:touch}
.net-list>*+*{margin-top:8px}
.net-row{display:flex;align-items:center;gap:10px;width:100%;min-height:50px;padding:10px 14px;border:1px solid var(--ctl);border-radius:14px;background:var(--inset);color:var(--text);font-size:15px;text-align:left;cursor:pointer;transition:border-color .15s,background-color .15s}
.net-row.sel{border:2px solid var(--t-sky);padding:9px 13px;background:rgba(var(--k-sky),.16)}
.net-lock{flex:none;width:24px;text-align:center}
.net-ssid{flex:1 1 auto;min-width:0;font-weight:700;word-break:break-word;overflow-wrap:anywhere}
.net-rssi{flex:none;min-width:64px;text-align:right;font-size:12.5px;color:var(--muted);font-variant-numeric:tabular-nums}
.bars{display:inline-flex;align-items:flex-end;flex:none;height:18px}
.bars i{display:block;width:4px;margin-right:3px;border-radius:2px;background:var(--baroff)}
.bars i:last-child{margin-right:0}
.bars i.on{background:linear-gradient(180deg,#6EE7B7,#10B981)}
.conn-state{display:none;margin-top:14px;padding:12px 14px;border-radius:14px;border:1px solid transparent;font-size:13.5px;line-height:1.6;word-break:break-word;overflow-wrap:anywhere}
.conn-state a{color:inherit;font-weight:700;text-decoration:underline}
.conn-state.progress{display:block;border-color:rgba(var(--k-sky),.5);background:rgba(var(--k-sky),.12);color:var(--t-sky)}
.conn-state.ok{display:block;border-color:rgba(var(--k-emerald),.5);background:rgba(var(--k-emerald),.12);color:var(--t-emerald)}
.conn-state.err{display:block;border-color:rgba(var(--k-rose),.5);background:rgba(var(--k-rose),.12);color:var(--t-rose)}
.conn-state.warn{display:block;border-color:rgba(var(--k-amber),.55);background:rgba(var(--k-amber),.12);color:var(--t-amber)}

/* ---- anahtar kutusu, katman, bildirim ---- */
.key-gate{display:none;max-width:560px;margin:20px auto;padding:0 16px}
.key-gate .card>*+*{margin-top:10px}
.overlay{position:fixed;top:0;right:0;bottom:0;left:0;z-index:1500;display:none;align-items:flex-start;justify-content:center;padding:16px;overflow-y:auto;-webkit-overflow-scrolling:touch;background:rgba(3,7,18,.93)}
.overlay-card{display:flex;flex-direction:column;width:100%;max-width:440px;margin:auto 0;padding:22px;border-radius:24px;border:1px solid var(--rim);background-color:var(--bg1);background-image:linear-gradient(180deg,var(--surf2),var(--surf));box-shadow:inset 0 1px 0 var(--hi),0 24px 60px -20px rgba(0,0,0,.8);animation:rise .22s ease both}
.overlay-card>*+*{margin-top:12px}
.auth-box{flex-direction:column}
.auth-box>*+*{margin-top:10px}
.toast{position:fixed;left:16px;right:16px;bottom:16px;bottom:calc(16px + env(safe-area-inset-bottom));z-index:2000;display:none;max-width:460px;margin:0 auto;padding:14px 18px;border-radius:18px;background:linear-gradient(135deg,var(--p1),var(--p2));color:#fff;font-size:14px;font-weight:700;line-height:1.45;text-align:center;word-break:break-word;overflow-wrap:anywhere;box-shadow:inset 0 1px 0 rgba(255,255,255,.28),0 16px 36px -12px rgba(0,0,0,.65);animation:rise .22s ease both}
.toast.err{background:linear-gradient(135deg,var(--d1),var(--d2))}
@supports ((-webkit-backdrop-filter:blur(1px)) or (backdrop-filter:blur(1px))){
.overlay{background:rgba(3,7,18,.7);-webkit-backdrop-filter:blur(10px);backdrop-filter:blur(10px)}
}
table{width:100%;margin-top:10px;border-collapse:collapse;border-radius:14px;overflow:hidden;background:var(--surf)}
th,td{padding:12px 14px;border-bottom:1px solid var(--rim);font-size:14px;text-align:left;word-break:break-word;overflow-wrap:anywhere}
th{background:var(--surf2);color:var(--muted);font-size:12px;text-transform:uppercase}

/* ---- renk degistiriciler ve metin tonlari (bilesenlerden SONRA: ayni oncelikte kazanir) ---- */
.k-sky{--k:var(--k-sky);--t:var(--t-sky)}.k-cyan{--k:var(--k-cyan);--t:var(--t-cyan)}.k-emerald{--k:var(--k-emerald);--t:var(--t-emerald)}.k-amber{--k:var(--k-amber);--t:var(--t-amber)}.k-violet{--k:var(--k-violet);--t:var(--t-violet)}
.tile.k-emerald,.tile.k-sky,.tile.k-amber{border-color:rgba(var(--k),.34);background:rgba(var(--k),.07)}
.btn.k-cyan.btn-outline{border-color:var(--t);color:var(--t)}
.t-sky{color:var(--t-sky)}.t-cyan{color:var(--t-cyan)}.t-emerald{color:var(--t-emerald)}.t-amber{color:var(--t-amber)}.t-rose{color:var(--t-rose)}

/* ---- flex 'gap' desteklemeyen tarayicilar (iOS < 14.1, Chrome < 84): betik <html>'e 'nogap' ekler ---- */
.nogap .row>*,.nogap .row-between>*,.nogap .seg>*,.nogap .hint-row>*,.nogap .tile-head>*,.nogap .card-header>*,.nogap .cfg-head>*,.nogap .sec-head>*,.nogap .wst-head>*,.nogap .header-info>*,.nogap .rs-bar>*,.nogap .rs-tools>*,.nogap .rs-send>*,.nogap .err-banner>*,.nogap header>*{margin:3px 6px 3px 0}
.nogap .nav-tabs>*{margin-right:4px}
.nogap .logo-title>*+*,.nogap .sec-id>*+*,.nogap .wst>*+*,.nogap .mc-head>*+*,.nogap .net-row>*+*,.nogap .chk>*+*,.nogap .row2>*+*,.nogap .rt-box>*+*{margin-left:10px}

/* ---- duyarli ---- */
@media (min-width:720px){header{padding:16px 24px}.header-info{flex:0 1 auto}.nav-tabs{padding:8px 24px 0}.content-section{padding:24px}}
@media (max-width:720px){.pair-grid,.grid-2col{grid-template-columns:1fr !important}}
@media (max-width:380px){.content-section{padding:14px 12px 24px}.card{padding:14px}.secbox{padding:14px}.btn{padding-left:14px;padding-right:14px}.shutter-btn{font-size:12px}}
@media (prefers-reduced-motion:reduce){*,*::before,*::after{animation:none !important;transition:none !important;scroll-behavior:auto !important}}
</style>
</head>
<body>

<header>
  <div class="logo-title">
    <img id="logoImg" class="logo-img" alt="">
    <div class="app-head">
      <h1 class="app-title" id="hdrDevName">Akıllı Ev &amp; Bina Kontrol</h1>
      <span class="app-sub">Waveshare ESP32-S3 Endüstriyel Pano Modülü</span>
    </div>
  </div>
  <button type="button" class="btn btn-outline btn-sm" id="btnLogout" style="display: none;" onclick="logout()" title="Bu tarayıcıda kayıtlı cihaz anahtarını unut">Çıkış</button>
  <div class="header-info">
    <span>🌐 IP: <b id="hdrIp">-</b></span>
    <span>📶 WiFi: <b id="hdrRssi">-</b></span>
    <span>⏱️ Uptime: <b id="hdrUptime">-</b></span>
  </div>
</header>

<div class="ap-banner" id="apBanner" role="status">🔧 Kurulum modu (AP): yalnızca Wi-Fi ayarlarını değiştirebilirsiniz.</div>

<div class="nav-tabs" role="tablist">
  <button type="button" class="nav-tab active" data-tab="control" role="tab" aria-selected="true" onclick="switchTab('control', this)">⚡ Kontrol</button>
  <button type="button" class="nav-tab" data-tab="config" role="tab" aria-selected="false" onclick="switchTab('config', this)">⚙️ Kanal Ayarları</button>
  <button type="button" class="nav-tab" data-tab="wifi" role="tab" aria-selected="false" onclick="switchTab('wifi', this)">📶 Wi-Fi (Station)</button>
  <button type="button" class="nav-tab" data-tab="rs485" role="tab" aria-selected="false" onclick="switchTab('rs485', this)">📟 RS485 Terminal</button>
  <button type="button" class="nav-tab" data-tab="system" role="tab" aria-selected="false" onclick="switchTab('system', this)">ℹ️ Sistem</button>
</div>

<!-- AP kaynaklı (anahtarsız) kurulum modunda Wi-Fi dışındaki sekmelerde gösterilir -->
<div class="key-gate" id="keyGate">
  <div class="card">
    <h3 class="card-h">🔑 Bu işlem için cihaz anahtarı gerekir</h3>
    <p class="muted">Kurulum modunda (AP) yalnızca Wi-Fi ayarlarını anahtarsız değiştirebilirsiniz. Diğer ayarlar için cihaz anahtarını girin (anahtar etikette ve uygulamada gösterilmez; kurulum sırasında fabrika/servis aracı verir).</p>
    <input type="password" id="gateKey" placeholder="Cihaz anahtarı" aria-label="Cihaz anahtarı" autocomplete="off" onkeydown="if(event.key==='Enter')submitGateKey()">
    <button class="btn btn-primary" onclick="submitGateKey()">Giriş</button>
    <span class="muted" id="gateMsg" role="alert"></span>
  </div>
</div>

<!-- ================= TAB 1: KONTROL ================= -->
<div id="tab-control" class="content-section active" role="tabpanel">
  <div class="quick-actions">
    <button class="btn btn-secondary" onclick="cmdAll('lightsoff')">💡 Tüm Işıkları Kapat</button>
    <button class="btn btn-secondary" onclick="cmdAll('shuttersdown')">🔽 Tüm Panjurları İndir</button>
    <button class="btn btn-secondary" onclick="cmdAll('shuttersup')">▲ Tüm Panjurları Kaldır</button>
    <button class="btn btn-outline" onclick="cmdAll('shuttersstop')">⏹ Panjurları Durdur</button>
  </div>

  <div class="section-title">
    <span>🎛️ Röle ve Cihaz Durumları</span>
    <span class="note" id="liveStatusTxt">Canlı güncelleniyor</span>
  </div>

  <div class="cards-grid" id="relaysGrid"></div>

  <div class="section-title">
    <span>🔘 Dijital Girişler (8DI Duvar Butonları)</span>
    <span class="note">DGND ile temas anında yeşile döner</span>
  </div>
  <div class="di-grid" id="diGrid"></div>
</div>

<!-- ================= TAB 2: KANAL AYARLARI ================= -->
<div id="tab-config" class="content-section" role="tabpanel">

  <div class="err-banner" id="cfgLoadError">
    <span>Yapılandırma cihazdan yüklenemedi.</span>
    <button class="btn btn-outline btn-sm" onclick="loadConfig(3)">Tekrar dene</button>
  </div>

  <!-- 📦 Ek Modül Kurulum Kartı -->
  <div class="card ext-card">
    <div class="cfg-head">
      <div class="row">
        <span class="ext-ico">📦</span>
        <div>
          <div class="ext-title">Harici Genişletme Modülü Kurulumu (RS485)</div>
          <div class="note">Daire panosunda ilave röle ve giriş genişletme kartı kullanılacak mı?</div>
        </div>
      </div>
      <div class="row">
        <span class="ext-q">Ek modül kuracak mısınız?</span>
        <button type="button" class="switch-btn" id="swExtModule" role="switch" aria-checked="false" aria-label="Ek modül kuracak mısınız?" onclick="toggleExtModule()"><span class="switch-knob"></span></button>
      </div>
    </div>

    <div id="extModuleOptions" style="display: none;">
      <div class="ext-grid">
        <div>
          <label class="lbl" for="selExtChannels">Ek Modül Kaç Kanallı? (Piyasa Seçenekleri)</label>
          <select id="selExtChannels" onchange="onExtChannelsChange(this.value)">
            <option value="2">2 Kanallı Modül (+2 Röle / +2 DI - 1 Panjur)</option>
            <option value="4">4 Kanallı Modül (+4 Röle / +4 DI - 2 Panjur)</option>
            <option value="8" selected>8 Kanallı Modül (+8 Röle / +8 DI - 4 Panjur) [En Yaygın]</option>
            <option value="12">12 Kanallı Modül (+12 Röle / +12 DI - 6 Panjur)</option>
            <option value="16">16 Kanallı Modül (+16 Röle / +16 DI - 8 Panjur) [Yaygın]</option>
            <option value="24">24 Kanallı Modül (+24 Röle / +24 DI - 12 Panjur)</option>
            <option value="32">32 Kanallı Modül (+32 Röle / +32 DI - 16 Panjur) [Maksimum]</option>
          </select>
        </div>
        <div>
          <label class="lbl" for="inpExtAddr">Modbus Slave ID (RS485 Adresi):</label>
          <input type="number" id="inpExtAddr" class="inp-num" value="1" min="1" max="247" onchange="onExtAddressChange(this.value)">
        </div>
        <div class="callout k-sky">
          ⚡ <b>Toplam Sistem Kapasitesi:</b> <span id="lblTotalCapacity" class="t-cyan fw">16 Röle / 16 Giriş (8 Çift)</span>
        </div>
      </div>
    </div>
  </div>

  <div class="section-title">
    <span id="cfgRelayTitle">⚙️ Röle Çıkış Yapılandırması</span>
    <button class="btn btn-primary" onclick="saveRelayConfig()">💾 Röle Ayarlarını Kaydet</button>
  </div>
  <p class="hint mb">
    Panjur motorları 2 röle (Yukarı + Aşağı) gerektirir ve birleşik grup olarak çalışır; yön değişiminde <b>yazılımsal</b> 500 ms ölü zaman uygulanır.
    Bu yazılımsal bir korumadır: motor güvenliği için <b>harici kontaktör veya mekanik interlock</b> kullanılması önerilir. Lamba veya kilit için münferit seçim yapabilirsiniz.
  </p>
  <div id="cfgRelayPairsContainer" class="stack"></div>

  <div class="section-title" style="margin-top: 36px;">
    <span id="cfgDITitle">🔘 Giriş Yapılandırması (Duvar Butonları &amp; Sensörler)</span>
    <button class="btn btn-primary" onclick="saveDIConfig()">💾 Giriş Ayarlarını Kaydet</button>
  </div>
  <p class="hint mb">
    Duvardaki buton tesisatınıza göre seçim yapın. Panjuru tek yaylı butonla bağlarsanız 2. klemens serbest kalır ve evdeki başka bir lamba/kapı için değerlendirilebilir.
  </p>
  <div id="cfgDIPairsContainer" class="stack"></div>
</div>

<!-- ================= TAB 3: WIFI & AG ================= -->
<div id="tab-wifi" class="content-section" role="tabpanel">
  <div class="card card-narrow">

    <!-- Wi-Fi Bağlantı Durumu Kartı -->
    <div id="wifiStatusCard" class="wifi-card">
      <div class="note">Bağlantı durumu yükleniyor...</div>
    </div>

    <h3 class="card-h">📶 Ev Wi-Fi Ağına Bağlan (Station Modu)</h3>
    <p class="hint">Cihazın ev modemi üzerinden yerel ağa bağlanmasını sağlar. Böylece modeme bağlı tüm telefon ve bilgisayarlardan doğrudan erişebilirsiniz. Wi-Fi bilgileri yalnızca bağlantı doğrulanınca kalıcı olarak kaydedilir.</p>

    <div class="row-between">
      <span class="lbl-sm">📡 Çevredeki Wi-Fi Ağları:</span>
      <button type="button" class="btn btn-outline btn-sm" id="btnWifiRescan" onclick="scanWifi(true)">🔄 Ağları Yenile</button>
    </div>
    <div id="wifiNetList" class="net-list" role="listbox" aria-label="Çevredeki Wi-Fi ağları"></div>
    <span id="scanStatus" class="note" style="margin-top: 6px;"></span>

    <div>
      <button type="button" id="btnWifiQr" class="btn btn-outline btn-block k-cyan" onclick="triggerWifiQrScan()">
        📷 Modem Wi-Fi Karekodu Tara (Kamera / Fotoğraf)
      </button>
      <input type="file" id="wifiQrFileInput" accept="image/*" capture="environment" style="display: none;" onchange="handleWifiQrFile(event)">
      <span id="qrHint" class="note" style="display: block; margin-top: 6px;">
        Modem etiketindeki veya telefonunuzdaki Wi-Fi karekodunu taratarak SSID ve şifreyi otomatik doldurabilirsiniz.
      </span>
    </div>

    <div>
      <label for="wifiSsid" class="lbl">Seçilen Wi-Fi Adı (SSID):</label>
      <input type="text" id="wifiSsid" placeholder="Listeden bir ağa dokunun veya adı yazın" autocomplete="off" autocapitalize="off" spellcheck="false">
    </div>

    <div>
      <label for="wifiPass" class="lbl">Wi-Fi Şifresi:</label>
      <input type="password" id="wifiPass" placeholder="Wi-Fi Şifreniz" autocomplete="off">
      <label class="chk">
        <input type="checkbox" id="wifiPassShow" onchange="toggleWifiPass()"> Şifreyi göster
      </label>
    </div>

    <div class="row2">
      <button type="button" id="btnWifiConnect" class="btn btn-primary" style="flex: 1;" onclick="connectWifi()">Bağlan ve Kalıcı Kaydet</button>
      <button id="btnWifiDisconnect" class="btn btn-danger btn-sm" style="display: none;" onclick="disconnectWifi()">Bağlantıyı Kes</button>
    </div>

    <div id="wifiConnState" class="conn-state" role="status" aria-live="polite"></div>
  </div>
</div>

<!-- ================= TAB 4: RS485 ================= -->
<div id="tab-rs485" class="content-section" role="tabpanel">
  <div class="rs-bar">
    <div class="row">
      <span class="lbl-sm">Baud Rate:</span>
      <select id="rs485Baud" aria-label="Baud Rate" onchange="changeRs485Baud()">
        <option value="9600">9600</option>
        <option value="19200">19200</option>
        <option value="38400">38400</option>
        <option value="115200">115200</option>
      </select>
    </div>
    <button class="btn btn-secondary" onclick="clearRs485Logs()">Temizle</button>
  </div>

  <div class="rs-tools">
    <button class="btn btn-primary" onclick="scanRs485Module()">🔍 Harici 8-Kanal Röle Modülünü Tara</button>
    <button class="btn btn-secondary" onclick="extRelayBtn(1, 2)">⚡ Modül Röle 1 Toggle</button>
    <button class="btn btn-secondary" onclick="extRelayBtn(0, 0)">🔴 Modül Tümünü Kapat</button>
  </div>

  <div class="terminal-window" id="rs485Terminal">Terminal başlatılıyor...</div>

  <div class="rs-send">
    <select id="rs485Format" aria-label="Veri biçimi">
      <option value="ascii">Metin (ASCII)</option>
      <option value="hex">HEX (Onaltılı)</option>
    </select>
    <input type="text" id="rs485Input" placeholder="Gönderilecek veri (Örn: 01 03 00 00 00 02 C4 0B veya Ping)" aria-label="Gönderilecek veri" autocomplete="off">
    <button class="btn btn-primary" onclick="sendRs485()">Gönder</button>
  </div>
</div>

<!-- ================= TAB 5: SISTEM ================= -->
<div id="tab-system" class="content-section" role="tabpanel">
  <div class="card card-narrow">
    <h3 class="card-h">ℹ️ Donanım ve Sistem Detayları</h3>
    <div class="sys-list">
      <div><b>İşlemci:</b> ESP32-S3 (Xtensa LX7 Çift Çekirdek, 240 MHz)</div>
      <div><b>Flash Hafıza:</b> 16 MB QIO</div>
      <div><b>PSRAM:</b> 8 MB Octal</div>
      <div><b>Cihaz Kimliği:</b> <span id="sysUid">-</span></div>
      <div><b>Yazılım Sürümü:</b> <span id="sysFw">-</span></div>
      <div><b>Bulut (MQTT):</b> <span id="sysMqtt">-</span></div>
      <div><b>Cihaz Adı:</b> <input type="text" id="sysDevName" maxlength="31" aria-label="Cihaz Adı" autocomplete="off"></div>
    </div>
    <div class="row">
      <button class="btn btn-primary" onclick="saveDevName()">İsmi Güncelle</button>
      <button class="btn btn-secondary" onclick="rebootSystem()">🔄 Yeniden Başlat</button>
      <button class="btn btn-danger" onclick="resetSystem()">⚠️ Fabrika Ayarlarına Dön</button>
    </div>

    <div class="sep">
      <h3 class="card-h" style="font-size: 15px;">🔑 Cihaz Anahtarını Değiştir</h3>
      <p class="muted">Yerel (LAN) erişim anahtarı 8-32 karakter olmalıdır (boşluksuz, yazdırılabilir ASCII). Değişince uygulamadaki kayıtlı anahtar da güncellenmelidir.</p>
      <div class="row">
        <input type="password" id="newKeyInput" placeholder="Yeni anahtar" aria-label="Yeni anahtar" style="flex: 1; min-width: 180px; width: auto;" autocomplete="off">
        <button class="btn btn-secondary" onclick="rekeyDevice()">Anahtarı Değiştir</button>
      </div>
    </div>
  </div>
</div>

<div class="toast" id="toast" role="status" aria-live="polite">İşlem başarılı!</div>

<!-- Kimlik doğrulama / provizyon katmanı -->
<div class="overlay" id="authOverlay">
  <div class="overlay-card">
    <h3 class="card-h" id="authTitle">Cihaz Anahtarı Gerekli</h3>
    <p class="muted" id="authMsg" role="alert"></p>

    <div id="authLoginBox" class="auth-box" style="display: flex;">
      <input type="password" id="authKey" placeholder="Cihaz anahtarı" aria-label="Cihaz anahtarı" autocomplete="off" onkeydown="if(event.key==='Enter')submitKey()">
      <button class="btn btn-primary" onclick="submitKey()">Giriş</button>
      <p class="muted">Anahtar etikette ve uygulamada gösterilmez; kurulum sırasında fabrika/servis aracı verir. Anahtarınız yoksa servis yetkilisine başvurun.</p>
      <p class="muted">Giriş bu tarayıcıda hatırlanır; ortak bir telefondaysanız işiniz bitince üstteki “Çıkış” düğmesine basın.</p>
    </div>

    <div id="authProvBox" class="auth-box" style="display: none;">
      <p class="muted">Bu cihaz henüz kurulmamış (provizyonsuz). Yerel erişim anahtarı ve kurtarma ağı (AP) parolası belirleyin. <b>Bu iki değeri güvenli bir yere kaydedin</b>; sonradan yalnızca anahtarla değiştirilebilir.</p>
      <p class="muted"><b>Sunucuya kayıtlı (etiketli) panolarda bu formu kullanmayın:</b> kurulumu fabrika aracı (USB) ya da uygulamanın kurulum sihirbazı yapar; burada belirlenen anahtarı sunucu bilmez.</p>
      <label class="muted" for="provKey">Yerel anahtar (8-32 karakter)</label>
      <div class="row2">
        <input type="text" id="provKey" maxlength="32" autocomplete="off" autocapitalize="off" spellcheck="false">
        <button class="btn btn-outline" onclick="fillRandom('provKey', 24)">Üret</button>
      </div>
      <label class="muted" for="provAp">Kurtarma ağı (AP) parolası (8-32 karakter)</label>
      <div class="row2">
        <input type="text" id="provAp" maxlength="32" autocomplete="off" autocapitalize="off" spellcheck="false">
        <button class="btn btn-outline" onclick="fillRandom('provAp', 16)">Üret</button>
      </div>
      <button class="btn btn-primary" onclick="submitProvision()">Cihazı Kur</button>
      <div class="secret-box" id="provResult" style="display: none;"></div>
      <button class="btn btn-secondary" id="provDone" style="display: none;" onclick="closeProv()">Kaydettim, kapat</button>
    </div>
  </div>
</div>

<script>
'use strict';

// ============================================================================
// Yardımcılar
// ============================================================================
function $(id) { return document.getElementById(id); }

// HTML'e basılan HER dış kaynaklı metin (SSID, kanal adı, cihaz adı, IP...) buradan geçer.
function esc(s) {
  return String(s === undefined || s === null ? '' : s).replace(/[&<>"'`]/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;', '`': '&#96;' }[c];
  });
}
function toInt(v, d) {
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : (d === undefined ? 0 : d);
}
function isIpv4(s) {
  return typeof s === 'string' && /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/.test(s);
}
const ENC = new TextEncoder();
function utf8Len(s) { return ENC.encode(String(s)).length; }
// UTF-8 karakterini bölmeden en fazla max bayt
function clampBytes(s, max) {
  let out = '';
  let n = 0;
  for (const ch of String(s)) {
    const l = ENC.encode(ch).length;
    if (n + l > max) break;
    out += ch;
    n += l;
  }
  return out;
}
function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

let toastTimer = null;
function showToast(msg, isError) {
  const t = $('toast');
  t.textContent = msg;
  t.className = 'toast' + (isError ? ' err' : '');
  t.style.display = 'block';
  clearTimeout(toastTimer);
  toastTimer = setTimeout(function () { t.style.display = 'none'; }, isError ? 4500 : 2500);
}

const ERR_TEXT = {
  unauthorized: 'Cihaz anahtarı hatalı veya eksik.',
  locked: 'Çok fazla hatalı deneme; kısa süre bekleyin.',
  unprovisioned: 'Cihaz henüz kurulmamış (anahtar tanımlı değil).',
  already_provisioned: 'Cihaz zaten kurulmuş.',
  bad_host: 'Geçersiz erişim adresi.',
  bad_origin: 'İstek kaynağı reddedildi.',
  unsupported_media_type: 'İstek biçimi desteklenmiyor.',
  invalid_json: 'Geçersiz veri biçimi.',
  empty_body: 'İstek gövdesi boş.',
  too_large: 'İstek çok büyük.',
  busy: 'Cihaz meşgul (panjur hareket ediyor veya işlem sürüyor).',
  storage_error: 'Ayarlar cihaz hafızasına yazılamadı.',
  storage: 'Ayarlar cihaz hafızasına yazılamadı.',
  invalid_ssid: 'Wi-Fi adı geçersiz (1-32 bayt).',
  invalid_password: 'Wi-Fi şifresi 8-63 karakter olmalı (açık ağ için boş bırakın).',
  invalid_key: 'Anahtar 8-32 karakter, boşluksuz yazdırılabilir ASCII olmalı.',
  invalid_ap_pass: 'AP parolası 8-32 karakter olmalı.',
  invalid_baud: 'Desteklenmeyen baud değeri.',
  shutter_channel: 'Panjur kanalları bu araçla doğrudan sürülemez.',
  invalid_pair: 'Geçersiz panjur çifti.',
  invalid_channel: 'Geçersiz kanal.',
  invalid_command: 'Geçersiz komut.',
  unknown_command: 'Bilinmeyen komut.',
  invalid_value: 'Geçersiz değer.',
  invalid_device_name: 'Cihaz adı geçersiz (en fazla 31 bayt, kontrol karakteri yok).',
  invalid_name: 'Kanal adı geçersiz (kontrol karakteri / bozuk karakter).',
  invalid_type: 'Geçersiz kanal tipi.',
  invalid_runtime: 'Süre aralık dışında (panjur 1-300 sn, darbe 1-60000 ms).',
  invalid_ext_channels: 'Ek modül kanal sayısı geçersiz.',
  invalid_ext_address: 'Modbus adresi 1-247 olmalı.',
  invalid_target_relay: 'Giriş için hedef röle geçersiz.',
  invalid_mode: 'Giriş modu geçersiz.',
  invalid_shutter_pair: 'Panjur röleleri (Yukarı + Aşağı) çift olarak tanımlanmalı.',
  send_failed: 'RS485 gönderimi başarısız.',
  no_response: 'Modülden yanıt alınamadı.',
  queue_full: 'Komut kuyruğu dolu, tekrar deneyin.',
  unavailable: 'Cihaz şu an yanıt veremiyor.',
  rate_limited: 'Çok sık Wi-Fi bağlantı isteği gönderildi; biraz bekleyip tekrar deneyin.'
};
function errText(r) {
  const code = r && r.data && r.data.error;
  // Cihaz nedeni ayrica bildirdiyse (ör. "ek modul panjuru hareket ediyor") duz metin olarak gosterilir
  const msg = r && r.data && typeof r.data.message === 'string' ? r.data.message.slice(0, 160) : '';
  if (msg) return msg;
  if (code && ERR_TEXT[code]) {
    const wait = (code === 'rate_limited' && r.data) ? toInt(r.data.retry_after) : 0;
    return ERR_TEXT[code] + (wait > 0 ? ' (' + wait + ' sn)' : '');
  }
  return 'İşlem başarısız' + (code ? ' (' + code + ')' : ' (HTTP ' + (r ? r.status : '?') + ')');
}

// ============================================================================
// API istemcisi (X-Device-Key, zaman aşımı, kimlik hataları)
// ============================================================================
// Cihaz anahtarı KALICI saklanır: localStorage'da 'ahbu_key' (bir kez girilince sonraki açılışlarda sorulmaz).
// Depo yalnız bu sayfanın kaynağına (http://<pano ip>) özgüdür (tarayıcı kaynak yalıtımı). localStorage yoksa/kapalıysa
// (gizli mod vb.) sessionStorage, o da yoksa yalnız bellek kullanılır. 'Çıkış' anahtarı hepsinden siler.
// Yalnızca cihazın KABUL ETTİĞİ anahtar yazılır; cihazın reddettiği (401) anahtar hemen silinir.
const KEY_NAME = 'ahbu_key';
function readStoredKey() {
  let v = '';
  try { v = localStorage.getItem(KEY_NAME) || ''; } catch (e) { v = ''; }
  if (v) return v;
  try { v = sessionStorage.getItem(KEY_NAME) || ''; } catch (e) { return ''; }
  if (v) {   // eski sürümden (yalnız oturum) kalan anahtar: kalıcı depoya taşı
    try { localStorage.setItem(KEY_NAME, v); sessionStorage.removeItem(KEY_NAME); } catch (e) { /* taşınamadı: oturumda kalır */ }
  }
  return v;
}
function writeStoredKey(k) {
  let kept = false;
  try { if (k) localStorage.setItem(KEY_NAME, k); else localStorage.removeItem(KEY_NAME); kept = true; } catch (e) { /* gizli mod */ }
  try {
    if (k && !kept) sessionStorage.setItem(KEY_NAME, k);   // localStorage yazılamadı: oturum yedeği
    else sessionStorage.removeItem(KEY_NAME);              // eski oturum kopyası kalmasın
  } catch (e) { /* yalnız bellek (deviceKey) */ }
}
let deviceKey = readStoredKey();
let keyPersisted = !!deviceKey;      // bellekteki anahtar depoda mı (cihaz onayladı)
let keyFromStorage = keyPersisted;   // bu açılışta depodan mı geldi (ileti seçimi)
let authNotice = '';                 // anahtar reddedilince gösterilen ileti (yoklama üzerine yazmasın)
const MSG_SAVED_KEY = 'Kayıtlı anahtar artık geçerli değil (değiştirilmiş veya cihaz sıfırlanmış olabilir). Yeni anahtarı girin.';
const MSG_WRONG_KEY = 'Anahtar hatalı. Tekrar deneyin.';
function storeKey(k) {               // k = cihazın kabul ettiği anahtar: kalıcı yazılır; '' hepsini siler
  deviceKey = k;
  keyPersisted = !!k;
  writeStoredKey(k);
  updateLogoutBtn();
}
function keyAccepted() { if (deviceKey && !keyPersisted) storeKey(deviceKey); }
function dropRejectedKey(k) {        // cihaz anahtarı reddetti: bellekten ve (aynıysa) depodan silinir
  if (deviceKey === k) { deviceKey = ''; keyPersisted = false; keyFromStorage = false; }
  if (readStoredKey() === k) writeStoredKey('');
  updateLogoutBtn();
}
// 'Çıkış': bu tarayıcıdaki kayıtlı anahtarı unutur (ortak telefonda işiniz bitince kullanın) ve sayfayı yeniler.
function logout() {
  authNotice = '';
  storeKey('');
  location.reload();
}
// AP kaynaklı anahtarsız kurulum modunda (apMode) 'Çıkış' gizlidir: orada kayıtlı anahtar kullanılmaz.
function updateLogoutBtn() {
  const b = $('btnLogout');
  if (b) b.style.display = (deviceKey && !apMode) ? 'inline-flex' : 'none';
}
// Başka sekmede giriş/çıkış yapıldıysa bu sekme de uyar (anahtar kurulum ekranı açıkken sayfa yenilenmez).
window.addEventListener('storage', function (e) {
  if (e.key !== null && e.key !== KEY_NAME) return;
  const v = readStoredKey();
  if (v === deviceKey) return;
  deviceKey = v;
  keyPersisted = !!v;
  keyFromStorage = !!v;
  updateLogoutBtn();
  if (v) schedulePoll(0);
  else if (authMode !== 'provision') location.reload();
});

const API_TIMEOUT_MS = 7000;
async function api(path, opts) {
  opts = opts || {};
  const headers = {};
  const sentKey = (deviceKey && !opts.nokey) ? deviceKey : '';   // nokey: AP kaynaklı anahtarsız yol (eski/yanlış anahtar gönderilmez)
  if (sentKey) headers['X-Device-Key'] = sentKey;
  let body;
  if (opts.json !== undefined) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(opts.json);
  }
  const ctl = new AbortController();
  const timer = setTimeout(function () { ctl.abort(); }, opts.timeout || API_TIMEOUT_MS);
  try {
    const res = await fetch(path, { method: opts.method || 'GET', headers: headers, body: body, cache: 'no-store', signal: ctl.signal });
    const ct = (res.headers.get('content-type') || '').toLowerCase();
    let data = null;
    if (opts.text) {
      data = await res.text();
    } else if (ct.indexOf('application/json') >= 0) {
      try { data = await res.json(); } catch (e) { data = null; }
    }
    const out = { ok: res.ok, status: res.status, data: data };
    if (sentKey) {
      if (sentKey !== deviceKey) {
        out.stale = true;   // yanıt, o arada değiştirilen/silinen eski anahtara ait: yok sayılır
      } else if (res.status === 401 || (res.status === 403 && data && data.error === 'unprovisioned')) {
        // Gönderilen anahtar reddedildi (yanlış/eski ya da cihaz sıfırlanmış): kayıtlı anahtar HEMEN silinir.
        // Aynı yanlış anahtarı yoklamayla tekrarlamak cihazda IP kilidini (5 hata -> 60 sn) tetiklerdi.
        out.keyRejected = true;
        if (res.status === 401) authNotice = keyFromStorage ? MSG_SAVED_KEY : MSG_WRONG_KEY;
        dropRejectedKey(sentKey);
      }
    }
    if (!opts.quiet) onAuthResponse(out);   // quiet: çağıran 401/403/423'ü kendisi yorumlar (AP kaynaklı yol sondajı vb.)
    return out;
  } finally {
    clearTimeout(timer);
  }
}

function onAuthResponse(r) {
  if (r.stale) return;
  if (apMode && (r.status === 401 || r.status === 423)) setApMode(false);   // AP kaynaklı yetki kalktı: anahtar gerekir
  if (r.status === 401) {
    showAuth('login', r.keyRejected ? authNotice : 'Devam etmek için cihaz anahtarını girin.');
  } else if (r.status === 423) {
    const s = (r.data && r.data.retry_after) ? r.data.retry_after : 60;
    showAuth('login', 'Çok fazla hatalı deneme. ' + s + ' sn sonra tekrar deneyin.');
  } else if (r.status === 403 && r.data && r.data.error === 'unprovisioned') {
    showAuth('provision');
  }
}

let authMode = '';
function showAuth(mode, msg) {
  authMode = mode;
  $('authOverlay').style.display = 'flex';
  $('authLoginBox').style.display = (mode === 'login') ? 'flex' : 'none';
  $('authProvBox').style.display = (mode === 'provision') ? 'flex' : 'none';
  $('authTitle').textContent = (mode === 'provision') ? 'Cihaz Kurulumu (Provizyon)' : 'Cihaz Anahtarı Gerekli';
  $('authMsg').textContent = msg || '';
}
function hideAuth() {
  if (authMode === 'provision' && $('provResult').style.display !== 'none') return;   // bilgileri okuyabilsin
  authMode = '';
  authNotice = '';
  $('authOverlay').style.display = 'none';
}

async function submitKey() {
  const k = $('authKey').value.trim();
  if (!k) { $('authMsg').textContent = 'Anahtarı girin.'; return; }
  authNotice = '';
  deviceKey = k;   // önce bellekte denenir; yalnız cihaz KABUL EDERSE kalıcı kaydedilir
  keyPersisted = false;
  keyFromStorage = false;
  updateLogoutBtn();
  try {
    const r = await api('/api/auth/check');
    if (r.ok) {
      storeKey(k);
      $('authKey').value = '';
      hideAuth();
      showToast('Giriş başarılı');
      schedulePoll(0);
      loadConfig(3);
    } else if (r.status !== 423) {
      if (deviceKey === k) deviceKey = '';   // 401'de api() zaten sildi
      updateLogoutBtn();
    }
  } catch (e) {
    $('authMsg').textContent = 'Pano ile bağlantı kurulamadı.';
  }
}

function closeProv() {
  $('provResult').style.display = 'none';
  $('provDone').style.display = 'none';
  $('provResult').textContent = '';
  hideAuth();
}

function fillRandom(id, len) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  const buf = new Uint32Array(len);
  crypto.getRandomValues(buf);
  let s = '';
  for (let i = 0; i < len; i++) s += alphabet[buf[i] % alphabet.length];
  $(id).value = s;
}

async function submitProvision() {
  const key = $('provKey').value;
  const ap = $('provAp').value;
  if (key.length < 8 || key.length > 32 || !/^[\x21-\x7E]+$/.test(key)) { showToast('Anahtar 8-32 karakter, boşluksuz olmalı.', true); return; }
  if (ap.length < 8 || ap.length > 32 || !/^[\x20-\x7E]+$/.test(ap)) { showToast('AP parolası 8-32 karakter olmalı.', true); return; }
  try {
    const r = await api('/api/factory/init', { method: 'POST', json: { local_key: key, ap_pass: ap } });
    if (!r.ok) { showToast(errText(r), true); return; }
    storeKey(key);
    const box = $('provResult');
    box.style.display = 'block';
    $('provDone').style.display = 'inline-flex';
    box.textContent = 'KAYDEDİN -> Yerel anahtar: ' + key + '  |  AP parolası: ' + ap +
      '  (Kurtarma ağının parolası değişti; Wi-Fi bağlantınız kesilirse yeni parolayla yeniden bağlanın.)';
    showToast('Cihaz kuruldu');
    schedulePoll(1000);
  } catch (e) {
    showToast('Pano ile bağlantı kurulamadı.', true);
  }
}

// ============================================================================
// AP kaynaklı (anahtarsız) Wi-Fi kurulum modu (CONTRACTS 3d)
// Teknisyen müşteride panonun kurtarma ağındayken internet yoktur; cihaz anahtarını sunucudan alamaz. Cihaz, istemci
// SoftAP arayüzündeyse (+ AP WPA2 + cihaz provizyonlu) YALNIZ GET /api/wifi/scan, POST /api/wifi/connect ve
// GET /api/wifi/status uçlarını anahtarsız açar. Bu modda yalnızca Wi-Fi sekmesi çalışır; diğer sekmeler anahtar ister.
// ============================================================================
let apMode = false;
let lastApStatus = null;

function setApMode(on) {
  on = !!on;
  const changed = (apMode !== on);
  apMode = on;
  if (document.body && document.body.classList) document.body.classList.toggle('ap-mode', on);
  $('apBanner').style.display = on ? 'block' : 'none';
  updateLogoutBtn();
  updateGate();
  if (on && changed && activeTab !== 'wifi') switchTab('wifi', document.querySelector('.nav-tab[data-tab="wifi"]'));
}

// Anahtar kutusu: yalnız AP kaynaklı modda ve Wi-Fi dışındaki sekmelerde
function updateGate() {
  $('keyGate').style.display = (apMode && activeTab !== 'wifi') ? 'block' : 'none';
}

// Anahtarsız sondaj: 200 -> bu istemci AP kaynaklı yetkili; 401/403/423 -> değil (anahtar gerekir).
async function probeApMode() {
  try {
    const r = await api('/api/wifi/status', { nokey: true, quiet: true });
    if (r.ok && r.data && typeof r.data === 'object' && typeof r.data.wifi_connect_state === 'string') {
      lastApStatus = r.data;
      return true;
    }
  } catch (e) { /* ağ hatası: AP kaynaklı sayılmaz */ }
  return false;
}

// AP modunda durum yoklaması: yalnız /api/wifi/status (tam durum anahtar ister)
async function fetchApStatus() {
  const r = await api('/api/wifi/status', { nokey: true, quiet: true });
  if (r.ok && r.data && typeof r.data === 'object') {
    lastApStatus = r.data;
    renderApStatus(r.data);
    return;
  }
  // AP kaynaklı yetki kalktı (AP kapandı/WPA2'den döndü/provizyon değişti): anahtar katmanı
  setApMode(false);
  onAuthResponse(r);
  throw new Error('AP durumu alınamadı: ' + r.status);
}

function renderApStatus(d) {
  $('hdrIp').textContent = d.wifi_connected ? (d.wifi_sta_ip || '-') : '-';
  $('hdrRssi').textContent = d.wifi_connected ? (toInt(d.wifi_rssi) + ' dBm') : 'Bağlı değil';
  $('hdrUptime').textContent = '-';
  renderWifiCard({
    wifi_connected: !!d.wifi_connected,
    wifi_sta_ssid: d.wifi_sta_ssid,
    wifi_sta_ip: d.wifi_sta_ip,
    wifi_sta_rssi: d.wifi_rssi,
    wifi_ap_active: !!d.ap_active,
    wifi_connect_state: d.wifi_connect_state,
    wifi_connect_reason: d.wifi_connect_reason
  });
}

// Anahtar kutusundan giriş (AP modunda diğer sekmeler için)
async function submitGateKey() {
  const msg = $('gateMsg');
  const k = $('gateKey').value.trim();
  if (!k) { msg.textContent = 'Anahtarı girin.'; return; }
  deviceKey = k;   // önce bellekte denenir; yalnız cihaz KABUL EDERSE kalıcı kaydedilir
  keyPersisted = false;
  keyFromStorage = false;
  try {
    const r = await api('/api/auth/check', { quiet: true });
    if (r.ok) {
      storeKey(k);
      $('gateKey').value = '';
      msg.textContent = '';
      setApMode(false);
      hideAuth();
      showToast('Giriş başarılı');
      schedulePoll(0);
      loadConfig(3);
      return;
    }
    if (deviceKey === k) deviceKey = '';   // 401'de api() zaten sildi
    updateLogoutBtn();
    if (r.status === 423) msg.textContent = 'Çok fazla hatalı deneme. ' + ((r.data && r.data.retry_after) ? r.data.retry_after : 60) + ' sn sonra tekrar deneyin.';
    else msg.textContent = MSG_WRONG_KEY;
  } catch (e) {
    if (deviceKey === k) deviceKey = '';
    updateLogoutBtn();
    msg.textContent = 'Pano ile bağlantı kurulamadı.';
  }
}

// ============================================================================
// Sekmeler
// ============================================================================
let activeTab = 'control';
function switchTab(tabId, el) {
  document.querySelectorAll('.nav-tab').forEach(function (t) { t.classList.remove('active'); t.setAttribute('aria-selected', 'false'); });
  document.querySelectorAll('.content-section').forEach(function (s) { s.classList.remove('active'); });
  if (el) {
    el.classList.add('active');
    el.setAttribute('aria-selected', 'true');
    if (el.scrollIntoView) { try { el.scrollIntoView({ block: 'nearest', inline: 'nearest' }); } catch (e) { /* eski tarayici */ } }
  }
  $('tab-' + tabId).classList.add('active');
  activeTab = tabId;
  updateGate();
  if (apMode && tabId !== 'wifi') return;   // anahtarsız AP modunda yalnız Wi-Fi sekmesi çalışır (diğerleri anahtar kutusu gösterir)
  if (tabId === 'config') { if (currentConfig) renderConfigTables(); else loadConfig(1); }
  if (tabId === 'wifi') { scanWifi(false); schedulePoll(0); }
  if (tabId === 'rs485') { refreshRs485Logs(); }
}

// ============================================================================
// Durum (yoklama: yolda-istek kilidi, gizli sekmede durur, hatada geri çekilir)
// ============================================================================
let lastStatus = null;
let statusInflight = false;
let failStreak = 0;
let pollTimer = null;

function schedulePoll(ms) {
  clearTimeout(pollTimer);
  pollTimer = setTimeout(pollStatus, ms);
}
async function pollStatus() {
  if (document.hidden) { schedulePoll(3000); return; }   // sekme gizliyken istek yok
  if (statusInflight) { schedulePoll(800); return; }     // önceki istek sürüyor: üst üste binme yok
  if (wifiConnecting) { schedulePoll(2500); return; }    // bağlantı sonucu ayrı (daha sık) yoklanır: cihazı iki kat yükleme
  statusInflight = true;
  try {
    await fetchStatus();
    failStreak = 0;
    $('liveStatusTxt').textContent = 'Canlı güncelleniyor';
  } catch (e) {
    failStreak++;
    $('liveStatusTxt').textContent = 'Bağlantı yok, yeniden deneniyor...';
  }
  statusInflight = false;
  schedulePoll(apMode ? 3000 : Math.min(1500 * Math.pow(2, Math.min(failStreak, 3)), 12000));
}
document.addEventListener('visibilitychange', function () { if (!document.hidden) schedulePoll(0); });

async function fetchStatus() {
  if (apMode) { await fetchApStatus(); return; }
  const r = await api('/api/status', { quiet: true });
  const d = r.data;
  const keyProblem = (r.status === 401 || r.status === 423);
  const restricted = !!(r.ok && d && d.provisioned !== false && !Array.isArray(d.relays));   // anahtarsız kısıtlı özet
  if (keyProblem || restricted) {
    // Anahtar yok/yanlış/kilitli: istemci AP kaynaklı mı? (anahtarsız Wi-Fi servis akışı, CONTRACTS 3d)
    if (await probeApMode()) {
      if (restricted) renderRestricted(d);
      hideAuth();
      setApMode(true);
      renderApStatus(lastApStatus);
      return;
    }
    onAuthResponse(r);   // 401/423: anahtar katmanı
    if (restricted) {
      renderRestricted(d);
      showAuth('login', authNotice || (deviceKey ? 'Anahtar kabul edilmedi.' : 'Devam etmek için cihaz anahtarını girin.'));
      return;
    }
    throw new Error('durum alınamadı: ' + r.status);
  }
  onAuthResponse(r);     // 403 unprovisioned vb.
  if (!r.ok || !d) throw new Error('durum alınamadı: ' + r.status);
  if (d.provisioned === false) {
    renderRestricted(d);
    showAuth('provision');
    return;
  }
  hideAuth();
  keyAccepted();   // tam durum geldi = anahtar cihazca onaylandi: kalici kaydet
  lastStatus = d;
  $('hdrDevName').textContent = d.device_name || '';
  $('hdrIp').textContent = d.ip || '-';
  $('hdrRssi').textContent = d.wifi_connected ? (d.wifi_rssi + ' dBm') : 'Bağlı değil';
  const up = toInt(d.uptime_sec);
  $('hdrUptime').textContent = Math.floor(up / 3600) + 's ' + Math.floor((up % 3600) / 60) + 'd ' + (up % 60) + 'sn';
  $('sysUid').textContent = d.device || '-';
  $('sysFw').textContent = d.fw || '-';
  $('sysMqtt').textContent = d.mqtt_configured ? (d.mqtt_connected ? 'Bağlı' : 'Kimlik var, bağlantı bekleniyor') : 'Kimlik tanımlı değil (yalnızca yerel)';
  renderRelays(d);
  renderDIs(d.dis);
  renderWifiCard(d);
  if (!currentConfig && !configLoading) loadConfig(3);   // anahtar geçerli: yapılandırma (AP modunda anahtarsız yüklenmez)
}

function renderRestricted(d) {
  $('hdrDevName').textContent = d.name || '';
  $('hdrIp').textContent = '-';
  $('hdrRssi').textContent = d.wifi_connected ? 'Bağlı' : 'Bağlı değil';
  $('sysUid').textContent = d.device || '-';
  $('sysFw').textContent = d.fw || '-';
}

function renderWifiCard(data) {
  const card = $('wifiStatusCard');
  if (!card) return;
  const btnDisconnect = $('btnWifiDisconnect');
  let cls;
  let html;

  if (data.wifi_connected) {
    if (btnDisconnect) btnDisconnect.style.display = apMode ? 'none' : 'inline-flex';   // bağlantıyı kesmek anahtar ister
    const ip = data.wifi_sta_ip;
    const ipHtml = isIpv4(ip)
      ? '<a class="chip-ip" href="http://' + esc(ip) + '" target="_blank" rel="noopener noreferrer">http://' + esc(ip) + '</a>'
      : esc(ip || '-');
    cls = 'wifi-card ok';
    html =
      '<div class="wst">' +
        '<div class="wst-ico">🟢</div>' +
        '<div class="wst-body">' +
          '<div class="wst-head">' +
            '<div class="wst-title">Modeme Bağlıyız (Ev Ağı Aktif)</div>' +
            '<span class="pill pill-live k-emerald">ÇEVRİMİÇİ</span>' +
          '</div>' +
          '<div class="wst-lines">' +
            '<div><b>Bağlı Bulunulan Ağ:</b> <span class="wst-ssid">' + esc(data.wifi_sta_ssid || 'Bilinmiyor') + '</span></div>' +
            '<div><b>Cihazın IP Adresi:</b> ' + ipHtml + '</div>' +
            '<div><b>Sinyal Gücü:</b> <span class="fw">' + esc(data.wifi_sta_rssi) + ' dBm</span></div>' +
          '</div>' +
          '<div class="wst-tip">' +
            '💡 <b>Başka bir ağa bağlanmak için:</b> Aşağıdaki listeden yeni Wi-Fi ağını seçip şifresini yazarak <i>"Bağlan ve Kalıcı Kaydet"</i> butonuna tıklayın.' +
          '</div>' +
        '</div>' +
      '</div>';
  } else {
    if (btnDisconnect) btnDisconnect.style.display = 'none';
    const apSsidHtml = data.wifi_ap_ssid ? ' <span class="fw">' + esc(data.wifi_ap_ssid) + '</span>' : '';
    const apLine = data.wifi_ap_active
      ? '<div><b>Kurulum/kurtarma ağı (AP) yayında:</b>' + apSsidHtml + '</div>' +
        (data.wifi_ap_ip ? '<div><b>Cihaz IP\'si:</b> <span class="chip-ip">' + esc(data.wifi_ap_ip) + '</span></div>' : '')
      : '<div><b>Durum:</b> Kurtarma ağı şu an kapalı (kesinti sürerse otomatik açılır).</div>';
    let connLine = '';
    if (data.wifi_connect_state === 'connecting') connLine = '<div><b>Bağlanılıyor...</b></div>';
    else if (data.wifi_connect_state === 'failed') connLine = '<div class="t-rose"><b>Son bağlanma denemesi başarısız</b> (neden kodu: ' + esc(data.wifi_connect_reason) + ')</div>';
    cls = 'wifi-card ap';
    html =
      '<div class="wst">' +
        '<div class="wst-ico">📡</div>' +
        '<div class="wst-body">' +
          '<div class="wst-head">' +
            '<div class="wst-title">Yerel Erişim Noktası (AP Modu)</div>' +
            '<span class="pill k-amber">MODEME BAĞLI DEĞİL</span>' +
          '</div>' +
          '<div class="wst-lines">' + apLine + connLine + '</div>' +
          '<div class="wst-tip">' +
            '👉 <b>Ev Ağına Bağlanmak İçin:</b> Aşağıdaki listeden ev Wi-Fi modeminize dokunun, şifrenizi girin ve <i>"Bağlan ve Kalıcı Kaydet"</i> butonuna tıklayın.' +
          '</div>' +
        '</div>' +
      '</div>';
  }
  const sig = cls + '|' + html;   // aynı içerik: DOM yeniden kurulmaz (odak/animasyon kaybolmaz)
  if (card._sig !== sig) {
    card._sig = sig;
    card.className = cls;
    card.innerHTML = html;
  }
}

function totalRelayCount() {
  if (!currentConfig) return 8;
  return currentConfig.ext_module_enabled ? (8 + toInt(currentConfig.ext_module_channels, 8)) : 8;
}

// ============================================================================
// Kontrol sekmesi
// ============================================================================
function renderRelays(data) {
  const grid = $('relaysGrid');
  const relays = Array.isArray(data.relays) ? data.relays : [];
  const shutters = Array.isArray(data.shutters) ? data.shutters : [];
  let html = '';

  for (let i = 0; i < relays.length; i++) {
    const r = relays[i];
    if (!r) continue;
    const type = toInt(r.type);

    // Panjur çiftinin ikinci kanalı ayrı kart olarak çizilmez
    if ((type === 1 || type === 2) && (i % 2 === 1)) continue;

    const isExt = (i >= 8);
    const modBadge = isExt
      ? '<span class="pill k-violet">📦 Ek Modül CH ' + (i - 7) + '</span>'
      : '';

    if (type === 1) { // Panjur kartı
      const pair1 = (i >> 1) + 1;   // 1 tabanlı panjur numarası
      let sh = null;
      for (let k = 0; k < shutters.length; k++) { if (toInt(shutters[k].pair) === pair1) { sh = shutters[k]; break; } }
      if (!sh) sh = { is_moving: false, dir: 0, pos: 0 };
      const dir = toInt(sh.dir);

      let stateBadge = '<span class="card-type-badge">⏹ Durdu</span>';
      let indicatorClass = 'status-indicator';
      if (sh.is_moving) {
        indicatorClass += ' moving';
        stateBadge = '<span class="card-type-badge mv">' + (dir === 1 ? '▲ Açılıyor...' : '▼ Kapanıyor...') + '</span>';
      }
      const baseName = String(r.name || '').replace(/ \(Yukari\)/i, '');

      html +=
        '<div class="card' + (sh.is_moving ? ' is-moving' : '') + '">' +
          '<div class="card-header">' +
            '<div class="row">' +
              '<span class="' + indicatorClass + '"></span>' +
              '<span class="card-title">🪟 ' + esc(baseName) + '</span>' + modBadge +
            '</div>' + stateBadge +
          '</div>' +
          '<div class="note">Konum: <b>%' + toInt(sh.pos) + '</b></div>' +
          '<div class="shutter-controls">' +
            '<button class="shutter-btn s-up' + (dir === 1 ? ' active' : '') + '" onclick="cmdShutter(' + pair1 + ', \'up\')">▲ AÇ</button>' +
            '<button class="shutter-btn s-stop" onclick="cmdShutter(' + pair1 + ', \'stop\')">⏹ DURDUR</button>' +
            '<button class="shutter-btn s-down' + (dir === 2 ? ' active' : '') + '" onclick="cmdShutter(' + pair1 + ', \'down\')">▼ KAPAT</button>' +
          '</div>' +
        '</div>';
    } else { // Normal lamba veya darbe rölesi
      const isLight = (type === 0);
      const icon = isLight ? '💡' : '⚡';
      const typeStr = isLight ? 'Aydınlatma' : 'Darbe (Tetik)';
      const onClass = r.state ? 'on' : '';
      const ch = i + 1;   // 1 tabanlı röle kanalı

      html +=
        '<div class="card' + (r.state ? ' is-on' : '') + '">' +
          '<div class="card-header">' +
            '<div class="row">' +
              '<span class="status-indicator ' + onClass + '"></span>' +
              '<span class="card-title">' + icon + ' ' + esc(r.name) + '</span>' + modBadge +
            '</div>' +
            '<span class="card-type-badge">' + typeStr + '</span>' +
          '</div>' +
          '<div class="row-between">' +
            '<span class="note">Durum: <b>' + (r.state ? 'AÇIK' : 'KAPALI') + '</b></span>' +
            (isLight
              ? '<button type="button" class="switch-btn ' + onClass + '" role="switch" aria-checked="' + (r.state ? 'true' : 'false') + '" aria-label="' + esc(r.name) + '" onclick="toggleRelay(' + ch + ')"><span class="switch-knob"></span></button>'
              : '<button class="btn btn-secondary btn-sm" onclick="triggerImpulse(' + ch + ')">⚡ Tetikle</button>') +
          '</div>' +
        '</div>';
    }
  }
  if (grid._html !== html) {   // aynı içerik: DOM yeniden kurulmaz (odak/animasyon kaybolmaz)
    grid._html = html;
    grid.innerHTML = html;
  }
}

function renderDIs(dis) {
  const grid = $('diGrid');
  const list = Array.isArray(dis) ? dis : [];
  let html = '';
  for (let i = 0; i < list.length; i++) {
    const d = list[i];
    if (!d) continue;
    html +=
      '<div class="di-pill' + (d.state ? ' active' : '') + '">' +
        '<div class="di-line"><span>DI ' + (i + 1) + '</span>' + (i >= 8 ? '<span class="di-ext">(Ek)</span>' : '') + '</div>' +
        '<div class="di-state">' + (d.state ? 'KAPALI (ON)' : 'AÇIK (OFF)') + '</div>' +
      '</div>';
  }
  if (grid._html !== html) {
    grid._html = html;
    grid.innerHTML = html;
  }
}

// Yoldaki komutu olan düğmeye ikinci basış yok sayılır (çift gönderim ve ters çevirme yok)
const pendingCmds = {};
async function sendCmd(key, path) {
  if (pendingCmds[key]) return;
  pendingCmds[key] = true;
  try {
    const r = await api(path, { method: 'POST' });
    if (!r.ok && r.status !== 401 && r.status !== 423) showToast(errText(r), true);
  } catch (e) {
    showToast('Pano ile bağlantı kurulamadı.', true);
  } finally {
    delete pendingCmds[key];
    schedulePoll(250);
  }
}

// İdempotent: "toggle" yerine istenen hedef durum (state=0/1) gönderilir.
function toggleRelay(ch1) {
  const r = lastStatus && lastStatus.relays ? lastStatus.relays[ch1 - 1] : null;
  const desired = (r && r.state) ? 0 : 1;
  sendCmd('r' + ch1, '/api/relay?ch=' + ch1 + '&state=' + desired);
}
function triggerImpulse(ch1) { sendCmd('r' + ch1, '/api/relay?ch=' + ch1 + '&state=1'); }
function cmdShutter(pair1, action) { sendCmd('s' + pair1, '/api/relay?pair=' + pair1 + '&cmd=' + action); }
async function cmdAll(cmd) {
  await sendCmd('all', '/api/all?cmd=' + cmd);
  showToast('Komut iletildi');
}

// ============================================================================
// Yapılandırma
// ============================================================================
let currentConfig = null;

let configLoading = false;
async function loadConfig(retries) {
  if (configLoading) return false;
  configLoading = true;
  try {
    return await loadConfigOnce(retries);
  } finally {
    configLoading = false;
  }
}
async function loadConfigOnce(retries) {
  const banner = $('cfgLoadError');
  const n = retries || 1;
  for (let i = 0; i < n; i++) {
    try {
      const r = await api('/api/config');
      if (r.ok && r.data && Array.isArray(r.data.relays)) {
        currentConfig = r.data;
        $('sysDevName').value = currentConfig.device_name || '';
        if (currentConfig.rs485_baud) $('rs485Baud').value = String(currentConfig.rs485_baud);
        if (!$('wifiSsid').value) $('wifiSsid').value = currentConfig.wifi_ssid || '';
        ensureConfigArrays();
        updateExtModuleUI();
        renderConfigTables();
        banner.style.display = 'none';
        return true;
      }
      if (r.status === 401 || r.status === 423 || r.status === 403) break;   // kimlik gerekli: yeniden denemenin anlamı yok
    } catch (e) { /* ağ hatası: yeniden dene */ }
    if (i + 1 < n) await sleep(1000 * (i + 1));
  }
  banner.style.display = 'flex';
  return false;
}

function ensureConfigArrays() {
  if (!currentConfig) return;
  if (!Array.isArray(currentConfig.relays)) currentConfig.relays = [];
  if (!Array.isArray(currentConfig.dis)) currentConfig.dis = [];
  const total = totalRelayCount();
  for (let i = 0; i < total; i++) {
    if (!currentConfig.relays[i]) {
      currentConfig.relays[i] = {
        id: i + 1,
        name: (i % 2 === 0) ? ('Panjur ' + (Math.floor(i / 2) + 1) + ' (Yukari)') : ('Panjur ' + (Math.floor(i / 2) + 1) + ' (Asagi)'),
        type: (i % 2 === 0) ? 1 : 2,
        runtime_sec: 20
      };
    }
    if (!currentConfig.dis[i]) {
      currentConfig.dis[i] = {
        id: i + 1,
        name: (i % 2 === 0) ? ('Panjur ' + (Math.floor(i / 2) + 1) + ' Butonu') : ('Giriş ' + (i + 1) + ' (Boşta / Serbest)'),
        target_relay: (i % 2 === 0) ? (i + 1) : 0,
        mode: (i % 2 === 0) ? 2 : 0
      };
    }
  }
}

function updateExtModuleUI() {
  if (!currentConfig) return;
  const isEn = !!currentConfig.ext_module_enabled;
  const ch = toInt(currentConfig.ext_module_channels, 8) || 8;
  const sw = $('swExtModule');
  const opt = $('extModuleOptions');
  if (sw) { sw.classList.toggle('on', isEn); sw.setAttribute('aria-checked', isEn ? 'true' : 'false'); }
  if (opt) opt.style.display = isEn ? 'block' : 'none';
  if ($('selExtChannels')) $('selExtChannels').value = String(ch);
  if ($('inpExtAddr')) $('inpExtAddr').value = currentConfig.ext_module_address || 1;

  const totalR = isEn ? (8 + ch) : 8;
  const totalP = totalR / 2;
  if ($('lblTotalCapacity')) $('lblTotalCapacity').textContent = totalR + ' Röle / ' + totalR + ' Giriş (' + totalP + ' Çift)';
  if ($('cfgRelayTitle')) $('cfgRelayTitle').textContent = '⚙️ Röle Çıkış Yapılandırması (' + totalR + ' Kanal - ' + totalP + ' Çift)';
  if ($('cfgDITitle')) $('cfgDITitle').textContent = '🔘 Giriş Yapılandırması (' + totalR + ' DI Duvar Butonları & Sensörler)';
}

function toggleExtModule() {
  if (!currentConfig) { showToast('Yapılandırma henüz yüklenmedi.', true); return; }
  currentConfig.ext_module_enabled = !currentConfig.ext_module_enabled;
  // Etkinleştirilince kanal sayısı doldurulur (varsayılan 8); cihaz da aynı normalizasyonu yapar
  if (currentConfig.ext_module_enabled && !toInt(currentConfig.ext_module_channels)) currentConfig.ext_module_channels = 8;
  ensureConfigArrays();
  updateExtModuleUI();
  renderConfigTables();
}
function onExtChannelsChange(val) {
  if (!currentConfig) return;
  const n = toInt(val, 8);
  currentConfig.ext_module_channels = [2, 4, 8, 12, 16, 24, 32].indexOf(n) >= 0 ? n : 8;
  ensureConfigArrays();
  updateExtModuleUI();
  renderConfigTables();
}
function onExtAddressChange(val) {
  if (!currentConfig) return;
  const a = toInt(val, 1);
  currentConfig.ext_module_address = (a >= 1 && a <= 247) ? a : 1;
  $('inpExtAddr').value = currentConfig.ext_module_address;
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
  return String(currentConfig.relays[r1].name || '').replace(/ \(Yukari\)| \(Asagi\)| Aydinlatma/gi, '').trim() || ('Panjur ' + (p + 1));
}

function setPairMode(p, toShutter) {
  if (!currentConfig) return;
  const r1 = p * 2, r2 = p * 2 + 1;
  const di1 = p * 2, di2 = p * 2 + 1;

  if (toShutter) {
    const baseName = clampBytes(getPairBaseName(p), 22);
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
  const baseName = clampBytes(getPairBaseName(p), 22);

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
    currentConfig.dis[di1].name = clampBytes(baseName, 20) + ' (Yukarı)';

    currentConfig.dis[di2].mode = 4; // DI_MODE_SHUTTER_DOWN
    currentConfig.dis[di2].target_relay = di1 + 2;
    currentConfig.dis[di2].name = clampBytes(baseName, 20) + ' (Aşağı)';
  }
  renderConfigTables();
  // Tesisat tipi değişikliğini anında kaydet (kaydet butonuna gerek yok)
  postConfig();
}

function onPairNameInput(p, val) {
  if (!currentConfig) return;
  const r1 = p * 2, r2 = p * 2 + 1;
  const name = clampBytes(String(val).trim(), 22);   // " (Yukari)" eki dahil en fazla 31 bayt
  currentConfig.relays[r1].name = name + ' (Yukari)';
  currentConfig.relays[r2].name = name + ' (Asagi)';
}
function onPairRuntimeInput(p, val) {
  if (!currentConfig) return;
  let num = toInt(val, 20);
  if (num < 1) num = 1;
  if (num > 300) num = 300;
  const r1 = p * 2, r2 = p * 2 + 1;
  currentConfig.relays[r1].runtime_sec = num;
  currentConfig.relays[r2].runtime_sec = num;
}
function onSingleNameInput(rIdx, val) {
  if (!currentConfig) return;
  currentConfig.relays[rIdx].name = clampBytes(String(val).trim(), 31);
}
function onSingleTypeChange(rIdx, val) {
  if (!currentConfig) return;
  const t = toInt(val);
  currentConfig.relays[rIdx].type = (t === 3) ? 3 : 0;   // münferit kanal: lamba veya darbe
  if (t === 0) currentConfig.relays[rIdx].runtime_sec = 0;
  else if (t === 3 && !currentConfig.relays[rIdx].runtime_sec) currentConfig.relays[rIdx].runtime_sec = 500;
  renderConfigTables();
}
function onSingleRuntimeInput(rIdx, val) {
  if (!currentConfig) return;
  let ms = toInt(val, 500);
  if (ms < 1) ms = 1;
  if (ms > 60000) ms = 60000;
  currentConfig.relays[rIdx].runtime_sec = ms;
}
function onDINameInput(diIdx, val) {
  if (!currentConfig) return;
  currentConfig.dis[diIdx].name = clampBytes(String(val), 31);
}
function onFreeDITargetChange(diIdx, val) {
  if (!currentConfig) return;
  const targetId = toInt(val);
  currentConfig.dis[diIdx].target_relay = targetId;
  currentConfig.dis[diIdx].mode = 0;
  if (targetId > 0 && currentConfig.relays[targetId - 1]) {
    currentConfig.dis[diIdx].name = clampBytes(String(currentConfig.relays[targetId - 1].name || ''), 22) + ' Butonu';
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

  const pairBadge = isExt
    ? '<span class="pill pill-lg k-violet">📦 Ek Modül - Çift ' + (p + 1) + ' (Röle ' + (r1 + 1) + ' & Röle ' + (r2 + 1) + ') [CH ' + (r1 - 7) + ' & ' + (r2 - 7) + ']</span>'
    : '<span class="pill pill-lg' + (isShut ? ' k-sky' : '') + '">⚡ Ana Pano - Çift ' + (p + 1) + ' (Röle ' + (r1 + 1) + ' & Röle ' + (r2 + 1) + ')</span>';

  let html =
    '<div class="card' + (isShut ? ' is-shutter' : '') + '">' +
      '<div class="cfg-head">' +
        '<div class="row">' + pairBadge +
          '<span class="lbl-sm">Çalışma Amacı:</span>' +
        '</div>' +
        '<div class="seg">' +
          '<button type="button" class="btn btn-sm ' + (isShut ? 'btn-primary' : 'btn-outline') + '" onclick="setPairMode(' + p + ', true)">🪟 Panjur Motoru (Birleşik)</button>' +
          '<button type="button" class="btn btn-sm ' + (!isShut ? 'btn-primary' : 'btn-outline') + '" onclick="setPairMode(' + p + ', false)">💡 Münferit / Ayrı Röleler</button>' +
        '</div>' +
      '</div>';

  if (isShut) {
    html +=
      '<div class="pair-grid">' +
        '<div>' +
          '<label class="lbl" for="cfgPairName_' + p + '">🪟 Panjur Grubu Adı:</label>' +
          '<input type="text" id="cfgPairName_' + p + '" class="inp-strong" value="' + esc(baseName) + '" placeholder="Örn: Panjur ' + (p + 1) + '" oninput="onPairNameInput(' + p + ', this.value)">' +
          '<div class="hint-row t-sky">' +
            '<span>▲ <b>Röle ' + (r1 + 1) + ':</b> Yukarı (Açma)</span>' +
            '<span>▼ <b>Röle ' + (r2 + 1) + ':</b> Aşağı (Kapatma)</span>' +
            '<span class="pill k-amber">🔒 Yazılımsal kilit (500 ms ölü zaman) — harici kontaktör/mekanik interlock önerilir</span>' +
          '</div>' +
        '</div>' +
        '<div>' +
          '<label class="lbl" for="cfgPairRuntime_' + p + '">Hareket Süresi (Motor Kapanma):</label>' +
          '<div class="row">' +
            '<input type="number" id="cfgPairRuntime_' + p + '" class="inp-num" value="' + toInt(runtime, 20) + '" min="1" max="300" oninput="onPairRuntimeInput(' + p + ', this.value)">' +
            '<span class="note">saniye (1-300)</span>' +
          '</div>' +
          '<div class="note" style="margin-top: 4px;">Süre dolunca motor otomatik durur.</div>' +
        '</div>' +
      '</div>';
  } else {
    html += '<div class="grid-2col">' + renderSingleRelayBox(r1, isExt) + renderSingleRelayBox(r2, isExt) + '</div>';
  }
  return html + '</div>';
}

function renderSingleRelayBox(r, isExt) {
  const cfg = currentConfig.relays[r];
  const t = toInt(cfg.type);
  return (
    '<div class="tile">' +
      '<div class="tile-head">' +
        '<span class="tile-title">💡 Röle ' + (r + 1) + ' (' + (isExt ? 'Ek Modül CH ' + (r - 7) : 'Pano Çıkışı') + ')</span>' +
        '<span class="note">Tekli Yük</span>' +
      '</div>' +
      '<input type="text" id="cfgRName_' + r + '" value="' + esc(cfg.name) + '" oninput="onSingleNameInput(' + r + ', this.value)" placeholder="Kanal Adı (Örn: Lamba ' + (r + 1) + ')">' +
      '<div class="row2">' +
        '<select id="cfgRType_' + r + '" onchange="onSingleTypeChange(' + r + ', this.value)">' +
          '<option value="0"' + (t === 0 ? ' selected' : '') + '>💡 Normal Aydınlatma</option>' +
          '<option value="3"' + (t === 3 ? ' selected' : '') + '>⚡ Darbe / Tetik (Kilit)</option>' +
        '</select>' +
        (t === 3
          ? '<div class="rt-box">' +
              '<input type="number" id="cfgRRuntime_' + r + '" class="inp-num" value="' + toInt(cfg.runtime_sec, 500) + '" min="1" max="60000" oninput="onSingleRuntimeInput(' + r + ', this.value)" placeholder="Süre">' +
              '<span class="note">ms</span>' +
            '</div>'
          : '<input type="hidden" id="cfgRRuntime_' + r + '" value="0">') +
      '</div>' +
    '</div>'
  );
}

function renderDIPairCard(p, totalRelays) {
  const di1 = p * 2, di2 = p * 2 + 1;
  const isShut = isPairShutter(p);
  const baseName = getPairBaseName(p);
  const isExt = (p >= 4);

  if (isShut) {
    const isSingle = (currentConfig.dis[di1].mode === 2); // DI_MODE_SHUTTER_STEP=2: tek buton (2 kablo)

    let freeRelayOptions = '';
    for (let r = 1; r <= totalRelays; r++) {
      if (r !== (p * 2 + 1) && r !== (p * 2 + 2)) {
        const rName = currentConfig.relays[r - 1].name;
        const sel = (currentConfig.dis[di2].target_relay === r) ? ' selected' : '';
        freeRelayOptions += '<option value="' + r + '"' + sel + '>Röle ' + r + ' (' + esc(rName) + ')</option>';
      }
    }

    const diBadge = isExt
      ? '<span class="pill pill-lg k-violet">📦 Ek Modül - DI ' + (di1 + 1) + ' & DI ' + (di2 + 1) + ' [CH ' + (di1 - 7) + ' & ' + (di2 - 7) + ']</span>'
      : '<span class="pill pill-lg k-sky">🔘 Ana Pano - DI ' + (di1 + 1) + ' & DI ' + (di2 + 1) + '</span>';

    let html =
      '<div class="card is-shutter">' +
        '<div class="cfg-head">' +
          '<div class="row">' + diBadge +
            '<span class="hl t-amber">🪟 Hedef Panjur: ' + esc(baseName) + '</span>' +
          '</div>' +
          '<div class="lbl-sm">Duvardaki Tesisat Tipi:</div>' +
        '</div>' +
        '<div class="grid-2col">' +
          '<div class="mode-card' + (isSingle ? ' selected' : '') + '" onclick="setDIPairShutterWiring(' + p + ', \'single\')">' +
            '<div class="mc-head">' +
              '<input type="radio" name="diWiring_' + p + '" value="single" ' + (isSingle ? 'checked' : '') + '>' +
              '<span class="hl t-emerald">🪟 1. Tesisat: Tek Butonla Kontrol (2 Kablo)</span>' +
            '</div>' +
            '<div class="note">DI ' + (di1 + 1) + ' tek yaylı butonla tüm panjuru yönetir. <b>DI ' + (di2 + 1) + ' girişi boşa çıkar (serbest kalır).</b></div>' +
          '</div>' +
          '<div class="mode-card' + (!isSingle ? ' selected' : '') + '" onclick="setDIPairShutterWiring(' + p + ', \'dual\')">' +
            '<div class="mc-head">' +
              '<input type="radio" name="diWiring_' + p + '" value="dual" ' + (!isSingle ? 'checked' : '') + '>' +
              '<span class="hl t-sky">⬆️⬇️ 2. Tesisat: Çift Tuşlu Anahtar (3 Kablo)</span>' +
            '</div>' +
            '<div class="note">DI ' + (di1 + 1) + ' Yukarı Aç, DI ' + (di2 + 1) + ' Aşağı Kapat tuşu olarak iki ayrı klemens kullanılır.</div>' +
          '</div>' +
        '</div>';

    if (isSingle) {
      const freeTarget = currentConfig.dis[di2].target_relay;
      html +=
        '<div class="grid-2col">' +
          '<div class="tile k-emerald">' +
            '<div class="tile-head">' +
              '<span class="tile-title">🔘 DI ' + (di1 + 1) + ' Panjur Butonu</span>' +
              '<span class="pill k-emerald">Panjura Atandı</span>' +
            '</div>' +
            '<input type="text" id="cfgDIName_' + di1 + '" value="' + esc(currentConfig.dis[di1].name) + '" oninput="onDINameInput(' + di1 + ', this.value)">' +
            '<div class="note">Çalışma: <b>Aç ➔ Dur ➔ Kapat ➔ Dur</b> döngüsü.</div>' +
            '<div class="note t-emerald">🔌 <b>Bağlantı:</b> DGND ile DI ' + (di1 + 1) + ' arasına 2 kablo ile yaylı anahtar bağlanır.</div>' +
          '</div>' +
          '<div class="tile k-sky dash">' +
            '<div class="tile-head">' +
              '<span class="tile-title">🟢 DI ' + (di2 + 1) + ' Girişi: SERBEST / BOŞTA</span>' +
              '<span class="pill k-sky">İsteğe Bağlı</span>' +
            '</div>' +
            '<div class="note">Panjur tek butonla yönetildiği için DI ' + (di2 + 1) + ' klemensi <b>boştadır</b>. Dilerseniz başka bir aydınlatmaya atayabilirsiniz.</div>' +
            '<div class="row2">' +
              '<span class="note">Tetikleyeceği Röle:</span>' +
              '<select id="cfgDITarget_' + di2 + '" onchange="onFreeDITargetChange(' + di2 + ', this.value)">' +
                '<option value="0"' + (freeTarget === 0 ? ' selected' : '') + '>-- Boşta (Röle Tetiklemez) --</option>' + freeRelayOptions +
              '</select>' +
            '</div>' +
            (freeTarget > 0
              ? '<div>' +
                  '<input type="text" id="cfgDIName_' + di2 + '" value="' + esc(currentConfig.dis[di2].name) + '" oninput="onDINameInput(' + di2 + ', this.value)" placeholder="Buton Adı">' +
                  '<div class="note t-emerald" style="margin-top: 4px;">🔌 DGND ile DI ' + (di2 + 1) + ' arasına yaylı buton bağlanır.</div>' +
                '</div>'
              : '') +
          '</div>' +
        '</div>';
    } else {
      html +=
        '<div class="grid-2col">' +
          '<div class="tile k-sky">' +
            '<div class="tile-head">' +
              '<span class="tile-title">⬆️ DI ' + (di1 + 1) + ': YUKARI Açma Tuşu</span>' +
              '<span class="pill k-sky">Panjur Aç</span>' +
            '</div>' +
            '<input type="text" id="cfgDIName_' + di1 + '" value="' + esc(currentConfig.dis[di1].name) + '" oninput="onDINameInput(' + di1 + ', this.value)">' +
            '<div class="note">Basınca yukarı açar, giderken basılırsa durdurur.</div>' +
          '</div>' +
          '<div class="tile k-amber">' +
            '<div class="tile-head">' +
              '<span class="tile-title">⬇️ DI ' + (di2 + 1) + ': AŞAĞI Kapatma Tuşu</span>' +
              '<span class="pill k-amber">Panjur Kapat</span>' +
            '</div>' +
            '<input type="text" id="cfgDIName_' + di2 + '" value="' + esc(currentConfig.dis[di2].name) + '" oninput="onDINameInput(' + di2 + ', this.value)">' +
            '<div class="note">Basınca aşağı kapatır, inerken basılırsa durdurur.</div>' +
          '</div>' +
        '</div>' +
        '<div class="callout k-emerald">' +
          '🔌 <b>3 Kablolu Tesisat Bağlantısı:</b> Ortak uç <b>DGND</b>\'ye, Yukarı tuşu <b>DI ' + (di1 + 1) + '</b>\'e, Aşağı tuşu <b>DI ' + (di2 + 1) + '</b>\'e bağlanır.' +
        '</div>';
    }
    return html + '</div>';
  }

  // Münferit giriş çifti
  return (
    '<div class="card">' +
      '<div class="cfg-head">' +
        '<span class="hl-muted">🔘 Bağımsız Girişler: DI ' + (di1 + 1) + ' ve DI ' + (di2 + 1) + ' (' + (isExt ? 'Ek Modül' : 'Ana Pano') + ')</span>' +
      '</div>' +
      '<div class="grid-2col">' + renderSingleDICard(di1, totalRelays) + renderSingleDICard(di2, totalRelays) + '</div>' +
    '</div>'
  );
}

function sectionBox(variant, icon, title, subtitle, badge, inner) {
  return (
    '<div class="secbox k-' + variant + '">' +
      '<div class="sec-head">' +
        '<div class="sec-id">' +
          '<span class="sec-ico">' + icon + '</span>' +
          '<div><div class="sec-title">' + title + '</div>' +
          '<div class="sec-sub">' + subtitle + '</div></div>' +
        '</div>' +
        '<span class="pill pill-lg k-' + variant + '">' + badge + '</span>' +
      '</div>' +
      '<div class="sec-body">' + inner + '</div>' +
    '</div>'
  );
}

function renderConfigTables() {
  if (!currentConfig) return;

  const isExt = !!currentConfig.ext_module_enabled;
  const extCh = toInt(currentConfig.ext_module_channels, 8) || 8;
  const totalRelays = totalRelayCount();
  const totalPairs = totalRelays / 2;

  // 1. Röle çıkışları
  const rContainer = $('cfgRelayPairsContainer');
  if (rContainer) {
    let main = '';
    for (let p = 0; p < 4; p++) main += renderRelayPairCard(p);
    let full = sectionBox('sky', '🏠', 'Ana Cihaz Röle Çıkışları', 'Yerel 8RO Pano Klemensleri (Röle 1 - 8)', '8 Kanal / 4 Çift', main);
    if (isExt && totalPairs > 4) {
      let ext = '';
      for (let p = 4; p < totalPairs; p++) ext += renderRelayPairCard(p);
      full += sectionBox('violet', '📦', 'Harici RS485 Ek Modül Röleleri',
        'RS485 Genişletme Kartı Çıkışları (Röle 9 - ' + totalRelays + ') • Slave ID: ' + toInt(currentConfig.ext_module_address, 1),
        'Ek ' + extCh + ' Kanal / ' + (extCh / 2) + ' Çift', ext);
    }
    rContainer.innerHTML = full;
  }

  // 2. Girişler
  const diContainer = $('cfgDIPairsContainer');
  if (diContainer) {
    let main = '';
    for (let p = 0; p < 4; p++) main += renderDIPairCard(p, totalRelays);
    let full = sectionBox('sky', '🏠', 'Ana Cihaz Girişleri (Duvar Butonları)', 'Yerel 8DI Duvar Butonu ve Sensör Klemensleri (DI 1 - 8)', '8 Giriş / 4 Çift', main);
    if (isExt && totalPairs > 4) {
      let ext = '';
      for (let p = 4; p < totalPairs; p++) ext += renderDIPairCard(p, totalRelays);
      full += sectionBox('violet', '📦', 'Harici RS485 Ek Modül Girişleri',
        'RS485 Genişletme Kartı Girişleri (DI 9 - DI ' + totalRelays + ')',
        'Ek ' + extCh + ' Giriş / ' + (extCh / 2) + ' Çift', ext);
    }
    diContainer.innerHTML = full;
  }
}

function renderSingleDICard(diIdx, totalRelays) {
  const d = currentConfig.dis[diIdx];
  if (!totalRelays) totalRelays = totalRelayCount();
  let targetOpts = '<option value="0"' + (d.target_relay === 0 ? ' selected' : '') + '>-- Devre Dışı (Röle Tetiklemez) --</option>';
  for (let r = 1; r <= totalRelays; r++) {
    targetOpts += '<option value="' + r + '"' + (d.target_relay === r ? ' selected' : '') + '>Röle ' + r + ' (' + esc(currentConfig.relays[r - 1].name) + ')</option>';
  }

  const targetType = (d.target_relay > 0 && currentConfig.relays[d.target_relay - 1]) ? currentConfig.relays[d.target_relay - 1].type : -1;
  let typeInfo;
  if (d.target_relay === 0) {
    typeInfo = '<div class="note">⚪ Boşta (Herhangi bir röleye bağlı değil)</div>';
  } else if (targetType === 0) {
    typeInfo = '<div class="note t-sky">💡 <b>Standart Lamba Butonu</b> (Bas-aç / bas-kapat). 🔌 DGND ile DI arasına bağlanır.</div>';
  } else if (targetType === 3) {
    typeInfo = '<div class="note t-amber">⚡ <b>Darbe / Tetik Butonu</b> (Kapı kilidi). 🔌 DGND ile DI arasına bağlanır.</div>';
  } else {
    typeInfo = '<div class="note t-emerald">🪟 Panjur Kontrolü (Tek Buton Döngü: Aç-Dur-Kapat-Dur).</div>';
  }

  return (
    '<div class="tile">' +
      '<div class="tile-head">' +
        '<span class="tile-title">🔘 DI ' + (diIdx + 1) + ' Girişi</span>' +
        '<span class="note">Tekli Buton</span>' +
      '</div>' +
      '<input type="text" id="cfgDIName_' + diIdx + '" value="' + esc(d.name) + '" oninput="onDINameInput(' + diIdx + ', this.value)" placeholder="Giriş Adı">' +
      '<div class="row2">' +
        '<span class="note">Tetikle:</span>' +
        '<select id="cfgDITarget_' + diIdx + '" onchange="onSingleDITargetChange(' + diIdx + ', this.value)">' + targetOpts + '</select>' +
      '</div>' + typeInfo +
    '</div>'
  );
}

function onSingleDITargetChange(diIdx, val) {
  if (!currentConfig) return;
  const tId = toInt(val);
  currentConfig.dis[diIdx].target_relay = tId;
  if (tId === 0 || !currentConfig.relays[tId - 1]) {
    currentConfig.dis[diIdx].mode = 0;
  } else {
    const tType = currentConfig.relays[tId - 1].type;
    if (tType === 1 || tType === 2) currentConfig.dis[diIdx].mode = 2;
    else if (tType === 3) currentConfig.dis[diIdx].mode = 1;
    else currentConfig.dis[diIdx].mode = 0;
  }
  renderConfigTables();
}

// Cihaza yalnızca etkin kanallar gönderilir; diğer kayıtlar cihazda olduğu gibi kalır.
function buildConfigPayload() {
  const total = totalRelayCount();
  const relays = [];
  const dis = [];
  for (let i = 0; i < total; i++) {
    const r = currentConfig.relays[i];
    const d = currentConfig.dis[i];
    relays.push({ name: String(r.name || ''), type: toInt(r.type), runtime_sec: toInt(r.runtime_sec) });
    dis.push({ name: String(d.name || ''), target_relay: toInt(d.target_relay), mode: toInt(d.mode) });
  }
  return {
    device_name: String(currentConfig.device_name || ''),
    ext_module_enabled: !!currentConfig.ext_module_enabled,
    ext_module_channels: toInt(currentConfig.ext_module_channels, 0),
    ext_module_address: toInt(currentConfig.ext_module_address, 1),
    relays: relays,
    dis: dis
  };
}

async function saveRelayConfig() {
  if (!currentConfig) { showToast('Yapılandırma henüz yüklenmedi.', true); return; }
  const totalPairs = totalRelayCount() / 2;
  for (let p = 0; p < totalPairs; p++) {
    const r1 = p * 2, r2 = p * 2 + 1;
    if (isPairShutter(p)) {
      const elName = $('cfgPairName_' + p);
      if (elName) {
        const val = clampBytes(elName.value.trim(), 22) || ('Panjur ' + (p + 1));
        currentConfig.relays[r1].name = val + ' (Yukari)';
        currentConfig.relays[r2].name = val + ' (Asagi)';
      }
      currentConfig.relays[r1].type = 1;   // çift her zaman Yukarı + Aşağı olarak kaydedilir
      currentConfig.relays[r2].type = 2;
      const elRt = $('cfgPairRuntime_' + p);
      let rt = elRt ? toInt(elRt.value, 20) : toInt(currentConfig.relays[r1].runtime_sec, 20);
      if (rt < 1 || rt > 300) { showToast('Panjur ' + (p + 1) + ' süresi 1-300 sn olmalı.', true); return; }
      currentConfig.relays[r1].runtime_sec = rt;
      currentConfig.relays[r2].runtime_sec = rt;
    } else {
      const idxs = [r1, r2];
      for (let k = 0; k < idxs.length; k++) {
        const r = idxs[k];
        const elN = $('cfgRName_' + r);
        if (elN) currentConfig.relays[r].name = clampBytes(elN.value.trim(), 31);
        const elT = $('cfgRType_' + r);
        if (elT) currentConfig.relays[r].type = (toInt(elT.value) === 3) ? 3 : 0;
        const elRt = $('cfgRRuntime_' + r);
        let ms = elRt ? toInt(elRt.value, 0) : 0;
        if (currentConfig.relays[r].type === 3) {
          if (ms < 1 || ms > 60000) { showToast('Röle ' + (r + 1) + ' darbe süresi 1-60000 ms olmalı.', true); return; }
        } else {
          ms = 0;
        }
        currentConfig.relays[r].runtime_sec = ms;
      }
    }
  }
  await postConfig();
}

async function saveDIConfig() {
  if (!currentConfig) { showToast('Yapılandırma henüz yüklenmedi.', true); return; }
  const totalDIs = totalRelayCount();
  for (let i = 0; i < totalDIs; i++) {
    const elName = $('cfgDIName_' + i);
    if (elName) currentConfig.dis[i].name = clampBytes(elName.value.trim(), 31);
  }
  await postConfig();
}

async function postConfig() {
  if (!currentConfig) return false;
  try {
    const r = await api('/api/config', { method: 'POST', json: buildConfigPayload() });
    if (r.ok) {
      showToast('Ayarlar cihaz hafızasına kaydedildi!');
      schedulePoll(0);
      return true;
    }
    showToast('HATA: ' + errText(r), true);
  } catch (e) {
    showToast('Bağlantı hatası: ' + e.message, true);
  }
  return false;
}

// ============================================================================
// Wi-Fi (Station): ağ listesi (RSSI çubuğu + kilit), karekod, bağlan ve sonucu /api/wifi/status ile bekle
// Anahtarsız AP kaynaklı modda (apMode) istekler X-Device-Key göndermez; cihaz ağ konumuna göre yetkilendirir.
// ============================================================================
// Sinyal düzeyi 0..4 (çubuk sayısı)
function rssiLevel(rssi) {
  const r = toInt(rssi, -100);
  if (r >= -55) return 4;
  if (r >= -65) return 3;
  if (r >= -75) return 2;
  if (r >= -85) return 1;
  return 0;
}

// Ağ listesi: SSID'ler komşu ağlardan gelir; YALNIZ DOM API (textContent) ile basılır, HTML olarak yorumlanmaz.
function renderNetworkList(networks) {
  const box = $('wifiNetList');
  box.innerHTML = '';
  const cur = $('wifiSsid').value;
  networks.forEach(function (n) {
    const ssid = String(n.ssid);
    const rssi = toInt(n.rssi, -100);
    const enc = !!n.enc;
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'net-row' + (ssid === cur ? ' sel' : '');
    row.setAttribute('role', 'option');
    row.setAttribute('aria-label', ssid + ', sinyal ' + rssi + ' dBm, ' + (enc ? 'şifreli ağ' : 'açık ağ'));

    const lock = document.createElement('span');
    lock.className = 'net-lock';
    lock.textContent = enc ? '🔒' : '🔓';
    const name = document.createElement('span');
    name.className = 'net-ssid';
    name.textContent = ssid;
    const bars = document.createElement('span');
    bars.className = 'bars';
    bars.setAttribute('aria-hidden', 'true');
    const level = rssiLevel(rssi);
    for (let i = 1; i <= 4; i++) {
      const bar = document.createElement('i');
      bar.className = (i <= level) ? 'on' : '';
      bar.style.height = (3 + i * 3) + 'px';
      bars.appendChild(bar);
    }
    const val = document.createElement('span');
    val.className = 'net-rssi';
    val.textContent = rssi + ' dBm';

    row.appendChild(lock);
    row.appendChild(name);
    row.appendChild(bars);
    row.appendChild(val);
    row.onclick = function () { pickNetwork(ssid, enc, row); };
    box.appendChild(row);
  });
}

// Listeden ağ seçimi: SSID alanı doldurulur ve ŞİFRE KUTUSUNA ODAKLANILIR (açık ağda şifre alanı boşaltılır)
function pickNetwork(ssid, enc, row) {
  $('wifiSsid').value = ssid;
  const kids = $('wifiNetList').children || [];
  for (let i = 0; i < kids.length; i++) kids[i].className = String(kids[i].className).replace(/\s*\bsel\b/g, '');
  if (row) row.className = String(row.className) + ' sel';
  const pass = $('wifiPass');
  if (!enc) { pass.value = ''; pass.placeholder = 'Açık ağ: şifre gerekmez'; }
  else pass.placeholder = 'Wi-Fi Şifreniz';
  pass.focus();
}

function toggleWifiPass() {
  $('wifiPass').type = $('wifiPassShow').checked ? 'text' : 'password';
}

let scanInflight = false;
async function scanWifi(forceRefresh) {
  if (scanInflight) return;
  scanInflight = true;
  const statusEl = $('scanStatus');
  const box = $('wifiNetList');
  statusEl.textContent = 'Çevredeki ağlar taranıyor (2-4 sn sürebilir)...';
  if (forceRefresh) box.innerHTML = '';
  try {
    let r = null;
    let data = null;
    let attempts = 0;
    let fails = 0;
    for (;;) {
      try {
        r = await api('/api/wifi/scan' + ((forceRefresh && attempts === 0 && fails === 0) ? '?refresh=1' : ''), { nokey: apMode });
        data = r.data;
        fails = 0;
      } catch (e) {
        // tarama sırasında SoftAP kanalı kısa süre bozulabilir: geçici istek hatası yeniden denenir
        if (++fails > 2) throw e;
        await sleep(1200);
        continue;
      }
      if (r.ok && data && data.status === 'scanning' && attempts < 10) {
        attempts++;
        await sleep(1200);
        continue;
      }
      break;
    }
    if (r.ok && data && data.status === 'done' && Array.isArray(data.networks)) {
      if (data.networks.length > 0) {
        renderNetworkList(data.networks);
        statusEl.textContent = data.networks.length + ' adet 2.4 GHz ağ bulundu. Bağlanacağınız ağa dokunun:';
      } else {
        box.innerHTML = '';
        statusEl.textContent = 'Çevrede 2.4 GHz ağ bulunamadı. Yenileyin veya Wi-Fi adını aşağıya elle yazın.';
      }
    } else if (r.status === 401 || r.status === 423) {
      statusEl.textContent = 'Ağ listesi için cihaz anahtarı gerekli.';
    } else {
      statusEl.textContent = 'Ağ listelenemedi. Yenile butonuna basabilir veya Wi-Fi adını aşağıya yazabilirsiniz.';
    }
  } catch (e) {
    statusEl.textContent = 'Ağ listesi alınamadı. Wi-Fi adını aşağıdaki kutuya doğrudan yazabilirsiniz.';
  } finally {
    scanInflight = false;
  }
}

// ---- Modem Wi-Fi karekodu (kamera / fotoğraf): BarcodeDetector yoksa SESSİZ yedek (elle giriş) ----
function setQrHint(msg) {
  const el = $('qrHint');
  if (el) el.textContent = msg;
}
function qrCapable() {
  return typeof BarcodeDetector !== 'undefined' && typeof createImageBitmap === 'function' && !!$('wifiQrFileInput');
}
function triggerWifiQrScan() {
  const input = $('wifiQrFileInput');
  if (!input || !qrCapable()) {
    // Kamera/fotoğraf çözücü yok (ör. güvenli olmayan http bağlamı, iOS Safari): hata gösterilmez, elle giriş sürer
    setQrHint('Bu tarayıcı karekod çözmeyi desteklemiyor. Wi-Fi adını ve şifresini aşağıdaki kutulara elle girin.');
    return;
  }
  input.click();
}

async function handleWifiQrFile(event) {
  const target = event && event.target;
  const file = target && target.files && target.files[0];
  if (!file) return;
  setQrHint('Karekod taranıyor, lütfen bekleyin...');
  let ok = false;
  try {
    const bmp = await createImageBitmap(file);
    const detector = new BarcodeDetector({ formats: ['qr_code'] });
    const codes = await detector.detect(bmp);
    if (codes && codes.length > 0) ok = parseAndApplyWifiQr(codes[0].rawValue);
  } catch (err) {
    ok = false;   // çözücü hatası: sessizce elle girişe dönülür
  }
  try { target.value = ''; } catch (e) { /* salt okunur olabilir */ }
  setQrHint(ok ? 'Karekod okundu; bilgileri kontrol edip bağlanın.' : 'Karekod okunamadı. Fotoğrafı daha yakından ve net çekin ya da bilgileri elle girin.');
}

// Wi-Fi karekodu: WIFI:T:WPA;S:<ssid>;P:<parola>;H:true;;
// Değerlerdeki \\ \; \, \: \" kaçışları çözülür; S:"..." biçimi (tırnaklı) düz metin sayılır.
function parseWifiQr(raw) {
  if (typeof raw !== 'string') return null;
  const text = raw.trim();
  if (!/^WIFI:/i.test(text)) return null;
  const body = text.substring(5);
  const fields = {};
  let i = 0;
  while (i < body.length) {
    if (body[i] === ';') {   // ";;" veya alan sonu
      i++;
      if (body[i] === ';' || i >= body.length) break;
      continue;
    }
    let key = '';
    while (i < body.length && body[i] !== ':' && body[i] !== ';') { key += body[i]; i++; }
    if (body[i] !== ':') { continue; }
    i++;   // ':'
    let val = '';
    while (i < body.length) {
      const c = body[i];
      if (c === '\\' && i + 1 < body.length) { val += body[i + 1]; i += 2; continue; }   // kaçış: sonraki karakter düz
      if (c === ';') break;
      val += c;
      i++;
    }
    if (i < body.length && body[i] === ';') i++;
    fields[key.toUpperCase()] = val;
  }
  let ssid = fields.S;
  if (ssid === undefined || ssid === '') return null;
  if (ssid.length >= 2 && ssid[0] === '"' && ssid[ssid.length - 1] === '"') ssid = ssid.substring(1, ssid.length - 1);
  let pass = fields.P || '';
  if (pass.length >= 2 && pass[0] === '"' && pass[pass.length - 1] === '"') pass = pass.substring(1, pass.length - 1);
  const type = (fields.T || '').toUpperCase();
  return { ssid: ssid, pass: (type === 'NOPASS') ? '' : pass, type: type, hidden: /^true$/i.test(fields.H || '') };
}

// Wi-Fi dışı karekod yükleri (URL, e-posta, telefon, kartvizit...) ağ adı (SSID) sanılmaz
function looksLikeNonWifiPayload(t) {
  return /^[a-z][a-z0-9+.-]*:\/\//i.test(t) || /^(mailto:|tel:|sms:|smsto:|geo:|matmsg:|mecard:|bizcard:|begin:|urlto:|market:|intent:|www\.)/i.test(t) || /[\u0000-\u001f\u007f]/.test(t);
}

function parseAndApplyWifiQr(raw) {
  if (!raw) return false;
  const q = parseWifiQr(raw);
  if (q) {
    if (q.type === 'WEP' || q.type === 'EAP' || q.type === 'WPA2-EAP') {
      showToast('Bu güvenlik türü (' + q.type + ') desteklenmiyor.', true);
      return false;
    }
    if (utf8Len(q.ssid) > 32) { showToast('Karekoddaki Wi-Fi adı çok uzun (en fazla 32 bayt).', true); return false; }
    $('wifiSsid').value = q.ssid;
    $('wifiPass').value = q.pass;
    showToast('✅ Wi-Fi karekodu okundu: ' + q.ssid);
    return true;
  }
  const text = String(raw).trim();
  if (!/^WIFI:/i.test(text) && !looksLikeNonWifiPayload(text) && utf8Len(text) <= 32) {
    $('wifiSsid').value = text;
    showToast('Ağ adı (SSID) karekoddan alındı: ' + text);
    return true;
  }
  return false;
}

let wifiConnecting = false;

// Bağlantı durum göstergesi (kind: progress | ok | err | warn | ''): metin DOM API ile (textContent) basılır
function setConnState(kind, text, ip, tail) {
  const box = $('wifiConnState');
  if (!box) return;
  box.className = 'conn-state' + (kind ? ' ' + kind : '');
  box.textContent = text || '';
  if (kind && box.scrollIntoView) { try { box.scrollIntoView({ block: 'nearest' }); } catch (e) { /* eski tarayici */ } }
  if (ip && isIpv4(ip)) {
    const a = document.createElement('a');
    a.href = 'http://' + ip;
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
    a.textContent = 'http://' + ip;
    a.style.color = 'inherit';
    a.style.fontWeight = '700';
    box.appendChild(a);
  }
  if (tail) {
    const t = document.createElement('span');
    t.textContent = tail;
    box.appendChild(t);
  }
}

function wifiReasonText(reason) {
  const r = toInt(reason);
  if ([2, 15, 202, 204].indexOf(r) >= 0) return 'Wi-Fi şifresi hatalı.';
  if (r === 201) return 'Ağ bulunamadı (menzil dışı veya yalnızca 5 GHz).';
  if (r === 0) return 'Modem zamanında yanıt vermedi.';
  return 'Bağlanılamadı (neden kodu: ' + r + ').';
}

// POST /api/wifi/connect 200 "connecting" bağlandı demek DEĞİLDİR: sonuç /api/wifi/status ile beklenir.
// BAŞARI YALNIZ wifi_connect_state === 'success'. Cihaza ulaşılamazsa (pano modeme bağlanınca AP kanalı değişir/kapanır)
// sonuç BELİRSİZ ('lost') sayılır, başarısızlık sanılmaz.
const WIFI_RESULT_TIMEOUT_MS = 40000;
async function waitWifiResult() {
  const started = Date.now();
  let misses = 0;
  while (Date.now() - started < WIFI_RESULT_TIMEOUT_MS) {
    await sleep(1500);
    let r;
    try {
      r = await api('/api/wifi/status', { nokey: apMode, quiet: true });
    } catch (e) {
      if (++misses >= 3) return { state: 'lost' };
      continue;
    }
    if (r.status === 401 || r.status === 403 || r.status === 423) {
      onAuthResponse(r);
      return { state: 'denied', status: r.status };
    }
    if (!r.ok || !r.data) {
      if (++misses >= 3) return { state: 'lost' };
      continue;
    }
    misses = 0;
    const st = r.data;
    if (st.wifi_connect_state === 'success') return { state: 'success', ip: String(st.wifi_sta_ip || ''), ssid: String(st.wifi_sta_ssid || '') };
    if (st.wifi_connect_state === 'failed') return { state: 'failed', reason: toInt(st.wifi_connect_reason) };
    // connecting / idle: beklemeye devam
  }
  return { state: 'timeout' };
}

async function connectWifi() {
  if (wifiConnecting) return;
  const ssid = $('wifiSsid').value;
  const pass = $('wifiPass').value;
  if (!ssid) { setConnState('err', 'Lütfen Wi-Fi adı girin.'); return; }
  if (utf8Len(ssid) > 32) { setConnState('err', 'Wi-Fi adı en fazla 32 bayt olabilir.'); return; }
  if (pass.length !== 0 && (utf8Len(pass) < 8 || utf8Len(pass) > 63)) { setConnState('err', 'Wi-Fi şifresi 8-63 karakter olmalı (açık ağ için boş bırakın).'); return; }

  wifiConnecting = true;
  setConnState('progress', 'Wi-Fi bilgileri panoya gönderiliyor...');
  try {
    const res = await api('/api/wifi/connect', { method: 'POST', json: { ssid: ssid, pass: pass }, nokey: apMode });
    if (!res.ok) { setConnState('err', errText(res)); return; }

    setConnState('progress', 'Pano modeme bağlanıyor: ' + ssid + ' (en çok 40 sn sürebilir)...');
    const out = await waitWifiResult();
    if (out.state === 'success') {
      setConnState('ok', 'Bağlandı: ' + (out.ssid || ssid) + '. Panonun ev ağındaki adresi: ', out.ip,
        apMode ? ' Kurulum ağı (AP) birkaç saniye içinde kapanır; telefonunuzu ev Wi-Fi ağına geri alın.' : '');
    } else if (out.state === 'failed') {
      setConnState('err', 'Bağlanılamadı: ' + wifiReasonText(out.reason) + ' Önceki ağ ayarı korundu.');
    } else if (out.state === 'lost') {
      setConnState('warn', 'Pano ile bağlantı kesildi; sonuç doğrulanamadı. Pano modeme bağlandıysa kurulum ağı (AP) kapanmıştır: telefonunuzu ev Wi-Fi ağına alıp durumu kontrol edin.');
    } else if (out.state === 'denied') {
      setConnState('warn', 'Bu işlem için cihaz anahtarı gerekir.');
    } else {
      setConnState('warn', 'Bağlantı 40 sn içinde doğrulanamadı. Şifreyi ve modem mesafesini kontrol edip tekrar deneyin.');
    }
  } catch (e) {
    setConnState('err', 'Pano ile bağlantı kurulamadı.');
  } finally {
    wifiConnecting = false;
    schedulePoll(0);
  }
}

async function disconnectWifi() {
  if (!confirm('Cihazın modem bağlantısı kesilsin ve kayıtlı Wi-Fi bilgisi silinsin mi? (Yalnızca kurtarma ağı kalır)')) return;
  showToast('Modem bağlantısı kesiliyor...');
  try {
    const r = await api('/api/wifi/disconnect', { method: 'POST' });
    if (!r.ok) showToast(errText(r), true);
  } catch (e) {
    showToast('Pano ile bağlantı kurulamadı.', true);
  }
  setTimeout(function () { schedulePoll(0); }, 1500);
}

// ============================================================================
// RS485
// ============================================================================
let rs485Inflight = false;
async function refreshRs485Logs() {
  if (rs485Inflight || document.hidden) return;
  rs485Inflight = true;
  try {
    const r = await api('/api/rs485/logs', { text: true });
    if (r.ok) {
      const term = $('rs485Terminal');
      term.textContent = r.data || 'Henüz veri akışı yok.';
      term.scrollTop = term.scrollHeight;
    }
  } catch (e) { /* sessiz */ }
  rs485Inflight = false;
}
setInterval(function () { if (activeTab === 'rs485') refreshRs485Logs(); }, 2500);

async function sendRs485() {
  const fmt = $('rs485Format').value;
  const val = $('rs485Input').value;
  if (!val) return;
  try {
    const r = await api('/api/rs485/send', { method: 'POST', json: { data: val, isHex: (fmt === 'hex') } });
    if (!r.ok) { showToast(errText(r), true); return; }
    $('rs485Input').value = '';
  } catch (e) {
    showToast('İletişim hatası!', true);
  }
  refreshRs485Logs();
}

async function clearRs485Logs() {
  try { await api('/api/rs485/clear', { method: 'POST' }); } catch (e) { /* sessiz */ }
  refreshRs485Logs();
}

async function changeRs485Baud() {
  const baud = toInt($('rs485Baud').value, 9600);
  try {
    const r = await api('/api/rs485/baud', { method: 'POST', json: { baud: baud } });
    if (r.ok) showToast('RS485 baud rate ' + baud + ' olarak ayarlandı.');
    else showToast(errText(r), true);
  } catch (e) {
    showToast('İletişim hatası!', true);
  }
  refreshRs485Logs();
}

async function scanRs485Module() {
  showToast('Harici 8-kanal modül taranıyor (birkaç saniye sürebilir)...');
  try {
    let r = await api('/api/rs485/scan', { method: 'POST' });
    const started = Date.now();
    // Tarama arka planda yürür: 202 + yoklama
    while (r.ok && r.data && r.data.status === 'scanning' && Date.now() - started < 60000) {
      await sleep(1500);
      r = await api('/api/rs485/scan');
    }
    if (r.ok && r.data && r.data.status === 'done') {
      if (r.data.found) showToast('Modül Bulundu! Adres: ' + r.data.slaveId + ', Baud: ' + r.data.baud);
      else showToast('Modülden yanıt alınamadı. A/B kablolarını ve beslemeyi kontrol edin.', true);
    } else if (!r.ok) {
      showToast(errText(r), true);
    } else {
      showToast('Tarama tamamlanamadı.', true);
    }
  } catch (e) {
    showToast('Tarama hatası!', true);
  }
  refreshRs485Logs();
}

function extRelayBtn(channel, action) {
  controlExtRelay(currentConfig ? toInt(currentConfig.ext_module_address, 1) : 1, channel, action);
}

async function controlExtRelay(slaveId, channel, action) {
  try {
    const r = await api('/api/rs485/relay', { method: 'POST', json: { slaveId: slaveId, channel: channel, action: action } });
    if (r.ok && r.data && r.data.success) showToast('Modül Röle ' + (channel || 'Tümü') + ' komutu uygulandı.');
    else showToast(r.ok ? 'Modülden onay yanıtı alınamadı!' : errText(r), true);
  } catch (e) {
    showToast('İletişim hatası!', true);
  }
  refreshRs485Logs();
}

// ============================================================================
// Sistem
// ============================================================================
async function saveDevName() {
  if (!currentConfig) { showToast('Yapılandırma henüz yüklenmedi.', true); return; }
  const name = clampBytes($('sysDevName').value.trim(), 31);
  if (!name) { showToast('Cihaz adı boş olamaz.', true); return; }
  currentConfig.device_name = name;
  await postConfig();
}

async function rebootSystem() {
  if (!confirm('Cihaz yeniden başlatılsın mı? (Panjurlar durdurulur)')) return;
  try {
    const r = await api('/api/system/reboot', { method: 'POST' });
    showToast(r.ok ? 'Cihaz yeniden başlatılıyor...' : errText(r), !r.ok);
  } catch (e) {
    showToast('Pano ile bağlantı kurulamadı.', true);
  }
}

async function resetSystem() {
  const typed = prompt('Tüm kanal/giriş ayarları ve Wi-Fi bilgisi silinecek (cihaz anahtarı ve bulut kimliği korunur). Onaylamak için SIFIRLA yazın:');
  if (typed !== 'SIFIRLA') { if (typed !== null) showToast('Onay metni eşleşmedi; işlem iptal edildi.', true); return; }
  try {
    const r = await api('/api/system/reset', { method: 'POST' });
    if (r.ok) {
      showToast('Fabrika ayarlarına dönülüyor, cihaz yeniden başlayacak...');
      setTimeout(function () { location.reload(); }, 8000);
    } else {
      showToast(errText(r), true);
    }
  } catch (e) {
    showToast('Pano ile bağlantı kurulamadı.', true);
  }
}

async function rekeyDevice() {
  const k = $('newKeyInput').value;
  if (k.length < 8 || k.length > 32 || !/^[\x21-\x7E]+$/.test(k)) { showToast('Anahtar 8-32 karakter, boşluksuz olmalı.', true); return; }
  try {
    const r = await api('/api/auth/rekey', { method: 'POST', json: { local_key: k } });
    if (r.ok) {
      storeKey(k);
      $('newKeyInput').value = '';
      showToast('Anahtar değiştirildi. Uygulamadaki kayıtlı anahtarı da güncelleyin.');
    } else {
      showToast(errText(r), true);
    }
  } catch (e) {
    showToast('Pano ile bağlantı kurulamadı.', true);
  }
}

// ============================================================================
// Başlatıcı
// ============================================================================
(function init() {
  // Esnek kutuda 'gap' yoksa (iOS < 14.1, Chrome < 84) kenar boşluğu yedeği için <html>'e 'nogap' eklenir
  try {
    const probe = document.createElement('div');
    probe.style.cssText = 'display:flex;flex-direction:column;row-gap:1px;position:absolute;visibility:hidden';
    probe.appendChild(document.createElement('i'));
    probe.appendChild(document.createElement('i'));
    document.body.appendChild(probe);
    const hasGap = probe.scrollHeight === 1;
    document.body.removeChild(probe);
    if (!hasGap) document.documentElement.className += ' nogap';
  } catch (e) { /* yedek uygulanmaz */ }
  try {
    const link = document.querySelector('link[rel="icon"]');
    if (link && $('logoImg')) $('logoImg').src = link.href;   // aynı simge iki kez gömülmesin
  } catch (e) { /* simge isteğe bağlı */ }
  updateLogoutBtn();
  // Kayıtlı anahtar varsa açılışta GET /api/auth/check ile doğrulanır (otomatik giriş). 401 -> anahtar silinir (api() içinde);
  // anahtar kutusunu ilk yoklama açar: kurulum ağındaki (AP kaynaklı) istemcide kutu hiç görünmez. Ağ hatasında anahtar korunur.
  const start = function () { schedulePoll(0); };   // yapılandırma, tam durum (anahtar geçerli) alınınca fetchStatus içinde yüklenir
  if (deviceKey) {
    api('/api/auth/check', { quiet: true }).then(function (r) { if (r.ok) keyAccepted(); }).catch(function () { /* ağ hatası */ }).then(start);
  } else {
    start();
  }
})();
</script>
</body>
</html>
)rawliteral";
