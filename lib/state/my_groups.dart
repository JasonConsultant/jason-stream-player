import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'providers.dart';

/// Eigene Gruppe („Fußball“, „Kinder“ …) mit Sendern aus beliebigen
/// Anbieter-Gruppen. Pro Portal gespeichert.
class MyGroup {
  static const prefix = 'my_';
  final String id;
  final String name;
  final List<String> channels;
  const MyGroup(this.id, this.name, this.channels);

  static bool isMy(String categoryId) => categoryId.startsWith(prefix);

  Map<String, Object> toJson() => {'id': id, 'n': name, 'c': channels};
  factory MyGroup.fromJson(Map<String, dynamic> j) => MyGroup(
      j['id'] as String, j['n'] as String, (j['c'] as List).cast<String>());

  MyGroup copy({String? name, List<String>? channels}) =>
      MyGroup(id, name ?? this.name, channels ?? this.channels);
}

class MyGroupsNotifier extends AsyncNotifier<List<MyGroup>> {
  String _key(String portalId) => 'mygroups_$portalId';

  @override
  Future<List<MyGroup>> build() async {
    final s = await ref.watch(storageProvider.future);
    final p = await ref.watch(activePortalProvider.future);
    if (p == null) return const [];
    try {
      return (jsonDecode(s.option(_key(p.id), '[]')) as List)
          .map((e) => MyGroup.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _save(List<MyGroup> list) async {
    final s = await ref.read(storageProvider.future);
    final p = await ref.read(activePortalProvider.future);
    if (p == null) return;
    await s.setOption(
        _key(p.id), jsonEncode([for (final g in list) g.toJson()]));
    state = AsyncData(list);
  }

  List<MyGroup> get _list => state.value ?? const [];

  Future<MyGroup> create(String name, {List<String> channels = const []}) async {
    final g = MyGroup('${MyGroup.prefix}${const Uuid().v4().substring(0, 8)}',
        name.trim(), [...channels]);
    await _save([..._list, g]);
    return g;
  }

  Future<void> rename(String id, String name) => _save([
        for (final g in _list) g.id == id ? g.copy(name: name.trim()) : g
      ]);

  Future<void> delete(String id) =>
      _save([for (final g in _list) if (g.id != id) g]);

  /// Sender hinzufügen bzw. entfernen.
  Future<void> toggle(String groupId, String channelId) => _save([
        for (final g in _list)
          if (g.id != groupId)
            g
          else
            g.copy(
                channels: g.channels.contains(channelId)
                    ? [for (final c in g.channels) if (c != channelId) c]
                    : [...g.channels, channelId])
      ]);

  /// Reihenfolge der Gruppen.
  Future<void> reorder(List<String> ids) {
    final byId = {for (final g in _list) g.id: g};
    return _save([
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
      for (final g in _list)
        if (!ids.contains(g.id)) g,
    ]);
  }
}

final myGroupsProvider =
    AsyncNotifierProvider<MyGroupsNotifier, List<MyGroup>>(MyGroupsNotifier.new);
