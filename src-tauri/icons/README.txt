Icon files go here.

Generate them automatically from a 1024×1024 source PNG by running, from the
project root:

    npm run tauri icon path/to/your-source.png

That command produces the full icon set Tauri needs:
  - 32x32.png
  - 128x128.png
  - 128x128@2x.png
  - icon.png         (used for the system tray)
  - icon.icns        (macOS)
  - icon.ico         (Windows)
  - Square*Logo.png  (Microsoft Store)

Until you do this the build will fail with a missing-icon error.
