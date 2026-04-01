import 'dart:io';

import 'package:flutter/widgets.dart';

/// Builds an Image widget from a file path using dart:io File.
Widget buildFileImage(
  String path, {
  double? height,
  double? width,
  BoxFit? fit,
  Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
}) {
  return Image.file(
    File(path),
    height: height,
    width: width,
    fit: fit,
    errorBuilder: errorBuilder,
  );
}
