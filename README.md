# Text Extractor

A cross-platform Tauri desktop utility that extracts text from any region of your screen — including text inside images, videos, and other non-copyable interfaces — using local Tesseract OCR.

Press the global hotkey, drag a rectangle, and the recognised text lands on your clipboard.

## How it works

1. App runs in the system tray (no main window).
2. Global hotkey `Ctrl+Shift+T` (Windows/Linux) / `Cmd+Shift+T` (macOS) triggers a screen capture.
3. A transparent fullscreen overlay opens for selection.
4. The selected region is cropped, preprocessed (upscaled + grayscaled), and run through Tesseract.
5. Result is written to the clipboard with a notification toast.

## Prerequisites

### All platforms

- [Rust](https://rustup.rs/) (1.77+)
- [Node.js](https://nodejs.org/) (18+)
- Platform-specific Tauri prerequisites: see https://v2.tauri.app/start/prerequisites/

### Tesseract (system dependency)

The Rust `tesseract` crate links to libtesseract.

| Platform | Install |
| --- | --- |
| **macOS** | `brew install tesseract leptonica` |
| **Debian/Ubuntu** | `sudo apt install libtesseract-dev libleptonica-dev clang` |
| **Fedora** | `sudo dnf install tesseract-devel leptonica-devel clang` |
| **Arch** | `sudo pacman -S tesseract leptonica clang` |
| **Windows** | Install [UB Mannheim Tesseract](https://github.com/UB-Mannheim/tesseract/wiki) and add it to PATH. You may also need to set `TESSDATA_PREFIX` to the `tessdata` directory. |

For shipping to end users, vendor the Tesseract binaries with your installer rather than asking users to install them.

## Setup

```bash
npm install
```

You'll also need icons in `src-tauri/icons/` before the first build. Generate them from any 1024×1024 PNG with:

```bash
npm run tauri icon path/to/source.png
```

## Run in dev mode

```bash
npm run tauri dev
```

The app launches and lives in the system tray. Press `Ctrl+Shift+T` to trigger.

## Build for distribution

```bash
npm run tauri build
```

Bundles will appear in `src-tauri/target/release/bundle/`.

## Platform notes

### macOS
- First launch requires **Screen Recording** permission (System Settings → Privacy & Security → Screen Recording). Without it `xcap` returns a black image.
- For distribution: code-sign and notarize the app, otherwise Gatekeeper will block it.

### Linux
- **X11**: works out of the box.
- **Wayland**: `xcap` uses the `xdg-desktop-portal` protocol, which prompts the user to grant screen access *every capture session*. There's no way around this — it's a Wayland design decision. For a smoother experience, recommend X11 to users.

### Windows
- Smoothest of the three. Make sure your installer bundles `tesseract.dll`, `leptonica.dll`, and the `tessdata` folder (the English language data is ~15 MB).

## Project layout

```
text-extractor/
├── src/                       # React overlay UI
│   ├── App.tsx                # Selection rectangle, masks, hint UI
│   ├── main.tsx               # React entry
│   └── styles.css             # Overlay styles
├── src-tauri/
│   ├── src/
│   │   ├── main.rs            # Desktop entry point
│   │   ├── lib.rs             # Tauri setup, tray, hotkey, commands
│   │   ├── capture.rs         # xcap-based screen capture
│   │   └── ocr.rs             # Tesseract wrapper + preprocessing
│   ├── capabilities/
│   │   └── default.json       # Tauri 2 permissions
│   ├── Cargo.toml
│   └── tauri.conf.json
├── index.html
├── package.json
├── tsconfig.json
└── vite.config.ts
```

## Architecture notes

- **Capture is taken before the overlay shows** so the user selects against a frozen, pre-captured image. Trying to capture *after* the user selects produces flicker and includes the overlay itself in the screenshot.
- **OCR runs on a blocking task** (`tokio::task::spawn_blocking`) so it doesn't stall the Tauri event loop.
- **The overlay window is hidden, not closed**, between captures. Recreating windows is slow on macOS and would add noticeable latency to the hotkey-to-overlay path.
- **Scale factors are computed in the renderer** (`physicalWidth / window.innerWidth`) to handle HiDPI/Retina displays correctly. On mixed-DPI multi-monitor setups this can drift — the v2 fix is to capture the cursor's monitor specifically.

## Roadmap

- Multi-monitor support (capture the monitor under the cursor)
- Language picker (Tesseract supports 100+ languages)
- Selection refinement before commit (drag handles to adjust the rectangle)
- Optional cloud OCR (Google Vision) for higher accuracy
- Capture history (last N extractions, accessible from tray)
- Settings window (custom hotkey, OCR language, preprocessing toggles)
