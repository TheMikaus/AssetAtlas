# TASK-06 — Renderer frame cost and an honest face cap

**Stage 2 · Size M · No dependencies**

## Problem

### 6a. The viewer silently hides geometry

`MeshPainter.paint()` (`lib/main.dart` ~L2076):

```dart
final step = math.max(1, (faces.length / 14000).ceil());
for (var index = 0; index < faces.length; index += step) {
```

Above ~14,000 triangles the painter draws every *step*-th face. A 112k-triangle model renders with
one eighth of its triangles and nothing in the UI says so. For a tool whose job is answering "is this
asset OK?", a viewer that invents holes is worse than a slow one — the user cannot distinguish a
broken export from a rendering shortcut.

### 6b. Every frame redoes work it could keep

A pan gesture produces one `setState` per pointer move, and each frame:

- copies the entire face list — `mesh.faces.toList()`;
- sorts it with `(a, b) => _faceDepth(projected, b).compareTo(_faceDepth(projected, a))`, which
  **recomputes both depths inside the comparator**: O(F log F) depth computations where O(F) would do;
- draws back-facing triangles that will be painted over anyway (no culling);
- for textured meshes, issues `save` → `clipPath` → `transform` → `drawImage` → `restore` **per
  triangle**, plus up to three more `drawPath` calls per triangle for base colour, vertex tint and
  shading.

## Required behaviour

1. Nothing is dropped from the render without the UI saying so.
2. The per-frame cost of an interaction (pan/zoom) drops materially on meshes in the 10k–150k
   triangle range, with no visual regression on the fixture models.
3. Rendering output for small meshes is unchanged apart from culling of genuinely back-facing
   triangles.

## Implementation notes

Work in this order; each step is independently shippable.

### Step 1 — precompute depth keys

Compute each face's average depth once into a `Float64List` (or a list of `(index, depth)` records),
sort indices by that, then iterate. This alone removes the dominant cost of the sort.

```dart
final depths = Float64List(faces.length);
for (var i = 0; i < faces.length; i++) {
  depths[i] = _faceDepth(projected, faces[i]);
}
final order = List<int>.generate(faces.length, (i) => i)
  ..sort((a, b) => depths[b].compareTo(depths[a]));
```

Avoid `mesh.faces.toList()` — sort an index list, not a copy of the face objects.

### Step 2 — backface culling

The painter already computes a face normal in `_faceLight`. Compute the projected-space signed area
once per face and skip faces facing away from the viewer. Typical closed meshes lose ~50% of their
draw calls with no visual change.

Careful: `_faceLight` currently takes `.abs()` of the diffuse term, i.e. lights both sides. Culling
back faces is safe for closed meshes but will visibly change single-sided geometry such as foliage
cards. **Gate culling behind a toggle in the viewer controls, default on**, and note it in the
`USER_MANUAL.md` model-preview section.

### Step 3 — surface the cap instead of hiding it

Replace the silent `step` decimation with an explicit budget:

- Keep a face budget (start with the current 14,000; make it a named top-level constant such as
  `maxRenderedFaces`).
- After culling, if the remaining face count still exceeds the budget, render the budget's worth —
  but **by depth priority, not by index stride** (take the nearest N faces after the sort, which is a
  far better approximation than every-Nth).
- Show it in the existing bottom-left overlay, which already reads
  `'${mesh.name} · ${mesh.vertices.length} verts · ${mesh.faces.length} faces'`. Append e.g.
  `· showing 14,000 of 112,340` and give the label a distinct colour when the cap is active.

### Step 4 — batch the textured path

Replace the per-triangle clip/transform/drawImage with `Canvas.drawVertices`, using a
`Paint()..shader = ImageShader(...)` per material. Group faces by material, build one `Vertices`
object per material per frame from positions and texture coordinates, and issue one `drawVertices`
call per material. This is the large win and the most involved part — if time runs short, ship
steps 1–3 and open a follow-up for this one.

Watch for: `Vertices.raw` wants `Float32List`s; UVs must be in texture pixel space for
`ImageShader` with an identity matrix; the existing per-face vertex tint has no direct equivalent, so
pass vertex colours through the `colors:` parameter of `Vertices` rather than as extra draw passes.

## Tests

The painter is not directly unit-testable today, but these are:

- **Face-budget selection**: extract the "which faces to draw" decision into a pure top-level
  function — e.g. `List<int> selectRenderedFaceOrder({required List<double> depths, required int budget, ...})`
  — and test it: under budget returns everything; over budget returns exactly `budget` entries; the
  returned entries are the nearest ones; ordering is back-to-front.
- **Culling predicate**: pure function over three projected points; assert the sign convention on a
  known clockwise and counter-clockwise triangle.
- **Golden-ish smoke test**: a widget test that pumps `ModelPreview` against the fixture FBX (guarded
  by the native-helper skip) and asserts the overlay text reports the full face count for a small
  mesh, and a "showing N of M" form when the budget is forced low via the constant.

## Acceptance criteria

- [ ] No code path drops geometry without the overlay reporting it.
- [ ] Depth is computed once per face per frame.
- [ ] Culling is toggleable and documented in `USER_MANUAL.md`.
- [ ] Measured: record before/after frame times for a mesh of >50k triangles (Flutter DevTools
      timeline, or a stopwatch around `paint`) and put the numbers in the PR description.
- [ ] `flutter analyze` clean, `flutter test` green.

## Out of scope

- A real depth buffer or per-pixel lighting — the painter's algorithm stays.
- Fixing perspective-affine UV distortion (documented non-goal in
  `docs/TECH_SPEC_RENDERING_FBX.md`).
- Moving rendering to the GPU via a shader pipeline.
