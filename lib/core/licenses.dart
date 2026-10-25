import 'package:flutter/foundation.dart';

/// Lizenzhinweise für eingebundene native Bibliotheken, die nicht als
/// Dart-Paket im Lizenzverzeichnis auftauchen (Seite „Open-Source-Lizenzen“).
void registerNativeLicenses() {
  LicenseRegistry.addLicense(() => Stream.fromIterable(const [
        LicenseEntryWithLineBreaks(['AndroidX Media3 (ExoPlayer) 1.8.0'], '''
Copyright (C) The Android Open Source Project

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.'''),
        LicenseEntryWithLineBreaks(['Media3 FFmpeg decoder (org.jellyfin.media3:media3-ffmpeg-decoder 1.8.0+1)'], '''
Extension code: Copyright (C) The Android Open Source Project and Jellyfin contributors, Apache License 2.0.

Bundled FFmpeg libraries (libffmpegJNI): FFmpeg is licensed under the GNU Lesser General Public License (LGPL) version 2.1 or later. FFmpeg is a trademark of Fabrice Bellard. Source code: https://ffmpeg.org and https://github.com/jellyfin/jellyfin-androidx-media

This library is free software; you can redistribute it and/or modify it under the terms of the GNU Lesser General Public License as published by the Free Software Foundation; either version 2.1 of the License, or (at your option) any later version. This library is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.'''),
        LicenseEntryWithLineBreaks(['AndroidX MediaRouter 1.8.0, AndroidX AppCompat/Fragment/RecyclerView (Abhängigkeiten von Google Cast)'], '''
Copyright (C) The Android Open Source Project

Licensed under the Apache License, Version 2.0. http://www.apache.org/licenses/LICENSE-2.0'''),
        LicenseEntryWithLineBreaks(['Google Play services – Cast framework (com.google.android.gms:play-services-cast-framework 22.1.0)'], '''
Copyright (C) Google LLC.

Not open source: provided by Google under the Android Software Development Kit License Agreement (https://developer.android.com/studio/terms). Used for Chromecast (Google Cast) with the Default Media Receiver. Google Cast requires Google Play services on the device.'''),
        LicenseEntryWithLineBreaks(['OkHttp 4.12'], '''
Copyright (C) Square, Inc.

Licensed under the Apache License, Version 2.0. http://www.apache.org/licenses/LICENSE-2.0'''),
        LicenseEntryWithLineBreaks(['SQLite 3 (über das Dart-Paket sqlite3, MIT-Lizenz)'], '''
The author disclaims copyright to this source code. In place of a legal notice, here is a blessing:

May you do good and not evil.
May you find forgiveness for yourself and forgive others.
May you share freely, never taking more than you give.

SQLite is in the public domain (https://sqlite.org/copyright.html). Used as the on-device catalog database (channel lists, movies, series, programme guide, search index).'''),
      ]));
}
