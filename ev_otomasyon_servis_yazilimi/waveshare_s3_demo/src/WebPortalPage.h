#pragma once
// ============================================================================
// WebPortalPage.h - Gomulu web arayuzu (tek sayfa, GET /).
//
// Bu dosyanin kaynagi WebPortal.cpp'den ayrilmistir; arayuz mantigi (JS) bu dosyadadir.
// Guvenlik tasarimi (CONTRACTS Bolum 3, 3d):
//  - Kimlik: sayfa anahtarsiz yuklenir; JS cihaz anahtarini ister, sessionStorage'da tutar ve her
//    istekte "X-Device-Key" basligiyla gonderir. Provizyonsuz cihazda kurulum (factory/init) formu cikar.
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
<title>AHBU Akıllı Ev &amp; Bina Kontrol</title>
<link rel="icon" type="image/png" href="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACQAAAAkCAIAAABuYg/PAAABCGlDQ1BJQ0MgUHJvZmlsZQAAeJxjYGA8wQAELAYMDLl5JUVB7k4KEZFRCuwPGBiBEAwSk4sLGHADoKpv1yBqL+viUYcLcKakFicD6Q9ArFIEtBxopAiQLZIOYWuA2EkQtg2IXV5SUAJkB4DYRSFBzkB2CpCtkY7ETkJiJxcUgdT3ANk2uTmlyQh3M/Ck5oUGA2kOIJZhKGYIYnBncAL5H6IkfxEDg8VXBgbmCQixpJkMDNtbGRgkbiHEVBYwMPC3MDBsO48QQ4RJQWJRIliIBYiZ0tIYGD4tZ2DgjWRgEL7AwMAVDQsIHG5TALvNnSEfCNMZchhSgSKeDHkMyQx6QJYRgwGDIYMZAKbWPz9HbOBQAAALM0lEQVR42k2Xa4xd11XH19pn73PuPffOfXnGM+NHHDseOzNx6jycJg1pkyiKilqB8gWJDyCBgaZQVQhSBVWgIj4gykOi/UCpqOADfGgrKC2KqKqobQJpipKmThvHdm1nnNhje5733pn7OI+914MPdybKPls6WtLR+Z//OltrrR/+6KcXjTGICAC4t4wxAAigxhhARACEyRMAqAoAAKgAigAAiAKqoqCqoACgqiKiqqq7IQCIiEXESbAnicYYREAAYyJERARENAAKinuioKC4F6qKokYAiqKgygBoooiYAeB9MQCwk9vEmUE0iIFZdOIQDCKiQQMIoIgGEQEBYXcpKkwuAAVVEVUWFRJrwLlIVJn5fT92oqQALoqYuV9Kbaq1r9OpVp2NwEQQRYAIBsEAGATzvhKA7m1REAUREAFmKArpdnvdfr+RGOdsIJqoWBVVhDiOssKvDfmuY8eI5fv/+/qVq9eCL6MPLOtcHLu0WqmmVVQYZ1mW5yEQE7GIsqgqi8RJcvLk8UceeiCtNy9fuTrXcNXElSEAgFWAyCARX9sYnTxx95vnL/3NX33RDzfvPHygllYjE0XWmshG1lpnYxfHSSV2MQCUZV6WOQViYhURFWEmCoPR+Fv/tlbbd/BP/vTziwvHLly4cPeBVoSGQPCVNy4kzr1zq5t25rM8/8M/+P2P3r/wzDO/2my04sTFLrbO7TqLTGSjyEYuQlFlUiIKxCICAMJCTCGEoiiGg8ELL3z3hz+5+OWvfLVRrw03by0cms6Dj85+6jNMfGNzNHvg0Ff+4at3tOzZ3/4tZhUVEVBVZiYiIibiQGwQjh2crafJ2kavKLksvQ/ee/Y+lKX3PvgyiOJDHz6zefPGq2+c//gvf3xtbb1dcwhoAHRclC5Jtnq9m8tXnnrqiZ3hkFUmp1FEmFlEEAHRVCvx0vHDaT1tNqbuXTxaTVxkokZ96q4j80cPzx2Y2wcAaFCEu73+k09+dPX6O5tbWzZJRlmJAgZUi6JUwOFg0Gqk9al6IC8qJEzMxMwiAECCzkanTtwJxv7e8186+9wXieXUySOREZRw8eLbz33u+e1eryzzEEhEgvfVWtpq1ne2+4gmLws1apjEF56IVSSOY2YJnilMMqeBgdSWZK0x9917or89ePYL//x/b1x6+aWfPf+33x5k4UOLJ2v1ar8/Hva2trr99fWNcTbyIQQiQIzjhIiZqMgKIjIUyHvPRKIqokXhg9+VKj0JpCS1SmLP3L+0cvPWZz77ude+++9nPvaxp88+99pPbvz6p/94dWdr8fid3hdzM+2sKLazYlT4IlAg9qVXERZh5rIsvQ+GiDz5QESBAcD7wlPpA5NX1YonV6/yh+9buHTpytnf/ezyhQu/9PD90r+xc+OtJ5+Yh+nec3/3599/+XUGvN0bkajE9SJKSoWSKC9LFp6YCRSYyBCREFOgEIiZi7L0nkKpRNF47Fupf+CeI6++fv5Tz/5Rb2P9gQcXmknpZLBv8HYULjz22MPv/PDyc5//s/WtblLvcKC4PQvtWTI2EJXeq3AgCj6ICDEbVQDAQFQSMbMvKXhWhcLnM51o4c793/re63/59Z9J7a7jH3rw+NOP11oHMjuNnU6xM+4vN5/6tWcVtn88PPf4Jx998PTpE3ONyMbqEmIJpRfR0vvCl6qqIgZUAYGYvQ+gMPlbRZl32snMTPsb3/z2X3/hL/Ib1xYefWb61CfeXZvhw48UBJzIsYfvssXqYPPSwice0dHO17705f/8r+90nNnvez4bB2FPXlQKXxalnxRSO6nHnkgQWZiZAGSqZvOs/Nd/+toPXnyx0Z5ZrPWmuu+2o/rGrUvXA8H22k6vuLpZaWPsXKV3s2c2umHo/+Uf//76u9cef+rpSjHMisL7oEzeEyiJRqpqRURFvaegKizMGspsbTVvNBunT9+z+u6VbCezWG0enN0adl13OQt55LUSZGVQDKpJ1Kb06HzV2KX5DVc/dOqeE5sbW9vb24FDYFGFoixBGSQREcsgCup9KJhEYTgYvLN2y6VNl1SXFhcOLT30zptv1w6dygi61970YqaCX5ypm7TZXe0PObRhWKtNgdns3Lu/uu/ujN25n7/MPpRjmJ0/IMqF9ygMUAHda55F6XOvwjwcDtfXt1b7Wa1zZG5me1BoppVB56hxld7WdqtFt8fieZjWOTXa4h3ZgbVXx2PSrTKaDYOV4ubN0YX+7Z0pPdxotpmoKEqzOzKoBVZQ8CEUpbCIJ2q05qtzS5h2PK1XuX+wWfbO/beqa9YwVvXgrvXGyY4/c7ixkOqVuYM4AnmvqI+7HOXcpOOn7s1n/ei2MJEw5XkeGzPpQVZVFZSIQmBUMZFLW62AXBYrWeYpBC4y6p+rpZWZdlIqTldjkvFqHraGeRRcc0z97ahy/KnhzZsgt1JPo9uhYpvNNmIQEQ5liZEVVVAwkzSS5+A9ABg0xoCVbqKb4+HAt7C6NJeh3N4udjJvHWyG0Rjy1lSyOdKf3uLrG7XujT4HL7W2Fy0zD5kzZG1k0RgR8d5TIABQEDsZvwKF4L0CgKjRQjgIjbOxmznkDhzft7E84m6Z25pQWPzIjOep8Fbe2/YrRezSJ+Dwa92VV4b9ZHo2LYpSCcQJAAqzMPuisAlOZiyroKIqRORLYRImEaBQUCjA4fqQln90sXn3r+zfzqYXDt3++ff656/5aoW8aTu8Y3/Td88d+QhsXe3YeGmcjJPxeRQmHwMgiChoWRTO2MkYaUEVAIhCCIEp+FCwaqAyhKAi+dbBytRCtroxHJVbRXnU0O1y6t3L2zOHlvYfPlC79Iom7q2X1ht5GBcbtipQldhVQggGkZkkEAeapBFArSqICAdWZlUNHEQkhKAsNrYOpscb1Y6sp7PzWKwUxU77wfkT043a9NK+pcdkuJqNbk2pbSSC2RrYJoolIhOCMREHImJR0L1tAcEgqDAaE0IoiwKNURZhGg3LhYPjuMn11jFxVefziqvHszVfLa1NiG7N3Xd3mc+NxuOQF4FlHOjqtfciMMwiAhyCKGAUizIqgIAFVGcNsK/WmzbtZKNRvdFU1UDky+L68uVao5PdWI5sBCCVCuIyuYoN4XI+yFFtmZexNaqKCC6KinEWV2txrCaCUZ7ZdCZtzMJ4NXaRgloRjZ1tVd3N4Wjh3jM333qpXmcA+PTv/Ea320sq1TsOH7qy/N7lq9dVaPHknZU03t7ZbjUbzanG5saW98GXHo1JK5V+f+c3l05udvtf/48XqpUkL/jE6Uez0XA2tZXYiaidHMrjR2auv/YLSOzskZPlYG2qnl78xRVfhp3BcGXldl74bDwaDIeVBNa21mZm9u3sbG+sbzXqU8yaxMn16yvBh4MH51/6nx+72CWxVTQH7loyGGi8trC4sAs+3/jOi3meDwc7l66unF/eAGMsMoe8yDJjDKJhZhMZ56wxACLWIRqjoMLCpBRkj1EAAFgkMqZSrWrkSCIVWTw6vXj0cHtfJ62nFgEMIKiZ69RD8Cubo6wUxqqrVQAAEZxBABBVVrDOCCKgTljNRODiXRqbFCSLAAClolVTsTDXqc8208hZYxAVrCogmjh2SaUyVYnarow5QGxFJwRoEBX30OyDBAiggKgKoCoCAKiqqjL5RA1ZjNis1CvVWhzHiKiiFgGiyLjYVdO01WqHwLq1kedjFAFAExmDZvLyCRfu6uyBk6qqKIoAoqqwiIqIQpy46enpdmdfLU1j54wxgGDRIBp0zqVpVUURMakko2xcFqUIfwBE95gTYZf9YLfiTQzppGWpIKJzrlarNepTjUajWqvY2KIxgPD/xMf0FbvfHQIAAAAASUVORK5CYII=">
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
input[type="text"], input[type="password"], input[type="number"], select { background: #0f172a; border: 1px solid var(--card-border); color: var(--text); padding: 8px 12px; border-radius: 8px; font-size: 14px; width: 100%; }
input[type="text"]:focus, input[type="password"]:focus, input[type="number"]:focus, select:focus { outline: none; border-color: var(--primary); }
.terminal-window { background: #000; border: 1px solid var(--card-border); border-radius: 10px; height: 320px; padding: 14px; font-family: monospace; font-size: 13px; color: #10b981; overflow-y: auto; white-space: pre-wrap; margin-bottom: 12px; }
.toast { position: fixed; bottom: 20px; right: 20px; background: var(--primary); color: white; padding: 12px 20px; border-radius: 10px; box-shadow: 0 10px 15px -3px rgba(0,0,0,0.3); font-weight: 600; display: none; z-index: 2000; max-width: 90vw; }
.mode-cards-group { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 12px; margin-top: 6px; }
.mode-card { display: flex; flex-direction: column; padding: 12px 14px; border-radius: 10px; background: #0f172a; border: 1.5px solid var(--card-border); cursor: pointer; transition: all 0.2s ease; user-select: none; }
.mode-card:hover { border-color: rgba(96, 165, 250, 0.6); background: #131d31; }
.mode-card.selected { background: rgba(59, 130, 246, 0.12); border-color: var(--primary); box-shadow: 0 0 12px rgba(59, 130, 246, 0.25); }
.mode-card-header { display: flex; align-items: center; gap: 8px; font-weight: 700; font-size: 13.5px; color: var(--text); }
.mode-card-desc { font-size: 12px; color: var(--text-muted); margin-top: 6px; line-height: 1.4; }
.mode-card-wiring { font-size: 11px; color: #34d399; margin-top: 8px; padding-top: 6px; border-top: 1px dashed rgba(255, 255, 255, 0.1); line-height: 1.4; }
.pair-grid { display: grid; grid-template-columns: 2fr 1fr; gap: 16px; align-items: start; }
.grid-2col { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
.overlay { position: fixed; inset: 0; background: rgba(2, 6, 23, 0.92); z-index: 1500; display: none; align-items: center; justify-content: center; padding: 16px; }
.overlay-card { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 14px; padding: 22px; width: 100%; max-width: 440px; display: flex; flex-direction: column; gap: 12px; }
.muted { color: var(--text-muted); font-size: 13px; line-height: 1.5; }
.err-banner { background: rgba(239, 68, 68, 0.12); border: 1px solid rgba(239, 68, 68, 0.4); color: #fca5a5; padding: 12px 14px; border-radius: 10px; margin-bottom: 14px; font-size: 13px; display: none; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap; }
.secret-box { background: #0f172a; border: 1px dashed var(--accent); border-radius: 10px; padding: 12px; font-family: monospace; font-size: 13px; word-break: break-all; line-height: 1.7; }
.ap-banner { display: none; background: rgba(245, 158, 11, 0.14); border-bottom: 1px solid rgba(245, 158, 11, 0.55); color: #fcd34d; padding: 10px 20px; font-size: 13.5px; font-weight: 600; text-align: center; line-height: 1.5; }
body.ap-mode .nav-tab:not([data-tab="wifi"]):not(.active) { opacity: 0.6; }
body.ap-mode .content-section:not(#tab-wifi) { display: none !important; }
.key-gate { display: none; max-width: 560px; margin: 24px auto; padding: 0 16px; }
.key-gate .card { gap: 10px; }
.net-list { display: flex; flex-direction: column; gap: 6px; max-height: 300px; overflow-y: auto; margin-top: 4px; }
.net-row { display: flex; align-items: center; gap: 10px; width: 100%; padding: 10px 12px; background: #0f172a; border: 1px solid var(--card-border); border-radius: 10px; color: var(--text); font-size: 14px; cursor: pointer; text-align: left; transition: 0.15s; }
.net-row:hover { border-color: rgba(96, 165, 250, 0.6); background: #131d31; }
.net-row.sel { border-color: var(--primary); background: rgba(59, 130, 246, 0.14); }
.net-lock { width: 22px; text-align: center; flex: none; }
.net-ssid { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 600; }
.net-rssi { flex: none; min-width: 58px; text-align: right; font-size: 12px; color: var(--text-muted); }
.bars { flex: none; display: inline-flex; align-items: flex-end; gap: 2px; height: 16px; }
.bars i { display: block; width: 4px; background: #334155; border-radius: 1px; }
.bars i.on { background: var(--success); }
.conn-state { display: none; margin-top: 14px; padding: 12px 14px; border-radius: 10px; font-size: 13.5px; line-height: 1.6; border: 1px solid transparent; word-break: break-word; }
.conn-state.progress { display: block; background: rgba(59, 130, 246, 0.10); border-color: rgba(59, 130, 246, 0.45); color: #93c5fd; }
.conn-state.ok { display: block; background: rgba(16, 185, 129, 0.12); border-color: rgba(16, 185, 129, 0.5); color: #6ee7b7; }
.conn-state.err { display: block; background: rgba(239, 68, 68, 0.12); border-color: rgba(239, 68, 68, 0.45); color: #fca5a5; }
.conn-state.warn { display: block; background: rgba(245, 158, 11, 0.12); border-color: rgba(245, 158, 11, 0.5); color: #fcd34d; }
@media (max-width: 720px) {
  .pair-grid, .grid-2col { grid-template-columns: 1fr !important; }
}
</style>
</head>
<body>

<header>
  <div class="logo-title">
    <img id="logoImg" alt="" style="width:38px;height:38px;border-radius:9px;box-shadow:0 2px 10px rgba(0,0,0,0.4);vertical-align:middle;">
    <div>
      <h1 style="font-size: 18px; font-weight: 700;" id="hdrDevName">Akıllı Ev &amp; Bina Kontrol</h1>
      <span style="font-size: 12px; color: var(--text-muted);">Waveshare ESP32-S3 Endüstriyel Pano Modülü</span>
    </div>
  </div>
  <div class="header-info">
    <span>🌐 IP: <b id="hdrIp">-</b></span>
    <span>📶 WiFi: <b id="hdrRssi">-</b></span>
    <span>⏱️ Uptime: <b id="hdrUptime">-</b></span>
  </div>
</header>

<div class="ap-banner" id="apBanner" role="status">🔧 Kurulum modu (AP): yalnızca Wi-Fi ayarlarını değiştirebilirsiniz.</div>

<div class="nav-tabs">
  <div class="nav-tab active" data-tab="control" onclick="switchTab('control', this)">⚡ Kontrol</div>
  <div class="nav-tab" data-tab="config" onclick="switchTab('config', this)">⚙️ Kanal Ayarları</div>
  <div class="nav-tab" data-tab="wifi" onclick="switchTab('wifi', this)">📶 Wi-Fi (Station)</div>
  <div class="nav-tab" data-tab="rs485" onclick="switchTab('rs485', this)">📟 RS485 Terminal</div>
  <div class="nav-tab" data-tab="system" onclick="switchTab('system', this)">ℹ️ Sistem</div>
</div>

<!-- AP kaynaklı (anahtarsız) kurulum modunda Wi-Fi dışındaki sekmelerde gösterilir -->
<div class="key-gate" id="keyGate">
  <div class="card">
    <h3 style="font-size: 16px;">🔑 Bu işlem için cihaz anahtarı gerekir</h3>
    <p class="muted">Kurulum modunda (AP) yalnızca Wi-Fi ayarlarını anahtarsız değiştirebilirsiniz. Diğer ayarlar için cihaz anahtarını girin (anahtar cihazın etiketinde/servis kaydında veya uygulamada bulunur).</p>
    <input type="password" id="gateKey" placeholder="Cihaz anahtarı" autocomplete="off" onkeydown="if(event.key==='Enter')submitGateKey()">
    <button class="btn btn-primary" style="justify-content: center;" onclick="submitGateKey()">Giriş</button>
    <span class="muted" id="gateMsg" role="alert"></span>
  </div>
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

  <div class="err-banner" id="cfgLoadError">
    <span>Yapılandırma cihazdan yüklenemedi.</span>
    <button class="btn btn-outline" style="padding: 6px 12px;" onclick="loadConfig(3)">Tekrar dene</button>
  </div>

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
    Panjur motorları 2 röle (Yukarı + Aşağı) gerektirir ve birleşik grup olarak çalışır; yön değişiminde <b>yazılımsal</b> 500 ms ölü zaman uygulanır.
    Bu yazılımsal bir korumadır: motor güvenliği için <b>harici kontaktör veya mekanik interlock</b> kullanılması önerilir. Lamba veya kilit için münferit seçim yapabilirsiniz.
  </p>
  <div id="cfgRelayPairsContainer" style="display: flex; flex-direction: column; gap: 16px;"></div>

  <div class="section-title" style="margin-top: 36px;">
    <span id="cfgDITitle">🔘 Giriş Yapılandırması (Duvar Butonları &amp; Sensörler)</span>
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
    <p style="font-size: 13px; color: var(--text-muted); margin-bottom: 14px;">Cihazın ev modemi üzerinden yerel ağa bağlanmasını sağlar. Böylece modeme bağlı tüm telefon ve bilgisayarlardan doğrudan erişebilirsiniz. Wi-Fi bilgileri yalnızca bağlantı doğrulanınca kalıcı olarak kaydedilir.</p>

    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px;">
      <label style="font-size: 13px; font-weight: 600;">📡 Çevredeki Wi-Fi Ağları:</label>
      <button type="button" class="btn btn-outline" id="btnWifiRescan" style="padding: 4px 10px; font-size: 12px;" onclick="scanWifi(true)">🔄 Ağları Yenile</button>
    </div>
    <div id="wifiNetList" class="net-list" role="listbox" aria-label="Çevredeki Wi-Fi ağları"></div>
    <span id="scanStatus" style="font-size: 12px; color: var(--text-muted); display: block; margin-top: 4px;"></span>

    <div style="margin-top: 10px;">
      <button type="button" id="btnWifiQr" class="btn btn-outline" style="width: 100%; justify-content: center; font-size: 13px; font-weight: 600; border-color: #06B6D4; color: #06B6D4;" onclick="triggerWifiQrScan()">
        📷 Modem Wi-Fi Karekodu Tara (Kamera / Fotoğraf)
      </button>
      <input type="file" id="wifiQrFileInput" accept="image/*" capture="environment" style="display: none;" onchange="handleWifiQrFile(event)">
      <span id="qrHint" style="font-size: 11px; color: var(--text-muted); display: block; margin-top: 4px;">
        Modem etiketindeki veya telefonunuzdaki Wi-Fi karekodunu taratarak SSID ve şifreyi otomatik doldurabilirsiniz.
      </span>
    </div>

    <div style="margin-top: 14px;">
      <label for="wifiSsid" style="font-size: 13px; font-weight: 600; margin-bottom: 6px; display: block;">Seçilen Wi-Fi Adı (SSID):</label>
      <input type="text" id="wifiSsid" placeholder="Listeden bir ağa dokunun veya adı yazın" autocomplete="off" autocapitalize="off" spellcheck="false">
    </div>

    <div style="margin-top: 14px;">
      <label for="wifiPass" style="font-size: 13px; font-weight: 600; margin-bottom: 6px; display: block;">Wi-Fi Şifresi:</label>
      <input type="password" id="wifiPass" placeholder="Wi-Fi Şifreniz" autocomplete="off">
      <label style="display: flex; align-items: center; gap: 6px; margin-top: 6px; font-size: 12px; color: var(--text-muted); cursor: pointer;">
        <input type="checkbox" id="wifiPassShow" style="width: auto;" onchange="toggleWifiPass()"> Şifreyi göster
      </label>
    </div>

    <div style="display: flex; gap: 10px; margin-top: 16px;">
      <button type="button" id="btnWifiConnect" class="btn btn-primary" style="flex: 1; justify-content: center;" onclick="connectWifi()">Bağlan ve Kalıcı Kaydet</button>
      <button id="btnWifiDisconnect" class="btn btn-danger" style="display: none; padding: 10px 14px; font-size: 13px;" onclick="disconnectWifi()">Bağlantıyı Kes</button>
    </div>

    <div id="wifiConnState" class="conn-state" role="status" aria-live="polite"></div>
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
    <button class="btn btn-secondary" onclick="extRelayBtn(1, 2)">⚡ Modül Röle 1 Toggle</button>
    <button class="btn btn-secondary" onclick="extRelayBtn(0, 0)">🔴 Modül Tümünü Kapat</button>
  </div>

  <div class="terminal-window" id="rs485Terminal">Terminal başlatılıyor...</div>

  <div style="display: flex; gap: 10px; flex-wrap: wrap;">
    <select id="rs485Format" style="width: 110px;">
      <option value="ascii">Metin (ASCII)</option>
      <option value="hex">HEX (Onaltılı)</option>
    </select>
    <input type="text" id="rs485Input" placeholder="Gönderilecek veri (Örn: 01 03 00 00 00 02 C4 0B veya Ping)" style="flex: 1;" autocomplete="off">
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
      <div><b>Cihaz Kimliği:</b> <span id="sysUid">-</span></div>
      <div><b>Yazılım Sürümü:</b> <span id="sysFw">-</span></div>
      <div><b>Bulut (MQTT):</b> <span id="sysMqtt">-</span></div>
      <div><b>Cihaz Adı:</b> <input type="text" id="sysDevName" maxlength="31" style="width: 220px; display: inline-block; padding: 4px 8px;" autocomplete="off"></div>
    </div>
    <div style="display: flex; gap: 10px; margin-top: 10px; flex-wrap: wrap;">
      <button class="btn btn-primary" onclick="saveDevName()">İsmi Güncelle</button>
      <button class="btn btn-secondary" onclick="rebootSystem()">🔄 Yeniden Başlat</button>
      <button class="btn btn-danger" onclick="resetSystem()">⚠️ Fabrika Ayarlarına Dön</button>
    </div>

    <div style="border-top: 1px solid var(--card-border); padding-top: 14px;">
      <h3 style="font-size: 15px; margin-bottom: 8px;">🔑 Cihaz Anahtarını Değiştir</h3>
      <p class="muted" style="margin-bottom: 8px;">Yerel (LAN) erişim anahtarı 8-32 karakter olmalıdır (boşluksuz, yazdırılabilir ASCII). Değişince uygulamadaki kayıtlı anahtar da güncellenmelidir.</p>
      <div style="display: flex; gap: 8px; flex-wrap: wrap;">
        <input type="password" id="newKeyInput" placeholder="Yeni anahtar" style="flex: 1; min-width: 180px;" autocomplete="off">
        <button class="btn btn-secondary" onclick="rekeyDevice()">Anahtarı Değiştir</button>
      </div>
    </div>
  </div>
</div>

<div class="toast" id="toast">İşlem başarılı!</div>

<!-- Kimlik doğrulama / provizyon katmanı -->
<div class="overlay" id="authOverlay">
  <div class="overlay-card">
    <h3 id="authTitle">Cihaz Anahtarı Gerekli</h3>
    <p class="muted" id="authMsg"></p>

    <div id="authLoginBox" style="display: flex; flex-direction: column; gap: 10px;">
      <input type="password" id="authKey" placeholder="Cihaz anahtarı" autocomplete="off" onkeydown="if(event.key==='Enter')submitKey()">
      <button class="btn btn-primary" style="justify-content: center;" onclick="submitKey()">Giriş</button>
      <p class="muted">Anahtar, cihazın etiketinde/servis kaydında veya uygulamada (Cihaz Ayarları) bulunur.</p>
    </div>

    <div id="authProvBox" style="display: none; flex-direction: column; gap: 10px;">
      <p class="muted">Bu cihaz henüz kurulmamış (provizyonsuz). Yerel erişim anahtarı ve kurtarma ağı (AP) parolası belirleyin. <b>Bu iki değeri güvenli bir yere kaydedin</b>; sonradan yalnızca anahtarla değiştirilebilir.</p>
      <label class="muted">Yerel anahtar (8-32 karakter)</label>
      <div style="display: flex; gap: 8px;">
        <input type="text" id="provKey" maxlength="32" autocomplete="off" autocapitalize="off" spellcheck="false">
        <button class="btn btn-outline" onclick="fillRandom('provKey', 24)">Üret</button>
      </div>
      <label class="muted">Kurtarma ağı (AP) parolası (8-32 karakter)</label>
      <div style="display: flex; gap: 8px;">
        <input type="text" id="provAp" maxlength="32" autocomplete="off" autocapitalize="off" spellcheck="false">
        <button class="btn btn-outline" onclick="fillRandom('provAp', 16)">Üret</button>
      </div>
      <button class="btn btn-primary" style="justify-content: center;" onclick="submitProvision()">Cihazı Kur</button>
      <div class="secret-box" id="provResult" style="display: none;"></div>
      <button class="btn btn-secondary" id="provDone" style="display: none; justify-content: center;" onclick="closeProv()">Kaydettim, kapat</button>
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
  t.style.background = isError ? 'var(--danger)' : 'var(--primary)';
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
let deviceKey = '';
try { deviceKey = sessionStorage.getItem('ahbu_key') || ''; } catch (e) { deviceKey = ''; }
function storeKey(k) {
  deviceKey = k;
  try { if (k) sessionStorage.setItem('ahbu_key', k); else sessionStorage.removeItem('ahbu_key'); } catch (e) { /* gizli mod */ }
}

const API_TIMEOUT_MS = 7000;
async function api(path, opts) {
  opts = opts || {};
  const headers = {};
  if (deviceKey && !opts.nokey) headers['X-Device-Key'] = deviceKey;   // nokey: AP kaynaklı anahtarsız yol (eski/yanlış anahtar gönderilmez)
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
    if (!opts.quiet) onAuthResponse(out);   // quiet: çağıran 401/403/423'ü kendisi yorumlar (AP kaynaklı yol sondajı vb.)
    return out;
  } finally {
    clearTimeout(timer);
  }
}

function onAuthResponse(r) {
  if (apMode && (r.status === 401 || r.status === 423)) setApMode(false);   // AP kaynaklı yetki kalktı: anahtar gerekir
  if (r.status === 401) {
    showAuth('login', deviceKey ? 'Anahtar hatalı. Tekrar deneyin.' : 'Devam etmek için cihaz anahtarını girin.');
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
  $('authOverlay').style.display = 'none';
}

async function submitKey() {
  const k = $('authKey').value.trim();
  if (!k) { $('authMsg').textContent = 'Anahtarı girin.'; return; }
  storeKey(k);
  try {
    const r = await api('/api/auth/check');
    if (r.ok) {
      $('authKey').value = '';
      hideAuth();
      showToast('Giriş başarılı');
      schedulePoll(0);
      loadConfig(3);
    } else if (r.status !== 423) {
      storeKey('');
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
  storeKey(k);
  try {
    const r = await api('/api/auth/check', { quiet: true });
    if (r.ok) {
      $('gateKey').value = '';
      msg.textContent = '';
      setApMode(false);
      hideAuth();
      showToast('Giriş başarılı');
      schedulePoll(0);
      loadConfig(3);
      return;
    }
    storeKey('');
    if (r.status === 423) msg.textContent = 'Çok fazla hatalı deneme. ' + ((r.data && r.data.retry_after) ? r.data.retry_after : 60) + ' sn sonra tekrar deneyin.';
    else msg.textContent = 'Anahtar hatalı. Tekrar deneyin.';
  } catch (e) {
    storeKey('');
    msg.textContent = 'Pano ile bağlantı kurulamadı.';
  }
}

// ============================================================================
// Sekmeler
// ============================================================================
let activeTab = 'control';
function switchTab(tabId, el) {
  document.querySelectorAll('.nav-tab').forEach(function (t) { t.classList.remove('active'); });
  document.querySelectorAll('.content-section').forEach(function (s) { s.classList.remove('active'); });
  if (el) {
    el.classList.add('active');
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
      showAuth('login', deviceKey ? 'Anahtar kabul edilmedi.' : 'Devam etmek için cihaz anahtarını girin.');
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

  if (data.wifi_connected) {
    if (btnDisconnect) btnDisconnect.style.display = apMode ? 'none' : 'inline-flex';   // bağlantıyı kesmek anahtar ister
    card.style.background = 'rgba(16, 185, 129, 0.08)';
    card.style.border = '1px solid rgba(16, 185, 129, 0.35)';
    const ip = data.wifi_sta_ip;
    const ipHtml = isIpv4(ip)
      ? '<a href="http://' + esc(ip) + '" target="_blank" rel="noopener noreferrer" style="color: #34D399; font-weight: bold; text-decoration: underline; background: rgba(16,185,129,0.15); padding: 2px 8px; border-radius: 6px;">http://' + esc(ip) + '</a>'
      : esc(ip || '-');
    card.innerHTML =
      '<div style="display: flex; align-items: flex-start; gap: 14px;">' +
        '<div style="font-size: 28px; line-height: 1;">🟢</div>' +
        '<div style="flex: 1;">' +
          '<div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 6px;">' +
            '<div style="font-size: 15px; font-weight: 700; color: #10B981;">Modeme Bağlıyız (Ev Ağı Aktif)</div>' +
            '<span style="background: rgba(16, 185, 129, 0.2); color: #34D399; font-size: 11px; padding: 2px 8px; border-radius: 12px; font-weight: 600;">ÇEVRİMİÇİ</span>' +
          '</div>' +
          '<div style="margin-top: 10px; font-size: 13px; line-height: 1.9; color: var(--text);">' +
            '<div><b>Bağlı Bulunulan Ağ:</b> <span style="color: #60A5FA; font-weight: bold;">' + esc(data.wifi_sta_ssid || 'Bilinmiyor') + '</span></div>' +
            '<div><b>Cihazın IP Adresi:</b> ' + ipHtml + '</div>' +
            '<div><b>Sinyal Gücü:</b> <span style="font-weight: 600;">' + esc(data.wifi_sta_rssi) + ' dBm</span></div>' +
          '</div>' +
          '<div style="margin-top: 12px; padding: 10px 12px; background: rgba(0, 0, 0, 0.25); border-radius: 8px; font-size: 12px; color: var(--text-muted); border-left: 3px solid #10B981;">' +
            '💡 <b>Başka bir ağa bağlanmak için:</b> Aşağıdaki listeden yeni Wi-Fi ağını seçip şifresini yazarak <i>"Bağlan ve Kalıcı Kaydet"</i> butonuna tıklayın.' +
          '</div>' +
        '</div>' +
      '</div>';
  } else {
    if (btnDisconnect) btnDisconnect.style.display = 'none';
    card.style.background = 'rgba(245, 158, 11, 0.08)';
    card.style.border = '1px solid rgba(245, 158, 11, 0.35)';
    const apSsidHtml = data.wifi_ap_ssid ? ' <span style="font-weight: 600;">' + esc(data.wifi_ap_ssid) + '</span>' : '';
    const apLine = data.wifi_ap_active
      ? '<div><b>Kurulum/kurtarma ağı (AP) yayında:</b>' + apSsidHtml + '</div>' +
        (data.wifi_ap_ip ? '<div><b>Cihaz IP\'si:</b> <span style="color: #F59E0B; font-weight: bold; background: rgba(245,158,11,0.15); padding: 2px 8px; border-radius: 6px;">' + esc(data.wifi_ap_ip) + '</span></div>' : '')
      : '<div><b>Durum:</b> Kurtarma ağı şu an kapalı (kesinti sürerse otomatik açılır).</div>';
    let connLine = '';
    if (data.wifi_connect_state === 'connecting') connLine = '<div><b>Bağlanılıyor...</b></div>';
    else if (data.wifi_connect_state === 'failed') connLine = '<div style="color:#FCA5A5;"><b>Son bağlanma denemesi başarısız</b> (neden kodu: ' + esc(data.wifi_connect_reason) + ')</div>';
    card.innerHTML =
      '<div style="display: flex; align-items: flex-start; gap: 14px;">' +
        '<div style="font-size: 28px; line-height: 1;">📡</div>' +
        '<div style="flex: 1;">' +
          '<div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 6px;">' +
            '<div style="font-size: 15px; font-weight: 700; color: #F59E0B;">Yerel Erişim Noktası (AP Modu)</div>' +
            '<span style="background: rgba(245, 158, 11, 0.2); color: #FBBF24; font-size: 11px; padding: 2px 8px; border-radius: 12px; font-weight: 600;">MODEME BAĞLI DEĞİL</span>' +
          '</div>' +
          '<div style="margin-top: 10px; font-size: 13px; line-height: 1.9; color: var(--text);">' + apLine + connLine + '</div>' +
          '<div style="margin-top: 12px; padding: 10px 12px; background: rgba(0, 0, 0, 0.25); border-radius: 8px; font-size: 12px; color: var(--text-muted); border-left: 3px solid #F59E0B;">' +
            '👉 <b>Ev Ağına Bağlanmak İçin:</b> Aşağıdaki listeden ev Wi-Fi modeminize dokunun, şifrenizi girin ve <i>"Bağlan ve Kalıcı Kaydet"</i> butonuna tıklayın.' +
          '</div>' +
        '</div>' +
      '</div>';
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
      ? '<span style="background: rgba(168, 85, 247, 0.15); color: #C084FC; font-size: 11px; padding: 2px 7px; border-radius: 6px; font-weight: 600;">📦 Ek Modül CH ' + (i - 7) + '</span>'
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
        stateBadge = '<span class="card-type-badge" style="color: var(--accent); font-weight: bold;">' + (dir === 1 ? '▲ Açılıyor...' : '▼ Kapanıyor...') + '</span>';
      }
      const baseName = String(r.name || '').replace(/ \(Yukari\)/i, '');

      html +=
        '<div class="card">' +
          '<div class="card-header">' +
            '<div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">' +
              '<span class="' + indicatorClass + '"></span>' +
              '<span class="card-title">🪟 ' + esc(baseName) + '</span>' + modBadge +
            '</div>' + stateBadge +
          '</div>' +
          '<div style="font-size: 12px; color: var(--text-muted);">Konum: <b>%' + toInt(sh.pos) + '</b></div>' +
          '<div class="shutter-controls">' +
            '<button class="shutter-btn ' + (dir === 1 ? 'active' : '') + '" onclick="cmdShutter(' + pair1 + ', \'up\')">▲ AÇ</button>' +
            '<button class="shutter-btn" onclick="cmdShutter(' + pair1 + ', \'stop\')">⏹ DURDUR</button>' +
            '<button class="shutter-btn ' + (dir === 2 ? 'active' : '') + '" onclick="cmdShutter(' + pair1 + ', \'down\')">▼ KAPAT</button>' +
          '</div>' +
        '</div>';
    } else { // Normal lamba veya darbe rölesi
      const isLight = (type === 0);
      const icon = isLight ? '💡' : '⚡';
      const typeStr = isLight ? 'Aydınlatma' : 'Darbe (Tetik)';
      const onClass = r.state ? 'on' : '';
      const ch = i + 1;   // 1 tabanlı röle kanalı

      html +=
        '<div class="card">' +
          '<div class="card-header">' +
            '<div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">' +
              '<span class="status-indicator ' + onClass + '"></span>' +
              '<span class="card-title">' + icon + ' ' + esc(r.name) + '</span>' + modBadge +
            '</div>' +
            '<span class="card-type-badge">' + typeStr + '</span>' +
          '</div>' +
          '<div style="display: flex; justify-content: space-between; align-items: center;">' +
            '<span style="font-size: 13px; color: var(--text-muted);">Durum: <b>' + (r.state ? 'AÇIK' : 'KAPALI') + '</b></span>' +
            (isLight
              ? '<div class="switch-btn ' + onClass + '" onclick="toggleRelay(' + ch + ')"><div class="switch-knob"></div></div>'
              : '<button class="btn btn-secondary" style="font-size: 12px; padding: 6px 12px;" onclick="triggerImpulse(' + ch + ')">⚡ Tetikle</button>') +
          '</div>' +
        '</div>';
    }
  }
  grid.innerHTML = html;
}

function renderDIs(dis) {
  const grid = $('diGrid');
  const list = Array.isArray(dis) ? dis : [];
  let html = '';
  for (let i = 0; i < list.length; i++) {
    const d = list[i];
    if (!d) continue;
    html +=
      '<div class="di-pill ' + (d.state ? 'active' : '') + '">' +
        '<div style="display: flex; align-items: center; justify-content: center; gap: 4px;">' +
          '<span>DI ' + (i + 1) + '</span>' + (i >= 8 ? '<span style="font-size: 10px; color: #C084FC;">(Ek)</span>' : '') +
        '</div>' +
        '<div style="font-size: 11px; opacity: 0.8; margin-top: 4px;">' + (d.state ? 'KAPALI (ON)' : 'AÇIK (OFF)') + '</div>' +
      '</div>';
  }
  grid.innerHTML = html;
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
  if (sw) sw.classList.toggle('on', isEn);
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
    ? '<span style="background: rgba(168, 85, 247, 0.2); color: #C084FC; font-weight: 700; font-size: 13px; padding: 5px 12px; border-radius: 8px;">📦 Ek Modül - Çift ' + (p + 1) + ' (Röle ' + (r1 + 1) + ' & Röle ' + (r2 + 1) + ') [CH ' + (r1 - 7) + ' & ' + (r2 - 7) + ']</span>'
    : '<span style="background: ' + (isShut ? 'rgba(59, 130, 246, 0.2)' : 'rgba(148, 163, 184, 0.15)') + '; color: ' + (isShut ? '#60A5FA' : '#94a3b8') + '; font-weight: 700; font-size: 13px; padding: 5px 12px; border-radius: 8px;">⚡ Ana Pano - Çift ' + (p + 1) + ' (Röle ' + (r1 + 1) + ' & Röle ' + (r2 + 1) + ')</span>';

  let html =
    '<div class="card" style="background: var(--card-bg); border: 1.5px solid ' + (isShut ? 'rgba(59, 130, 246, 0.45)' : 'var(--card-border)') + '; border-radius: 14px; padding: 18px; gap: 14px;">' +
      '<div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 12px;">' +
        '<div style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap;">' + pairBadge +
          '<span style="font-size: 12.5px; color: var(--text-muted); font-weight: 600;">Çalışma Amacı:</span>' +
        '</div>' +
        '<div style="display: flex; gap: 6px; background: #0f172a; padding: 4px; border-radius: 10px; border: 1px solid var(--card-border);">' +
          '<button type="button" class="btn ' + (isShut ? 'btn-primary' : 'btn-outline') + '" style="padding: 6px 14px; font-size: 12.5px; border-radius: 7px;" onclick="setPairMode(' + p + ', true)">🪟 Panjur Motoru (Birleşik)</button>' +
          '<button type="button" class="btn ' + (!isShut ? 'btn-primary' : 'btn-outline') + '" style="padding: 6px 14px; font-size: 12.5px; border-radius: 7px;" onclick="setPairMode(' + p + ', false)">💡 Münferit / Ayrı Röleler</button>' +
        '</div>' +
      '</div>';

  if (isShut) {
    html +=
      '<div class="pair-grid">' +
        '<div>' +
          '<label style="font-size: 12.5px; color: var(--text-muted); font-weight: 600; display: block; margin-bottom: 6px;">🪟 Panjur Grubu Adı:</label>' +
          '<input type="text" id="cfgPairName_' + p + '" value="' + esc(baseName) + '" placeholder="Örn: Panjur ' + (p + 1) + '" oninput="onPairNameInput(' + p + ', this.value)" style="font-size: 14.5px; font-weight: 600;">' +
          '<div style="font-size: 12px; color: #60A5FA; margin-top: 8px; display: flex; align-items: center; gap: 14px; flex-wrap: wrap;">' +
            '<span>▲ <b>Röle ' + (r1 + 1) + ':</b> Yukarı (Açma)</span>' +
            '<span>▼ <b>Röle ' + (r2 + 1) + ':</b> Aşağı (Kapatma)</span>' +
            '<span style="background: rgba(245, 158, 11, 0.15); color: #FCD34D; padding: 2px 8px; border-radius: 6px; font-size: 11px;">🔒 Yazılımsal kilit (500 ms ölü zaman) — harici kontaktör/mekanik interlock önerilir</span>' +
          '</div>' +
        '</div>' +
        '<div>' +
          '<label style="font-size: 12.5px; color: var(--text-muted); font-weight: 600; display: block; margin-bottom: 6px;">Hareket Süresi (Motor Kapanma):</label>' +
          '<div style="display: flex; align-items: center; gap: 8px;">' +
            '<input type="number" id="cfgPairRuntime_' + p + '" value="' + toInt(runtime, 20) + '" min="1" max="300" oninput="onPairRuntimeInput(' + p + ', this.value)" style="width: 90px; text-align: center; font-weight: bold; font-size: 14.5px;">' +
            '<span style="font-size: 13px; color: var(--text-muted);">saniye (1-300)</span>' +
          '</div>' +
          '<div style="font-size: 11px; color: var(--text-muted); margin-top: 4px;">Süre dolunca motor otomatik durur.</div>' +
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
    '<div style="background: #0f172a; padding: 14px; border-radius: 10px; border: 1px solid rgba(255,255,255,0.06); display: flex; flex-direction: column; gap: 10px;">' +
      '<div style="display: flex; justify-content: space-between; align-items: center;">' +
        '<span style="font-weight: 700; font-size: 13.5px; color: #93C5FD;">💡 Röle ' + (r + 1) + ' (' + (isExt ? 'Ek Modül CH ' + (r - 7) : 'Pano Çıkışı') + ')</span>' +
        '<span style="font-size: 11px; color: var(--text-muted);">Tekli Yük</span>' +
      '</div>' +
      '<input type="text" id="cfgRName_' + r + '" value="' + esc(cfg.name) + '" oninput="onSingleNameInput(' + r + ', this.value)" placeholder="Kanal Adı (Örn: Lamba ' + (r + 1) + ')">' +
      '<div style="display: flex; gap: 10px; align-items: center;">' +
        '<div style="flex: 1;">' +
          '<select id="cfgRType_' + r + '" onchange="onSingleTypeChange(' + r + ', this.value)">' +
            '<option value="0"' + (t === 0 ? ' selected' : '') + '>💡 Normal Aydınlatma</option>' +
            '<option value="3"' + (t === 3 ? ' selected' : '') + '>⚡ Darbe / Tetik (Kilit)</option>' +
          '</select>' +
        '</div>' +
        (t === 3
          ? '<div style="display: flex; align-items: center; gap: 6px; width: 115px;">' +
              '<input type="number" id="cfgRRuntime_' + r + '" value="' + toInt(cfg.runtime_sec, 500) + '" min="1" max="60000" oninput="onSingleRuntimeInput(' + r + ', this.value)" placeholder="Süre" style="width: 75px; text-align: center;">' +
              '<span style="font-size: 12px; color: var(--text-muted);">ms</span>' +
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
      ? '<span style="background: rgba(168, 85, 247, 0.2); color: #C084FC; font-weight: 700; font-size: 13px; padding: 5px 12px; border-radius: 8px;">📦 Ek Modül - DI ' + (di1 + 1) + ' & DI ' + (di2 + 1) + ' [CH ' + (di1 - 7) + ' & ' + (di2 - 7) + ']</span>'
      : '<span style="background: rgba(59, 130, 246, 0.2); color: #60A5FA; font-weight: 700; font-size: 13px; padding: 5px 12px; border-radius: 8px;">🔘 Ana Pano - DI ' + (di1 + 1) + ' & DI ' + (di2 + 1) + '</span>';

    let html =
      '<div class="card" style="background: var(--card-bg); border: 1.5px solid rgba(59, 130, 246, 0.4); border-radius: 14px; padding: 18px; gap: 14px;">' +
        '<div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 12px;">' +
          '<div style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap;">' + diBadge +
            '<span style="font-weight: 700; font-size: 14px; color: #F59E0B;">🪟 Hedef Panjur: ' + esc(baseName) + '</span>' +
          '</div>' +
          '<div style="font-size: 12px; color: var(--text-muted); font-weight: 600;">Duvardaki Tesisat Tipi:</div>' +
        '</div>' +
        '<div class="grid-2col">' +
          '<div class="mode-card ' + (isSingle ? 'selected' : '') + '" onclick="setDIPairShutterWiring(' + p + ', \'single\')">' +
            '<div style="display: flex; align-items: center; gap: 8px; margin-bottom: 6px;">' +
              '<input type="radio" name="diWiring_' + p + '" value="single" ' + (isSingle ? 'checked' : '') + ' style="width:auto; margin:0;">' +
              '<span style="font-weight: 700; font-size: 14px; color: #10B981;">🪟 1. Tesisat: Tek Butonla Kontrol (2 Kablo)</span>' +
            '</div>' +
            '<div style="font-size: 12px; color: var(--text-muted);">DI ' + (di1 + 1) + ' tek yaylı butonla tüm panjuru yönetir. <b>DI ' + (di2 + 1) + ' girişi boşa çıkar (serbest kalır).</b></div>' +
          '</div>' +
          '<div class="mode-card ' + (!isSingle ? 'selected' : '') + '" onclick="setDIPairShutterWiring(' + p + ', \'dual\')">' +
            '<div style="display: flex; align-items: center; gap: 8px; margin-bottom: 6px;">' +
              '<input type="radio" name="diWiring_' + p + '" value="dual" ' + (!isSingle ? 'checked' : '') + ' style="width:auto; margin:0;">' +
              '<span style="font-weight: 700; font-size: 14px; color: #60A5FA;">⬆️⬇️ 2. Tesisat: Çift Tuşlu Anahtar (3 Kablo)</span>' +
            '</div>' +
            '<div style="font-size: 12px; color: var(--text-muted);">DI ' + (di1 + 1) + ' Yukarı Aç, DI ' + (di2 + 1) + ' Aşağı Kapat tuşu olarak iki ayrı klemens kullanılır.</div>' +
          '</div>' +
        '</div>';

    if (isSingle) {
      const freeTarget = currentConfig.dis[di2].target_relay;
      html +=
        '<div class="grid-2col" style="margin-top: 4px;">' +
          '<div style="background: rgba(16, 185, 129, 0.06); border: 1px solid rgba(16, 185, 129, 0.25); border-radius: 10px; padding: 14px; display: flex; flex-direction: column; gap: 8px;">' +
            '<div style="display: flex; justify-content: space-between; align-items: center;">' +
              '<span style="font-weight: 700; font-size: 13.5px; color: #34D399;">🔘 DI ' + (di1 + 1) + ' Panjur Butonu</span>' +
              '<span style="background: rgba(16, 185, 129, 0.2); color: #34D399; font-size: 11px; padding: 2px 8px; border-radius: 6px; font-weight: bold;">Panjura Atandı</span>' +
            '</div>' +
            '<input type="text" id="cfgDIName_' + di1 + '" value="' + esc(currentConfig.dis[di1].name) + '" oninput="onDINameInput(' + di1 + ', this.value)">' +
            '<div style="font-size: 12px; color: var(--text-muted);">Çalışma: <b>Aç ➔ Dur ➔ Kapat ➔ Dur</b> döngüsü.</div>' +
            '<div style="font-size: 11.5px; color: #34D399; margin-top: 4px;">🔌 <b>Bağlantı:</b> DGND ile DI ' + (di1 + 1) + ' arasına 2 kablo ile yaylı anahtar bağlanır.</div>' +
          '</div>' +
          '<div style="background: rgba(59, 130, 246, 0.06); border: 1px dashed rgba(59, 130, 246, 0.4); border-radius: 10px; padding: 14px; display: flex; flex-direction: column; gap: 8px;">' +
            '<div style="display: flex; justify-content: space-between; align-items: center;">' +
              '<span style="font-weight: 700; font-size: 13.5px; color: #60A5FA;">🟢 DI ' + (di2 + 1) + ' Girişi: SERBEST / BOŞTA</span>' +
              '<span style="background: rgba(59, 130, 246, 0.2); color: #93C5FD; font-size: 11px; padding: 2px 8px; border-radius: 6px; font-weight: bold;">İsteğe Bağlı</span>' +
            '</div>' +
            '<div style="font-size: 12px; color: var(--text-muted); line-height: 1.4;">Panjur tek butonla yönetildiği için DI ' + (di2 + 1) + ' klemensi <b>boştadır</b>. Dilerseniz başka bir aydınlatmaya atayabilirsiniz.</div>' +
            '<div style="display: flex; align-items: center; gap: 8px; margin-top: 4px;">' +
              '<span style="font-size: 12px; color: var(--text-muted); white-space: nowrap;">Tetikleyeceği Röle:</span>' +
              '<select id="cfgDITarget_' + di2 + '" onchange="onFreeDITargetChange(' + di2 + ', this.value)">' +
                '<option value="0"' + (freeTarget === 0 ? ' selected' : '') + '>-- Boşta (Röle Tetiklemez) --</option>' + freeRelayOptions +
              '</select>' +
            '</div>' +
            (freeTarget > 0
              ? '<div style="margin-top: 4px;">' +
                  '<input type="text" id="cfgDIName_' + di2 + '" value="' + esc(currentConfig.dis[di2].name) + '" oninput="onDINameInput(' + di2 + ', this.value)" placeholder="Buton Adı">' +
                  '<div style="font-size: 11px; color: #34D399; margin-top: 4px;">🔌 DGND ile DI ' + (di2 + 1) + ' arasına yaylı buton bağlanır.</div>' +
                '</div>'
              : '') +
          '</div>' +
        '</div>';
    } else {
      html +=
        '<div class="grid-2col" style="margin-top: 4px;">' +
          '<div style="background: rgba(59, 130, 246, 0.08); border: 1px solid rgba(59, 130, 246, 0.3); border-radius: 10px; padding: 14px; display: flex; flex-direction: column; gap: 8px;">' +
            '<div style="display: flex; justify-content: space-between; align-items: center;">' +
              '<span style="font-weight: 700; font-size: 13.5px; color: #60A5FA;">⬆️ DI ' + (di1 + 1) + ': YUKARI Açma Tuşu</span>' +
              '<span style="background: rgba(59, 130, 246, 0.2); color: #93C5FD; font-size: 11px; padding: 2px 8px; border-radius: 6px; font-weight: bold;">Panjur Aç</span>' +
            '</div>' +
            '<input type="text" id="cfgDIName_' + di1 + '" value="' + esc(currentConfig.dis[di1].name) + '" oninput="onDINameInput(' + di1 + ', this.value)">' +
            '<div style="font-size: 12px; color: var(--text-muted);">Basınca yukarı açar, giderken basılırsa durdurur.</div>' +
          '</div>' +
          '<div style="background: rgba(245, 158, 11, 0.08); border: 1px solid rgba(245, 158, 11, 0.3); border-radius: 10px; padding: 14px; display: flex; flex-direction: column; gap: 8px;">' +
            '<div style="display: flex; justify-content: space-between; align-items: center;">' +
              '<span style="font-weight: 700; font-size: 13.5px; color: #F59E0B;">⬇️ DI ' + (di2 + 1) + ': AŞAĞI Kapatma Tuşu</span>' +
              '<span style="background: rgba(245, 158, 11, 0.2); color: #FCD34D; font-size: 11px; padding: 2px 8px; border-radius: 6px; font-weight: bold;">Panjur Kapat</span>' +
            '</div>' +
            '<input type="text" id="cfgDIName_' + di2 + '" value="' + esc(currentConfig.dis[di2].name) + '" oninput="onDINameInput(' + di2 + ', this.value)">' +
            '<div style="font-size: 12px; color: var(--text-muted);">Basınca aşağı kapatır, inerken basılırsa durdurur.</div>' +
          '</div>' +
        '</div>' +
        '<div style="font-size: 11.5px; color: #34D399; padding: 8px 12px; background: rgba(52, 211, 153, 0.08); border-radius: 8px;">' +
          '🔌 <b>3 Kablolu Tesisat Bağlantısı:</b> Ortak uç <b>DGND</b>\'ye, Yukarı tuşu <b>DI ' + (di1 + 1) + '</b>\'e, Aşağı tuşu <b>DI ' + (di2 + 1) + '</b>\'e bağlanır.' +
        '</div>';
    }
    return html + '</div>';
  }

  // Münferit giriş çifti
  return (
    '<div class="card" style="background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 14px; padding: 18px; gap: 14px;">' +
      '<div style="font-weight: 700; font-size: 13.5px; color: #94A3B8; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 10px;">' +
        '🔘 Bağımsız Girişler: DI ' + (di1 + 1) + ' ve DI ' + (di2 + 1) + ' (' + (isExt ? 'Ek Modül' : 'Ana Pano') + ')' +
      '</div>' +
      '<div class="grid-2col">' + renderSingleDICard(di1, totalRelays) + renderSingleDICard(di2, totalRelays) + '</div>' +
    '</div>'
  );
}

function sectionBox(color, icon, title, subtitle, badge, inner) {
  return (
    '<div style="background: rgba(30, 41, 59, 0.4); border: 1.5px solid ' + color + '; border-radius: 16px; padding: 20px; display: flex; flex-direction: column; gap: 16px;">' +
      '<div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; border-bottom: 1px solid rgba(255,255,255,0.08); padding-bottom: 12px;">' +
        '<div style="display: flex; align-items: center; gap: 10px;">' +
          '<span style="font-size: 22px;">' + icon + '</span>' +
          '<div><div style="font-size: 16px; font-weight: 700; color: ' + (icon === '📦' ? '#C084FC' : '#60A5FA') + ';">' + title + '</div>' +
          '<div style="font-size: 12px; color: var(--text-muted);">' + subtitle + '</div></div>' +
        '</div>' +
        '<span style="background: ' + (icon === '📦' ? 'rgba(168, 85, 247, 0.15)' : 'rgba(59, 130, 246, 0.15)') + '; color: ' + (icon === '📦' ? '#E9D5FF' : '#93C5FD') + '; font-size: 12px; padding: 4px 12px; border-radius: 8px; font-weight: 600;">' + badge + '</span>' +
      '</div>' +
      '<div style="display: flex; flex-direction: column; gap: 14px;">' + inner + '</div>' +
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
    let full = sectionBox('rgba(59, 130, 246, 0.35)', '🏠', 'Ana Cihaz Röle Çıkışları', 'Yerel 8RO Pano Klemensleri (Röle 1 - 8)', '8 Kanal / 4 Çift', main);
    if (isExt && totalPairs > 4) {
      let ext = '';
      for (let p = 4; p < totalPairs; p++) ext += renderRelayPairCard(p);
      full += '<div style="margin-top: 10px;">' +
        sectionBox('rgba(168, 85, 247, 0.45)', '📦', 'Harici RS485 Ek Modül Röleleri',
          'RS485 Genişletme Kartı Çıkışları (Röle 9 - ' + totalRelays + ') • Slave ID: ' + toInt(currentConfig.ext_module_address, 1),
          'Ek ' + extCh + ' Kanal / ' + (extCh / 2) + ' Çift', ext) + '</div>';
    }
    rContainer.innerHTML = full;
  }

  // 2. Girişler
  const diContainer = $('cfgDIPairsContainer');
  if (diContainer) {
    let main = '';
    for (let p = 0; p < 4; p++) main += renderDIPairCard(p, totalRelays);
    let full = sectionBox('rgba(59, 130, 246, 0.35)', '🏠', 'Ana Cihaz Girişleri (Duvar Butonları)', 'Yerel 8DI Duvar Butonu ve Sensör Klemensleri (DI 1 - 8)', '8 Giriş / 4 Çift', main);
    if (isExt && totalPairs > 4) {
      let ext = '';
      for (let p = 4; p < totalPairs; p++) ext += renderDIPairCard(p, totalRelays);
      full += '<div style="margin-top: 10px;">' +
        sectionBox('rgba(168, 85, 247, 0.45)', '📦', 'Harici RS485 Ek Modül Girişleri',
          'RS485 Genişletme Kartı Girişleri (DI 9 - DI ' + totalRelays + ')',
          'Ek ' + extCh + ' Giriş / ' + (extCh / 2) + ' Çift', ext) + '</div>';
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
    typeInfo = '<div style="font-size: 12px; color: var(--text-muted);">⚪ Boşta (Herhangi bir röleye bağlı değil)</div>';
  } else if (targetType === 0) {
    typeInfo = '<div style="font-size: 12px; color: #60A5FA;">💡 <b>Standart Lamba Butonu</b> (Bas-aç / bas-kapat). 🔌 DGND ile DI arasına bağlanır.</div>';
  } else if (targetType === 3) {
    typeInfo = '<div style="font-size: 12px; color: #F59E0B;">⚡ <b>Darbe / Tetik Butonu</b> (Kapı kilidi). 🔌 DGND ile DI arasına bağlanır.</div>';
  } else {
    typeInfo = '<div style="font-size: 12px; color: #10B981;">🪟 Panjur Kontrolü (Tek Buton Döngü: Aç-Dur-Kapat-Dur).</div>';
  }

  return (
    '<div style="background: #0f172a; padding: 14px; border-radius: 10px; border: 1px solid rgba(255,255,255,0.06); display: flex; flex-direction: column; gap: 8px;">' +
      '<div style="display: flex; justify-content: space-between; align-items: center;">' +
        '<span style="font-weight: 700; font-size: 13.5px; color: #60A5FA;">🔘 DI ' + (diIdx + 1) + ' Girişi</span>' +
        '<span style="font-size: 11px; color: var(--text-muted);">Tekli Buton</span>' +
      '</div>' +
      '<input type="text" id="cfgDIName_' + diIdx + '" value="' + esc(d.name) + '" oninput="onDINameInput(' + diIdx + ', this.value)" placeholder="Giriş Adı">' +
      '<div style="display: flex; align-items: center; gap: 8px;">' +
        '<span style="font-size: 12px; color: var(--text-muted); white-space: nowrap;">Tetikle:</span>' +
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
  try {
    const link = document.querySelector('link[rel="icon"]');
    if (link && $('logoImg')) $('logoImg').src = link.href;   // aynı simge iki kez gömülmesin
  } catch (e) { /* simge isteğe bağlı */ }
  schedulePoll(0);   // yapılandırma, tam durum (anahtar geçerli) alınınca fetchStatus içinde yüklenir
})();
</script>
</body>
</html>
)rawliteral";
