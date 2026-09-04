# TASK-10 — Batch the textured path into drawVertices

**Stage 2 · Size M–L · Follows TASK-06 · Needs visual verification against real asset packs**

## Why this is separate

TASK-06 shipped steps 1–3 (depth computed once, backface culling, an honest
depth-priority face cap). Step 4 — replacing the per-triangle draw with
`Canvas.drawVertices` — was deliberately left out of that commit: it is the larger
performance win, but it is the one part that can regress *how models look*, and a
two-triangle fixture cannot tell you that. It needs eyes on real content.

## Problem

For each textured triangle, `MeshPainter.paint()` currently issues:

```
canvas.save()
canvas.clipPath(triangle)
canvas.transform(uv -> screen matrix)
canvas.drawImage(texture, ...)
canvas.restore()
```

plus up to three more `drawPath` calls for the opaque base colour, the vertex tint
(`BlendMode.modulate`) and the shading overlay. At the 14,000-face budget that is
tens of thousands of canvas operations per frame, each with its own clip stack
push. `drawVertices` with an `ImageShader` collapses the textured fill for a whole
material into a single call.

## Required behaviour

- Textured rendering is issued as one `drawVertices` call per material per frame,
  instead of one clip+transform+draw per triangle.
- No visual regression on real content: textures land on the same triangles, with
  the same orientation, tint and opacity as before.
- Solid and wireframe modes are unaffected.

## Implementation notes

1. Group the faces selected by `selectRenderedFaceOrder` by `materialIndex`,
   preserving the back-to-front order within each group. Note the tradeoff: one
   call per material means depth ordering is only correct *within* a material.
   For opaque geometry that is fine; for materials with `opacity < 1` you may need
   to keep the per-triangle path. Decide explicitly and write the decision down.
2. Build `ui.Vertices.raw` per material:
   - `positions`: `Float32List` of projected screen x/y
   - `textureCoordinates`: `Float32List` in **texture pixel space** (UV × image
     width/height), matching what `ImageShader` with an identity matrix expects
   - `colors`: `Int32List` — this is where the existing per-face vertex tint goes,
     replacing the extra `BlendMode.modulate` pass
3. `Paint()..shader = ImageShader(image, TileMode.clamp, TileMode.clamp, Matrix4.identity().storage)`.
   Build one shader per material per frame, not per triangle.
4. Keep the shading term. Per-vertex colours can carry it if you fold the face
   light into the vertex colour, which also removes the black overlay `drawPath`.
5. Leave the existing per-triangle path in place behind a flag while you compare,
   then delete it once the comparison is done.

## Verification (the point of this task)

Not optional, and not satisfiable with the test fixture:

- Pick at least three real models with different characteristics — a Synty-style
  low-poly prop with a palette atlas, something with multiple materials, and
  something with an alpha-tested texture (foliage).
- Screenshot each in textured mode, before and after, at the same camera. Put the
  pairs in the PR.
- Check specifically for: UV orientation flips, seams at triangle edges, tint
  differences, and alpha behaviour.
- Re-measure frame time on a >50k-triangle mesh and report the numbers, as
  TASK-06 did.

## Acceptance criteria

- [ ] One `drawVertices` call per material per frame on the textured path.
- [ ] Before/after screenshots of three real models attached, no visible
      regression.
- [ ] Frame-time measurement in the PR description.
- [ ] Documented decision about transparent materials.
- [ ] `flutter analyze` clean, `flutter test` green.

## Out of scope

- Perspective-correct UV interpolation (`drawVertices` is still affine per
  triangle — this task does not change that, and the affine limitation stays
  documented in `docs/TECH_SPEC_RENDERING_FBX.md`).
- A depth buffer.
