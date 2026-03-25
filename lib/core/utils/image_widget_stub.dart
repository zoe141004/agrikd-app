import 'package:flutter/widgets.dart';

/// Builds an Image widget from a file path.
/// On web, this stub is used — shows a placeholder since dart:io is unavailable.
Widget buildFileImage(
  String path, {
  double? height,
  double? width,
  BoxFit? fit,
  Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
}) {
  return Builder(
    builder: (context) =>
        errorBuilder?.call(context, 'Not supported on web', null) ??
        const SizedBox.shrink(),
  );
}
