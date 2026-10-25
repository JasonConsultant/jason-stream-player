import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'download_transfer.dart';

/// Was die Benachrichtigung des Download-Dienstes zeigt.
class DownloadNotice {
  final String title;
  final String text;

  /// 0…1000, -1 = unbestimmt.
  final int progress;

  /// Alle angehalten → „Fortsetzen“ statt „Pause“.
  final bool paused;
  const DownloadNotice(
      {required this.title,
      required this.text,
      this.progress = -1,
      this.paused = false});

  Map<String, Object?> toMap() =>
      {'title': title, 'text': text, 'progress': progress, 'paused': paused};

  @override
  bool operator ==(Object other) =>
      other is DownloadNotice &&
      other.title == title &&
      other.text == text &&
      other.progress == progress &&
      other.paused == paused;

  @override
  int get hashCode => Object.hash(title, text, progress, paused);
}

/// Android-Seite der Downloads (Kotlin: Downloads.kt): Vordergrunddienst
/// mit Benachrichtigung (hält die App bei ausgeschaltetem Bildschirm am
/// Laufen), freier Speicher und Schreiben in einen SAF-Ordner.
class DownloadNative {
  static const _ch = MethodChannel('de.jasonstream.player/dl');

  static bool get available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static final _actions = StreamController<String>.broadcast();
  static bool _handler = false;

  /// Knöpfe der Benachrichtigung: pause | resume | cancel.
  static Stream<String> get actions {
    if (!_handler && available) {
      _handler = true;
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'action') {
          final a = (call.arguments as Map?)?['action'];
          if (a is String) _actions.add(a);
        }
        return null;
      });
    }
    return _actions.stream;
  }

  /// Dienst starten/aktualisieren (null = beenden).
  static Future<void> service(DownloadNotice? n) async {
    if (!available) return;
    try {
      if (n == null) {
        await _ch.invokeMethod('stop');
      } else {
        await _ch.invokeMethod('update', n.toMap());
      }
    } catch (_) {
      // z. B. Start aus dem Hintergrund verboten – Download läuft trotzdem.
    }
  }

  /// Freier Platz am Pfad (StatFs), -1 = unbekannt.
  static Future<int> freeSpace(String path) async {
    if (!available) return -1;
    try {
      return (await _ch.invokeMethod<num>('freeSpace', {'path': path}))
              ?.toInt() ??
          -1;
    } catch (_) {
      return -1;
    }
  }

  /// Datei im SAF-Ordner [tree] (Unterordner [dir], mit `.nomedia`)
  /// anlegen. Liefert die Dokument-Adresse (content://…).
  static Future<String?> safCreate(String tree, String dir, String name,
      {String mime = 'video/x-matroska'}) async {
    if (!available) return null;
    try {
      return await _ch.invokeMethod<String>(
          'safCreate', {'tree': tree, 'dir': dir, 'name': name, 'mime': mime});
    } catch (_) {
      return null;
    }
  }

  /// Größe eines SAF-Dokuments, -1 = nicht vorhanden.
  static Future<int> safSize(String uri) async {
    if (!available) return -1;
    try {
      return (await _ch.invokeMethod<num>('safSize', {'uri': uri}))?.toInt() ??
          -1;
    } catch (_) {
      return -1;
    }
  }

  static Future<bool> safDelete(String uri) async {
    if (!available) return false;
    try {
      return await _ch.invokeMethod<bool>('safDelete', {'uri': uri}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<int> _open(String uri, bool append) async =>
      (await _ch.invokeMethod<num>('safOpen', {'uri': uri, 'append': append}))!
          .toInt();
  static Future<void> _write(int h, Uint8List b) =>
      _ch.invokeMethod('safWrite', {'handle': h, 'bytes': b});
  static Future<void> _close(int h) =>
      _ch.invokeMethod('safClose', {'handle': h});
}

/// Schreibt über den Plattform-Kanal in ein SAF-Dokument (USB-Stick,
/// Netzlaufwerk). Fortsetzen nur, wenn der Anbieter Anhängen kann.
class SafSink implements DownloadSink {
  final String uri;
  int? _handle;
  SafSink(this.uri);

  @override
  Future<int> length() async {
    final n = await DownloadNative.safSize(uri);
    return n < 0 ? 0 : n;
  }

  @override
  Future<void> open({required bool append}) async {
    final h = await DownloadNative._open(uri, append);
    // -1: Anbieter kann nicht anhängen → Download von vorne.
    if (h < 0) throw const NoAppendException();
    _handle = h;
  }

  @override
  Future<void> write(Uint8List data) => DownloadNative._write(_handle!, data);

  @override
  Future<void> close() async {
    final h = _handle;
    _handle = null;
    if (h != null) await DownloadNative._close(h);
  }

  @override
  Future<void> delete() async {
    await DownloadNative.safDelete(uri);
  }
}
