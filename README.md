# AssetAtlas

AssetAtlas is a desktop-first asset catalog and preview tool focused on local game/content pipelines.

This repository is now focused on the Flutter Windows desktop app.

New users should start with the [User Manual](USER_MANUAL.md).

## Repository Layout

- `work/asset_atlas_native/` - Primary active app (Flutter desktop, Windows-focused)
- `outputs/` - Build/export artifacts

## Recommended Starting Point

For current development and packaging:

1. Open `work/asset_atlas_native/`
2. Read `work/asset_atlas_native/README.md`
3. Use the scripts under `work/asset_atlas_native/scripts/`

## Key Features (Active Desktop Track)

- Recursive local folder scan and catalog
- Mixed asset support: images, audio, 3D models
- Search, filtering, ignore workflow, and copy workflow
- Model preview modes: textured, solid, wireframe
- FBX import with texture path relinking and diagnostics
- Windows packaging and installer scripts

## Technical Specs

See the `docs/` folder for implementation-level technical specs:

- [Architecture](docs/TECH_SPEC_ARCHITECTURE.md) - app structure, data flow, and module boundaries.
- [Rendering and FBX](docs/TECH_SPEC_RENDERING_FBX.md) - importer pipeline, texture resolution, and renderer behavior.
- [Build and Release](docs/TECH_SPEC_BUILD_RELEASE.md) - versioning, packaging scripts, and installer workflow.
