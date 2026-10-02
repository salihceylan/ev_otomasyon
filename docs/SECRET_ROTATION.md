# Sır Döndürme Rehberi (değer içermez)

Denetimde aşağıdaki sırların **repoda, istemci uygulamada veya yapılandırma dosyalarında açıkta** olduğu görüldü. Bu sırlar
"ifşa olmuş" kabul edilir: kodu düzeltmek yetmez, **değerleri değiştirmek (rotate)** gerekir. Bu belge hangi sırrın nerede
olduğunu, değişince neyin etkileneceğini ve uygulama sırasını verir. Hiçbir sır değeri bu belgede yoktur.

> Önemli: Sunucu SSH parolası da repoda başka bir amaçla (yönetici API anahtarı / süper kullanıcı parolası olarak) göründüğü
> için aynı değerin başka yerlerde de geçerli olup olmadığı kontrol edilmeli ve **hepsi** değiştirilmelidir.

## Uygulama sırası

| # | Sır | Nerede açığa çıktı | Değişince etkisi | Nasıl |
|---|---|---|---|---|
| 1 | **Sunucu SSH parolası** (`gudeteknoloji` kullanıcısı) | Sohbet/dokümantasyon + repoda aynı değerin başka rolde bulunması | Yalnızca yöneticiler | Sunucuda `passwd`; ardından **anahtar tabanlı girişe geç**, `PasswordAuthentication no`, `fail2ban` kontrolü |
| 2 | **Süper kullanıcı hesap parolaları** | `migrations/002`, `014`, seed betikleri, `EVOTOMASYON_TASKS.md`, test kontrol listesi | O hesaplarla giriş | Uygulamadan/admin panelinden yeni parola; eski seed dosyaları `dev_seeds/`'e taşındı ve üretimde çalıştırılmaz |
| 3 | **PostgreSQL parolası** (`ev_admin`) | `docker-compose.yml`, `migrations/run_*.js`, `.env` | API, EMQX (authn), migration betikleri | Yeni parola → `.env` → `docker compose up -d` (yalnızca ev otomasyonu yığını) → API yeniden başlat. **Uygulama için en az yetkili ayrı DB rolü** kullan (`scripts/create_db_roles.sql`) |
| 4 | **`JWT_SECRET`** | `server/.env` (git'te takipliydi), tahmin edilebilir kalıp | **Tüm kullanıcılar çıkış yapar** (beklenen) | ≥ 32 bayt rastgele (`openssl rand -hex 32`); `.env`'i git'ten çıkar |
| 5 | **`PIN_PEPPER`, `LOCAL_KEY_SECRET`** (yeni) | — | `PIN_PEPPER` değişirse tüm kurulum PIN özetleri geçersiz olur → **ilk kez üretirken seç, sonra değiştirme** (eski özetler için geçiş fonksiyonu var) | `openssl rand -hex 32` |
| 6 | **MQTT `backend_service` parolası** | `init_mqtt_users.sql`, `emqx_config/*`, `.env` | Köprü bağlantısı | Yeni parola → `scripts/create_backend_mqtt_user.js` → `.env` → API yeniden başlat |
| 7 | **Paylaşılan eski MQTT kimlikleri** (`home_*` sabit parola) | APK içinde, firmware içinde, repoda | Eski firmware'li panolar bağlanamaz | **Panolar yeniden flash + provizyon edildikten SONRA** legacy authenticator kapatılır (`DEPLOY_RUNBOOK.md`) |
| 8 | **Yönetici API anahtarı** (APK'ya gömülüydü) | `lib/services/ev_cloud_api_service.dart` (artık silindi), `admin_api_key_middleware.js` (varsayılan değer silindi) | Fabrika aracı | Yeni `ADMIN_API_KEY` (isteğe bağlı, ≥ 32) veya yalnızca JWT girişi; **eski değer APK'larda kalacağı için sunucuda kesinlikle reddedilir** |
| 9 | **EMQX dashboard yönetici parolası** | `docker-compose.yml` / varsayılan | Dashboard girişi | İlk girişte değiştir; port yalnızca `127.0.0.1` |
| 10 | **Redis parolası** | `docker-compose.yml` | Redis kullanılmıyordu, servis kaldırıldı | — |
| 11 | **SMTP kimlik bilgileri** | `server/.env` (içerik denetlenemedi) | E-posta/OTP gönderimi | Sağlayıcıda yenile |
| 12 | **Cihaz kurulum PIN'leri** (stoktaki cihazlar) | Tuzsuz SHA-256 özetleri (sızarsa 6 haneli uzay anında kırılır) | Etiketler | Kritik değil ama dağıtımda yeni HMAC'e yükseltilir; sızıntı şüphesinde etiketler yeniden basılır |

## Git geçmişi

- `server/.env` iki commit'te (`16b1b6f`, `fb8f0f7`) geçmişte. Kod tarafında `.env` takipten çıkarıldı (dosya diskte kalır) ve `.gitignore`'a eklendi.
- Denetimde `git remote` tanımlı değildi (yalnızca yerel). **Uzak depoya push edilmediyse** sırlar yalnızca bu makinede ve yedeklerde.
  Push edilmişse veya yedek/paylaşım varsa geçmiş `git filter-repo` ile temizlenmeli **ve yine de sırlar döndürülmeli** (temizlik geri alınamaz sızıntıyı geri almaz).
- Geçmiş yeniden yazımı yıkıcıdır; **kullanıcı onayı olmadan yapılmadı**.

## Doğrulama (döndürme sonrası)

```bash
# Repoda artık sır kalmadığını kontrol et (kalıplar; değerleri çıktıya basma)
git grep -n -i -E "password\s*[:=]\s*['\"][^'\"]{6,}" -- ':!docs' ':!*.md' | head
git ls-files | grep -E '(^|/)\.env($|\.)' | grep -v example   # boş olmalı
```
