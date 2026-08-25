# TASK-04 — Make texture relink actually deterministic

**Stage 1 · Size M · No dependencies**

## Problem

`findDeterministicTextureRelink()` (`lib/main.dart` ~L2818) is the function that rescues FBX files
whose baked-in texture paths point at the original author's machine. It is advertised as
deterministic in the README and in `docs/TECH_SPEC_RENDERING_FBX.md`. It is not.

```dart
sourceCandidates.sort((a, b) => score(b).compareTo(score(a)));
final best = sourceCandidates.first;
final bestScore = score(best);
if (bestScore < 80) return null;
return best.path;
```

Two problems:

1. **Ties resolve arbitrarily.** Dart's `List.sort` is documented as not stable. When two candidates
   score equally — common with Synty-style packs where `Texture_01_A.png` and `Texture_01_B.png` both
   match the same rules — the winner depends on the incoming list order and on sort internals. The
   same model can relink to a different texture after an unrelated re-scan, on another machine, or
   after a Dart upgrade. Silent, non-reproducible visual differences are the worst kind of bug to
   chase.
2. **`score()` runs inside the comparator.** Each call builds several `RegExp` objects and lowercases
   strings, and a comparator is invoked O(n log n) times. With a few thousand texture candidates,
   scoring dominates. `findFallbackTexture()` (~L2905) has exactly the same shape and the same two
   problems.

## Required behaviour

- Given the same catalog contents, the same model, and the same requested texture path, the resolved
  texture is **always the same**, regardless of the order assets arrive in.
- Each candidate is scored exactly once per resolution.
- Behaviour on non-tied inputs is unchanged — this is a determinism and performance fix, not a
  re-tuning of the scoring heuristics. Do not adjust the point values.

## Implementation notes

1. Score once, then sort the scored pairs (decorate–sort–undecorate):

   ```dart
   final scored = [
     for (final asset in sourceCandidates) (asset: asset, score: score(asset)),
   ]..sort((a, b) {
       final byScore = b.score.compareTo(a.score);
       if (byScore != 0) return byScore;
       return normalizePathKey(a.asset.path).compareTo(normalizePathKey(b.asset.path));
     });
   ```

   The tie-break must be a **total order over something intrinsic to the candidate** — the normalized
   path is unique per asset and already has a helper (`normalizePathKey`). Never tie-break on list
   index.

2. Hoist the `RegExp`s that `score()` and its helpers rebuild on every call
   (`RegExp(r'\.[^.]+$')`, `RegExp(r'[^a-z0-9]+')`, the `paletteTail` pattern) to top-level `final`
   constants. They are stateless and safe to share.

3. Apply the identical treatment to `findFallbackTexture()`, including the tie-break.

4. `tokenSet()` and `normalize()` allocate per call inside scoring loops; caching the normalized
   basename per candidate for the duration of one resolution is worthwhile and stays local.

## Tests

New file `test/texture_relink_test.dart`. These are pure functions over `AssetItem` lists, so they
need no filesystem and no native helper — construct `AssetItem`s directly.

- **Tie determinism (fails today, in principle — write it first):** build two candidates that score
  identically for a requested texture, run `findDeterministicTextureRelink` twice with the candidate
  list in both orders, assert both calls return the same path, and assert it is the
  lexicographically-smaller normalized path.
- **Order independence:** shuffle a 20-candidate list with a fixed seed (`math.Random(1234)`) across
  several permutations; assert one stable answer.
- **Threshold:** a candidate scoring below 80 returns `null`.
- **Known-good cases stay unchanged** — lock in the behaviours the scoring comments describe:
  exact basename match wins; `_Mike`-style author suffix stripped (`Wall_01_Mike.psd` request →
  `Wall_01.png`); Synty variant (`Texture_01.psd` request → `Texture_01_A.png`); singular/plural
  drift (`window` → `windows`); same-directory candidate preferred over a distant one.
- **ZIP containment:** a model inside `pack_a.zip` never relinks to a texture inside `pack_b.zip`.
  The existing code enforces this — pin it so the refactor cannot regress it.
- **Fallback:** the same tie-determinism assertion for `findFallbackTexture`.

## Acceptance criteria

- [ ] Repeated resolutions over reordered catalogs return identical results.
- [ ] `score()` is evaluated once per candidate per resolution (assert this if you like, by
      instrumenting a counter in a test-only variant, or simply verify by inspection in review).
- [ ] Existing FBX pipeline tests unchanged and green.
- [ ] `flutter analyze` clean.

## Out of scope

- Changing the scoring heuristics or thresholds.
- Making relink configurable or surfacing it in the UI.
- The O(n) candidate filter that runs per material (addressed by TASK-05's caching).
