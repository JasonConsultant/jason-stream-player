import 'dart:math';

import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';

/// Synthetische Großanbieter-Daten für Last-/Laufzeittests (deterministisch).

const stressCountries = [
  ('DE', 'Germany'), ('TR', 'Türkiye'), ('UK', 'United Kingdom'),
  ('AT', 'Austria'), ('CH', 'Schweiz'), ('FR', 'France'), ('IT', 'Italia'),
  ('ES', 'España'), ('NL', 'Nederland'), ('PL', 'Polska'), ('RO', 'Romania'),
  ('RS', 'Balkan'), ('AL', 'Shqip'), ('AR', 'Arabic'), ('US', 'USA'),
  ('IN', 'India'), ('GR', 'Greece'), ('PT', 'Portugal'), ('BG', 'Bulgaria'),
  ('KU', 'Kurdistan'),
];

const _topics = [
  'Sport', 'News', 'Movies', 'Kids', 'Music', 'Documentary', 'Entertainment',
  'Series', 'Regional', 'Religion', 'Shopping', 'Lifestyle', 'Cinema', 'PPV',
  'Events', 'Football', 'Nature', 'History', 'Comedy', 'Culture',
];

const _brands = [
  'ZDF', 'ARD', 'RTL', 'ProSieben', 'Sat.1', 'Kabel Eins', 'VOX', 'Sky Sport',
  'Sky Cinema', 'Eurosport', 'DAZN', 'TRT', 'ATV', 'Kanal D', 'Show TV',
  'Star TV', 'Fox', 'beIN Sports', 'BBC', 'ITV', 'Channel', 'Canal+', 'Rai',
  'Mediaset', 'TVE', 'Antena', 'Pink', 'Nova', 'Top Channel', 'MBC',
  'Al Jazeera', 'CNN', 'HBO', 'Discovery', 'National Geographic', 'Nick',
  'Cartoon Network', 'MTV', 'Arena Sport', 'Sport Klub',
];

const _suffix = ['', ' Avrupa', ' Maxx', ' Plus', ' Action', ' Family', ' Max'];
const _quality = ['HD', 'FHD', 'SD', '4K', 'ᴴᴰ', 'HEVC', '(Backup)', 'RAW'];

/// [channels] Sender in [groups] Gruppen, mit Varianten (HD/FHD/…),
/// Länderpräfixen in Gruppen- und teils in Sendernamen.
LiveData stressLive({int channels = 50000, int groups = 800, int seed = 1}) {
  final r = Random(seed);
  final cats = <Category>[];
  for (var g = 0; g < groups; g++) {
    final (code, land) = stressCountries[g % stressCountries.length];
    final topic = _topics[(g ~/ stressCountries.length) % _topics.length];
    final n = g ~/ (stressCountries.length * _topics.length);
    final name = switch (g % 4) {
      0 => '$code | $topic${n > 0 ? ' $n' : ''}',
      1 => '$code: $topic${n > 0 ? ' $n' : ''}',
      2 => '[$code] $topic${n > 0 ? ' $n' : ''}',
      _ => '$land $topic${n > 0 ? ' $n' : ''}',
    };
    cats.add(Category(id: 'g$g', name: name));
  }
  final out = <Channel>[];
  var i = 0;
  while (out.length < channels) {
    final g = i % groups;
    final (code, _) = stressCountries[g % stressCountries.length];
    final brand = _brands[r.nextInt(_brands.length)];
    final num = r.nextInt(12);
    final base = '$brand${num == 0 ? '' : ' $num'}'
        '${_suffix[r.nextInt(_suffix.length)]}';
    final prefixed = r.nextBool();
    // 1–4 Varianten desselben Senders in derselben Gruppe.
    final variants = 1 + r.nextInt(4);
    for (var v = 0; v < variants && out.length < channels; v++) {
      final q = v == 0 && r.nextBool() ? '' : ' ${_quality[r.nextInt(_quality.length)]}';
      final name = '${prefixed ? '$code: ' : ''}$base$q';
      final id = 'c${out.length}';
      out.add(Channel(
        id: id,
        name: name,
        categoryId: 'g$g',
        streamUrl: 'http://srv.example:8080/live/u/p/${out.length}.ts',
        logoUrl: r.nextInt(3) == 0 ? null : 'http://logo.example/$id.png',
        epgId: r.nextInt(4) == 0 ? null : 'e${out.length % 5000}',
        number: out.length + 1,
      ));
    }
    i++;
  }
  return LiveData(cats, out);
}

const _words = [
  'Night', 'Day', 'Love', 'War', 'City', 'Dark', 'Last', 'First', 'Return',
  'Secret', 'King', 'Queen', 'Road', 'Storm', 'Fire', 'Ice', 'Dream', 'Blood',
  'Gold', 'Star', 'Heart', 'Shadow', 'Island', 'River', 'Mountain', 'Hunter',
];

const _genres = [
  'Action', 'Drama', 'Komödie', 'Thriller', 'Horror', 'Science-Fiction',
  'Dokumentation', 'Animation', 'Krimi', 'Romance', 'Abenteuer', 'Familie',
  'Fantasy', 'War', 'History', 'Aksiyon', 'Dram', 'Komedi',
];
const _first = ['Anna', 'Jonas', 'Lena', 'Mehmet', 'Elif', 'Paul', 'Sofia',
  'Tom', 'Ayşe', 'Lukas', 'Mia', 'Emre', 'Clara', 'Noah', 'Zeynep'];
const _last = ['Berger', 'Yılmaz', 'Hartmann', 'Demir', 'Kern', 'Wolff',
  'Smith', 'Kaya', 'Fischer', 'Weber', 'Öztürk', 'Brown', 'Schulz'];

/// [items] Filme bzw. Serien in [cats] Kategorien. [rich]: zusätzlich
/// Genres (1–3, gemischte Schreibweisen), Jahr, Bewertung, Zeitstempel,
/// Besetzung (3–5 aus ~5000 Namen) und Regie – mit eigenem Zufall, damit
/// die übrigen Felder unverändert bleiben.
VodData stressVod({required int items, int cats = 300, bool series = false,
    int seed = 2, bool rich = false}) {
  final r = Random(seed);
  final x = Random(seed + 1000);
  String person() => '${_first[x.nextInt(_first.length)]} '
      '${_last[x.nextInt(_last.length)]}${x.nextInt(26) == 0 ? '' : ' ${String.fromCharCode(65 + x.nextInt(26))}.'}'
      '${x.nextInt(12)}';
  String genres() => [
        for (var g = 0, n = 1 + x.nextInt(3); g < n; g++)
          _genres[x.nextInt(_genres.length)]
      ].join(x.nextBool() ? ', ' : ' / ');
  final c = <Category>[
    for (var i = 0; i < cats; i++)
      Category(
          id: '${series ? 's' : 'm'}$i',
          name: '${stressCountries[i % stressCountries.length].$1} - '
              '${_topics[i % _topics.length]} ${i ~/ _topics.length}'),
  ];
  final out = <VodItem>[
    for (var i = 0; i < items; i++)
      VodItem(
        id: '${series ? 's' : 'm'}$i',
        name: '${i % 3 == 0 ? '${stressCountries[r.nextInt(stressCountries.length)].$1} - ' : ''}'
            '${_words[r.nextInt(_words.length)]} ${_words[r.nextInt(_words.length)]} '
            '${r.nextInt(500)} (${1970 + r.nextInt(56)})',
        categoryId: c[i % cats].id,
        streamUrl: 'http://srv.example:8080/movie/u/p/$i.mkv',
        isSeries: series,
        genre: rich && x.nextInt(10) > 0 ? genres() : null,
        year: rich ? 1950 + x.nextInt(76) : null,
        rating: rich ? (x.nextInt(100) / 10) : null,
        added: rich && x.nextInt(5) > 0
            ? DateTime(2020).add(Duration(minutes: x.nextInt(3000000)))
            : null,
        cast: rich && x.nextInt(3) > 0
            ? [for (var p = 0, n = 3 + x.nextInt(3); p < n; p++) person()]
                .join(', ')
            : null,
        director: rich && x.nextBool() ? person() : null,
      ),
  ];
  return VodData(c, out);
}

/// XMLTV mit [channels] Sendern über [days] Tage (je Tag [perDay]
/// Sendungen, Hälfte zurück, Hälfte voraus), stückweise an [sink].
void writeStressXmltv(StringSink sink,
    {int channels = 5000, int days = 14, int perDay = 24, DateTime? now}) {
  final t0 = (now ?? DateTime.now()).toUtc();
  final start = DateTime.utc(t0.year, t0.month, t0.day)
      .subtract(Duration(days: days ~/ 2));
  String ts(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}${t.hour.toString().padLeft(2, '0')}'
      '${t.minute.toString().padLeft(2, '0')}00 +0000';
  sink.write('<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n');
  for (var c = 0; c < channels; c++) {
    sink.write('<channel id="e$c"><display-name>Sender $c</display-name></channel>\n');
  }
  final step = Duration(minutes: 24 * 60 ~/ perDay);
  final b = StringBuffer();
  for (var c = 0; c < channels; c++) {
    var t = start;
    for (var p = 0; p < days * perDay; p++) {
      final e = t.add(step);
      b.write('<programme start="${ts(t)}" stop="${ts(e)}" channel="e$c">'
          '<title lang="de">${_words[(c + p) % _words.length]} '
          '${_words[(c * 7 + p) % _words.length]} $p</title>'
          '<desc lang="de">Folge $p der Reihe – eine Beschreibung mit etwas '
          'Text, wie sie in echten EPG-Daten vorkommt (Sender $c).</desc>'
          '<category lang="de">Serie</category></programme>\n');
      t = e;
    }
    sink.write(b.toString());
    b.clear();
  }
  sink.write('</tv>\n');
}
