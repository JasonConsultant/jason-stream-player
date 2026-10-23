import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../data/portal_detect.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../security.dart';
import 'pairing.dart';

/// Kopplungs-Sitzung auf dem Fernseher.
///
/// Ablauf:
/// 1. [start] öffnet einen HTTP-Server auf der WLAN-Adresse (zufälliger Port).
/// 2. [url] (`http://<ip>:<port>/p/<token>`) als QR-Code anzeigen.
/// 3. Das Handy öffnet die Adresse, schickt das Formular ab.
/// 4. [result] liefert die Zugangsdaten; der Server beendet sich danach.
///
/// Sicherheit: Nur der geheime Token-Pfad wird beantwortet, einmalige Nutzung,
/// Ablauf nach [ttl], Größenlimit für Anfragen, strenge Header.
class PairingSession {
  /// Gültigkeit einer Kopplung.
  static const ttl = Duration(minutes: 10);

  /// Maximale Größe des Formular-Inhalts.
  static const maxBodyBytes = 16 * 1024;

  static const _headers = <String, String>{
    'Cache-Control': 'no-store',
    'Pragma': 'no-cache',
    'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; "
        "script-src 'unsafe-inline'; form-action 'self'",
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'X-Frame-Options': 'DENY',
  };

  final HttpServer _server;
  final String _path;
  final Uri url;
  final _completer = Completer<PairingResult>();
  Timer? _timer;
  bool _closed = false;

  PairingSession._(this._server, this._path, this.url) {
    // Fehler (Ablauf/Abbruch) nicht als unbehandelt melden, falls niemand
    // auf [result] wartet. Andere Zuhörer erhalten den Fehler trotzdem.
    _completer.future.ignore();
  }

  /// Liefert die Zugangsdaten oder einen [PairingException]-Fehler
  /// (Zeit abgelaufen / abgebrochen).
  Future<PairingResult> get result => _completer.future;

  /// `true`, solange der Server Anfragen annimmt.
  bool get isActive => !_closed;

  /// Startet die Sitzung.
  ///
  /// [bindAddress] nur für Tests (z. B. `InternetAddress.loopbackIPv4`);
  /// sonst wird die WLAN-/LAN-Adresse des Geräts ermittelt.
  static Future<PairingSession> start({
    InternetAddress? bindAddress,
    Duration timeout = ttl,
  }) async {
    final address = bindAddress ?? await _findLanAddress();
    final server = await HttpServer.bind(address, 0);
    server
      ..autoCompress = false
      ..idleTimeout = const Duration(seconds: 15)
      ..serverHeader = null;
    final token = _newToken();
    final path = '/p/$token';
    final url = Uri(
      scheme: 'http',
      host: address.address,
      port: server.port,
      path: path,
    );
    final session = PairingSession._(server, path, url);
    session._timer = Timer(timeout, () {
      session._finish(error: PairingException(
          tr('Die Zeit ist abgelaufen. Bitte den QR-Code neu erzeugen.')));
    });
    server.listen(
      (req) => session._handle(req).catchError((Object _) {
        // Verbindungsfehler einzelner Anfragen ignorieren.
      }),
      onError: (Object _) {},
    );
    return session;
  }

  /// Vorzeitig beenden (z. B. wenn der Bildschirm verlassen wird).
  Future<void> cancel() =>
      _finish(error: PairingException(tr('Kopplung abgebrochen.')));

  // ---------------------------------------------------------------------------
  // Netzwerk

  static Future<InternetAddress> _findLanAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final picked = pickLanAddress([
      for (final i in interfaces) ...i.addresses,
    ]);
    if (picked == null) {
      throw PairingException(tr('Kein WLAN/Netzwerk gefunden.'));
    }
    return picked;
  }

  /// Wählt die passende Adresse: private Bereiche (192.168/16, 10/8,
  /// 172.16/12) zuerst, sonst irgendeine andere IPv4 außer Loopback und
  /// Link-Local. `null`, wenn keine passt.
  static InternetAddress? pickLanAddress(List<InternetAddress> addresses) {
    final candidates = addresses
        .where((a) =>
            a.type == InternetAddressType.IPv4 &&
            !a.isLoopback &&
            !a.isLinkLocal &&
            a.rawAddress.length == 4 &&
            a.rawAddress[0] != 0)
        .toList();
    int rank(InternetAddress a) {
      final b = a.rawAddress;
      if (b[0] == 192 && b[1] == 168) return 0;
      if (b[0] == 10) return 1;
      if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return 2;
      return 3;
    }

    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => rank(a).compareTo(rank(b)));
    return candidates.first;
  }

  /// 128 Bit Zufall, base64url ohne Auffüllzeichen.
  static String _newToken() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Vergleich in konstanter Zeit (bei gleicher Länge).
  static bool _constantTimeEquals(String a, String b) {
    // Die Länge des Pfads ist kein Geheimnis.
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> _finish({PairingResult? value, Object? error}) async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    if (!_completer.isCompleted) {
      if (value != null) {
        _completer.complete(value);
      } else {
        _completer.completeError(
            error ?? PairingException(tr('Kopplung beendet.')));
      }
    }
    await _server.close(force: true);
  }

  // ---------------------------------------------------------------------------
  // Anfragen

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    _headers.forEach(res.headers.set);

    if (_closed || !_constantTimeEquals(req.uri.path, _path) ||
        req.uri.hasQuery) {
      await _sendAndClose(req, HttpStatus.notFound, _messagePage(
          tr('Nicht gefunden'), tr('Diese Adresse ist ungültig oder abgelaufen.')));
      return;
    }

    switch (req.method) {
      case 'GET':
        await _send(res, HttpStatus.ok, _formPage());
      case 'POST':
        await _handlePost(req);
      default:
        res.headers.set(HttpHeaders.allowHeader, 'GET, POST');
        await _sendAndClose(req, HttpStatus.methodNotAllowed,
            _messagePage(tr('Nicht erlaubt'), tr('Diese Anfrage wird nicht unterstützt.')));
    }
  }

  Future<void> _handlePost(HttpRequest req) async {
    final res = req.response;
    final ct = req.headers.contentType;
    if (ct == null ||
        ct.mimeType.toLowerCase() != 'application/x-www-form-urlencoded') {
      await _sendAndClose(req, HttpStatus.unsupportedMediaType,
          _messagePage(tr('Ungültige Anfrage'), tr('Falsches Datenformat.')));
      return;
    }
    if (req.contentLength > maxBodyBytes) {
      await _sendTooLarge(req);
      return;
    }

    final bytes = BytesBuilder(copy: false);
    var tooLarge = false;
    await for (final chunk in req) {
      if (bytes.length + chunk.length > maxBodyBytes) {
        tooLarge = true;
        break;
      }
      bytes.add(chunk);
    }
    if (tooLarge) {
      await _sendTooLarge(req);
      return;
    }
    if (_closed) {
      // Inzwischen bereits erfolgreich gekoppelt oder abgelaufen.
      await _send(res, HttpStatus.gone, _messagePage(
          tr('Abgelaufen'), tr('Diese Kopplung ist bereits beendet.')));
      return;
    }

    Map<String, String> fields;
    try {
      fields = Uri.splitQueryString(
        utf8.decode(bytes.takeBytes()),
        encoding: utf8,
      );
    } on FormatException {
      await _send(res, HttpStatus.badRequest,
          _formPage(error: tr('Die Eingaben konnten nicht gelesen werden.')));
      return;
    }

    // „Einfügen & erkennen“: Text des Anbieters auswerten und das Formular
    // ausgefüllt zurückgeben (noch nichts an den Fernseher übergeben).
    if (fields['action'] == 'detect') {
      final draft = detectPortalInput(fields['paste'] ?? '');
      final form = _FormData.from(fields);
      if (draft == null) {
        await _send(res, HttpStatus.ok, _formPage(
            form: form,
            error: tr('Nichts erkannt. Bitte den Link oder die Zugangsdaten des Anbieters einfügen – z. B. http://host:port/get.php?username=…&password=… oder Portal-Adresse mit MAC.')));
        return;
      }
      final filled = _FormData.fromDraft(draft, name: form.name,
          epgUrl: form.epgUrl.isNotEmpty ? form.epgUrl : (draft.epgUrl ?? ''));
      await _send(res, HttpStatus.ok, _formPage(
          form: filled,
          info: trf('Erkannt: {0} · {1}', [
            switch (draft.type) {
              PortalType.xtream => 'Xtream',
              PortalType.m3u => 'M3U',
              _ => tr('MAC-Portal'),
            },
            draft.hostLabel,
          ])));
      return;
    }

    final form = _FormData.from(fields);
    final error = form.validate();
    if (error != null) {
      await _send(res, HttpStatus.unprocessableEntity,
          _formPage(form: form, error: error));
      return;
    }

    await _send(res, HttpStatus.ok, _messagePage(
        tr('Fertig!'), tr('Fertig! Schau auf deinen Fernseher.'), success: true));
    await _finish(value: form.toResult());
  }

  Future<void> _sendTooLarge(HttpRequest req) async {
    final res = req.response;
    res.persistentConnection = false;
    await _send(res, HttpStatus.requestEntityTooLarge, _messagePage(
        tr('Zu groß'), tr('Die Eingaben sind zu umfangreich.')));
  }

  Future<void> _sendAndClose(HttpRequest req, int status, String html) async {
    // Inhalt wird nicht gelesen – Verbindung danach schließen.
    req.response.persistentConnection = false;
    await _send(req.response, status, html);
  }

  Future<void> _send(HttpResponse res, int status, String html) async {
    res
      ..statusCode = status
      ..headers.contentType = ContentType.html;
    res.write(html);
    await res.close();
  }

  // ---------------------------------------------------------------------------
  // HTML

  static const _escape = HtmlEscape(HtmlEscapeMode(
    escapeLtGt: true,
    escapeQuot: true,
    escapeApos: true,
  ));
  static String _e(String? s) => _escape.convert(s ?? '');

  static const _css = '''
*{box-sizing:border-box}
body{margin:0;background:#0f1115;color:#e8eaf0;font:16px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:480px;margin:0 auto;padding:24px 16px 40px}
h1{font-size:1.5rem;margin:0 0 4px}
p.sub{color:#9aa1b2;margin:0 0 20px}
label{display:block;font-size:.9rem;color:#b9bfcc;margin:14px 0 6px}
input,select,textarea{width:100%;padding:12px;border-radius:10px;border:1px solid #2a2f3a;background:#181b22;color:#e8eaf0;font-size:1rem;font-family:inherit}
input:focus,select:focus,textarea:focus{outline:2px solid #4f8cff;border-color:transparent}
textarea{min-height:72px;resize:vertical}
button{width:100%;margin-top:22px;padding:14px;border:0;border-radius:10px;background:#4f8cff;color:#fff;font-size:1.05rem;font-weight:600}
button.sec{margin-top:10px;padding:11px;background:#1d2330;color:#cfd6e6;border:1px solid #2a2f3a;font-size:.95rem}
.box{background:#141821;border:1px solid #2a2f3a;border-radius:12px;padding:12px 12px 14px;margin:0 0 6px}
.box p{margin:0 0 8px;color:#b9bfcc;font-size:.9rem}
.err{background:#3a1d22;border:1px solid #7a2d38;color:#ffc9d0;padding:12px;border-radius:10px;margin-bottom:8px}
.info{background:#15302a;border:1px solid #1f6b58;color:#b9f0dc;padding:12px;border-radius:10px;margin-bottom:8px}
.ok{font-size:3rem;margin:24px 0 8px}
.note{color:#8a90a0;font-size:.85rem;margin-top:20px}
.opt{color:#7d8392;font-weight:400}
[hidden]{display:none!important}
''';

  static String _page(String title, String body) => '<!doctype html>'
      '<html lang="${L10n.lang}"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<meta name="referrer" content="no-referrer">'
      '<title>${_e(title)}</title><style>$_css</style></head>'
      '<body><main>$body</main></body></html>';

  static String _messagePage(String title, String text,
      {bool success = false}) {
    final icon = success ? '<div class="ok">&#10003;</div>' : '';
    return _page(title, '$icon<h1>${_e(title)}</h1><p class="sub">${_e(text)}</p>');
  }

  String _formPage({_FormData? form, String? error, String? info}) {
    final f = form ?? _FormData.empty();
    final type = f.type;
    String opt(String value, String label) =>
        '<option value="$value"${type == value ? ' selected' : ''}>'
        '${_e(label)}</option>';
    String hiddenUnless(Set<String> types) =>
        types.contains(type) ? '' : ' hidden';
    final urlLabel = switch (type) {
      'm3u' => tr('Playlist-URL'),
      'stalker' => tr('Portal-URL'),
      _ => tr('Server-URL'),
    };
    final body = StringBuffer()
      ..write('<h1>Jason Stream Player</h1>')
      ..write('<p class="sub">${_e(tr('Zugangsdaten an den Fernseher senden'))}</p>');
    if (error != null) {
      body.write('<div class="err" role="alert">${_e(error)}</div>');
    }
    if (info != null) {
      body.write('<div class="info" role="status">${_e(info)}</div>');
    }
    body
      ..write('<form method="post" action="${_e(_path)}" autocomplete="off">')
      // „Einfügen & erkennen“: beliebiger Anbieter-Text → Felder ausfüllen.
      ..write('<div class="box">')
      ..write('<p>${_e(tr('Zugangsdaten vom Anbieter hier einfügen (Link oder Text) – Art, Adresse und Zugangsdaten werden automatisch erkannt.'))}</p>')
      ..write('<textarea id="paste" name="paste" maxlength="4000" '
          'autocapitalize="off" spellcheck="false" '
          'placeholder="${_e(tr('Link oder Text des Anbieters'))}"></textarea>')
      ..write('<button type="submit" class="sec" name="action" value="detect" '
          'formnovalidate>${_e(tr('Einfügen & erkennen'))}</button>')
      ..write('</div>')
      ..write('<label for="type">${_e(tr('Zugangsart'))}</label>')
      ..write('<select id="type" name="type">')
      ..write(opt('xtream', 'Xtream Codes'))
      ..write(opt('m3u', tr('M3U-Playlist')))
      ..write(opt('stalker', tr('MAC-Portal')))
      ..write('</select>')
      ..write('<label for="name">${_e(tr('Name'))} '
          '<span class="opt">(${_e(tr('optional'))})</span></label>')
      ..write('<input id="name" name="name" maxlength="100" '
          'value="${_e(f.name)}" placeholder="${_e(tr('z. B. Mein Anbieter'))}">')
      ..write('<label for="url" id="urlLabel">${_e(urlLabel)}</label>')
      ..write('<input id="url" name="url" type="url" inputmode="url" required '
          'maxlength="2000" autocapitalize="off" spellcheck="false" '
          'value="${_e(f.safeUrl)}" placeholder="http://…">')
      ..write('<div id="xtream"${hiddenUnless({'xtream'})}>')
      ..write('<label for="username">${_e(tr('Benutzername'))}</label>')
      ..write('<input id="username" name="username" maxlength="200" '
          'autocapitalize="off" spellcheck="false" value="${_e(f.username)}">')
      ..write('<label for="password">${_e(tr('Passwort'))}</label>')
      ..write('<input id="password" name="password" type="password" '
          'maxlength="200" autocomplete="new-password"'
          '${f.echoPassword ? ' value="${_e(f.password)}"' : ''}>')
      ..write('</div>')
      ..write('<div id="stalker"${hiddenUnless({'stalker'})}>')
      ..write('<label for="mac">${_e(tr('MAC-Adresse'))}</label>')
      ..write('<input id="mac" name="mac" maxlength="17" autocapitalize="characters" '
          'spellcheck="false" placeholder="00:1A:79:XX:XX:XX" '
          'pattern="[0-9A-Fa-f]{2}([:\\-][0-9A-Fa-f]{2}){5}" '
          'value="${_e(f.mac)}">')
      ..write('</div>')
      ..write('<label for="epg">EPG-URL '
          '<span class="opt">(${_e(tr('optional'))})</span></label>')
      ..write('<input id="epg" name="epg" type="url" inputmode="url" '
          'maxlength="2000" autocapitalize="off" spellcheck="false" '
          'value="${_e(f.epgUrl)}" placeholder="http://…">')
      ..write('<button type="submit">${_e(tr('An Fernseher senden'))}</button>')
      ..write('</form>')
      ..write('<p class="note">${_e(tr('Die Daten gehen nur an deinen Fernseher im '
          'selben Netzwerk – nicht ins Internet. Diese Seite funktioniert nur '
          'einmal und läuft nach 10 Minuten ab.'))}</p>')
      ..write('<script>${_js()}</script>');
    return _page(tr('Mit Fernseher koppeln'), body.toString());
  }

  /// Feldbeschriftungen für das Umschalten im Browser (JSON, sicher escaped).
  static String _js() {
    final labels = const JsonEncoder()
        .convert({
          'xtream': tr('Server-URL'),
          'm3u': tr('Playlist-URL'),
          'stalker': tr('Portal-URL'),
        })
        .replaceAll('<', r'\u003c');
    return '''
(function(){
var t=document.getElementById("type"),l=document.getElementById("urlLabel"),
x=document.getElementById("xtream"),s=document.getElementById("stalker"),
u=document.getElementById("username"),p=document.getElementById("password"),
m=document.getElementById("mac");
var labels=$labels;
function upd(){var v=t.value;l.textContent=labels[v]||"URL";
x.hidden=v!=="xtream";s.hidden=v!=="stalker";
u.required=p.required=v==="xtream";m.required=v==="stalker";}
t.addEventListener("change",upd);upd();
})();
''';
  }
}

/// Formularinhalt mit Prüfung.
class _FormData {
  static final _macRe = RegExp(r'^[0-9A-F]{2}(:[0-9A-F]{2}){5}$');
  static const _types = {'xtream', 'm3u', 'stalker'};

  final String type;
  final String name;
  final String url;
  final String username;
  final String password;
  final String mac;
  final String epgUrl;

  /// Nach „Einfügen & erkennen“: erkanntes Passwort ins Formular zurück
  /// (sonst wird ein Passwort nie zurückgeschickt).
  final bool echoPassword;

  _FormData({
    required this.type,
    required this.name,
    required this.url,
    required this.username,
    required this.password,
    required this.mac,
    required this.epgUrl,
    this.echoPassword = false,
  });

  factory _FormData.fromDraft(PortalDraft d,
          {required String name, required String epgUrl}) =>
      _FormData(
        type: d.type == PortalType.demo ? 'xtream' : d.type.name,
        name: name,
        url: d.url,
        username: d.username ?? '',
        password: d.password ?? '',
        mac: d.mac ?? '',
        epgUrl: epgUrl,
        echoPassword: true,
      );

  factory _FormData.empty() => _FormData(
      type: 'xtream', name: '', url: '', username: '', password: '',
      mac: '', epgUrl: '');

  factory _FormData.from(Map<String, String> f) {
    String v(String k, [int max = 2000]) {
      final s = (f[k] ?? '').trim();
      return s.length > max ? s.substring(0, max) : s;
    }

    final rawType = v('type', 20);
    return _FormData(
      type: _types.contains(rawType) ? rawType : 'xtream',
      name: v('name', 100),
      url: v('url'),
      username: v('username', 200),
      // Passwort nicht kürzen/trimmen wäre genauer, Leerzeichen am Rand
      // sind bei Zugangsdaten aber fast immer Tippfehler.
      password: v('password', 200),
      mac: v('mac', 17).toUpperCase().replaceAll('-', ':'),
      epgUrl: v('epg'),
    );
  }

  /// URL nur zurückgeben, wenn sie keine Zugangsdaten enthält.
  String get safeUrl {
    final u = Uri.tryParse(url);
    if (u == null) return '';
    if (u.userInfo.isNotEmpty || (u.hasQuery && !echoPassword)) return '';
    return url;
  }

  /// Übersetzte Fehlermeldung oder `null`, wenn alles passt.
  String? validate() {
    if (url.isEmpty) {
      return switch (type) {
        'm3u' => tr('Bitte die Playlist-URL eingeben.'),
        'stalker' => tr('Bitte die Portal-URL eingeben.'),
        _ => tr('Bitte die Server-URL eingeben.'),
      };
    }
    if (!UrlPolicy.isWeb(url)) {
      return tr('Die Adresse muss mit http:// oder https:// beginnen.');
    }
    if (epgUrl.isNotEmpty && !UrlPolicy.isWeb(epgUrl)) {
      return tr('Die EPG-URL muss mit http:// oder https:// beginnen.');
    }
    switch (type) {
      case 'xtream':
        if (username.isEmpty) return tr('Bitte den Benutzernamen eingeben.');
        if (password.isEmpty) return tr('Bitte das Passwort eingeben.');
      case 'stalker':
        if (mac.isEmpty) return tr('Bitte die MAC-Adresse eingeben.');
        if (!_macRe.hasMatch(mac)) {
          return tr('Die MAC-Adresse muss so aussehen: 00:1A:79:12:34:56.');
        }
    }
    return null;
  }

  PairingResult toResult() {
    final host = Uri.tryParse(url)?.host ?? '';
    return PairingResult(
      type: type,
      name: name.isNotEmpty ? name : host,
      url: url,
      username: type == 'xtream' ? username : null,
      password: type == 'xtream' ? password : null,
      mac: type == 'stalker' ? mac : null,
      epgUrl: epgUrl.isEmpty ? null : epgUrl,
    );
  }
}
