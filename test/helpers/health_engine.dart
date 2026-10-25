import 'package:jason_stream_player/player/engine.dart';

import 'fake_engine.dart';

/// Fake-Engine mit Messwerten (wie mpv/Exo über [EngineHealthSource]).
class HealthEngine extends FakeEngine implements EngineHealthSource {
  HealthEngine({super.id, super.config});
  EngineHealth h = EngineHealth.unknown;
  int fullCalls = 0;

  @override
  Future<EngineHealth> health({bool full = false}) async {
    if (full) fullCalls++;
    return h;
  }

  @override
  bool get hasDecoderFallback => id == 'exo';

  static Future<PlaybackEngine> factory(EngineConfig c) async {
    final e = HealthEngine(id: c.engine, config: c);
    FakeEngine.created.add(e);
    return e;
  }
}
