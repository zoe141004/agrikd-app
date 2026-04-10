import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Top-level function for compute() isolate — compresses an image file.
/// Must be top-level (not a class method) so it can be sent to an isolate.
Uint8List compressImageSync(String imagePath) {
  try {
    final file = File(imagePath);
    if (!file.existsSync()) {
      throw ArgumentError('Image file not found: $imagePath');
    }
    final bytes = file.readAsBytesSync();
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw ArgumentError('Could not decode image: $imagePath');
    }

    // Resize if larger than max dimension
    const maxDimension = 800;
    const maxSizeBytes = 200 * 1024; // 200KB
    img.Image resized = image;
    if (image.width > maxDimension || image.height > maxDimension) {
      if (image.width > image.height) {
        resized = img.copyResize(image, width: maxDimension);
      } else {
        resized = img.copyResize(image, height: maxDimension);
      }
    }

    // Try encoding at decreasing quality until under 200KB
    for (final quality in [80, 60, 40, 20]) {
      final compressed = img.encodeJpg(resized, quality: quality);
      if (compressed.length <= maxSizeBytes || quality == 20) {
        return Uint8List.fromList(compressed);
      }
    }

    // Unreachable: loop always returns on quality == 20
    return Uint8List.fromList(img.encodeJpg(resized, quality: 20));
  } catch (e) {
    // Re-throw with context so compute() caller gets a meaningful error
    throw ArgumentError('Image compression failed for $imagePath: $e');
  }
}
