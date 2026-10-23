import 'dart:convert';

import 'package:flutter/services.dart';

import '../data/repository.dart' show RepositoryException;

import '../data/net.dart';
import '../l10n/strings.dart';
import 'platform_info.dart';
import 'updater_stub.dart' if (dart.library.io) 'updater_io.dart';

/// Neue Version aus den GitHub-Releases.
class UpdateInfo {
  final String version;
  final String notes;
  final Uri apkUrl;
  final int size;
  const UpdateInfo(this.version, this.notes, this.apkUrl, this.size);
}

/// Selbst-Update über GitHub-Releases – wie der Play Store, nur ohne Store:
/// Die App fragt die neueste Version ab, lädt die passende APK und öffnet
/// den Android-Installer. Android installiert sie nur, wenn sie mit dem
/// gleichen Schlüssel signiert ist.
class Updater {
  static const _ch = MethodChannel('de.jasonstream.player/platform');

  /// „besitzer/projekt“ – wird beim Bauen gesetzt (--dart-define=UPDATE_REPO=…).
  static const repo = String.fromEnvironment('UPDATE_REPO');

  static bool get enabled => repo.isNotEmpty && PlatformInfo.isAndroid;

  static Future<Map<String, dynamic>> _info() async =>
      await _ch.invokeMapMethod<String, dynamic>('appInfo') ?? const {};

  static Future<String> currentVersion() async {
    if (!PlatformInfo.isAndroid) return '';
    try {
      return (await _info())['version'] as String? ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Hersteller und Modell (z. B. „NVIDIA SHIELD Android TV“), sonst ''.
  static Future<String> deviceModel() async {
    if (!PlatformInfo.isAndroid) return '';
    try {
      return (await _info())['model'] as String? ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 0.9.10 > 0.9.4 (Zahlen, nicht Text vergleichen).
  static int compareVersions(String a, String b) {
    List<int> p(String v) => v
        .replaceFirst(RegExp('^v'), '')
        .split('+')
        .first
        .split('.')
        .map((x) => int.tryParse(x) ?? 0)
        .toList();
    final x = p(a), y = p(b);
    for (var i = 0; i < 4; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d.sign;
    }
    return 0;
  }

  /// Passender Dateiname: normale oder TR-App, 64- oder 32-Bit – bzw. die
  /// TV-APK (beide Architekturen), wenn eine solche installiert ist.
  /// Die Split-APKs haben einen um 1000/2000 erhöhten versionCode; nach
  /// einem Split-Update ließe sich keine TV-APK mehr darüber installieren.
  static String assetFor(
      {required String package,
      required List<String> abis,
      required String version,
      bool universal = false}) {
    final tr = package.endsWith('.tr');
    if (universal) return 'JasonStreamPlayer${tr ? '_TR' : ''}_TV_$version.apk';
    final abi = abis.contains('arm64-v8a') ? 'arm64' : 'arm32';
    return 'JasonStreamPlayer${tr ? '_TR' : ''}_${version}_$abi.apk';
  }

  /// Neuere Version vorhanden? null = aktuell (oder nicht prüfbar).
  static Future<UpdateInfo?> check() async {
    if (!enabled) return null;
    final info = await _info();
    final current = info['version'] as String? ?? '0';
    final Uint8List bytes;
    try {
      bytes = await Net.get(
        Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
        maxBytes: 1024 * 1024,
        headers: const {'Accept': 'application/vnd.github+json'},
      );
    } on RepositoryException catch (e) {
      // Noch keine Veröffentlichung im Projekt → einfach „aktuell“.
      if ('$e'.contains('404')) return null;
      // GitHub begrenzt anonyme Abfragen (60/Std.) → nicht „Zugangsdaten“.
      if ('$e'.contains('403') || '$e'.contains('429')) {
        throw RepositoryException(
            tr('Update-Server gerade ausgelastet – bitte später erneut versuchen.'));
      }
      rethrow;
    }
    final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final latest = (j['tag_name'] as String? ?? '').replaceFirst('v', '');
    if (latest.isEmpty || compareVersions(latest, current) <= 0) return null;
    final want = assetFor(
        package: info['package'] as String? ?? '',
        abis: (info['abis'] as List?)?.cast<String>() ?? const [],
        version: latest,
        universal: info['universal'] == true);
    for (final a in (j['assets'] as List? ?? const [])) {
      if (a is Map && a['name'] == want) {
        final url = Uri.parse(a['browser_download_url'] as String);
        if (url.scheme != 'https') return null;
        return UpdateInfo(latest, (j['body'] as String? ?? '').trim(), url,
            (a['size'] as num?)?.toInt() ?? 0);
      }
    }
    return null;
  }

  /// Herunterladen und Installer öffnen. false = Erlaubnis
  /// „Unbekannte Apps installieren“ fehlt (Einstellungsseite wurde geöffnet).
  static Future<bool> downloadAndInstall(UpdateInfo u,
      {void Function(int received, int? total)? onProgress}) async {
    final info = await _info();
    if (info['canInstall'] != true) {
      await _ch.invokeMethod('requestInstallPermission');
      return false;
    }
    final bytes = await Net.get(u.apkUrl,
        maxBytes: 200 * 1024 * 1024,
        timeout: const Duration(seconds: 60),
        onProgress: onProgress);
    final dir = await _ch.invokeMethod<String>('updateDir');
    final path = '$dir/update.apk';
    await writeUpdateFile(path, bytes);
    return await _ch.invokeMethod<bool>('installApk', {'path': path}) ?? false;
  }
}
