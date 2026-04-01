import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../constants/app_constants.dart';

/// Top-level function for compute() isolate — reads, validates, decodes and
/// preprocesses an image file into a Float32List ready for TFLite inference.
/// Must be top-level (not a class method) so it can be sent to an isolate.
Float32List preprocessImageFromPath(String imagePath) {
  final bytes = File(imagePath).readAsBytesSync();

  // Magic bytes validation
  if (bytes.length < 4) {
    throw ArgumentError('Invalid image file');
  }
  final isJpeg = bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
  final isPng =
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47;
  if (!isJpeg && !isPng) {
    throw ArgumentError('Invalid image file. Content is not JPEG or PNG.');
  }

  final image = img.decodeImage(bytes);
  if (image == null) {
    throw ArgumentError('Could not decode image');
  }
  return ImagePreprocessor.preprocess(image);
}

class ImagePreprocessor {
  ImagePreprocessor._();

  /// Replicate PyTorch: Resize(224,224) -> ToTensor() -> Normalize(ImageNet)
  /// Output: Float32List [1 * 224 * 224 * 3] in NHWC format for TFLite
  static Float32List preprocess(img.Image image) {
    const size = AppConstants.imageSize;
    const mean = AppConstants.imagenetMean;
    const std = AppConstants.imagenetStd;

    // 1. Resize to 224x224
    final resized = img.copyResize(
      image,
      width: size,
      height: size,
      interpolation: img.Interpolation.linear,
    );

    // 2. Convert to float [0,1] and normalize (NHWC format for TFLite)
    final input = Float32List(1 * size * size * 3);

    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final pixel = resized.getPixel(x, y);
        final idx = (y * size + x) * 3;
        input[idx + 0] = (pixel.r / 255.0 - mean[0]) / std[0]; // R
        input[idx + 1] = (pixel.g / 255.0 - mean[1]) / std[1]; // G
        input[idx + 2] = (pixel.b / 255.0 - mean[2]) / std[2]; // B
      }
    }
    return input;
  }

  /// Validate image file before processing
  static bool isValidImageSize(int fileSizeBytes) {
    return fileSizeBytes <= AppConstants.maxImageSizeBytes;
  }
}
