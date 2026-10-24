plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// ---------------------------------------------------------------------------
// Versionierung (native TV-App)
//
//   versionCode = 2_000_000 + major * 10_000 + minor * 100 + patch
//
// Die Flutter-Builds liegen weit darunter (1.x: versionCode < 1000, auch mit
// ABI-Aufschlag < 10_000). Dadurch kann die native TV-APK eine bestehende
// Flutter-Installation (gleiche App-ID, gleicher Schlüssel) direkt
// aktualisieren. minor/patch jeweils 0..99. Vorabversionen (alpha/beta) haben
// keinen eigenen Zähler: Für jede verteilte Vorabversion patch erhöhen.
//
// Ausnahme Testreihe 2.0.0-alphaN: vPreBuild zählt die verteilten Alphas
// (alpha1 = 0 → 2020000, alpha2 = 1 → 2020001, alpha3 = 2 → 2020002, alpha4 = 3 → 2020003), damit jede als Update über
// die vorige installiert. Die fertige Version muss dann einen höheren Code
// haben als die letzte Alpha (z. B. als 2.0.1 bzw. vPreBuild weiterzählen).
// ---------------------------------------------------------------------------
val vMajor = 2
val vMinor = 0
val vPatch = 0
val vSuffix = "-alpha4"
val vPreBuild = 3
fun nativeVersionCode(major: Int, minor: Int, patch: Int): Int {
    require(minor in 0..99 && patch in 0..99)
    return 2_000_000 + major * 10_000 + minor * 100 + patch
}

android {
    namespace = "de.jasonstream.player"
    compileSdk = 36

    defaultConfig {
        // EXAKT wie die Flutter-App – sonst kein Update der bestehenden
        // Installation (und keine Datenübernahme).
        applicationId = "de.jasonstream.player"
        minSdk = 26
        targetSdk = 35
        versionCode = nativeVersionCode(vMajor, vMinor, vPatch) + vPreBuild
        versionName = "$vMajor.$vMinor.$vPatch$vSuffix"
        buildConfigField("String", "DEFAULT_LANG", "\"system\"")
        // SHA-256 des Release-Zertifikats (Integritätsprüfung). Leer = aus;
        // nur der Release-Build bekommt den Wert (siehe buildTypes).
        buildConfigField("String", "EXPECTED_SIG", "\"\"")
        // Test-Build (tvtest): eigene App-ID neben der Flutter-App, kein Updater.
        buildConfigField("boolean", "TEST_BUILD", "false")
        buildConfigField("boolean", "UPDATER_ENABLED", "true")
    }

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
            buildConfigField("String", "DEFAULT_LANG", "\"tr\"")
        }
    }

    buildTypes {
        release {
            // Unsigniert: wird nach dem Bauen mit tool/sign_release.sh
            // (Schlüsselwechsel, APK Signature Scheme v3 + lineage) signiert.
            signingConfig = null
            // Fingerabdruck des Release-Schlüssels: -PjspCertSha256=… oder JSP_CERT_SHA256.
            val sig = (project.findProperty("jspCertSha256") as String?) ?: System.getenv("JSP_CERT_SHA256") ?: ""
            buildConfigField("String", "EXPECTED_SIG", "\"$sig\"")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        // Erste Testversion fürs echte Gerät: wie release (R8, nicht debuggable),
        // aber eigene App-ID (läuft neben der Flutter-App), eigener Name/Banner,
        // ohne Selbst-Update und ohne Integritätsprüfung.
        //   ./gradlew :app:assembleStandardTvtest  →  danach tool/sign_release.sh
        create("tvtest") {
            initWith(getByName("release"))
            applicationIdSuffix = ".tvtest"
            versionNameSuffix = "-tvtest"
            matchingFallbacks += listOf("release")
            signingConfig = null
            resValue("string", "app_name", "JSP TV (Test)")
            buildConfigField("String", "EXPECTED_SIG", "\"\"")
            buildConfigField("boolean", "TEST_BUILD", "true")
            buildConfigField("boolean", "UPDATER_ENABLED", "false")
            ndk { abiFilters += listOf("armeabi-v7a", "arm64-v8a") }
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging {
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "META-INF/versions/9/OSGI-INF/MANIFEST.MF")
    }
    testOptions { unitTests.isIncludeAndroidResources = true }
    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    implementation(project(":core"))
    implementation(project(":data"))
    implementation(project(":player"))

    implementation(libs.androidx.core.ktx)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.tv.material)
    implementation(libs.compose.material.icons)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.coroutines.android)

    implementation(libs.media3.exoplayer)
    implementation(libs.media3.exoplayer.hls)
    implementation(libs.media3.datasource.okhttp)

    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    // QR-Code für „Mit dem Handy einrichten“ (nur der Encoder bleibt nach R8).
    implementation(libs.zxing.core)

    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.compose.ui.tooling.preview)

    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)
    // Bildschirmfotos (JVM, Robolectric mit nativer Grafik) – nur mit -Pscreenshots.
    testImplementation(libs.robolectric)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    debugImplementation(libs.compose.ui.test.manifest)
}

// Bildschirmfotos: ./gradlew :app:testStandardDebugUnitTest -Pscreenshots
// (schreibt PNGs nach -PscreenshotDir=… bzw. build/screenshots). Sonst ausgelassen,
// damit `test` ohne Robolectric-Downloads schnell bleibt.
tasks.withType<Test>().configureEach {
    if (project.hasProperty("screenshots")) {
        systemProperty("jsp.screenshots", "true")
        systemProperty("jsp.screenshotDir", (project.findProperty("screenshotDir") as String?) ?: layout.buildDirectory.dir("screenshots").get().asFile.path)
        maxHeapSize = "3g"
        // Maven Central drosselt (429) → Spiegel wie in settings.gradle.kts.
        systemProperty("robolectric.dependency.repo.url", "https://maven-central.storage-download.googleapis.com/maven2")
    } else {
        exclude("**/screenshots/**")
        maxHeapSize = "2g"
    }
    // Fokus-/D-Pad-Tests (Robolectric + Compose) brauchen die Test-Activity aus
    // ui-test-manifest – die gibt es nur in Debug-Varianten.
    if (!name.contains("Debug")) {
        exclude("**/focus/**")
    }
}
