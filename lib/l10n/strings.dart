import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'translations.g.dart';

/// App-Sprachen. Quelltexte sind Deutsch; Englisch/Türkisch kommen aus
/// lib/l10n/arb/*.arb (generiert nach translations.g.dart via
/// `dart run tool/gen_l10n.dart`) und werden über den deutschen Text
/// nachgeschlagen. Fehlt eine
/// Übersetzung, bleibt der deutsche Text stehen – nie ein leerer Text.
class L10n {
  /// Vorgabe beim ersten Start; die türkische APK setzt
  /// --dart-define=DEFAULT_LANG=tr.
  static const defaultChoice =
      String.fromEnvironment('DEFAULT_LANG', defaultValue: 'system');

  static const supported = ['de', 'en', 'tr'];
  static const names = {'de': 'Deutsch', 'en': 'English', 'tr': 'Türkçe'};

  /// Aktuelle Sprache (global, damit auch Fehlermeldungen außerhalb der UI
  /// übersetzt werden).
  static String lang =
      defaultChoice == 'system' ? systemLang() : defaultChoice;

  static String systemLang() {
    final l = PlatformDispatcher.instance.locale.languageCode;
    return supported.contains(l) ? l : 'en';
  }

  static final Map<String, Map<String, String>> _tables = {
    for (final e in translations.entries) e.key: {...e.value},
  };

  static String t(String de) =>
      lang == 'de' ? de : (_tables[lang]?[de] ?? de);

  /// Übersetzung mit Platzhaltern: tf('Aufnahme bis {0}', [zeit]).
  static String tf(String de, List<Object?> args) {
    var s = t(de);
    for (var i = 0; i < args.length; i++) {
      s = s.replaceAll('{$i}', '${args[i]}');
    }
    return s;
  }

  @visibleForTesting
  static Map<String, Map<String, String>> get tables => _tables;
}

/// Kurzform für UI-Texte.
String tr(String de) => L10n.t(de);
String trf(String de, List<Object?> args) => L10n.tf(de, args);

/// Gewählte Sprache: 'system', 'de', 'en' oder 'tr'.
class AppLangNotifier extends Notifier<String> {
  @override
  String build() {
    ref.listen(storageProvider, (_, next) {
      final st = next.value;
      if (st != null) _apply(st.option('applang', L10n.defaultChoice));
    }, fireImmediately: true);
    return L10n.lang;
  }

  void _apply(String choice) {
    L10n.lang = choice == 'system' ? L10n.systemLang() : choice;
    state = L10n.lang;
  }

  String get choice =>
      ref.read(storageProvider).value?.option('applang', L10n.defaultChoice) ??
      L10n.defaultChoice;

  Future<void> set(String choice) async {
    final st = await ref.read(storageProvider.future);
    await st.setOption('applang', choice);
    _apply(choice);
  }
}

final appLangProvider =
    NotifierProvider<AppLangNotifier, String>(AppLangNotifier.new);

/// Für Widgets, die per context arbeiten wollen.
class S {
  const S();
  static S of(BuildContext context) => const S();
  String get recordings => tr('Aufnahmen');
  String get recordingsHint => tr('Aufnahmen laufen auch bei geschlossener App '
      'und ausgeschaltetem Bildschirm (mit Hinweis in der Benachrichtigungsleiste). '
      'Gespeichert im App-Ordner (Android/data/de.jasonstream.player).');
  String get noRecordings => tr('Noch keine Aufnahmen');
  String get cancel => tr('Abbrechen');
  String get delete => tr('Löschen');
}
