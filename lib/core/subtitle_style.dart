/// Untertitel-Aussehen: Einstellungen (Storage-Optionen sub_size, sub_color,
/// sub_bg, sub_outline) → mpv-Eigenschaften. Reines Dart, ohne Flutter.
class SubtitleStyle {
  /// 'klein' | 'normal' | 'gross' | 'sehrgross'
  final String size;

  /// 'weiss' | 'gelb' | 'cyan'
  final String color;

  /// true = halbtransparenter Kasten hinter dem Text.
  final bool box;

  /// true = schwarzer Rand um die Buchstaben.
  final bool outline;

  const SubtitleStyle({
    this.size = 'normal',
    this.color = 'weiss',
    this.box = false,
    this.outline = true,
  });

  static const sizes = ['klein', 'normal', 'gross', 'sehrgross'];
  static const colors = ['weiss', 'gelb', 'cyan'];

  /// Aus Storage-Optionen (unbekannte Werte → Standard).
  factory SubtitleStyle.fromOptions(String Function(String key, String fallback) option) =>
      SubtitleStyle(
        size: _pick(option('sub_size', 'normal'), sizes, 'normal'),
        color: _pick(option('sub_color', 'weiss'), colors, 'weiss'),
        box: option('sub_bg', 'none') == 'box',
        outline: option('sub_outline', 'on') != 'off',
      );

  static String _pick(String v, List<String> allowed, String fallback) =>
      allowed.contains(v) ? v : fallback;

  /// mpv: sub-font-size (bezogen auf 720p-Höhe).
  int get fontSize => switch (size) {
        'klein' => 36,
        'gross' => 60,
        'sehrgross' => 72,
        _ => 48,
      };

  /// mpv-Farbe als #AARRGGBB.
  String get colorHex => switch (color) {
        'gelb' => '#FFFFFF00',
        'cyan' => '#FF00FFFF',
        _ => '#FFFFFFFF',
      };

  /// Textfarbe als ARGB-Zahl (für die Vorschau in Flutter).
  int get colorArgb => switch (color) {
        'gelb' => 0xFFFFFF00,
        'cyan' => 0xFF00FFFF,
        _ => 0xFFFFFFFF,
      };

  String get backColorHex => box ? '#80000000' : '#00000000';

  int get borderSize => outline ? 2 : 0;

  /// Alle mpv-Eigenschaften, die gesetzt werden müssen (Name → Wert).
  Map<String, String> get mpvProperties => {
        'sub-font-size': '$fontSize',
        'sub-color': colorHex,
        'sub-back-color': backColorHex,
        'sub-border-size': '$borderSize',
        'sub-border-color': '#FF000000',
      };

  SubtitleStyle copy({String? size, String? color, bool? box, bool? outline}) =>
      SubtitleStyle(
        size: size ?? this.size,
        color: color ?? this.color,
        box: box ?? this.box,
        outline: outline ?? this.outline,
      );

  /// Storage-Optionen zum Speichern.
  Map<String, String> get options => {
        'sub_size': size,
        'sub_color': color,
        'sub_bg': box ? 'box' : 'none',
        'sub_outline': outline ? 'on' : 'off',
      };
}
