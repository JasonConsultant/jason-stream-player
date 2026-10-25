import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/downloads/download_models.dart';
import 'package:jason_stream_player/data/downloads/download_rules.dart';
import 'package:jason_stream_player/data/downloads/download_transfer.dart';
import 'package:jason_stream_player/data/downloads/local_playback.dart';
import 'package:jason_stream_player/data/recordings/recordings.dart';
import 'package:jason_stream_player/data/smb/smb.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/downloads/download_button.dart'
    show downloadErrorText;
import 'package:jason_stream_player/ui/settings/smb_settings_screen.dart';
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';

/// 2.3 Netzlaufwerk (SMB): Konfiguration, Fake-Kanal (Fehlerfälle), Download
/// direkt aufs NAS inkl. Fortsetzen und Ausfall (kein stiller Rückfall),
/// Aufnahmen (Prüfung vor dem Start, Verschieben nach dem Ende),
/// Wiedergabe über den Proxy, Einstellungen.
///
/// `TV_SHOTS=ordner`: phone_smb_settings.png, tv_smb_settings.png.

/// In-Memory-NAS hinter dem Plattform-Kanal.
class FakeNas {
  final files = <String, BytesBuilder>{};
  final calls = <String>[];
  String? failWith; // Code für alle folgenden Aufrufe (z. B. 'host')
  int failAfterWrites = -1;
  int writes = 0;
  final handles = <int, String>{};
  var next = 1;
  Map<String, Object?>? lastCfg;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    final a = (call.arguments as Map).cast<String, Object?>();
    if (a['cfg'] != null) lastCfg = (a['cfg'] as Map).cast<String, Object?>();
    if (failWith != null) {
      throw PlatformException(code: failWith!, message: 'STATUS_X');
    }
    final rel = a['rel'] as String? ?? '';
    switch (call.method) {
      case 'test':
        return {'free': 500 * 1024 * 1024 * 1024, 'total': 1 << 42};
      case 'free':
        return 500 * 1024 * 1024 * 1024;
      case 'size':
        return files[rel]?.length ?? -1;
      case 'open':
        if (a['append'] != true || !files.containsKey(rel)) {
          files[rel] = BytesBuilder();
        }
        handles[next] = rel;
        return next++;
      case 'write':
        writes++;
        if (failAfterWrites >= 0 && writes > failAfterWrites) {
          failWith = 'host';
          throw PlatformException(code: 'host');
        }
        files[handles[a['handle']]]!.add(a['bytes'] as Uint8List);
        return null;
      case 'close':
        handles.remove(a['handle']);
        return null;
      case 'delete':
        return files.remove(rel) != null;
      case 'list':
        return [
          for (final e in files.entries)
            if (e.key.startsWith('$rel/'))
              {
                'name': e.key.substring(rel.length + 1),
                'size': e.value.length,
                'modified': 1700000000000
              },
        ];
      case 'upload':
        files[rel] = BytesBuilder()..add(Uint8List(1234));
        return 1234;
      case 'serve':
        return 'http://127.0.0.1:4711/tok/${Uri.encodeComponent(rel)}';
    }
    throw MissingPluginException();
  }
}

const _cfg = SmbConfig(
    server: 'nas.local',
    share: 'video',
    path: 'IPTV',
    user: 'jason',
    password: 'Geheim!42');

late FakeNas nas;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await loadAppFonts();
  });

  setUp(() {
    nas = FakeNas();
    Smb.forceAvailable = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(Smb.channel, nas.handle);
  });
  tearDown(() {
    Smb.forceAvailable = false;
    Smb.current = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(Smb.channel, null);
  });

  group('Konfiguration', () {
    test('Prüfung, Anzeige, Adressen ohne Zugangsdaten', () {
      expect(_cfg.problem, isNull);
      expect(_cfg.display, r'\\nas.local\video\IPTV');
      final u = _cfg.uriFor('Downloads/Film.mkv');
      expect(u, 'smb://nas.local/video/IPTV/Downloads/Film.mkv');
      expect(u, isNot(contains('jason')));
      expect(u, isNot(contains('Geheim')));
      expect(_cfg.relOf(u), 'Downloads/Film.mkv');
      expect(_cfg.relOf('smb://other/video/IPTV/x'), isNull);
      expect(_cfg.relOf('smb://nas.local/video/IPTV/../etc'), isNull);
      expect(const SmbConfig(server: '', share: 'x').problem, 'Server fehlt');
      expect(const SmbConfig(server: 'nas', share: '').problem, 'Freigabe fehlt');
      expect(const SmbConfig(server: 'u@nas', share: 'v').problem, isNotNull);
      expect(const SmbConfig(server: 'nas', share: 'v', path: 'a/../b').problem,
          isNotNull);
      expect(SmbConfig.fromJson(_cfg.toJson()), _cfg);
    });

    test('Zugang verschlüsselt gespeichert, nicht in der Sicherung', () async {
      SharedPreferences.setMockInitialValues({});
      final st = await Storage.open(store: PreviewSecretStore());
      await st.setSmbConfig(_cfg);
      final prefs = await SharedPreferences.getInstance();
      final plain = prefs.getKeys().map((k) => '$k=${prefs.get(k)}').join();
      expect(plain, isNot(contains('Geheim!42')));
      expect(plain, isNot(contains('nas.local')));
      expect(jsonEncode(st.exportAll()), isNot(contains('Geheim!42')));
      final again = await Storage.open(store: PreviewSecretStore());
      expect(again.smbConfig(), _cfg);
      expect(Smb.current, _cfg);
    });
  });

  group('Kanal (Fake)', () {
    test('Test liefert freien Platz; Fehler als verständlicher Text',
        () async {
      final r = await Smb.test(_cfg);
      expect(r.free, 500 * 1024 * 1024 * 1024);
      expect(nas.lastCfg!['password'], 'Geheim!42');
      for (final (code, text) in [
        ('auth', 'Netzlaufwerk: Benutzer oder Passwort falsch'),
        ('host', 'Netzlaufwerk nicht erreichbar (Server aus oder anderes Netz?)'),
        ('share', 'Netzlaufwerk: Freigabe nicht gefunden'),
        ('smb1', 'Server spricht nur SMB1 – bitte SMB2/3 am NAS einschalten'),
        ('full', 'Netzlaufwerk ist voll'),
        ('denied', 'Netzlaufwerk: keine Schreibrechte'),
        ('timeout', 'Netzlaufwerk antwortet nicht (Zeitüberschreitung)'),
      ]) {
        nas.failWith = code;
        await expectLater(
            Smb.test(_cfg),
            throwsA(isA<SmbException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.message, 'message', text)));
      }
    });

    test('Ohne Plugin: „nicht unterstützt“', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(Smb.channel, null);
      await expectLater(
          Smb.free(_cfg),
          throwsA(isA<SmbException>()
              .having((e) => e.code, 'code', 'unavailable')));
    });
  });

  group('Download direkt aufs NAS', () {
    final body = Uint8List.fromList(List.generate(300000, (i) => i % 251));
    http.Client server({bool ranges = true}) => MockClient((req) async {
          final range = req.headers['range'];
          if (ranges && range != null) {
            final start = int.parse(range.substring(6, range.indexOf('-')));
            return http.Response.bytes(body.sublist(start), 206, headers: {
              'content-range': 'bytes $start-${body.length - 1}/${body.length}',
              'content-length': '${body.length - start}',
            });
          }
          return http.Response.bytes(body, 200,
              headers: {'content-length': '${body.length}'});
        });

    test('vollständig, dann Ausfall mittendrin → nas:host, kein Rückfall',
        () async {
      final sink = SmbSink(_cfg, 'Downloads/Film.mkv');
      final ok = await DownloadTransfer(server(), blockSize: 64 * 1024).run(
          url: 'http://srv/f.mkv', sink: sink, token: TransferToken());
      expect(ok.end, TransferEnd.complete);
      expect(nas.files['Downloads/Film.mkv']!.toBytes(), body);

      // Neuer Download, NAS fällt beim Schreiben aus.
      nas.failAfterWrites = nas.writes;
      final sink2 = SmbSink(_cfg, 'Downloads/Film2.mkv');
      final bad = await DownloadTransfer(server(), blockSize: 64 * 1024).run(
          url: 'http://srv/f.mkv', sink: sink2, token: TransferToken());
      expect(bad.end, TransferEnd.failed);
      expect(bad.error, 'nas:host');
      expect(isPermanentDownloadError(bad.error!), isTrue,
          reason: 'nicht automatisch wiederholen/ausweichen');
      expect(downloadErrorText(bad.error), contains('Netzlaufwerk nicht erreichbar'));
      expect(downloadErrorText(bad.error), contains('angehalten'));
      expect(nas.files['Downloads/Film2.mkv']!.length, 0);

      // NAS wieder da → Fortsetzen hängt an (Range).
      nas.failWith = null;
      nas.failAfterWrites = -1;
      final again = await DownloadTransfer(server(), blockSize: 64 * 1024).run(
          url: 'http://srv/f.mkv', sink: sink2, token: TransferToken());
      expect(again.end, TransferEnd.complete);
      expect(nas.files['Downloads/Film2.mkv']!.toBytes(), body);
    });

    test('NAS beim Start nicht erreichbar → nas:host', () async {
      nas.failWith = 'host';
      final out = await DownloadTransfer(server()).run(
          url: 'http://srv/f.mkv',
          sink: SmbSink(_cfg, 'Downloads/x.mkv'),
          token: TransferToken());
      expect(out.error, 'nas:host');
    });

    test('Offline-Wiedergabe: smb:// über den lokalen Proxy', () async {
      Smb.current = _cfg;
      final u = await LocalPlayback.resolvePath(
          _cfg.uriFor('Downloads/Der Pate.mkv'));
      expect(u, startsWith('http://127.0.0.1:4711/'));
      expect(Uri.decodeComponent(u), contains('Downloads/Der Pate.mkv'));
      expect(LocalPlayback.uriOf('/data/x.mkv'), 'file:///data/x.mkv');
      final item = DownloadItem(
          id: 'd',
          scope: 's',
          source: VodSource.portal,
          itemId: 'm',
          title: 'Der Pate',
          categoryId: 'c',
          maskedUrl: 'x',
          ext: 'mkv',
          added: DateTime(2026),
          path: _cfg.uriFor('Downloads/Der Pate.mkv'));
      final media = await LocalPlayback(item).resolve();
      expect(media.url, startsWith('http://127.0.0.1:4711/'));
      Smb.current = null;
      await expectLater(LocalPlayback.resolvePath(_cfg.uriFor('x.mkv')),
          throwsA(isA<SmbException>()));
    });
  });

  group('Aufnahmen', () {
    const ch = Channel(
        id: 'c1', name: 'Das Erste', categoryId: 'g', streamUrl: 'http://s/1');

    Future<ProviderContainer> container(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues(prefs);
      final st = await Storage.open(store: PreviewSecretStore());
      await st.setSmbConfig(_cfg);
      final c = ProviderContainer(overrides: [
        storageProvider.overrideWith((ref) async => st),
      ]);
      addTearDown(c.dispose);
      c.listen(recordingsProvider, (_, __) {});
      await c.read(storageProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return c;
    }

    test('NAS nicht erreichbar → Aufnahme abgelehnt mit Hinweis', () async {
      final c = await container({'set_rectree': 'smb'});
      final n = c.read(recordingsProvider.notifier);
      n.nasCheck = (_) async => throw const SmbException('host');
      final now = DateTime.now();
      final r = await n.schedule(
          ch,
          EpgEntry(
              channelEpgId: 'c1',
              title: 'Tatort',
              start: now.add(const Duration(hours: 1)),
              end: now.add(const Duration(hours: 2))));
      expect(r, RecResult.nasUnavailable);
      expect(c.read(recordingsProvider), isEmpty);
      expect(nasRecordingRefusedText(n.lastNasError),
          contains('Aufnahme nicht gestartet'));
    });

    test('NAS erreichbar → Aufnahme mit Ziel NAS (lokal gepuffert)', () async {
      final c = await container({'set_rectree': 'smb'});
      final n = c.read(recordingsProvider.notifier);
      n.nasCheck = (_) async {};
      final now = DateTime.now();
      await n.schedule(
          ch,
          EpgEntry(
              channelEpgId: 'c1',
              title: 'Tatort',
              start: now.add(const Duration(hours: 1)),
              end: now.add(const Duration(hours: 2))));
      final rec = c.read(recordingsProvider).single;
      expect(rec.nas, isTrue);
      expect(Recording.fromJson(rec.toJson().cast()).nas, isTrue);
    });

    test('Fertige Aufnahme wird verschoben; Ausfall → bleibt lokal mit '
        'Hinweis', () async {
      final done = Recording(
          id: 'r1',
          channelId: 'c1',
          channelName: 'Das Erste',
          title: 'Tatort',
          start: DateTime(2026, 10, 25, 20, 15),
          end: DateTime(2026, 10, 25, 21, 45),
          status: 'fertig',
          path: '/data/rec/Das Erste – Tatort.ts',
          nas: true);
      // NAS beim ersten (automatischen) Versuch nicht erreichbar.
      nas.failWith = 'host';
      final c = await container({
        'set_rectree': 'smb',
        'set_recordings': jsonEncode([done.toJson()]),
      });
      final n = c.read(recordingsProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await n.moveFinishedNow();
      var r = c.read(recordingsProvider).single;
      expect(r.path, done.path);
      expect(r.error, contains('liegt im App-Ordner'));
      String? movedRel;
      n.nasUpload = (cfg, local, rel) async {
        movedRel = rel;
        return 1;
      };
      await n.moveFinishedNow();
      r = c.read(recordingsProvider).single;
      expect(movedRel, 'Aufnahmen/Das Erste – Tatort.ts');
      expect(r.path, _cfg.uriFor('Aufnahmen/Das Erste – Tatort.ts'));
      expect(r.error, isNull);
    });
  });

  group('Einstellungen', () {
    Future<Storage> pump(WidgetTester tester, {bool tv = false}) async {
      SharedPreferences.setMockInitialValues({'set_applang': 'de'});
      final st = await Storage.open(store: PreviewSecretStore());
      tester.view.physicalSize =
          tv ? const Size(1920, 1080) : const Size(1080, 2340);
      tester.view.devicePixelRatio = tv ? 2 : 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          isTvProvider.overrideWithValue(tv),
          storageProvider.overrideWith((ref) async => st),
        ],
        child: MaterialApp(
          theme: buildTheme(tv: tv),
          builder: (context, child) =>
              TvSafeMediaQuery(enabled: tv, child: child!),
          home: RepaintBoundary(
              key: _shot,
              child: Navigator(
                onGenerateRoute: (_) => MaterialPageRoute(
                    builder: (_) => const Scaffold(body: SizedBox())),
              )),
        ),
      ));
      await tester.pump();
      final nav = tester.state<NavigatorState>(find.byType(Navigator).last);
      nav.push(MaterialPageRoute(builder: (_) => const SmbSettingsScreen()));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return st;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('Handy: Felder, Test, Fehler, als Speicherort verwenden',
        (tester) async {
      final st = await pump(tester);
      await tester.enterText(find.byKey(const ValueKey('smb-server')), 'nas.local');
      await tester.enterText(find.byKey(const ValueKey('smb-share')), 'video');
      await tester.enterText(find.byKey(const ValueKey('smb-user')), 'jason');
      await tester.enterText(find.byKey(const ValueKey('smb-pass')), 'Geheim!42');
      nas.failWith = 'auth';
      await tester.ensureVisible(find.byKey(const ValueKey('smb-test')));
      await tester.tap(find.byKey(const ValueKey('smb-test')));
      await settle(tester);
      expect(find.text('Netzlaufwerk: Benutzer oder Passwort falsch'),
          findsOneWidget);
      nas.failWith = null;
      await tester.tap(find.byKey(const ValueKey('smb-test')));
      await settle(tester);
      expect(find.text('Verbindung in Ordnung · 500 GB frei'), findsOneWidget);
      expect(st.smbConfig(), isNull, reason: 'Test speichert nichts');
      await writeShot(tester, _shot, 'phone_smb_settings');
      await tester.tap(find.byKey(const ValueKey('smb-use')));
      await settle(tester);
      expect(st.option(RecTree.optionKey, ''), RecTree.smbValue);
      expect(st.smbConfig()!.display, r'\\nas.local\video\JasonStreamPlayer');
      expect(find.byType(SmbSettingsScreen), findsNothing);
    });

    testWidgets('TV: D-Pad durch die Felder bis „Verbindung testen“',
        (tester) async {
      await pump(tester, tv: true);
      tester.widget<TextField>(find.byKey(const ValueKey('smb-server')))
          .controller!
          .text = 'nas.local';
      tester.widget<TextField>(find.byKey(const ValueKey('smb-share')))
          .controller!
          .text = 'video';
      await settle(tester);
      await writeShot(tester, _shot, 'tv_smb_settings');
      // Server-Feld hat den Fokus (neu) – ▼ bis zum Test-Knopf.
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 200));
      }
      final f = FocusManager.instance.primaryFocus?.context;
      var onTest = false;
      f?.visitAncestorElements((e) {
        if (e.widget.key == const ValueKey('smb-test')) onTest = true;
        return !onTest;
      });
      expect(onTest, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(nas.calls, contains('test'), reason: 'OK löst den Test aus');
    });
  });
}

final _shot = GlobalKey();
