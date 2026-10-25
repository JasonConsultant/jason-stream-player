import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/player/watchdog.dart';
import 'package:jason_stream_player/ui/player/reconnect.dart';
import 'package:jason_stream_player/ui/player/timeshift.dart';

/// Kleiner Ersatz-Player: spielt eine Liste von Quellen; jede Quelle
/// scheitert so oft wie angegeben, bevor sie läuft. Die Steuerung ist
/// dieselbe wie im PlayerScreen (_failure/_watch), nur ohne mpv.
class _FakeSession {
  final List<int> failuresPerSource;
  final bool decoderError;
  final bool hardwareBroken;
  final policy = ReconnectPolicy();
  final log = <String>[];
  int source = 0;
  bool software = false;
  late final List<int> _left = [...failuresPerSource];
  DateTime now = DateTime(2026, 10, 21, 20);

  _FakeSession(this.failuresPerSource,
      {this.decoderError = false, this.hardwareBroken = false});

  /// Öffnet die aktuelle Quelle; true = läuft.
  bool _open() {
    if (hardwareBroken && !software) return false;
    if (_left[source] > 0) {
      _left[source]--;
      return false;
    }
    return true;
  }

  /// Bis Wiedergabe läuft oder aufgegeben wird. Liefert den letzten Schritt.
  RecoveryKind run({bool live = true}) {
    var ok = _open();
    while (!ok) {
      final step = policy.onFailure(
        kind: FailureKind.error,
        message: decoderError || hardwareBroken
            ? 'vd: Could not open codec'
            : 'tcp: Connection timed out',
        live: live,
        variantsLeft: live ? failuresPerSource.length - 1 - source : 0,
      );
      final ms = step.delay.inMilliseconds;
      log.add('${step.kind.name}${step.kind == RecoveryKind.retry ? ' ${ms % 1000 == 0 ? '${ms ~/ 1000}s' : '${ms}ms'}' : ''}');
      now = now.add(step.delay);
      switch (step.kind) {
        case RecoveryKind.nextVariant:
          source++;
        case RecoveryKind.softwareDecode:
          software = true;
        case RecoveryKind.giveUp:
          return RecoveryKind.giveUp;
        default:
          break;
      }
      ok = _open();
    }
    log.add('playing $source');
    return RecoveryKind.retry;
  }
}

void main() {
  group('ReconnectPolicy', () {
    const full = ['retry 500ms', 'retry 1s', 'retry 2s', 'retry 4s', 'retry 8s'];
    test('Wiederholen mit 0,5/1/2/4/8 s, dann aufgeben (keine Varianten)', () {
      final s = _FakeSession([99]);
      expect(s.run(), RecoveryKind.giveUp);
      expect(s.log, [...full, 'giveUp']);
    });

    test('kurzer Aussetzer: zweiter Versuch klappt', () {
      final s = _FakeSession([1]);
      s.run();
      expect(s.log, ['retry 500ms', 'playing 0']);
    });

    test('nach den Wiederholungen nächste Variante', () {
      final s = _FakeSession([99, 0, 0]);
      s.run();
      expect(s.log, [...full, 'nextVariant', 'playing 1']);
    });

    test('weitere Varianten bekommen je einen Versuch', () {
      final s = _FakeSession([99, 99, 99]);
      expect(s.run(), RecoveryKind.giveUp);
      expect(s.log, [
        ...full, 'nextVariant', //
        'retry 500ms', 'nextVariant', 'retry 500ms', 'giveUp',
      ]);
    });

    test('VOD: kein Variantenwechsel', () {
      final s = _FakeSession([99, 0]);
      expect(s.run(live: false), RecoveryKind.giveUp);
      expect(s.log.contains('nextVariant'), isFalse);
    });

    test('Decoder-Fehler (mpv): gleich Software-Dekodierung', () {
      final s = _FakeSession([0], hardwareBroken: true);
      s.run();
      expect(s.log, ['softwareDecode', 'playing 0']);
    });

    test('Software-Dekodierung nur einmal, keine Endlosschleife', () {
      final s = _FakeSession([99], decoderError: true);
      expect(s.run(), RecoveryKind.giveUp);
      expect(s.log.where((e) => e == 'softwareDecode').length, 1);
      expect(s.log.length, lessThan(12));
    });

    test('403/404 wird nicht wiederholt, sondern Variante gewechselt', () {
      final p = ReconnectPolicy();
      expect(
          p.onFailure(
              kind: FailureKind.error,
              message: 'HTTP error 403 Forbidden',
              live: true,
              variantsLeft: 1),
          const RecoveryStep(
              RecoveryKind.nextVariant, ReconnectPolicy.switchDelay));
      expect(
          p.onFailure(
              kind: FailureKind.error,
              message: 'HTTP error 404 Not Found',
              live: true,
              variantsLeft: 0),
          const RecoveryStep(RecoveryKind.giveUp));
    });

    test('Hänger (ohne Meldung) wird wiederholt', () {
      final p = ReconnectPolicy();
      expect(p.onFailure(kind: FailureKind.stall, live: true),
          const RecoveryStep(RecoveryKind.retry, Duration(milliseconds: 500)));
    });

    test('nach 60 s guter Wiedergabe wieder volle Versuche', () {
      final p = ReconnectPolicy();
      final t0 = DateTime(2026);
      for (var i = 0; i < 3; i++) {
        p.onFailure(kind: FailureKind.stall, live: true, now: t0);
      }
      expect(p.recovering, isTrue);
      p.markGood(t0);
      p.markGood(t0.add(const Duration(seconds: 30)));
      expect(p.recovering, isTrue);
      p.markGood(t0.add(const Duration(seconds: 61)));
      expect(p.recovering, isFalse);
      expect(
          p.onFailure(
              kind: FailureKind.stall,
              live: true,
              now: t0.add(const Duration(seconds: 62))),
          const RecoveryStep(RecoveryKind.retry, Duration(milliseconds: 500)));
    });

    test('Störung unterbricht die 60 s', () {
      final p = ReconnectPolicy();
      final t0 = DateTime(2026);
      p.onFailure(kind: FailureKind.stall, live: true, now: t0);
      p.markGood(t0);
      p.onFailure(kind: FailureKind.stall, live: true, now: t0); // retries = 2
      p.markGood(t0.add(const Duration(seconds: 50)));
      p.markGood(t0.add(const Duration(seconds: 70)));
      expect(p.recovering, isTrue, reason: 'erst 20 s am Stück gut');
    });

    test('isDecoderError', () {
      expect(ReconnectPolicy.isDecoderError('vd: Could not open codec'), isTrue);
      expect(ReconnectPolicy.isDecoderError('Error decoding frame'), isTrue);
      expect(ReconnectPolicy.isDecoderError('tcp: Connection reset'), isFalse);
    });
  });

  group('Hänger (Wachhund „eingefroren“)', () {
    WatchSample play(int s, {bool active = true}) => WatchSample(
        active: active,
        playing: true,
        buffering: false,
        position: Duration(seconds: s),
        hasFirstFrame: true,
        videoExpected: false);

    test('steht die Position, gilt das nach 7 s als Hänger', () {
      final d = PlaybackWatchdog()..reset(live: true);
      final t0 = DateTime(2026);
      Duration sec(int s) => Duration(seconds: s);
      expect(d.sample(play(0), t0), isNull);
      expect(d.sample(play(1), t0.add(sec(1))), isNull);
      for (var i = 2; i <= 7; i++) {
        expect(d.sample(play(1), t0.add(sec(i))), isNull);
      }
      expect(d.sample(play(1), t0.add(sec(8))), WatchAlarm.frozen);
    });

    test('pausiert ist kein Hänger', () {
      final d = PlaybackWatchdog()..reset(live: true);
      final t0 = DateTime(2026);
      d.sample(play(5), t0);
      d.sample(play(6), t0.add(const Duration(seconds: 1)));
      for (var i = 2; i < 120; i++) {
        expect(d.sample(play(6, active: false), t0.add(Duration(seconds: i))),
            isNull);
      }
      // Weiter: Frist beginnt neu.
      final t1 = t0.add(const Duration(seconds: 120));
      expect(d.sample(play(6), t1), isNull);
      expect(d.sample(play(6), t1.add(const Duration(seconds: 1))), isNull);
      expect(d.sample(play(6), t1.add(const Duration(seconds: 2))), isNull);
    });
  });

  group('Live-Pause', () {
    final t0 = DateTime(2026, 10, 21, 20);
    Duration s(int v) => Duration(seconds: v);

    test('Pause → Rückstand wächst, Weiter behält ihn', () {
      final ts = TimeshiftState(window: const Duration(minutes: 10), now: t0);
      expect(ts.isShifted(t0), isFalse);
      ts.pause(t0.add(s(60)));
      expect(ts.paused, isTrue);
      expect(ts.behind(t0.add(s(120))), s(60));
      ts.resume(t0.add(s(814)));
      expect(ts.behind(t0.add(s(900))), s(600), reason: 'höchstens Puffer');
      expect(fmtBehind(ts.behind(t0.add(s(900)))), '−10:00');
    });

    test('Spulen bleibt im Puffer und nicht über Live hinaus', () {
      final ts = TimeshiftState(window: const Duration(minutes: 10), now: t0);
      ts.pause(t0.add(s(100)));
      ts.resume(t0.add(s(160))); // 60 s zurück
      final at = t0.add(s(170));
      expect(ts.seek(s(10), at), s(10)); // vor
      expect(ts.behind(at), s(50));
      expect(ts.seek(s(100), at), s(50)); // nur bis Live
      expect(ts.behind(at), Duration.zero);
      expect(ts.isShifted(at), isFalse);
      // Zurück höchstens bis zum Pufferanfang (seit dem Öffnen 170 s).
      expect(ts.seek(s(-1000), at), s(-170));
      expect(ts.behind(at), s(170));
    });

    test('Zappen leert den Puffer; „Zurück zu Live“', () {
      final ts = TimeshiftState(window: const Duration(minutes: 10), now: t0);
      ts.pause(t0);
      expect(ts.behind(t0.add(s(30))), s(30));
      ts.goLive();
      expect(ts.isShifted(t0.add(s(30))), isFalse);
      ts.pause(t0.add(s(40)));
      ts.reset(t0.add(s(50)));
      expect(ts.paused, isFalse);
      expect(ts.behind(t0.add(s(60))), Duration.zero);
    });

    test('ohne Puffer keine Live-Pause', () {
      final ts = TimeshiftState(window: Duration.zero, now: t0);
      ts.pause(t0);
      expect(ts.paused, isFalse);
      expect(ts.enabled, isFalse);
    });

    test('Abgleich mit mpv', () {
      final ts = TimeshiftState(window: const Duration(minutes: 10), now: t0);
      ts.pause(t0);
      ts.resume(t0.add(s(90)));
      ts.sync(s(84), t0.add(s(100)));
      expect(ts.behind(t0.add(s(100))), s(84));
    });

    test('Puffergröße: Einstellung, Arbeitsspeicher, Low-RAM', () {
      expect(planLiveBuffer(0, null), isNull);
      // Unbekannter Speicher: vorsichtig (160 MB).
      final unknown = planLiveBuffer(30, null)!;
      expect(unknown.forwardBytes + unknown.backBytes, 160 << 20);
      expect(unknown.window.inMinutes, inInclusiveRange(2, 4));
      // Viel Speicher: 10 Minuten ganz.
      final big = planLiveBuffer(
          10, (avail: 3 << 30, total: 4 << 30, lowRam: false))!;
      expect(big.forwardBytes + big.backBytes, 10 * 60 * liveBytesPerSecond);
      // Knapper Speicher: 30 % des freien.
      final small = planLiveBuffer(
          30, (avail: 400 << 20, total: 2 << 30, lowRam: false))!;
      expect(small.forwardBytes + small.backBytes, (400 << 20) * 3 ~/ 10);
      // Mi Box (2 GB, viel frei): höchstens 160 MB.
      final mibox = planLiveBuffer(
          30, (avail: 1200 << 20, total: 1900 << 20, lowRam: false))!;
      expect(mibox.forwardBytes + mibox.backBytes, 160 << 20);
      // Low-RAM-Gerät: höchstens 48 MB.
      final low =
          planLiveBuffer(30, (avail: 1 << 30, total: 1 << 30, lowRam: true))!;
      expect(low.forwardBytes + low.backBytes, 48 << 20);
      // Fast nichts frei: lieber gar keine Live-Pause.
      expect(
          planLiveBuffer(10, (avail: 30 << 20, total: 1 << 30, lowRam: false)),
          isNull);
    });

    test('fmtBehind', () {
      expect(fmtBehind(const Duration(minutes: 12, seconds: 34)), '−12:34');
      expect(fmtBehind(const Duration(seconds: 5)), '−0:05');
      expect(fmtBehind(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '−1:02:03');
    });
  });
}
