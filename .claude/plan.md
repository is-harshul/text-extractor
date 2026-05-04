# Build Plan: `screen-text-selector`

A cross-platform Tauri desktop utility that extracts text from any region of the screen using local Tesseract OCR. Hand this plan to Claude Code as-is. It's organized so each phase produces a runnable checkpoint.

---

## Project Overview

Build a tray-resident desktop utility that extracts text from any region of the screen using local Tesseract OCR. User presses a global hotkey, drags a rectangle on a transparent overlay, and the recognized text lands on the clipboard.

**Stack:** Tauri 2.x · Rust backend · React + TypeScript frontend · Vite · Local Tesseract OCR

**Targets:** Windows, macOS, Linux (X11 + Wayland)

---

## Prerequisites (verify before starting)

- Rust 1.77+ (`rustup`)
- Node.js 18+
- Platform Tauri prerequisites: https://v2.tauri.app/start/prerequisites/
- **Tesseract system library:**
  - macOS: `brew install tesseract leptonica`
  - Debian/Ubuntu: `sudo apt install libtesseract-dev libleptonica-dev clang`
  - Fedora: `sudo dnf install tesseract-devel leptonica-devel clang`
  - Windows: UB Mannheim Tesseract installer; add to PATH; set `TESSDATA_PREFIX`

---

## Architecture

- **No main window.** App lives in the system tray.
- **One overlay window**, transparent + fullscreen + alwaysOnTop + skipTaskbar, hidden on startup, shown on hotkey.
- **Capture-then-overlay flow:** Rust captures the screen *before* showing the overlay, so the user selects against a frozen image. Prevents flicker and keeps the overlay itself out of the screenshot.
- **OCR on blocking thread** via `tokio::task::spawn_blocking` — Tesseract is CPU-bound and would otherwise stall the event loop.
- **HiDPI handling:** frontend computes `scaleX = physicalWidth / window.innerWidth` and passes physical pixel coords back to Rust for cropping.

---

## Phase 1 — Project Bootstrap

1. Scaffold: `npm create tauri-app@latest screen-text-selector` → React + TypeScript + npm
2. Install frontend plugin packages:
   ```
   npm install @tauri-apps/plugin-global-shortcut @tauri-apps/plugin-clipboard-manager @tauri-apps/plugin-notification
   ```
3. In `src-tauri/`, add Rust dependencies:
   ```
   cargo add tauri-plugin-global-shortcut tauri-plugin-clipboard-manager tauri-plugin-notification
   cargo add xcap tesseract image serde serde_json log
   cargo add tokio --features rt-multi-thread,macros
   ```
4. Pin versions in `Cargo.toml`: `tauri = "2"`, `xcap = "0.0.14"`, `tesseract = "0.15"`, `image = "0.25"`.
5. Generate icons: `npm run tauri icon path/to/source.png` (any 1024×1024 PNG).

**Checkpoint:** `npm run tauri dev` launches the default scaffolded app.

---

## Phase 2 — Tauri Configuration

### `src-tauri/tauri.conf.json`
- `productName: "Screen Text Selector"`
- Identifier: `com.screentextselector.app`
- Single window labeled `"overlay"` with: `fullscreen: true`, `transparent: true`, `decorations: false`, `alwaysOnTop: true`, `skipTaskbar: true`, `resizable: false`, `visible: false`, `shadow: false`, `focus: true`
- `app.trayIcon`: point at `icons/icon.png`, `iconAsTemplate: true`
- `bundle.category: "Utility"`

### `src-tauri/capabilities/default.json`
Permissions needed:
- `core:default`, `core:window:allow-show`, `core:window:allow-hide`, `core:window:allow-set-focus`, `core:window:allow-close`
- `core:event:allow-listen`, `core:event:allow-unlisten`
- `global-shortcut:allow-register`, `global-shortcut:allow-unregister`, `global-shortcut:allow-is-registered`
- `clipboard-manager:allow-write-text`, `clipboard-manager:allow-read-text`
- `notification:default`, `notification:allow-notify`

Scope: `"windows": ["overlay"]`

**Checkpoint:** Overlay window is defined but starts hidden. App launches with no visible window.

---

## Phase 3 — Rust Backend

Split into three modules under `src-tauri/src/`:

### `capture.rs`
- `struct Capture { image: DynamicImage, width: u32, height: u32 }`
- `fn capture_primary_monitor() -> Result<Capture, String>` using `xcap::Monitor::all()`, find primary (fallback to first), call `capture_image()`, wrap in `DynamicImage::ImageRgba8`.
- `fn crop(capture: &Capture, x, y, w, h) -> DynamicImage` — clamp to image bounds defensively before calling `crop_imm`.

### `ocr.rs`
- `fn extract_text(image: &DynamicImage) -> Result<String, String>`
- **Preprocessing pipeline (don't skip — accuracy is night and day):**
  1. Adaptive upscale: if `min(w,h) < 200` → 3×; if `< 400` → 2×; else 1×. Use `FilterType::Lanczos3`.
  2. Convert to grayscale via `to_luma8()`.
- Encode to PNG bytes, pass to `Tesseract::new(None, Some("eng"))?.set_image_from_mem(&bytes)?.get_text()`.
- Trim whitespace, strip stray `\u{000C}` form-feeds.

### `lib.rs` (main module)
- `struct AppState { capture: Mutex<Option<Capture>> }` registered via `.manage()`.
- **Two `#[tauri::command]`s:**
  - `get_capture_dimensions(state) -> Result<(u32, u32), String>` — returns physical pixel dimensions for the frontend's scale calculation.
  - `process_selection(app, x, y, w, h) -> Result<String, String>`:
    1. Crop the active capture (extract via state lock, drop the lock before async work)
    2. Hide overlay window *before* OCR completes (so the toast appears against the real desktop)
    3. `tokio::task::spawn_blocking` for `ocr::extract_text`
    4. If empty → notification "No text detected"; else → write to clipboard + notification with first 80 chars preview (append "…" if truncated)
- **`fn trigger_capture(app: &AppHandle)`:** spawn async, run capture on blocking thread, store in state, show overlay, `set_focus()`, emit `"capture-ready"` event.
- **Setup block:**
  - Register global shortcut: `Modifiers::CONTROL | Modifiers::SHIFT` + `Code::KeyT` (Tauri normalizes CONTROL → Cmd on macOS automatically).
  - Build tray icon with menu: "Capture text (Ctrl+Shift+T)" + separator + "Quit". Left-click on tray also triggers capture.
  - Register both menu events and `TrayIconEvent::Click` handler.
  - Hide overlay window on startup as a safety net.
- **Run loop:** ignore `RunEvent::ExitRequested` from window-close so closing the overlay doesn't quit the app — only the tray "Quit" item should exit.

### `main.rs`
- Add `#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]` to suppress Windows console window in release.
- Single line: `screen_text_selector_lib::run();`
- Set `[lib] name = "screen_text_selector_lib"` in `Cargo.toml`.

**Checkpoint:** Pressing the hotkey triggers a capture and shows the (still empty) overlay window; tray menu works.

---

## Phase 4 — React Overlay UI

### `src/App.tsx`
**State machine:** `"idle" | "ready" | "selecting" | "processing"`

**Refs/state needed:**
- `rect: { x, y, w, h } | null`
- `scaleX, scaleY: number`
- `startRef` for mousedown anchor

**Lifecycle:**
- On mount: `listen("capture-ready", ...)` → call `invoke<[number, number]>("get_capture_dimensions")`, compute `scaleX = physW / window.innerWidth`, `scaleY = physH / window.innerHeight`, set status to `"ready"`. Cleanup the listener on unmount.
- Esc key listener → call `closeOverlay()` (resets state, calls `getCurrentWindow().hide()`).

**Mouse handlers:**
- `onMouseDown` (ignore if processing): record start point, set rect, status → selecting
- `onMouseMove`: only when selecting; update rect using `Math.min`/`Math.abs` so dragging in any direction works
- `onMouseUp`: if rect < 5×5 → treat as accidental click, close overlay; else status → processing, `invoke("process_selection", { x: round(rect.x*scaleX), ... })`. Reset state in `finally`.

**Render structure:**
- Wrapper `.overlay` with `data-status` attribute (drives CSS via attribute selector)
- When `ready`: render `<Crosshair />` component (tracks mouse position, renders two thin lines)
- When `selecting` or `processing`: render four `.mask` divs forming a frame around the selection (top, left, right, bottom of the rect) — this "punches out" the dim, leaving the selection bright. Plus the `.selection` div with a dimension badge `"{w} × {h}"`.
- Always render `.hint` pill at the bottom: shows "Drag to capture · Esc to cancel" or spinner + "Reading text…" when processing.

### `src/styles.css`
- CSS variables for accent color (cyan-ish: `#6ee7ff`), mask color (`rgba(8,12,20,0.45)`), hint background (dark glass).
- `html, body, #root` → 100vw/100vh, transparent background, `overflow: hidden`.
- `.overlay` uses `cursor: crosshair`, `user-select: none`.
- Use `.overlay[data-status="ready"]::before` for the global dim — the four mask divs replace it during selection.
- `.selection`: 1.5px solid accent border, soft glow shadow, brief 120ms scale-in animation.
- `.hint`: pill-shaped, `backdrop-filter: blur(12px)`, fixed at bottom center.
- `.spinner`: 12px conic-rotation animation.
- `kbd` styling for the Esc indicator.

### `src/main.tsx`
Standard React entry; mount `<App />` in StrictMode.

### `index.html`
Vanilla — just a `#root` div and the module script tag.

**Checkpoint:** Hotkey → overlay appears with crosshair → drag a rect → text appears in clipboard with notification.

---

## Phase 5 — Build Tooling

### `vite.config.ts`
- `@vitejs/plugin-react`
- `clearScreen: false`, `server.port: 5173`, `server.strictPort: true`
- `envPrefix: ["VITE_", "TAURI_ENV_*"]`

### `tsconfig.json`
Standard Vite + React TS config; `"strict": true`, `"jsx": "react-jsx"`, `"noUnusedLocals": true`.

### `package.json` scripts
```json
{
  "dev": "vite",
  "build": "tsc && vite build",
  "tauri": "tauri"
}
```

**Checkpoint:** `npm run tauri build` produces installers in `src-tauri/target/release/bundle/`.

---

## Phase 6 — Cross-Platform Validation

For each platform, walk through this checklist:

### macOS
- [ ] First launch: app silently captures black; permission dialog appears.
- [ ] Grant Screen Recording permission (System Settings → Privacy & Security).
- [ ] Restart app, verify capture works.
- [ ] Verify Cmd+Shift+T triggers (Tauri auto-normalizes Modifiers::CONTROL).
- [ ] **Unsigned builds will be Gatekeeper-blocked** — code-sign + notarize for distribution.

### Windows
- [ ] Verify hotkey, capture, OCR pipeline.
- [ ] Verify no console window appears in release build.
- [ ] Confirm Tesseract DLLs (`tesseract.dll`, `leptonica.dll`) and `tessdata/` directory are bundled with installer.
- [ ] Test on a fresh VM without Tesseract installed system-wide.

### Linux X11
- [ ] Confirm capture, hotkey, tray icon all functional.

### Linux Wayland
- [ ] **Expect a portal prompt every capture session.** This is a Wayland design constraint, not a bug.
- [ ] Document this clearly in the README — recommend X11 for best UX.

---

## Phase 7 — Documentation

Write `README.md` covering:
- What the app does (one-paragraph summary)
- Prerequisites with per-OS Tesseract install commands
- `npm install` → `npm run tauri icon` → `npm run tauri dev`
- Per-platform notes (macOS permission, Wayland prompts, Windows DLL bundling)
- Project layout tree
- Architecture decisions (why capture-then-overlay, why blocking thread for OCR, how HiDPI scaling works)
- Roadmap section

---

## Known Issues / Out of Scope for v1

- **Multi-monitor:** v1 always captures the primary monitor. v2 should detect cursor position and capture that monitor.
- **Mixed-DPI multi-monitor:** the `scaleX/scaleY` calculation can drift if monitors have different scale factors. Defer.
- **DRM-protected content** (Netflix, some PDF viewers) captures as black rectangles. Cannot be fixed.
- **Wayland portal prompt-per-session** — no clean workaround exists.
- **Tesseract bundled vs system-installed** — v1 expects system install. For shipping to end users, vendor the binaries with the installer (separate task).

---

## v2 Roadmap (after v1 ships)

1. Multi-monitor support (capture cursor's monitor)
2. Settings window: hotkey customization, OCR language picker, preprocessing toggles
3. Capture history (last N extractions, accessible from tray submenu)
4. Selection refinement (drag handles to adjust the rectangle before committing)
5. Optional cloud OCR backend (Google Vision) with offline/online toggle
6. First-run permission flow on macOS with explicit dialog and "Open Settings" button

---

## File Structure (final)

```
screen-text-selector/
├── src/
│   ├── App.tsx
│   ├── main.tsx
│   └── styles.css
├── src-tauri/
│   ├── src/
│   │   ├── main.rs
│   │   ├── lib.rs
│   │   ├── capture.rs
│   │   └── ocr.rs
│   ├── capabilities/default.json
│   ├── icons/                  # generated by `tauri icon`
│   ├── Cargo.toml
│   ├── build.rs
│   └── tauri.conf.json
├── index.html
├── package.json
├── tsconfig.json
├── vite.config.ts
├── README.md
└── .gitignore
```

---

Phases are ordered so each one ends at a runnable state — Claude Code can pause for review between phases, or bang straight through.