# AssetAtlas User Manual

AssetAtlas is a Windows desktop app for cataloging, searching, previewing, and
copying game-development and media assets stored on your computer.

This guide covers AssetAtlas v1.1.0.

## 1. Install AssetAtlas

1. Open the [latest AssetAtlas release](https://github.com/TheMikaus/AssetAtlas/releases/latest).
2. Download the Windows installer named similar to
   `asset_atlas_native-setup-X.Y.Z-release-YYYYMMDD-HHMMSS.exe`.
3. Run the installer.
4. Choose whether to create a desktop shortcut, then finish installation.
5. Launch **Asset Atlas Native** from the Start menu or desktop shortcut.

The version number appears in the application header.

## 2. Scan Your First Asset Folder

1. Select **Scan folder** in the top toolbar.
2. Choose the highest-level folder that contains the assets you want to browse.
3. Wait for the scan status in the header to finish.

AssetAtlas scans subfolders automatically. Known build and metadata folders,
including `.git`, `.vs`, `.vscode`, `Intermediate`, `Saved`, and
`DerivedDataCache`, are skipped.

Your catalog and source-folder list are stored locally and restored the next
time AssetAtlas starts.

## 3. Browse and Search

Select an asset in the lower list to open its preview and details.

Use the search box to search by:

- File name
- Relative path
- Automatically generated tags

Use the left panel to filter the catalog by image, model, or audio assets. The
model-texture filters can show all models, models with valid textures, or models
whose textures could not be located.

### ZIP archives

AssetAtlas can index supported files inside ZIP archives. These entries appear
in the catalog without extracting the complete archive.

Enable **Hide ZIP contents** in the left panel if you only want to see ordinary
files. This also prevents hidden ZIP models from entering background texture
validation.

## 4. Preview Assets

### Images

Select an image to display it in the preview area. Images stored in ZIP archives
are read directly from the archive.

### Audio

Select an audio file, then use **Play preview**, pause, seek, and the time display.
ZIP-contained audio is played from its archived bytes.

### 3D models

AssetAtlas currently renders OBJ and FBX geometry. Other recognized model types
can be cataloged, but their 3D preview is not implemented yet.

In the model preview:

- Drag to rotate the model.
- Use the mouse wheel to zoom.
- Choose **Textured**, **Solid**, or **Wireframe** rendering.
- Choose **Corner**, **Top**, or **Unlit** lighting.
- If the model contains multiple UV sets, use **UV set** to inspect them or leave
  **Material default** selected.
- Use **Fallback** to adjust the checkerboard size shown when a UV-mapped model
  has no usable texture.
- **Hide back faces** (on by default) skips triangles facing away from you, which
  makes large models noticeably smoother. Turn it off for single-sided geometry
  such as foliage cards or planes, where those triangles are meant to be seen.

Very dense models are capped for responsiveness. When that happens the label under
the model reads "face cap: showing 14000 nearest" — the model is complete, but the
viewer is drawing only the nearest triangles, so gaps you see in that state are the
cap and not the asset.

AssetAtlas supports FBX embedded textures, scene transforms, repeated mesh
instances, and named UV sets. It can also relink many stale texture references,
including common Synty authoring-path and pack-name variants.

An animation-only FBX may contain a skeleton and animation curves but no mesh to
draw. AssetAtlas identifies this condition in the preview. Animation playback is
not implemented yet.

## 5. Texture Diagnostics

The details panel shows textures referenced by an FBX model and nearby texture
candidates. A texture entry may be reported as found, relinked, embedded, or
missing.

For ZIP-contained FBX models, AssetAtlas searches for external textures within
the same ZIP. It does not intentionally borrow a similarly named texture from a
different archive.

If a model still looks incorrect:

1. Check the listed texture references in the details panel.
2. Try **Material default** and the available named UV sets.
3. Compare **Corner**, **Top**, and **Unlit** lighting.
4. Confirm that the texture files are included in the scanned folder or the same
   ZIP archive.
5. Rescan the source folder after adding or moving texture files.

## 6. Select and Copy Assets

1. Use the checkbox beside an asset to select it.
2. Select additional assets as needed.
3. Choose **Copy N** in the top toolbar.
4. Select a destination folder.

AssetAtlas copies selected ordinary files and extracts selected ZIP entries to
the destination. Archive entry paths are sanitized to prevent files from being
written outside the chosen destination.

The copy operation does not delete or move the source assets, and it never
overwrites a file that is already in the destination. Asset libraries often reuse
names, so if two selected assets are both called `Albedo.png` the second is
written as `Albedo (2).png`. The status line reports exactly what happened, for
example `12 copied · 2 renamed to avoid overwrite · 1 skipped (source missing)`.
Assets whose source file has since been deleted or moved are reported as skipped;
one file failing to copy does not stop the rest.

## 7. Ignore Assets

Use the checkbox at the right side of an asset row to mark that asset as ignored.
Selected assets can be ignored together.

Enable **Hide ignored** in the left panel to remove ignored entries from the
visible list. Ignore state is saved in the local catalog.

## 8. Save and Load Projects

A project is a saved snapshot of selected asset membership.

### Save a project

1. Select the assets you want in the project.
2. Choose **Save project**.
3. Enter a unique project name.

Saving again while a project is active updates its membership.

### Load, rename, or delete a project

1. Choose **Load project**.
2. Select a project to restore its selected assets.
3. Use the rename or delete controls beside a saved project when needed.

Deleting a project removes its saved membership but does not delete any asset
files.

## 9. Troubleshooting

### A folder scan appears incomplete

- Check whether the missing files are in an intentionally ignored folder.
- ZIP inspection is safety-limited for very large archives and excessive entry
  counts.
- Confirm that the file extension is supported.
- Rescan after changing the source folder.

### An FBX has no visible model

The file may be an animation-only FBX with no embedded mesh, or it may contain
unsupported/corrupt geometry. Read the error shown in the preview panel.

### An FBX is untextured or uses the wrong texture

- Inspect its texture diagnostics.
- Confirm the expected texture exists in the scanned source or the same ZIP.
- Try another UV set.
- Use **Unlit** to distinguish texture problems from lighting.

### Performance is slow

Large folders, ZIP archives, and high-polygon FBX files can take time to scan or
render. Narrow the scanned folder, enable **Hide ZIP contents**, or avoid opening
very large models while a scan is running.

## 10. Supported File Types

- Images: PNG, JPG/JPEG, WebP, GIF, BMP
- FBX texture references may additionally identify PSD, TGA, DDS, and TIFF
  files, but those formats are not currently cataloged as standalone images.
- Audio: WAV, MP3, FLAC, OGG, MIDI
- Models: OBJ, FBX, glTF/GLB, BLEND, DAE, STL
- Archives: ZIP

Direct 3D rendering currently focuses on OBJ and FBX.

## 11. Data and Privacy

AssetAtlas works with local files. Its catalog and project data are stored in a
local SQLite database in the application-support directory. Scanning, previewing,
ignoring, and project management do not upload your assets.

Only an explicit copy operation writes asset copies to another folder.

## 12. Getting Help

Report problems through the
[AssetAtlas GitHub repository](https://github.com/TheMikaus/AssetAtlas/issues).
Include the AssetAtlas version, Windows version, relevant file type, and a short
description of what you expected and what occurred. Do not attach licensed asset
packs unless their license permits redistribution.
