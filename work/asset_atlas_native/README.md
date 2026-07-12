# Asset Atlas Native

Flutter desktop track for Asset Atlas.

## Current Status

This is no longer a template app. It is an active native prototype that can:

- Scan local folders recursively using native filesystem access.
- Catalog image, audio, and model assets.
- Skip known non-content folders such as `.git`, `.vs`, `Intermediate`, and `Saved`.
- Search assets by name, relative path, and generated tags.
- Filter by type and hide ignored assets.
- Select assets and copy selected files to a chosen target folder.
- Restore catalog and source roots from a local SQLite database on startup.
- Save and load project snapshots (selected asset membership) backed by SQLite.
- Preview images.
- Preview audio files with play/pause and seek.
- Preview 3D models with a software renderer (textured, solid, wireframe modes).
- Render FBX textures in textured mode using imported UV coordinates.
- Show model texture discovery diagnostics for FBX content.

Main implementation is in [lib/main.dart](lib/main.dart).

## Run

```sh
flutter pub get
flutter run -d windows
```

If your Flutter SDK has different desktop targets enabled, you can also use:

```sh
flutter run -d macos
flutter run -d linux
```

## Validation

```sh
flutter test
flutter analyze
```

## Package Windows Executable

Use the packaging script to build and stage a distributable Windows folder, and
optionally a zip archive.

```powershell
pwsh -File .\scripts\package_windows.ps1
```

Useful options:

```powershell
# Build Debug package instead of Release
pwsh -File .\scripts\package_windows.ps1 -Configuration Debug

# Skip zip creation
pwsh -File .\scripts\package_windows.ps1 -NoZip

# Skip flutter pub get (faster when dependencies are unchanged)
pwsh -File .\scripts\package_windows.ps1 -SkipPubGet
```

Outputs are written under `dist/` with timestamped folder names.

## Create Windows Installer

To build the app and create an installer (Inno Setup):

```powershell
pwsh -File .\scripts\create_windows_installer.ps1
```

Notes:

- Requires Inno Setup 6 (`ISCC.exe`) installed.
- Installer output is written to `dist/installers/`.
- A staged app folder is also generated under `dist/`.
- Installer filename includes version, configuration, and timestamp.

Useful options:

```powershell
# Build debug installer
pwsh -File .\scripts\create_windows_installer.ps1 -Configuration Debug

# Skip flutter pub get for faster iteration
pwsh -File .\scripts\create_windows_installer.ps1 -SkipPubGet
```

## Version Bumping

Use the version script whenever code changes are made:

```powershell
pwsh -File .\scripts\bump_version.ps1
```

Options:

```powershell
# Bump minor or major instead of patch
pwsh -File .\scripts\bump_version.ps1 -Part minor
pwsh -File .\scripts\bump_version.ps1 -Part major

# Preview without changing files
pwsh -File .\scripts\bump_version.ps1 -DryRun
```

Scan regression is covered by fixture-based tests in [test/scan_fixture_test.dart](test/scan_fixture_test.dart) using [test/fixtures/corpus](test/fixtures/corpus).

Copy flow regression is covered in [test/copy_fixture_test.dart](test/copy_fixture_test.dart).

FBX textured pipeline regression is covered in [test/fbx_texture_pipeline_test.dart](test/fbx_texture_pipeline_test.dart).

## Supported File Types (Current)

- Images: `png`, `jpg`, `jpeg`, `webp`, `gif`, `bmp`
- Audio: `wav`, `mp3`, `flac`, `ogg`, `midi`, `mid`
- Models: `obj`, `fbx`, `gltf`, `glb`, `blend`, `dae`, `stl`

Note: Model rendering currently focuses on mesh visualization and diagnostics, not full runtime-accurate material/shader parity.

## Known Gaps

- Project management is minimal (no rename/delete/history UI yet).
- Textured preview uses triangle-affine UV mapping, so perspective-heavy assets may still show minor distortion at extreme camera angles.
- Large-folder indexing can block UI responsiveness during heavy scans.

## Immediate Next Priorities

1. Add project rename/delete/history UI and guards around duplicate names.
2. Move folder scanning and mesh parsing into background isolates for responsiveness.
3. Expand regression tests to include project save/load flows.
