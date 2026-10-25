# Kanal-Einstieg (Flutter-Plugin-Registrierung) und Engine nie entfernen.
-keep class de.jasonstream.exoplayer.** { *; }
# FFmpeg-Erweiterung wird von DefaultRenderersFactory per Reflection geladen.
-keep class androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer { <init>(...); }
-keep class androidx.media3.decoder.ffmpeg.FfmpegLibrary { *; }
-keepclasseswithmembernames class * { native <methods>; }
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
