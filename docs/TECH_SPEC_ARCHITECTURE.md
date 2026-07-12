# Technical Spec: Architecture

## Scope

This spec describes the active desktop implementation in `work/asset_atlas_native`.

## High-Level Design

The app is a Flutter desktop client with three primary responsibilities:

1. Asset indexing and persistence
2. Asset preview and interaction
3. FBX ingestion and material/texture diagnostics

## Main Components

- `lib/main.dart`
  - Primary UI composition and state management
  - Asset scanning, filtering, selection, and preview orchestration
  - Database interactions and project snapshot flow

- SQLite persistence (`sqflite_common_ffi`)
  - Stores catalog assets and source roots
  - Stores project snapshot metadata

- Native FBX helper (`asset_atlas_mesh_importer.exe`)
  - Built from `windows/runner/mesh_importer.cpp`
  - Uses `ufbx` to parse geometry/material/texture references
  - Outputs JSON consumed by Flutter

## Runtime Flow

1. User scans source folders
2. Files are classified into image/audio/model types
3. Catalog entries are stored and restored from SQLite
4. Selecting a model triggers parser/preview path:
   - FBX: native helper -> JSON -> mesh model
   - Non-FBX model fallback path remains lightweight
5. Renderer displays model by selected mode

## Data Model Notes

- `AssetItem` represents indexed file metadata
- `MeshModel` represents normalized mesh + materials + optional vertex color data
- `MeshMaterial` includes visual channels used by renderer

## Non-Goals (Current)

- Full physically based renderer parity with DCC/game engines
- Full shader graph execution
- Real-time scene-lighting parity with source engine

## Current Constraints

- Most logic remains in `main.dart` (monolithic state surface)
- Rendering is software-style custom painter based
- Large scans can still pressure UI responsiveness

## Planned Evolution

- Move indexing and parsing to background isolates
- Further separate data, services, and UI layers
- Expand renderer controls and material diagnostics UI
