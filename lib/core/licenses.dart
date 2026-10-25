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
        LicenseEntryWithLineBreaks(['OkHttp 4.12'], '''
Copyright (C) Square, Inc.

Licensed under the Apache License, Version 2.0. http://www.apache.org/licenses/LICENSE-2.0'''),
      ]));
}
