# SyncBridge

SyncBridge is a unified, locally networked cross-device file sharing (AirDrop-style) and real-time clipboard synchronization suite designed for macOS (Dynamic Notch interface) and Android. 

It is 100% compatible with the **KDE Connect** protocol, allowing seamless interoperability with standard KDE Connect clients across Linux, Android, and macOS.

---

## 🚀 Downloads & Releases

Get the latest production-ready versions of SyncBridge for both macOS and Android:

- **macOS App (`SyncBridge.dmg`):** [Download Latest macOS Release](https://github.com/Anas15102/SyncBridge/releases/latest/download/SyncBridge.dmg)
- **Android App (`SyncBridge.apk`):** [Download Latest Android APK](https://github.com/Anas15102/SyncBridge/releases/latest/download/SyncBridge.apk)

---

## Project Structure

- **`SyncBridge.app/`** — The packaged, production-ready macOS Dynamic Notch application (featuring the obsidian/liquid glass UI, drag-and-drop file beaming, live clipboard sync, and custom branding).
- **`macos-notch-app/`** — Complete source code for the macOS Notch client.
- **`android-app/`** — Complete Android Kotlin / Jetpack Compose application source code featuring:
  - Foreground Service for persistent background Wi-Fi discovery & TCP connections.
  - Accessibility Service & Action Sheet Share Receiver for background clipboard reading and writing without ADB.
  - Scoped Storage MediaStore integration so files land directly in your Android Downloads folder and show up in your Gallery/Music apps.
- **`reference-repos/`** — Upstream KDE Connect and Soduto reference implementations.

---

## Features

1. **Dynamic Notch Island (macOS):**
   - Sits at the top of your MacBook screen.
   - Expandable on mouse hover or click.
   - **Drag & Drop Beam:** Drag any file (.jpg, .png, .mp4, .mp3, .pdf, .zip, .dmg, etc.) onto the Notch to instantly beam it over Wi-Fi to your phone.
   - **Live Clipboard History:** Real-time synchronized clipboard tracker with one-click copy.

2. **Android App & Share Target:**
   - **System Share Sheet Integration:** Select "Send to Mac" from any Android app's share menu to instantly beam files and text over Wi-Fi.
   - **Foreground Service:** Keeps active connections alive in the background.

---

## Building & Running

### macOS App
1. Open `macos-notch-app/SyncBridge.xcodeproj` in Xcode, or run the pre-built `SyncBridge.app` in the root directory.
2. Grant local network access when prompted by macOS.

### Android App
1. Open `android-app/` in Android Studio.
2. Build and run onto your Android device (`./gradlew installDebug`).
3. Ensure both devices are on the same Wi-Fi network for automatic UDP broadcast discovery on port `1716`.
