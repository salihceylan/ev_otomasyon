package com.ahbu.evotomasyon.ev_otomasyon

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * BoardNetworkCore durum makinesi: sahte platform + SANAL ZAMAN ile (Android sınıfı yok).
 * Cihazda doğrulanamayan her yol (zaman aşımı, GRACE, kayıp, bayat geri çağrı, çifte sonuç...) burada sınanır.
 */
class BoardNetworkCoreTest {

    // ------------------------------------------------------------------------------------------
    // Sahte altyapı
    // ------------------------------------------------------------------------------------------

    private fun ip(a: Int, b: Int, c: Int, d: Int): ByteArray =
        byteArrayOf(a.toByte(), b.toByte(), c.toByte(), d.toByte())

    /** Panonun kurulum ağındaki telefon adresi (192.168.4.0/24). */
    private val apAddresses = listOf(ip(192, 168, 4, 2))

    /** Ev modemi (başka alt ağ). */
    private val homeAddresses = listOf(ip(192, 168, 1, 20))

    private class FakeScheduler : BoardNetworkScheduler {
        private class Entry(val at: Long, val seq: Long, val task: Runnable)

        private val queue = ArrayList<Entry>()
        private var seq = 0L
        var now = 0L
            private set

        override fun post(task: Runnable) {
            queue.add(Entry(now, seq++, task))
        }

        override fun postDelayed(task: Runnable, delayMs: Long) {
            queue.add(Entry(now + delayMs, seq++, task))
        }

        override fun cancel(task: Runnable) {
            queue.removeAll { it.task === task }
        }

        /** [ms] ilerlet; süresi dolan görevleri (sırayla, görev içinde eklenenler dahil) çalıştır. */
        fun advance(ms: Long) {
            val target = now + ms
            while (true) {
                val next = queue.filter { it.at <= target }
                    .minWithOrNull(compareBy<Entry>({ it.at }, { it.seq })) ?: break
                queue.remove(next)
                if (next.at > now) now = next.at
                next.task.run()
            }
            now = target
        }

        fun runDue() = advance(0)

        fun pendingCount(): Int = queue.size
    }

    private class FakePlatform(nativeTimeout: Boolean) : BoardNetworkPlatform<String> {
        override val hasNativeRequestTimeout: Boolean = nativeTimeout
        var supported = true
        var wifiHardware = true
        var permission = true

        var requestThrows: RuntimeException? = null
        var requestCalls = 0
        var lastTimeoutMs = -1
        val listeners = ArrayList<BoardNetworkListener<String>>()

        var unregisterCalls = 0
        var unregisterThrows: RuntimeException? = null

        /** Ağ -> adresler; `null` = ağ yok/koptu. Tanımsız ağ da `null` döner. */
        val ipv4 = HashMap<String, List<ByteArray>?>()
        var boundTo: String? = null
        val bindCalls = ArrayList<String?>()
        val bindResult = HashMap<String, Boolean>()
        var bindThrows: RuntimeException? = null

        /**
         * `bindProcessTo(ağ)` false döndükten SONRA ağın adresleri (yalnız anahtar varsa): `null` = ağ GERÇEKTEN koptu
         * (getLinkProperties null); başka değer = adresler değişti. Anahtar yoksa ağ canlı kalır (VPN reddi gibi).
         */
        val ipv4AfterFailedBind = HashMap<String, List<ByteArray>?>()

        /** Ek kayıp izleyicisi (registerNetworkCallback) kayıtları. */
        var watchCalls = 0
        var watchUnregisterCalls = 0
        var watchThrows: RuntimeException? = null
        var watchUnregisterThrows: RuntimeException? = null
        val watchers = ArrayList<(String) -> Unit>()

        /** `ipv4Addresses` sorgusunun kendisi fırlatsın (platform hatası). */
        var ipv4Throws: RuntimeException? = null

        override fun isSupported() = supported

        override fun hasWifiHardware() = wifiHardware

        override fun hasChangeNetworkStatePermission() = permission

        override fun requestWifiNetwork(
            timeoutMs: Int,
            listener: BoardNetworkListener<String>,
        ): NetworkRegistration {
            requestCalls++
            lastTimeoutMs = timeoutMs
            requestThrows?.let { throw it }
            listeners.add(listener)
            return NetworkRegistration {
                unregisterCalls++
                unregisterThrows?.let { throw it }
            }
        }

        override fun watchWifiLoss(onLost: (String) -> Unit): NetworkRegistration {
            watchCalls++
            watchThrows?.let { throw it }
            watchers.add(onLost)
            return NetworkRegistration {
                watchUnregisterCalls++
                watchUnregisterThrows?.let { throw it }
            }
        }

        override fun bindProcessTo(network: String?): Boolean {
            bindCalls.add(network)
            if (network == null) {
                boundTo = null
                return true
            }
            bindThrows?.let { throw it }
            val ok = bindResult[network] ?: true
            if (ok) {
                boundTo = network
            } else if (ipv4AfterFailedBind.containsKey(network)) {
                ipv4[network] = ipv4AfterFailedBind[network]
            }
            return ok
        }

        override fun processBoundNetwork(): String? = boundTo

        override fun ipv4Addresses(network: String): List<ByteArray>? {
            ipv4Throws?.let { throw it }
            return ipv4[network]
        }
    }

    private class Harness(nativeTimeout: Boolean = true) {
        val platform = FakePlatform(nativeTimeout)
        val scheduler = FakeScheduler()
        val logs = ArrayList<String>()
        var lostNotifications = 0
        var boundAtLostNotification: String? = "<yok>"

        val core = BoardNetworkCore(
            platform = platform,
            scheduler = scheduler,
            log = { logs.add(it) },
            onNetworkLost = {
                boundAtLostNotification = platform.boundTo
                lostNotifications++
            },
        )

        val subnet: Ipv4Subnet = Ipv4Subnet.parse("192.168.4.0/24")!!

        /** [acquire] çağırır; sonuçları (TAM BİR KEZ gelmesi gereken) listeye toplar. */
        fun acquire(timeoutMs: Long = 8_000, on: Ipv4Subnet = subnet): MutableList<AcquireResult> {
            val results = ArrayList<AcquireResult>()
            core.acquire(on, timeoutMs) { results.add(it) }
            return results
        }

        /** En son oturumun dinleyicisi. */
        val listener: BoardNetworkListener<String>
            get() = platform.listeners.last()

        fun available(network: String) {
            listener.onAvailable(network)
            scheduler.runDue()
        }

        fun linkAddresses(network: String, addresses: List<ByteArray>) {
            listener.onLinkAddresses(network, addresses)
            scheduler.runDue()
        }

        fun lost(network: String) {
            listener.onLost(network)
            scheduler.runDue()
        }

        /** Ek kayıp izleyicisinden (registerNetworkCallback) gelen onLost: istek geri çağrısından BAĞIMSIZ yol. */
        fun watchLost(network: String) {
            platform.watchers.last()(network)
            scheduler.runDue()
        }

        fun unavailable() {
            listener.onUnavailable()
            scheduler.runDue()
        }
    }

    /** Telefon panonun kurulum ağında: N1 -> 192.168.4.x. Sonuçlar dönen listeye toplanır. */
    private fun Harness.acquireAndBindToBoardNetwork(network: String = "N1"): MutableList<AcquireResult> {
        platform.ipv4[network] = apAddresses
        val results = acquire()
        available(network)
        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), results)
        assertEquals(network, platform.boundTo)
        return results
    }

    // ------------------------------------------------------------------------------------------
    // Başarı yolları
    // ------------------------------------------------------------------------------------------

    @Test
    fun acquire_matchingNetworkOnAvailable_bindsAndKeepsRequestRegistered() {
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses

        val results = h.acquire()
        assertTrue("ağ görülmeden sonuç olmamalı", results.isEmpty())
        assertEquals(1, h.platform.requestCalls)
        assertEquals(8_000, h.platform.lastTimeoutMs)

        h.available("N1")

        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), results)
        assertEquals("N1", h.platform.boundTo)
        assertTrue(h.core.isBound())
        // (8) bağlama sürerken kayıt AÇIK kalır; zamanlayıcı kalmaz.
        assertEquals(0, h.platform.unregisterCalls)
        assertEquals(0, h.scheduler.pendingCount())
        assertEquals(0, h.lostNotifications)
    }

    @Test
    fun acquire_addressArrivesAfterOnAvailable_bindsOnLinkAddresses() {
        val h = Harness()
        h.platform.ipv4["N1"] = emptyList() // DHCP henüz bitmedi
        val results = h.acquire()

        h.available("N1")
        assertTrue(results.isEmpty())
        assertFalse(h.core.isBound())
        assertEquals(emptyList<String?>(), h.platform.bindCalls)

        h.linkAddresses("N1", apAddresses)

        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), results)
        assertEquals("N1", h.platform.boundTo)
        assertEquals(0, h.scheduler.pendingCount())
    }

    @Test
    fun acquire_linkAddressesBeforeAvailable_isTreatedAsNetworkSeen() {
        val h = Harness()
        val results = h.acquire()
        h.linkAddresses("N1", apAddresses)
        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), results)
    }

    @Test
    fun acquire_nonMatchingThenMatchingWithinGrace_binds() {
        val h = Harness()
        h.platform.ipv4["N1"] = homeAddresses
        val results = h.acquire()

        h.available("N1")
        h.scheduler.advance(2_000)
        assertTrue(results.isEmpty())

        h.linkAddresses("N1", apAddresses)
        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), results)

        // GRACE iptal edildi: süre dolsa da ikinci sonuç GELMEZ.
        h.scheduler.advance(60_000)
        assertEquals(1, results.size)
        assertEquals("N1", h.platform.boundTo)
    }

    @Test
    fun acquire_secondNetworkMatchesWhileFirstDoesNot_bindsSecond() {
        val h = Harness()
        h.platform.ipv4["HOME"] = homeAddresses
        h.platform.ipv4["AP"] = apAddresses
        val results = h.acquire()

        h.available("HOME")
        assertTrue(results.isEmpty())
        h.available("AP")

        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), results)
        assertEquals("AP", h.platform.boundTo)
    }

    // ------------------------------------------------------------------------------------------
    // Başarısızlık / zaman aşımı yolları
    // ------------------------------------------------------------------------------------------

    @Test
    fun acquire_nonMatchingNetwork_graceExpires_notOnBoardNetwork_andReleasesRequest() {
        val h = Harness()
        h.platform.ipv4["N1"] = homeAddresses
        val results = h.acquire()

        h.available("N1")
        h.scheduler.advance(BoardNetworkCore.GRACE_MS - 1)
        assertTrue("GRACE dolmadan sonuç olmamalı", results.isEmpty())

        h.scheduler.advance(1)

        assertEquals(1, results.size)
        assertEquals(BoardNetworkStatus.NOT_ON_BOARD_NETWORK, results[0].status)
        assertEquals("ev modemi: IPv4 adresi var ama alt ağa uymuyor", BoardNetworkCore.DETAIL_OTHER_SUBNET, results[0].detail)
        assertEquals(1, h.platform.unregisterCalls)
        assertNull(h.platform.boundTo)
        assertEquals("hiç bağlama denenmemeli", emptyList<String?>(), h.platform.bindCalls)
        assertFalse(h.core.isBound())
        assertEquals(0, h.scheduler.pendingCount())
        assertEquals(0, h.lostNotifications)
    }

    @Test
    fun acquire_noWifiNetworkAtAll_onUnavailable_returnsNoWifi_andStaysQuiet() {
        val h = Harness()
        val results = h.acquire(timeoutMs = 5_000)
        assertEquals(5_000, h.platform.lastTimeoutMs)

        h.unavailable()

        // Yalnız Wi-Fi taşıyıcılı istek zaman aşımına uğradı = telefonun bağlı bir Wi-Fi ağı yok.
        assertEquals(listOf(AcquireResult(BoardNetworkStatus.NO_WIFI, BoardNetworkCore.DETAIL_NO_WIFI_NETWORK)), results)
        assertEquals(1, h.platform.unregisterCalls) // zaten bırakılmış olsa da unregister denenir (IAE bağlayıcıda yutulur)
        assertEquals(0, h.scheduler.pendingCount()) // bekçi iptal edildi

        h.scheduler.advance(120_000)
        assertEquals("bekçi ikinci sonuç üretmemeli", 1, results.size)
    }

    @Test
    fun acquire_noNativeTimeout_watchdogFiresExactlyAtTimeout() {
        // API 24-25: zaman aşımının TEK uygulayıcısı elle (Handler.postDelayed) kurulan bekçidir.
        val h = Harness(nativeTimeout = false)
        val results = h.acquire(timeoutMs = 3_000)

        h.scheduler.advance(2_999)
        assertTrue(results.isEmpty())
        h.scheduler.advance(1)

        assertEquals(1, results.size)
        assertEquals(BoardNetworkStatus.NO_WIFI, results[0].status)
        assertEquals(1, h.platform.unregisterCalls) // elle zaman aşımında isteği BIRAKMAK şart
        assertEquals(0, h.scheduler.pendingCount())
    }

    @Test
    fun acquire_nativeTimeout_watchdogIsOnlyABackstopAfterMargin() {
        // API 26+: onUnavailable hiç gelmese bile (OEM hatası) acquire TAKILI KALMAZ.
        val h = Harness(nativeTimeout = true)
        val results = h.acquire(timeoutMs = 3_000)

        h.scheduler.advance(3_000 + BoardNetworkCore.WATCHDOG_MARGIN_MS - 1)
        assertTrue(results.isEmpty())
        h.scheduler.advance(1)

        assertEquals(1, results.size)
        assertEquals(BoardNetworkStatus.NO_WIFI, results[0].status)
        assertEquals(1, h.platform.unregisterCalls)
    }

    @Test
    fun acquire_unavailableWhileEvaluating_isIgnored_graceStillDecides() {
        val h = Harness()
        h.platform.ipv4["N1"] = homeAddresses
        val results = h.acquire()
        h.available("N1")

        h.unavailable() // olmaması gereken ama zararsız olması gereken olay

        assertTrue(results.isEmpty())
        h.scheduler.advance(BoardNetworkCore.GRACE_MS)
        assertEquals(BoardNetworkStatus.NOT_ON_BOARD_NETWORK, results.single().status)
    }

    @Test
    fun acquire_networkLostWhileEvaluating_isIgnored_graceStillEnds() {
        val h = Harness()
        h.platform.ipv4["N1"] = homeAddresses
        val results = h.acquire()
        h.available("N1")

        h.lost("N1")

        assertTrue(results.isEmpty())
        assertEquals(0, h.lostNotifications) // bağlı değildik: Dart'a networkLost GİTMEZ
        h.scheduler.advance(BoardNetworkCore.GRACE_MS)
        assertEquals(BoardNetworkStatus.NOT_ON_BOARD_NETWORK, results.single().status)
    }

    @Test
    fun acquire_networkAlreadyGoneAtAvailable_waitsThenGraceEnds() {
        val h = Harness()
        h.platform.ipv4["N1"] = null // getLinkProperties null: ağ koptu
        val results = h.acquire()

        h.available("N1")
        assertTrue(results.isEmpty())

        h.scheduler.advance(BoardNetworkCore.GRACE_MS)
        assertEquals(BoardNetworkStatus.NOT_ON_BOARD_NETWORK, results.single().status)
        assertEquals(BoardNetworkCore.DETAIL_NO_IPV4_ADDRESS, results.single().detail)
        assertTrue(h.platform.bindCalls.isEmpty())
    }

    @Test
    fun acquire_networkNeverGetsAnIpv4Address_graceEnds_withNoIpv4Detail() {
        // DHCP bitmedi (ya da yalnız IPv6): adres listesi grace boyunca BOŞ kalır.
        val h = Harness()
        h.platform.ipv4["N1"] = emptyList()
        val results = h.acquire()

        h.available("N1")
        h.linkAddresses("N1", emptyList())
        h.scheduler.advance(BoardNetworkCore.GRACE_MS)

        assertEquals(
            listOf(AcquireResult(BoardNetworkStatus.NOT_ON_BOARD_NETWORK, BoardNetworkCore.DETAIL_NO_IPV4_ADDRESS)),
            results,
        )
        assertEquals(1, h.platform.unregisterCalls)
    }

    @Test
    fun acquire_bindReturnsFalse_networkGone_countsAsLost_thenGraceEnds() {
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        h.platform.bindResult["N1"] = false // bindProcessToNetwork false ...
        h.platform.ipv4AfterFailedBind["N1"] = null // ... ve ağ GERÇEKTEN koptu (getLinkProperties null)
        val results = h.acquire()

        h.available("N1")
        assertTrue(results.isEmpty())
        assertFalse(h.core.isBound())
        assertNull(h.platform.boundTo)

        h.scheduler.advance(BoardNetworkCore.GRACE_MS)
        assertEquals(BoardNetworkStatus.NOT_ON_BOARD_NETWORK, results.single().status)
        assertEquals(BoardNetworkCore.DETAIL_BIND_RETURNED_FALSE, results.single().detail)
        assertEquals(1, h.platform.unregisterCalls)
    }

    @Test
    fun acquire_bindReturnsFalseForFirstNetwork_networkGone_secondNetworkBinds() {
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        h.platform.ipv4["N2"] = apAddresses
        h.platform.bindResult["N1"] = false
        h.platform.ipv4AfterFailedBind["N1"] = null
        val results = h.acquire()

        h.available("N1")
        h.available("N2")

        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), results)
        assertEquals("N2", h.platform.boundTo)
    }

    @Test
    fun acquire_bindReturnsFalse_whileNetworkAlive_failsAtOnceWithBindDenied_andCleansUp() {
        // İşletim sistemi bağlamayı reddetti (ör. atlanamaz VPN: netd EPERM) ama ağ CANLI: GRACE beklemek boşuna ve
        // "pano ağında değil" ipucu yanlış olurdu -> beklemeden error/bind_denied.
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        h.platform.bindResult["N1"] = false
        val results = h.acquire()

        h.available("N1")

        assertEquals(
            listOf(AcquireResult(BoardNetworkStatus.ERROR, BoardNetworkCore.DETAIL_BIND_DENIED)),
            results,
        )
        assertEquals("GRACE/bekçi zamanlayıcısı kalmamalı", 0, h.scheduler.pendingCount())
        assertEquals("ağ isteği bırakıldı", 1, h.platform.unregisterCalls)
        assertFalse(h.core.isBound())
        assertNull(h.platform.boundTo)
        assertEquals("bağlanamadı: kayıp izleyicisi kaydedilmemeli", 0, h.platform.watchCalls)
        assertEquals(0, h.lostNotifications)

        // Süre geçse de ikinci sonuç gelmez; VPN kapanınca sonraki acquire normal bağlanır (sızıntı yok).
        h.scheduler.advance(120_000)
        assertEquals(1, results.size)
        h.platform.bindResult.clear()
        val again = h.acquire()
        h.available("N1")
        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), again)
        assertEquals("N1", h.platform.boundTo)
    }

    @Test
    fun acquire_bindReturnsFalse_afterwardsAddressesNoLongerMatch_isNotADenial_waitsForGrace() {
        // Ağ canlı ama adresleri artık alt ağa uymuyor (yeniden yapılandırıldı): "reddedildi" DEĞİL; GRACE kararı verir.
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        h.platform.bindResult["N1"] = false
        h.platform.ipv4AfterFailedBind["N1"] = homeAddresses
        val results = h.acquire()

        h.available("N1")
        assertTrue(results.isEmpty())

        h.scheduler.advance(BoardNetworkCore.GRACE_MS)
        assertEquals(BoardNetworkStatus.NOT_ON_BOARD_NETWORK, results.single().status)
        assertEquals(BoardNetworkCore.DETAIL_BIND_RETURNED_FALSE, results.single().detail)
    }

    @Test
    fun acquire_bindThrows_returnsErrorAndCleansUp() {
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        h.platform.bindThrows = IllegalStateException("boom")
        val results = h.acquire()

        h.available("N1")

        assertEquals(1, results.size)
        assertEquals(BoardNetworkStatus.ERROR, results[0].status)
        assertEquals("bind_failed:IllegalStateException", results[0].detail)
        assertEquals(1, h.platform.unregisterCalls)
        assertFalse(h.core.isBound())
        assertEquals(0, h.scheduler.pendingCount())

        // Sızıntı yok: sonraki acquire yeniden çalışır.
        h.platform.bindThrows = null
        val again = h.acquire()
        h.available("N1")
        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), again)
    }

    // ------------------------------------------------------------------------------------------
    // Ön koşullar ve platform hataları
    // ------------------------------------------------------------------------------------------

    @Test
    fun acquire_permissionMissing_returnsPermissionDenied_withoutRequest() {
        val h = Harness()
        h.platform.permission = false

        val results = h.acquire()

        assertEquals(BoardNetworkStatus.PERMISSION_DENIED, results.single().status)
        assertEquals(0, h.platform.requestCalls)
        assertFalse(h.core.isBound())
    }

    @Test
    fun acquire_securityExceptionFromRequest_returnsPermissionDenied_andLeavesNoSession() {
        val h = Harness()
        h.platform.requestThrows = SecurityException("no permission")

        val results = h.acquire()

        assertEquals(1, results.size)
        assertEquals(BoardNetworkStatus.PERMISSION_DENIED, results[0].status)
        assertEquals(0, h.platform.unregisterCalls) // kayıt oluşmadı: unregister EDİLMEMELİ
        assertEquals(0, h.scheduler.pendingCount())

        // Oturum sızmadı: izin gelince yeni istek başlar ve bağlanır.
        h.platform.requestThrows = null
        h.platform.ipv4["N1"] = apAddresses
        val again = h.acquire()
        assertEquals(2, h.platform.requestCalls)
        h.available("N1")
        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), again)
    }

    @Test
    fun acquire_runtimeExceptionFromRequest_returnsErrorWithShortDetail() {
        val h = Harness()
        h.platform.requestThrows = IllegalStateException("too many requests")

        val results = h.acquire()

        assertEquals(1, results.size)
        assertEquals(BoardNetworkStatus.ERROR, results[0].status)
        assertEquals("request_failed:IllegalStateException", results[0].detail)
        assertEquals(0, h.platform.unregisterCalls)
        assertFalse(h.core.isBound())
        assertEquals(0, h.scheduler.pendingCount())
    }

    @Test
    fun acquire_unsupportedPlatform_returnsUnsupported() {
        val h = Harness()
        h.platform.supported = false
        assertEquals(BoardNetworkStatus.UNSUPPORTED, h.acquire().single().status)
        assertEquals(0, h.platform.requestCalls)
    }

    @Test
    fun acquire_noWifiHardware_returnsNoWifi_withoutWaiting() {
        val h = Harness()
        h.platform.wifiHardware = false
        assertEquals(BoardNetworkStatus.NO_WIFI, h.acquire().single().status)
        assertEquals(0, h.platform.requestCalls)
        assertEquals(0, h.scheduler.pendingCount())
    }

    @Test
    fun acquire_timeoutIsClampedToSaneRange() {
        val cases = listOf(
            0L to BoardNetworkCore.DEFAULT_TIMEOUT_MS,
            -5L to BoardNetworkCore.DEFAULT_TIMEOUT_MS,
            1L to BoardNetworkCore.MIN_TIMEOUT_MS,
            8_000L to 8_000,
            10_000_000L to BoardNetworkCore.MAX_TIMEOUT_MS,
        )
        for ((requested, expected) in cases) {
            val h = Harness()
            h.acquire(timeoutMs = requested)
            assertEquals("timeoutMs=$requested", expected, h.platform.lastTimeoutMs)
            assertTrue("işletim sistemine verilen zaman aşımı pozitif olmalı", h.platform.lastTimeoutMs > 0)
        }
    }

    // ------------------------------------------------------------------------------------------
    // İdempotans ve birleştirme
    // ------------------------------------------------------------------------------------------

    @Test
    fun acquire_concurrentCallsMergeIntoOneRequest_andEachGetsExactlyOneResult() {
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        val r1 = h.acquire()
        val r2 = h.acquire()
        val r3 = h.acquire(timeoutMs = 1) // ikinci çağrının zaman aşımı yok sayılır

        assertEquals("tek ağ isteği", 1, h.platform.requestCalls)
        assertEquals(8_000, h.platform.lastTimeoutMs)

        h.available("N1")

        for (r in listOf(r1, r2, r3)) {
            assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), r)
        }
        assertEquals(1, h.platform.bindCalls.count { it != null })
    }

    @Test
    fun acquire_whileBound_returnsAlreadyBound_withoutNewRequest() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork()

        val second = h.acquire()

        assertEquals(listOf(AcquireResult(BoardNetworkStatus.ALREADY_BOUND)), second)
        assertEquals(1, h.platform.requestCalls)
        assertEquals("N1", h.platform.boundTo)
        assertEquals(0, h.lostNotifications)
    }

    @Test
    fun acquire_whileBound_rebindsWhenProcessBindingWasClearedBySomeoneElse() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork()
        h.platform.boundTo = null // başkası bindProcessToNetwork(null) yaptı

        val second = h.acquire()

        assertEquals(listOf(AcquireResult(BoardNetworkStatus.ALREADY_BOUND)), second)
        assertEquals("süreç bağlaması yeniden kurulmalı", "N1", h.platform.boundTo)
        assertEquals(1, h.platform.requestCalls)
    }

    @Test
    fun acquire_whileBound_butNetworkGone_dropsStaleBindingAndStartsFresh() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork()
        val oldListener = h.listener
        h.platform.ipv4["N1"] = null // ağ gitti ama onLost henüz işlenmedi

        val second = h.acquire()

        assertTrue("yeni istek bekliyor", second.isEmpty())
        assertEquals(2, h.platform.requestCalls)
        assertNull("bayat bağlama çözüldü", h.platform.boundTo)
        assertEquals(1, h.platform.unregisterCalls)
        assertEquals("kayıp izleyicisi de bırakıldı", 1, h.platform.watchUnregisterCalls)
        assertEquals("Dart'a kayıp bildirilir", 1, h.lostNotifications)
        assertNull("bildirim çözüldükten SONRA gitmeli", h.boundAtLostNotification)

        // Eski oturumun geç gelen olayı yok sayılır (ikinci bildirim/ikinci sonuç YOK).
        oldListener.onLost("N1")
        h.scheduler.runDue()
        assertEquals(1, h.lostNotifications)

        h.platform.ipv4["N1"] = apAddresses
        h.available("N1")
        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), second)
    }

    @Test
    fun acquire_whileBound_butDifferentSubnetRequested_dropsAndStartsFresh() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork()
        val other = Ipv4Subnet.parse("10.0.0.0/24")!!

        val second = h.acquire(on = other)

        assertTrue(second.isEmpty())
        assertEquals(2, h.platform.requestCalls)
        assertNull(h.platform.boundTo)
        assertEquals(1, h.lostNotifications)
    }

    @Test
    fun acquire_differentSubnetWhilePending_isRejected_pendingUnaffected() {
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        val first = h.acquire()
        val other = Ipv4Subnet.parse("10.0.0.0/24")!!

        val second = h.acquire(on = other)

        assertEquals(BoardNetworkStatus.ERROR, second.single().status)
        assertEquals(BoardNetworkCore.DETAIL_OTHER_SUBNET_PENDING, second.single().detail)
        assertEquals(1, h.platform.requestCalls)

        h.available("N1")
        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), first)
    }

    @Test
    fun acquire_afterTimeout_startsANewSession() {
        val h = Harness()
        val first = h.acquire()
        h.unavailable()
        assertEquals(BoardNetworkStatus.NO_WIFI, first.single().status)

        h.platform.ipv4["N1"] = apAddresses
        val second = h.acquire()
        assertEquals(2, h.platform.requestCalls)
        h.available("N1")

        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), second)
        assertEquals("ilk sonuç değişmedi", 1, first.size)
    }

    // ------------------------------------------------------------------------------------------
    // Kayıp (onLost)
    // ------------------------------------------------------------------------------------------

    @Test
    fun lostBoundNetwork_unbindsFirst_thenUnregisters_thenNotifiesOnce() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork()
        val listener = h.listener

        h.lost("N1")

        assertNull(h.platform.boundTo)
        assertFalse(h.core.isBound())
        assertEquals(1, h.platform.unregisterCalls)
        assertEquals("kayıp izleyicisi de bırakıldı", 1, h.platform.watchUnregisterCalls)
        assertEquals(1, h.lostNotifications)
        assertNull("yerel taraf ÖNCE çözer, SONRA bildirir", h.boundAtLostNotification)

        // Aynı olayın tekrarı/bayat geri çağrı: ikinci bildirim YOK.
        listener.onLost("N1")
        h.scheduler.runDue()
        assertEquals(1, h.lostNotifications)
        assertEquals(1, h.platform.unregisterCalls)
    }

    @Test
    fun lostOfAnotherNetworkWhileBound_isIgnored() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork("N1")

        h.lost("N2")

        assertTrue(h.core.isBound())
        assertEquals("N1", h.platform.boundTo)
        assertEquals(0, h.lostNotifications)
        assertEquals(0, h.platform.unregisterCalls)
    }

    @Test
    fun availableOfAnotherNetworkWhileBound_keepsTheCommittedNetworkAsLongAsItIsAlive() {
        // Gerçek platform modeli (NetworkCallback.onAvailable belgesi): requestNetwork geri çağrısı artık YENİ en iyi ağı
        // (N2) izler; N1 için onLost(N1) bir daha GELMEZ. N1 canlı olduğu sürece bağlama sürer.
        val h = Harness()
        h.acquireAndBindToBoardNetwork("N1")
        h.platform.ipv4["N2"] = apAddresses

        h.available("N2")
        h.linkAddresses("N2", apAddresses)

        assertTrue(h.core.isBound())
        assertEquals("N1", h.platform.boundTo)
        assertEquals(1, h.platform.bindCalls.count { it != null })
        assertEquals(0, h.lostNotifications)
        assertEquals(0, h.platform.unregisterCalls)
        assertEquals("kayıp izleyicisi korunur", 0, h.platform.watchUnregisterCalls)
    }

    @Test
    fun availableOfAnotherNetworkWhileBound_boundNetworkAlreadyGone_unbindsThenNotifiesOnce() {
        // İstek N2'ye geçti ve N1 çoktan gitti: onLost(N1) HİÇ gelmeyecek. Çekirdek bunu fark edip (önce çöz, sonra
        // bildir) süreci ölü bir ağa bağlı bırakmamalı.
        val h = Harness()
        h.acquireAndBindToBoardNetwork("N1")
        h.platform.ipv4["N2"] = homeAddresses
        h.platform.ipv4["N1"] = null

        h.available("N2")

        assertNull(h.platform.boundTo)
        assertFalse(h.core.isBound())
        assertEquals(1, h.lostNotifications)
        assertNull("önce çöz, sonra bildir", h.boundAtLostNotification)
        assertEquals(1, h.platform.unregisterCalls)
        assertEquals(1, h.platform.watchUnregisterCalls)

        // Aynı oturumun tekrar eden olayları ikinci bildirim üretmez.
        h.linkAddresses("N2", homeAddresses)
        assertEquals(1, h.lostNotifications)
    }

    @Test
    fun availableOfAnotherNetworkWhileBound_addressQueryThrows_keepsBinding() {
        // ipv4Addresses fırlatırsa ağ canlı sayılır: bağlama bozulmaz (yanlış alarm yok).
        val h = Harness()
        h.acquireAndBindToBoardNetwork("N1")
        h.platform.ipv4["N2"] = homeAddresses
        h.platform.ipv4Throws = IllegalStateException("boom")

        h.available("N2")

        assertTrue(h.core.isBound())
        assertEquals("N1", h.platform.boundTo)
        assertEquals(0, h.lostNotifications)
    }

    @Test
    fun lossWatch_reportsLossOfBoundNetwork_evenThoughRequestMovedToAnotherNetwork() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork("N1")
        h.platform.ipv4["N2"] = homeAddresses
        h.available("N2") // istek N2'ye geçti; N1 hâlâ canlı -> bağlama sürer
        assertTrue(h.core.isBound())

        h.platform.ipv4["N1"] = null
        h.watchLost("N1") // istek geri çağrısı N1 için onLost VERMEZ; yalnız ek izleyici duyar

        assertNull(h.platform.boundTo)
        assertFalse(h.core.isBound())
        assertEquals(1, h.lostNotifications)
        assertNull("önce çöz, sonra bildir", h.boundAtLostNotification)
        assertEquals(1, h.platform.unregisterCalls)
        assertEquals(1, h.platform.watchUnregisterCalls)
    }

    @Test
    fun lossWatch_isRegisteredOnlyOnceBound_andUnregisteredOnRelease() {
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        h.acquire()
        assertEquals("bağlanmadan izleyici yok", 0, h.platform.watchCalls)

        h.available("N1")
        assertEquals(1, h.platform.watchCalls)
        assertEquals(0, h.platform.watchUnregisterCalls)

        h.core.release()

        assertEquals(1, h.platform.watchUnregisterCalls)
        assertEquals(1, h.platform.unregisterCalls)
        h.core.release() // idempotent: ikinci unregister yok
        assertEquals(1, h.platform.watchUnregisterCalls)
    }

    @Test
    fun lossWatch_isNotRegisteredWhenNothingGetsBound() {
        val notOnBoard = Harness()
        notOnBoard.platform.ipv4["N1"] = homeAddresses
        notOnBoard.acquire()
        notOnBoard.available("N1")
        notOnBoard.scheduler.advance(BoardNetworkCore.GRACE_MS)
        assertEquals(0, notOnBoard.platform.watchCalls)

        val noWifi = Harness()
        noWifi.acquire()
        noWifi.unavailable()
        assertEquals(0, noWifi.platform.watchCalls)
    }

    @Test
    fun lossWatch_ignoresLossOfOtherNetworks() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork("N1")

        h.watchLost("HOME")

        assertTrue(h.core.isBound())
        assertEquals("N1", h.platform.boundTo)
        assertEquals(0, h.lostNotifications)
        assertEquals(0, h.platform.unregisterCalls)
    }

    @Test
    fun lossReportedByBothRequestCallbackAndWatch_notifiesExactlyOnce() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork("N1")
        val requestListener = h.listener
        val watcher = h.platform.watchers.last()

        requestListener.onLost("N1")
        watcher("N1")
        h.scheduler.runDue()

        assertEquals(1, h.lostNotifications)
        assertEquals(1, h.platform.unregisterCalls)
        assertEquals(1, h.platform.watchUnregisterCalls)
    }

    @Test
    fun staleWatchCallback_afterRelease_doesNotTouchTheNewSession() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork("N1")
        val staleWatcher = h.platform.watchers.last()
        h.core.release()

        h.platform.ipv4["N1"] = apAddresses
        val fresh = h.acquire()
        staleWatcher("N1") // eski oturumun izleyicisi: yok sayılmalı
        h.scheduler.runDue()

        assertEquals(0, h.lostNotifications)
        assertTrue("yeni oturum etkilenmemeli", fresh.isEmpty())
        h.available("N1")
        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), fresh)
        assertEquals("N1", h.platform.boundTo)
    }

    @Test
    fun lossWatchRegistrationFailure_doesNotBreakTheBinding_andFallbackStillWorks() {
        val h = Harness()
        h.platform.watchThrows = SecurityException("no ACCESS_NETWORK_STATE")
        h.platform.ipv4["N1"] = apAddresses
        val results = h.acquire()

        h.available("N1")

        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), results)
        assertTrue(h.core.isBound())
        assertEquals("N1", h.platform.boundTo)
        assertTrue(h.logs.any { it.contains("SecurityException") })

        // Yedek yol: istek başka ağa geçip bağlı ağ koptuysa yine çözülür ve bildirilir.
        h.platform.ipv4["N2"] = homeAddresses
        h.platform.ipv4["N1"] = null
        h.available("N2")
        assertFalse(h.core.isBound())
        assertEquals(1, h.lostNotifications)
        assertEquals("kayıt hiç oluşmadı", 0, h.platform.watchUnregisterCalls)
    }

    @Test
    fun lossWatchUnregisterThrows_isSwallowed() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork("N1")
        h.platform.watchUnregisterThrows = IllegalArgumentException("already unregistered")

        val outcome = h.core.release()

        assertEquals(ReleaseOutcome(released = true, wasBound = true), outcome)
        assertNull(h.platform.boundTo)
        assertEquals("ağ isteği kaydı da yine bırakıldı", 1, h.platform.unregisterCalls)
    }

    @Test
    fun afterLoss_acquireWorksAgain() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork()
        h.lost("N1")

        h.platform.ipv4["N3"] = apAddresses
        val again = h.acquire()
        assertEquals(2, h.platform.requestCalls)
        h.available("N3")

        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), again)
        assertEquals("N3", h.platform.boundTo)
    }

    // ------------------------------------------------------------------------------------------
    // release
    // ------------------------------------------------------------------------------------------

    @Test
    fun release_whileBound_unbindsUnregisters_withoutNotifyingDart_andIsIdempotent() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork()

        val first = h.core.release()

        assertEquals(ReleaseOutcome(released = true, wasBound = true), first)
        assertNull(h.platform.boundTo)
        assertFalse(h.core.isBound())
        assertEquals(1, h.platform.unregisterCalls)
        assertEquals("release `networkLost` göndermez", 0, h.lostNotifications)
        assertEquals(0, h.scheduler.pendingCount())

        val second = h.core.release()
        assertEquals(ReleaseOutcome(released = false, wasBound = false), second)
        assertEquals("ikinci release ikinci unregister yapmamalı", 1, h.platform.unregisterCalls)
    }

    @Test
    fun release_whileBound_thenStaleLostFromOldRequest_doesNotNotifyOrTouchNewSession() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork()
        val oldListener = h.listener
        h.core.release()

        // Yeni oturum başladı (bekliyor); eski isteğin geç gelen onLost/onUnavailable olayları ona DOKUNMAZ.
        h.platform.ipv4["N1"] = apAddresses
        val fresh = h.acquire()
        oldListener.onLost("N1")
        oldListener.onUnavailable()
        h.scheduler.runDue()

        assertEquals(0, h.lostNotifications)
        assertTrue("yeni oturum etkilenmemeli", fresh.isEmpty())
        h.available("N1")
        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), fresh)
    }

    @Test
    fun release_whilePending_finishesEveryWaiterWithReleasedError_exactlyOnce() {
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        val r1 = h.acquire()
        val r2 = h.acquire()
        val listener = h.listener

        val outcome = h.core.release()

        assertEquals(ReleaseOutcome(released = true, wasBound = false), outcome)
        val expected = listOf(AcquireResult(BoardNetworkStatus.ERROR, "released"))
        assertEquals(expected, r1)
        assertEquals(expected, r2)
        assertEquals(1, h.platform.unregisterCalls)
        assertEquals(0, h.scheduler.pendingCount())

        // Bayat geri çağrılar: ne bağlanır ne ikinci sonuç üretir.
        listener.onAvailable("N1")
        listener.onLinkAddresses("N1", apAddresses)
        listener.onUnavailable()
        h.scheduler.advance(120_000)
        assertEquals(expected, r1)
        assertEquals(expected, r2)
        assertNull(h.platform.boundTo)
        assertTrue(h.platform.bindCalls.isEmpty())
    }

    @Test
    fun release_whileEvaluating_cancelsGraceAndFinishesWaiter() {
        val h = Harness()
        h.platform.ipv4["N1"] = homeAddresses
        val results = h.acquire()
        h.available("N1")

        h.core.release()
        h.scheduler.advance(120_000)

        assertEquals(listOf(AcquireResult(BoardNetworkStatus.ERROR, "released")), results)
    }

    @Test
    fun release_whenNothingBound_isANoOp() {
        val h = Harness()

        val outcome = h.core.release()

        assertEquals(ReleaseOutcome(released = false, wasBound = false), outcome)
        assertTrue("bağlama yokken bindProcessTo çağrılmamalı", h.platform.bindCalls.isEmpty())
        assertEquals(0, h.platform.unregisterCalls)
    }

    @Test
    fun release_clearsStrayProcessBinding_evenWithoutSession() {
        val h = Harness()
        h.platform.boundTo = "STRAY" // durum bayrağımız "bağlı değil" ama süreçte bağlama kalmış

        val outcome = h.core.release()

        assertEquals(ReleaseOutcome(released = true, wasBound = true), outcome)
        assertNull(h.platform.boundTo)
    }

    @Test
    fun release_survivesUnregisterThatThrows() {
        val h = Harness()
        h.acquireAndBindToBoardNetwork()
        h.platform.unregisterThrows = IllegalArgumentException("NetworkCallback was already unregistered")

        val outcome = h.core.release()

        assertEquals(ReleaseOutcome(released = true, wasBound = true), outcome)
        assertNull(h.platform.boundTo)
        assertFalse(h.core.isBound())
    }

    // ------------------------------------------------------------------------------------------
    // Her sonuç tam bir kez / sağlamlık
    // ------------------------------------------------------------------------------------------

    @Test
    fun eachWaiterGetsExactlyOneResult_evenWithManyDuplicateEvents() {
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        val results = h.acquire()

        h.available("N1")
        h.available("N1")
        h.linkAddresses("N1", apAddresses)
        h.linkAddresses("N1", emptyList())
        h.unavailable()
        h.lost("N9")
        h.scheduler.advance(120_000)

        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), results)
    }

    @Test
    fun aWaiterThatThrows_doesNotStopOtherWaiters_orLeaveBrokenState() {
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        h.core.acquire(h.subnet, 8_000) { throw IllegalStateException("plugin yanıtı patladı") }
        val second = h.acquire()

        h.available("N1")

        assertEquals(listOf(AcquireResult(BoardNetworkStatus.BOUND)), second)
        assertTrue(h.core.isBound())
        assertTrue(h.logs.any { it.contains("IllegalStateException") })
    }

    @Test
    fun reentrantAcquireFromAWaiter_isSafe() {
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        val inner = ArrayList<AcquireResult>()
        h.core.acquire(h.subnet, 8_000) {
            // sonuç iletilirken yeniden acquire: oturum zaten BOUND -> already_bound
            h.core.acquire(h.subnet, 8_000) { r -> inner.add(r) }
        }

        h.available("N1")

        assertEquals(listOf(AcquireResult(BoardNetworkStatus.ALREADY_BOUND)), inner)
        assertEquals(1, h.platform.requestCalls)
    }

    @Test
    fun staleCallbacksAfterTimeout_areIgnored() {
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        val results = h.acquire()
        val listener = h.listener
        h.unavailable()
        assertEquals(BoardNetworkStatus.NO_WIFI, results.single().status)

        listener.onAvailable("N1")
        listener.onLinkAddresses("N1", apAddresses)
        h.scheduler.runDue()

        assertEquals(1, results.size)
        assertNull("bayat olay bağlama YAPMAMALI", h.platform.boundTo)
        assertTrue(h.platform.bindCalls.isEmpty())
    }

    @Test
    fun logs_neverContainAddressesOrNetworkNames() {
        val h = Harness()
        h.platform.ipv4["N1"] = apAddresses
        h.acquire()
        h.available("N1")
        h.lost("N1")
        h.platform.ipv4["N2"] = homeAddresses
        h.acquire()
        h.available("N2")
        h.scheduler.advance(BoardNetworkCore.GRACE_MS)
        h.core.release()

        // Bağlama reddi (VPN), istek başka ağa geçti ve kayıp izleyicisi yolları da günlüğe IP/ağ adı yazmamalı.
        h.platform.ipv4["N3"] = apAddresses
        h.platform.bindResult["N3"] = false
        h.acquire()
        h.available("N3")
        h.platform.bindResult.clear()
        h.acquire()
        h.available("N3")
        h.platform.ipv4["N4"] = homeAddresses
        h.available("N4")
        h.platform.ipv4["N3"] = null
        h.watchLost("N3")
        h.platform.watchThrows = IllegalStateException("boom")
        h.platform.ipv4["N5"] = apAddresses
        h.acquire()
        h.available("N5")

        assertTrue("günlük satırı üretilmeliydi", h.logs.isNotEmpty())
        for (line in h.logs) {
            assertFalse("günlükte IP olmamalı: $line", line.contains("192.168"))
            assertFalse("günlükte ağ adı olmamalı: $line", line.contains("AHBU"))
        }
    }
}
