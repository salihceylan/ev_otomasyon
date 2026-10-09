import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Surum imza anahtari: android/key.properties (+ android/ahbu-release.jks). Ikisi de git'e EKLENMEZ (android/.gitignore).
// Uygulama baglantisi dogrulamasi (sunucu /.well-known/assetlinks.json) bu anahtarin SHA-256 parmak izine baglidir.
// Dosya yoksa (baska bilgisayar / test derlemesi) surum derlemesi gelistirme (debug) anahtariyla imzalanir ve uyari
// yazilir: o APK dagitilmamalidir (karekod uygulamayi acmaz, guncelleme imza uyusmazligi verir).
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) FileInputStream(keystorePropertiesFile).use { load(it) }
}
val hasReleaseKey = keystorePropertiesFile.exists()

android {
    namespace = "com.ahbu.evotomasyon.ev_otomasyon"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications (arka plan alarm bildirimi) Java 8+ API'leri icin desugaring ister.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ahbu.evotomasyon.ev_otomasyon"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { rootProject.file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("UYARI: android/key.properties yok; surum derlemesi GELISTIRME (debug) anahtariyla imzalaniyor. Bu APK dagitilmamali.")
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // JVM birim testleri (src/test): saf mantik (Ipv4Subnet, BoardNetworkCore). 4.12 cevrimdisi Gradle onbelleginde var.
    testImplementation("junit:junit:4.12")
}
