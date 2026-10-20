import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/subtitle_style.dart';

void main() {
  test('Standard: normal, weiß, kein Kasten, Rand an', () {
    final s = SubtitleStyle.fromOptions((k, f) => f);
    expect(s.mpvProperties, {
      'sub-font-size': '48',
      'sub-color': '#FFFFFFFF',
      'sub-back-color': '#00000000',
      'sub-border-size': '2',
      'sub-border-color': '#FF000000',
    });
  });

  test('Größen → sub-font-size', () {
    expect(const SubtitleStyle(size: 'klein').fontSize, 36);
    expect(const SubtitleStyle(size: 'normal').fontSize, 48);
    expect(const SubtitleStyle(size: 'gross').fontSize, 60);
    expect(const SubtitleStyle(size: 'sehrgross').fontSize, 72);
  });

  test('Farben → #AARRGGBB', () {
    expect(const SubtitleStyle(color: 'weiss').colorHex, '#FFFFFFFF');
    expect(const SubtitleStyle(color: 'gelb').colorHex, '#FFFFFF00');
    expect(const SubtitleStyle(color: 'cyan').colorHex, '#FF00FFFF');
    expect(const SubtitleStyle(color: 'gelb').colorArgb, 0xFFFFFF00);
  });

  test('Kasten und Rand', () {
    final s = const SubtitleStyle(box: true, outline: false);
    expect(s.backColorHex, '#80000000');
    expect(s.borderSize, 0);
    expect(s.mpvProperties['sub-border-size'], '0');
  });

  test('Aus Storage-Optionen; unbekannte Werte → Standard', () {
    final opts = {
      'sub_size': 'sehrgross',
      'sub_color': 'cyan',
      'sub_bg': 'box',
      'sub_outline': 'off',
    };
    final s = SubtitleStyle.fromOptions((k, f) => opts[k] ?? f);
    expect(s.size, 'sehrgross');
    expect(s.color, 'cyan');
    expect(s.box, isTrue);
    expect(s.outline, isFalse);
    expect(s.options, opts);

    final bad = SubtitleStyle.fromOptions((k, f) => 'quatsch');
    expect(bad.size, 'normal');
    expect(bad.color, 'weiss');
    expect(bad.box, isFalse);
    expect(bad.outline, isTrue); // alles außer 'off' = an
  });
}
