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

## Flat Palette Faces

Palette-atlas content (Synty and similar) maps an entire face to one texel, so
the face's UV triangle has zero area. These are detected and filled with the
sampled texel colour rather than drawn through the affine texture path, which
cannot invert a degenerate transform. Consecutive flat faces are batched into a
single `drawVertices` call with per-vertex colours.

This is not an optimisation detail: before it existed, every such face rendered
as the material's untextured base colour, which is most of a low-poly model.

## Normal Maps

The importer emits each material's normal map separately (`normalTexture`), and
it is resolved and read back to CPU like the base texture. Shading applies it
per face: a tangent frame is built from the triangle's position and UV
derivatives, the sampled tangent-space normal is rotated into view space, and
the diffuse term uses that instead of the geometric normal.

Two honest limits:

- This is per face, not per pixel. A normal map can tilt a whole triangle; it
  cannot add detail inside one. Per-pixel would need a fragment shader.
- Faces pinned to a single texel (the palette case) have no UV gradient, so
  there is no tangent frame and they keep their geometric normal.

The viewer only offers the toggle when the model actually carries a normal map.
Note that palette-atlas packs such as Synty ship none: a 60-model sample of the
reference catalog found zero.

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
