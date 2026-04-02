import 'dart:io' show File;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

class ModelIntegrity {
  ModelIntegrity._();

  /// Compute SHA-256 checksum of an asset file
  static Future<String> sha256Asset(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Compute SHA-256 checksum of a filesystem file (for OTA models)
  static Future<String> sha256File(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    return sha256.convert(bytes).toString();
  }

  /// Compute SHA-256 checksum of raw bytes
  static String sha256Bytes(List<int> bytes) {
    return sha256.convert(bytes).toString();
  }

  /// Verify a bundled asset against its expected checksum
  static Future<bool> verify(String assetPath, String expectedChecksum) async {
    final actual = await sha256Asset(assetPath);
    return actual == expectedChecksum;
  }

  /// Verify a filesystem file against its expected checksum (for OTA models)
  static Future<bool> verifyFile(
    String filePath,
    String expectedChecksum,
  ) async {
    final actual = await sha256File(filePath);
    return actual == expectedChecksum;
  }
}
