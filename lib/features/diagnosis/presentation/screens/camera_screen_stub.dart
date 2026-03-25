import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'package:app/core/l10n/app_strings.dart';
import 'package:app/providers/diagnosis_provider.dart';
import 'package:app/providers/sync_provider.dart';
import 'result_screen.dart';

/// Web-only CameraScreen — no camera/permission_handler, gallery pick only.
class CameraScreen extends ConsumerStatefulWidget {
  final String leafType;

  const CameraScreen({super.key, required this.leafType});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  bool _isProcessing = false;
  final ImagePicker _picker = ImagePicker();

  Future<void> _pickFromGallery() async {
    if (_isProcessing) return;

    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 90,
    );

    if (image == null) return;

    setState(() => _isProcessing = true);
    await _processImage(image.path);
  }

  Future<void> _processImage(String imagePath) async {
    await ref
        .read(diagnosisProvider.notifier)
        .diagnose(imagePath, widget.leafType);

    final diagState = ref.read(diagnosisProvider);
    if (diagState.status == DiagnosisStatus.error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(diagState.errorMessage ?? S.get('error_generic'))),
        );
        setState(() => _isProcessing = false);
      }
      return;
    }

    // Trigger sync after successful diagnosis
    ref.read(syncProvider.notifier).triggerSync();

    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ResultScreen(leafType: widget.leafType),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(S.get('take_photo')),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: _isProcessing
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 16),
                  Text(S.get('checking'), style: const TextStyle(color: Colors.white)),
                ],
              ),
            )
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.camera_alt_outlined,
                        size: 64, color: Colors.white54),
                    const SizedBox(height: 16),
                    Text(
                      S.get('camera_no_web'),
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _pickFromGallery,
                      icon: const Icon(Icons.photo_library),
                      label: Text(S.get('pick_gallery')),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
