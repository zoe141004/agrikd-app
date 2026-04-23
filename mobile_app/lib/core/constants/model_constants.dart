class LeafModelInfo {
  final String leafType;
  final String displayName;
  final String vietnameseName;
  final String englishName;
  final String? assetPath;
  final int numClasses;
  final List<String> classLabels;
  final Map<String, String> classDisplayNames;
  final Map<String, String> classEnglishNames;

  const LeafModelInfo({
    required this.leafType,
    required this.displayName,
    required this.vietnameseName,
    required this.englishName,
    this.assetPath,
    required this.numClasses,
    required this.classLabels,
    required this.classDisplayNames,
    required this.classEnglishNames,
  });

  /// Build a LeafModelInfo from server/DB data (for OTA-only models not bundled in app).
  factory LeafModelInfo.fromServer({
    required String leafType,
    required int numClasses,
    required List<String> classLabels,
    String? displayName,
  }) {
    final name = displayName ?? _capitalize(leafType.replaceAll('_', ' '));
    final cleanedNames = {for (final l in classLabels) l: cleanLabel(l)};
    return LeafModelInfo(
      leafType: leafType,
      displayName: name,
      vietnameseName: name,
      englishName: name,
      numClasses: numClasses,
      classLabels: classLabels,
      classDisplayNames: cleanedNames,
      classEnglishNames: cleanedNames,
    );
  }

  static String _capitalize(String s) {
    return s
        .split(' ')
        .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  /// Labels for diseases only (excludes any "healthy" class).
  List<String> get diseaseLabels =>
      classLabels.where((l) => !l.toLowerCase().contains('healthy')).toList();

  /// Number of diseases (excludes healthy class).
  int get diseaseCount => diseaseLabels.length;

  /// Whether this model includes a healthy-leaf class.
  bool get hasHealthyClass =>
      classLabels.any((l) => l.toLowerCase().contains('healthy'));

  /// Locale-aware leaf type name.
  String localizedName(String locale) =>
      locale == 'vi' ? vietnameseName : englishName;

  /// Locale-aware class display name for a given raw label.
  String localizedClassName(String label, String locale) {
    if (locale == 'vi') {
      return classDisplayNames[label] ?? cleanLabel(label);
    }
    return classEnglishNames[label] ?? cleanLabel(label);
  }

  /// Converts a raw classLabel into human-readable English.
  /// Strips prefix like "Tomato___" and replaces underscores with spaces.
  static String cleanLabel(String raw) {
    final stripped = raw.contains('___') ? raw.split('___').last : raw;
    return stripped.replaceAll('_', ' ').trim();
  }
}

class ModelConstants {
  ModelConstants._();

  static const Map<String, LeafModelInfo> models = {
    'tomato': LeafModelInfo(
      leafType: 'tomato',
      displayName: 'Lá cà chua (Tomato Leaf)',
      vietnameseName: 'Lá cà chua',
      englishName: 'Tomato Leaf',
      assetPath: 'assets/models/tomato/tomato_student.tflite',
      numClasses: 10,
      // ImageFolder alphabetical sort on folder names
      classLabels: [
        'Tomato___Bacterial_spot',
        'Tomato___Early_blight',
        'Tomato___Late_blight',
        'Tomato___Leaf_Mold',
        'Tomato___Septoria_leaf_spot',
        'Tomato___Spider_mites Two-spotted_spider_mite',
        'Tomato___Target_Spot',
        'Tomato___Tomato_Yellow_Leaf_Curl_Virus',
        'Tomato___Tomato_mosaic_virus',
        'Tomato___healthy',
      ],
      classDisplayNames: {
        'Tomato___Bacterial_spot': 'Đốm vi khuẩn',
        'Tomato___Early_blight': 'Sương mai sớm',
        'Tomato___Late_blight': 'Sương mai muộn',
        'Tomato___Leaf_Mold': 'Mốc lá',
        'Tomato___Septoria_leaf_spot': 'Đốm lá Septoria',
        'Tomato___Spider_mites Two-spotted_spider_mite': 'Nhện đỏ hai chấm',
        'Tomato___Target_Spot': 'Đốm đích',
        'Tomato___Tomato_Yellow_Leaf_Curl_Virus': 'Virus xoăn vàng lá',
        'Tomato___Tomato_mosaic_virus': 'Virus khảm',
        'Tomato___healthy': 'Khỏe mạnh',
      },
      classEnglishNames: {
        'Tomato___Bacterial_spot': 'Bacterial spot',
        'Tomato___Early_blight': 'Early blight',
        'Tomato___Late_blight': 'Late blight',
        'Tomato___Leaf_Mold': 'Leaf Mold',
        'Tomato___Septoria_leaf_spot': 'Septoria leaf spot',
        'Tomato___Spider_mites Two-spotted_spider_mite': 'Spider mites',
        'Tomato___Target_Spot': 'Target Spot',
        'Tomato___Tomato_Yellow_Leaf_Curl_Virus': 'Yellow Leaf Curl Virus',
        'Tomato___Tomato_mosaic_virus': 'Mosaic virus',
        'Tomato___healthy': 'Healthy',
      },
    ),
    'burmese_grape_leaf': LeafModelInfo(
      leafType: 'burmese_grape_leaf',
      displayName: 'Lá mận Miến Điện (Burmese Grape Leaf)',
      vietnameseName: 'Lá mận Miến Điện',
      englishName: 'Burmese Grape Leaf',
      assetPath:
          'assets/models/burmese_grape_leaf/burmese_grape_leaf_student.tflite',
      numClasses: 5,
      // ImageFolder alphabetical sort on folder names
      classLabels: [
        'Anthracnose (Brown Spot)',
        'Healthy',
        'Insect Damage',
        'Leaf Spot (Yellow)',
        'Powdery Mildew',
      ],
      classDisplayNames: {
        'Anthracnose (Brown Spot)': 'Thán thư - Đốm nâu',
        'Healthy': 'Khỏe mạnh',
        'Insect Damage': 'Hư hại do côn trùng',
        'Leaf Spot (Yellow)': 'Đốm vàng lá',
        'Powdery Mildew': 'Phấn trắng',
      },
      classEnglishNames: {
        'Anthracnose (Brown Spot)': 'Anthracnose (Brown Spot)',
        'Healthy': 'Healthy',
        'Insect Damage': 'Insect Damage',
        'Leaf Spot (Yellow)': 'Leaf Spot (Yellow)',
        'Powdery Mildew': 'Powdery Mildew',
      },
    ),
  };

  static LeafModelInfo getModel(String leafType) {
    final model = models[leafType];
    if (model == null) {
      throw ArgumentError('Unknown leaf type: $leafType');
    }
    return model;
  }

  /// Returns null instead of throwing for unknown leaf types (server-only models).
  static LeafModelInfo? tryGetModel(String leafType) => models[leafType];

  static List<String> get availableLeafTypes => models.keys.toList();

  /// Cached list of all LeafModelInfo values (avoids re-creating on every access).
  static final List<LeafModelInfo> modelsList = models.values.toList();
}
