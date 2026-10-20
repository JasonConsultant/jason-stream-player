import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/updater.dart';

void main() {
  test('Versionen vergleichen', () {
    expect(Updater.compareVersions('0.9.10', '0.9.4'), 1);
    expect(Updater.compareVersions('v1.0.0', '0.9.9'), 1);
    expect(Updater.compareVersions('0.9.4', '0.9.4+15'), 0);
    expect(Updater.compareVersions('0.9.3', '0.9.4'), -1);
  });

  test('Passende APK wählen', () {
    expect(
        Updater.assetFor(
            package: 'de.jasonstream.player',
            abis: ['arm64-v8a', 'armeabi-v7a'],
            version: '1.0.0'),
        'JasonStreamPlayer_1.0.0_arm64.apk');
    expect(
        Updater.assetFor(
            package: 'de.jasonstream.player.tr',
            abis: ['armeabi-v7a'],
            version: '1.0.0'),
        'JasonStreamPlayer_TR_1.0.0_arm32.apk');
    // TV-Build (beide Architekturen) → wieder die TV-APK
    expect(
        Updater.assetFor(
            package: 'de.jasonstream.player',
            abis: ['arm64-v8a', 'armeabi-v7a'],
            version: '1.0.6',
            universal: true),
        'JasonStreamPlayer_TV_1.0.6.apk');
    expect(
        Updater.assetFor(
            package: 'de.jasonstream.player.tr',
            abis: ['armeabi-v7a'],
            version: '1.0.6',
            universal: true),
        'JasonStreamPlayer_TR_TV_1.0.6.apk');
  });

  test('Versionen: Tag mit v und vierstellig', () {
    expect(Updater.compareVersions('1.0.10', '1.0.9'), 1);
    expect(Updater.compareVersions('1.0.6', '1.0.6'), 0);
    expect(Updater.compareVersions('1.0', '1.0.0'), 0);
  });
}
