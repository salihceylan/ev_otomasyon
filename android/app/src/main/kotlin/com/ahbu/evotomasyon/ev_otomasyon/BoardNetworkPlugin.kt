package com.ahbu.evotomasyon.ev_otomasyon

import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * `ev_otomasyon/board_network` MethodChannel köprüsü (WP-NET-K). Tasarım notları ve "cihazda doğrulanmadı"
 * uyarısı: BoardNetworkBinder.kt dosya başlığı. Durum makinesi: BoardNetworkCore.kt.
 *
 * KANAL SÖZLEŞMESİ (Dart tarafı WP-NET-D ile BİREBİR; StandardMethodCodec):
 *
 *  Dart -> yerel
 *  - `acquire {subnet: String ("192.168.4.0/24"), timeoutMs: int (varsayılan 8000)}`
 *      -> `{status: String, detail: String?}`; status ∈ bound | already_bound | not_on_board_network |
 *      no_wifi | timeout | permission_denied | unsupported | error.
 *      bound/already_bound: süreç, bağlantı adresleri alt ağda olan Wi-Fi ağına BAĞLANDI. Diğerlerinde süreç
 *      varsayılan ağı DEĞİŞMEDİ. İdempotent; eşzamanlı çağrılar tek isteğe birleşir.
 *      Geçersiz/eksik `subnet` -> `error` + `invalid_subnet`.
 *      `timeout` YEREL taraftan ÜRETİLMEZ (işletim sistemi zaman aşımı `no_wifi` olur; Dart kendi üst sınırında
 *      üretir). Yerel yanıt en geç `timeoutMs` + [BoardNetworkCore.GRACE_MS] sonra gelir. `detail` yalnız tanı
 *      içindir (`BoardNetworkCore.DETAIL_*`; ör. `bind_denied` = ağ canlıyken işletim sistemi bağlamayı reddetti).
 *  - `release` -> `{status: "released" | "not_bound"}`. Her zaman güvenli; bekleyen `acquire`'ı
 *      `{status: "error", detail: "released"}` ile bitirir.
 *  - `status` -> `{bound: bool, sdk: int}`.
 *
 *  Yerel -> Dart
 *  - `networkLost` (argümansız): bağlanan ağ kaybolunca. Yerel taraf ÖNCE kendisi çözer, SONRA bildirir.
 *
 * YAŞAM DÖNGÜSÜ: yalnız uygulama bağlamı tutulur (etkinlik sızdırılmaz). Motor ayrılınca
 * ([onDetachedFromEngine]) ve etkinlik yok edilince ([onDetachedFromActivity]) `release` yapılır, böylece
 * süreç bağlaması Dart'ın `release` çağırmaması halinde bile SIZMAZ.
 *
 * İŞ PARÇACIĞI: MethodChannel çağrıları ana iş parçacığında gelir; sonuçlar da ana iş parçacığında döner.
 * Her sonuç TAM BİR KEZ iletilir ([OnceResult]); çifte `reply` gömme katmanında IllegalStateException
 * ("Reply already submitted") = ÇÖKME demektir.
 */
class BoardNetworkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private var channel: MethodChannel? = null
    private var binder: BoardNetworkBinder? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Olağandışı: aynı örnek yeniden bağlanıyorsa önceki bağlamayı bırak (sızıntı olmasın).
        binder?.release()

        val newChannel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        newChannel.setMethodCallHandler(this)
        channel = newChannel
        // applicationContext: etkinlik bağlamı SIZDIRILMAZ.
        binder = BoardNetworkBinder(binding.applicationContext) { notifyNetworkLost() }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Önce kanalı bırak (artık Dart'a bildirim gitmesin), sonra bağlamayı çöz. release `networkLost` göndermez.
        channel?.setMethodCallHandler(null)
        channel = null
        val current = binder
        binder = null
        current?.release()
    }

    // --- ActivityAware: yalnızca "etkinlik yok edildi" için ---------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = Unit

    // Yapılandırma değişimi geçicidir: bağlama KORUNUR.
    override fun onDetachedFromActivityForConfigChanges() = Unit

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = Unit

    override fun onDetachedFromActivity() {
        val outcome = binder?.release() ?: return
        // Dart hâlâ yaşıyorsa (motor ayrılmadıysa) bağlamanın çözüldüğünü bilmelidir.
        if (outcome.wasBound) notifyNetworkLost()
    }

    // --- MethodChannel -----------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val reply = OnceResult(result)
        try {
            when (call.method) {
                METHOD_ACQUIRE -> handleAcquire(call, reply)
                METHOD_RELEASE -> handleRelease(reply)
                METHOD_STATUS -> handleStatus(reply)
                else -> reply.notImplemented()
            }
        } catch (e: Exception) {
            // ASLA çökertme. OnceResult sayesinde zaten yanıtlanmışsa bu çağrı etkisizdir.
            Log.w(TAG, "${call.method} başarısız: ${e.javaClass.simpleName}")
            val failure = if (call.method == METHOD_STATUS) {
                statusMap(bound = false)
            } else {
                resultMap(BoardNetworkStatus.ERROR, "exception:${e.javaClass.simpleName}")
            }
            reply.success(failure)
        }
    }

    private fun handleAcquire(call: MethodCall, reply: OnceResult) {
        val current = binder
        if (current == null) {
            reply.success(resultMap(BoardNetworkStatus.ERROR, "engine_detached"))
            return
        }
        val subnet = (call.argument<Any>("subnet") as? String)?.let { Ipv4Subnet.parse(it) }
        if (subnet == null) {
            reply.success(resultMap(BoardNetworkStatus.ERROR, "invalid_subnet"))
            return
        }
        // Dart int'i 32 bit'e sığarsa Integer, sığmazsa Long gelir: Number olarak oku.
        val timeoutMs = (call.argument<Any>("timeoutMs") as? Number)?.toLong()
            ?: BoardNetworkCore.DEFAULT_TIMEOUT_MS.toLong()

        current.acquire(subnet, timeoutMs) { result ->
            reply.success(resultMap(result.status, result.detail))
        }
    }

    private fun handleRelease(reply: OnceResult) {
        val outcome = binder?.release()
        val status = if (outcome != null && outcome.released) {
            BoardNetworkStatus.RELEASED
        } else {
            BoardNetworkStatus.NOT_BOUND
        }
        reply.success(mapOf("status" to status))
    }

    private fun handleStatus(reply: OnceResult) {
        reply.success(statusMap(bound = binder?.isBound() == true))
    }

    private fun notifyNetworkLost() {
        val current = channel ?: return
        try {
            current.invokeMethod(METHOD_NETWORK_LOST, null)
        } catch (e: RuntimeException) {
            Log.w(TAG, "networkLost iletilemedi: ${e.javaClass.simpleName}")
        }
    }

    private fun resultMap(status: String, detail: String?): Map<String, Any?> =
        hashMapOf("status" to status, "detail" to detail)

    private fun statusMap(bound: Boolean): Map<String, Any?> =
        hashMapOf("bound" to bound, "sdk" to Build.VERSION.SDK_INT)

    /** [MethodChannel.Result]'ı sarar: ilk yanıttan sonrakiler sessizce yok sayılır (çifte reply = çökme). */
    private class OnceResult(private val delegate: MethodChannel.Result) {
        private val replied = AtomicBoolean(false)

        fun success(value: Any?) {
            if (replied.compareAndSet(false, true)) delegate.success(value)
        }

        fun notImplemented() {
            if (replied.compareAndSet(false, true)) delegate.notImplemented()
        }
    }

    companion object {
        /** Dart tarafıyla paylaşılan kanal adı (StandardMethodCodec). */
        const val CHANNEL_NAME = "ev_otomasyon/board_network"

        private const val METHOD_ACQUIRE = "acquire"
        private const val METHOD_RELEASE = "release"
        private const val METHOD_STATUS = "status"
        private const val METHOD_NETWORK_LOST = "networkLost"
        private const val TAG = "BoardNetwork"
    }
}
