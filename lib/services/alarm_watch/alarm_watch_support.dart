import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Arka planda alarm bildirimi bu platformda var mı (yalnız Android; web/iOS/masaüstü/test ortamı ✖).
bool get alarmWatchPlatformSupported => !kIsWeb && Platform.isAndroid;
