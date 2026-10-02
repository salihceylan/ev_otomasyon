import 'dart:async';
import 'dart:io';

import '../services/api_exception.dart';
import '../services/automation_api_service.dart';
import '../services/secure_storage_service.dart';

/// Herhangi bir istisnayı kullanıcıya gösterilebilir Türkçe mesaja çevirir.
///
/// Ham istisna metni (SQL, yığın, dosya yolu, `Exception: ...` öneki) **asla** gösterilmez;
/// bilinmeyen hatalar için [fallback] döner.
String friendlyError(
  Object? error, {
  String fallback = 'İşlem tamamlanamadı. Lütfen tekrar deneyin.',
}) {
  if (error is ApiException) return error.message;
  if (error is LocalApiException) return error.message;
  if (error is SecureStorageException) return error.message;
  if (error is TimeoutException) {
    return 'İşlem zaman aşımına uğradı. Bağlantınızı kontrol edip tekrar deneyin.';
  }
  if (error is IOException) {
    return 'Ağ bağlantısı kurulamadı. Bağlantınızı kontrol edip tekrar deneyin.';
  }
  return fallback;
}
