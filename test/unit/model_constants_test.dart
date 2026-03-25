import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/constants/model_constants.dart';

void main() {
  group('ModelConstants', () {
    test('has both tomato and burmese_grape_leaf models', () {
      expect(ModelConstants.availableLeafTypes, contains('tomato'));
      expect(ModelConstants.availableLeafTypes, contains('burmese_grape_leaf'));
      expect(ModelConstants.availableLeafTypes.length, 2);
    });

    test('getModel returns correct info for tomato', () {
      final info = ModelConstants.getModel('tomato');
      expect(info.leafType, 'tomato');
      expect(info.numClasses, 10);
      expect(info.classLabels.length, 10);
      expect(info.assetPath, contains('tomato_student.tflite'));
    });

    test('getModel returns correct info for burmese_grape_leaf', () {
      final info = ModelConstants.getModel('burmese_grape_leaf');
      expect(info.leafType, 'burmese_grape_leaf');
      expect(info.numClasses, 5);
      expect(info.classLabels.length, 5);
      expect(info.assetPath, contains('burmese_grape_leaf_student.tflite'));
    });

    test('getModel throws for unknown leaf type', () {
      expect(
        () => ModelConstants.getModel('unknown'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('tomato class labels follow ImageFolder alphabetical order', () {
      final labels = ModelConstants.getModel('tomato').classLabels;
      // Index 0 should be Bacterial_spot (alphabetically first)
      expect(labels[0], 'Tomato___Bacterial_spot');
      // Index 9 should be healthy (alphabetically last)
      expect(labels[9], 'Tomato___healthy');
    });

    test('burmese class labels follow ImageFolder alphabetical order', () {
      final labels = ModelConstants.getModel('burmese_grape_leaf').classLabels;
      expect(labels[0], 'Anthracnose (Brown Spot)');
      expect(labels[1], 'Healthy');
      expect(labels[4], 'Powdery Mildew');
    });
  });

  group('LeafModelInfo', () {
    test('diseaseLabels excludes healthy class', () {
      final tomato = ModelConstants.getModel('tomato');
      expect(tomato.diseaseLabels.length, 9);
      expect(tomato.diseaseLabels.any((l) => l.contains('healthy')), isFalse);
    });

    test('hasHealthyClass returns true for both models', () {
      expect(ModelConstants.getModel('tomato').hasHealthyClass, isTrue);
      expect(ModelConstants.getModel('burmese_grape_leaf').hasHealthyClass, isTrue);
    });

    test('localizedName returns correct language', () {
      final tomato = ModelConstants.getModel('tomato');
      expect(tomato.localizedName('en'), 'Tomato Leaf');
      expect(tomato.localizedName('vi'), contains('cà chua'));
    });

    test('localizedClassName returns translated names', () {
      final tomato = ModelConstants.getModel('tomato');
      expect(tomato.localizedClassName('Tomato___healthy', 'en'), 'Healthy');
      expect(tomato.localizedClassName('Tomato___healthy', 'vi'), 'Khỏe mạnh');
    });

    test('cleanLabel strips prefix and underscores', () {
      expect(LeafModelInfo.cleanLabel('Tomato___Bacterial_spot'), 'Bacterial spot');
      expect(LeafModelInfo.cleanLabel('Healthy'), 'Healthy');
    });
  });
}
