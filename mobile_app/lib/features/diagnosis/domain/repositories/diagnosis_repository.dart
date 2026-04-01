import '../models/prediction.dart';

abstract class DiagnosisRepository {
  Future<void> loadModel(String leafType);
  Future<Prediction> diagnose(String imagePath, String leafType);
  void dispose();
}
