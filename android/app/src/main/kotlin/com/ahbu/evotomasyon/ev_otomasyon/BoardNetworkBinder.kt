package com.ahbu.evotomasyon.ev_otomasyon

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.net.Inet4Address

/*
 * WP-NET-K: pano kurulum ağına (SoftAP) süreç bağlama — ANDROID YAPIŞTIRICISI.
 *
 * SORUN
 *   Pano kurulum/kurtarma ağı (WPA2 SoftAP, AHBU-<MAC son 6>, 192.168.4.1) İNTERNETSİZDİR. Android bu Wi-Fi
 *   ağını "doğrulanmamış" (NOT VALIDATED) sayar ve MOBİL VERİ AÇIKSA uygulamaların VARSAYILAN ağını hücresele
 *   çevirir: uygulamanın 192.168.4.1'e attığı HTTP istekleri hücreselden çıkar ve başarısız olur.
 *
 * ÇÖZÜM
 *   Yalnız pano kurulum ağıyla konuşulan SÜRELERDE uygulama SÜRECİNİ Wi-Fi ağına bağlamak:
 *   ConnectivityManager.requestNetwork (yalnız Wi-Fi taşıyıcısı) + bindProcessToNetwork; iş bitince
 *   (ya da ağ kaybolunca) çözmek. Akış, durum makinesi ve her sonucun TAM BİR KEZ iletilmesi
 *   BoardNetworkCore.kt'dedir (platformdan bağımsız, JVM birim testli); bu dosya yalnız Android
 *   sınıflarına ince bağdır. Kanal sözleşmesi ve çağrılar: BoardNetworkPlugin.kt.
 *
 * TASARIM NOTLARI
 *   1) Neden SÜREÇ-GENELİ bağlama? Dart'ın dart:io soketleri yerel `socket()` çağrılarıyla (Dart VM'in
 *      kendi katmanı) oluşur; tek tek bir android.net.Network'e bağlanamazlar (Network.getSocketFactory()
 *      yalnız Java soketlerini kapsar). bindProcessToNetwork ise bu süreçte SONRADAN oluşan tüm soketleri
 *      (yerel kod dahil) ve ad çözümlemelerini o ağa yönlendirir. Başka yol yoktur.
 *   2) Bağlama sürerken buluta/MQTT'ye YENİ bağlantılar da AYNI (internetsiz) ağdan gider ve başarısız olur
 *      (REST, MQTT yeniden bağlanma, oturum yenileme...). Bu yüzden bağlama KISA tutulmalıdır: Dart tarafı
 *      kiralama (lease) ile yönetir, iş biter bitmez `release` çağırır (varsayılan: bekleme/linger YOK; bırakma
 *      Dart'ta bu çağrının yanıtından sonra tamamlanır, yani çağrı dönünce süreç artık bağlı değildir).
 *   3) MEVCUT AÇIK soketler etkilenmez: bağlama yalnız bağlamadan SONRA oluşturulan soketleri/çözümlemeleri
 *      yönlendirir (örn. zaten açık MQTT TCP bağlantısı hücreselden sürer; kopup yeniden kurulursa
 *      bağlıyken kurulan yeni bağlantı Wi-Fi'ye gider).
 *   4) Android 10+ WifiNetworkSpecifier ile PROGRAMATİK olarak panonun ağına bağlanmak bu işin KAPSAMI
 *      DIŞIDIR: kullanıcı telefonu ağa (etiketteki 2. karekod/elle) kendisi bağlar; biz yalnız ZATEN bağlı
 *      olan Wi-Fi ağına süreci bağlarız. (Bağlı değilse `no_wifi`/`not_on_board_network` döner.)
 *   5) "Pano ağı mı?" kararı ağın bağlantı adreslerindendir (LinkProperties.linkAddresses içinde alt ağa
 *      düşen IPv4): SSID okunmaz (konum izni gerekir) ve SSID/IP/parola günlüğe YAZILMAZ.
 *   6) ağ isteği INTERNET/VALIDATED yeteneği İSTEMEZ (internetsiz Wi-Fi eşleşmelidir). Kayıt, bağlama
 *      sürerken AÇIK kalır: ağı "istenen" tutar (Android internetsiz Wi-Fi'yi sessizce bırakmasın) ve
 *      onLost için gereklidir. DİKKAT: requestNetwork geri çağrısı yalnız o anki "en iyi" ağı izler
 *      (NetworkCallback.onAvailable/onLost belgesi): istek daha iyi bir Wi-Fi'ye geçerse (ör. otomatik ağ geçişi,
 *      STA+STA) bağlı ağın onLost'u HİÇ gelmez. Bu yüzden bağlıyken ek bir registerNetworkCallback (yalnız Wi-Fi,
 *      yalnız onLost; ACCESS_NETWORK_STATE yeter) bağlı ağın kaybını izler (watchWifiLoss).
 *   7) İŞ PARÇACIĞI: tüm durum ana iş parçacığındadır. API 24-25'te geri çağrılar ConnectivityManager'ın kendi
 *      iş parçacığından gelir; çekirdek hepsini ana iş parçacığına taşır. API 26+'da ana Handler verilir.
 *   8) Kullanımdan kalkmış API YOK: allNetworks/getNetworkInfo/getActiveNetworkInfo kullanılmaz; ağ
 *      bulma yalnız requestNetwork/NetworkCallback ile yapılır. Süreç bağlama (API 23+) minSdk 24'te güvenli.
 *   9) SONUÇ EŞLEMESİ (`acquire` -> status[/detail]):
 *        bound                : adresleri alt ağda olan Wi-Fi ağına bağlandı.
 *        already_bound        : zaten bağlıydı ve ağ hâlâ geçerli.
 *        not_on_board_network : Wi-Fi görüldü ama ~3 sn (GRACE) içinde alt ağa uyan IPv4 adresi yok
 *                               (detail: other_subnet | no_ipv4_address | bind_returned_false).
 *        no_wifi              : cihazda Wi-Fi donanımı yok YA DA timeoutMs içinde hiçbir Wi-Fi ağı bağlanmadı
 *                               (onUnavailable / elle zaman aşımı). Sözleşmedeki "timeout" yerel taraftan
 *                               ÜRETİLMEZ (gerekçe: BoardNetworkCore.noWifiNetwork).
 *        permission_denied    : CHANGE_NETWORK_STATE yok / SecurityException.
 *        error / bind_denied  : alt ağa uyan Wi-Fi ağı CANLI ama bindProcessToNetwork false döndü = işletim sistemi
 *                               süreç bağlamasını REDDETTİ (AOSP netd: UID'ye atlanamaz bir VPN uygulanıyorsa EPERM;
 *                               VpnService.Builder.allowBypass() çağırmayan her VPN uygulaması dahil). Beklenmez,
 *                               hemen döner; Dart ipucu: "VPN açıksa kapatıp yeniden deneyin".
 *        unsupported | error  : ConnectivityManager yok / beklenmeyen RuntimeException (kısa detail).
 *      Başarısız her durumda süreç varsayılan ağı DEĞİŞMEZ ve ağ isteği kaydı BIRAKILIR (sızıntı yok).
 *
 * !!! CİHAZDA DOĞRULANMADI !!!
 *   Bu kod gerçek bir Android cihazda/emülatörde ÇALIŞTIRILMADI (kullanıcı kararı: deneme sahada kullanıcı
 *   tarafından yapılacak). Doğrulanan: Kotlin derlemesi, saf mantığın (Ipv4Subnet + BoardNetworkCore, sahte
 *   platform + sanal zaman) JVM birim testleri. Doğrulanmayanlar: gerçek ConnectivityService davranışı
 *   (internetsiz Wi-Fi'nin requestNetwork ile eşleşmesi, geri çağrı sırası), OEM davranışları (Samsung/Xiaomi/
 *   Huawei "akıllı ağ geçişi", internetsiz Wi-Fi'yi otomatik bırakma), Android 14+ kısıtları, çoklu Wi-Fi
 *   (STA+STA) cihazlar, ağ geçişinde (istek başka Wi-Fi'ye geçince) bağlı ağın kaybının ek kayıp izleyicisiyle
 *   duyulması, VPN etkinken bağlamanın reddedilmesi (bind_denied) ve Dart soketlerinin bağlamayı gerçekten izlediği.
 *   Herhangi bir atlanamaz VPN etkinken süreç bağlaması REDDEDİLİR (yalnız "her zaman açık + kilitli VPN" değil).
 */

/** Dart tarafına bakan, Android'e özgü yüz: [BoardNetworkCore]'u gerçek ConnectivityManager'a bağlar. */
internal class BoardNetworkBinder(context: Context, onNetworkLost: () -> Unit) {
    private val core: BoardNetworkCore<Network>

    init {
        // Etkinliği SIZDIRMA: yalnız uygulama bağlamı tutulur.
        val appContext = context.applicationContext ?: context
        val mainHandler = Handler(Looper.getMainLooper())
        core = BoardNetworkCore(
            platform = AndroidBoardNetworkPlatform(appContext, mainHandler),
            scheduler = HandlerScheduler(mainHandler),
            log = { message -> Log.i(TAG, message) },
            onNetworkLost = onNetworkLost,
        )
    }

    /** Ana iş parçacığında çağrılır; [onResult] TAM BİR KEZ çağrılır. Bkz. [BoardNetworkCore.acquire]. */
    fun acquire(subnet: Ipv4Subnet, timeoutMs: Long, onResult: (AcquireResult) -> Unit) {
        warnIfNotMainThread("acquire")
        core.acquire(subnet, timeoutMs, onResult)
    }

    /** Her zaman güvenli ve idempotent. Bkz. [BoardNetworkCore.release]. */
    fun release(): ReleaseOutcome {
        warnIfNotMainThread("release")
        return core.release()
    }

    fun isBound(): Boolean = core.isBound()

    private fun warnIfNotMainThread(operation: String) {
        // Çekirdek iş parçacığı güvenli DEĞİLDİR (yalnız ana iş parçacığı). Çökertmeyiz, yalnız uyarırız.
        if (Looper.myLooper() !== Looper.getMainLooper()) {
            Log.w(TAG, "$operation ana iş parçacığı dışından çağrıldı")
        }
    }
}

/** [BoardNetworkPlatform]'un ConnectivityManager gerçeklemesi. */
private class AndroidBoardNetworkPlatform(
    private val context: Context,
    private val mainHandler: Handler,
) : BoardNetworkPlatform<Network> {

    private val connectivityManager: ConnectivityManager? =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    // requestNetwork(request, callback, handler, timeoutMs) API 26 (O) ile geldi.
    override val hasNativeRequestTimeout: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O

    // bindProcessToNetwork / getBoundNetworkForProcess API 23 (M); minSdk 24 olsa da savunma amaçlı denetlenir.
    override fun isSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && connectivityManager != null

    // İzin gerektirmez: PackageManager özelliği.
    override fun hasWifiHardware(): Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI)

    // Normal izin: manifestte bildirilmişse kurulumda verilir (çalışma zamanı isteği YOK).
    override fun hasChangeNetworkStatePermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.CHANGE_NETWORK_STATE) ==
            PackageManager.PERMISSION_GRANTED

    override fun requestWifiNetwork(
        timeoutMs: Int,
        listener: BoardNetworkListener<Network>,
    ): NetworkRegistration {
        val cm = connectivityManager ?: throw IllegalStateException("ConnectivityManager yok")

        // Yalnız Wi-Fi taşıyıcısı. INTERNET/VALIDATED yeteneği İSTENMEZ: internetsiz Wi-Fi eşleşmelidir.
        // (NetworkRequest.Builder varsayılanı NOT_RESTRICTED + TRUSTED + NOT_VPN'dir; INTERNET içermez.)
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        val callback = ForwardingCallback(listener)

        // Fırlatırsa (SecurityException, TooManyRequestsException...) kayıt OLUŞMAMIŞTIR; çekirdek ele alır.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // API 26+: işletim sistemi zaman aşımı (onUnavailable) + geri çağrılar ana Handler'da.
            cm.requestNetwork(request, callback, mainHandler, timeoutMs)
        } else {
            // API 24-25: zaman aşımı seçeneği yok; çekirdeğin bekçisi (Handler.postDelayed) uygular.
            cm.requestNetwork(request, callback)
        }

        return NetworkRegistration {
            try {
                cm.unregisterNetworkCallback(callback)
            } catch (e: IllegalArgumentException) {
                // onUnavailable'dan sonra istek işletim sistemince zaten bırakılmıştır
                // ("NetworkCallback was already unregistered"): beklenen durum, sızıntı DEĞİL.
                Log.d(TAG, "ağ isteği kaydı zaten kaldırılmış")
            }
        }
    }

    override fun watchWifiLoss(onLost: (Network) -> Unit): NetworkRegistration {
        val cm = connectivityManager ?: throw IllegalStateException("ConnectivityManager yok")

        // Dinleme kaydı (requestNetwork DEĞİL): her eşleşen Wi-Fi ağının onLost'u gelir, "en iyi ağ" ayrımı yoktur.
        // Ağı canlı tutmaz ve sistemde hiçbir ağ talebi oluşturmaz. ACCESS_NETWORK_STATE yeter (manifestte var).
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        val callback = LossOnlyCallback(onLost)

        // Fırlatırsa (SecurityException, TooManyRequestsException...) kayıt OLUŞMAMIŞTIR; çekirdek ele alır.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            cm.registerNetworkCallback(request, callback, mainHandler) // 3 argümanlı sürüm API 26
        } else {
            cm.registerNetworkCallback(request, callback) // geri çağrılar kendi iş parçacığından; çekirdek taşır
        }

        return NetworkRegistration {
            try {
                cm.unregisterNetworkCallback(callback)
            } catch (e: IllegalArgumentException) {
                Log.d(TAG, "kayıp izleyicisi zaten kaldırılmış")
            }
        }
    }

    override fun bindProcessTo(network: Network?): Boolean =
        connectivityManager?.bindProcessToNetwork(network) ?: false

    override fun processBoundNetwork(): Network? = connectivityManager?.boundNetworkForProcess

    override fun ipv4Addresses(network: Network): List<ByteArray>? {
        // Ağ koptuysa getLinkProperties null döner. NOT: kullanımdan kalkmış getNetworkInfo vb. kullanılmaz.
        val properties = connectivityManager?.getLinkProperties(network) ?: return null
        return ipv4AddressesOf(properties)
    }
}

/**
 * ConnectivityManager geri çağrılarını (herhangi bir iş parçacığında) çekirdeğin dinleyicisine iletir.
 * Burada DURUM TUTULMAZ ve hiçbir iş yapılmaz; taşıma/denetim çekirdektedir.
 */
private class ForwardingCallback(
    private val listener: BoardNetworkListener<Network>,
) : ConnectivityManager.NetworkCallback() {

    override fun onAvailable(network: Network) {
        listener.onAvailable(network)
    }

    // DHCP adresi onAvailable'dan SONRA gelebilir: adresler burada da (yeniden) değerlendirilir.
    override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
        listener.onLinkAddresses(network, ipv4AddressesOf(linkProperties))
    }

    override fun onLost(network: Network) {
        listener.onLost(network)
    }

    // API 26+: zaman aşımı ya da istek karşılanamıyor. (API 24-25'te çağrılmaz; çekirdeğin bekçisi vardır.)
    override fun onUnavailable() {
        listener.onUnavailable()
    }
}

/** Yalnız `onLost` ilgilendirir (bağlı ağın kaybı); diğer olaylar bilerek yok sayılır. Durum tutmaz. */
private class LossOnlyCallback(
    private val listener: (Network) -> Unit,
) : ConnectivityManager.NetworkCallback() {
    override fun onLost(network: Network) {
        listener(network)
    }
}

/** Ana iş parçacığı kuyruğu üzerinde [BoardNetworkScheduler]. */
private class HandlerScheduler(private val handler: Handler) : BoardNetworkScheduler {
    override fun post(task: Runnable) {
        handler.post(task)
    }

    override fun postDelayed(task: Runnable, delayMs: Long) {
        handler.postDelayed(task, delayMs)
    }

    override fun cancel(task: Runnable) {
        handler.removeCallbacks(task)
    }
}

/** Bağlantı adreslerinin yalnız IPv4 olanları (4 bayt). IPv6 adresleri alt ağ denetimine girmez. */
private fun ipv4AddressesOf(properties: LinkProperties): List<ByteArray> =
    properties.linkAddresses.mapNotNull { (it.address as? Inet4Address)?.address }

private const val TAG = "BoardNetwork"
