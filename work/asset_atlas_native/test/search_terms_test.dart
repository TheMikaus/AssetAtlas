import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asset_atlas_native/main.dart';

/// The filter grammar, against the fixture the MCP is also tested on.
///
/// The app and the MCP have to answer a search identically -- the same words
/// typed into the box and handed to `search_assets` must select the same
/// files. They are separate implementations in different languages, which is
/// the arrangement that always drifts, so neither owns the grammar:
/// `work/atlas_mcp/fixtures/search_queries.json` does, and both suites read
/// it. A case added there fails on whichever side has not caught up.
Map<String, dynamic> loadQueryFixture() {
  // The test's working directory is the package root.
  final file = File('../atlas_mcp/fixtures/search_queries.json');
  if (!file.existsSync()) {
    throw StateError(
      'search_queries.json is not beside this checkout at '
      '${file.absolute.path}. The grammar is shared with the MCP and this '
      'suite is meaningless without it.',
    );
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// The field resolver for a fixture asset, standing in for an AssetItem.
///
/// Mirrors `_row_for` in test_atlas_mcp.py: the fixture names the type a
/// person sees, which is the effective one.
String Function(String) resolverFor(Map<String, dynamic> asset) {
  final name = (asset['name'] as String).toLowerCase();
  final path = (asset['relative_path'] as String).toLowerCase();
  final tags = (asset['tags'] as List)
      .map((tag) => tag as String)
      .join(' ')
      .toLowerCase();
  return (String field) => switch (field) {
    'name' => name,
    'path' => path,
    'tag' => tags,
    'type' => asset['type'] as String,
    'ext' => (asset['ext'] as String).toLowerCase(),
    'rig' => (asset['rig'] as String?) ?? '',
    _ => '$name\u0000$path\u0000$tags',
  };
}

void main() {
  final fixture = loadQueryFixture();
  final parseCases = fixture['parse'] as List;
  final matchCases = fixture['match'] as List;
  final assets = fixture['assets'] as Map<String, dynamic>;

  group('the fixture', () {
    test('is loaded and not a stub', () {
      // A fixture that silently stopped loading would pass every loop below.
      expect(parseCases.length, greaterThan(20));
      expect(matchCases.length, greaterThan(20));
    });

    test('lists the same fields the code does', () {
      // Adding a field on one side only is the drift this catches.
      expect(
        (fixture['fields'] as List).where((field) => field != 'any').toList(),
        assetQueryNamedFields,
      );
      expect(
        (fixture['exact_fields'] as List).toSet(),
        assetQueryExactFields,
      );
      expect(
        (fixture['reserved_fields'] as List).toSet(),
        assetQueryReservedFields.keys.toSet(),
      );
    });
  });

  group('parseAssetQuery', () {
    for (final entry in parseCases) {
      final testCase = entry as Map<String, dynamic>;
      final query = testCase['query'] as String;
      final why = testCase['why'] as String;

      test('$why: ${jsonEncode(query)}', () {
        final parsed = parseAssetQuery(query);
        if (testCase.containsKey('error_contains')) {
          expect(
            parsed.isValid,
            isFalse,
            reason: 'this query has to be refused',
          );
          expect(
            parsed.error!.toLowerCase(),
            contains((testCase['error_contains'] as String).toLowerCase()),
          );
          // A refusal matches nothing, so a caller that ignored isValid gets
          // an empty list rather than the whole library.
          expect(parsed.clauses, isEmpty);
        } else {
          expect(parsed.error, isNull, reason: parsed.error ?? '');
          final expected = (testCase['clauses'] as List)
              .map(
                (clause) => (clause as List)
                    .map(
                      (term) => AssetQueryTerm(
                        (term as List)[0] as String,
                        term[1] as String,
                      ),
                    )
                    .toList(),
              )
              .toList();
          expect(parsed.clauses, expected);
        }
      });
    }
  });

  group('assetMatchesQuery', () {
    for (final entry in matchCases) {
      final testCase = entry as Map<String, dynamic>;
      final query = testCase['query'] as String;
      final assetKey = testCase['asset'] as String;
      final expected = testCase['matches'] as bool;

      test('${testCase['why']}: ${jsonEncode(query)} on $assetKey', () {
        final parsed = parseAssetQuery(query);
        expect(parsed.error, isNull, reason: parsed.error ?? '');
        expect(
          assetMatchesQuery(
            parsed,
            resolverFor(assets[assetKey] as Map<String, dynamic>),
          ),
          expected,
        );
      });
    }
  });

  group('looksLikeAnimation', () {
    // The same cases the MCP is held to. A guess standing in for a probe is
    // exactly what drifts between two implementations unnoticed.
    final animationCases = fixture['animation_paths'] as List;

    test('the fixture has both answers in it', () {
      final answers = animationCases
          .map((entry) => (entry as Map)['animation'] as bool)
          .toSet();
      expect(answers, {true, false});
    });

    for (final entry in animationCases) {
      final testCase = entry as Map<String, dynamic>;
      final path = testCase['path'] as String;
      test('${testCase['why']}: $path', () {
        expect(looksLikeAnimation(path), testCase['animation'] as bool);
      });
    }
  });

  group('effectiveType and the animation rule', () {
    AssetItem model({String? modelKind, required String relativePath,
        String type = 'model'}) => AssetItem(
      id: 'a',
      name: relativePath.split('/').last,
      path: 'K:/$relativePath',
      relativePath: relativePath,
      sourceRoot: 'K:/',
      sourceName: 'lib',
      ext: 'fbx',
      type: type,
      size: 1,
      modified: DateTime(2026),
      tags: const [],
      modelKind: modelKind,
    );

    test('a probed mesh outranks the folder', () {
      // The rule is a fallback, not an override.
      expect(
        model(modelKind: 'mesh', relativePath: 'p/Animations/SM_Thing.fbx')
            .effectiveType,
        'model',
      );
    });

    test('a probed clip is a clip wherever it sits', () {
      expect(
        model(modelKind: 'animation', relativePath: 'p/Models/SM_Thing.fbx')
            .effectiveType,
        'animation',
      );
    });

    test('an unprobed file falls back to the folder', () {
      expect(
        model(relativePath: 'p/Animations/A_Run.fbx').effectiveType,
        'animation',
      );
    });

    test('an unprobed file elsewhere stays a model', () {
      expect(
        model(relativePath: 'p/Models/SM_Barrel.fbx').effectiveType,
        'model',
      );
    });

    test('the rule only applies to models', () {
      // An image in an Animations folder is still an image: the rule reads
      // model rows only, so nothing else can be dragged into 'animation'.
      expect(
        model(relativePath: 'p/Animations/T_Thing.png', type: 'image')
            .effectiveType,
        'image',
      );
    });

    test('type=animation in the box finds an unprobed clip', () {
      final clip = model(relativePath: 'p/Animations/A_Run.fbx');
      expect(
        assetMatchesQuery(parseAssetQuery('type=animation'), clip.queryValue),
        isTrue,
      );
      expect(
        assetMatchesQuery(parseAssetQuery('type=model'), clip.queryValue),
        isFalse,
      );
    });
  });

  group('AssetItem.queryValue', () {
    // The resolver above stands in for an AssetItem, so this is what ties the
    // fixture to the real class: the same fields, read off a real asset.
    AssetItem makeAsset() => AssetItem(
      id: 'a',
      name: 'SM_Prop_Barrel_01.FBX',
      path: 'K:/Assets/Synty/Models/SM_Prop_Barrel_01.FBX',
      relativePath: 'Synty/POLYGON_Western/Models/SM_Prop_Barrel_01.FBX',
      sourceRoot: 'K:/Assets',
      sourceName: 'Assets',
      ext: 'FBX',
      type: 'model',
      size: 1024,
      modified: DateTime(2026),
      tags: const ['Model', 'FBX', 'Grungy'],
    );

    test('every field a term can name is resolved', () {
      final asset = makeAsset();
      for (final field in assetQueryNamedFields) {
        expect(
          () => asset.queryValue(field),
          returnsNormally,
          reason: '$field= would throw at search time',
        );
      }
    });

    test('name, path and tags are folded to lowercase', () {
      final asset = makeAsset();
      expect(asset.queryValue('name'), 'sm_prop_barrel_01.fbx');
      expect(asset.queryValue('path'), contains('polygon_western'));
      expect(asset.queryValue('tag'), 'model fbx grungy');
      expect(asset.queryValue('ext'), 'fbx');
    });

    test('type is the effective type, not the stored one', () {
      final texture = AssetItem(
        id: 'b',
        name: 'T_Western_01.png',
        path: 'K:/Assets/Synty/Textures/T_Western_01.png',
        relativePath: 'Synty/POLYGON_Western/Textures/T_Western_01.png',
        sourceRoot: 'K:/Assets',
        sourceName: 'Assets',
        ext: 'png',
        type: 'image',
        size: 512,
        modified: DateTime(2026),
        tags: const ['image'],
      );
      expect(texture.type, 'image');
      expect(texture.queryValue('type'), 'texture');
    });

    test('an unset rig is empty, so rig=none does not match it', () {
      // 'none' means probed and rigless; null means nobody has looked. A
      // search must not conflate the two.
      final asset = makeAsset();
      expect(asset.rigFamily, isNull);
      expect(asset.queryValue('rig'), '');
      expect(
        assetMatchesQuery(parseAssetQuery('rig=none'), asset.queryValue),
        isFalse,
      );
    });

    test('a plain term cannot straddle two fields', () {
      // The NUL separators in searchText are the only thing stopping a term
      // spanning the end of the name and the start of the path.
      final asset = makeAsset();
      final straddle =
          'sm_prop_barrel_01.fbx${asset.relativePath.substring(0, 5).toLowerCase()}';
      expect(
        assetMatchesQuery(parseAssetQuery(straddle), asset.queryValue),
        isFalse,
      );
    });

    test('a real asset answers a scoped query the fixture way', () {
      final asset = makeAsset();
      for (final (query, expected) in <(String, bool)>[
        ('barrel', true),
        ('tag=grungy', true),
        ('tag=barrel', false),
        ('name=western', false),
        ('path=western', true),
        ('type=model ext=fbx', true),
        ('type=texture', false),
        ('name=crate or name=barrel', true),
      ]) {
        expect(
          assetMatchesQuery(parseAssetQuery(query), asset.queryValue),
          expected,
          reason: query,
        );
      }
    });
  });
}
