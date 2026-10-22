# FFmpeg-Erweiterung wird von DefaultRenderersFactory per Reflection geladen.
-keep class androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer { <init>(...); }
-keep class androidx.media3.decoder.ffmpeg.FfmpegLibrary { *; }
-keepclasseswithmembernames class * { native <methods>; }
