import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../downloads/download_transfer.dart';

/// Netzlaufwerk (SMB 2/3) als Speicherort für Aufnahmen und Downloads
/// (ab 2.3). Die Arbeit macht das Android-Plugin (jsp_exoplayer,
/// SmbBridge.kt mit smbj); hier: Einstellungen, Kanal, Fehlertexte, Sink.
///
/// Zugangsdaten liegen verschlüsselt im SecretStore (Storage.smbConfig) und
/// gehen nur über den Plattform-Kanal an die Bibliothek – nie in Pfade,
/// Dateinamen, Protokolle oder Fehlertexte.
class SmbConfig {
  final String server;
  final String share;

  /// Basisordner in der Freigabe (z. B. „IPTV“), leer = Wurzel.
  final String path;
  final String user;
  final String password;
  final String domain;

  const SmbConfig({
    required this.server,
    required this.share,
    this.path = '',
    this.user = '',
    this.password = '',
    this.domain = '',
  });

  Map<String, Object> toJson() => {
        'server': server.trim(),
        'share': share.trim(),
        'path': path.trim(),
        'user': user.trim(),
        'password': password,
        'domain': domain.trim(),
      };

  static SmbConfig? fromJson(Object? j) {
    if (j is! Map) return null;
    String s(String k) => j[k] is String ? j[k] as String : '';
    final c = SmbConfig(
        server: s('server'),
        share: s('share'),
        path: s('path'),
        user: s('user'),
        password: s('password'),
        domain: s('domain'));
    return c.problem == null ? c : null;
  }

  /// Fehlende/ungültige Angabe (Text) oder null.
  String? get problem {
    final sv = server.trim();
    if (sv.isEmpty) return tr('Server fehlt');
    if (RegExp(r'[\s@]').hasMatch(sv.replaceFirst(RegExp(r'^smb://'), ''))) {
      return tr('Server ungültig (nur Name oder IP-Adresse, ohne Benutzer)');
    }
    if (share.trim().replaceAll(RegExp(r'[\\/]'), '').isEmpty) {
      return tr('Freigabe fehlt');
    }
    final parts = path.replaceAll('\\', '/').split('/');
    if (parts.contains('..')) return tr('Pfad darf kein „..“ enthalten');
    return null;
  }

  /// Anzeige: \\server\freigabe\pfad (ohne Zugangsdaten).
  String get display {
    final host = server
        .trim()
        .replaceFirst(RegExp(r'^smb://'), '')
        .replaceAll(RegExp(r'^[\\/]+'), '')
        .split(RegExp(r'[\\/]'))
        .first;
    final sh = share.trim().replaceAll(RegExp(r'^[\\/]+|[\\/]+$'), '');
    final p = path.trim().replaceAll('/', '\\').replaceAll(RegExp(r'^\\+|\\+$'), '');
    return '\\\\$host\\$sh${p.isEmpty ? '' : '\\$p'}';
  }

  /// Gespeicherte Datei-Adresse `smb://server/freigabe/pfad/<rel>` (ohne
  /// Zugangsdaten) – für Download-Einträge/Aufnahmen.
  String uriFor(String rel) {
    final host = display.substring(2).split('\\').first;
    final sh = share.trim().replaceAll(RegExp(r'^[\\/]+|[\\/]+$'), '');
    final p = path.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
    final r = rel.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
    return 'smb://$host/$sh/${p.isEmpty ? '' : '$p/'}$r';
  }

  /// Relativer Pfad (unter dem Basisordner) einer [uriFor]-Adresse; null,
  /// wenn sie nicht zu dieser Konfiguration gehört.
  String? relOf(String uri) {
    final prefix = uriFor('');
    if (!uri.startsWith(prefix)) return null;
    final r = uri.substring(prefix.length);
    if (r.split('/').contains('..')) return null;
    return r;
  }

  @override
  bool operator ==(Object other) =>
      other is SmbConfig && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Fehler vom Netzlaufwerk (Code aus SmbLogic.classify in Kotlin).
class SmbException implements SinkError {
  /// auth, host, share, path, denied, full, smb1, timeout, io, unavailable
  final String code;
  const SmbException(this.code);

  String get message => smbErrorText(code);

  /// Code für Downloads (`nas:<code>`).
  @override
  String get sinkCode => 'nas:$code';

  @override
  String toString() => 'SmbException($code)';
}

String smbErrorText(String code) => switch (code) {
      'auth' => tr('Netzlaufwerk: Benutzer oder Passwort falsch'),
      'host' => tr('Netzlaufwerk nicht erreichbar (Server aus oder anderes Netz?)'),
      'share' => tr('Netzlaufwerk: Freigabe nicht gefunden'),
      'path' => tr('Netzlaufwerk: Ordner nicht gefunden'),
      'denied' => tr('Netzlaufwerk: keine Schreibrechte'),
      'full' => tr('Netzlaufwerk ist voll'),
      'smb1' => tr('Server spricht nur SMB1 – bitte SMB2/3 am NAS einschalten'),
      'timeout' => tr('Netzlaufwerk antwortet nicht (Zeitüberschreitung)'),
      'unavailable' => tr('Netzlaufwerk wird auf diesem Gerät nicht unterstützt'),
      _ => tr('Netzlaufwerk: Übertragung unterbrochen'),
    };

/// Ergebnis von [Smb.test].
typedef SmbTestResult = ({int free, int total});

/// Plattform-Kanal „de.jasonstream/smb“.
class Smb {
  Smb._();
  static const channel = MethodChannel('de.jasonstream/smb');

  /// Tests: Kanal auch außerhalb von Android benutzen (Fake-Handler).
  @visibleForTesting
  static bool forceAvailable = false;

  /// Aktueller Zugang (von Storage gesetzt) – für Stellen ohne Zugriff auf
  /// den Speicher (Offline-Wiedergabe, „Datei vorhanden?“).
  static SmbConfig? current;

  static bool get available =>
      forceAvailable ||
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static Future<T?> _call<T>(String method, Map<String, Object?> args) async {
    if (!available) throw const SmbException('unavailable');
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw SmbException(e.code);
    } on MissingPluginException {
      throw const SmbException('unavailable');
    }
  }

  static Map<String, Object?> _a(SmbConfig c, [Map<String, Object?>? more]) =>
      {'cfg': c.toJson(), ...?more};

  /// Verbindung prüfen (legt den Basisordner an). Wirft [SmbException].
  static Future<SmbTestResult> test(SmbConfig c) async {
    final m = await _call<Map<dynamic, dynamic>>('test', _a(c)) ?? const {};
    return (
      free: (m['free'] as num?)?.toInt() ?? -1,
      total: (m['total'] as num?)?.toInt() ?? -1,
    );
  }

  /// Freier Platz in Bytes (-1 = unbekannt). Wirft bei Nichterreichbarkeit.
  static Future<int> free(SmbConfig c) async =>
      (await _call<num>('free', _a(c)))?.toInt() ?? -1;

  /// Größe einer Datei, -1 = nicht vorhanden.
  static Future<int> size(SmbConfig c, String rel) async =>
      (await _call<num>('size', _a(c, {'rel': rel})))?.toInt() ?? -1;

  static Future<bool> delete(SmbConfig c, String rel) async =>
      await _call<bool>('delete', _a(c, {'rel': rel})) ?? false;

  static Future<List<({String name, int size, DateTime modified})>> list(
      SmbConfig c, String dir) async {
    final l = await _call<List<dynamic>>('list', _a(c, {'rel': dir})) ?? const [];
    return [
      for (final e in l.whereType<Map>())
        (
          name: '${e['name']}',
          size: (e['size'] as num?)?.toInt() ?? 0,
          modified: DateTime.fromMillisecondsSinceEpoch(
              (e['modified'] as num?)?.toInt() ?? 0),
        ),
    ];
  }

  /// Lokale Datei aufs NAS kopieren (Größe wird geprüft). Liefert Bytes.
  static Future<int> upload(SmbConfig c, String localPath, String rel) async =>
      (await _call<num>('upload', _a(c, {'local': localPath, 'rel': rel})))
          ?.toInt() ??
      -1;

  /// Adresse zum Abspielen (lokaler Proxy auf 127.0.0.1 mit Zufallstoken).
  static Future<String> serve(SmbConfig c, String rel) async {
    final u = await _call<String>('serve', _a(c, {'rel': rel}));
    if (u == null) throw const SmbException('io');
    return u;
  }

  static Future<int> _open(SmbConfig c, String rel, bool append) async =>
      (await _call<num>('open', _a(c, {'rel': rel, 'append': append})))!
          .toInt();
  static Future<void> _write(int h, Uint8List b) =>
      _call<void>('write', {'handle': h, 'bytes': b});
  static Future<void> _close(int h) => _call<void>('close', {'handle': h});
}

/// Schreibt einen Download direkt aufs NAS (Fortsetzen: an das Dateiende
/// anhängen, wie bei lokalen Dateien). Fällt das NAS aus, wirft jeder
/// Schritt [SmbException] – der Download pausiert mit Hinweis, es gibt
/// keinen stillen Wechsel in den App-Ordner.
class SmbSink implements DownloadSink {
  final SmbConfig config;
  final String rel;
  int? _handle;
  SmbSink(this.config, this.rel);

  @override
  Future<int> length() async {
    final n = await Smb.size(config, rel);
    return n < 0 ? 0 : n;
  }

  @override
  Future<void> open({required bool append}) async {
    _handle = await Smb._open(config, rel, append);
  }

  @override
  Future<void> write(Uint8List data) => Smb._write(_handle!, data);

  @override
  Future<void> close() async {
    final h = _handle;
    _handle = null;
    if (h != null) {
      try {
        await Smb._close(h);
      } on SmbException {
        // Verbindung weg – die Datei ist bis zum letzten Schreiben gültig.
      }
    }
  }

  @override
  Future<void> delete() async {
    await Smb.delete(config, rel);
  }
}
