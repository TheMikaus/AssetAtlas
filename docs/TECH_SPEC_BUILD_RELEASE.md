# Technical Spec: Build, Packaging, and Release

## Scope

Defines the current Windows build and packaging workflow for `work/asset_atlas_native`.

## Build Prerequisites

- Flutter SDK configured for Windows desktop
- Visual Studio C++ build tools for Flutter Windows builds
- Inno Setup 6 for installer generation (`ISCC.exe`)

## Primary Commands

From `work/asset_atlas_native`:

- Run app (debug):
  - `flutter run -d windows`
- Analyze:
  - `flutter analyze`
- Build release:
  - `flutter build windows --release`

## Packaging Scripts

- `scripts/package_windows.ps1`
  - Builds app
  - Stages distributable folder under `dist/`
  - Optional zip output

- `scripts/create_windows_installer.ps1`
  - Builds app
  - Stages folder under `dist/`
  - Generates and compiles Inno Setup installer
  - Installer output under `dist/installers/`
  - Installer filename includes version + configuration + timestamp

- `scripts/bump_version.ps1`
  - Bumps `pubspec.yaml` semantic version + build number
  - Supports patch/minor/major modes

## Versioning Policy (Current)

- Version source: `pubspec.yaml`
- Format: `major.minor.patch+build`
- Rule in this repo: bump version when code changes are made

## Recommended Release Sequence

1. Run analyzer/tests
2. Bump version (`scripts/bump_version.ps1`)
3. Build installer (`scripts/create_windows_installer.ps1`)
4. Validate installer on clean machine if possible
5. Tag release in Git/GitHub

## Artifacts

- App staging directory:
  - `work/asset_atlas_native/dist/asset_atlas_native-windows-x64-<config>-<timestamp>`
- Installer:
  - `work/asset_atlas_native/dist/installers/asset_atlas_native-setup-<version>-<config>-<timestamp>.exe`

## Constraints and Notes

- Large generated/vendor files should stay ignored and out of git history
- Build outputs can be sizable; retain only necessary artifacts per release
- Keep installer metadata aligned with product naming decisions
