import 'dart:typed_data';

/// Web stub — File operations are not available on web.
class File {
  final String path;
  File(this.path);
  Future<bool> exists() async => false;
  Future<int> length() async => 0;
  Future<Uint8List> readAsBytes() async => Uint8List(0);
}
