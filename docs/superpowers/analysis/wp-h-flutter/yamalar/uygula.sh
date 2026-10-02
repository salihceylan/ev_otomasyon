#!/usr/bin/env bash
# Gece hatırlatması (WP-H Flutter) yamalarını sırayla uygular.
#
# Kullanım (Windows Git Bash'te):
#   bash uygula.sh [--sadece-kontrol] [HEDEF_KOK]
#     HEDEF_KOK        Flutter projesinin kökü (pubspec.yaml'ın olduğu dizin; yamalar bu köke göredir). Verilmezse bulunduğun dizin.
#     --sadece-kontrol Hiçbir dosyaya yazmaz; yamaların HEPSİNİ hedefte toptan 'git apply --check' ile dener ve özet basar.
#
# Yarım ağaç olmaz: uygulamadan ÖNCE bütün yamalar tek 'git apply --check' çağrısıyla (sırayla, hiçbir şey yazmadan)
# denenir; biri bile uygulanamazsa HİÇBİRİ uygulanmaz. Toptan kontrol geçtikten sonra yamalar sırayla uygulanır.
#
# Betik analyze/test KOMUTLARINI ÇALIŞTIRMAZ; sonunda yalnız yazdırır. Yamaların sırası ve anlamı: README.md.
# Gerçek ağaca uygulamadan önce ORKESTRATÖR ile 'şimdi uygula' penceresini teyit edin.

set -u

KONTROL=0
HEDEF=""
for arg in "$@"; do
  case "$arg" in
    --sadece-kontrol) KONTROL=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) echo "HATA: bilinmeyen seçenek: $arg (bkz. --help)" >&2; exit 2 ;;
    *) HEDEF="$arg" ;;
  esac
done

YAMA_DIZIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEDEF="${HEDEF:-$PWD}"
if [ ! -f "$HEDEF/pubspec.yaml" ]; then
  echo "HATA: '$HEDEF' bir Flutter proje kökü değil (pubspec.yaml yok)." >&2
  exit 2
fi
cd "$HEDEF" || exit 2

# Yamalar depo köküne göredir. 'git apply' bir deponun ALT dizininde kök-göreli yolları hata vermeden ATLAR
# (hiçbir şey uygulamadan başarılı görünür); bu yüzden alt dizinde çalışmayı reddederiz.
ONEK="$(git rev-parse --show-prefix 2>/dev/null || true)"
if [ -n "$ONEK" ]; then
  echo "HATA: '$HEDEF' bir git deposunun alt dizini ('$ONEK'). Yamalar depo köküne göredir ve 'git apply'" >&2
  echo "      alt dizinde kök-göreli yolları sessizce atlar. HEDEF_KOK olarak depo kökünü verin." >&2
  exit 2
fi

if grep -q "firebase_core\|firebase_messaging" pubspec.yaml 2>/dev/null; then
  echo "UYARI: pubspec.yaml'da firebase satırları var. Bu yama seti Firebase'siz tasarlandı (kullanıcı kararı)." >&2
fi

# Satır sonu: yamalar LF'dir; CRLF'li dosyalara (app_shell, automation_state, api_models, pubspec.yaml, ayar kartı)
# --ignore-whitespace ile uygulanır. core.autocrlf=false verilir (aksi halde Windows'ta git, LF'li dosyaları da
# CRLF'e çevirir); eklenen satırlar LF yazıldığı için CRLF'li dosyalar uygulamadan sonra bu betikte yeniden tamamen
# CRLF'e çevrilir. Yeni dosyalar LF olarak yazılır.
YAMALAR=(
  01-yeni-dosyalar.patch
  03-mevcut-dosyalar.patch
  04-app-shell.patch
)
APPLY=(git -c core.autocrlf=false apply --ignore-whitespace)
UYGULANAN=()

DOSYALAR=()
for y in "${YAMALAR[@]}"; do
  if [ ! -f "$YAMA_DIZIN/$y" ]; then
    echo "HATA: yama dosyası yok: $YAMA_DIZIN/$y" >&2
    exit 3
  fi
  DOSYALAR+=("$YAMA_DIZIN/$y")
done

HATA_DOSYASI="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/uygula_hata.$$")"
trap 'rm -f "$HATA_DOSYASI"' EXIT

geri_alma_yaz() {
  if [ "${#UYGULANAN[@]}" -gt 0 ]; then
    echo >&2
    echo "Şu ana kadar uygulananları geri almak için (TERS sırayla), '$HEDEF' içinde:" >&2
    for ((i=${#UYGULANAN[@]}-1; i>=0; i--)); do
      echo "  git -c core.autocrlf=false apply -R --ignore-whitespace '$YAMA_DIZIN/${UYGULANAN[$i]}'" >&2
    done
    echo "(CRLF'li dosyalarda geri alma sonrası satır sonu karışık kalırsa: sed -i 's/\\r\$//; s/\$/\\r/' <dosya>)" >&2
  fi
}

# 1) TOPTAN kontrol: hepsi birden ve sırayla; hiçbir şey yazılmaz.
if "${APPLY[@]}" --check "${DOSYALAR[@]}" 2>"$HATA_DOSYASI"; then
  for y in "${YAMALAR[@]}"; do echo "[tamam]  $y  (toptan kontrol geçti)"; done
else
  echo "[HATA]   toptan kontrol BAŞARISIZ; HİÇBİR dosya değiştirilmedi:" >&2
  sed 's/^/         /' "$HATA_DOSYASI" >&2
  echo >&2
  echo "Tanı (yalnız deneme; hiçbir şey yazılmaz): her yama tek başına" >&2
  for y in "${YAMALAR[@]}"; do
    if "${APPLY[@]}" --check "$YAMA_DIZIN/$y" 2>/dev/null; then
      echo "  [tamam]  $y" >&2
    else
      echo "  [HATA]   $y" >&2
    fi
  done
  echo >&2
  echo "NE YAPMALI: dosya, yama yazıldıktan sonra başka bir ekip tarafından değişmiş olabilir (çakışma)." >&2
  echo "  1) Hangi hunk'ın başarısız olduğunu görmek için: git apply --check -v --ignore-whitespace '<yama>'" >&2
  echo "  2) Hunk'ları tek tek uygulayıp başarısızları .rej dosyasına düşürmek için (yalnız elle birleştirmeye karar verirseniz):" >&2
  echo "       git -c core.autocrlf=false apply --reject --ignore-whitespace '<yama>'" >&2
  echo "     (sonra *.rej dosyalarını elle birleştirin ve silin; CRLF'li dosyayı yeniden CRLF'e çevirin)" >&2
  echo "  3) Özellikle app_shell.dart / automation_state.dart için README.md'deki '3 yönlü birleştirme notları'" >&2
  echo "     bölümüne bakın (eklenen satırlar küçük ve bağımsızdır)." >&2
  echo "  Bu betik burada durdu; HİÇBİR yama uygulanmadı." >&2
  exit 1
fi

if [ "$KONTROL" -eq 1 ]; then
  echo
  echo "Yalnız kontrol: HİÇBİR dosya değiştirilmedi. Üç yama, bu ağaçta toptan ve sırayla uygulanabilir."
  exit 0
fi

# 2) Uygulama: toptan kontrol geçtiği için hepsinin uygulanması beklenir. Yamalar sırayla uygulanır; her biri için
# önce CRLF'li hedef dosyalar belirlenir (Git Bash'te grep CR'yi gizler: 'tr' ile say), uygulamadan sonra bu dosyalar
# yeniden tamamen CRLF'e çevrilir. Beklenmedik bir hatada (disk/izin) uygulananların geri alma komutları yazılır.
for y in "${YAMALAR[@]}"; do
  dosya="$YAMA_DIZIN/$y"
  CRLF_DOSYALAR=()
  while IFS= read -r hedef; do
    if [ -f "$hedef" ] && [ "$(head -c 8192 "$hedef" | tr -d -c '\r' | wc -c)" -gt 0 ]; then
      CRLF_DOSYALAR+=("$hedef")
    fi
  done < <(sed -n 's#^+++ b/##p' "$dosya")
  if "${APPLY[@]}" "$dosya"; then
    for hedef in ${CRLF_DOSYALAR[@]+"${CRLF_DOSYALAR[@]}"}; do
      sed -i 's/\r$//; s/$/\r/' "$hedef"
    done
    UYGULANAN+=("$y")
    echo "[uygulandı] $y"
  else
    echo "[HATA]   $y  toptan kontrol geçmişti ama uygulama başarısız oldu (disk/izin? ağaç bu arada değişti mi?)" >&2
    geri_alma_yaz
    exit 1
  fi
done

# 3) Yamaların hedeflediği her dosya var mı (sessiz atlanma olmasın).
EKSIK=0
for dosya in "${DOSYALAR[@]}"; do
  while IFS= read -r hedef; do
    if [ ! -f "$hedef" ]; then
      echo "UYARI: beklenen dosya yok: $hedef" >&2
      EKSIK=1
    fi
  done < <(sed -n 's#^+++ b/##p' "$dosya")
done
if [ "$EKSIK" -ne 0 ]; then
  echo "[HATA]   yamalar uygulandı ama bazı hedef dosyalar yok; ağacı elle inceleyin." >&2
  geri_alma_yaz
  exit 1
fi

echo
echo "Tüm yamalar uygulandı: ${UYGULANAN[*]}"
echo
echo "Geri almak için (TERS sırayla), '$HEDEF' içinde:"
for ((i=${#UYGULANAN[@]}-1; i>=0; i--)); do
  echo "  git -c core.autocrlf=false apply -R --ignore-whitespace '$YAMA_DIZIN/${UYGULANAN[$i]}'"
done
echo "(geri alma sonrası CRLF'li dosyalarda satır sonu karışık kalırsa: sed -i 's/\\r\$//; s/\$/\\r/' <dosya>)"
cat <<'SON'

SIRADAKİ ADIMLAR (bu betik bunları ÇALIŞTIRMAZ; elle, aynı anda tek flutter komutu):
  1) Bağımlılık kilidi (yalnız fake_async transitive -> direct dev değişir):
       flutter pub get
  2) Analiz (0 sorun beklenir):
       flutter analyze
  3) Hedefli testler (gece hatırlatması seti):
       flutter test test/push test/services/peace_notice_controller_test.dart test/services/peace_v2_models_and_api_test.dart test/services/push_token_api_adapter_test.dart test/services/automation_state_logout_hook_test.dart test/ui/peace_notice_host_test.dart test/ui/peace_reminder_details_test.dart test/ui/push_status_tile_test.dart test/ui/peace_card_integration_test.dart test/child_lock_and_night_notification_test.dart
  4) Tam test (taban +1903 ~8; LIVE kopyasında ölçülen entegre sonuç +2493 ~8; gerçek ağaçta sayı başka ekiplerin testleriyle değişebilir, hiçbir test kırılmamalı):
       flutter test
  5) Derleme ve cihazda deneme (Android/iOS dosyalarına dokunulmadı; deneme kullanıcıda/orkestratördedir):
       flutter build apk --debug
SON
