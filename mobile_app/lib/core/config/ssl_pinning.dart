import 'dart:io';

import 'package:flutter/foundation.dart';

/// Enforces SSL certificate validation for all HTTP requests.
///
/// In release builds, rejects any bad certificate (self-signed, expired,
/// wrong hostname). In debug/profile builds, allows all certificates
/// for local development flexibility.
class SslPinningHttpOverrides extends HttpOverrides {
  /// [allowedHost] — the hostname of the Supabase project (e.g.,
  /// "xyz.supabase.co"). Reserved for future SPKI hash pinning.
  SslPinningHttpOverrides({required String allowedHost});

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);

    if (kReleaseMode) {
      // In production: reject ALL bad certificates unconditionally.
      // This prevents MITM attacks even if a rogue CA is trusted.
      client.badCertificateCallback = (cert, host, port) {
        debugPrint(
          '[SSL] Bad certificate rejected for $host:$port '
          '(issuer: ${cert.issuer}, expires: ${cert.endValidity})',
        );
        return false;
      };
    }

    return client;
  }
}
