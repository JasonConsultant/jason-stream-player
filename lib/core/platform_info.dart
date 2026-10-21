import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Plattform-Infos und native Hilfsfunktionen (TV-Erkennung, Bild-in-Bild).
class PlatformInfo {
  static const _channel = MethodChannel('de.jasonstream.player/platform');
  static bool? _cached;

  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Web-Vorschau: Startparameter aus der URL (?tv=1&screen=guide&demo=1).
  static Map<String, String> get launchParams =>
      kIsWeb ? Uri.base.queryParameters : const {};

  /// Android: Startaktion aus einer Benachrichtigung (einmalig), z. B.
  /// `{action: play, channel: id, portal: id}`. Sonst null.
  static Future<Map<String, String>?> takeLaunchAction() async {
    if (!isAndroid) return null;
    try {
      final m = await _channel.invokeMapMethod<String, String>('takeLaunchAction');
      return m;
    } on Object {
      return null;
    }
  }

  /// Android: [onAvailable] wird aufgerufen, wenn die laufende App über eine
  /// Benachrichtigung erneut geöffnet wurde (dann [takeLaunchAction] abfragen).
  static void listenLaunchActions(void Function() onAvailable) {
    if (!isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'launchActionAvailable') onAvailable();
      return null;
    });
  }

  /// Selbstprüfung (Android): Signatur, Root, Debugger.
  static Future<({bool signatureOk, bool rooted, bool debugger})>
      integrity() async {
    if (!isAndroid) return (signatureOk: true, rooted: false, debugger: false);
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('integrity') ??
          const {};
      return (
        signatureOk: m['signatureOk'] != false,
        rooted: m['rooted'] == true,
        debugger: m['debugger'] == true,
      );
    } on Object {
      return (signatureOk: true, rooted: false, debugger: false);
    }
  }

  /// M3U-Datei vom Gerät wählen; wird in den App-Ordner kopiert.
  /// Liefert (Pfad als file://-Adresse, Dateiname) oder null (abgebrochen).
  static Future<({String url, String? name})?> pickPlaylist() async {
    if (!isAndroid) return null;
    final m = await _channel.invokeMapMethod<String, dynamic>('pickPlaylist');
    if (m == null) return null;
    return (
      url: Uri.file(m['path'] as String).toString(),
      name: m['name'] as String?,
    );
  }

  /// Datei über den System-Speicherdialog ablegen (z. B. Sicherung).
  /// true = gespeichert, false = abgebrochen. Wirft bei Fehlern.
  static Future<bool> saveFile({
    required String name,
    required String mime,
    required Uint8List bytes,
  }) async {
    if (!isAndroid) return false;
    return await _channel.invokeMethod<bool>(
            'saveFile', {'name': name, 'mime': mime, 'bytes': bytes}) ??
        false;
  }

  /// Datei über den System-Öffnendialog einlesen (max. 50 MB).
  /// Liefert (Inhalt, Dateiname) oder null (abgebrochen). Wirft bei Fehlern.
  static Future<({Uint8List bytes, String? name})?> openFile() async {
    if (!isAndroid) return null;
    final m = await _channel.invokeMapMethod<String, dynamic>('openFile');
    if (m == null) return null;
    return (bytes: m['bytes'] as Uint8List, name: m['name'] as String?);
  }

  static Future<bool> isTv() async {
    if (_cached != null) return _cached!;
    if (kIsWeb) return _cached = launchParams['tv'] == '1';
    if (!isAndroid) return _cached = false;
    try {
      _cached = await _channel.invokeMethod<bool>('isTv') ?? false;
    } on Object {
      _cached = false;
    }
    return _cached!;
  }

  /// Android: Bild-in-Bild starten. Liefert false, wenn nicht unterstützt.
  static Future<bool> enterPip({int width = 16, int height = 9}) async {
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
              'enterPip', {'w': width, 'h': height}) ??
          false;
    } on Object {
      return false;
    }
  }

  /// Android: Bildschirmfotos/Aufnahmen für dieses Fenster sperren
  /// (FLAG_SECURE), z. B. während Zugangsdaten eingegeben werden.
  static Future<void> setSecureScreen(bool on) async {
    if (!isAndroid) return;
    try {
      await _channel.invokeMethod('setSecure', {'on': on});
    } on Object {
      // ignorieren
    }
  }

  /// Android: automatisch in PiP wechseln, wenn der Nutzer die App verlässt.
  /// Bildwiederholrate des Fernsehers an [fps] anpassen; 0 = zurück auf
  /// die normale Einstellung.
  static Future<void> setFrameRate(double fps) async {
    if (!isAndroid) return;
    try {
      await _channel.invokeMethod('setFrameRate', {'fps': fps});
    } on Object {
      // ignorieren – nicht jedes Gerät kann umschalten
    }
  }

  /// Arbeitsspeicher (Android): frei/gesamt in Bytes und ob das Gerät als
  /// „wenig RAM“ gilt. null = unbekannt (andere Plattform, alte App-Version).
  static Future<({int avail, int total, bool lowRam})?> memoryInfo() async {
    if (!isAndroid) return null;
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('memInfo');
      if (m == null) return null;
      final avail = (m['avail'] as num?)?.toInt() ?? 0;
      final total = (m['total'] as num?)?.toInt() ?? 0;
      if (avail <= 0 || total <= 0) return null;
      return (avail: avail, total: total, lowRam: m['lowRam'] == true);
    } on Object {
      return null;
    }
  }

  static Future<void> setAutoPip(bool enabled) async {
    if (!isAndroid) return;
    try {
      await _channel.invokeMethod('setAutoPip', {'enabled': enabled});
    } on Object {
      // ignorieren
    }
  }
}
