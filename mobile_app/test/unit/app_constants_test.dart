import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/constants/app_constants.dart';

void main() {
  group('AppConstants', () {
    test('imageSize is 224', () {
      expect(AppConstants.imageSize, 224);
    });

    test('imagenetMean has 3 channels', () {
      expect(AppConstants.imagenetMean.length, 3);
      expect(AppConstants.imagenetMean[0], closeTo(0.485, 0.001));
      expect(AppConstants.imagenetMean[1], closeTo(0.456, 0.001));
      expect(AppConstants.imagenetMean[2], closeTo(0.406, 0.001));
    });

    test('imagenetStd has 3 channels', () {
      expect(AppConstants.imagenetStd.length, 3);
      expect(AppConstants.imagenetStd[0], closeTo(0.229, 0.001));
      expect(AppConstants.imagenetStd[1], closeTo(0.224, 0.001));
      expect(AppConstants.imagenetStd[2], closeTo(0.225, 0.001));
    });

    test('maxImageSizeBytes is 10 MB', () {
      expect(AppConstants.maxImageSizeBytes, 10 * 1024 * 1024);
    });

    test('syncBatchSize is 50', () {
      expect(AppConstants.syncBatchSize, 50);
    });
  });
}
