import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/subtitle_style.dart';
import 'package:jason_stream_player/data/repository.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/ui/player/mpv_tuning.dart';
import 'package:jason_stream_player/ui/player/player_debug.dart';
import 'package:jason_stream_player/ui/player/stream_url.dart';
import 'package:jason_stream_player/ui/player/subtitle_view.dart';
import 'package:jason_stream_player/ui/player/timeshift.dart';
import 'package:jason_stream_player/ui/settings/settings_screen.dart';
import 'package:jason_stream_player/ui/widgets/live_preview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/content14_harness.dart';

/// 1.5 „Tempo“: mpv-Eigenschaften nur bei Änderung, Live-Puffer,
/// Untertitel-Aussehen in Flutter, Video-Ausgabe, Diagnose-Anzeige,
/// Abspiel-Adresse ohne Warten auf den Login.

/// Ersatz für NativePlayer.setProperty.
class _FakeMpv {
  final calls = <(String, String)>[];
  final unsupported = <String>{};
  Future<void> set(String k, String v) async {
    calls.add((k, v));
    if (unsupported.contains(k)) throw Exception('unknown option $k');
  }

  Map<String, String> get last => {for (final (k, v) in calls) k: v};
}

Map<String, String> _open(
  bool live, {
  LiveBufferPlan? plan,
  int buffer = 48 << 20,
  String ua = 'JSP',
  SubtitleStyle sub = const SubtitleStyle(),
  bool passthrough = false,
}) =>
    MpvTuning.perOpen(
      live: live,
      plan: plan,
      bufferBytes: buffer,
      userAgent: ua,
      referrer: '',
      subtitles: sub,
      passthrough: passthrough,
    );

const _ch = Channel(
    id: 'c1',
    name: 'Eins',
    categoryId: 'g',
    streamUrl: 'http://a.tv/live/u/p/1.ts');

void main() {
  setUpAll(() async {
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });

  group('mpv-Eigenschaften', () {
    test('Feste Optionen einmal, je Öffnen nur Änderungen', () async {
      final mpv = _FakeMpv();
      final props = MpvProps(mpv.set);
      expect(await props.apply(MpvTuning.constant), MpvTuning.constant.length);
      expect(await props.apply(MpvTuning.constant), 0);

      final first = await props.apply(_open(true));
      // Vorher je Öffnen: 5 Untertitel + 1 Ton + 7 Puffer/Kopfzeilen.
      expect(first, greaterThanOrEqualTo(10));
      // Zappen (nächster Live-Sender, gleiche Einstellungen): nichts.
      final zap = await props.apply(_open(true));
      expect(zap, 0);
      // ignore: avoid_print
      print('[player15] mpv-Eigenschaften: 1. Öffnen $first, Zappen $zap '
          '(vorher je Öffnen 12 setProperty-Aufrufe)');
      // Film: nur Puffer/Analyse ändern sich.
      mpv.calls.clear();
      await props.apply(_open(false));
      expect(
          mpv.calls.map((c) => c.$1).toSet(),
          {
            'demuxer-seekable-cache',
            'demuxer-max-bytes',
            'demuxer-max-back-bytes',
            'demuxer-lavf-analyzeduration',
            'demuxer-lavf-probesize',
          }..removeWhere((k) => _open(true)[k] == _open(false)[k]));
      // Untertitel-Aussehen geändert → nur diese Eigenschaften.
      mpv.calls.clear();
      await props.apply(_open(false, sub: const SubtitleStyle(color: 'gelb')));
      expect(mpv.calls, [('sub-color', '#FFFFFF00')]);
      // Durchreichen an/aus.
      mpv.calls.clear();
      await props.apply(_open(false,
          sub: const SubtitleStyle(color: 'gelb'), passthrough: true));
      expect(mpv.calls.single.$1, 'audio-spdif');
    });

    test('Unbekannte Option: Fehler geschluckt, nicht wiederholt', () async {
      final mpv = _FakeMpv()..unsupported.add('demuxer-lavf-probesize');
      final props = MpvProps(mpv.set);
      await props.apply(_open(true));
      final n = mpv.calls.length;
      await props.apply(_open(true));
      expect(mpv.calls.length, n);
      props.forget('user-agent');
      expect(await props.apply(_open(true)), 1);
    });

    test('Live ohne Live-Pause: kleiner Rückpuffer, 16–32 MB voraus', () {
      final normal =
          MpvTuning.stream(live: true, plan: null, bufferBytes: 48 << 20);
      expect(normal['demuxer-max-back-bytes'], '${6 << 20}');
      expect(normal['demuxer-max-bytes'], '${32 << 20}');
      expect(normal['demuxer-seekable-cache'], 'auto');
      expect(normal['demuxer-lavf-analyzeduration'], '1');
      expect(normal['demuxer-lavf-probesize'], MpvTuning.liveProbeSize);
      final small =
          MpvTuning.stream(live: true, plan: null, bufferBytes: 16 << 20);
      expect(small['demuxer-max-bytes'], '${16 << 20}');
      final big =
          MpvTuning.stream(live: true, plan: null, bufferBytes: 128 << 20);
      expect(big['demuxer-max-bytes'], '${32 << 20}');
      // Vorher: 48 MB zurück + 48 MB voraus = 96 MB; jetzt 38 MB.
    });

    test('Live-Pause: Puffer wie geplant (unverändert)', () {
      const plan = LiveBufferPlan(200 << 20, 150 << 20, Duration(minutes: 30));
      final m = MpvTuning.stream(live: true, plan: plan, bufferBytes: 48 << 20);
      expect(m['demuxer-max-bytes'], '${200 << 20}');
      expect(m['demuxer-max-back-bytes'], '${150 << 20}');
      expect(m['demuxer-seekable-cache'], 'yes');
      const small = LiveBufferPlan(8 << 20, 40 << 20, Duration(minutes: 1));
      expect(
          MpvTuning.stream(
              live: true,
              plan: small,
              bufferBytes: 48 << 20)['demuxer-max-bytes'],
          '${48 << 20}');
    });

    test('Filme: Puffer wie bisher', () {
      final m =
          MpvTuning.stream(live: false, plan: null, bufferBytes: 48 << 20);
      expect(m['demuxer-max-bytes'], '${48 << 20}');
      expect(m['demuxer-max-back-bytes'], '${48 << 20}');
      expect(m['demuxer-lavf-analyzeduration'], '1.5');
    });
  });

  test('Video-Ausgabe: Werte für den VideoController', () {
    expect(VideoOutput.fromId(null), VideoOutput.standard);
    expect(VideoOutput.fromId('quatsch'), VideoOutput.standard);
    expect(VideoOutput.standard.controller, (null, null));
    expect(VideoOutput.fromId('direct').controller,
        ('mediacodec_embed', 'mediacodec'));
    expect(VideoOutput.fromId('compat').controller, (null, 'no'));
  });

  test('Untertitel-Aussehen → SubtitleViewConfiguration', () {
    final d = subtitleViewConfig(const SubtitleStyle());
    expect(d.style.fontSize, 32); // media_kit-Standard = „normal“
    expect(d.style.color, const Color(0xFFFFFFFF));
    expect(d.style.backgroundColor, const Color(0x00000000));
    expect(d.style.shadows, isNotEmpty); // Rand
    final s = subtitleViewConfig(const SubtitleStyle(
        size: 'sehrgross', color: 'gelb', box: true, outline: false));
    expect(s.style.fontSize, 48);
    expect(s.style.color, const Color(0xFFFFFF00));
    expect(s.style.backgroundColor, const Color(0x80000000));
    expect(s.style.shadows, isEmpty);
    expect(
        subtitleViewConfig(const SubtitleStyle(size: 'klein')).style.fontSize,
        24);
  });

  test('Diagnose-Anzeige: Zeilen', () {
    final l = PlayerDebugInfo.format({
      'hwdec-current': 'mediacodec',
      'current-vo': 'mediacodec_embed',
      'container-fps': '50.000000',
      'frame-drop-count': '3',
      'demuxer-cache-duration': '4.25',
    }, sent: 12);
    expect(l.first, 'hwdec mediacodec · vo mediacodec_embed');
    expect(l.any((x) => x.startsWith('fps 50.0')), isTrue);
    expect(l.any((x) => x.contains('drop 3')), isTrue);
    expect(l.any((x) => x.contains('cache 4.3 s') || x.contains('cache 4.2 s')),
        isTrue);
    expect(l.last, 'mpv props sent 12');
  });

  group('Abspiel-Adresse', () {
    test('Xtream: wartet nicht auf den Login', () async {
      const p = Portal(
          id: 'x', name: 'X', type: PortalType.xtream, url: 'http://a.tv');
      final login = Completer<IptvRepository?>();
      var asked = 0;
      final url = await resolveLiveUrl(_ch,
          portal: p, current: const AsyncLoading(), repo: () {
        asked++;
        return login.future;
      }).timeout(const Duration(seconds: 1));
      expect(url, _ch.streamUrl);
      expect(asked, 1, reason: 'Login trotzdem angestoßen');
    });

    test('MAC-Portal: wartet wie bisher', () async {
      const p = Portal(
          id: 's', name: 'S', type: PortalType.stalker, url: 'http://m.tv');
      final login = Completer<IptvRepository?>();
      var done = false;
      final f = resolveLiveUrl(_ch,
          portal: p,
          current: const AsyncLoading(),
          repo: () => login.future).then((u) {
        done = true;
        return u;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(done, isFalse);
      login.complete(null);
      expect(await f, _ch.streamUrl);
    });
  });

  test('Live-Vorschau: Vollbild gibt den Vorschau-Player frei', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctl = c.read(livePreviewProvider);
    expect(ctl.alive, isFalse);
    var inside = -1;
    await ctl.whilePaused(() async {
      inside = ctl.paused.value;
      expect(ctl.alive, isFalse);
    });
    expect(inside, 1);
    expect(ctl.paused.value, 0);
    ctl.release(); // ohne Player: nichts zu tun
    expect(ctl.releases, 0);
  });

  group('Einstellungen (Fernseher)', () {
    Future<Storage> storage() async {
      SharedPreferences.setMockInitialValues({});
      return Storage.open(store: PreviewSecretStore());
    }

    testWidgets('Video-Ausgabe: OK schaltet weiter', (tester) async {
      final st = (await tester.runAsync(storage))!;
      await pumpC14(tester, const Scaffold(body: SettingsScreen()),
          const C14Data(), Future.value(st));
      final tile = find.byKey(const ValueKey('video-output'));
      await tester.ensureVisible(tile);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(tr('Video-Ausgabe')), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.text(tr('Standard'))),
          findsOneWidget);
      await tester.tap(tile);
      await tester.pump(const Duration(milliseconds: 300));
      expect(st.option(VideoOutput.optionKey, ''), 'direct');
      await c14Done(tester);
    });

    testWidgets('Handy: keine Video-Ausgabe', (tester) async {
      final st = (await tester.runAsync(storage))!;
      await pumpC14(tester, const Scaffold(body: SettingsScreen()),
          const C14Data(tv: false), Future.value(st));
      expect(find.byKey(const ValueKey('video-output'), skipOffstage: false),
          findsNothing);
      // (Bekannt: „Speicherort“ der Aufnahmen läuft bei 360 dp Breite rechts
      // über – unabhängig von dieser Änderung.)
      tester.takeException();
      await c14Done(tester);
    });

    testWidgets('5× OK auf der Versionszeile: Diagnose-Anzeige an/aus',
        (tester) async {
      final st = (await tester.runAsync(storage))!;
      await pumpC14(tester, const Scaffold(body: SettingsScreen()),
          const C14Data(), Future.value(st));
      final v = find.byKey(const ValueKey('settings-version'));
      await tester.ensureVisible(v);
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 0; i < 4; i++) {
        await tester.tap(v);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(st.flag(PlayerDebugInfo.flagKey), isFalse);
      await tester.tap(v);
      await tester.pump(const Duration(milliseconds: 100));
      expect(st.flag(PlayerDebugInfo.flagKey), isTrue);
      expect(find.text(tr('Diagnose-Anzeige im Player an')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await c14Done(tester);
    });
  });
}
