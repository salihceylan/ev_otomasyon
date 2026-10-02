package com.ahbu.evotomasyon.ev_otomasyon

import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// local_auth (biyometrik giris) bir FragmentActivity ister: FlutterActivity ile
// BiometricPrompt acilamaz ve kimlik dogrulama sessizce basarisiz olur.
class MainActivity : FlutterFragmentActivity() {
    // Pano kurulum agina (internetsiz Wi-Fi) surec baglama koprusu (ev_otomasyon/board_network).
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(BoardNetworkPlugin())
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 12+ (API 31+) siyah SplashScreen beklemesini sonlandır,
        // zengin elektronik devre tasarımının hemen görünmesini sağla
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { splashScreenView ->
                splashScreenView.remove()
            }
        }
    }
}
