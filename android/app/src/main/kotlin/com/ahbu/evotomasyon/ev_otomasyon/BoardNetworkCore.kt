package com.ahbu.evotomasyon.ev_otomasyon

/*
 * WP-NET-K: pano kurulum ağına (SoftAP) süreç bağlama — PLATFORMDAN BAĞIMSIZ ÇEKİRDEK.
 *
 * Tasarım notlarının tamamı BoardNetworkBinder.kt dosya başlığındadır (neden süreç-geneli bağlama,
 * bağlama süresince yeni bağlantıların etkisi, kapsam dışı olanlar, cihazda DOĞRULANMADI uyarısı).
 *
 * Bu dosya hiçbir `android.*` sınıfı kullanmaz: ConnectivityManager/Handler gibi her şey aşağıdaki
 * küçük arayüzlerin ardındadır ([BoardNetworkPlatform], [BoardNetworkScheduler]). Amaç, cihaz/emülatör
 * olmadan da DOĞRULANABİLEN bir durum makinesi: JVM birim testi (`BoardNetworkCoreTest`) sahte platform +
 * sanal zamanla her yolu (zaman aşımı, GRACE, kayıp, çifte sonuç, bayat geri çağrı...) sınar.
 * Android'e özgü ince yapıştırıcı BoardNetworkBinder.kt içindedir.
 */

/** Kanal sözleşmesindeki `status` değerleri (`ev_otomasyon/board_network`). BİREBİR korunmalıdır. */
internal object BoardNetworkStatus {
    const val BOUND = "bound"
    const val ALREADY_BOUND = "already_bound"
    const val NOT_ON_BOARD_NETWORK = "not_on_board_network"
    const val NO_WIFI = "no_wifi"

    /**
     * Sözleşmede var; YEREL taraf üretmez: işletim sistemi zaman aşımı ([NO_WIFI] olarak raporlanır, bkz.
     * [BoardNetworkCore.noWifiNetwork]). Dart tarafı kendi üst sınırı dolunca (dart_timeout) üretir.
     */
    const val TIMEOUT = "timeout"
    const val PERMISSION_DENIED = "permission_denied"
    const val UNSUPPORTED = "unsupported"
    const val ERROR = "error"

    // release için
    const val RELEASED = "released"
    const val NOT_BOUND = "not_bound"
}

/** `acquire` sonucu: sözleşmedeki `{status, detail?}`. `detail` kısa, SSID/IP/parola İÇERMEYEN bir ipucudur. */
internal data class AcquireResult(val status: String, val detail: String? = null)

/**
 * [BoardNetworkCore.release] ne yaptı: [released] = bir şey çözüldü (oturum ve/veya süreç bağlaması);
 * [wasBound] = süreç gerçekten bir ağa bağlıydı.
 */
internal data class ReleaseOutcome(val released: Boolean, val wasBound: Boolean)

/** Platformdaki ağ isteği kaydı. [unregister] tekrar çağrılabilir/zaten kaldırılmış olabilir; atmamalıdır. */
internal fun interface NetworkRegistration {
    fun unregister()
}

/**
 * Platformdan çekirdeğe ağ olayları. Herhangi bir İŞ PARÇACIĞINDAN çağrılabilir (API 24-25'te
 * ConnectivityManager kendi iş parçacığında çağırır); çekirdek hepsini ana iş parçacığına taşır.
 */
internal interface BoardNetworkListener<N : Any> {
    /** İstenen türde (Wi-Fi) bir ağ hazır. Bağlantı adresleri bu anda henüz boş olabilir. */
    fun onAvailable(network: N)

    /** Ağın bağlantı adresleri değişti/geldi (yalnız IPv4 adresleri, 4'er bayt). */
    fun onLinkAddresses(network: N, ipv4Addresses: List<ByteArray>)

    fun onLost(network: N)

    /** İşletim sistemi zaman aşımına uğradı (API 26+): istek zaten bırakılmıştır. */
    fun onUnavailable()
}

/** Ana iş parçacığı kuyruğu. Üretimde `Handler(Looper.getMainLooper())`; testte sanal saat. */
internal interface BoardNetworkScheduler {
    fun post(task: Runnable)

    fun postDelayed(task: Runnable, delayMs: Long)

    /** [task]'ın bekleyen tüm gönderilerini iptal eder (yoksa etkisiz). */
    fun cancel(task: Runnable)
}

/** Çekirdeğin Android'den ihtiyaç duyduğu her şey. [N] = ağ tutamacı (üretimde `android.net.Network`). */
internal interface BoardNetworkPlatform<N : Any> {
    /** `true`: ağ isteğinin zaman aşımını işletim sistemi de uygular (API 26+, `onUnavailable`). */
    val hasNativeRequestTimeout: Boolean

    /** Süreç bağlama API'si (API 23+) ve ConnectivityManager var mı? */
    fun isSupported(): Boolean

    /** Cihazda Wi-Fi donanımı var mı (`FEATURE_WIFI`)? İzin gerektirmez. */
    fun hasWifiHardware(): Boolean

    /** `CHANGE_NETWORK_STATE` izni verilmiş mi? (normal izin: manifestte varsa kurulumda verilir) */
    fun hasChangeNetworkStatePermission(): Boolean

    /**
     * Yalnız Wi-Fi taşıyıcılı (INTERNET/VALIDATED İSTEMEYEN) bir ağ isteği kaydeder; olaylar
     * [listener]'a gider. SecurityException (izin) veya başka RuntimeException (ör. çok fazla istek)
     * FIRLATABİLİR; fırlatırsa kayıt OLUŞMAMIŞTIR.
     */
    fun requestWifiNetwork(timeoutMs: Int, listener: BoardNetworkListener<N>): NetworkRegistration

    /**
     * Wi-Fi ağlarının KAYBINI izleyen ek kayıt (yalnız Wi-Fi taşıyıcılı `registerNetworkCallback`): herhangi bir
     * Wi-Fi ağı koptuğunda [onLost] çağrılır (herhangi bir İŞ PARÇACIĞINDAN). Gerekçe: `requestNetwork` geri çağrısı
     * yalnız "en iyi" ağı izler; istek daha iyi bir Wi-Fi'ye geçerse (`onAvailable(yeni)`) önceki ağ için `onLost`
     * HİÇ gelmez (Android belgesi), oysa süreç hâlâ o ağa bağlıdır. SecurityException/RuntimeException
     * FIRLATABİLİR; fırlatırsa kayıt OLUŞMAMIŞTIR.
     */
    fun watchWifiLoss(onLost: (N) -> Unit): NetworkRegistration

    /**
     * Süreci [network]'e bağlar (`null` = çöz). `false`: bağlanamadı. İki neden olabilir (çekirdek [ipv4Addresses] ile
     * ayırır): ağ bu arada koptu ya da ağ CANLI ama işletim sistemi bağlamayı reddetti (netd EPERM: atlanamaz VPN).
     */
    fun bindProcessTo(network: N?): Boolean

    /** Sürecin şu an bağlı olduğu ağ; bağlama yoksa `null`. */
    fun processBoundNetwork(): N?

    /** [network]'ün IPv4 adresleri; ağ bilinmiyorsa/koptuysa `null` (boş liste = henüz adres yok). */
    fun ipv4Addresses(network: N): List<ByteArray>?
}

/**
 * Süreç bağlama durum makinesi. TÜM genel metotlar ve içsel durum yalnız ANA iş parçacığındadır
 * (platform olayları [BoardNetworkScheduler.post] ile buraya taşınır).
 *
 * Tek bir "oturum" ([Session]) tutulur; aşamaları:
 *
 *  - WAITING    : istek kayıtlı, henüz hiçbir Wi-Fi ağı görülmedi. Bitişi: ağ görülür (EVALUATING), ya da
 *                 `onUnavailable`/bekçi zamanlayıcısı ([BoardNetworkStatus.NO_WIFI]; bkz. [noWifiNetwork]).
 *  - EVALUATING : bir Wi-Fi ağı görüldü, adresleri alt ağa uyuyor mu bakılıyor. `onAvailable` VE
 *                 `onLinkAddresses` ikisinde de değerlendirilir (DHCP adresi `onAvailable`'dan SONRA
 *                 gelebilir). Uyarsa bağlanır (BOUND); [GRACE_MS] içinde uymazsa [NOT_ON_BOARD_NETWORK].
 *                 `bindProcessTo` false dönerse: ağ canlıysa işletim sistemi bağlamayı REDDETMİŞTİR (tipik neden
 *                 VPN) -> beklemeden `error`/[DETAIL_BIND_DENIED]; ağ koptuysa kayıp sayılır, GRACE beklenir.
 *  - BOUND      : süreç ağa bağlı, kayıt AÇIK kalır (ağı canlı tutar). Bitişi: `release` ya da bağlı ağın kaybı
 *                 (önce çöz, SONRA [onNetworkLost] bildir). Kaybı İKİ kaynak bildirir: istek geri çağrısının
 *                 `onLost`'u VE ek kayıp izleyicisi ([BoardNetworkPlatform.watchWifiLoss]); gerekçe: `requestNetwork`
 *                 yalnız "en iyi" ağı izler, istek başka bir Wi-Fi'ye geçerse bağlı ağın `onLost`'u HİÇ gelmez.
 *  - CLOSED     : bitti; oturum artık [session] değildir, bayat olaylar yok sayılır.
 *
 * Her sonuç TAM BİR KEZ iletilir: bekleyenler listesi sonuç iletilmeden ÖNCE boşaltılır ve oturum
 * kapatılır; aynı oturuma ait sonraki olaylar `session === s` denetiminde elenir.
 */
internal class BoardNetworkCore<N : Any>(
    private val platform: BoardNetworkPlatform<N>,
    private val scheduler: BoardNetworkScheduler,
    private val log: (String) -> Unit,
    /** Bağlı ağ kaybolunca (çözüldükten SONRA) çağrılır; `release` çağrısında ÇAĞRILMAZ. */
    private val onNetworkLost: () -> Unit,
) {
    private enum class Phase { WAITING, EVALUATING, BOUND, CLOSED }

    /** Tek etkin oturum: bekleyen istek VEYA bağlı ağ. */
    private var session: Session? = null

    /** Süreç şu an (bizim tarafımızdan) bir ağa bağlı mı? */
    fun isBound(): Boolean = session?.phase == Phase.BOUND

    /**
     * Süreci, bağlantı adresleri [subnet] içinde olan Wi-Fi ağına bağlar. İDEMPOTENTTİR: zaten bağlıysa
     * [BoardNetworkStatus.ALREADY_BOUND]; sürmekte olan bir istek varsa [waiter] ona EKLENİR (tek ağ
     * isteği, bekleyenlerin hepsi aynı sonucu alır; ikinci çağrının [timeoutMs] değeri yok sayılır).
     * [waiter] TAM BİR KEZ çağrılır (bazı yollarda eşzamanlı, bazılarında sonradan).
     */
    fun acquire(subnet: Ipv4Subnet, timeoutMs: Long, waiter: (AcquireResult) -> Unit) {
        val current = session
        if (current != null) {
            when (current.phase) {
                Phase.BOUND -> {
                    // (2) Zaten bağlı ve ağ hâlâ geçerliyse "already_bound".
                    if (revalidateBound(current, subnet)) {
                        waiter(AcquireResult(BoardNetworkStatus.ALREADY_BOUND))
                        return
                    }
                    // Bayat bağlama çözüldü (session == null): aşağıda yeni istek başlar.
                }
                Phase.WAITING, Phase.EVALUATING -> {
                    if (current.subnet == subnet) {
                        current.waiters.add(waiter)
                        log("acquire: sürmekte olan isteğe katıldı (bekleyen=${current.waiters.size})")
                    } else {
                        // Aynı anda iki farklı alt ağ istenemez; yanlış ağa "bound" demektense hata.
                        waiter(AcquireResult(BoardNetworkStatus.ERROR, DETAIL_OTHER_SUBNET_PENDING))
                    }
                    return
                }
                Phase.CLOSED -> session = null // savunma: olmamalı
            }
        }
        startSession(subnet, timeoutMs, waiter)
    }

    /**
     * Her zaman güvenli ve idempotent: bekleyen istek varsa [DETAIL_RELEASED] ile `error` olarak bitirir,
     * süreç bağlamasını çözer, ağ isteği kaydını siler. Zamanlayıcıları iptal eder. [onNetworkLost]
     * ÇAĞIRMAZ (çözme isteği Dart'tan/yaşam döngüsünden gelir).
     */
    fun release(): ReleaseOutcome {
        var released = false
        var wasBound = false

        val s = session
        if (s != null) {
            wasBound = s.phase == Phase.BOUND
            teardown(s)
            finish(s, AcquireResult(BoardNetworkStatus.ERROR, DETAIL_RELEASED))
            released = true
        }
        // Emniyet kemeri: durum bayrağımız "bağlı değil" dese bile süreçte bağlama kalmışsa çöz (sızıntı olmasın).
        if (clearProcessBinding()) {
            released = true
            wasBound = true
        }
        if (released) log("release: wasBound=$wasBound") // boş release çağrıları (Dart'ın rutin çağrısı) günlüğü kirletmesin
        return ReleaseOutcome(released, wasBound)
    }

    // ---------------------------------------------------------------------------------------------
    // Oturum başlatma
    // ---------------------------------------------------------------------------------------------

    private fun startSession(subnet: Ipv4Subnet, timeoutMs: Long, waiter: (AcquireResult) -> Unit) {
        if (!platform.isSupported()) {
            waiter(AcquireResult(BoardNetworkStatus.UNSUPPORTED, "no_process_binding_api"))
            return
        }
        // (1) CHANGE_NETWORK_STATE yoksa "permission_denied" (SecurityException da aşağıda aynı sonuca gider).
        if (!platform.hasChangeNetworkStatePermission()) {
            waiter(AcquireResult(BoardNetworkStatus.PERMISSION_DENIED, "CHANGE_NETWORK_STATE"))
            return
        }
        // (6) "Wi-Fi hiç yoksa": cihazda Wi-Fi donanımı yoksa beklemeden "no_wifi".
        if (!platform.hasWifiHardware()) {
            waiter(AcquireResult(BoardNetworkStatus.NO_WIFI, "no_wifi_hardware"))
            return
        }

        val timeout = clampTimeout(timeoutMs)
        val s = Session(subnet)
        s.waiters.add(waiter)
        session = s
        try {
            // (3)+(4) Yalnız Wi-Fi taşıyıcılı istek; API 26+ ise işletim sistemi zaman aşımıyla.
            s.registration = platform.requestWifiNetwork(timeout, s)
        } catch (e: SecurityException) {
            abandonUnregistered(s)
            log("request: SecurityException -> permission_denied")
            waiter(AcquireResult(BoardNetworkStatus.PERMISSION_DENIED, "security_exception"))
            return
        } catch (e: RuntimeException) {
            abandonUnregistered(s)
            log("request: ${e.javaClass.simpleName} -> error")
            waiter(AcquireResult(BoardNetworkStatus.ERROR, "request_failed:${e.javaClass.simpleName}"))
            return
        }
        // Bekçi: API 24-25'te zaman aşımının TEK uygulayıcısı; API 26+'da `onUnavailable` kaçarsa yedek.
        val watchdogDelay = if (platform.hasNativeRequestTimeout) timeout + WATCHDOG_MARGIN_MS else timeout.toLong()
        scheduler.postDelayed(s.watchdog, watchdogDelay)
        log("acquire: istek kaydedildi (timeoutMs=$timeout, nativeTimeout=${platform.hasNativeRequestTimeout})")
    }

    /** `requestWifiNetwork` fırlattı: kayıt YOK, çözülecek bağlama YOK; yalnız oturumu at. */
    private fun abandonUnregistered(s: Session) {
        s.phase = Phase.CLOSED
        s.waiters.clear() // [waiter] çağıran tarafından doğrudan yanıtlanır (çifte yanıt olmasın)
        if (session === s) session = null
    }

    // ---------------------------------------------------------------------------------------------
    // Platform olayları (ana iş parçacığında)
    // ---------------------------------------------------------------------------------------------

    /** `onAvailable` ve `onLinkAddresses` ortak yolu: ağı gör, adreslerini değerlendir. */
    private fun handleNetworkSeen(s: Session, network: N, knownAddresses: List<ByteArray>?) {
        if (!isCurrent(s)) return
        when (s.phase) {
            Phase.WAITING -> {
                s.phase = Phase.EVALUATING
                scheduler.cancel(s.watchdog)
                scheduler.postDelayed(s.grace, GRACE_MS) // (5) en çok ~3 sn eşleşme beklenir
                log("wifi ağı görüldü, değerlendiriliyor")
            }
            Phase.EVALUATING -> Unit
            // Zaten bir ağa bağlıyız (taahhüt ettiğimiz ağda kalırız). AMA requestNetwork geri çağrısı yalnız "en iyi"
            // ağı izler: başka bir ağ görüldüyse istek artık ONU izliyordur ve bağlı ağın (A) kaybı için onLost(A)
            // HİÇ gelmeyebilir -> A'nın canlı olup olmadığına bakılır (kalıcı güvence: [startLossWatch]).
            Phase.BOUND -> {
                if (network != s.network) verifyBoundNetworkAlive(s)
                return
            }
            Phase.CLOSED -> return
        }
        evaluate(s, network, knownAddresses ?: platform.ipv4Addresses(network))
    }

    /**
     * BOUND iken istek başka bir ağa geçtiyse: bağlı ağ hâlâ canlı mı? Değilse süreç ölü bir ağa bağlı kalırdı (yeni
     * soketler, bulut dahil, başarısız olurdu): ÖNCE çöz, SONRA Dart'a bildir. Canlıysa bağlama sürer; sonraki kaybı
     * [startLossWatch] izleyicisi bildirir. Sorgu fırlatırsa ağ canlı sayılır (bağlama bozulmaz).
     */
    private fun verifyBoundNetworkAlive(s: Session) {
        val bound = s.network ?: return
        val alive = try {
            platform.ipv4Addresses(bound) != null
        } catch (e: RuntimeException) {
            true
        }
        if (alive) {
            log("istek başka bir Wi-Fi ağını izliyor; bağlı ağ canlı, bağlama sürüyor")
            return
        }
        log("istek başka bir Wi-Fi ağına geçti ve bağlı ağ artık yok; çözülüyor")
        teardown(s)
        notifyLost()
    }

    /**
     * BOUND iken ek kayıp izleyicisi (yalnız Wi-Fi): bağlı ağın kaybı, istek başka bir ağa geçmiş olsa bile duyulur
     * (o durumda requestNetwork geri çağrısı onLost(bağlı ağ) göndermez). Olaylar ana iş parçacığına taşınır ve
     * [handleLost] ile (oturum kimliği + ağ eşleşmesi denetimiyle) işlenir. Kaydedilemezse bağlama yine de sürer
     * (yedekler: [verifyBoundNetworkAlive], sonraki `acquire`'ın [revalidateBound] denetimi, Dart'ın `release`'i).
     */
    private fun startLossWatch(s: Session) {
        try {
            s.lossWatch = platform.watchWifiLoss { lost -> scheduler.post(Runnable { handleLost(s, lost) }) }
        } catch (e: RuntimeException) {
            log("kayıp izleyicisi kaydedilemedi: ${e.javaClass.simpleName}")
        }
    }

    private fun evaluate(s: Session, network: N, addresses: List<ByteArray>?) {
        if (addresses == null) {
            log("ağ değerlendirmeden önce koptu; bekleniyor")
            return
        }
        if (addresses.isNotEmpty()) s.sawIpv4Address = true // yalnız tanı ipucu (bkz. onGraceExpired)
        if (!s.subnet.containsAny(addresses)) {
            // Adres henüz gelmemiş (DHCP) ya da başka bir Wi-Fi ağı olabilir: onLinkAddresses'i/GRACE'i bekle.
            log("alt ağa uyan IPv4 adresi yok (ipv4Sayısı=${addresses.size}); bekleniyor")
            return
        }
        val bound = try {
            platform.bindProcessTo(network)
        } catch (e: RuntimeException) {
            log("bindProcessTo: ${e.javaClass.simpleName} -> error")
            teardown(s)
            finish(s, AcquireResult(BoardNetworkStatus.ERROR, "bind_failed:${e.javaClass.simpleName}"))
            return
        }
        if (!bound) {
            // bindProcessToNetwork false iki nedenle dönebilir (AOSP: netd ağ seçme denetimi):
            //  (1) ağ bu arada koptu (ENONET)  -> kayıp say, başka ağ/GRACE beklenir;
            //  (2) ağ CANLI ama bağlama reddedildi (EPERM: UID'ye atlanamaz bir VPN uygulanıyor; EACCES) -> aynı UID
            //      için her ağda reddedilir: GRACE'i beklemek boşuna ve "pano ağında değil" ipucu yanlış olurdu.
            if (isBindDenied(s, network)) {
                log("bindProcessTo false ama ağ canlı; bağlama reddedildi (tipik neden: VPN)")
                teardown(s)
                finish(s, AcquireResult(BoardNetworkStatus.ERROR, DETAIL_BIND_DENIED))
                return
            }
            s.bindReturnedFalse = true
            log("bindProcessTo false (ağ koptu); kayıp sayıldı")
            return
        }
        s.network = network
        s.phase = Phase.BOUND
        scheduler.cancel(s.grace)
        scheduler.cancel(s.watchdog)
        startLossWatch(s)
        log("bound")
        // (5) Bekleyen TÜM sonuçlara "bound". Kayıt AÇIK kalır (8): ağı "istenen" tutar; kaybı istek geri çağrısı
        // ve ek kayıp izleyicisi bildirir.
        finish(s, AcquireResult(BoardNetworkStatus.BOUND))
    }

    /** `bindProcessTo` false döndükten sonra: ağ HÂLÂ canlı ve alt ağa uyuyorsa bağlama reddedilmiştir (ağ kopmamıştır). */
    private fun isBindDenied(s: Session, network: N): Boolean {
        val addresses = try {
            platform.ipv4Addresses(network)
        } catch (e: RuntimeException) {
            null
        }
        return addresses != null && s.subnet.containsAny(addresses)
    }

    private fun handleLost(s: Session, network: N) {
        if (!isCurrent(s)) return
        if (s.phase == Phase.BOUND && s.network == network) {
            // (7) Bağlı ağ kayboldu: ÖNCE çöz + kaydı sil + durumu temizle, SONRA Dart'a bildir.
            log("bağlı ağ kayboldu; çözülüyor")
            teardown(s)
            notifyLost()
        } else {
            log("bağlı olmayan ağ kayboldu (yok sayıldı)")
        }
    }

    /** `onUnavailable`: işletim sistemi zaman aşımı; hiçbir Wi-Fi ağı hazır olmadı. */
    private fun handleUnavailable(s: Session) {
        if (!isCurrent(s) || s.phase != Phase.WAITING) return
        log("onUnavailable -> no_wifi")
        noWifiNetwork(s)
    }

    private fun onWatchdog(s: Session) {
        if (!isCurrent(s) || s.phase != Phase.WAITING) return
        log("bekçi zaman aşımı -> no_wifi")
        noWifiNetwork(s)
    }

    /**
     * (6) Zaman aşımı: istek YALNIZ Wi-Fi taşıyıcısı istediğinden (başka hiçbir yetenek yok), süre içinde hiç
     * `onAvailable` gelmemesi = "telefonun bağlı bir Wi-Fi ağı yok" demektir (Wi-Fi kapalı / hiçbir ağa bağlı
     * değil). Bu ayrım izin (ACCESS_WIFI_STATE) ya da kullanımdan kalkmış API olmadan, doğrudan işletim
     * sisteminin yanıtından yapılabildiği için sözleşmedeki "timeout" yerine daha açıklayıcı olan `no_wifi`
     * döner (Dart tarafında ipucu: "pano ağına bağlanın"). Sözleşme "timeout"ı tercih ederse TEK değişiklik
     * bu satırdaki durumdur. Ağ en az bir kez görüldüyse bu yola HİÇ girilmez (bkz. GRACE).
     */
    private fun noWifiNetwork(s: Session) {
        // `onUnavailable` isteği zaten bıraktı; yine de unregister denenir (IAE bağlayıcıda yutulur) -> sızıntı olmaz.
        teardown(s)
        finish(s, AcquireResult(BoardNetworkStatus.NO_WIFI, DETAIL_NO_WIFI_NETWORK))
    }

    private fun onGraceExpired(s: Session) {
        if (!isCurrent(s) || s.phase != Phase.EVALUATING) return
        // Durum sözleşme gereği hep not_on_board_network; `detail` yalnız TANI ipucudur (IP/SSID içermez):
        //  - other_subnet     : ağın IPv4 adresi var ama alt ağa uymuyor (telefon başka bir Wi-Fi'de),
        //  - no_ipv4_address  : ağ görüldü ama süre içinde hiç IPv4 adresi gelmedi (DHCP gecikmesi/IPv6-only),
        //  - bind_returned_false: alt ağa uyan ağa bağlanılamadı (ağ bağlama anında koptu).
        val detail = when {
            s.bindReturnedFalse -> DETAIL_BIND_RETURNED_FALSE
            s.sawIpv4Address -> DETAIL_OTHER_SUBNET
            else -> DETAIL_NO_IPV4_ADDRESS
        }
        log("GRACE doldu, uyan ağ yok -> not_on_board_network ($detail)")
        teardown(s)
        finish(s, AcquireResult(BoardNetworkStatus.NOT_ON_BOARD_NETWORK, detail))
    }

    // ---------------------------------------------------------------------------------------------
    // Yardımcılar
    // ---------------------------------------------------------------------------------------------

    /** BOUND oturum hâlâ [subnet] için geçerli mi? Değilse çözer + bildirir ve `false` döner. */
    private fun revalidateBound(s: Session, subnet: Ipv4Subnet): Boolean {
        val network = s.network
        val addresses = if (network != null) platform.ipv4Addresses(network) else null
        if (network == null || addresses == null || !subnet.containsAny(addresses)) {
            log("bağlı ağ artık geçerli değil; çözülüyor")
            teardown(s)
            notifyLost()
            return false
        }
        if (platform.processBoundNetwork() != network) {
            // Süreç bağlaması başka biri tarafından silinmiş: aynı ağa yeniden bağla.
            val rebound = try {
                platform.bindProcessTo(network)
            } catch (e: RuntimeException) {
                false
            }
            if (!rebound) {
                log("süreç bağlaması yeniden kurulamadı; çözülüyor")
                teardown(s)
                notifyLost()
                return false
            }
            log("süreç bağlaması yeniden kuruldu")
        }
        return true
    }

    /**
     * Oturumu kapatır: zamanlayıcıları iptal et, (bağlıysa) süreci çöz, ağ isteği kaydını sil.
     * Idempotenttir. Bekleyen sonuçlara DOKUNMAZ ([finish] ayrıdır).
     */
    private fun teardown(s: Session) {
        scheduler.cancel(s.watchdog)
        scheduler.cancel(s.grace)
        val wasBound = s.phase == Phase.BOUND
        s.phase = Phase.CLOSED
        if (session === s) session = null
        if (wasBound) {
            try {
                platform.bindProcessTo(null)
            } catch (e: RuntimeException) {
                log("bindProcessTo(null): ${e.javaClass.simpleName}")
            }
        }
        val registration = s.registration
        s.registration = null
        unregisterQuietly(registration)
        val lossWatch = s.lossWatch
        s.lossWatch = null
        unregisterQuietly(lossWatch)
    }

    private fun unregisterQuietly(registration: NetworkRegistration?) {
        if (registration == null) return
        try {
            registration.unregister()
        } catch (e: RuntimeException) {
            log("unregister: ${e.javaClass.simpleName}")
        }
    }

    /** Bekleyen herkese [result]'ı TAM BİR KEZ ilet. Liste önce boşaltılır (yeniden girişe karşı güvenli). */
    private fun finish(s: Session, result: AcquireResult) {
        if (s.waiters.isEmpty()) return
        val pending = ArrayList(s.waiters)
        s.waiters.clear()
        for (waiter in pending) {
            try {
                waiter(result)
            } catch (e: RuntimeException) {
                log("bekleyen sonucu iletirken hata: ${e.javaClass.simpleName}")
            }
        }
    }

    /** Süreçte (kimin yaptığına bakmadan) kalmış bağlama varsa çözer; çözdüyse `true`. */
    private fun clearProcessBinding(): Boolean {
        val bound = try {
            platform.processBoundNetwork()
        } catch (e: RuntimeException) {
            null
        }
        if (bound == null) return false
        try {
            platform.bindProcessTo(null)
        } catch (e: RuntimeException) {
            log("bindProcessTo(null): ${e.javaClass.simpleName}")
        }
        return true
    }

    private fun notifyLost() {
        try {
            onNetworkLost()
        } catch (e: RuntimeException) {
            log("networkLost bildirimi: ${e.javaClass.simpleName}")
        }
    }

    private fun isCurrent(s: Session): Boolean = session === s && s.phase != Phase.CLOSED

    /** `requestNetwork` zaman aşımı kesinlikle pozitif olmalıdır; uç değerler makul aralığa çekilir. */
    private fun clampTimeout(timeoutMs: Long): Int = when {
        timeoutMs <= 0L -> DEFAULT_TIMEOUT_MS
        timeoutMs < MIN_TIMEOUT_MS -> MIN_TIMEOUT_MS
        timeoutMs > MAX_TIMEOUT_MS -> MAX_TIMEOUT_MS
        else -> timeoutMs.toInt()
    }

    /**
     * Bir `acquire` -> `release`/kayıp ömrü. Platform olayları [BoardNetworkListener] olarak buraya gelir ve
     * ANA iş parçacığına taşınır; her taşınan iş, oturum kimliği ([isCurrent]) yeniden denetlenerek çalışır.
     */
    private inner class Session(val subnet: Ipv4Subnet) : BoardNetworkListener<N> {
        var phase: Phase = Phase.WAITING
        var network: N? = null
        var registration: NetworkRegistration? = null

        /** Yalnız BOUND iken: Wi-Fi kaybı izleyicisi ([startLossWatch]); [teardown] siler. */
        var lossWatch: NetworkRegistration? = null
        val waiters = ArrayList<(AcquireResult) -> Unit>(2)

        // Yalnız GRACE sonunda `detail` ipucu üretmek için (karar mantığını ETKİLEMEZ).
        var sawIpv4Address = false
        var bindReturnedFalse = false

        val watchdog = Runnable { onWatchdog(this@Session) }
        val grace = Runnable { onGraceExpired(this@Session) }

        override fun onAvailable(network: N) {
            scheduler.post(Runnable { handleNetworkSeen(this@Session, network, null) })
        }

        override fun onLinkAddresses(network: N, ipv4Addresses: List<ByteArray>) {
            scheduler.post(Runnable { handleNetworkSeen(this@Session, network, ipv4Addresses) })
        }

        override fun onLost(network: N) {
            scheduler.post(Runnable { handleLost(this@Session, network) })
        }

        override fun onUnavailable() {
            scheduler.post(Runnable { handleUnavailable(this@Session) })
        }
    }

    internal companion object {
        /** Sözleşmedeki `timeoutMs` varsayılanı. */
        const val DEFAULT_TIMEOUT_MS = 8_000
        const val MIN_TIMEOUT_MS = 500
        const val MAX_TIMEOUT_MS = 60_000

        /** Ağ görüldükten sonra adresin alt ağa uyması için beklenen EN ÇOK süre (DHCP gecikmesi payı). */
        const val GRACE_MS = 3_000L

        /** API 26+'da işletim sistemi zaman aşımından SONRA devreye giren yedek bekçinin payı. */
        const val WATCHDOG_MARGIN_MS = 1_500L

        const val DETAIL_RELEASED = "released"
        const val DETAIL_OTHER_SUBNET_PENDING = "other_subnet_pending"
        const val DETAIL_NO_WIFI_NETWORK = "no_wifi_network"
        const val DETAIL_OTHER_SUBNET = "other_subnet"
        const val DETAIL_NO_IPV4_ADDRESS = "no_ipv4_address"
        const val DETAIL_BIND_RETURNED_FALSE = "bind_returned_false"

        /** `error` + bu detay: ağ canlıyken `bindProcessToNetwork` false döndü (işletim sistemi reddetti; tipik neden VPN). */
        const val DETAIL_BIND_DENIED = "bind_denied"
    }
}
