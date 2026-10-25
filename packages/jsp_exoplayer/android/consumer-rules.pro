# Kanal-Einstieg (Flutter-Plugin-Registrierung) und Engine nie entfernen.
-keep class de.jasonstream.exoplayer.** { *; }
# FFmpeg-Erweiterung wird von DefaultRenderersFactory per Reflection geladen.
-keep class androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer { <init>(...); }
-keep class androidx.media3.decoder.ffmpeg.FfmpegLibrary { *; }
-keepclasseswithmembernames class * { native <methods>; }
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# Netzlaufwerk (smbj): Ereignisbus MBassador ruft @Handler-Methoden per
# Reflection auf; SLF4J ohne Logger-Bindung (No-Op), optionale Teile fehlen.
-keep class com.hierynomus.** { *; }
-keep class net.engio.mbassy.** { *; }
-keepclassmembers class * { @net.engio.mbassy.listener.Handler *; }
-dontwarn org.slf4j.**
-dontwarn javax.el.**
-dontwarn net.engio.mbassy.**
-dontwarn com.hierynomus.**
-dontwarn javax.security.auth.kerberos.**
-dontwarn org.ietf.jgss.**
