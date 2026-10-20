import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/repository.dart';
import 'package:jason_stream_player/models/models.dart';

Channel ch(String id, String epg) =>
    Channel(id: id, name: id, categoryId: 'c', streamUrl: 'http://x/$id', epgId: epg);

void main() {
  test('Nur EPGs der Länder der Sender', () {
    const base = 'https://epgshare01.online/epgshare01/epg_ripper_';
    final urls = [
      for (final c in ['AL1', 'ALL_SOURCES1', 'AT1', 'DE1', 'DELUXEMUSIC1', 'IT1', 'TR1', 'UK1', 'US2'])
        '$base$c.xml.gz'
    ];
    final channels = [
      ch('1', 'ZDF.de'), ch('2', 'DasErste.de'), ch('3', 'TRT1.tr'),
      ch('4', 'BBCOne.uk'),
    ];
    final picked = IptvRepository.pickEpgUrls(urls, channels);
    expect(picked, ['${base}DE1.xml.gz', '${base}TR1.xml.gz', '${base}UK1.xml.gz']);
  });
}
