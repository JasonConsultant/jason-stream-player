import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Eigener Release-Schlüssel (nicht im Quellcode-Archiv!). Pfad über
// android/key.properties oder Umgebungsvariable JSP_KEY_PROPERTIES.
val keyProps = Properties().apply {
    val f = file(System.getenv("JSP_KEY_PROPERTIES") ?: "../key.properties")
    if (f.exists()) FileInputStream(f).use { load(it) }
}
val hasReleaseKey = keyProps.getProperty("storeFile") != null

android {
    namespace = "de.jasonstream.player"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        resValues = true
        buildConfig = true
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {

        applicationId = "de.jasonstream.player"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26 // Android 8 – auch ältere Fernseher
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // SHA-256 des Release-Zertifikats: Die App prüft beim Start, ob sie
        // mit diesem Schlüssel signiert ist (Schutz gegen veränderte Kopien).
        // Leer = Prüfung aus. Nur der Release-Build bekommt den Wert –
        // Debug/Profile werden mit dem Debug-Schlüssel signiert und würden
        // sonst (bei vorhandener key.properties) als „verändert“ gelten.
        buildConfigField("String", "EXPECTED_SIG", "\"\"")
    }

    // Zwei Ausgaben: Standard (Sprache wie das Gerät) und Türkisch
    // (startet auf Türkisch, eigene App-ID → parallel installierbar).
    flavorDimensions += "lang"
    productFlavors {
        create("standard") {
            dimension = "lang"
            resValue("string", "app_name", "Jason Stream Player")
        }
        create("turkish") {
            dimension = "lang"
            applicationIdSuffix = ".tr"
            resValue("string", "app_name", "Jason Stream Player TR")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = if (hasReleaseKey) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
            buildConfigField(
                "String", "EXPECTED_SIG",
                "\"" + (if (hasReleaseKey) (keyProps.getProperty("certSha256") ?: "") else "") + "\""
            )
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
    // Android-TV-Startbildschirm: Vorschau-Kanal „Favoriten“ (TvChannels.kt)
    implementation("androidx.tvprovider:tvprovider:1.0.0")
}
