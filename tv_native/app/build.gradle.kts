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
// ---------------------------------------------------------------------------
val vMajor = 2
val vMinor = 0
val vPatch = 0
val vSuffix = "-alpha1"
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
        versionCode = nativeVersionCode(vMajor, vMinor, vPatch)
        versionName = "$vMajor.$vMinor.$vPatch$vSuffix"
        buildConfigField("String", "DEFAULT_LANG", "\"system\"")
        // SHA-256 des Release-Zertifikats (Integritätsprüfung). Leer = aus;
        // nur der Release-Build bekommt den Wert (siehe buildTypes).
        buildConfigField("String", "EXPECTED_SIG", "\"\"")
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
    }
}
