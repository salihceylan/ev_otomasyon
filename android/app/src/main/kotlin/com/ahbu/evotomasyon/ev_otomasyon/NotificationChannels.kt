package com.ahbu.evotomasyon.ev_otomasyon

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build

// Bildirim kanallari (Faz 2 tasarimi F2.C.5). Sunucu push'u `channel_id` ile bu kanallara yazar (CONTRACTS §2.5);
// kanal yoksa Android bildirimi varsayilan kanala dusurur ya da hic gostermez. Olusturma idempotenttir: her acilista
// cagrilir, var olan kanalin kullanici ayarlarini (ses, titresim, rahatsiz etme) DEGISTIRMEZ. FCM ag gecidi yokken de
// zararsizdir ve gelecekteki ag gecidi icin kanallari hazir eder. Yeni bagimlilik yok (yalniz NotificationManager).
object NotificationChannels {
    data class Spec(
        val id: String,
        val name: String,
        val description: String,
        val importance: Int,
        val visibility: Int,
        val alarmSound: Boolean,
    )

    // Kullaniciya gorunen adlar Turkce; kimlikler sunucu sozlesmesiyle birebir ayni.
    val specs: List<Spec> = listOf(
        Spec(
            id = "safety_alarm",
            name = "Güvenlik alarmları",
            description = "Su baskını, gaz, duman ve hırsız alarmları.",
            importance = NotificationManager.IMPORTANCE_HIGH,
            visibility = Notification.VISIBILITY_PUBLIC,
            alarmSound = true,
        ),
        Spec(
            id = "safety_info",
            name = "Güvenlik bilgileri",
            description = "Alarm doğrulanamadı, güvenlik ayarı değişti gibi bilgiler.",
            importance = NotificationManager.IMPORTANCE_DEFAULT,
            visibility = Notification.VISIBILITY_PRIVATE,
            alarmSound = false,
        ),
        Spec(
            id = "peace_reminder",
            name = "Gece hatırlatması",
            description = "Gece açık kalan lamba ve panjur hatırlatması.",
            importance = NotificationManager.IMPORTANCE_DEFAULT,
            visibility = Notification.VISIBILITY_PRIVATE,
            alarmSound = false,
        ),
    )

    private val alarmVibration = longArrayOf(0, 800, 400, 800, 400, 800)

    fun ensure(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        for (spec in specs) {
            try {
                val channel = NotificationChannel(spec.id, spec.name, spec.importance)
                channel.description = spec.description
                channel.lockscreenVisibility = spec.visibility
                if (spec.alarmSound) {
                    val attributes = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                    channel.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM), attributes)
                    channel.enableVibration(true)
                    channel.vibrationPattern = alarmVibration
                    // Yalniz kullanici "Rahatsiz Etmeyin"i asma iznini verirse etkili olur.
                    channel.setBypassDnd(true)
                }
                manager.createNotificationChannel(channel)
            } catch (e: Exception) {
                // Kanal olusturulamadi: uygulama acilisi bozulmaz (bildirim varsayilan kanala duser).
            }
        }
    }
}
