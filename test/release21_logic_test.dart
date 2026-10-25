import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/stream_errors.dart';
import 'package:jason_stream_player/player/engine.dart';
import 'package:jason_stream_player/player/exo_engine.dart';
import 'package:jason_stream_player/player/mpv_engine.dart';
import 'package:jason_stream_player/player/watchdog.dart';
import 'package:jason_stream_player/player/zap_guard.dart';
import 'package:jason_stream_player/ui/player/mpv_tuning.dart';
import 'package:jason_stream_player/ui/player/reconnect.dart';

/// 2.1: Start-/Verbindungs-Leiter, Wachhunde, Eingriffs-Budget,
/// Zap-Schutz – reine Logik mit Fake-Uhr.
void main() {
  final t0 = DateTime(2026, 10, 25, 20);
  Duration sec(num s) => Duration(milliseconds: (s * 1000).round());

  /// Schritte einer Leiter bis „aufgeben“/„Hinweis“ (höchstens 20).
  List<String> ladder(ReconnectPolicy p, FailureKind kind,
      {String? message,
      EngineErrorKind? engineKind,
      bool live = true,
      int variants = 0,
      int hosts = 0,
      bool canSoftware = true,
      bool canSwitchEngine = false,
      bool fallback = false}) {
    final out = <String>[];
    for (var i = 0; i < 20; i++) {
      final s = p.onFailure(
        kind: kind,
        message: message,
        engineKind: engineKind,
        live: live,
        variantsLeft: variants,
        hostsLeft: hosts,
        canSoftware: canSoftware,
        canSwitchEngine: canSwitchEngine,
        engineHasDecoderFallback: fallback,
        now: t0,
      );
      switch (s.kind) {
        case RecoveryKind.retry:
          out.add('retry ${s.delay.inMilliseconds}');
        case RecoveryKind.nextVariant:
          variants--;
          out.add('variant');
        case RecoveryKind.nextHost:
          hosts--;
          out.add('host');
        case RecoveryKind.softwareDecode:
          canSoftware = false;
          out.add('software');
        case RecoveryKind.otherEngine:
          out.add('engine');
        case RecoveryKind.careful:
          out.add('careful');
        case RecoveryKind.restartVideo:
          out.add('restartVideo');
        case RecoveryKind.reselectAudio:
          out.add('reselectAudio');
        case RecoveryKind.notify:
          out.add('notify');
          return out;
        case RecoveryKind.giveUp:
          out.add('giveUp');
          return out;
      }
    }
    return out;
  }

  group('Fehlerart', () {
    test('429/458/„Too Many Requests“/ffmpeg 4XX → Anbieter bremst', () {
      for (final m in [
        'HTTP error 429 Too Many Requests',
        'HTTP error 458',
        'Server returned 4XX Client Error, but not one of 40{0,1,3,4}',
        'too many requests',
      ]) {
        expect(StreamError.classify(m).kind, StreamErrorKind.rateLimited,
            reason: m);
        expect(FaultClass.of(FailureKind.error, message: m),
            FaultClass.rateLimited);
      }
      // Zahlen in Adressen zählen nicht.
      expect(StreamError.classify('Failed to open http://x/429/1.ts').kind,
          isNot(StreamErrorKind.rateLimited));
    });

    test('Einordnung nach Engine-Fehlerart und Meldung', () {
      expect(FaultClass.of(FailureKind.error, message: 'HTTP error 503'),
          FaultClass.network);
      expect(FaultClass.of(FailureKind.error, message: 'HTTP error 404'),
          FaultClass.hopeless);
      expect(
          FaultClass.of(FailureKind.error,
              message: 'Decoder error', engineKind: EngineErrorKind.decoder),
          FaultClass.decoder);
      expect(
          FaultClass.of(FailureKind.error,
              message: 'x', engineKind: EngineErrorKind.container),
          FaultClass.format);
      expect(
          FaultClass.of(FailureKind.error,
              message: 'Invalid data found when processing input'),
          FaultClass.format);
      expect(FaultClass.of(FailureKind.stall), FaultClass.network);
      expect(FaultClass.of(FailureKind.buffering), FaultClass.network);
      expect(FaultClass.of(FailureKind.startTimeout), FaultClass.start);
      expect(FaultClass.of(FailureKind.noVideo), FaultClass.video);
      expect(FaultClass.of(FailureKind.noAudio), FaultClass.audio);
    });
  });

  group('Verbindungs-Leiter', () {
    test('Netz: 0,5/1/2/4/8 s, dann Ersatz-Adresse, dann Variante', () {
      final p = ReconnectPolicy();
      expect(
          ladder(p, FailureKind.error,
              message: 'tcp: Connection timed out', hosts: 1, variants: 1),
          [
            'retry 500', 'retry 1000', 'retry 2000', 'retry 4000', 'retry 8000',
            'host', 'retry 500', //
            'variant', 'retry 500', 'giveUp',
          ]);
    });

    test('VOD: keine Variante, Ersatz-Adresse ja', () {
      final p = ReconnectPolicy();
      final l = ladder(p, FailureKind.error,
          message: 'HTTP error 502', live: false, hosts: 1, variants: 3);
      expect(l, contains('host'));
      expect(l, isNot(contains('variant')));
      expect(l.last, 'giveUp');
    });

    test('Dauer-Puffern und Hänger laufen über dieselbe Leiter', () {
      expect(ladder(ReconnectPolicy(), FailureKind.buffering).first,
          'retry 500');
      expect(ladder(ReconnectPolicy(), FailureKind.stall).length, 6);
    });

    test('429/458: lange warten, keine Ersatz-Adressen/Varianten', () {
      final p = ReconnectPolicy();
      expect(
          ladder(p, FailureKind.error,
              message: 'HTTP error 429', hosts: 2, variants: 2),
          ['retry 8000', 'retry 20000', 'retry 45000', 'giveUp']);
      final q = ReconnectPolicy();
      final waits = ladder(q, FailureKind.error, message: 'HTTP error 458')
          .where((e) => e.startsWith('retry'))
          .map((e) => int.parse(e.split(' ').last));
      expect(waits.every((ms) => ms >= 8000), isTrue,
          reason: 'nicht hämmern');
    });

    test('403/404: nicht wiederholen → Ersatz-Adresse → Variante', () {
      expect(
          ladder(ReconnectPolicy(), FailureKind.error,
              message: 'HTTP error 404 Not Found', hosts: 1, variants: 1),
          ['host', 'variant', 'giveUp']);
    });
  });

  group('Start-Leiter', () {
    test('ohne Bild: gleiche Engine, vorsichtig, andere Engine, '
        'Ersatz-Adresse, Variante', () {
      final p = ReconnectPolicy();
      expect(
          ladder(p, FailureKind.startTimeout,
              canSwitchEngine: true, hosts: 1, variants: 1),
          [
            'retry 500', 'careful', 'engine', 'host', 'variant', 'giveUp',
          ]);
      expect(p.triedCareful, isTrue);
      expect(p.triedEngine, isTrue);
    });

    test('ohne andere Engine/Ersatz: nach vorsichtigem Start aufgeben', () {
      expect(ladder(ReconnectPolicy(), FailureKind.startTimeout),
          ['retry 500', 'careful', 'giveUp']);
    });

    test('Decoder (mpv): Software → andere Engine → Variante', () {
      expect(
          ladder(ReconnectPolicy(), FailureKind.error,
              message: 'vd: Could not open codec',
              canSwitchEngine: true,
              variants: 1),
          ['software', 'engine', 'variant', 'giveUp']);
    });

    test('Decoder (ExoPlayer probiert selbst): gleich andere Engine', () {
      expect(
          ladder(ReconnectPolicy(), FailureKind.error,
              message: 'Decoder error',
              engineKind: EngineErrorKind.decoder,
              canSwitchEngine: true,
              fallback: true),
          ['engine', 'giveUp']);
    });

    test('Software nicht möglich („Hardware direkt“) → andere Engine', () {
      expect(
          ladder(ReconnectPolicy(), FailureKind.error,
              message: 'hwdec failed',
              canSoftware: false,
              canSwitchEngine: true),
          ['engine', 'giveUp']);
    });

    test('Format/Container (ExoPlayer): gleich andere Engine', () {
      final p = ReconnectPolicy();
      expect(
          p
              .next(
                  FailureKind.error,
                  const RecoveryOptions(
                      live: false,
                      canSwitchEngine: true,
                      carefulHelpsFormat: false),
                  engineKind: EngineErrorKind.container,
                  now: t0)
              .kind,
          RecoveryKind.otherEngine);
    });

    test('Format/Container (mpv): vorsichtig analysieren, dann andere Engine', () {
      expect(
          ladder(ReconnectPolicy(), FailureKind.error,
              message: 'Container error',
              engineKind: EngineErrorKind.container,
              canSwitchEngine: true),
          ['careful', 'engine', 'giveUp']);
    });

    test('Netzfehler wechseln nie Engine oder Dekoder', () {
      final l = ladder(ReconnectPolicy(), FailureKind.error,
          message: 'HTTP error 503', canSwitchEngine: true);
      expect(l, isNot(contains('engine')));
      expect(l, isNot(contains('software')));
      expect(l, isNot(contains('careful')));
    });
  });

  group('Wachhund-Leiter', () {
    test('kein Bild: Videoausgabe neu → neu öffnen → Software → Engine', () {
      expect(
          ladder(ReconnectPolicy(), FailureKind.noVideo,
              canSwitchEngine: true),
          ['restartVideo', 'retry 500', 'software', 'engine', 'giveUp']);
    });

    test('kein Ton: Tonspur neu → neu öffnen → nur Hinweis', () {
      expect(ladder(ReconnectPolicy(), FailureKind.noAudio),
          ['reselectAudio', 'retry 500', 'notify']);
    });
  });

  group('Eingriffs-Budget', () {
    test('höchstens 3 Episoden je 5 Minuten, danach Fehlermeldung', () {
      final p = ReconnectPolicy();
      var t = t0;
      for (var i = 0; i < 3; i++) {
        final s = p.onFailure(kind: FailureKind.stall, live: true, now: t);
        expect(s.kind, RecoveryKind.retry, reason: 'Episode ${i + 1}');
        // Läuft wieder 60 s gut → Leiter von vorn, Budget bleibt.
        p.markGood(t.add(sec(1)));
        p.markGood(t.add(sec(62)));
        expect(p.recovering, isFalse);
        t = t.add(sec(63));
      }
      final s = p.onFailure(kind: FailureKind.stall, live: true, now: t);
      expect(s.kind, RecoveryKind.giveUp);
      expect(s.budgetExhausted, isTrue);
      // 5 Minuten nach dem ersten Eingriff ist wieder Platz.
      p.markGood(t);
      p.markGood(t.add(sec(61)));
      final later = t0.add(const Duration(minutes: 5, seconds: 1));
      expect(
          p.onFailure(kind: FailureKind.stall, live: true, now: later).kind,
          RecoveryKind.retry);
    });

    test('Schritte innerhalb einer Episode verbrauchen kein Budget', () {
      final p = ReconnectPolicy();
      final l = ladder(p, FailureKind.error,
          message: 'timeout', hosts: 1, variants: 2);
      expect(l.length, greaterThan(3));
      expect(p.budget.count(t0), 1);
    });

    test('Nutzer schaltet um / „Erneut versuchen“: Budget wieder voll', () {
      final p = ReconnectPolicy();
      for (var i = 0; i < 3; i++) {
        p.onFailure(kind: FailureKind.stall, live: true, now: t0);
        p.markGood(t0);
        p.markGood(t0.add(sec(61)));
      }
      expect(p.budget.count(t0), 3);
      p.reset();
      expect(p.budget.count(t0), 0);
      expect(p.onFailure(kind: FailureKind.stall, live: true, now: t0).kind,
          RecoveryKind.retry);
    });

    test('Eingriffe werden gezählt (Stream-Info)', () {
      final p = ReconnectPolicy();
      ladder(p, FailureKind.noAudio);
      expect(p.interventions, 3);
    });
  });

  group('Start-Gedächtnis (Sitzung)', () {
    test('erfolgreiche Stufe je Sender', () {
      final m = StartMemory();
      expect(m.of('ch:a').isDefault, isTrue);
      m.remember('ch:a', const StartProfile(careful: true, variantId: 'v2'));
      expect(m.of('ch:a'),
          const StartProfile(careful: true, variantId: 'v2'));
      expect(m.of('ch:b').isDefault, isTrue);
      m.remember('ch:a', const StartProfile());
      expect(m.length, 0, reason: 'Standard wird nicht gespeichert');
      m.remember(null, const StartProfile(software: true));
      expect(m.length, 0);
    });
  });

  group('Wachhunde', () {
    late PlaybackWatchdog w;
    late DateTime now;
    setUp(() {
      w = PlaybackWatchdog();
      now = t0;
    });

    /// [n] Sekunden lang je Sekunde einen Messpunkt; liefert die Alarme.
    List<WatchAlarm> run(int n, WatchSample Function(int i) f) {
      final out = <WatchAlarm>[];
      for (var i = 0; i < n; i++) {
        now = now.add(sec(1));
        final a = w.sample(f(i), now);
        if (a != null) out.add(a);
      }
      return out;
    }

    var pos = 0;
    var frames = 0;
    var audio = 0;
    WatchSample good(int i,
        {bool active = true,
        bool moveFrames = true,
        bool moveAudio = true,
        bool movePos = true,
        bool buffering = false,
        bool playing = true,
        bool videoExpected = true,
        bool audioExpected = true,
        bool firstFrame = true,
        int? dropped,
        bool countersKnown = true}) {
      if (movePos) pos += 1000;
      if (moveFrames) frames += 25;
      if (moveAudio) audio += 1000;
      return WatchSample(
        active: active,
        playing: playing,
        buffering: buffering,
        position: Duration(milliseconds: pos),
        hasFirstFrame: firstFrame,
        videoExpected: videoExpected,
        audioExpected: audioExpected,
        videoFrames: countersKnown ? frames : null,
        audioTicks: countersKnown ? audio : null,
        droppedFrames: dropped,
        fps: 25,
      );
    }

    WatchSample opening({bool active = true}) => WatchSample(
        active: active,
        playing: true,
        buffering: true,
        position: Duration.zero);

    test('Start: live 8 s, Film 12 s bis zum ersten Bild', () {
      w.reset(live: true, now: now);
      expect(run(7, (_) => opening()), isEmpty);
      expect(run(1, (_) => opening()), [WatchAlarm.startTimeout]);
      expect(run(20, (_) => opening()), isEmpty, reason: 'nur einmal');
      w.reset(live: false, now: now);
      expect(run(11, (_) => opening()), isEmpty);
      expect(run(1, (_) => opening()), [WatchAlarm.startTimeout]);
    });

    test('Start: vorsichtiger Start bekommt mehr Zeit', () {
      w.reset(live: true, budgetFactor: 1.5, now: now);
      expect(run(11, (_) => opening()), isEmpty);
      expect(run(1, (_) => opening()), [WatchAlarm.startTimeout]);
    });

    test('Start: erstes Bild bzw. laufende Position (Radio) beendet die Frist',
        () {
      w.reset(live: true, now: now);
      run(3, (_) => opening());
      expect(
          run(1, (i) => const WatchSample(
              active: true,
              playing: true,
              buffering: false,
              position: Duration.zero,
              hasFirstFrame: true)),
          isEmpty);
      expect(w.started, isTrue);
      w.reset(live: true, now: now);
      pos = 0;
      expect(
          run(20, (i) => good(i,
              firstFrame: false, videoExpected: false, countersKnown: false)),
          isEmpty);
      expect(w.started, isTrue);
    });

    test('Start: Pause/Hintergrund zählt nicht', () {
      w.reset(live: true, now: now);
      expect(run(30, (_) => opening(active: false)), isEmpty);
      expect(run(7, (_) => opening()), isEmpty);
      expect(run(1, (_) => opening()), [WatchAlarm.startTimeout]);
    });

    test('kein Bild: Ton/Position läuft, keine Bilder > 6 s', () {
      w.reset(live: true, now: now);
      run(3, (i) => good(i));
      expect(run(5, (i) => good(i, moveFrames: false)), isEmpty);
      expect(run(1, (i) => good(i, moveFrames: false)), [WatchAlarm.noVideo]);
    });

    test('kein Bild: kein Fehlalarm bei Nur-Ton, Hintergrund, Radio', () {
      w.reset(live: true, now: now);
      run(3, (i) => good(i));
      expect(
          run(60, (i) => good(i, moveFrames: false, videoExpected: false)),
          isEmpty);
    });

    test('kein Bild: unbekannte Zähler → kein Alarm', () {
      w.reset(live: true, now: now);
      run(3, (i) => good(i));
      expect(run(30, (i) => good(i, countersKnown: false)), isEmpty);
    });

    test('kein Bild: mpv ohne Bildzähler, Ausgabe-fps 0', () {
      w.reset(live: true, now: now);
      var p = 0;
      WatchSample s(double fps) {
        p += 1000;
        return WatchSample(
            active: true,
            playing: true,
            buffering: false,
            position: Duration(milliseconds: p),
            hasFirstFrame: true,
            outputFps: fps);
      }

      run(3, (_) => s(25));
      expect(run(5, (_) => s(0)), isEmpty);
      expect(run(1, (_) => s(0)), [WatchAlarm.noVideo]);
    });

    test('eingefroren: Position steht > 7 s bei „spielt“ ohne Puffern', () {
      w.reset(live: true, now: now);
      run(3, (i) => good(i));
      final a = run(8, (i) => good(i, movePos: false, moveFrames: false,
          moveAudio: false));
      expect(a, [WatchAlarm.frozen]);
    });

    test('eingefroren: Pause durch den Nutzer ist kein Hänger', () {
      w.reset(live: true, now: now);
      run(3, (i) => good(i));
      expect(
          run(120, (i) => good(i,
              active: false,
              movePos: false,
              moveFrames: false,
              moveAudio: false)),
          isEmpty);
    });

    test('eingefroren: Cast/Mini-Player (inaktiv) – keine Alarme', () {
      w.reset(live: false, now: now);
      expect(
          run(120, (i) => good(i,
              active: false,
              movePos: false,
              moveFrames: false,
              moveAudio: false,
              buffering: true,
              firstFrame: false)),
          isEmpty);
    });

    test('Puffern zählt nicht als eingefroren, aber > 15 s als Dauer-Puffern',
        () {
      w.reset(live: true, now: now);
      run(3, (i) => good(i));
      expect(
          run(14, (i) => good(i,
              buffering: true, movePos: false, moveFrames: false)),
          isEmpty);
      expect(
          run(1, (i) => good(i,
              buffering: true, movePos: false, moveFrames: false)),
          [WatchAlarm.buffering]);
    });

    test('kurzes Puffern setzt die Frist zurück', () {
      w.reset(live: true, now: now);
      run(3, (i) => good(i));
      for (var k = 0; k < 5; k++) {
        expect(run(10, (i) => good(i, buffering: true, movePos: false)),
            isEmpty);
        expect(run(2, (i) => good(i)), isEmpty);
      }
    });

    test('Ton weg: Bilder laufen, Ton steht > 5 s', () {
      w.reset(live: true, now: now);
      run(3, (i) => good(i));
      expect(run(4, (i) => good(i, moveAudio: false)), isEmpty);
      expect(run(1, (i) => good(i, moveAudio: false)), [WatchAlarm.noAudio]);
    });

    test('Ton weg: nicht ohne Tonspur (stumm gewählt) und nicht bei Pause', () {
      w.reset(live: true, now: now);
      run(3, (i) => good(i));
      expect(run(30, (i) => good(i, moveAudio: false, audioExpected: false)),
          isEmpty);
      expect(
          run(30, (i) => good(i, moveAudio: false, active: false)), isEmpty);
    });

    test('rearm: nach „Videoausgabe neu“ wieder volle Frist', () {
      w.reset(live: true, now: now);
      run(3, (i) => good(i));
      run(4, (i) => good(i, moveFrames: false));
      w.rearm();
      expect(run(6, (i) => good(i, moveFrames: false)), isEmpty);
      expect(run(1, (i) => good(i, moveFrames: false)), [WatchAlarm.noVideo]);
    });

    test('Ruckeln: lange hohe Drop-Rate → Hinweis, Hysterese, Höchstzahl', () {
      w.reset(live: false, now: now);
      var dropped = 0;
      // 25 fps, 8 verworfene Bilder je Sekunde (32 %).
      final alarms = <(int, WatchAlarm)>[];
      for (var i = 0; i < 1800; i++) {
        dropped += 8;
        now = now.add(sec(1));
        final a = w.sample(good(i, dropped: dropped), now);
        if (a != null) alarms.add((i, a));
      }
      expect(alarms.map((e) => e.$2).toSet(), {WatchAlarm.stutter});
      expect(alarms.length, 2, reason: 'höchstens 2 Hinweise je Sitzung');
      expect(alarms.first.$1, greaterThanOrEqualTo(55),
          reason: 'erst nach längerer Zeit');
      expect(alarms[1].$1 - alarms[0].$1, greaterThanOrEqualTo(600),
          reason: '10 min Ruhe');
    });

    test('Ruckeln: kurzer Ausreißer oder geringe Rate → kein Hinweis', () {
      w.reset(live: true, now: now);
      var dropped = 0;
      for (var i = 0; i < 600; i++) {
        // 20 Bilder auf einmal alle 2 min, sonst 1 je 10 s.
        if (i % 120 == 0) dropped += 20;
        if (i % 10 == 0) dropped++;
        now = now.add(sec(1));
        expect(w.sample(good(i, dropped: dropped), now), isNull);
      }
    });
  });

  group('Zap-Schutz', () {
    test('einzelner Druck sofort, schnelle Folge erst nach 500 ms Ruhe', () {
      final g = ZapGuard();
      expect(g.press(t0), Duration.zero);
      expect(g.press(t0.add(sec(0.3))), const Duration(milliseconds: 500));
      expect(g.press(t0.add(sec(0.6))), const Duration(milliseconds: 500));
      expect(g.press(t0.add(sec(1.9))), const Duration(milliseconds: 500),
          reason: '1,3 s seit dem letzten Druck');
      expect(g.press(t0.add(sec(3.4))), Duration.zero, reason: '≥ 1,5 s');
      g.reset();
      expect(g.press(t0.add(sec(3.5))), Duration.zero);
    });
  });

  group('Engine-Messwerte', () {
    test('mpv-Eigenschaften → EngineHealth', () {
      final h = MpvEngine.healthFrom({
        'estimated-frame-number': '1200',
        'estimated-vf-fps': '25.000',
        'audio-pts': '48.250',
        'frame-drop-count': '3',
        'decoder-frame-drop-count': '2',
        'demuxer-cache-duration': '7.5',
        'vid': '1',
        'aid': 'no',
        'hwdec-current': 'mediacodec',
        'video-format': 'h264',
        'audio-codec-name': 'aac',
        'video-params/w': '1920',
        'video-params/h': '1080',
        'container-fps': '50.000',
        'video-bitrate': '6000000',
      });
      expect(h.videoFrames, 1200);
      expect(h.outputFps, 25);
      expect(h.audioTicks, 48250);
      expect(h.droppedFrames, 5);
      expect(h.bufferSeconds, 7.5);
      expect(h.hasVideoTrack, isTrue);
      expect(h.hasAudioTrack, isFalse);
      expect(h.hardwareDecoder, isTrue);
      expect(h.videoCodec, 'h264');
      expect(h.width, 1920);
      expect(h.fps, 50);
      expect(h.videoBitrate, 6000000);
      final sw = MpvEngine.healthFrom({'hwdec-current': 'no'});
      expect(sw.hardwareDecoder, isFalse);
      expect(MpvEngine.healthFrom(const {}).droppedFrames, isNull);
    });

    test('Exo-Statistik → EngineHealth', () {
      final h = ExoEngine.healthFrom({
        'videoFrames': 900,
        'audioBuffers': 450,
        'dropped': 4,
        'bufferedMs': 12500,
        'videoMime': 'video/hevc',
        'audioMime': 'audio/eac3',
        'videoHw': true,
        'videoDecoder': 'c2.amlogic.hevc.decoder',
        'width': 3840,
        'height': 2160,
        'fps': 50.0,
        'bitrate': 15000000,
      }, position: const Duration(seconds: 3));
      expect(h.videoFrames, 900);
      expect(h.audioTicks, 450);
      expect(h.droppedFrames, 4);
      expect(h.bufferSeconds, 12.5);
      expect(h.hasVideoTrack, isTrue);
      expect(h.hasAudioTrack, isTrue);
      expect(h.videoCodec, 'hevc');
      expect(h.audioCodec, 'E-AC3');
      expect(h.hardwareDecoder, isTrue);
      final off = ExoEngine.healthFrom({'audioMime': 'audio/aac'},
          selection: const EngineSelection(audio: EngineTrack.no));
      expect(off.hasAudioTrack, isFalse);
      expect(off.hasVideoTrack, isFalse, reason: 'Radio: keine Videospur');
      expect(ExoEngine.healthFrom(const {}).hasVideoTrack, isNull);
    });

    test('mpv vorsichtiger Start: mehr Analyse, erst mit Puffer', () {
      final normal =
          MpvTuning.stream(live: true, plan: null, bufferBytes: 48 << 20);
      final careful = MpvTuning.stream(
          live: true, plan: null, bufferBytes: 48 << 20, careful: true);
      expect(normal['cache-pause-initial'], 'no');
      expect(careful['cache-pause-initial'], 'yes');
      expect(double.parse(careful['demuxer-lavf-analyzeduration']!),
          greaterThan(double.parse(normal['demuxer-lavf-analyzeduration']!)));
      expect(int.parse(careful['demuxer-lavf-probesize']!),
          greaterThan(int.parse(normal['demuxer-lavf-probesize']!)));
    });
  });
}
