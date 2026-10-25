// Media3 ExoPlayer als Wiedergabe-Engine (nur Android). Versionen wie in der
// nativen TV-App (tv_native/gradle/libs.versions.toml).
group = "de.jasonstream.exoplayer"
version = "1.0"

plugins {
    id("com.android.library")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

val media3 = "1.8.0"
val ffmpegDecoder = "1.8.0+1"
// Google Cast (Default Media Receiver) über das Android-Framework.
val castFramework = "22.1.0"
val mediarouter = "1.8.0-beta01"
val smbj = "0.14.0"

android {
    namespace = "de.jasonstream.exoplayer"
    compileSdk = flutter.compileSdkVersion

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main").java.srcDirs("src/main/kotlin")
        getByName("test").java.srcDirs("src/test/kotlin")
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    dependencies {
        implementation("androidx.media3:media3-exoplayer:$media3")
        implementation("androidx.media3:media3-exoplayer-hls:$media3")
        implementation("androidx.media3:media3-exoplayer-dash:$media3")
        implementation("androidx.media3:media3-datasource-okhttp:$media3")
        // Software-Ton (MP2/AC3/E-AC3/DTS/TrueHD …) für Geräte ohne passende
        // Hardware-Dekoder; DefaultRenderersFactory lädt ihn per Reflection.
        implementation("org.jellyfin.media3:media3-ffmpeg-decoder:$ffmpegDecoder")
        implementation("com.google.android.gms:play-services-cast-framework:$castFramework")
        implementation("androidx.mediarouter:mediarouter:$mediarouter")
        // Netzlaufwerk: SMB 2/3 (Apache-2.0; zieht BouncyCastle, SLF4J-API,
        // MBassador, asn-one nach – alle MIT/Apache, siehe Lizenzseite).
        implementation("com.hierynomus:smbj:$smbj")
        testImplementation("junit:junit:4.13.2")
    }
}
