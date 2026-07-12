# Asset Atlas

Asset Atlas is a local-first content management prototype for indie game asset folders.

## MVP

- Scan one or more local folders.
- Catalog images, audio, and common 3D model files.
- Preview PNG/JPG/WebP/GIF/BMP images.
- Listen to WAV/MP3/FLAC/OGG/MIDI where the browser supports playback.
- Render a simple wireframe preview for OBJ files.
- Browse assets as a flat list, by type, by source folder, or by tag.
- Filter by name, folder, extension, or tag.
- Select assets, mark them ignored, and hide ignored assets.
- Add manual tags to assets.
- Copy selected non-ignored assets to a chosen target folder in browsers that support the File System Access API.
- Save named project selections locally.

## Run

```sh
npm start
```

Then open `http://127.0.0.1:8765`.

You can click `Load demo catalog` to prove the main workflow without selecting real folders.

For direct folder scanning and copying, the browser must support `showDirectoryPicker`. If it does not, use the `Import folders` button to catalog folders through a file input.

## Next Build Step

Wrap the app in Electron or Tauri for a native Windows/Mac desktop release. That layer should add persistent folder permissions, richer 3D preview support for GLTF/GLB/FBX/STL, background indexing, duplicate detection, and project-specific ignore/sync manifests.
