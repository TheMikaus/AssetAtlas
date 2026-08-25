# TASK-03 — UTF-8 across the importer boundary

**Stage 1 · Size S · No dependencies · Touches C++ and Dart**

## Problem

The native helper emits UTF-8. Dart reads it two different ways, and one of them is wrong.

`runMeshImporter()` (`lib/main.dart` ~L3668):

```dart
if (inputBytes == null) {
  final processResult = await Process.run(helper, [sourcePath]);   // <-- systemEncoding
  return MeshImporterResult(
    exitCode: processResult.exitCode,
    stdout: processResult.stdout as String? ?? '',
    ...
```

`Process.run`'s `stdoutEncoding` defaults to `systemEncoding`, which on Windows is the machine's
ANSI codepage (typically cp1252), **not** UTF-8. The `--stdin` branch a few lines below does the
right thing — it collects bytes and calls `utf8.decode(..., allowMalformed: true)`.

So an FBX loaded from disk whose material name or texture path contains any non-ASCII character
(`Café_Wall.png`, `Größe_01.fbx`, a Japanese pack name) arrives mojibaked. The relink then fails to
match the real filename, and the log line says the texture could not be resolved — with no hint that
the string was corrupted in transit. ZIP-sourced FBX files with the same content resolve fine, which
makes the bug look random.

A second, related hole is on the C++ side. `print_json_string()`
(`windows/runner/mesh_importer.cpp` ~L67) escapes `\`, `"`, `\n`, `\r`, `\t` and passes every other
byte straight through — including control bytes below 0x20, which are illegal raw in JSON. One such
byte in a material name makes `jsonDecode` throw, and the user sees a generic "importer failed".

## Required behaviour

1. Both importer invocation paths decode stdout and stderr as UTF-8.
2. Round-tripping a non-ASCII material name or texture path through the importer preserves the exact
   string.
3. The importer's JSON output is valid for any byte sequence ufbx can hand it.

## Implementation notes

### Dart side

Make the on-disk branch byte-based like the stdin branch, so there is one decoding rule:

```dart
final processResult = await Process.run(
  helper,
  [sourcePath],
  stdoutEncoding: null,   // returns List<int>
  stderrEncoding: null,
);
return MeshImporterResult(
  exitCode: processResult.exitCode,
  stdout: utf8.decode(processResult.stdout as List<int>, allowMalformed: true),
  stderr: utf8.decode(processResult.stderr as List<int>, allowMalformed: true),
);
```

Passing `null` makes `Process.run` return raw bytes. Keep `allowMalformed: true` so a bad byte
degrades to U+FFFD instead of throwing — matching the existing stdin path.

Consider collapsing both branches into one helper that takes an optional `inputBytes` and always
decodes the same way; the duplication is what let them drift.

### C++ side

In `print_json_string()`, add a default case for control characters:

```cpp
default:
  if (static_cast<unsigned char>(*p) < 0x20) {
    printf("\\u%04x", static_cast<unsigned char>(*p));
  } else {
    putchar(*p);
  }
  break;
```

Bytes ≥ 0x80 must still pass through untouched — they are the continuation bytes of valid UTF-8
sequences and escaping them individually would corrupt the text.

## Tests

- **Round-trip test** in `test/native_fbx_importer_test.dart` (guard it with the same
  `helper.existsSync()` skip the file already uses): add an ASCII FBX fixture whose material name
  contains non-ASCII characters — e.g. `Matériau_Grün` — next to the existing
  `test/fixtures/fbx/transformed_uv_embedded.fbx`. Run the helper on it and assert the decoded
  `materials[0]['name']` equals the exact source string. This fails today.

  The existing fixture is hand-written ASCII FBX; copy it and edit the material name, keeping the
  file ASCII-FBX so it stays diffable. Write the file as UTF-8 without BOM.

- **Escaping unit test**: not directly reachable from Dart. Cover it by adding a material name with a
  literal control byte to the same fixture and asserting `jsonDecode` succeeds (today it throws).

- Existing importer tests must stay green.

## Acceptance criteria

- [ ] Both importer paths decode as UTF-8; no `systemEncoding` remains in the file.
- [ ] A non-ASCII material name survives the round trip byte-for-byte.
- [ ] A control byte in a material name yields valid JSON.
- [ ] `flutter build windows --release` succeeds (you are changing C++ — the analyzer will not catch
      a compile error for you), then `flutter analyze` and `flutter test` are clean.

## Out of scope

- Replacing the JSON protocol with a binary one (planned separately).
- Non-Windows importer builds.
