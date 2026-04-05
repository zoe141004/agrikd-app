# AgriKD -- Plant Leaf Disease Recognition

## About

AgriKD is an AI-powered mobile application that identifies plant leaf diseases from a
single photograph. It uses Knowledge Distillation to compress a large Vision Transformer
model into a lightweight MobileNetV2 network that runs entirely on-device, with no
internet connection required for inference.

**Core capabilities:**

- Real-time disease classification from camera capture or gallery image
- Fully offline inference -- no cloud dependency for predictions
- Dual-language interface (English and Vietnamese)
- Cloud synchronization for prediction history when online
- Over-the-air (OTA) model updates with integrity verification
- Dark mode support
- Automatic crash reporting for faster issue resolution

---

## Supported Crops

### Tomato (10 classes)

Bacterial Spot, Early Blight, Late Blight, Leaf Mold, Septoria Leaf Spot,
Spider Mites, Target Spot, Yellow Leaf Curl Virus, Mosaic Virus, and Healthy.

### Burmese Grape Leaf (5 classes)

Anthracnose (Brown Spot), Healthy, Insect Damage, Leaf Spot (Yellow), and
Powdery Mildew.

---

## Key Features

| Feature | Description |
|---|---|
| Camera Capture | Take a photo directly from the app for instant analysis |
| Gallery Picker | Select an existing image from device storage |
| Probability Chart | Visual bar chart showing prediction probabilities for all classes |
| Diagnosis History | Browse, search, and review all past predictions |
| Statistics Dashboard | Aggregated charts of disease frequency and trends |
| Cloud Sync | Automatic background synchronization to Supabase when online |
| OTA Model Updates | Receive updated models without reinstalling the app |
| Dark Mode | System-aware or manual dark/light theme toggle |
| Dual Language | Switch between English and Vietnamese at any time |

---

## Download

Download the latest APK from the
[GitHub Releases](../../releases) page.

Select the appropriate build for your device:

| Build Variant | Size | Architectures |
|---|---|---|
| Fat APK (universal) | ~85 MB | armeabi-v7a, arm64-v8a, x86_64 |
| arm64-v8a (recommended) | ~31 MB | 64-bit ARM devices |

---

## System Requirements

- **Operating system:** Android 7.0 (Nougat, API 24) or higher
- **Storage:** approximately 85 MB (fat APK) or 31 MB (arm64-v8a)
- **Permissions:** Camera (for live capture), Storage (for gallery picker)
- **Network:** Not required for inference; required only for cloud sync and OTA updates

---

## Installation

1. Download the APK file from GitHub Releases onto your Android device.
2. If prompted, enable **Install from Unknown Sources** in your device settings
   (Settings > Security > Unknown Sources, or Settings > Apps > Special Access >
   Install Unknown Apps).
3. Open the downloaded APK and tap **Install**.
4. Once installation completes, tap **Open** to launch AgriKD.
5. Grant the Camera permission when prompted on first launch.

---

## Quick Start

1. **Launch the app** -- you will be greeted by the Home screen.
2. **Select a leaf type** -- tap the leaf selector at the top to choose between
   Tomato and Burmese Grape Leaf.
3. **Capture or select an image:**
   - Tap the **Camera** button to take a live photo of a leaf.
   - Tap the **Gallery** button to pick an existing image from your device.
4. **View results** -- the Result screen displays the top predicted disease (or
   Healthy) along with a probability bar chart for all classes.
5. **Review history** -- navigate to the History tab to browse previous diagnoses,
   view details, or check aggregated statistics.

For best accuracy, photograph a single leaf against a plain background under natural
lighting. Avoid blurry images and extreme angles.

---

## Settings

Access Settings from the bottom navigation bar or the gear icon.

| Setting | Options |
|---|---|
| Theme | Light / Dark / System default |
| Language | English / Vietnamese |
| Default Leaf Type | Tomato / Burmese Grape Leaf |
| Cloud Sync | Enable or disable automatic synchronization |
| Account | Sign in with Email or Google; manage profile |

---

## OTA Model Updates

AgriKD periodically checks for updated models when the device is online.

- The app queries the Supabase model registry for newer versions.
- If an update is available, the new TFLite file is downloaded in the background.
- The downloaded file is verified against its SHA-256 checksum before activation.
- If verification fails, the app retains the previously active model.
- No user action is required -- updates are applied automatically on the next
  inference after download completes.

---

## Troubleshooting

**Q: The app crashes or shows a black screen on launch.**
A: Ensure your device runs Android 7.0 or higher. Try clearing the app cache
(Settings > Apps > AgriKD > Clear Cache) and relaunching.

**Q: The camera does not open.**
A: Verify that Camera permission is granted (Settings > Apps > AgriKD > Permissions).
Restart the app after granting the permission.

**Q: Predictions seem inaccurate.**
A: Use a clear, well-lit photograph of a single leaf. Avoid images with multiple
overlapping leaves, heavy shadows, or motion blur. The model achieves approximately
87% Top-1 accuracy under controlled conditions.

**Q: I selected the wrong leaf type.**
A: Return to the Home screen and switch the leaf type selector before capturing a
new image. Previous predictions remain in the history under the leaf type they were
recorded with.

**Q: Cloud sync is not working.**
A: Confirm that you are signed in and that the device has an active internet
connection. Check that Cloud Sync is enabled in Settings. Pending records will be
synchronized automatically once connectivity is restored.

**Q: How do I update the app?**
A: Download the latest APK from GitHub Releases and install it over the existing
version. Your local data and prediction history will be preserved.

**Q: The app says "Model not found."**
A: This may occur if bundled model assets were corrupted during installation.
Uninstall and reinstall the app. If the issue persists, download a fresh APK from
GitHub Releases.

---

*AgriKD is developed as a capstone project demonstrating Knowledge Distillation for
efficient on-device plant disease recognition.*
