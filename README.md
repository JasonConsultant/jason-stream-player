# Jason Stream Player

IPTV-Player für **Android 10+ (Handy/Tablet)** und **Android TV**.
Unterstützt Xtream-Codes-Portale, M3U-Playlisten (mit XMLTV-EPG) und MAC-/Stalker-Portale.
App-Sprachen: Deutsch, English, Türkçe.
Eine Flutter-Codebasis; auf dem Fernseher erkennt die App den TV-Modus
automatisch (Fernbedienung/D-Pad, größere Schrift, Leanback-Startbildschirm).

## Neu in v1.0 – 1.0.7

- **Startseite** mit Zuletzt gesehen, Favoriten, Weiterschauen, Kacheln
- **Selbst-Update** über GitHub-Releases (Einstellungen → Nach Updates suchen)
- **Eigene Gruppen**, **Meine Liste** und Verlauf bei Filmen/Serien
- **EPG-Quellen** (Länder-EPG), Fortschrittsanzeige, Auswahl bei großen
  M3U-Listen (nur Länder der eigenen Sender)
- **M3U-Datei vom Gerät**, **Portal bearbeiten**
- **Fernseher-APKs** (32+64 Bit, ab Android 9), türkische Variante
- 1.0.7: Fehlerbehebungen nach unabhängiger Code-Prüfung

## Neu in v0.9.4 – Sicherheit

- **Eigener Release-Schlüssel** (RSA 4096) mit Schlüsselwechsel (APK
  Signature Scheme v3, `tool/sign_release.sh`): Updates installieren sich über
  ältere Versionen, ohne Datenverlust. Schlüssel liegt **nicht** im Quellcode.
- **Schutz gegen veränderte Kopien**: Die App prüft beim Start ihr eigenes
  Zertifikat; neu signierte/manipulierte APKs starten nicht.
- **App-Sperre** (Einstellungen → Sicherheit): Fingerabdruck, Gesicht oder
  Geräte-PIN beim Öffnen und nach 1 Min. im Hintergrund.
- **Hinweis bei Root oder Debugger** (einmalig, abschaltbar).

## Neu in v0.9.3

- **Filme & Serien**: „Meine Liste“ (Favoriten, ♥ auf der Detailseite),
  Reihe „Weiterschauen & zuletzt gesehen“ mit Fortschritt und „S2 · F3“,
  Filter-Chips „★ Meine Liste“ / „Zuletzt gesehen“
- **Serien**: „S1 F3 fortsetzen · 12:34“ bzw. automatisch die nächste Folge,
  „Von vorne“, gesehene Folgen mit ✓; angefangene Folge antippen →
  „Fortsetzen“ oder „Von vorne“

## Neu in v0.9.2

- **Eigene Gruppen** („Fußball“, „Kinder“ …): Sender aus allen Anbieter-Gruppen
  sammeln – Sender lange drücken → „Gruppen“. Stehen in Live TV und TV-Guide
  direkt nach den Favoriten, lassen sich sortieren, umbenennen, löschen.
- **EPG-Quellen** pro Portal: kleine Länder-EPGs (Deutschland, Österreich,
  Schweiz, Türkei, UK, Albanien – je wenige MB) statt oder zusätzlich zum
  großen Anbieter-EPG, eigene XMLTV-Adressen möglich
- **Fortschritt beim EPG-Laden** („Herunterladen 84 / 210 MB“, „Wird
  verarbeitet …“) in den Einstellungen und im TV-Guide

## Neu in v0.9

- **EPG-Zuordnung wie TiviMate**: Sender ohne oder mit abweichender EPG-Kennung
  werden über den Namen zugeordnet („DE: ZDF HD“ ↔ „ZDF.de“), Groß/Klein egal.
  Fehlt ein Sender trotzdem, holt die App das Kurz-Programm direkt vom Portal
  (Xtream `get_short_epg`). Hängende Downloads brechen nach 6 Min. ab,
  „Jetzt aktualisieren“ zeigt Fehler an.
- **Erinnerungen** an Sendungen (TV-Guide → Sendung → „Erinnern“): Hinweis
  2 Min. vorher mit „Umschalten“, auch als Benachrichtigung bei geschlossener App
- **Live-Vorschau** beim Stöbern (Tablet/TV, abschaltbar)
- **Zuletzt gesehen** als Gruppe, **vorheriger Sender** per Taste ⇄ im Player
  (Fernbedienung: „Last“-Taste)
- **AFR** – automatische Bildwiederholrate auf TV-Boxen (Einstellungen → Wiedergabe)

## Neu in v0.8

- **QR-Code-Einrichtung**: Fernseher zeigt einen QR-Code, Handy scannt ihn und
  überträgt den Zugang im Browser (gleiches WLAN, Code einmalig, 10 Min. gültig)
- **MAC-/Stalker-Portale** (Live-TV und EPG; Archiv und Filme folgen)
- **Globale Suche** über Sender, Sendungen (inkl. Archiv), Filme und Serien
- **Multiview** mit 2–4 Sendern gleichzeitig, Ton per Auswahl
- **Aufnahme**: laufende Sendung per Knopf im Live-Bild, geplante Aufnahmen
  aus dem TV-Guide, Liste unter Einstellungen → Aufnahmen. Aufnahmen laufen,
  solange die App geöffnet ist (auf TV-Boxen üblich)
- **Schlaf-Timer** (15 Min. bis 2 Std.) mit Warnung 1 Min. vorher
- **Gruppen und Sender umsortieren**, Gruppen ausblenden (Live-TV → ⇅)
- **Bevorzugte Ton- und Untertitelsprache**, Spurauswahl mit Sprachnamen
- **App-Sprache** Deutsch / English / Türkçe (Einstellungen → Sprache)

## Funktionen (v0.6)

**Live TV**
- Gruppen, Favoriten, Suche, Sendernummern, Logos (ohne Logo: Monogramm)
- „Jetzt läuft“ mit Fortschritt in der Liste; auf Tablet/TV Vorschau-Spalte mit Danach-Programm
- Sender-Menü (langes Drücken / Menü-Taste): Favorit, Sperren (PIN), Verstecken
- **Catch-up-Archiv** pro Sender, nach Tagen sortiert
- **„Von Anfang“** in der Vorschau-Spalte: laufende Sendung neu starten

**Sendung-Replay** (bei Sendern mit Catch-up)
- Im Live-Bild: Button „Von Anfang“ oder Taste ⏪/⏮ auf der Fernbedienung
- Im Replay frei spulen, „Vorherige“ / „Nächste“ Sendung (auch Kanal±, ⏮/⏭)
- „LIVE“ springt jederzeit zurück ins Live-Bild (auch Stopp-Taste)
- Nahtlos: Am Ende einer Sendung läuft die nächste weiter, bis man wieder
  live ist
- TV-Guide: lange drücken/Menü-Taste auf einer Sendung → „Von Anfang“ oder
  „Replay abspielen“

**TV-Guide**
- Programmraster über alle Sender, −6 h bis +24 h, „Jetzt“-Linie
- Vergangene Sendungen mit Archiv türkis markiert → direkt abspielbar
- Wischen bzw. D-Pad zum Navigieren, Filter nach Gruppe/Favoriten

**Filme & Serien** (Xtream)
- Titelbild, „Weiterschauen“, Top bewertet, Neu, Reihen pro Kategorie, Suche
- Detailseiten mit Handlung, Besetzung, Staffeln und Folgen
- Merkt die Position: „Fortsetzen bei 42:10“

**Player** (libmpv über media_kit – spielt TS, HLS, MKV, alle gängigen Codecs)
- Live: ▲▼ / Kanal± / Wischen zum Umschalten, **Zifferntasten-Direktwahl**,
  Senderliste per ◀ ohne die Wiedergabe zu stoppen, Jetzt/Danach-Einblendung
- Filme/Folgen: Spulen (◀▶ ±10 s, Doppeltippen, FF/REW ±30 s), Suchleiste
- Ton- und Untertitelspuren
- **Bildformat**: Original, Füllen, Strecken, 16:9, 4:3, Kino 21:9, Zoom 115 %
  – im Player über den Format-Button oder die Zoom-Taste der Fernbedienung
  umschalten; wird pro Sender gemerkt (Standard in den Einstellungen)
- **Bild-in-Bild** (Handy), optional automatisch beim Verlassen der App
- Verständliche Fehlermeldung mit „Erneut versuchen“

**TV-Guide aktuell halten (v0.6)**
- EPG wird auf dem Gerät zwischengespeichert → sofort da, auch offline
- Automatisch: täglich zu einer wählbaren Uhrzeit (Standard 5:00), alle
  12/6 Std. oder nur manuell; läuft auch bei dauerhaft offener App (TV-Box)
  und wird beim nächsten Öffnen nachgeholt, wenn die App aus war
- Einstellungen → TV-Guide (EPG): Stand, nächste Aktualisierung, „Jetzt
  aktualisieren“

**Drehen (Handy)**
- Player startet im Querformat – auch bei aktiver Drehsperre; Button zum
  Umschalten auf „frei drehen“, wird gemerkt
- Restliche App folgt dem Drehen des Handys (Android-Drehsperre beachten)

**Einstellungen**
- Portal-Infos (Ablaufdatum, Verbindungen), Neu laden, Portal wechseln
- Hardware-Dekodierung, Puffergröße, Bildformat
- Kindersicherungs-PIN, versteckte Sender wiederherstellen

**Demo-Modus**: Auf dem Startbildschirm „Demo ausprobieren“ – erfundene Sender,
EPG, Filme und Serien, damit man die App ohne Zugang testen kann.

## Sicherheit (v0.4)

**Zugangsdaten**
- Server-/Playlist-Adresse, Benutzername, Passwort und EPG-Adresse liegen
  mit einem Schlüssel aus dem **Android-Keystore** verschlüsselt (AES-256-GCM, eigener Code ohne Fremd-Plugin). In den
  normalen App-Einstellungen stehen nur Name und Typ des Portals.
- Ältere Installationen werden beim ersten Start automatisch umgezogen.
- **Keine Backups**: `allowBackup=false` + `dataExtractionRules` – Daten
  gelangen weder in Cloud-Backups noch per Geräteumzug oder `adb backup` nach
  außen.
- **Nie sichtbar**: Alle Fehlermeldungen laufen durch einen Filter, der
  Benutzername, Passwort, Tokens und Xtream-Pfade ausblendet.
- **Login-Maske**: Bildschirmfotos/Aufnahmen gesperrt (FLAG_SECURE), keine
  Tastatur-Vorschläge/-Lernfunktion, Warnhinweis bei `http://`.
- „Alle Zugangsdaten löschen“ in den Einstellungen.

**PIN**: nur als PBKDF2-SHA256-Hash mit zufälligem Salz gespeichert;
nach 5 Fehlversuchen Sperre (30 s, verdoppelt sich bis max. 1 Std.).

**Netzwerk**
- https: nur System-Zertifikate (keine vom Nutzer installierten → schützt
  vor Mitlese-Proxys).
- Weiterleitungen von https auf http werden blockiert.
- Größenlimits für Playlist (80 MB), EPG (150 MB, entpackt 600 MB) und API.

**Manipulierte Playlists**: Nur Stream-Adressen mit http(s), rtmp, rtsp,
udp usw. – `file:`, `content:`, `data:` werden verworfen; Logos nur über
http(s).

**Standort-Sperren erkennen**: HTTP 451/403 beim Abspielen → klare Meldung
„An deinem Standort nicht verfügbar“, Sender wird markiert (24 Std.) und kann
ausgeblendet werden. Die App umgeht keine Sperren.

**Grenzen**: Bei Anbietern mit `http://` gehen die Zugangsdaten technisch
bedingt unverschlüsselt übers Netz (Xtream-Verfahren) – das kann keine App
verhindern. Auf gerooteten Geräten ist kein lokaler Schutz absolut.

**Tests**: `flutter test` – 37 Tests für Verschlüsselung, Ausblenden der
Zugangsdaten, URL-Prüfung, PIN-Sperre und Fehlererkennung.

**Release-Build** (verschleiert):
```bash
flutter build apk --release --flavor standard --split-per-abi --obfuscate --split-debug-info=build/symbols
```

## Installieren

Fertige APKs (separat mitgeliefert):
- `JasonStreamPlayer_0.6_arm64.apk` – fast alle Handys und TV-Boxen ab 2020
- `JasonStreamPlayer_0.6_arm32.apk` – günstige TV-Sticks mit 32-Bit-System
  (z. B. viele Fire-TV-Sticks)

Auf dem Gerät „Installation aus unbekannten Quellen“ erlauben und die APK öffnen.
Auf Android TV am einfachsten mit der App „Downloader“ oder per
`adb install JasonStreamPlayer_0.6_arm64.apk`.

Hinweis: Die APKs sind mit einem Debug-Schlüssel signiert. Für eine
Veröffentlichung im Play Store brauchst du einen eigenen Signaturschlüssel
(siehe unten).

## Selbst bauen

**Signieren:** `android/key.properties` (storeFile, storePassword, keyAlias,
keyPassword, certSha256) aus dem Schlüssel-Paket anlegen, bauen, dann
`tool/sign_release.sh <schlüssel-ordner> build/app/outputs/flutter-apk/*-release.apk`.
Ohne key.properties wird mit dem Debug-Schlüssel gebaut und die
Signaturprüfung ist aus.

**Zwei Varianten:** `standard` (Sprache wie das Gerät) und `turkish`
(startet auf Türkisch, App-ID `de.jasonstream.player.tr`, Name
„Jason Stream Player TR“ – parallel installierbar):

```bash
flutter build apk --release --flavor turkish --dart-define=DEFAULT_LANG=tr \
  --split-per-abi --obfuscate --split-debug-info=build/symbols-tr
```


Voraussetzungen: Flutter SDK ≥ 3.22, Android SDK (Android Studio), Java 17+.

```bash
flutter pub get
flutter run                       # auf angeschlossenem Gerät/Emulator
flutter build apk --release --flavor standard --split-per-abi
```

Android TV testen: in Android Studio einen „Television“-Emulator anlegen.

### Für den Play Store signieren

```bash
keytool -genkey -v -keystore ~/jason-upload.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias upload
```
Dann in `android/app/build.gradle.kts` eine `signingConfig` für `release`
eintragen und `flutter build appbundle` ausführen.

## Projektstruktur

```
lib/
  main.dart, app.dart          Start, Theme, Routing
  core/theme.dart              Farben & Typografie (Inter)
  core/platform_info.dart      TV-Erkennung, Bild-in-Bild (MethodChannel)
  models/models.dart           Portal, Channel, EpgEntry, VodItem, Episode …
  data/repository.dart         gemeinsame Schnittstelle aller Quellen
  data/xtream_repository.dart  Xtream-API inkl. Catch-up, Filme, Serien
  data/m3u_repository.dart     M3U + Catch-up (default/append/shift/flussonic)
  data/demo_repository.dart    Demo-Inhalte
  data/xmltv_parser.dart       XMLTV (auch .gz), parst im Hintergrund-Isolate
  data/storage.dart            Portale, Favoriten, Sperren, PIN, Positionen
  state/providers.dart         Riverpod-Provider
  ui/shell/                    Navigation (Seitenleiste TV/Tablet, unten Handy)
  ui/live/                     Live TV, Sender-Menü + Archiv, Kindersicherung
  ui/guide/                    TV-Guide
  ui/vod/                      Filme, Serien, Detailseiten
  ui/player/                   Vollbild-Player
  ui/settings/                 Einstellungen
android/                       Manifest (Leanback, PiP), MainActivity.kt
```

## Übersetzungen

Die Texte liegen als ARB-Dateien in `lib/l10n/arb/` (`app_de.arb` = deutscher
Quelltext, `app_en.arb`, `app_tr.arb` = Übersetzungen unter denselben
Schlüsseln). Sie lassen sich mit üblichen Werkzeugen (Crowdin, POEditor,
ARB-Editor in Android Studio) bearbeiten. Nach jeder Änderung:

```bash
dart run tool/gen_l10n.dart   # erzeugt lib/l10n/translations.g.dart
flutter test test/l10n_test.dart
```

`translations.g.dart` nie von Hand ändern. Der Generator bricht ab, wenn ein
Schlüssel fehlt oder Platzhalter (`{0}`, `{1}` …) nicht übereinstimmen. Im Code
bleibt es bei `tr('Deutscher Text')` bzw. `trf('… {0} …', [wert])`; neue Texte
in alle drei ARB-Dateien eintragen.

Neue Sprache: `app_xx.arb` anlegen, `xx` in `targetLangs` in
`tool/gen_l10n.dart` ergänzen und den Sprachcode in `L10n.supported` und
`L10n.names` (`lib/l10n/strings.dart`) eintragen.

## Hinweis

Jason Stream Player ist ein reiner Player und liefert keine Inhalte.
Portal-Zugangsdaten gibt der Nutzer selbst ein.
