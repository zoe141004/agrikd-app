import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';

import 'package:app/core/utils/model_integrity.dart';

void main() {
  group('ModelIntegrity', () {
    test('sha256Bytes computes correct hash for known input', () {
      // SHA-256 of empty string
      final hash = ModelIntegrity.sha256Bytes([]);
      expect(hash, 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });

    test('sha256Bytes computes correct hash for "hello"', () {
      final hash = ModelIntegrity.sha256Bytes('hello'.codeUnits);
      // Known SHA-256 of "hello"
      final expected = sha256.convert('hello'.codeUnits).toString();
      expect(hash, expected);
    });

    test('sha256Bytes produces different hashes for different inputs', () {
      final hash1 = ModelIntegrity.sha256Bytes('data1'.codeUnits);
      final hash2 = ModelIntegrity.sha256Bytes('data2'.codeUnits);
      expect(hash1, isNot(equals(hash2)));
    });

    test('sha256Bytes produces consistent hash for same input', () {
      final input = 'consistent data'.codeUnits;
      final hash1 = ModelIntegrity.sha256Bytes(input);
      final hash2 = ModelIntegrity.sha256Bytes(input);
      expect(hash1, equals(hash2));
    });
  });
}
