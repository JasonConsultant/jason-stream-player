# Plugin-Code, der per Kanal/JNI aus Dart aufgerufen wird, nie entfernen
# oder umbenennen – sonst NoSuchMethodError zur Laufzeit.
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class com.alexmercerind.** { *; }
-keep class de.jasonstream.player.** { *; }
-keep class com.github.dart_lang.jni.** { *; }
-dontwarn com.github.dart_lang.jni.**
