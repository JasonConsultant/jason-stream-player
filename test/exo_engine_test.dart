
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/player/engine.dart';
import 'package:jason_stream_player/player/exo_engine.dart';
import 'package:jason_stream_player/player/media_session.dart';
import 'package:jason_stream_player/state/playback_session.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/player/mpv_tuning.dart';
import 'package:jason_stream_player/core/subtitle_style.dart';
import 'package:jsp_exoplayer/jsp_exoplayer.dart';

/// ExoEngine gegen einen gemockten Plattformkanal: Abbildung der
/// mpv-Optionen, Ereignisse → Streams, Untertitel-Verzögerung, Statistik.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Map<String, Object?> stats;
  MockStreamHandlerEventSink? sink;

  setUp(() {
    calls = [];
    stats = {};
    sink = null;
    messenger.setMockMethodCallHandler(JspExoChannels.method, (c) async {
      calls.add(c);
      switch (c.method) {
        case 'create':
          return {'id': 7, 'textureId': 42};
        case 'stats':
          return stats;
      }
      return null;
    });
    messenger.setMockStreamHandler(
        EventChannel(JspExoChannels.events(7)),
        MockStreamHandler.inline(
            onListen: (args, events) {
              sink = events;
            },
            onCancel: (_) {
              sink = null;
            }));
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(JspExoChannels.method, null);
    messenger.setMockStreamHandler(EventChannel(JspExoChannels.events(7)), null);
  });

  Future<ExoEngine> create([EngineConfig c = const EngineConfig(engine: 'exo')]) async {
    final e = await ExoEngine.createForTest(c);
    await Future<void>.delayed(Duration.zero);
    return e;
  }

  MethodCall last(String m) => calls.lastWhere((c) => c.method == m);
  Map<Object?, Object?> args(String m) => last(m).arguments as Map;

  Future<void> event(Map<String, Object?> e) async {
    sink!.success(e);
    await Future<void>.delayed(Duration.zero);
  }

  test('create legt Player mit Textur an', () async {
    final e = await create();
    expect(calls.first.method, 'create');
    expect(e.textureId, 42);
    expect(e.id, 'exo');
    expect(e.supportsOptions, isTrue);
    expect(sink, isNotNull, reason: 'Ereigniskanal abonniert');
    await e.dispose();
    expect(last('dispose').arguments, {'id': 7});
  });

  test('mpv-Optionen → Kopfzeilen, Puffer, Decoder, Durchreichen', () async {
    final e = await create(const EngineConfig(engine: 'exo', bufferBytes: 16 << 20));
    final props = MpvProps(e.setOption);
    await props.apply(MpvTuning.constant);
    await props.apply(MpvTuning.perOpen(
      live: true,
      plan: null,
      bufferBytes: 16 << 20,
      userAgent: 'VLC/3',
      referrer: 'http://portal/',
      subtitles: const SubtitleStyle(),
      passthrough: true,
    ));
    // Kopfzeilen fehlen beim Öffnen → aus user-agent/referrer ergänzt.
    await e.open('http://s/1.ts', live: true);
    final a = args('open');
    expect(a['url'], 'http://s/1.ts');
    expect(a['live'], isTrue);
    expect(a['headers'], {'User-Agent': 'VLC/3', 'Referer': 'http://portal/'});
    expect(a['bufferBytes'], 16 << 20);
    expect(a['passthrough'], isTrue);
    expect(a['softwareVideo'], isFalse);
    // Ohne Live-Pause kein Rückpuffer.
    expect(a['backBytes'], 0);
    // Nicht abbildbar → still ignoriert.
    expect(e.ignored, containsAll(['network-timeout', 'demuxer-lavf-probesize', 'sub-font-size']));
    // Vorhandene Kopfzeilen gewinnen.
    await e.open('http://s/2.ts', headers: {'user-agent': 'Own'});
    expect((args('open')['headers'] as Map), {'user-agent': 'Own', 'Referer': 'http://portal/'});
    await e.dispose();
  });

  test('hwdec=no → Software zuerst; Live-Pause → Rückpuffer', () async {
    final e = await create(const EngineConfig(engine: 'exo', hwdec: 'no'));
    expect(await e.getOption('hwdec'), 'no');
    await e.setOption('hwdec', 'auto');
    expect(await e.getOption('hwdec'), 'auto');
    await e.setOption('hwdec', 'no');
    await e.setOption('demuxer-seekable-cache', 'yes');
    await e.setOption('demuxer-max-bytes', '400000000');
    await e.setOption('demuxer-max-back-bytes', '300000000');
    await e.open('http://s/1.ts', live: true);
    final a = args('open');
    expect(a['softwareVideo'], isTrue);
    expect(a['backBytes'], 300000000);
    expect(a['forwardBytes'], 400000000);
    await e.dispose();
  });

  test('Schalter „Hardware-Dekodierung“ aus → Software zuerst', () async {
    final e = await create(
        const EngineConfig(engine: 'exo', hardwareAcceleration: false));
    await e.open('http://s/1.ts');
    expect(args('open')['softwareVideo'], isTrue);
    await e.dispose();
  });

  test('Medienserver-Untertitel gehen beim Öffnen mit', () async {
    final e = await create();
    await e.open('http://emby/v.mkv', subtitles: const [
      EngineSubtitle('http://emby/s/Stream.srt', title: 'Deutsch', language: 'deu'),
    ]);
    expect(args('open')['subtitles'], [
      {'url': 'http://emby/s/Stream.srt', 'language': 'deu', 'label': 'Deutsch', 'codec': null}
    ]);
    // sub-add (mpv) ist ohne Wirkung.
    await e.command(['sub-add', 'x']);
    expect(calls.where((c) => c.method == 'command'), isEmpty);
    await e.dispose();
  });

  test('Ereignisse → Zustand und Streams', () async {
    final e = await create();
    final playing = <bool>[], buffering = <bool>[], completed = <bool>[];
    final widths = <int?>[];
    e.stream.playing.listen(playing.add);
    e.stream.buffering.listen(buffering.add);
    e.stream.completed.listen(completed.add);
    e.stream.width.listen(widths.add);
    await e.open('http://s/m.mp4');
    expect(e.state.buffering, isTrue);
    await event({'e': 'state', 'state': 'ready', 'playing': true});
    expect(e.state.buffering, isFalse);
    expect(e.state.playing, isTrue);
    await event({'e': 'pos', 'pos': 61000, 'dur': 7200000, 'buf': 75000});
    expect(e.state.position, const Duration(seconds: 61));
    expect(e.state.duration, const Duration(hours: 2));
    await event({'e': 'size', 'width': 720, 'height': 576, 'par': 64 / 45});
    expect(e.state.width, 720);
    expect(e.state.hasVideo, isTrue);
    expect(e.videoAspect, closeTo(16 / 9, 0.001));
    await event({'e': 'state', 'state': 'ended', 'playing': true});
    expect(e.state.completed, isTrue);
    expect(e.state.playing, isFalse);
    expect(completed.last, isTrue);
    expect(widths.last, 720);
    expect(buffering, containsAllInOrder([true, false]));
    expect(await e.getOption('time-pos'), '61.000');
    await e.dispose();
  });

  test('Spuren: auto/no vorn, Codec und Kanäle im Titel', () async {
    final t = ExoEngine.parseTracks([
      {'id': 'audio:0:0', 'type': 'audio', 'language': 'de', 'label': null, 'mime': 'audio/ac3', 'channels': 6},
      {'id': 'audio:0:1', 'type': 'audio', 'language': 'en', 'label': 'Original', 'mime': 'audio/mp4a-latm', 'channels': 2},
      {'id': 'text:1:0', 'type': 'text', 'language': 'de', 'label': 'Forced'},
      {'id': 'text:2:0', 'type': 'text', 'language': 'xx', 'supported': false},
      {'id': 'video:3:0', 'type': 'video', 'width': 1920},
    ]);
    expect([for (final a in t.audio) a.id], ['auto', 'no', 'audio:0:0', 'audio:0:1']);
    expect(t.audio[2].title, 'AC3 5.1');
    expect(t.audio[2].language, 'de');
    expect(t.audio[3].title, 'Original · AAC Stereo');
    expect([for (final s in t.subtitle) s.id], ['auto', 'no', 'text:1:0']);
  });

  test('Spurwahl, Lautstärke, Nur-Ton gehen an den Kanal', () async {
    final e = await create();
    await e.setAudioTrack(const EngineTrack('audio:0:1'));
    expect(args('selectTrack'), {'id': 7, 'type': 'audio', 'track': 'audio:0:1'});
    expect(e.state.track.audio.id, 'audio:0:1');
    await e.setSubtitleTrack(EngineTrack.no);
    expect(args('selectTrack'), {'id': 7, 'type': 'text', 'track': 'no'});
    await e.setVolume(25);
    expect(args('setVolume')['volume'], 0.25);
    await e.setVideoEnabled(false);
    expect(args('setVideoEnabled')['enabled'], isFalse);
    await e.seek(const Duration(seconds: 90));
    expect(args('seek')['ms'], 90000);
    await e.dispose();
  });

  test('Fehler mit Kategorie: erst failure, dann Text', () async {
    final e = await create();
    final order = <String>[];
    e.stream.failure.listen((f) => order.add('failure ${f.kind.name}'));
    e.stream.error.listen((m) => order.add('error $m'));
    await event({
      'e': 'error',
      'category': 'decoder',
      'code': 4001,
      'message': 'Decoder error (ERROR_CODE_DECODER_INIT_FAILED)',
    });
    await event({'e': 'error', 'category': 'network', 'code': 2004, 'message': 'HTTP error 403'});
    expect(order, [
      'failure decoder',
      'error Decoder error (ERROR_CODE_DECODER_INIT_FAILED)',
      'failure network',
      'error HTTP error 403',
    ]);
    expect(EngineErrorKind.decoder.wantsCompat, isTrue);
    expect(EngineErrorKind.container.wantsCompat, isTrue);
    expect(EngineErrorKind.format.wantsCompat, isTrue);
    expect(EngineErrorKind.network.wantsCompat, isFalse);
    expect(EngineErrorKind.drm.wantsCompat, isFalse);
    await e.dispose();
  });

  test('Statistik → mpv-Diagnosewerte und Exo-Zeilen', () async {
    final e = await create();
    stats = {
      'videoDecoder': 'c2.amlogic.avc.decoder',
      'videoHw': true,
      'audioDecoder': 'ffmpegAudio',
      'audioHw': false,
      'videoMime': 'video/avc',
      'audioMime': 'audio/ac3',
      'audioChannels': 6,
      'width': 1920,
      'height': 1080,
      'fps': 50.0,
      'dropped': 3,
      'bufferedMs': 12300,
      'bufferedPositionMs': 95000,
      'bitrate': 6200000,
      'bandwidth': 24000000,
    };
    expect(await e.getOption('hwdec-current'), 'mediacodec');
    expect(await e.getOption('current-vo'), 'exo-texture');
    expect(await e.getOption('video-codec'), 'h264');
    expect(await e.getOption('video-params/w'), '1920');
    expect(await e.getOption('container-fps'), '50.000');
    expect(await e.getOption('frame-drop-count'), '3');
    expect(await e.getOption('demuxer-cache-duration'), '12.3');
    expect(await e.getOption('demuxer-cache-time'), '95.000');
    expect(await e.getOption('estimated-vf-fps'), isNull);
    final lines = await e.diagnostics();
    expect(lines, [
      'ExoPlayer',
      'dec c2.amlogic.avc.decoder (HW)',
      'audio ffmpegAudio (SW) AC3 5.1',
      'h264 1920×1080 · fps 50.00',
      'drop 3',
      'bitrate 6.2 Mbit/s · net 24.0',
      'buffer 12.3 s',
    ]);
    await e.dispose();
  });

  test('Untertitel: positive Verzögerung hält zurück, negative nicht',
      () async {
    final e = await create();
    await e.setOption('sub-delay', '0.5');
    await event({
      'e': 'cues',
      'pos': 1000,
      'cues': [
        {'text': 'Hallo'}
      ]
    });
    expect(e.cues.value, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(e.cues.value, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(e.cues.value.single.text, 'Hallo');
    // Sprung: Zurückgehaltenes verwerfen.
    await event({
      'e': 'cues',
      'pos': 2000,
      'cues': [
        {'text': 'Später'}
      ]
    });
    await e.seek(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(e.cues.value, isEmpty);
    // Negativ: sofort (früher geht mit Media3 nicht).
    await e.setOption('sub-delay', '-2.0');
    await event({
      'e': 'cues',
      'pos': 3000,
      'cues': [
        {'text': 'Jetzt'},
        {
          'png': Uint8List.fromList([1, 2, 3]),
          'x': 0.5,
          'w': 0.4
        }
      ]
    });
    expect(e.cues.value, hasLength(2));
    expect(e.cues.value[1].png, isNotNull);
    expect(e.subtitleDelay, -2.0);
    await e.dispose();
  });

  testWidgets('Videofläche: Textur und Flutter-Untertitel', (tester) async {
    late ExoEngine e;
    await tester.runAsync(() async {
      e = await ExoEngine.createForTest(const EngineConfig(engine: 'exo'));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpWidget(MaterialApp(
        home: SizedBox(
            width: 800,
            height: 450,
            child: e.buildVideo(fit: BoxFit.contain)!)));
    expect(find.byKey(const ValueKey('exo-texture')), findsNothing);
    await tester.runAsync(() async {
      await event({'e': 'size', 'width': 1920, 'height': 1080, 'par': 1.0});
      await event({
        'e': 'cues',
        'pos': 1,
        'cues': [
          {'text': 'Untertitel'}
        ]
      });
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('exo-texture')), findsOneWidget);
    expect(find.text('Untertitel'), findsOneWidget);
    await tester.runAsync(e.dispose);
  });

  test('Mini-Player und Nur-Ton mit ExoEngine (Controller)', () async {
    final media = NoopMediaSession();
    final c = ProviderContainer(overrides: [
      isTvProvider.overrideWithValue(false),
      mediaSessionProvider.overrideWithValue(media),
      playbackEngineProvider.overrideWithValue(ExoEngine.createForTest),
    ]);
    addTearDown(c.dispose);
    final ctl = c.read(playbackProvider.notifier);
    final s = await ctl.start(
        const PlayRequest(title: 'Film', url: 'http://s/m.mp4'),
        config: const EngineConfig(engine: 'exo'));
    await Future<void>.delayed(Duration.zero);
    expect(s.engine, isA<ExoEngine>());
    await s.engine.open('http://s/m.mp4');
    await event({'e': 'state', 'state': 'ready', 'playing': true});
    await event({'e': 'size', 'width': 1280, 'height': 720, 'par': 1.0});
    ctl.toMini();
    expect(c.read(playbackProvider).showMini, isTrue);
    expect(c.read(playbackProvider).playing, isTrue);
    expect(c.read(playbackProvider).hasVideo, isTrue);
    // Nur-Ton: Videospur abwählen.
    await ctl.setAudioOnly(true);
    expect(args('setVideoEnabled')['enabled'], isFalse);
    expect(c.read(playbackProvider).audioOnly, isTrue);
    // Benachrichtigung: Pause/Weiter gehen an den nativen Player.
    await ctl.setPaused(true);
    expect(last('pause').method, 'pause');
    expect(media.updates.last.playing, isFalse);
    // Medien-Steuerung (Sperrbildschirm) bedient die Exo-Engine.
    media.callbacks!.onPlay();
    await Future<void>.delayed(Duration.zero);
    await ctl.setPaused(false);
    expect(last('play').method, 'play');
    // Engine-Wechsel behält Nur-Ton.
    final swapped = await ctl.swapEngine('exo');
    expect(swapped!.audioOnly, isTrue);
    expect(calls.where((x) => x.method == 'dispose'), hasLength(1));
    await ctl.stop();
    expect(calls.where((x) => x.method == 'dispose'), hasLength(2));
    expect(c.read(playbackProvider).active, isFalse);
  });
}
