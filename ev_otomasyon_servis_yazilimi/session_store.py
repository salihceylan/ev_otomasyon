# -*- coding: utf-8 -*-
"""
Hatırlanan oturum ("Beni hatırla") - AHBU servis/üretim aracı.

Kullanıcı kararı (2026-10-04, açık onay): "bir kere girince artık otomatik girsin". Kapsam SINIRLIDIR:

* Kimlik (sunucu adresi + e-posta; gizli DEĞİL) kullanıcı ayar JSON'una yazılır (``tool_theme.preferences_path()`` ile
  aynı dosya: %APPDATA%/AHBU/servis_araci_ayarlar.json) ve bir sonraki açılışta giriş penceresi ön dolu gelir.
* REFRESH TOKEN Windows DPAPI ile (CryptProtectData, kullanıcı kapsamı: yalnızca aynı Windows hesabı çözebilir)
  şifrelenip ``%APPDATA%/AHBU/factory_session.dat`` dosyasına yazılır. DPAPI yoksa (Windows dışı) ya da şifreleme
  başarısızsa token YAZILMAZ; yalnızca kimlik hatırlanır. Yeni bağımlılık yoktur (ctypes).
* PAROLA ASLA saklanmaz. Dosya bozuksa / başka kullanıcıya aitse / sürüm uyumsuzsa ``load()`` None döndürür.
* Sunucu refresh token'ı TEK KULLANIMLIK döndürür (rotasyon): yeni token her yenilemede ANINDA depoya yazılır; yazılamazsa
  eski token dosyası da silinir (kapalı-hata: bayat token ile "yeniden kullanım" alarmı tetiklenmesin).
* Token yalnızca ŞİFRELİ YÜKTE kayıtlı sunucu adresine gönderilir; adres uyuşmazsa sessiz giriş yapılmaz.
* Ortak bilgisayarda "Oturumu Kapat" kayıtlı tokeni siler ve sunucuda iptal eder; "Beni hatırla" işaretsiz giriş de siler.
  Pencere kapanışında hatırlanan oturum sunucuda iptal EDİLMEZ (aksi hâlde özellik anlamsız olur); hatırlanmayan oturum
  eskisi gibi iptal edilir.

Bu modül Tk kullanmaz; ağ çağrısını yalnızca ``SessionKeeper.try_restore`` içinde (arka plan iş parçacığında) yapar.
Tüm depo işlemleri kilitlidir.
"""

from __future__ import annotations

import ctypes
import json
import os
import threading
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

from factory_client import ApiError, FactoryError, SessionExpiredError, normalize_server_url
from tool_theme import preferences_path, read_preferences, update_preferences

SESSION_FILE_NAME = "factory_session.dat"
FORMAT_VERSION = 1
# DPAPI isteğe bağlı entropi: gizli değildir; yalnızca blob'u bu uygulamaya bağlar (başka programın blob'u çözülmez).
_ENTROPY = "AHBU servis araci oturum deposu v1".encode("utf-8")
_CRYPTPROTECT_UI_FORBIDDEN = 0x01
PREF_SERVER_URL = "server_url"
PREF_EMAIL = "email"

Protector = Callable[[bytes], bytes]

# try_restore sonuçları
RESTORED = "restored"      # sessiz giriş başarılı
NONE = "none"              # kayıtlı oturum yok
EXPIRED = "expired"        # sunucu token'ı reddetti (kayıt silindi)
FORBIDDEN = "forbidden"    # hesap artık süper kullanıcı değil (kayıt silindi, oturum iptal edildi)
NETWORK = "network"        # ağ/sunucu hatası (kayıt KORUNDU, sonra yeniden denenir)
MISMATCH = "mismatch"      # kayıtlı token başka sunucuya ait (gönderilmedi, kayıt korundu)


def session_file_path() -> str:
    """Token dosyasının yolu: ayar dosyasıyla aynı dizinde (%APPDATA%/AHBU ya da ~/.config/ahbu)."""
    return os.path.join(os.path.dirname(preferences_path()), SESSION_FILE_NAME)


# ---------------------------------------------------------------------------------------------------------------
# DPAPI (yalnızca Windows; ctypes ile, ek paket yok)
# ---------------------------------------------------------------------------------------------------------------
class _DataBlob(ctypes.Structure):
    _fields_ = [("cbData", ctypes.c_uint32), ("pbData", ctypes.POINTER(ctypes.c_char))]


def _blob(data: bytes) -> _DataBlob:
    buffer = ctypes.create_string_buffer(data, len(data))
    blob = _DataBlob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_char)))
    blob._buffer = buffer  # type: ignore[attr-defined]  # tampon blob yaşadığı sürece canlı kalsın
    return blob


def dpapi_available() -> bool:
    return os.name == "nt" and hasattr(ctypes, "WinDLL")


def _dpapi(protect: bool, data: bytes) -> bytes:
    if not dpapi_available():
        raise OSError("DPAPI yalnızca Windows'ta kullanılabilir.")
    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)  # type: ignore[attr-defined]
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)  # type: ignore[attr-defined]
    source = _blob(data)
    entropy = _blob(_ENTROPY)
    out = _DataBlob()
    if protect:
        ok = crypt32.CryptProtectData(
            ctypes.byref(source), "AHBU servis araci", ctypes.byref(entropy), None, None, _CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(out)
        )
    else:
        ok = crypt32.CryptUnprotectData(
            ctypes.byref(source), None, ctypes.byref(entropy), None, None, _CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(out)
        )
    if not ok:
        raise OSError(f"DPAPI hatası (kod {ctypes.get_last_error()})")
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        kernel32.LocalFree(out.pbData)


def dpapi_protect(data: bytes) -> bytes:
    """Veriyi geçerli Windows kullanıcısına bağlı olarak şifreler (başka kullanıcı/bilgisayar çözemez)."""
    return _dpapi(True, data)


def dpapi_unprotect(data: bytes) -> bytes:
    return _dpapi(False, data)


# ---------------------------------------------------------------------------------------------------------------
# Depo
# ---------------------------------------------------------------------------------------------------------------
@dataclass
class StoredSession:
    server_url: str
    email: str
    refresh_token: str = field(repr=False)  # repr/log'a sızmasın

    def __repr__(self) -> str:
        return f"StoredSession(server_url={self.server_url!r}, email={self.email!r}, <token gizli>)"


class SessionStore:
    """Kimlik (ayar JSON) + şifreli refresh token (DPAPI dosyası).

    ``protect``/``unprotect`` enjekte edilebilir (testler sahte şifreleyici verir); varsayılan DPAPI'dir.
    Hiçbir yöntem istisna sızdırmaz: disk/şifreleme sorunu "hatırlama yok" anlamına gelir."""

    def __init__(
        self,
        path: Optional[str] = None,
        prefs_path: Optional[str] = None,
        *,
        protect: Optional[Protector] = None,
        unprotect: Optional[Protector] = None,
    ) -> None:
        self.path = path or session_file_path()
        self.prefs_path = prefs_path or preferences_path()
        self._protect = protect if protect is not None else (dpapi_protect if dpapi_available() else None)
        self._unprotect = unprotect if unprotect is not None else (dpapi_unprotect if dpapi_available() else None)
        self._lock = threading.RLock()

    @property
    def can_store_token(self) -> bool:
        return self._protect is not None and self._unprotect is not None

    # ---- kimlik (gizli değil) ---------------------------------------------------------------------------------
    def identity(self) -> tuple[str, str]:
        """Hatırlanan (sunucu adresi, e-posta); yoksa boş dizeler."""
        data = read_preferences(self.prefs_path)
        url, email = data.get(PREF_SERVER_URL), data.get(PREF_EMAIL)
        return (url if isinstance(url, str) else "", email if isinstance(email, str) else "")

    def remember_identity(self, server_url: str, email: str) -> bool:
        return update_preferences({PREF_SERVER_URL: str(server_url or ""), PREF_EMAIL: str(email or "")}, path=self.prefs_path)

    def forget_identity(self) -> None:
        update_preferences(remove=(PREF_SERVER_URL, PREF_EMAIL), path=self.prefs_path)

    # ---- token (şifreli dosya) --------------------------------------------------------------------------------
    def has_token(self) -> bool:
        return os.path.isfile(self.path)

    def save(self, server_url: str, email: str, refresh_token: str) -> bool:
        """Kimliği ayar dosyasına, refresh tokeni şifreli dosyaya yazar. Token yazılamazsa False (kimlik yine hatırlanır)."""
        with self._lock:
            self.remember_identity(server_url, email)
            if not refresh_token or not self.can_store_token:
                return False
            payload = json.dumps(
                {"v": FORMAT_VERSION, "server_url": server_url, "email": email, "refresh_token": refresh_token},
                ensure_ascii=False,
            ).encode("utf-8")
            try:
                blob = self._protect(payload)  # type: ignore[misc]
            except (OSError, ValueError, ctypes.ArgumentError):
                return False
            try:
                os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
                tmp_path = self.path + ".tmp"
                with open(tmp_path, "wb") as handle:
                    handle.write(blob)
                os.replace(tmp_path, self.path)
                return True
            except OSError:
                return False

    def load(self) -> Optional[StoredSession]:
        """Kayıtlı oturum; dosya yoksa/bozuksa/başka kullanıcıya aitse/çözülemezse None (istisna sızmaz)."""
        with self._lock:
            if not self.can_store_token:
                return None
            try:
                with open(self.path, "rb") as handle:
                    blob = handle.read()
            except OSError:
                return None
            try:
                raw = self._unprotect(blob)  # type: ignore[misc]
                data = json.loads(raw.decode("utf-8"))
            except (OSError, ValueError, UnicodeDecodeError, ctypes.ArgumentError):
                return None
            if not isinstance(data, dict) or data.get("v") != FORMAT_VERSION:
                return None
            url, email, token = data.get("server_url"), data.get("email"), data.get("refresh_token")
            if not (isinstance(url, str) and isinstance(email, str) and isinstance(token, str) and token):
                return None
            return StoredSession(url, email, token)

    def clear_token(self) -> None:
        """Şifreli token dosyasını (ve yarım kalmış geçici dosyayı) siler; kimlik kalır."""
        with self._lock:
            for candidate in (self.path, self.path + ".tmp"):
                try:
                    os.remove(candidate)
                except OSError:
                    pass

    def clear(self) -> None:
        """Token + kimlik: hiçbir iz kalmaz (ortak bilgisayar: 'Oturumu Kapat')."""
        with self._lock:
            self.clear_token()
            self.forget_identity()


# ---------------------------------------------------------------------------------------------------------------
# Koordinatör: istemci <-> depo (Tk'siz, GUI'den bağımsız test edilir)
# ---------------------------------------------------------------------------------------------------------------
class SessionKeeper:
    """``ServerClient`` oturumunu depoyla eşler: hatırlama, sessiz geri yükleme, rotasyon yazımı, unutma."""

    def __init__(self, client: Any, store: SessionStore) -> None:
        self._client = client
        self._store = store
        self._lock = threading.RLock()
        self._remembered = False
        self._email = ""

    @property
    def remembered(self) -> bool:
        return self._remembered

    def remember(self, email: str) -> bool:
        """Başarılı girişten sonra: kimlik + şifreli refresh token yazılır, rotasyon kancası bağlanır.
        Token yazılamazsa (DPAPI yok/hata) yalnız kimlik hatırlanır ve False döner (oturum bu çalıştırmada yine açık)."""
        token = self._client.current_refresh_token()
        with self._lock:
            if not token:
                return False
            if self._store.save(self._client.base_url, email, token):
                self._remembered = True
                self._email = email
                self._client.session_listener = self._on_rotation
                return True
            self._remembered = False
            self._client.session_listener = None
            return False

    def forget(self) -> None:
        """Token + kimlik silinir, kanca çözülür ('Oturumu Kapat', 'Beni hatırla' işaretsiz giriş)."""
        with self._lock:
            self._remembered = False
            self._email = ""
            self._client.session_listener = None
            self._store.clear()

    def _on_rotation(self, new_refresh: str) -> None:
        with self._lock:
            if not self._remembered:
                return
            if not self._store.save(self._client.base_url, self._email, new_refresh):
                # Yeni token yazılamadı: eski token sunucuda kullanılmış sayıldı; dosyada bırakmak bir sonraki açılışta
                # "yeniden kullanım" alarmı (oturum ailesi iptali) üretir. Kapalı-hata: sil.
                self._store.clear_token()
                self._remembered = False
                self._client.session_listener = None

    def try_restore(self) -> tuple[str, str]:
        """Kayıtlı oturumla sessiz giriş (ARKA PLAN iş parçacığında çağrılır; ağ kullanır). (sonuç, e-posta) döner."""
        stored = self._store.load()
        if stored is None:
            return NONE, ""
        try:
            same_server = normalize_server_url(stored.server_url) == normalize_server_url(self._client.base_url)
        except ValueError:
            same_server = False
        if not same_server:
            return MISMATCH, stored.email  # token başka sunucu içindir: GÖNDERİLMEZ
        # Rotasyon kancası İSTEKTEN ÖNCE bağlanır: sunucu refresh token'ı yeniledikten sonra (ör. ardından /auth/me ağ
        # hatası verse bile) yeni token depoya yazılmış olmalı; eski token artık "kullanılmış" sayılır.
        with self._lock:
            self._remembered = True
            self._email = stored.email
            self._client.session_listener = self._on_rotation
        try:
            user = self._client.restore_session(stored.refresh_token)
        except SessionExpiredError:
            self._drop_remembered_token()
            return EXPIRED, stored.email
        except ApiError as exc:
            if exc.status == 403:  # yetkisiz hesap: oturum zaten iptal edildi; kayıt silinir
                self._drop_remembered_token()
                return FORBIDDEN, stored.email
            return NETWORK, stored.email
        except FactoryError:
            return NETWORK, stored.email
        email = str(user.get("email") or stored.email)
        with self._lock:
            self._email = email
        return RESTORED, email

    def _drop_remembered_token(self) -> None:
        """Sunucu token'ı reddetti: şifreli dosya silinir, kanca çözülür (kimlik/e-posta ön doldurma için kalır)."""
        with self._lock:
            self._remembered = False
            self._client.session_listener = None
            self._store.clear_token()
