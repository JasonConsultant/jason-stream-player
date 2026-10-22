# :player – öffentliche Schnittstelle

Modul `:player`, Paket `de.jasonstream.playback` (Namespace bewusst ≠ App,
sonst kollidieren die R-Klassen). `:app` hängt bereits davon ab
(`implementation(project(":player"))`).

## Einstieg

```kotlin
import de.jasonstream.playback.PlayerScreen
import de.jasonstream.playback.api.PlayRequest
import de.jasonstream.playback.api.PlayerDeps

PlayerScreen(
    request = PlayRequest.live(portal.id, channelsOfGroup, index),
    deps = myDeps,                         // : PlayerDeps
    onExit = { nav.popBackStack() },
    onOpenGuide = { nav.openGuide() },     // Blau / Guide-Taste
    onOpenChannelList = { showLiveOverlay = true }, // ◀ bei ausgeblendeter Leiste
    engine = activityEngine,               // optional, sonst eigene
    onRequestChanged = { current = it },   // optional: nach internem Zappen
    keepPlayingOnExit = false,             // true: externe Engine läuft weiter (Mini-Bild)
)
```

* Der Player nimmt den **ganzen Bildschirm** ein und fängt die Tasten der
  Fernbedienung selbst ab (Fokus). Wird ein App-Overlay (Senderliste) darüber
  gelegt, muss es den Fokus holen; der Player reagiert nicht, solange er den
  Fokus nicht hat. Danach Fokus zurück (einfach Overlay schließen – der
  Player holt sich den Fokus bei der nächsten Komposition).
* Meldet der Player über `onRequestChanged` einen neuen Stand und gibt die
  App ihn (auch leicht verändert, z. B. neue Listen-Instanz) zurück, öffnet
  er nicht erneut (Vergleich nach Art/Portal/Sender/Sendung/Adresse).
* Neue `request` (z. B. Auswahl in der App-Senderliste) → der Player schaltet
  mit derselben ExoPlayer-Instanz um (kein Neuaufbau).
* Zurück-Taste: schließt erst Leiste/Overlay/Menüs, dann `onExit()`.
  Die App sollte für den Player-Bildschirm kein eigenes BackHandler-Verhalten
  haben (der Player nutzt `BackHandler`).

## PlayRequest

```kotlin
data class PlayRequest(
    val portalId: String,
    val channels: List<Channel> = emptyList(),
    val index: Int = 0,
    val kind: Kind,                 // LIVE, CATCHUP, VOD, EPISODE
    val url: String? = null,
    val title: String? = null,
    val startPositionMs: Long = 0,  // > 0 erzwingt Start, sonst gemerkte Stelle
    val catchup: CatchupInfo? = null,   // CatchupInfo(channel, entry)
    val subtitle: String? = null,
    val resumeKey: String? = null,  // movie_<id>, ep_<id>, cu_<sender>_<startMs> (wie Flutter)
    val artworkUrl: String? = null,
    val nextUp: (suspend () -> NextUp?)? = null,
)
```

Fabriken (setzen Schlüssel/Untertitel wie die Flutter-App):

* `PlayRequest.live(portalId, channels, index)`
* `PlayRequest.catchup(portalId, channel, entry, channels = …, url = null)` –
  ohne `url` fragt der Player `deps.catchupUrl(...)`.
* `PlayRequest.movie(portalId, vodItem)`
* `PlayRequest.episode(portalId, series, episode, seasons, subtitleOf = { "S… · F… – …" }, onStart = {}, onSeriesFinished = {})`
  – mit `seasons` gibt es „Nächste Folge in 10 s“ (über Staffelgrenzen).

## PlayerDeps

Interface mit Vorgaben auf Basis von `Storage` (`StoragePlayerDeps(storage)`
ist eine fertige Minimal-Implementierung). Die App überschreibt:

| Methode | Zweck | Vorgabe |
|---|---|---|
| `storage` | Einstellungen `set_*`, `resume_`, `fav_`, `last_`, `recent_` | – (Pflicht) |
| `portal(id)` | Portal für Kopfzeilen + Ersatz-Adressen | – (Pflicht) |
| `suspend resolveLiveUrl(portalId, ch)` | Stalker `create_link`, sonst `HostFailover.rewrite` | `ch.streamUrl` |
| `suspend catchupUrl(portalId, ch, entry)` | `repo.catchupUrl(c, e)` | null |
| `epgOf(ch)` | Sendungen sortiert (aus dem Speicher, schnell) | leer |
| `epgRevision: StateFlow<Long>` | hochzählen, wenn EPG neu → Leiste/Overlay zeichnen neu | konstant |
| `wantEpg(ch)` | Leiste zeigt Sender → Kurz-EPG nachladen | no-op |
| `suspend channelEpg(ch)` | EPG inkl. Vergangenheit (Replay ◀▶) | `epgOf` |
| `variantIndex()` | `VariantIndex` der sichtbaren Liste | leer |
| `variantChoices/chooseVariant` | Option `varpick_<portal>` (wie Flutter) | implementiert |
| `allChannels(portalId)` / `rawChannels(portalId)` | Direktwahl-Rückfall (Nummer nicht in Gruppe / Nummer einer Variante) | leer |
| `isFavorite/toggleFavorite` | `fav_<portal>`; Gastmodus → false | implementiert |
| `isLocked` + `suspend confirmPin(ch)` | Kindersicherung beim Zappen | `locked_` / true |
| `onChannelStarted(portalId, ch)` | Verlauf + letzter Sender | `pushRecent` + `setLastChannel` |
| `setUnavailable(portalId, ch, on)` | 403/451 am Sender vermerken | no-op |
| `onRecord(portalId, ch, now)` | Rot / Aufnahme → Meldung | null → „folgt“-Hinweis (Stub) |
| `onResumeSaved(key)` | „Weiterschauen“ neu laden | no-op |

## PlayerEngine

```kotlin
val engine = PlayerEngine(context)   // ein ExoPlayer für alle Zaps
engine.release()                     // onStop / Activity-Ende
```

* `EngineConfig.fromStorage(storage)` – gleiche Puffer/Durchreichung wie der
  Vollbild-Player (sonst baut `open()` den ExoPlayer beim Wechsel neu).
* `attachSurface(view)` / `detachSurface(view)` (löst nur, wenn `view` noch
  aktuell ist – der Vollbild-Player benutzt das beim Verlassen).
* Ohne `keepPlayingOnExit` stoppt der Player eine übergebene Engine beim
  Verlassen (`engine.stop()`); mit `true` muss die App das selbst tun.

Der `PlayerScreen` gibt eine **selbst angelegte** Engine bei `ON_STOP` frei
und baut sie bei `ON_START` neu (öffnet den aktuellen Sender wieder). Eine
von außen übergebene Engine wird ebenfalls bei `ON_STOP` freigegeben
(`release()` ist idempotent, `open()` baut neu).

## Einstellungen (gleiche Schlüssel wie Flutter, mit Präfix `set_`)

`alang`, `slang` (Sprachcode/auto/off), `sub_size`, `sub_color`, `sub_bg`,
`sub_outline`, `passthrough` (Bool), `afr` (Bool), `buffer`
(klein/normal/gross), `livebuffer` (Minuten, 0 = aus), `fit` (Bildformat),
`aspect_<portal>_<sender>`, `playerdebug` (Bool), `autonext` (Bool, Std. an),
`accent` (Akzentfarbe), neu: `tunnel` (Bool, Std. aus).

## Gestaltung

* Farben: `de.jasonstream.core.ui.AppPalette` (ohne Compose, ARGB-Ints,
  Akzent-Vorgaben wie theme.dart, `AppPalette.accent(key)`).
* Schrift: Inter / InterDisplay als `R.font.inter_*` in `:core`
  (`de.jasonstream.core.R.font…`); Compose-`FontFamily` in
  `de.jasonstream.playback.ui.PlayerType` (`Inter`, `InterDisplay`).
* Texte: `de.jasonstream.core.R.string.<arb-key>` – erzeugt aus
  `lib/l10n/arb/app_{de,en,tr}.arb` mit `tools/gen_strings.py`
  (values = Englisch, values-de, values-tr; fehlende → Deutsch wie Flutter).
  Platzhalter `{0}` → `%1$s`.

## Live-Pause (Timeshift) – Stand

* HLS mit DVR-Fenster: echtes Pausieren/Spulen (◀▶ ±10 s, ◀◀ −30 s,
  ▶▶ = Live) im Fenster des Anbieters.
* MPEG-TS/progressiv: Pause = Anhalten; ExoPlayer puffert bis ~50 s bzw.
  `set_buffer` weiter. Weiter spielt zeitversetzt ab der Pausenstelle;
  länger als `set_livebuffer` pausiert oder Verbindung abgerissen →
  „Zurück zu Live“ (neu öffnen). Kein Spulen.
* TODO (Phase 2b): Ringpuffer auf dem Datenträger für TS-Live: eigene
  `DataSource`, die den TS-Strom parallel in eine Ringdatei
  (`cacheDir/timeshift.ts`, Größe aus `planLiveBuffer`) schreibt, und eine
  zweite `DataSource` mit Lese-Offset; SeekMap per PCR/Byte-Rate
  (`ConstantBitrateSeekMap`). Erst dann ist Spulen in TS-Live möglich.

## APK-Größe (Release, R8, universell)

Gemessen mit einer Minimal-App: +8,8 MB gegenüber ohne `:player`
(9,9 MB statt 1,1 MB). Davon FFmpeg-Audio (`libffmpegJNI.so`)
1,4–1,6 MB **je ABI** = 5,9 MB für 4 ABIs; Inter-Schriften 1,7 MB (gelten
für die ganze App); Texte (774 × 3) ~0,4 MB; Code (Media3 UI/HLS, Player,
Symbole nach R8) ~0,8 MB. Empfehlung: `ndk { abiFilters += listOf("armeabi-v7a", "arm64-v8a") }`
(TV-Boxen sind ARM) → −3 MB, oder ABI-Splits wie bei Flutter.
