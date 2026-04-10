import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:app/core/l10n/app_strings.dart';
import 'package:app/providers/diagnosis_provider.dart';
import 'package:app/providers/sync_provider.dart';
import 'result_screen.dart';

class CameraScreen extends ConsumerStatefulWidget {
  final String leafType;

  const CameraScreen({super.key, required this.leafType});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  int _selectedCameraIndex = 0;
  bool _isInitializing = true;
  bool _isProcessing = false;
  bool _permissionDenied = false;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (state == AppLifecycleState.inactive) {
      controller?.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() {
        _permissionDenied = true;
        _isInitializing = false;
      });
      return;
    }

    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        setState(() => _isInitializing = false);
        return;
      }

      await _startCamera(_selectedCameraIndex);
    } catch (e) {
      debugPrint('[Camera] Init failed: $e');
      setState(() => _isInitializing = false);
    }
  }

  Future<void> _startCamera(int cameraIndex) async {
    if (_cameras == null || _cameras!.isEmpty) return;

    final oldController = _controller;
    _controller = null;
    oldController?.dispose();

    final camera = _cameras![cameraIndex];
    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
    );

    _controller = controller;

    try {
      await controller.initialize();
      if (mounted) {
        setState(() {
          _selectedCameraIndex = cameraIndex;
          _isInitializing = false;
        });
      }
    } catch (e) {
      debugPrint('[Camera] Start camera failed: $e');
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  void _switchCamera() {
    if (_cameras == null || _cameras!.length < 2) return;
    final nextIndex = (_selectedCameraIndex + 1) % _cameras!.length;
    _startCamera(nextIndex);
  }

  Future<void> _capturePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      final xFile = await _controller!.takePicture();
      await _processImage(xFile.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(S.get('capture_failed'))));
        setState(() => _isProcessing = false);
      }
    }
  }

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
    try {
      await ref
          .read(diagnosisProvider.notifier)
          .diagnose(imagePath, widget.leafType)
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(S.get('error_timeout'))));
        setState(() => _isProcessing = false);
      }
      return;
    }

    final diagState = ref.read(diagnosisProvider);
    if (diagState.status == DiagnosisStatus.error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(diagState.errorMessage ?? S.get('error_generic')),
          ),
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
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isProcessing) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            Text(
              S.get('checking'),
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      );
    }

    if (_isInitializing) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (_permissionDenied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.camera_alt_outlined,
                size: 64,
                color: Colors.white54,
              ),
              const SizedBox(height: 16),
              Text(
                S.get('camera_needed'),
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => openAppSettings(),
                child: Text(S.get('open_settings')),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _pickFromGallery,
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                child: Text(S.get('pick_gallery')),
              ),
            ],
          ),
        ),
      );
    }

    if (_controller == null || !_controller!.value.isInitialized) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.camera_alt_outlined,
              size: 64,
              color: Colors.white54,
            ),
            const SizedBox(height: 16),
            Text(
              S.get('camera_unavailable'),
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _pickFromGallery,
              icon: const Icon(Icons.photo_library),
              label: Text(S.get('pick_gallery')),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.center,
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller!.value.previewSize!.height,
                  height: _controller!.value.previewSize!.width,
                  child: CameraPreview(_controller!),
                ),
              ),
            ),
          ),
        ),
        _buildControls(),
      ],
    );
  }

  Widget _buildControls() {
    final hasMultipleCameras = _cameras != null && _cameras!.length > 1;

    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 32),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Gallery button
            IconButton(
              onPressed: _pickFromGallery,
              icon: const Icon(Icons.photo_library, color: Colors.white),
              iconSize: 32,
            ),
            // Capture button
            GestureDetector(
              onTap: _capturePhoto,
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 4),
                ),
                child: Container(
                  margin: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            // Switch camera button
            IconButton(
              onPressed: hasMultipleCameras ? _switchCamera : null,
              icon: Icon(
                Icons.cameraswitch,
                color: hasMultipleCameras ? Colors.white : Colors.white24,
              ),
              iconSize: 32,
            ),
          ],
        ),
      ),
    );
  }
}
