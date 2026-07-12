# Technical Spec: Rendering and FBX Pipeline

## Scope

Describes the FBX import and rendering behavior used by the active Flutter desktop track.

## Import Pipeline

1. Flutter invokes native helper executable for FBX files.
2. Native helper parses scene with `ufbx`.
3. Helper emits JSON including:
   - vertices
   - triangle faces
   - UVs
   - materials
   - texture references
   - scene texture references
   - vertex colors
   - selected material channels (opacity, roughness, metalness, emissive, specular cues)
4. Flutter maps JSON to `MeshModel` and `MeshMaterial`.

## Texture Resolution Strategy

Resolution order for referenced textures:

1. Absolute path if present and exists
2. Relative to model directory
3. Deterministic relink against scanned texture candidates
4. Optional fallback lookup

If no usable texture exists, fallback material logic applies (including checker fallback in eligible cases).

## Rendering Modes

- `Textured`
  - UV-based textured triangle rendering
  - Material channels influence tint/alpha behavior
  - Optional edge overlay when configured

- `Solid`
  - Filled polygons with material-derived color
  - Edge overlay enabled
  - Kept opaque by design for readability

- `Wireframe`
  - Edge-only draw path

## Material Channel Usage (Current)

Renderer currently uses simplified channel interpretation:

- Base color and texture color
- Opacity (with safeguards against pathological near-zero values)
- Roughness/metalness/specular/emissive as lightweight color-response modifiers

This is intentionally approximate and not equivalent to full engine shading.

## Diagnostics and Logging

FBX pipeline logging writes to:

- `work/asset_atlas_native/logs/asset_atlas_fbx.log`

Logs include:

- Importer launch/completion
- JSON field counts
- Texture relink decisions
- Material texture resolution count
- Mesh summary and vertex-color stats

## Known Gaps

- No true per-pixel physically based lighting model
- No full material graph execution
- Perspective-affine texture mapping can show distortion at extreme angles

## Practical Goal

Prioritize robust local asset diagnostics and repeatable preview behavior over full visual parity with DCC/engine runtimes.
