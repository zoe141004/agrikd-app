class AppConstants {
  AppConstants._();

  static const int imageSize = 224;
  static const List<double> imagenetMean = [0.485, 0.456, 0.406];
  static const List<double> imagenetStd = [0.229, 0.224, 0.225];
  static const int maxImageSizeBytes = 10 * 1024 * 1024; // 10 MB
  static const int syncBatchSize = 50;
  static const int maxSyncRetries = 3;
  static const String appName = 'AgriKD';
}
