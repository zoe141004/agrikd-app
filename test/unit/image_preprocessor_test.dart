import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:app/core/utils/image_preprocessor.dart';
import 'package:app/core/constants/app_constants.dart';

void main() {
  group('ImagePreprocessor', () {
    test('preprocess returns correct length for 224x224 NHWC', () {
      final image = img.Image(width: 300, height: 200);
      final result = ImagePreprocessor.preprocess(image);

      expect(result, isA<Float32List>());
      expect(result.length, 1 * 224 * 224 * 3);
    });

    test('preprocess normalizes pixel values with ImageNet stats', () {
      // Create a solid red image (R=255, G=0, B=0)
      final image = img.Image(width: 224, height: 224);
      for (int y = 0; y < 224; y++) {
        for (int x = 0; x < 224; x++) {
          image.setPixelRgb(x, y, 255, 0, 0);
        }
      }

      final result = ImagePreprocessor.preprocess(image);

      // First pixel R channel: (255/255.0 - 0.485) / 0.229
      final expectedR = (1.0 - AppConstants.imagenetMean[0]) / AppConstants.imagenetStd[0];
      expect(result[0], closeTo(expectedR, 0.01));

      // First pixel G channel: (0/255.0 - 0.456) / 0.224
      final expectedG = (0.0 - AppConstants.imagenetMean[1]) / AppConstants.imagenetStd[1];
      expect(result[1], closeTo(expectedG, 0.01));

      // First pixel B channel: (0/255.0 - 0.406) / 0.225
      final expectedB = (0.0 - AppConstants.imagenetMean[2]) / AppConstants.imagenetStd[2];
      expect(result[2], closeTo(expectedB, 0.01));
    });

    test('isValidImageSize accepts files under 10 MB', () {
      expect(ImagePreprocessor.isValidImageSize(1024 * 1024), isTrue); // 1 MB
      expect(ImagePreprocessor.isValidImageSize(10 * 1024 * 1024), isTrue); // 10 MB exactly
    });

    test('isValidImageSize rejects files over 10 MB', () {
      expect(ImagePreprocessor.isValidImageSize(10 * 1024 * 1024 + 1), isFalse);
      expect(ImagePreprocessor.isValidImageSize(50 * 1024 * 1024), isFalse);
    });
  });
}
