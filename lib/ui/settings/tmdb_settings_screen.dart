import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/tmdb.dart';
import '../widgets/dpad_text_field.dart';
import '../widgets/focusable_tile.dart';

/// TMDB-Hinweis (Nutzungsbedingungen der TMDB-API).
const tmdbNotice =
    'This product uses the TMDB API but is not endorsed or certified by TMDB.';

/// Einstellungen → „Film-Infos (TMDB)“: eigener API-Schlüssel (v3 oder
/// v4-Token, verschlüsselt gespeichert), „Verbindung testen“, Quelle.
/// Ohne Schlüssel: alles wie bisher, kein Netzverkehr zu TMDB.
class TmdbSettingsScreen extends ConsumerStatefulWidget {
  const TmdbSettingsScreen({super.key});

  @override
  ConsumerState<TmdbSettingsScreen> createState() => _TmdbSettingsState();
}

class _TmdbSettingsState extends ConsumerState<TmdbSettingsScreen> {
  final _key = TextEditingController();
  bool _show = false;
  bool _busy = false;
  String? _error;
  String? _ok;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  static String errorText(TmdbErrorKind k) => switch (k) {
        TmdbErrorKind.invalidKey =>
          tr('TMDB lehnt den Schlüssel ab. Bitte prüfen (API-Schlüssel v3 oder Lese-Token v4).'),
        TmdbErrorKind.network =>
          tr('TMDB ist nicht erreichbar. Internetverbindung prüfen.'),
        TmdbErrorKind.rateLimited =>
          tr('TMDB bremst gerade (zu viele Anfragen). Bitte gleich nochmal.'),
        TmdbErrorKind.server => tr('TMDB antwortet nicht wie erwartet.'),
      };

  Future<void> _save({bool test = true}) async {
    if (_busy) return;
    final raw = TmdbKey.clean(_key.text);
    setState(() {
      _error = null;
      _ok = null;
    });
    if (raw.isEmpty) return;
    if (!TmdbKey.plausible(raw)) {
      setState(() => _error = tr(
          'Das sieht nicht wie ein TMDB-Schlüssel aus (32 Zeichen v3-Schlüssel oder langer v4-Token „eyJ…“).'));
      return;
    }
    final st = await ref.read(storageProvider.future);
    await st.setTmdbKey(raw);
    _key.clear();
    ref.invalidate(storageProvider);
    if (test) await _test(raw);
  }

  Future<void> _test([String? key]) async {
    final st = await ref.read(storageProvider.future);
    final k = key ?? st.tmdbKey;
    if (k == null || k.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      await TmdbClient(
              key: k,
              client: ref.read(tmdbHttpProvider),
              cache: MemoryTmdbCache())
          .test();
      if (mounted) setState(() => _ok = tr('Verbindung zu TMDB in Ordnung.'));
    } on TmdbException catch (e) {
      if (mounted) setState(() => _error = errorText(e.kind));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final st = await ref.read(storageProvider.future);
    await st.setTmdbKey(null);
    ref.invalidate(storageProvider);
    setState(() {
      _ok = null;
      _error = null;
    });
  }

  Future<void> _setSource(TmdbSource s) async {
    final st = await ref.read(storageProvider.future);
    await st.setOption(TmdbSource.optionKey, s.id);
    ref.invalidate(storageProvider);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(tmdbSettingsProvider);
    final t = Theme.of(context).textTheme;
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
          child: Text(text, style: t.labelSmall),
        );
    Widget source(TmdbSource v, String label, String sub) => Semantics(
          selected: s.source == v,
          child: FocusableTile(
            key: ValueKey('tmdb-src-${v.id}'),
            onTap: () => _setSource(v),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Icon(
                    s.source == v
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    color:
                        s.source == v ? AppColors.accent : AppColors.textFaint),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: t.titleSmall?.copyWith(fontSize: 15)),
                        Text(sub, style: t.bodySmall),
                      ]),
                ),
              ]),
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(tr('Film-Infos (TMDB)'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              Text(
                  tr('Mit einem eigenen, kostenlosen TMDB-Schlüssel ergänzt die '
                      'App fehlende Poster, Beschreibungen, Genres, Bewertungen, '
                      'Besetzung mit Fotos und Trailer. Ohne Schlüssel bleibt '
                      'alles wie bisher – es geht keine Anfrage an TMDB.'),
                  style: t.bodyMedium),
              heading(tr('API-SCHLÜSSEL')),
              Row(children: [
                Icon(
                    s.hasKey
                        ? Icons.verified_rounded
                        : Icons.key_off_rounded,
                    color: s.hasKey ? AppColors.accent : AppColors.textFaint),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      s.hasKey
                          ? tr('Schlüssel gespeichert (verschlüsselt)')
                          : tr('Kein Schlüssel – TMDB ist aus'),
                      key: const ValueKey('tmdb-key-state'),
                      style: t.titleSmall),
                ),
              ]),
              const SizedBox(height: 10),
              DpadTextField(
                controller: _key,
                builder: (_, dp) => TextField(
                  key: const ValueKey('tmdb-key'),
                  controller: _key,
                  obscureText: !_show,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: s.hasKey
                        ? tr('Neuen Schlüssel eingeben')
                        : tr('API-Schlüssel (v3) oder Lese-Token (v4)'),
                    suffixIcon: ExcludeFocus(
                      child: IconButton(
                        onPressed: () => setState(() => _show = !_show),
                        icon: Icon(_show
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded),
                      ),
                    ),
                  ),
                  onSubmitted: (_) {
                    dp.submitted();
                    _save();
                  },
                  readOnly: dp.readOnly,
                  showCursor: dp.showCursor,
                  onTap: dp.onTap,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 10, runSpacing: 10, children: [
                FilledButton.icon(
                  key: const ValueKey('tmdb-save'),
                  onPressed: () => _save(),
                  icon: const Icon(Icons.save_rounded),
                  label: Text(tr('Speichern & testen')),
                ),
                if (s.hasKey)
                  OutlinedButton.icon(
                    key: const ValueKey('tmdb-test'),
                    onPressed: () => _test(),
                    icon: const Icon(Icons.wifi_tethering_rounded),
                    label: Text(tr('Verbindung testen')),
                  ),
                if (s.hasKey)
                  TextButton.icon(
                    key: const ValueKey('tmdb-remove'),
                    onPressed: _remove,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text(tr('Schlüssel entfernen')),
                  ),
              ]),
              if (_busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (_ok != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_ok!,
                      key: const ValueKey('tmdb-ok'),
                      style: t.bodyMedium?.copyWith(color: AppColors.accent)),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!,
                      key: const ValueKey('tmdb-error'),
                      style: t.bodyMedium?.copyWith(color: AppColors.live)),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    tr('Schlüssel anlegen: themoviedb.org → Konto → '
                        'Einstellungen → API.'),
                    style: t.bodySmall),
              ),
              heading(tr('QUELLE')),
              source(TmdbSource.provider, tr('Nur Anbieter'),
                  tr('TMDB wird nicht gefragt')),
              source(TmdbSource.mix, tr('Anbieter + TMDB'),
                  tr('Fehlende Angaben aus TMDB ergänzen (empfohlen)')),
              source(TmdbSource.tmdb, tr('TMDB bevorzugt'),
                  tr('TMDB-Angaben ersetzen die des Anbieters, wo vorhanden')),
              heading(tr('SPRACHE')),
              Text(
                  trf('Wie die App-Sprache: {0}', [
                    L10n.names[L10n.lang] ?? L10n.lang,
                  ]),
                  style: t.bodyMedium),
              Text(
                  tr('Im Datensparmodus werden kleinere Bilder geladen. '
                      'Antworten werden 14 Tage auf dem Gerät gespeichert.'),
                  style: t.bodySmall),
              const SizedBox(height: 24),
              Text(tmdbNotice,
                  key: const ValueKey('tmdb-notice'),
                  style: t.bodySmall?.copyWith(color: AppColors.textFaint)),
            ],
          ),
        ),
      ),
    );
  }
}
