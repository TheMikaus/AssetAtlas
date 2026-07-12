# Asset Atlas Desktop

Electron desktop track for Asset Atlas.

## Track Role

This is currently the preferred short-term ship track for desktop UX while Flutter native is used as a parallel validation track for scanning/rendering behavior.

## Run

```sh
npm install
npm start
```

The working copy at `work/asset-atlas-desktop` already has dependencies installed.

## What This Version Adds

- Native folder picker with multi-folder scanning.
- Recursive nested-folder scanning through Node.
- Native copy flow using absolute file paths.
- Project root folder selection through a native folder picker.
- Absolute source paths retained for desktop assets.
- Binary OBJ files skipped during cataloging.
- Three.js model viewer path for FBX, GLB, and GLTF in desktop mode.
- Browser prototype wireframe renderer remains as fallback.

## Current Caveats

- The app shell is scaffolded and code checks pass, but GUI launch was not verified inside this sandboxed Codex session.
- Some FBX files with external textures or unusual embedded/compressed data may still need more loader-path handling.
- Persistent asset indexing should move from browser local storage to a desktop database in the next pass.

## Cross-Track Note

Fixture-based scan regression tests currently exist on the Flutter native track and should be mirrored here as part of shared contract enforcement.
