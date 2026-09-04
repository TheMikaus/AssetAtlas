import 'dart:async';
import 'dart:isolate';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeFbxLogPath();
  if (enableFbxLogs) {
    try {
      File(fbxLogFilePath).writeAsStringSync('', mode: FileMode.write);
    } catch (_) {
      // Ignore inability to reset log file.
    }
    fbxLog('FBX logging enabled. File: $fbxLogFilePath');
  }
  // Restoring this before the first frame keeps a clip from briefly showing
  // the stick figure when a character was already chosen.
  await AnimationCharacter.instance.load();
  runApp(const AssetAtlasApp());
}

const imageExts = {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'psd'};
const textureExts = {
  'png',
  'jpg',
  'jpeg',
  'webp',
  'bmp',
  'psd',
  'tga',
  'dds',
  'tif',
  'tiff',
};
const audioExts = {'wav', 'mp3', 'flac', 'ogg', 'midi', 'mid'};
const modelExts = {'obj', 'fbx', 'gltf', 'glb', 'blend', 'dae', 'stl'};
const archiveExts = {'zip'};
const maxZipIntrospectionBytes = 128 * 1024 * 1024;
const maxZipEntriesToInspect = 25000;
const maxZipArchiveCacheEntries = 8;
const appVersion = '1.10.11';
const _maxConcurrentModelValidations = 3;

/// How many chunks are classified at once.
///
/// Each worker holds one archive in memory while it works through a chunk, and
/// the largest here is ~126 MB, so this is capped well below the core count:
/// the ceiling is memory, not CPU. Two cores are left for the UI isolate and
/// the importer subprocesses the workers drive.
final _classificationWorkerCount = math.max(
  1,
  math.min(6, Platform.numberOfProcessors - 2),
);

/// Assets per worker chunk. Bigger amortises opening the archive; smaller
/// makes progress visible sooner.
const fbxClassifyChunkSize = 400;
const enableFbxLogs = true;
String fbxLogFilePath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}asset_atlas_fbx.log';
const ignoredFolderNames = {
  '__macosx',
  '.git',
  '.vs',
  '.vscode',
  '.idea',
  'binaries',
  'deriveddatacache',
  'intermediate',
  'saved',
};

void fbxLog(String message) {
  if (!enableFbxLogs) return;
  developer.log(message, name: 'AssetAtlas.FBX');
  final line = '${DateTime.now().toIso8601String()} | $message\n';
  try {
    File(
      fbxLogFilePath,
    ).writeAsStringSync(line, mode: FileMode.append, flush: false);
  } catch (_) {
    // Console logs still provide diagnostics if file logging is unavailable.
  }
}

void initializeFbxLogPath() {
  final cwd = Directory.current;
  final inProject = File(
    '${cwd.path}${Platform.pathSeparator}pubspec.yaml',
  ).existsSync();
  final nestedProject = File(
    '${cwd.path}${Platform.pathSeparator}work${Platform.pathSeparator}asset_atlas_native${Platform.pathSeparator}pubspec.yaml',
  ).existsSync();

  Directory? targetDir;
  if (inProject) {
    targetDir = Directory('${cwd.path}${Platform.pathSeparator}logs');
  } else if (nestedProject) {
    targetDir = Directory(
      '${cwd.path}${Platform.pathSeparator}work${Platform.pathSeparator}asset_atlas_native${Platform.pathSeparator}logs',
    );
  }

  if (targetDir == null) return;
  try {
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }
    fbxLogFilePath =
        '${targetDir.path}${Platform.pathSeparator}asset_atlas_fbx.log';
  } catch (_) {
    // Keep system temp fallback path.
  }
}

class AssetAtlasApp extends StatelessWidget {
  const AssetAtlasApp({this.enablePersistence = true, super.key});

  final bool enablePersistence;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Asset Atlas Native',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2f5f8f),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: CatalogScreen(enablePersistence: enablePersistence),
    );
  }
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({this.enablePersistence = true, super.key});

  final bool enablePersistence;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final db = AssetAtlasDatabase.instance;
  final assets = <AssetItem>[];
  final selectedIds = <String>{};
  final sourceRoots = <String>{};
  final searchController = TextEditingController();

  AssetItem? active;
  String? activeProjectId;
  String? activeProjectName;
  bool loadingPersisted = true;
  String query = '';
  String typeFilter = 'all';
  String modelTextureFilter = 'all';
  bool hideIgnored = true;
  bool hideZipAssets = false;
  bool scanning = false;
  double assetListWidth = 420;
  double filterPanelWidth = 260;
  bool gridMode = false;
  AssetSortMode sortMode = AssetSortMode.path;
  String? _lastSelectionAnchorId;
  String? folderFilter;
  final expandedFolders = <String>{};
  Timer? _searchDebounce;
  ScanHandle? _activeScan;

  /// Bumped whenever something that affects filtering changes without the
  /// catalog itself changing: an ignore toggle, a texture validation result, an
  /// FBX classification.
  int _listEpoch = 0;
  List<AssetItem>? _sortedCache;
  String? _sortedCacheKey;
  List<AssetItem>? _filteredCache;
  String? _filteredCacheKey;
  List<FolderNode>? _folderRootsCache;
  int _folderRootsRevision = -1;
  ScanStatus status = const ScanStatus('Ready', 'Choose a folder to catalog.');
  final modelHasValidTextures = <String, bool>{};
  final _modelValidationInFlight = <String>{};
  final _modelKindInFlight = <String>{};
  final Queue<AssetItem> _modelKindQueue = Queue<AssetItem>();
  bool _processingModelKindQueue = false;
  int _modelKindClassified = 0;
  int _classificationFailures = 0;
  final Queue<AssetItem> _modelValidationQueue = Queue<AssetItem>();
  bool _processingModelValidationQueue = false;
  final List<String> _assetHistory = <String>[];
  int _assetHistoryIndex = -1;

  /// Incremented whenever the catalog contents change. Preview widgets compare
  /// this to decide whether a cached import is still valid; comparing list
  /// lengths missed same-size changes.
  int catalogRevision = 0;

  bool get canGoBackInHistory => _assetHistoryIndex > 0;
  bool get canGoForwardInHistory =>
      _assetHistoryIndex >= 0 && _assetHistoryIndex < _assetHistory.length - 1;

  @override
  void initState() {
    super.initState();
    if (widget.enablePersistence) {
      status = const ScanStatus(
        'Starting up',
        'Restoring catalog in the background...',
      );
      _restorePersistedCatalog();
    } else {
      loadingPersisted = false;
    }
  }

  AssetItem? _assetById(String id) {
    for (final asset in assets) {
      if (asset.id == id) return asset;
    }
    return null;
  }

  void _seedHistoryWithActive() {
    _assetHistory.clear();
    if (active == null) {
      _assetHistoryIndex = -1;
      return;
    }
    _assetHistory.add(active!.id);
    _assetHistoryIndex = 0;
  }

  void _pruneHistoryToVisibleAssets() {
    if (_assetHistory.isEmpty) {
      _assetHistoryIndex = -1;
      return;
    }

    final activeHistoryId =
        _assetHistoryIndex >= 0 && _assetHistoryIndex < _assetHistory.length
        ? _assetHistory[_assetHistoryIndex]
        : null;
    final validAssetIds = assets.map((asset) => asset.id).toSet();
    _assetHistory.removeWhere((id) => !validAssetIds.contains(id));

    if (_assetHistory.isEmpty) {
      _assetHistoryIndex = -1;
      active = assets.isEmpty ? null : assets.first;
      if (active != null) {
        _assetHistory.add(active!.id);
        _assetHistoryIndex = 0;
      }
      return;
    }

    if (activeHistoryId != null) {
      final nextIndex = _assetHistory.indexOf(activeHistoryId);
      if (nextIndex >= 0) {
        _assetHistoryIndex = nextIndex;
      } else {
        _assetHistoryIndex = _assetHistory.length - 1;
      }
    } else {
      _assetHistoryIndex = _assetHistory.length - 1;
    }

    final historyAsset = _assetById(_assetHistory[_assetHistoryIndex]);
    if (historyAsset != null) {
      active = historyAsset;
    }
  }

  void _activateAsset(AssetItem asset, {bool addToHistory = true}) {
    // The preview is about to import this file regardless, so the
    // classification is nearly free here.
    _scheduleModelKindClassification([asset]);
    if (asset.type == 'model') {
      unawaited(_recordTexturesUsedBy(asset));
    }
    setState(() {
      active = asset;
      if (!addToHistory) return;

      if (_assetHistoryIndex >= 0 &&
          _assetHistoryIndex < _assetHistory.length - 1) {
        _assetHistory.removeRange(_assetHistoryIndex + 1, _assetHistory.length);
      }
      if (_assetHistory.isNotEmpty && _assetHistory.last == asset.id) {
        _assetHistoryIndex = _assetHistory.length - 1;
        return;
      }
      _assetHistory.add(asset.id);
      _assetHistoryIndex = _assetHistory.length - 1;
    });
  }

  void _goBackHistory() {
    if (!canGoBackInHistory) return;
    final nextIndex = _assetHistoryIndex - 1;
    final next = _assetById(_assetHistory[nextIndex]);
    if (next == null) return;
    setState(() {
      _assetHistoryIndex = nextIndex;
      active = next;
    });
  }

  void _goForwardHistory() {
    if (!canGoForwardInHistory) return;
    final nextIndex = _assetHistoryIndex + 1;
    final next = _assetById(_assetHistory[nextIndex]);
    if (next == null) return;
    setState(() {
      _assetHistoryIndex = nextIndex;
      active = next;
    });
  }

  /// Rebuilt only when the catalog changes: walking 48k paths on every
  /// rebuild would be pure waste.
  List<FolderNode> get folderRoots {
    if (_folderRootsCache == null || _folderRootsRevision != catalogRevision) {
      _folderRootsCache = buildFolderTree(assets);
      _folderRootsRevision = catalogRevision;
    }
    return _folderRootsCache!;
  }

  /// The catalog in display order, sorted once per (catalog, sort mode).
  /// Filtering a sorted list yields a sorted list, so searching no longer has
  /// to re-sort tens of thousands of assets on every keystroke.
  List<AssetItem> get sortedAssets {
    final key = '$catalogRevision|${sortMode.name}|$_listEpoch';
    if (_sortedCache == null || _sortedCacheKey != key) {
      _sortedCache = sortAssets(assets, sortMode);
      _sortedCacheKey = key;
    }
    return _sortedCache!;
  }

  List<AssetItem> get filteredAssets {
    final lower = query.trim().toLowerCase();
    final cacheKey = [
      lower,
      typeFilter,
      modelTextureFilter,
      hideIgnored,
      hideZipAssets,
      folderFilter ?? '',
      sortMode.name,
      catalogRevision,
      _listEpoch,
    ].join('|');
    if (_filteredCache != null && _filteredCacheKey == cacheKey) {
      return _filteredCache!;
    }

    final matches = sortedAssets.where((asset) {
      if (hideIgnored && asset.ignored) return false;
      if (folderFilter != null &&
          !isUnderFolder(asset.relativePath, folderFilter!)) {
        return false;
      }
      if (hideZipAssets && isZipVirtualPath(asset.path)) return false;
      if (typeFilter == 'animation') {
        // Only a parse can tell an animation clip from a mesh, so ask for one
        // and leave the asset out of the list until the answer arrives.
        if (asset.type == 'model' && asset.ext == 'fbx') {
          if (asset.modelKind == null) {
            _scheduleModelKindClassification([asset]);
            return false;
          }
          if (asset.modelKind != 'animation') return false;
        } else if (asset.effectiveType != 'animation') {
          return false;
        }
      } else if (typeFilter != 'all' && asset.effectiveType != typeFilter) {
        return false;
      }
      if (asset.type == 'model' && modelTextureFilter != 'all') {
        final hasValid = modelHasValidTextures[asset.id];
        if (hasValid == null) {
          _scheduleModelTextureValidation([asset]);
          return false;
        } else if (modelTextureFilter == 'valid' && !hasValid) {
          return false;
        } else if (modelTextureFilter == 'missing' && hasValid) {
          return false;
        }
      }
      if (lower.isEmpty) return true;
      return asset.searchText.contains(lower);
    }).toList();

    _filteredCache = matches;
    _filteredCacheKey = cacheKey;
    return matches;
  }

  /// Invalidate the memoised list after a change that filtering depends on.
  void _invalidateAssetViews() {
    _listEpoch += 1;
  }

  void _scheduleModelTextureValidation([Iterable<AssetItem>? subset]) {
    if (modelTextureFilter == 'all') return;
    final models = (subset ?? assets).where(
      (asset) =>
          asset.type == 'model' &&
          !(hideZipAssets && isZipVirtualPath(asset.path)),
    );
    for (final asset in models) {
      if (modelHasValidTextures.containsKey(asset.id)) continue;
      if (_modelValidationInFlight.contains(asset.id)) continue;
      _modelValidationInFlight.add(asset.id);
      _modelValidationQueue.add(asset);
    }
    unawaited(_processModelValidationQueue());
  }

  /// Classifying an FBX means reading it, so this is deliberately lazy:
  /// assets are classified when something needs the answer, and the result is
  /// persisted so it is paid for once.
  void _scheduleModelKindClassification(Iterable<AssetItem> subset) {
    final pending = <AssetItem>[];
    for (final asset in subset) {
      if (asset.ext != 'fbx' || asset.modelKind != null) continue;
      if (!_modelKindInFlight.add(asset.id)) continue;
      pending.add(asset);
    }
    if (pending.isEmpty) return;
    _modelKindQueue.addAll(pending);
    unawaited(_processModelKindQueue());
  }

  /// Runs classification on worker isolates, several at a time, folding the
  /// answers back in chunks.
  ///
  /// Inflating archive entries is genuine CPU work; doing it inline made the
  /// UI stutter, and applying one result at a time invalidated the filtered
  /// list once per file.
  Future<void> _processModelKindQueue() async {
    if (_processingModelKindQueue) return;
    _processingModelKindQueue = true;

    final helper = meshImporterPath();
    if (!File(helper).existsSync()) {
      _processingModelKindQueue = false;
      _modelKindQueue.clear();
      _modelKindInFlight.clear();
      return;
    }

    while (_modelKindQueue.isNotEmpty) {
      final pending = _modelKindQueue.toList();
      _modelKindQueue.clear();

      final chunks = buildFbxClassifyChunks(
        assets: pending,
        helperPath: helper,
      );
      final total = pending.length;
      var completed = 0;
      var nextChunk = 0;
      var failedChunks = 0;

      Future<void> worker() async {
        while (nextChunk < chunks.length) {
          final chunk = chunks[nextChunk++];
          Map<String, String> kinds;
          try {
            kinds = await runFbxClassifyChunk(chunk);
          } catch (error, stack) {
            // A failure here is ours, not the files'. Recording 'unreadable'
            // would bake a bug into the catalog as a verdict about 400 assets,
            // which is exactly what happened once already: leave them
            // unclassified so a later pass retries them, and say so.
            fbxLog('Classify chunk failed (${chunk.length} assets): $error');
            fbxLog('$stack');
            for (final id in chunk.assetIds) {
              _modelKindInFlight.remove(id);
            }
            failedChunks += 1;
            completed += chunk.length;
            continue;
          }
          completed += chunk.length;
          if (!mounted) return;
          _applyModelKinds(kinds, completed: completed, total: total);
        }
      }

      await Future.wait([
        for (var i = 0; i < _classificationWorkerCount; i += 1) worker(),
      ]);
      _classificationFailures += failedChunks;
      if (!mounted) break;
    }

    _processingModelKindQueue = false;
    if (!mounted) return;
    setState(() {
      status = _classificationFailures > 0
          ? ScanStatus(
              'Classification finished with errors',
              '$_modelKindClassified read, '
                  '$_classificationFailures chunks failed - see '
                  'logs/asset_atlas_fbx.log',
            )
          : ScanStatus(
              'Classification complete',
              '$_modelKindClassified FBX files read',
            );
    });
  }

  /// One rebuild and one database write per chunk, not per asset.
  void _applyModelKinds(
    Map<String, String> kinds, {
    required int completed,
    required int total,
  }) {
    if (kinds.isEmpty) return;
    final byId = {for (final asset in assets) asset.id: asset};
    for (final entry in kinds.entries) {
      byId[entry.key]?.modelKind = entry.value;
      _modelKindInFlight.remove(entry.key);
    }
    _modelKindClassified += kinds.length;

    setState(() {
      _invalidateAssetViews();
      status = ScanStatus(
        'Classifying FBX content',
        '$completed of $total read',
      );
    });

    _persistInBackground(() => db.updateAssetModelKinds(kinds));
  }

  Future<void> _processModelValidationQueue() async {
    if (_processingModelValidationQueue) return;
    _processingModelValidationQueue = true;
    while (_modelValidationQueue.isNotEmpty) {
      // A few at a time: each FBX validation is a subprocess plus a parse, and
      // strictly serial made the filter feel frozen on large catalogs.
      final batch = <AssetItem>[];
      while (batch.length < _maxConcurrentModelValidations &&
          _modelValidationQueue.isNotEmpty) {
        batch.add(_modelValidationQueue.removeFirst());
      }
      await Future.wait(batch.map(_validateModelTexture));
    }
    _processingModelValidationQueue = false;
  }

  Future<void> _validateModelTexture(AssetItem asset) async {
    // Already answered by an earlier pass.
    if (modelHasValidTextures.containsKey(asset.id)) {
      _modelValidationInFlight.remove(asset.id);
      return;
    }

    var hasValidTexture = false;
    try {
      if (asset.ext == 'fbx') {
        final entries = await loadModelTextureReferenceEntries(asset, assets);
        hasValidTexture = entries.any((entry) => entry.resolved);
      } else {
        hasValidTexture = findNearbyTextures(asset, assets).isNotEmpty;
      }
    } catch (_) {
      hasValidTexture = false;
    }

    if (mounted) {
      setState(() {
        modelHasValidTextures[asset.id] = hasValidTexture;
        _invalidateAssetViews();
      });
    }
    _modelValidationInFlight.remove(asset.id);
  }

  @override
  void dispose() {
    _activeScan?.cancel();
    _searchDebounce?.cancel();
    searchController.dispose();
    super.dispose();
  }

  Future<void> _restorePersistedCatalog() async {
    try {
      final snapshot = await db.loadCatalog();
      if (!mounted) return;
      setState(() {
        sourceRoots
          ..clear()
          ..addAll(snapshot.sourceRoots);
        assets
          ..clear()
          ..addAll(snapshot.assets);
        modelHasValidTextures.clear();
        MeshLoadCache.clear();
        ModelThumbnailCache.clear();
        catalogRevision += 1;
        active = assets.isNotEmpty ? assets.first : null;
        _seedHistoryWithActive();
        loadingPersisted = false;
        if (assets.isNotEmpty) {
          status = ScanStatus(
            'Catalog restored',
            '${assets.length} assets loaded from local database',
          );
        } else {
          status = const ScanStatus('Ready', 'Choose a folder to catalog.');
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        loadingPersisted = false;
        status = ScanStatus('Persistence unavailable', error.toString());
      });
    }
  }

  Future<void> _persistCatalog() async {
    if (!widget.enablePersistence) return;
    await db.saveCatalog(assets: assets, sourceRoots: sourceRoots.toList());
  }

  /// Runs a persistence call without blocking the caller, but surfaces a
  /// failure instead of letting it vanish into an unawaited future.
  void _persistInBackground(Future<void> Function() work) {
    if (!widget.enablePersistence) return;
    unawaited(
      work().catchError((Object error) {
        if (!mounted) return;
        setState(() {
          status = ScanStatus('Save failed', error.toString());
        });
      }),
    );
  }

  Future<void> saveProjectSnapshot() async {
    if (!widget.enablePersistence) {
      setState(() {
        status = const ScanStatus(
          'Projects unavailable',
          'Persistence is disabled for this session.',
        );
      });
      return;
    }

    final controller = TextEditingController(text: activeProjectName ?? '');
    final projectName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Project Snapshot'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Project name',
            hintText: 'Example: Jury_Rigs main pass',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (!mounted || projectName == null || projectName.isEmpty) return;

    final existing = await db.findProjectByName(projectName);
    if (!mounted) return;

    final canRenameActiveProject =
        activeProjectId != null && existing?.id == activeProjectId;
    if (existing != null && !canRenameActiveProject) {
      setState(() {
        status = const ScanStatus(
          'Project name already exists',
          'Use a different name or load/update the existing project.',
        );
      });
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final rootPath = sourceRoots.isEmpty ? null : sourceRoots.first;
    final shouldUpdate = activeProjectId != null;
    final projectId = shouldUpdate
        ? activeProjectId!
        : await db.saveProject(
            name: projectName,
            rootPath: rootPath,
            createdMs: now,
          );
    if (shouldUpdate) {
      await db.updateProject(
        projectId: projectId,
        name: projectName,
        rootPath: rootPath,
      );
    }
    await db.replaceProjectAssetIds(
      projectId: projectId,
      assetIds: selectedIds.toList(),
    );

    if (!mounted) return;
    setState(() {
      activeProjectId = projectId;
      activeProjectName = projectName;
      status = ScanStatus(
        shouldUpdate ? 'Project updated' : 'Project saved',
        '$projectName (${selectedIds.length} selected assets)',
      );
    });
  }

  Future<void> loadProjectSnapshot() async {
    if (!widget.enablePersistence) {
      setState(() {
        status = const ScanStatus(
          'Projects unavailable',
          'Persistence is disabled for this session.',
        );
      });
      return;
    }

    while (mounted) {
      final projects = await db.listProjects();
      if (!mounted) return;
      if (projects.isEmpty) {
        setState(() {
          status = const ScanStatus('No projects', 'Save a project first.');
          activeProjectId = null;
          activeProjectName = null;
        });
        return;
      }

      final result = await showDialog<_ProjectDialogResult>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Load Project Snapshot'),
          content: SizedBox(
            width: 560,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: projects.length,
              itemBuilder: (context, index) {
                final project = projects[index];
                final isActive = project.id == activeProjectId;
                return ListTile(
                  title: Text(project.name),
                  subtitle: Text(
                    project.rootPath == null
                        ? 'No root path'
                        : 'Root: ${project.rootPath}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  leading: isActive
                      ? const Icon(Icons.radio_button_checked)
                      : const Icon(Icons.bookmark_border),
                  onTap: () {
                    Navigator.of(context).pop(
                      _ProjectDialogResult(
                        action: _ProjectDialogAction.load,
                        project: project,
                      ),
                    );
                  },
                  trailing: Wrap(
                    spacing: 2,
                    children: [
                      IconButton(
                        tooltip: 'Rename project',
                        onPressed: () {
                          Navigator.of(context).pop(
                            _ProjectDialogResult(
                              action: _ProjectDialogAction.rename,
                              project: project,
                            ),
                          );
                        },
                        icon: const Icon(Icons.drive_file_rename_outline),
                      ),
                      IconButton(
                        tooltip: 'Delete project',
                        onPressed: () {
                          Navigator.of(context).pop(
                            _ProjectDialogResult(
                              action: _ProjectDialogAction.delete,
                              project: project,
                            ),
                          );
                        },
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );

      if (!mounted || result == null) return;
      if (result.action == _ProjectDialogAction.rename) {
        await _renameProject(result.project);
        continue;
      }
      if (result.action == _ProjectDialogAction.delete) {
        await _deleteProject(result.project);
        continue;
      }

      final loadedAssetIds = await db.loadProjectAssetIds(result.project.id);
      if (!mounted) return;
      setState(() {
        selectedIds
          ..clear()
          ..addAll(
            loadedAssetIds.where((id) => assets.any((asset) => asset.id == id)),
          );
        activeProjectId = result.project.id;
        activeProjectName = result.project.name;
        status = ScanStatus(
          'Project loaded',
          '${result.project.name} (${selectedIds.length} selected assets)',
        );
      });
      return;
    }
  }

  Future<void> _renameProject(PersistedProject project) async {
    final controller = TextEditingController(text: project.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Project'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Project name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted ||
        newName == null ||
        newName.isEmpty ||
        newName == project.name) {
      return;
    }

    final duplicate = await db.findProjectByName(newName);
    if (!mounted) return;
    if (duplicate != null && duplicate.id != project.id) {
      setState(() {
        status = const ScanStatus(
          'Project name already exists',
          'Use a unique name before renaming.',
        );
      });
      return;
    }

    await db.updateProject(
      projectId: project.id,
      name: newName,
      rootPath: project.rootPath,
    );
    if (!mounted) return;
    setState(() {
      if (activeProjectId == project.id) {
        activeProjectName = newName;
      }
      status = ScanStatus('Project renamed', '$newName updated successfully.');
    });
  }

  Future<void> _deleteProject(PersistedProject project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Project'),
        content: Text('Delete ${project.name}? This removes saved membership.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    await db.deleteProject(project.id);
    if (!mounted) return;
    setState(() {
      if (activeProjectId == project.id) {
        activeProjectId = null;
        activeProjectName = null;
      }
      status = ScanStatus('Project deleted', '${project.name} removed.');
    });
  }

  void cancelScan() {
    _activeScan?.cancel();
  }

  Future<void> chooseAndScan() async {
    final selectedPath = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose asset folder',
    );
    if (selectedPath == null) return;
    await scanFolder(selectedPath);
  }

  Future<void> scanJuryRigs() async {
    const path = r'W:\GameDevProjects\Jury_Rigs';
    if (!Directory(path).existsSync()) {
      setState(() {
        status = const ScanStatus('Jury_Rigs not found', path);
      });
      return;
    }
    await scanFolder(path);
  }

  Future<void> scanFolder(String rootPath) async {
    if (scanning) return;
    setState(() {
      scanning = true;
      status = ScanStatus('Scanning', rootPath);
    });

    // Off the UI isolate: this walks a whole tree and inflates every archive
    // it meets, which used to lock the window for the duration.
    final handle = await startFolderScan(
      rootPath,
      onStatus: (next) {
        if (!mounted) return;
        setState(() => status = next);
      },
    );
    _activeScan = handle;

    final ScanResult result;
    try {
      result = await handle.result;
    } on ScanCancelledException {
      if (!mounted) return;
      setState(() {
        scanning = false;
        _activeScan = null;
        status = ScanStatus('Scan cancelled', rootPath);
      });
      return;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        scanning = false;
        _activeScan = null;
        status = ScanStatus('Scan failed', error.toString());
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _activeScan = null;
      sourceRoots.add(rootPath);
      assets.removeWhere((asset) => asset.sourceRoot == rootPath);
      assets.addAll(result.assets);
      MeshLoadCache.clear();
      ModelThumbnailCache.clear();
      catalogRevision += 1;
      modelHasValidTextures.removeWhere(
        (assetId, _) => !assets.any((asset) => asset.id == assetId),
      );
      _modelValidationInFlight.removeWhere(
        (assetId) => !assets.any((asset) => asset.id == assetId),
      );
      _modelValidationQueue.removeWhere(
        (asset) => !assets.any((existing) => existing.id == asset.id),
      );
      active = result.assets.isNotEmpty ? result.assets.first : active;
      _pruneHistoryToVisibleAssets();
      scanning = false;
      status = ScanStatus(
        'Scan complete',
        '${result.assets.length} cataloged, ${result.skippedUnsupported} skipped, ${result.skippedBinaryObj} binary OBJ ignored',
      );
    });
    if (modelTextureFilter != 'all') {
      _scheduleModelTextureValidation(result.assets);
    }
    await _persistCatalog();
  }

  void removeSource(String rootPath) {
    setState(() {
      sourceRoots.remove(rootPath);
      assets.removeWhere((asset) => asset.sourceRoot == rootPath);
      MeshLoadCache.clear();
      ModelThumbnailCache.clear();
      catalogRevision += 1;
      modelHasValidTextures.removeWhere(
        (assetId, _) => !assets.any((asset) => asset.id == assetId),
      );
      _modelValidationInFlight.removeWhere(
        (assetId) => !assets.any((asset) => asset.id == assetId),
      );
      _modelValidationQueue.removeWhere(
        (asset) => !assets.any((existing) => existing.id == asset.id),
      );
      selectedIds.removeWhere((id) => !assets.any((asset) => asset.id == id));
      if (active?.sourceRoot == rootPath) {
        active = assets.isEmpty ? null : assets.first;
      }
      _pruneHistoryToVisibleAssets();
    });
    _persistInBackground(() => db.deleteAssetsForSourceRoot(rootPath));
  }

  Future<void> copySelected() async {
    final selected = assets
        .where((asset) => selectedIds.contains(asset.id))
        .toList();
    if (selected.isEmpty) return;
    final target = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose target folder',
    );
    if (target == null) return;

    try {
      final report = await copyAssetsToTarget(selected, target);
      if (!mounted) return;
      setState(() {
        status = ScanStatus(
          report.failedCount > 0 ? 'Copied with errors' : 'Copied assets',
          '${report.summaryLine} · target: $target',
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        status = ScanStatus('Copy failed', error.toString());
      });
    }
  }

  /// Arrow keys walk the visible list, so you can flick through candidates
  /// without moving the mouse back to the list for every one.
  void _stepActiveAsset(int delta) {
    final visible = filteredAssets;
    if (visible.isEmpty) return;
    final currentIndex = active == null
        ? -1
        : visible.indexWhere((asset) => asset.id == active!.id);
    final nextIndex = currentIndex < 0
        ? (delta > 0 ? 0 : visible.length - 1)
        : (currentIndex + delta).clamp(0, visible.length - 1);
    if (nextIndex == currentIndex) return;
    _activateAsset(visible[nextIndex]);
  }

  /// A scan of 48k assets costs tens of milliseconds, so run it when typing
  /// pauses rather than on every character.
  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    if (value.isEmpty) {
      setState(() => query = '');
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() => query = value);
    });
  }

  /// Marks the images a model actually uses, so they show as textures.
  ///
  /// Only what the model itself resolved counts: a folder name is a guess,
  /// this is evidence.
  Future<void> _recordTexturesUsedBy(AssetItem model) async {
    try {
      final mesh = await MeshLoadCache.load(model, allAssets: assets);
      final used = <String>{
        for (final material in mesh.materials)
          for (final path in material.resolvedTextures) normalizePathKey(path),
      };
      if (used.isEmpty) return;

      final newlyMarked = <String>[];
      for (final asset in assets) {
        if (asset.referencedByModel) continue;
        if (used.contains(normalizePathKey(asset.path))) {
          asset.referencedByModel = true;
          newlyMarked.add(asset.id);
        }
      }
      if (newlyMarked.isEmpty || !mounted) return;
      setState(_invalidateAssetViews);
      _persistInBackground(() => db.markAssetsReferencedByModel(newlyMarked));
    } catch (_) {
      // A model that will not import tells us nothing about textures.
    }
  }

  void _selectAll(List<AssetItem> visible) {
    setState(() {
      selectedIds.addAll(visible.map((asset) => asset.id));
    });
  }

  void _clearSelection() {
    setState(() {
      selectedIds.clear();
      _lastSelectionAnchorId = null;
    });
  }

  /// Shift-click extends from the last clicked row, the way every file browser
  /// behaves. Without it, selecting a run of assets means one click each.
  void _selectWithRange(AssetItem asset, bool selected, {bool range = false}) {
    final visible = filteredAssets;
    if (range && _lastSelectionAnchorId != null) {
      final anchorIndex = visible.indexWhere(
        (item) => item.id == _lastSelectionAnchorId,
      );
      final targetIndex = visible.indexWhere((item) => item.id == asset.id);
      if (anchorIndex >= 0 && targetIndex >= 0) {
        final start = math.min(anchorIndex, targetIndex);
        final end = math.max(anchorIndex, targetIndex);
        setState(() {
          for (var i = start; i <= end; i += 1) {
            if (selected) {
              selectedIds.add(visible[i].id);
            } else {
              selectedIds.remove(visible[i].id);
            }
          }
        });
        return;
      }
    }
    _lastSelectionAnchorId = asset.id;
    toggleSelected(asset, selected);
  }

  void toggleSelected(AssetItem asset, bool selected) {
    setState(() {
      if (selected) {
        selectedIds.add(asset.id);
      } else {
        selectedIds.remove(asset.id);
      }
    });
  }

  void setIgnored(AssetItem asset, bool ignored) {
    final changed = <AssetItem>[];
    setState(() {
      final selected = selectedIds.contains(asset.id)
          ? assets.where((item) => selectedIds.contains(item.id))
          : [asset];
      for (final item in selected) {
        item.ignored = ignored;
        changed.add(item);
      }
      _invalidateAssetViews();
    });
    // One UPDATE per changed asset, not a rewrite of the whole catalog.
    _persistInBackground(() async {
      for (final item in changed) {
        await db.updateAssetIgnored(assetId: item.id, ignored: item.ignored);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = filteredAssets;
    // FBX files nothing has read yet, so the animation count is a lower bound.
    final unclassifiedFbxCount = assets
        .where((asset) => asset.ext == 'fbx' && asset.modelKind == null)
        .length;
    final counts = {
      'all': assets.length,
      'image': assets.where((asset) => asset.effectiveType == 'image').length,
      'texture': assets
          .where((asset) => asset.effectiveType == 'texture')
          .length,
      'model': assets.where((asset) => asset.effectiveType == 'model').length,
      'animation': assets
          .where((asset) => asset.effectiveType == 'animation')
          .length,
      'audio': assets.where((asset) => asset.effectiveType == 'audio').length,
    };

    return Scaffold(
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              _stepActiveAsset(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              _stepActiveAsset(-1),
        },
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              HeaderBar(
                scanning: scanning,
                status: status,
                canGoBack: canGoBackInHistory,
                canGoForward: canGoForwardInHistory,
                onScan: chooseAndScan,
                onCancelScan: cancelScan,
                onSaveProject: saveProjectSnapshot,
                onLoadProject: loadProjectSnapshot,
                onCopySelected: copySelected,
                onGoBack: _goBackHistory,
                onGoForward: _goForwardHistory,
                selectedCount: selectedIds.length,
              ),
              Expanded(
                child: Row(
                  children: [
                    FilterPanel(
                      width: filterPanelWidth,
                      counts: counts,
                      unclassifiedFbxCount: unclassifiedFbxCount,
                      typeFilter: typeFilter,
                      modelTextureFilter: modelTextureFilter,
                      hideIgnored: hideIgnored,
                      hideZipAssets: hideZipAssets,
                      sourceRoots: sourceRoots.toList()..sort(),
                      folderRoots: folderRoots,
                      selectedFolder: folderFilter,
                      expandedFolders: expandedFolders,
                      onFolderSelected: (value) =>
                          setState(() => folderFilter = value),
                      onFolderExpandToggled: (path) {
                        setState(() {
                          if (!expandedFolders.remove(path)) {
                            expandedFolders.add(path);
                          }
                        });
                      },
                      onTypeChanged: (value) => setState(() {
                        typeFilter = value;
                        // A query typed against one type almost never means
                        // anything against the next, and leaving it set makes
                        // the new type look empty.
                        searchController.clear();
                        _onSearchChanged('');
                      }),
                      onModelTextureFilterChanged: (value) {
                        setState(() {
                          modelTextureFilter = value;
                          if (value == 'all') {
                            _modelValidationQueue.clear();
                            _modelValidationInFlight.clear();
                          }
                        });
                        if (value != 'all') {
                          _scheduleModelTextureValidation();
                        }
                      },
                      onHideIgnoredChanged: (value) =>
                          setState(() => hideIgnored = value),
                      onHideZipAssetsChanged: (value) {
                        setState(() {
                          hideZipAssets = value;
                          if (value &&
                              active != null &&
                              isZipVirtualPath(active!.path)) {
                            active = assets
                                .where((asset) => !isZipVirtualPath(asset.path))
                                .firstOrNull;
                            _seedHistoryWithActive();
                          }
                          if (value) {
                            _modelValidationQueue.removeWhere(
                              (asset) => isZipVirtualPath(asset.path),
                            );
                          }
                        });
                      },
                      onRemoveSource: removeSource,
                    ),
                    VerticalResizeHandle(
                      onDrag: (delta) {
                        setState(() {
                          filterPanelWidth = (filterPanelWidth + delta)
                              .clamp(200.0, 520.0)
                              .toDouble();
                        });
                      },
                    ),
                    // The browse list gets its own full-height column: as a bottom
                    // strip it showed a handful of rows out of tens of thousands.
                    SizedBox(
                      width: assetListWidth,
                      child: Column(
                        children: [
                          SearchAndSummary(
                            controller: searchController,
                            visibleCount: visible.length,
                            totalCount: assets.length,
                            selectedCount: selectedIds.length,
                            sortMode: sortMode,
                            gridMode: gridMode,
                            onChanged: _onSearchChanged,
                            onSortChanged: (value) =>
                                setState(() => sortMode = value),
                            onGridModeChanged: (value) =>
                                setState(() => gridMode = value),
                            onSelectAllVisible: () => _selectAll(visible),
                            onClearSelection: _clearSelection,
                          ),
                          Expanded(
                            child: gridMode
                                ? AssetGrid(
                                    assets: visible,
                                    active: active,
                                    selectedIds: selectedIds,
                                    onActivate: _activateAsset,
                                    onSelect: _selectWithRange,
                                  )
                                : AssetList(
                                    assets: visible,
                                    active: active,
                                    selectedIds: selectedIds,
                                    onActivate: _activateAsset,
                                    onSelect: _selectWithRange,
                                    onIgnoredChanged: setIgnored,
                                  ),
                          ),
                        ],
                      ),
                    ),
                    VerticalResizeHandle(
                      onDrag: (delta) {
                        setState(() {
                          assetListWidth = (assetListWidth - delta)
                              .clamp(280.0, 900.0)
                              .toDouble();
                        });
                      },
                    ),
                    Expanded(
                      child: PreviewPanel(
                        asset: active,
                        allAssets: assets,
                        catalogRevision: catalogRevision,
                        onActivateAsset: _activateAsset,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ListResizeHandle extends StatelessWidget {
  const ListResizeHandle({required this.onDrag, super.key});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
        child: Container(
          height: 12,
          decoration: BoxDecoration(
            color: const Color(0xffeef1f6),
            border: Border(
              top: BorderSide(color: Colors.black.withValues(alpha: .08)),
              bottom: BorderSide(color: Colors.black.withValues(alpha: .08)),
            ),
          ),
          child: Center(
            child: Container(
              width: 42,
              height: 3,
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HeaderBar extends StatelessWidget {
  const HeaderBar({
    required this.scanning,
    required this.status,
    required this.canGoBack,
    required this.canGoForward,
    required this.onScan,
    required this.onCancelScan,
    required this.onSaveProject,
    required this.onLoadProject,
    required this.onCopySelected,
    required this.onGoBack,
    required this.onGoForward,
    required this.selectedCount,
    super.key,
  });

  final bool scanning;
  final ScanStatus status;
  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback onScan;
  final VoidCallback onCancelScan;
  final VoidCallback onSaveProject;
  final VoidCallback onLoadProject;
  final VoidCallback onCopySelected;
  final VoidCallback onGoBack;
  final VoidCallback onGoForward;
  final int selectedCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: Colors.black.withValues(alpha: .08)),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final title = _HeaderTitle();
          final statusView = _StatusView(status: status, scanning: scanning);
          final actions = _HeaderActions(
            scanning: scanning,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            selectedCount: selectedCount,
            onScan: onScan,
            onCancelScan: onCancelScan,
            onSaveProject: onSaveProject,
            onLoadProject: onLoadProject,
            onCopySelected: onCopySelected,
            onGoBack: onGoBack,
            onGoForward: onGoForward,
          );

          if (constraints.maxWidth < 1080) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    title,
                    const SizedBox(width: 18),
                    Expanded(child: statusView),
                  ],
                ),
                const SizedBox(height: 10),
                actions,
              ],
            );
          }

          return Row(
            children: [
              title,
              const SizedBox(width: 24),
              Expanded(child: statusView),
              const SizedBox(width: 14),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _HeaderTitle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.inventory_2_outlined, size: 28),
        SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Asset Atlas Native · v$appVersion',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            Text(
              'Native scanner and asset browser',
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatusView extends StatelessWidget {
  const _StatusView({required this.status, required this.scanning});

  final ScanStatus status;
  final bool scanning;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(status.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: scanning ? null : 1),
        const SizedBox(height: 4),
        Text(
          status.detail,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
      ],
    );
  }
}

class _HeaderActions extends StatelessWidget {
  const _HeaderActions({
    required this.scanning,
    required this.canGoBack,
    required this.canGoForward,
    required this.selectedCount,
    required this.onScan,
    required this.onCancelScan,
    required this.onSaveProject,
    required this.onLoadProject,
    required this.onCopySelected,
    required this.onGoBack,
    required this.onGoForward,
  });

  final bool scanning;
  final bool canGoBack;
  final bool canGoForward;
  final int selectedCount;
  final VoidCallback onScan;
  final VoidCallback onCancelScan;
  final VoidCallback onSaveProject;
  final VoidCallback onLoadProject;
  final VoidCallback onCopySelected;
  final VoidCallback onGoBack;
  final VoidCallback onGoForward;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        IconButton(
          tooltip: 'Previous asset',
          onPressed: canGoBack ? onGoBack : null,
          icon: const Icon(Icons.arrow_back),
        ),
        IconButton(
          tooltip: 'Next asset',
          onPressed: canGoForward ? onGoForward : null,
          icon: const Icon(Icons.arrow_forward),
        ),
        if (scanning)
          FilledButton.icon(
            onPressed: onCancelScan,
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Stop scan'),
          )
        else
          FilledButton.icon(
            onPressed: onScan,
            icon: const Icon(Icons.folder_open),
            label: const Text('Scan folder'),
          ),
        OutlinedButton.icon(
          onPressed: scanning ? null : onSaveProject,
          icon: const Icon(Icons.save_outlined),
          label: const Text('Save project'),
        ),
        OutlinedButton.icon(
          onPressed: scanning ? null : onLoadProject,
          icon: const Icon(Icons.bookmarks_outlined),
          label: const Text('Load project'),
        ),
        OutlinedButton.icon(
          onPressed: selectedCount == 0 ? null : onCopySelected,
          icon: const Icon(Icons.copy_all_outlined),
          label: Text('Copy $selectedCount'),
        ),
      ],
    );
  }
}

/// One folder in the browse tree, with the number of assets at or below it.
class FolderNode {
  FolderNode({required this.name, required this.path});

  final String name;

  /// Full prefix as it appears in [AssetItem.relativePath], with no trailing
  /// separator. Filtering is a prefix match on this.
  final String path;

  int assetCount = 0;
  final Map<String, FolderNode> childrenByName = <String, FolderNode>{};

  List<FolderNode> get sortedChildren {
    final children = childrenByName.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return children;
  }
}

/// Builds the folder hierarchy from asset relative paths.
///
/// A flat list of tens of thousands of assets cannot be browsed by location,
/// and search only helps when you already know the name.
List<FolderNode> buildFolderTree(List<AssetItem> assets) {
  final roots = <String, FolderNode>{};
  for (final asset in assets) {
    final segments = asset.relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.length < 2) continue; // file sitting directly at the root
    segments.removeLast(); // drop the file name

    var levelMap = roots;
    final walked = <String>[];
    for (final segment in segments) {
      walked.add(segment);
      final node = levelMap.putIfAbsent(
        segment,
        () => FolderNode(name: segment, path: walked.join('/')),
      );
      node.assetCount += 1;
      levelMap = node.childrenByName;
    }
  }
  final sorted = roots.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return sorted;
}

/// True when [relativePath] sits at or below [folderPath].
bool isUnderFolder(String relativePath, String folderPath) {
  if (folderPath.isEmpty) return true;
  final normalized = relativePath.replaceAll('\\', '/');
  return normalized == folderPath || normalized.startsWith('$folderPath/');
}

class FolderTreeView extends StatelessWidget {
  const FolderTreeView({
    required this.roots,
    required this.selectedFolder,
    required this.expandedFolders,
    required this.onSelect,
    required this.onToggleExpanded,
    super.key,
  });

  final List<FolderNode> roots;
  final String? selectedFolder;
  final Set<String> expandedFolders;
  final ValueChanged<String?> onSelect;
  final ValueChanged<String> onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    if (roots.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text('No folders yet.', style: TextStyle(color: Colors.black54)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FolderRow(
          label: 'All folders',
          count: null,
          depth: 0,
          selected: selectedFolder == null,
          expandable: false,
          expanded: false,
          onTap: () => onSelect(null),
          onToggleExpanded: () {},
        ),
        for (final root in roots) ..._buildNode(root, 0),
      ],
    );
  }

  List<Widget> _buildNode(FolderNode node, int depth) {
    final expanded = expandedFolders.contains(node.path);
    return [
      _FolderRow(
        label: node.name,
        count: node.assetCount,
        depth: depth,
        selected: selectedFolder == node.path,
        expandable: node.childrenByName.isNotEmpty,
        expanded: expanded,
        onTap: () => onSelect(node.path),
        onToggleExpanded: () => onToggleExpanded(node.path),
      ),
      if (expanded)
        for (final child in node.sortedChildren)
          ..._buildNode(child, depth + 1),
    ];
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.label,
    required this.count,
    required this.depth,
    required this.selected,
    required this.expandable,
    required this.expanded,
    required this.onTap,
    required this.onToggleExpanded,
  });

  final String label;
  final int? count;
  final int depth;
  final bool selected;
  final bool expandable;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: .55)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.only(left: depth * 12.0, top: 1, bottom: 1),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                child: expandable
                    ? InkWell(
                        onTap: onToggleExpanded,
                        child: Icon(
                          expanded
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_right,
                          size: 16,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              Expanded(
                child: Tooltip(
                  message: label,
                  waitDuration: const Duration(milliseconds: 700),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ),
              if (count != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4, right: 2),
                  child: Text(
                    '$count',
                    style: const TextStyle(fontSize: 11, color: Colors.black45),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class FilterPanel extends StatelessWidget {
  const FilterPanel({
    required this.width,
    required this.counts,
    required this.unclassifiedFbxCount,
    required this.typeFilter,
    required this.modelTextureFilter,
    required this.hideIgnored,
    required this.hideZipAssets,
    required this.sourceRoots,
    required this.folderRoots,
    required this.selectedFolder,
    required this.expandedFolders,
    required this.onFolderSelected,
    required this.onFolderExpandToggled,
    required this.onTypeChanged,
    required this.onModelTextureFilterChanged,
    required this.onHideIgnoredChanged,
    required this.onHideZipAssetsChanged,
    required this.onRemoveSource,
    super.key,
  });

  final double width;
  final Map<String, int> counts;
  final int unclassifiedFbxCount;
  final String typeFilter;
  final String modelTextureFilter;
  final bool hideIgnored;
  final bool hideZipAssets;
  final List<String> sourceRoots;
  final List<FolderNode> folderRoots;
  final String? selectedFolder;
  final Set<String> expandedFolders;
  final ValueChanged<String?> onFolderSelected;
  final ValueChanged<String> onFolderExpandToggled;
  final ValueChanged<String> onTypeChanged;
  final ValueChanged<String> onModelTextureFilterChanged;
  final ValueChanged<bool> onHideIgnoredChanged;
  final ValueChanged<bool> onHideZipAssetsChanged;
  final ValueChanged<String> onRemoveSource;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Material(
        color: const Color(0xfff7f8fb),
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            const Text('Types', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final type in [
              'all',
              'image',
              'texture',
              'model',
              'animation',
              'audio',
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Tooltip(
                  message: type == 'animation' && unclassifiedFbxCount > 0
                      ? '$unclassifiedFbxCount FBX files have not been read '
                            'yet. Pick this filter to classify them.'
                      : '',
                  child: ChoiceChip(
                    selected: typeFilter == type,
                    // "(0)" would claim there are no animation clips when in
                    // fact nothing has looked yet.
                    label: Text(
                      type == 'animation' && unclassifiedFbxCount > 0
                          ? 'ANIMATION (${counts[type] ?? 0}+)'
                          : '${type.toUpperCase()} (${counts[type] ?? 0})',
                    ),
                    onSelected: (_) => onTypeChanged(type),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            const Text(
              'Model textures',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (final filter in ['all', 'valid', 'missing'])
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ChoiceChip(
                  selected: modelTextureFilter == filter,
                  label: Text(
                    filter == 'all'
                        ? 'All models'
                        : filter == 'valid'
                        ? 'With valid textures'
                        : 'Without valid textures',
                  ),
                  onSelected: (_) => onModelTextureFilterChanged(filter),
                ),
              ),
            const Divider(height: 28),
            CheckboxListTile(
              dense: true,
              value: hideIgnored,
              contentPadding: EdgeInsets.zero,
              title: const Text('Hide ignored'),
              onChanged: (value) => onHideIgnoredChanged(value ?? true),
            ),
            CheckboxListTile(
              dense: true,
              value: hideZipAssets,
              contentPadding: EdgeInsets.zero,
              title: const Text('Hide ZIP contents'),
              subtitle: const Text('Exclude assets indexed inside archives'),
              onChanged: (value) => onHideZipAssetsChanged(value ?? true),
            ),
            const Divider(height: 28),
            const Text(
              'Folders',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            FolderTreeView(
              roots: folderRoots,
              selectedFolder: selectedFolder,
              expandedFolders: expandedFolders,
              onSelect: onFolderSelected,
              onToggleExpanded: onFolderExpandToggled,
            ),
            const Divider(height: 28),
            const Text(
              'Source Folders',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (sourceRoots.isEmpty)
              const Text(
                'No folders scanned yet.',
                style: TextStyle(color: Colors.black54),
              ),
            for (final root in sourceRoots)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: CopyablePathText(path: root)),
                    IconButton(
                      tooltip: 'Remove source',
                      icon: const Icon(Icons.close, size: 18),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: () => onRemoveSource(root),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ViewModeButton extends StatelessWidget {
  const _ViewModeButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      style: IconButton.styleFrom(
        backgroundColor: selected ? scheme.primaryContainer : null,
        foregroundColor: selected ? scheme.onPrimaryContainer : Colors.black54,
      ),
      icon: Icon(icon, size: 20),
    );
  }
}

class SearchAndSummary extends StatelessWidget {
  const SearchAndSummary({
    required this.controller,
    required this.visibleCount,
    required this.totalCount,
    required this.selectedCount,
    required this.sortMode,
    required this.gridMode,
    required this.onChanged,
    required this.onSortChanged,
    required this.onGridModeChanged,
    required this.onSelectAllVisible,
    required this.onClearSelection,
    super.key,
  });

  final TextEditingController controller;
  final int visibleCount;
  final int totalCount;
  final int selectedCount;
  final AssetSortMode sortMode;
  final bool gridMode;
  final ValueChanged<String> onChanged;
  final ValueChanged<AssetSortMode> onSortChanged;
  final ValueChanged<bool> onGridModeChanged;
  final VoidCallback onSelectAllVisible;
  final VoidCallback onClearSelection;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search name, folder, or tag',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: controller.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              controller.clear();
                              onChanged('');
                            },
                          ),
                  ),
                  onChanged: onChanged,
                ),
              ),
              const SizedBox(width: 6),
              // List and grid answer different questions: "which file is this"
              // versus "which one looks right".
              // Two IconButtons rather than ToggleButtons: a Tooltip placed
              // as a direct child of ToggleButtons corrupts the Windows
              // accessibility tree, and the app then hard-crashes inside
              // flutter_windows.dll on the next window resize. IconButton's
              // own tooltip is safe and is what the rest of the app uses.
              _ViewModeButton(
                icon: Icons.view_list,
                tooltip: 'List view',
                selected: !gridMode,
                onPressed: () => onGridModeChanged(false),
              ),
              _ViewModeButton(
                icon: Icons.grid_view,
                tooltip: 'Thumbnail grid',
                selected: gridMode,
                onPressed: () => onGridModeChanged(true),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                '$visibleCount / $totalCount',
                style: const TextStyle(color: Colors.black54),
              ),
              const SizedBox(width: 10),
              DropdownButtonHideUnderline(
                child: DropdownButton<AssetSortMode>(
                  value: sortMode,
                  isDense: true,
                  focusColor: Colors.transparent,
                  items: [
                    for (final mode in AssetSortMode.values)
                      DropdownMenuItem(
                        value: mode,
                        child: Text(
                          'Sort: ${mode.label}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                  ],
                  onChanged: (next) {
                    if (next != null) onSortChanged(next);
                  },
                ),
              ),
              const Spacer(),
              if (visibleCount > 0)
                TextButton(
                  onPressed: onSelectAllVisible,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Select all'),
                ),
              if (selectedCount > 0)
                TextButton(
                  onPressed: onClearSelection,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text('Clear ($selectedCount)'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Icon shown for an asset's kind, used by both the list and the grid.
IconData iconForAssetType(String effectiveType) => switch (effectiveType) {
  'image' => Icons.image_outlined,
  'texture' => Icons.texture,
  'audio' => Icons.graphic_eq,
  'animation' => Icons.directions_run,
  'model' => Icons.view_in_ar_outlined,
  _ => Icons.insert_drive_file_outlined,
};

typedef AssetSelectCallback =
    void Function(AssetItem asset, bool selected, {bool range});

class AssetList extends StatelessWidget {
  const AssetList({
    required this.assets,
    required this.active,
    required this.selectedIds,
    required this.onActivate,
    required this.onSelect,
    required this.onIgnoredChanged,
    super.key,
  });

  final List<AssetItem> assets;
  final AssetItem? active;
  final Set<String> selectedIds;
  final ValueChanged<AssetItem> onActivate;
  final AssetSelectCallback onSelect;
  final void Function(AssetItem asset, bool ignored) onIgnoredChanged;

  @override
  Widget build(BuildContext context) {
    if (assets.isEmpty) {
      return const Center(child: Text('Scan a folder to catalog assets.'));
    }

    return ListView.builder(
      itemCount: assets.length,
      itemBuilder: (context, index) {
        final asset = assets[index];
        final isActive = active?.id == asset.id;
        final isSelected = selectedIds.contains(asset.id);
        return Material(
          color: isActive
              ? Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: .55)
              : Colors.transparent,
          child: InkWell(
            onTap: () => onActivate(asset),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Row(
                children: [
                  Tooltip(
                    message: isSelected
                        ? 'Selected for copy'
                        : 'Select for copy (shift-click for a range)',
                    child: Checkbox(
                      value: isSelected,
                      visualDensity: VisualDensity.compact,
                      onChanged: (value) => onSelect(
                        asset,
                        value ?? false,
                        range: HardwareKeyboard.instance.isShiftPressed,
                      ),
                    ),
                  ),
                  Icon(
                    iconForAssetType(asset.effectiveType),
                    size: 18,
                    color: Colors.black54,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          asset.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: isActive
                                ? FontWeight.w600
                                : FontWeight.normal,
                            decoration: asset.ignored
                                ? TextDecoration.lineThrough
                                : null,
                            color: asset.ignored ? Colors.black45 : null,
                          ),
                        ),
                        Tooltip(
                          message: asset.path,
                          waitDuration: const Duration(milliseconds: 600),
                          child: Text(
                            asset.relativePath,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black54,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    asset.ext.toUpperCase(),
                    style: const TextStyle(fontSize: 11, color: Colors.black45),
                  ),
                  // An eye reads as "hidden", where a second unlabelled
                  // checkbox next to the select box did not.
                  IconButton(
                    tooltip: asset.ignored
                        ? 'Ignored - click to un-ignore'
                        : 'Ignore this asset',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    icon: Icon(
                      asset.ignored
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 17,
                      color: asset.ignored ? Colors.black87 : Colors.black26,
                    ),
                    onPressed: () => onIgnoredChanged(asset, !asset.ignored),
                  ),
                  IconButton(
                    tooltip: 'Copy asset path',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    icon: const Icon(Icons.content_copy, size: 15),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: asset.path));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Asset path copied.')),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Thumbnail grid. Recognising an asset by eye is most of what this app is
/// for, and a column of filenames does not support that.
class AssetGrid extends StatelessWidget {
  const AssetGrid({
    required this.assets,
    required this.active,
    required this.selectedIds,
    required this.onActivate,
    required this.onSelect,
    super.key,
  });

  final List<AssetItem> assets;
  final AssetItem? active;
  final Set<String> selectedIds;
  final ValueChanged<AssetItem> onActivate;
  final AssetSelectCallback onSelect;

  @override
  Widget build(BuildContext context) {
    if (assets.isEmpty) {
      return const Center(child: Text('Scan a folder to catalog assets.'));
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.82,
      ),
      itemCount: assets.length,
      itemBuilder: (context, index) {
        final asset = assets[index];
        final isSelected = selectedIds.contains(asset.id);
        return AssetGridTile(
          asset: asset,
          allAssets: assets,
          isActive: active?.id == asset.id,
          isSelected: isSelected,
          onActivate: () => onActivate(asset),
          onToggleSelected: () => onSelect(
            asset,
            !isSelected,
            range: HardwareKeyboard.instance.isShiftPressed,
          ),
        );
      },
    );
  }
}

class AssetGridTile extends StatelessWidget {
  const AssetGridTile({
    required this.asset,
    required this.allAssets,
    required this.isActive,
    required this.isSelected,
    required this.onActivate,
    required this.onToggleSelected,
    super.key,
  });

  final AssetItem asset;
  final List<AssetItem> allAssets;
  final bool isActive;
  final bool isSelected;
  final VoidCallback onActivate;
  final VoidCallback onToggleSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: asset.relativePath,
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: isActive
            ? scheme.primaryContainer.withValues(alpha: .5)
            : const Color(0xfff4f6fa),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onActivate,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isActive ? scheme.primary : Colors.black12,
                width: isActive ? 2 : 1,
              ),
            ),
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: AssetThumbnail(
                            asset: asset,
                            allAssets: allAssets,
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        child: Checkbox(
                          value: isSelected,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onChanged: (_) => onToggleSelected(),
                        ),
                      ),
                      if (asset.ignored)
                        const Positioned(
                          top: 4,
                          right: 4,
                          child: Icon(
                            Icons.visibility_off_outlined,
                            size: 16,
                            color: Colors.black45,
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                  child: Text(
                    asset.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      decoration: asset.ignored
                          ? TextDecoration.lineThrough
                          : null,
                      color: asset.ignored ? Colors.black45 : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders small previews of models for the grid, and remembers them.
///
/// A grid of file-type icons does not answer "which one is the crate", which
/// is the whole reason to look at a grid. Rendering costs an FBX import, so
/// this is strictly on demand: only tiles that are actually built ask for one,
/// a couple render at a time, and results are kept in a bounded cache.
class ModelThumbnailCache {
  ModelThumbnailCache._();

  static const size = 128;
  static const maxEntries = 300;
  static const _maxConcurrent = 2;

  /// Requests waiting to render. Beyond this the oldest are dropped: they are
  /// almost certainly off screen by now, and asking again is cheap.
  static const maxQueued = 48;

  /// Rendering a thumbnail means importing the model. Turn this off to keep
  /// the grid to plain type icons -- tests do, so that unrelated widget tests
  /// are not dragged into FBX imports.
  static bool enabled = true;

  static final _entries = <String, ui.Image?>{};
  static final _pending = <String>{};
  static final _queue = Queue<_ThumbnailRequest>();
  static var _running = 0;

  /// Bumped whenever a thumbnail lands, so grids can rebuild.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Rendered thumbnails started. Test visibility only.
  static int renderCount = 0;

  /// Returns the cached image, or null and schedules a render.
  static ui.Image? imageFor(AssetItem asset, List<AssetItem> allAssets) {
    if (!enabled) return null;
    final cached = _entries.remove(asset.id);
    if (cached != null) {
      _entries[asset.id] = cached;
      return cached;
    }
    if (_entries.containsKey(asset.id)) {
      // Known to be unrenderable; do not keep trying.
      return null;
    }
    if (_pending.add(asset.id)) {
      // Newest first: while scrolling, the tile you are looking at now matters
      // more than one you flew past. An unbounded queue would keep rendering
      // thousands of thumbnails nobody can see any more.
      _queue.addFirst(_ThumbnailRequest(asset, allAssets));
      while (_queue.length > maxQueued) {
        _pending.remove(_queue.removeLast().asset.id);
      }
      unawaited(_drain());
    }
    return null;
  }

  static Future<void> _drain() async {
    if (_running >= _maxConcurrent || _queue.isEmpty) return;
    _running += 1;
    while (_queue.isNotEmpty) {
      final request = _queue.removeFirst();
      ui.Image? image;
      try {
        renderCount += 1;
        image = await renderModelThumbnail(
          request.asset,
          allAssets: request.allAssets,
        );
      } catch (_) {
        image = null;
      }
      _entries[request.asset.id] = image;
      _pending.remove(request.asset.id);
      while (_entries.length > maxEntries) {
        final oldest = _entries.keys.first;
        _entries.remove(oldest)?.dispose();
      }
      revision.value += 1;
    }
    _running -= 1;
  }

  /// Test visibility: how many requests are waiting.
  static int get queuedCount => _queue.length;

  static void clear() {
    for (final image in _entries.values) {
      image?.dispose();
    }
    _entries.clear();
    _pending.clear();
    _queue.clear();
    revision.value += 1;
  }
}

class _ThumbnailRequest {
  const _ThumbnailRequest(this.asset, this.allAssets);
  final AssetItem asset;
  final List<AssetItem> allAssets;
}

/// Draws one model into a square image with the same painter the preview uses,
/// so a thumbnail looks like what you get when you click it.
Future<ui.Image?> renderModelThumbnail(
  AssetItem asset, {
  List<AssetItem> allAssets = const [],
  int size = ModelThumbnailCache.size,
}) async {
  final mesh = await MeshLoadCache.load(asset, allAssets: allAssets);
  if (mesh.isAnimationOnly || mesh.faces.isEmpty) return null;

  // Same rasteriser as the preview, so a thumbnail matches what you get when
  // you click it -- including depth-correct overlaps.
  final raster = rasterizeMesh(
    mesh: mesh,
    yaw: -0.6,
    pitch: 0.35,
    zoom: 1,
    width: size,
    height: size,
    renderMode: RenderMode.textured,
    lightingMode: LightingMode.corner,
    cullBackFaces: true,
    backgroundArgb: 0x00000000,
  );
  return imageFromRaster(raster);
}

/// Image thumbnails are decoded at tile size, not full size: a 4K texture
/// atlas decoded per tile would exhaust memory in a grid of any size.
class AssetThumbnail extends StatelessWidget {
  const AssetThumbnail({
    required this.asset,
    this.allAssets = const [],
    super.key,
  });

  final AssetItem asset;
  final List<AssetItem> allAssets;

  static const _decodeWidth = 160;

  @override
  Widget build(BuildContext context) {
    if (asset.type == 'model' && asset.modelKind != 'animation') {
      return ModelThumbnail(asset: asset, allAssets: allAssets);
    }
    if (asset.type == 'image') {
      if (isZipVirtualPath(asset.path)) {
        return FutureBuilder<Uint8List?>(
          future: ZipThumbnailCache.bytesFor(asset),
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null || bytes.isEmpty) return _fallbackIcon();
            return Image.memory(
              bytes,
              fit: BoxFit.contain,
              cacheWidth: _decodeWidth,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _fallbackIcon(),
            );
          },
        );
      }
      return Image.file(
        File(asset.path),
        fit: BoxFit.contain,
        cacheWidth: _decodeWidth,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _fallbackIcon(),
      );
    }
    return _fallbackIcon();
  }

  Widget _fallbackIcon() {
    return Center(
      child: Icon(
        iconForAssetType(asset.effectiveType),
        size: 34,
        color: Colors.black26,
      ),
    );
  }
}

/// Shows a model's rendered thumbnail once it exists, and its type icon until
/// then, so the grid fills in as you look at it instead of blocking.
class ModelThumbnail extends StatelessWidget {
  const ModelThumbnail({
    required this.asset,
    required this.allAssets,
    super.key,
  });

  final AssetItem asset;
  final List<AssetItem> allAssets;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ModelThumbnailCache.revision,
      builder: (context, _, _) {
        final image = ModelThumbnailCache.imageFor(asset, allAssets);
        if (image == null) {
          return Center(
            child: Icon(
              iconForAssetType(asset.effectiveType),
              size: 34,
              color: Colors.black26,
            ),
          );
        }
        return RawImage(image: image, fit: BoxFit.contain);
      },
    );
  }
}

/// Small bounded cache of decompressed ZIP entries for thumbnails. Without it
/// scrolling a grid re-inflates the same archive entries continuously.
class ZipThumbnailCache {
  ZipThumbnailCache._();

  static const maxEntries = 200;
  static final _entries = <String, Future<Uint8List?>>{};

  static Future<Uint8List?> bytesFor(AssetItem asset) {
    final cached = _entries.remove(asset.id);
    if (cached != null) {
      _entries[asset.id] = cached;
      return cached;
    }
    final future = readZipVirtualAssetBytesByPath(asset.path);
    _entries[asset.id] = future;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return future;
  }

  static void clear() => _entries.clear();
}

class PreviewPanel extends StatefulWidget {
  const PreviewPanel({
    required this.asset,
    required this.allAssets,
    required this.catalogRevision,
    required this.onActivateAsset,
    super.key,
  });

  final AssetItem? asset;
  final List<AssetItem> allAssets;
  final int catalogRevision;
  final ValueChanged<AssetItem> onActivateAsset;

  @override
  State<PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<PreviewPanel> {
  double detailsWidth = 360;

  // Same reason as the diagnostics panel: a future built inline in build()
  // re-read and re-inflated the archive entry on every rebuild.
  String? _zipBytesKey;
  Future<Uint8List?>? _zipBytesFuture;

  Future<Uint8List?> _zipBytesFor(AssetItem item) {
    final key = '${item.id}|${widget.catalogRevision}';
    if (_zipBytesKey != key || _zipBytesFuture == null) {
      _zipBytesKey = key;
      _zipBytesFuture = readZipVirtualAssetBytesByPath(item.path);
    }
    return _zipBytesFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.asset;
    if (item == null) {
      return const Center(child: Text('Select an asset to preview.'));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxDetails = math.max(260.0, constraints.maxWidth - 360);
        final clampedDetailsWidth = detailsWidth
            .clamp(260.0, maxDetails)
            .toDouble();
        if (clampedDetailsWidth != detailsWidth) {
          detailsWidth = clampedDetailsWidth;
        }

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _previewFor(item)),
              const SizedBox(width: 8),
              VerticalResizeHandle(
                onDrag: (delta) {
                  setState(() {
                    detailsWidth = (detailsWidth - delta)
                        .clamp(260.0, maxDetails)
                        .toDouble();
                  });
                },
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: clampedDetailsWidth,
                child: AssetDetailsPanel(
                  item: item,
                  allAssets: widget.allAssets,
                  catalogRevision: widget.catalogRevision,
                  onActivateAsset: widget.onActivateAsset,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _previewFor(AssetItem item) {
    if (item.type == 'image') {
      if (isZipVirtualPath(item.path)) {
        return FutureBuilder<Uint8List?>(
          future: _zipBytesFor(item),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final bytes = snapshot.data;
            if (bytes == null || bytes.isEmpty) {
              return const Center(
                child: Text('Could not read image bytes from ZIP entry.'),
              );
            }
            return ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ColoredBox(
                color: const Color(0xffe9edf3),
                child: Center(
                  child: InteractiveViewer(
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      errorBuilder: (_, error, _) =>
                          Text('Image failed to load: $error'),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      }

      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(
          color: const Color(0xffe9edf3),
          child: Center(
            child: InteractiveViewer(
              child: Image.file(
                File(item.path),
                fit: BoxFit.contain,
                errorBuilder: (_, error, _) =>
                    Text('Image failed to load: $error'),
              ),
            ),
          ),
        ),
      );
    }

    if (item.type == 'model') {
      if (isZipVirtualPath(item.path) &&
          item.ext != 'obj' &&
          item.ext != 'fbx') {
        return _unsupportedZipModelPreview(item);
      }
      return ModelPreview(
        asset: item,
        allAssets: widget.allAssets,
        catalogRevision: widget.catalogRevision,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black12),
        borderRadius: BorderRadius.circular(8),
        color: const Color(0xfff2f5f9),
      ),
      child: AudioPreview(asset: item),
    );
  }

  Widget _unsupportedZipModelPreview(AssetItem item) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black12),
        borderRadius: BorderRadius.circular(8),
        color: const Color(0xfff2f5f9),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Preview for ${item.ext.toUpperCase()} inside ZIP is not available yet.\n'
            'Images, audio, and OBJ entries preview in-memory.\n'
            'Use Copy to extract this asset if you need external-tool preview.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54),
          ),
        ),
      ),
    );
  }
}

/// Whether [bytes] actually start like the audio container their extension
/// claims.
///
/// audioplayers_windows dies with an access violation on malformed input --
/// a native crash Dart cannot catch -- so nothing unverified may reach it.
/// Confirmed against a 268-byte AppleDouble stub named ".mp3", which took the
/// whole app down.
bool looksLikePlayableAudio(List<int> bytes, String ext) {
  if (bytes.length < 12) return false;

  bool startsWith(List<int> magic, {int offset = 0}) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i += 1) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  switch (ext) {
    case 'mp3':
      // ID3v2 tag, or an MPEG frame sync (11 set bits).
      if (startsWith([0x49, 0x44, 0x33])) return true;
      return bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0;
    case 'wav':
      return startsWith([0x52, 0x49, 0x46, 0x46]) &&
          startsWith([0x57, 0x41, 0x56, 0x45], offset: 8);
    case 'ogg':
      return startsWith([0x4F, 0x67, 0x67, 0x53]);
    case 'flac':
      return startsWith([0x66, 0x4C, 0x61, 0x43]) ||
          startsWith([0x49, 0x44, 0x33]);
    case 'mid':
    case 'midi':
      return startsWith([0x4D, 0x54, 0x68, 0x64]);
  }
  return true;
}

class AudioPreview extends StatefulWidget {
  const AudioPreview({required this.asset, super.key});

  final AssetItem asset;

  @override
  State<AudioPreview> createState() => _AudioPreviewState();
}

class _AudioPreviewState extends State<AudioPreview> {
  final player = AudioPlayer();
  StreamSubscription<Duration>? positionSub;
  StreamSubscription<Duration>? durationSub;
  StreamSubscription<PlayerState>? stateSub;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  PlayerState state = PlayerState.stopped;
  String? unplayableReason;

  @override
  void initState() {
    super.initState();
    durationSub = player.onDurationChanged.listen((next) {
      if (!mounted) return;
      setState(() => duration = next);
    });
    positionSub = player.onPositionChanged.listen((next) {
      if (!mounted) return;
      setState(() => position = next);
    });
    stateSub = player.onPlayerStateChanged.listen((next) {
      if (!mounted) return;
      setState(() => state = next);
    });
  }

  @override
  void didUpdateWidget(covariant AudioPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.path != widget.asset.path) {
      unawaited(player.stop());
      setState(() {
        position = Duration.zero;
        duration = Duration.zero;
        state = PlayerState.stopped;
        unplayableReason = null;
      });
    }
  }

  @override
  void dispose() {
    unawaited(positionSub?.cancel());
    unawaited(durationSub?.cancel());
    unawaited(stateSub?.cancel());
    unawaited(player.dispose());
    super.dispose();
  }

  Future<void> playPause() async {
    if (state == PlayerState.playing) {
      await player.pause();
      return;
    }

    try {
      if (isZipVirtualPath(widget.asset.path)) {
        final bytes = await readZipVirtualAssetBytesByPath(widget.asset.path);
        if (bytes == null || bytes.isEmpty) {
          _reportUnplayable('This archive entry could not be read.');
          return;
        }
        if (!looksLikePlayableAudio(bytes, widget.asset.ext)) {
          _reportUnplayable(
            'This file does not contain ${widget.asset.ext.toUpperCase()} '
            'audio data, so it cannot be played.',
          );
          return;
        }
        await player.play(BytesSource(bytes));
        return;
      }

      final file = File(widget.asset.path);
      if (!file.existsSync()) {
        _reportUnplayable('The file is no longer at this path.');
        return;
      }
      final header = await file.openRead(0, 32).expand((c) => c).toList();
      if (!looksLikePlayableAudio(header, widget.asset.ext)) {
        _reportUnplayable(
          'This file does not contain ${widget.asset.ext.toUpperCase()} '
          'audio data, so it cannot be played.',
        );
        return;
      }
      await player.play(DeviceFileSource(widget.asset.path));
    } catch (error) {
      _reportUnplayable('Playback failed: $error');
    }
  }

  void _reportUnplayable(String message) {
    if (!mounted) return;
    setState(() => unplayableReason = message);
  }

  String asClock(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final maxMillis = duration.inMilliseconds <= 0
        ? 1.0
        : duration.inMilliseconds.toDouble();
    final posMillis = position.inMilliseconds
        .clamp(0, duration.inMilliseconds)
        .toDouble();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.graphic_eq, size: 56, color: Colors.black54),
          const SizedBox(height: 16),
          Text(widget.asset.name, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 14),
          Slider(
            value: posMillis,
            min: 0,
            max: maxMillis,
            onChanged: duration.inMilliseconds <= 0
                ? null
                : (value) {
                    player.seek(Duration(milliseconds: value.round()));
                  },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Text(asClock(position)),
                const Spacer(),
                Text(asClock(duration)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (unplayableReason != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                unplayableReason!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xffb3261e)),
              ),
            ),
          FilledButton.icon(
            onPressed: playPause,
            icon: Icon(
              state == PlayerState.playing ? Icons.pause : Icons.play_arrow,
            ),
            label: Text(
              state == PlayerState.playing ? 'Pause preview' : 'Play preview',
            ),
          ),
        ],
      ),
    );
  }
}

class ModelPreview extends StatefulWidget {
  const ModelPreview({
    required this.asset,
    required this.allAssets,
    required this.catalogRevision,
    super.key,
  });

  final AssetItem asset;
  final List<AssetItem> allAssets;
  final int catalogRevision;

  @override
  State<ModelPreview> createState() => _ModelPreviewState();
}

class _ModelPreviewState extends State<ModelPreview> {
  late Future<MeshModel> meshFuture;
  double yaw = -0.6;
  double pitch = 0.35;
  double zoom = 1;
  RenderMode renderMode = RenderMode.textured;
  int checkerSquareSize = 16;
  String? uvSetOverride;
  LightingMode lightingMode = LightingMode.corner;
  bool cullBackFaces = true;

  /// A texture the user picked by hand, overriding whatever resolved.
  String? chosenTexturePath;
  bool useBaseTexture = true;
  bool useNormalMaps = true;
  bool useEmissiveMaps = true;
  bool useSpecular = true;
  bool interacting = false;
  Timer? _interactionTimer;

  /// Marks the camera as moving, and settles shortly after the last change so
  /// the view can re-render sharp.
  void _touchInteraction() {
    if (!interacting) setState(() => interacting = true);
    _interactionTimer?.cancel();
    _interactionTimer = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => interacting = false);
    });
  }

  Future<MeshModel> _loadCurrentMesh() async {
    final mesh = await MeshLoadCache.load(
      widget.asset,
      allAssets: widget.allAssets,
      fallbackCheckerSquareSize: checkerSquareSize,
    );
    final chosen = chosenTexturePath;
    if (chosen == null) return mesh;
    // Not cached: the cache is keyed on the file, and this is the user's
    // choice rather than anything the file said.
    return applyChosenTexture(mesh, chosen);
  }

  @override
  void initState() {
    super.initState();
    meshFuture = _loadCurrentMesh();
  }

  @override
  void dispose() {
    _interactionTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ModelPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id ||
        oldWidget.catalogRevision != widget.catalogRevision) {
      meshFuture = _loadCurrentMesh();
      yaw = -0.6;
      pitch = 0.35;
      zoom = 1;
      uvSetOverride = null;
      // A texture chosen for one model means nothing for the next.
      chosenTexturePath = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: const Color(0xffe9edf3),
        child: FutureBuilder<MeshModel>(
          future: meshFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Model failed to load:\n${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.black54),
                  ),
                ),
              );
            }
            final mesh = snapshot.data!;
            if (mesh.isAnimationOnly) {
              return AnimationClipPreview(
                mesh: mesh,
                allAssets: widget.allAssets,
                clipPath: widget.asset.path,
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The controls used to float over the model, which put
                // them exactly where you want to look. A real bar above
                // the viewport costs a little height and covers nothing.
                ModelToolbarBar(
                  children: [
                    if (mesh.skin != null)
                      ValueListenableBuilder<String?>(
                        valueListenable: AnimationCharacter.instance.path,
                        builder: (context, chosen, _) =>
                            AnimationCharacterButton(
                              isChosen: chosen == widget.asset.path,
                              onPressed: () => AnimationCharacter.instance.set(
                                chosen == widget.asset.path
                                    ? null
                                    : widget.asset.path,
                              ),
                            ),
                      ),
                    SegmentedButton<RenderMode>(
                      segments: const [
                        ButtonSegment(
                          value: RenderMode.textured,
                          label: Text('Textured'),
                        ),
                        ButtonSegment(
                          value: RenderMode.solid,
                          label: Text('Solid'),
                        ),
                        ButtonSegment(
                          value: RenderMode.wireframe,
                          label: Text('Wireframe'),
                        ),
                      ],
                      selected: {renderMode},
                      onSelectionChanged: (selection) {
                        if (selection.isEmpty) return;
                        setState(() => renderMode = selection.first);
                      },
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .9),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.black12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Light'),
                          const SizedBox(width: 8),
                          DropdownButtonHideUnderline(
                            child: DropdownButton<LightingMode>(
                              value: lightingMode,
                              isDense: true,
                              items: const [
                                DropdownMenuItem(
                                  value: LightingMode.corner,
                                  child: Text('Corner'),
                                ),
                                DropdownMenuItem(
                                  value: LightingMode.top,
                                  child: Text('Top'),
                                ),
                                DropdownMenuItem(
                                  value: LightingMode.unlit,
                                  child: Text('Unlit'),
                                ),
                              ],
                              onChanged: (next) {
                                if (next == null) return;
                                setState(() => lightingMode = next);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .9),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.black12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Hide back faces'),
                          Switch(
                            value: cullBackFaces,
                            onChanged: (next) =>
                                setState(() => cullBackFaces = next),
                          ),
                        ],
                      ),
                    ),
                    // Only shown when there is a normal map to apply: an
                    // inert control invites the question "why is nothing
                    // happening".
                    if (renderMode == RenderMode.textured) ...[
                      TexturePickerButton(
                        candidates: findNearbyTextures(
                          widget.asset,
                          widget.allAssets,
                        ),
                        chosenPath: chosenTexturePath,
                        onChosen: (path) => setState(() {
                          chosenTexturePath = path;
                          meshFuture = _loadCurrentMesh();
                        }),
                      ),
                      ShadingChannelPanel(
                        channels: [
                          if (mesh.materials.any(
                            (material) => material.texturePixels != null,
                          ))
                            ShadingChannel(
                              label: 'Base texture',
                              value: useBaseTexture,
                              onChanged: (next) =>
                                  setState(() => useBaseTexture = next),
                            ),
                          if (mesh.materials.any(
                            (material) => material.hasNormalMap,
                          ))
                            ShadingChannel(
                              label: 'Normal map',
                              value: useNormalMaps,
                              onChanged: (next) =>
                                  setState(() => useNormalMaps = next),
                            ),
                          if (mesh.materials.any(
                            (material) => material.hasEmissiveMap,
                          ))
                            ShadingChannel(
                              label: 'Emissive',
                              value: useEmissiveMaps,
                              onChanged: (next) =>
                                  setState(() => useEmissiveMaps = next),
                            ),
                          if (mesh.materials.any(
                            (material) => material.specularFactor > 0,
                          ))
                            ShadingChannel(
                              label: 'Specular',
                              value: useSpecular,
                              onChanged: (next) =>
                                  setState(() => useSpecular = next),
                            ),
                        ],
                      ),
                    ],
                    if (mesh.availableUvSets.length > 1) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .9),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.black12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('UV set'),
                            const SizedBox(width: 8),
                            DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: uvSetOverride ?? '',
                                isDense: true,
                                items: [
                                  const DropdownMenuItem(
                                    value: '',
                                    child: Text('Material default'),
                                  ),
                                  ...mesh.availableUvSets.map(
                                    (name) => DropdownMenuItem(
                                      value: name,
                                      child: Text(name),
                                    ),
                                  ),
                                ],
                                onChanged: (next) {
                                  setState(() {
                                    uvSetOverride = switch (next) {
                                      null || '' => null,
                                      _ => next,
                                    };
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .9),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.black12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Fallback'),
                          const SizedBox(width: 8),
                          DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              value: checkerSquareSize,
                              isDense: true,
                              items: const [4, 8, 16, 32, 64]
                                  .map(
                                    (size) => DropdownMenuItem<int>(
                                      value: size,
                                      child: Text('${size}px square'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (next) {
                                if (next == null || next == checkerSquareSize) {
                                  return;
                                }
                                setState(() {
                                  checkerSquareSize = next;
                                  meshFuture = _loadCurrentMesh();
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: Listener(
                    onPointerSignal: (event) {
                      if (event is PointerScrollEvent) {
                        _touchInteraction();
                        setState(() {
                          zoom = (zoom * (event.scrollDelta.dy > 0 ? .9 : 1.1))
                              .clamp(.35, 4)
                              .toDouble();
                        });
                      }
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) {
                        _touchInteraction();
                        setState(() {
                          yaw += details.delta.dx * .01;
                          pitch = (pitch + details.delta.dy * .01)
                              .clamp(-1.45, 1.45)
                              .toDouble();
                        });
                      },
                      child: Stack(
                        children: [
                          Positioned.fill(
                            // Wireframe is lines only, where per-pixel depth
                            // buys nothing; everything filled goes through the
                            // rasteriser so interpenetrating and coplanar faces
                            // resolve correctly.
                            child: renderMode == RenderMode.wireframe
                                ? CustomPaint(
                                    painter: MeshPainter(
                                      mesh: mesh,
                                      yaw: yaw,
                                      pitch: pitch,
                                      zoom: zoom,
                                      renderMode: renderMode,
                                      uvSetOverride: uvSetOverride,
                                      lightingMode: lightingMode,
                                      cullBackFaces: cullBackFaces,
                                      // Wireframe draws no surface, so the
                                      // shading channels do not apply to it.
                                      useNormalMaps: useNormalMaps,
                                    ),
                                  )
                                : RasterModelView(
                                    mesh: mesh,
                                    yaw: yaw,
                                    pitch: pitch,
                                    zoom: zoom,
                                    renderMode: renderMode,
                                    lightingMode: lightingMode,
                                    cullBackFaces: cullBackFaces,
                                    useBaseTexture: useBaseTexture,
                                    useNormalMaps: useNormalMaps,
                                    useEmissiveMaps: useEmissiveMaps,
                                    useSpecular: useSpecular,
                                    uvSetOverride: uvSetOverride,
                                    interacting: interacting,
                                  ),
                          ),
                          Align(
                            alignment: Alignment.bottomLeft,
                            child: Container(
                              margin: const EdgeInsets.all(12),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: .86),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Builder(
                                builder: (context) {
                                  final total = mesh.faces.length;
                                  final capped = total > maxRenderedFaces;
                                  final summary =
                                      '${mesh.name} · ${mesh.vertices.length} verts · $total faces';
                                  if (!capped) return Text(summary);
                                  return Text(
                                    '$summary · face cap: showing '
                                    '$maxRenderedFaces nearest',
                                    style: const TextStyle(
                                      color: Color(0xffb3540a),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Shown for an FBX that carries a skeleton and curves but no geometry. There
/// is nothing to draw, so report what the file actually holds instead of
/// showing an import error.
/// Draws one pose of a rig: a line from every bone to its parent.
///
/// The bounds come from the whole clip rather than the current frame, so the
/// figure does not breathe in and out as it plays.
class SkeletonPainter extends CustomPainter {
  SkeletonPainter({
    required this.skeleton,
    required this.frame,
    required this.yaw,
  });

  final SkeletonAnimation skeleton;
  final int frame;

  /// Rotation about the vertical axis, in radians.
  final double yaw;

  @override
  void paint(Canvas canvas, Size size) {
    if (frame < 0 || frame >= skeleton.frameCount) return;
    final positions = skeleton.positions[frame];
    final bounds = skeleton.bounds;

    final spanX = math.max(bounds.maxX - bounds.minX, 0.001);
    final spanY = math.max(bounds.maxY - bounds.minY, 0.001);
    // Depth rotates into x, so reserve the wider of the two for the scale.
    final scale =
        math.min(size.width / math.max(spanX, spanY), size.height / spanY) *
        0.82;
    final centerX = (bounds.minX + bounds.maxX) / 2;
    final centerY = (bounds.minY + bounds.maxY) / 2;
    final sinYaw = math.sin(yaw);
    final cosYaw = math.cos(yaw);

    Offset project(int bone) {
      final base = bone * 12;
      final x = positions[base + 9] - centerX;
      final y = positions[base + 10] - centerY;
      final z = positions[base + 11];
      final rotated = x * cosYaw + z * sinYaw;
      return Offset(
        size.width / 2 + rotated * scale,
        size.height / 2 - y * scale,
      );
    }

    final bonePaint = Paint()
      ..color = const Color(0xff2f3a4a)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final jointPaint = Paint()..color = const Color(0xff4c7fd4);

    for (var i = 0; i < skeleton.bones.length; i += 1) {
      final parent = skeleton.bones[i].parent;
      final point = project(i);
      if (parent >= 0 && parent < skeleton.bones.length) {
        canvas.drawLine(project(parent), point, bonePaint);
      }
      canvas.drawCircle(point, 2.2, jointPaint);
    }
  }

  @override
  bool shouldRepaint(covariant SkeletonPainter oldDelegate) =>
      oldDelegate.frame != frame ||
      oldDelegate.yaw != yaw ||
      !identical(oldDelegate.skeleton, skeleton);
}

/// Plays a clip's rig: drag to turn, scrub to a frame, or let it run.
class SkeletonPlayer extends StatefulWidget {
  const SkeletonPlayer({
    required this.skeleton,
    this.characterPath,
    this.allAssets = const [],
    this.clipPath = '',
    super.key,
  });

  final SkeletonAnimation skeleton;

  /// The model to play this clip on. Null falls back to the stick figure.
  final String? characterPath;
  final List<AssetItem> allAssets;
  final String clipPath;

  @override
  State<SkeletonPlayer> createState() => _SkeletonPlayerState();
}

class _SkeletonPlayerState extends State<SkeletonPlayer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;
  bool _playing = true;
  double _yaw = 0.4;
  MeshModel? _character;
  String? _characterError;
  RasterScene? _restScene;
  Float32List? _posedPositions;
  RetargetPlan? _plan;
  Float32List? _boneWorld;
  String? _retargetNote;

  /// The character's scene with this frame's positions written into it.
  ///
  /// Both the scene and the position buffer are built once and reused: the
  /// triangle and material tables do not change as a clip plays, and
  /// reallocating them every frame is what made playback stutter.
  RasterScene _poseScene(
    MeshModel character,
    SkeletonAnimation clip,
    int frame,
  ) {
    final scene = _restScene ??= RasterScene.fromMesh(character);
    final buffer = _posedPositions ??= Float32List(
      character.vertices.length * 3,
    );
    poseSkinnedPositions(
      character: character,
      clip: clip,
      frame: frame,
      out: buffer,
      plan: _plan,
      boneWorld: _boneWorld,
    );
    return scene.withPositions(buffer);
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      if (!_playing) return;
      setState(() => _elapsed = elapsed);
    })..start();
    _loadCharacter();
  }

  @override
  void didUpdateWidget(covariant SkeletonPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.characterPath != widget.characterPath ||
        !identical(oldWidget.skeleton, widget.skeleton)) {
      _character = null;
      _characterError = null;
      _restScene = null;
      _posedPositions = null;
      _plan = null;
      _boneWorld = null;
      _retargetNote = null;
      _loadCharacter();
    }
  }

  /// Works out how to drive this character with this clip.
  ///
  /// Rigs that agree are posed by the clip directly. Rigs that do not are
  /// retargeted through a reference character shipped beside the clip; without
  /// one there is nothing to correct against, so the character stays in its
  /// bind pose rather than being torn apart.
  Future<void> _buildPlan(MeshModel character) async {
    final rest = character.skeleton;
    if (rest == null) return;
    // A character with no bones in common with the clip cannot be driven by it
    // at all; say so rather than showing a bind pose with no explanation.
    if (rigBoneOverlap(rest, widget.skeleton) < minimumRigOverlap) {
      _plan = null;
      _boneWorld = null;
      _retargetNote =
          'This clip is for a different skeleton, so it cannot move this '
          'character. Look for clips beside it built for the same rig.';
      return;
    }

    final difference = rigAxisDifference(rest, widget.skeleton);
    if (difference <= maxDirectPoseAngle) {
      _plan = null;
      _boneWorld = null;
      _retargetNote = null;
      return;
    }

    // Measure every candidate against the clip and take the closest. This
    // pack ships a Polygon and a Sidekick character side by side, and the
    // clip was authored against exactly one of them; choosing by name picked
    // whichever sorted first, which corrected half the clips against a rig
    // they were never made for.
    // The reference is the clip's own rig in a T-pose, so it is chosen by how
    // many bones it shares with the clip -- not by how close its pose is. The
    // pack ships a Polygon and a Sidekick character with no bones in common,
    // and the clip belongs to exactly one of them.
    SkeletonAnimation? reference;
    AssetItem? referenceAsset;
    var bestOverlap = 0;
    for (final candidate in findClipReferenceCharacters(
      widget.clipPath,
      widget.allAssets,
    )) {
      try {
        final candidateMesh = await MeshLoadCache.load(
          candidate,
          allAssets: widget.allAssets,
        );
        final candidateRig = candidateMesh.skeleton;
        if (candidateRig == null) continue;
        final shared = rigBoneOverlap(candidateRig, widget.skeleton);
        if (shared > bestOverlap) {
          bestOverlap = shared;
          reference = candidateRig;
          referenceAsset = candidate;
        }
      } catch (error) {
        fbxLog('Could not load the reference rig ${candidate.name}: $error');
      }
    }
    if (bestOverlap < minimumRigOverlap) {
      reference = null;
      referenceAsset = null;
    }

    _plan = RetargetPlan.build(
      characterRest: rest,
      clip: widget.skeleton,
      sourceReference: reference,
    );
    _boneWorld = Float32List(rest.bones.length * 12);
    _retargetNote = reference == null
        ? 'This rig sits ${difference.round()}° from the clip and no '
              'matching reference character was found beside it, so only its '
              'own bind pose can be shown.'
        : 'Retargeted through ${referenceAsset!.name}: this rig sits '
              '${difference.round()}° from the clip.';
  }

  Future<void> _loadCharacter() async {
    final path = widget.characterPath;
    if (path == null) return;
    AssetItem? asset;
    for (final candidate in widget.allAssets) {
      if (candidate.path == path) {
        asset = candidate;
        break;
      }
    }
    if (asset == null) {
      setState(
        () => _characterError =
            'The chosen character is not in the '
            'catalog any more.',
      );
      return;
    }
    try {
      final mesh = await MeshLoadCache.load(asset, allAssets: widget.allAssets);
      if (!mounted) return;
      if (mesh.skin == null) {
        setState(() {
          _character = null;
          _characterError =
              '${asset!.name} has no skin weights, so a clip cannot move it.';
        });
        return;
      }
      await _buildPlan(mesh);
      if (!mounted) return;
      setState(() {
        _character = mesh;
        _characterError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _characterError = 'Could not load the character: $error');
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  int get _frame {
    final count = widget.skeleton.frameCount;
    if (count <= 1) return 0;
    final rate = widget.skeleton.frameRate <= 0
        ? 30.0
        : widget.skeleton.frameRate;
    // Loop: a locomotion clip is meant to be watched repeatedly.
    return ((_elapsed.inMicroseconds / 1e6) * rate).floor() % count;
  }

  /// Parks playback on one frame. Scrubbing implies pausing.
  void _seek(int frame) {
    final rate = widget.skeleton.frameRate <= 0
        ? 30.0
        : widget.skeleton.frameRate;
    setState(() {
      _playing = false;
      _elapsed = Duration(microseconds: (frame / rate * 1e6).round());
    });
  }

  @override
  Widget build(BuildContext context) {
    final skeleton = widget.skeleton;
    final frame = _frame;
    final character = _character;
    return Column(
      children: [
        if (_retargetNote != null && _characterError == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              _retargetNote!,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
        if (_characterError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              _characterError!,
              style: const TextStyle(fontSize: 12, color: Color(0xffb3261e)),
            ),
          ),
        Expanded(
          child: GestureDetector(
            onHorizontalDragUpdate: (details) =>
                setState(() => _yaw += details.delta.dx * 0.01),
            child: character == null
                ? CustomPaint(
                    painter: SkeletonPainter(
                      skeleton: skeleton,
                      frame: frame,
                      yaw: _yaw,
                    ),
                    child: const SizedBox.expand(),
                  )
                : RasterModelView(
                    mesh: character,
                    sceneOverride: _poseScene(character, skeleton, frame),
                    sceneRevision: frame,
                    yaw: _yaw,
                    pitch: 0,
                    zoom: 1,
                    renderMode: RenderMode.textured,
                    lightingMode: LightingMode.corner,
                    cullBackFaces: false,
                    useBaseTexture: true,
                    useNormalMaps: true,
                    useEmissiveMaps: true,
                    useSpecular: true,
                    // Every frame is a new mesh, so never wait on an isolate
                    // round trip for a sharp one.
                    interacting: true,
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: _playing ? 'Pause' : 'Play',
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                onPressed: () => setState(() {
                  if (_playing) {
                    _playing = false;
                  } else {
                    // Resume from where the scrub left off rather than
                    // jumping back to whatever the ticker has counted to.
                    _playing = true;
                  }
                }),
              ),
              Expanded(
                child: Slider(
                  value: frame.toDouble(),
                  max: math.max(1, skeleton.frameCount - 1).toDouble(),
                  divisions: math.max(1, skeleton.frameCount - 1),
                  label: 'Frame $frame',
                  onChanged: (value) => _seek(value.round()),
                ),
              ),
              SizedBox(
                width: 96,
                child: Text(
                  '${frame + 1} / ${skeleton.frameCount}',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class AnimationClipPreview extends StatelessWidget {
  const AnimationClipPreview({
    required this.mesh,
    this.allAssets = const [],
    this.clipPath = '',
    super.key,
  });

  final MeshModel mesh;

  /// Needed to find the chosen character, which lives elsewhere in the catalog.
  final List<AssetItem> allAssets;

  /// Where this clip came from, so its reference rig can be found beside it.
  final String clipPath;

  String get _duration {
    if (mesh.durationSeconds <= 0) return 'unknown';
    return '${mesh.durationSeconds.toStringAsFixed(2)}s';
  }

  @override
  Widget build(BuildContext context) {
    final skeleton = mesh.skeleton;
    if (skeleton != null) {
      return Column(
        children: [
          Expanded(
            child: ValueListenableBuilder<String?>(
              valueListenable: AnimationCharacter.instance.path,
              builder: (context, characterPath, _) => SkeletonPlayer(
                skeleton: skeleton,
                characterPath: characterPath,
                allAssets: allAssets,
                clipPath: clipPath,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '${skeleton.bones.length} bones · $_duration · '
              '${mesh.animationNames.join(", ")}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
        ],
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.directions_run, size: 56, color: Colors.black54),
            const SizedBox(height: 12),
            const Text(
              'Animation clip',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'This FBX contains animation and skeleton data, with no mesh to '
              'draw.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black.withValues(alpha: .6)),
            ),
            const SizedBox(height: 16),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .8),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.black12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DetailRow(
                      label: 'Takes',
                      value: mesh.animationStacks.toString(),
                    ),
                    DetailRow(label: 'Bones', value: mesh.boneCount.toString()),
                    DetailRow(label: 'Length', value: _duration),
                    if (mesh.animationNames.isNotEmpty)
                      DetailRow(
                        label: 'Clip names',
                        value: mesh.animationNames.join(', '),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Playback is not implemented yet.',
              style: TextStyle(color: Colors.black.withValues(alpha: .45)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Turns a [RasterResult] into an image the widget layer can draw.
Future<ui.Image> imageFromRaster(RasterResult raster) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    raster.pixels,
    raster.width,
    raster.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// Shows a mesh rendered by the depth-buffered rasteriser.
///
/// Rasterising costs tens of milliseconds, so while the camera is moving this
/// renders at half resolution and sharpens once you stop. The previous frame
/// stays on screen in the meantime rather than flashing empty.
class RasterModelView extends StatefulWidget {
  const RasterModelView({
    required this.mesh,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.renderMode,
    required this.lightingMode,
    required this.cullBackFaces,
    required this.useBaseTexture,
    required this.useNormalMaps,
    required this.useEmissiveMaps,
    required this.useSpecular,
    required this.interacting,
    this.sceneOverride,
    this.sceneRevision,
    this.uvSetOverride,
    super.key,
  });

  final MeshModel mesh;
  final double yaw;
  final double pitch;
  final double zoom;
  final RenderMode renderMode;
  final LightingMode lightingMode;
  final bool cullBackFaces;
  final bool useBaseTexture;
  final bool useNormalMaps;
  final bool useEmissiveMaps;
  final bool useSpecular;

  /// True while the user is dragging or zooming.
  final bool interacting;
  final String? uvSetOverride;

  /// A prebuilt scene to draw instead of flattening [mesh].
  ///
  /// Animation supplies this: only the vertex positions change per frame, and
  /// rebuilding the triangle and material tables 30 times a second is most of
  /// the cost of playback.
  final RasterScene? sceneOverride;

  /// Changes when [sceneOverride] holds different positions, so the frame
  /// cache can tell one pose from the next.
  final Object? sceneRevision;

  @override
  State<RasterModelView> createState() => _RasterModelViewState();
}

class _RasterModelViewState extends State<RasterModelView> {
  ui.Image? _image;
  RasterScene? _scene;
  String? _sceneKey;
  String? _renderedKey;
  bool _rendering = false;
  Size _lastSize = Size.zero;

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  String _keyFor(Size size, double scale) => [
    identityHashCode(widget.mesh),
    widget.yaw.toStringAsFixed(4),
    widget.pitch.toStringAsFixed(4),
    widget.zoom.toStringAsFixed(4),
    widget.renderMode.name,
    widget.lightingMode.name,
    widget.cullBackFaces,
    widget.useBaseTexture,
    widget.useNormalMaps,
    widget.useEmissiveMaps,
    widget.useSpecular,
    widget.sceneRevision ?? '',
    widget.uvSetOverride ?? '',
    size.width.round(),
    size.height.round(),
    scale,
  ].join('|');

  Future<void> _render(Size size) async {
    if (_rendering || size.isEmpty) return;
    // Coarse while the camera moves, sharp once it settles.
    final scale = widget.interacting ? 0.5 : 1.0;
    final key = _keyFor(size, scale);
    if (key == _renderedKey) return;

    _rendering = true;
    try {
      final width = math.max(1, (size.width * scale).round());
      final height = math.max(1, (size.height * scale).round());

      // Flattening the mesh is the expensive part of setup, so keep it per
      // mesh rather than per frame. Animation hands us a scene it already
      // holds, whose positions it swaps in place.
      final override = widget.sceneOverride;
      if (override == null) {
        final sceneKey =
            '${identityHashCode(widget.mesh)}|'
            '${widget.uvSetOverride ?? ''}';
        if (_scene == null || _sceneKey != sceneKey) {
          _scene = RasterScene.fromMesh(
            widget.mesh,
            uvSetOverride: widget.uvSetOverride,
          );
          _sceneKey = sceneKey;
        }
      }

      final request = RasterRequest(
        scene: override ?? _scene!,
        yaw: widget.yaw,
        pitch: widget.pitch,
        zoom: widget.zoom,
        width: width,
        height: height,
        renderMode: widget.renderMode,
        lightingMode: widget.lightingMode,
        cullBackFaces: widget.cullBackFaces,
        useBaseTexture: widget.useBaseTexture,
        useNormalMaps: widget.useNormalMaps,
        useEmissiveMaps: widget.useEmissiveMaps,
        useSpecular: widget.useSpecular,
      );

      // Coarse frames are small and wanted immediately; spending an isolate
      // hop on them would add more latency than it saves. The sharp frame is
      // the one that would stall the window, so that one goes to a worker.
      final raster = widget.interacting
          ? rasterizeScene(request)
          : await rasterizeSceneInIsolate(request);
      final image = await imageFromRaster(raster);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
        _renderedKey = key;
      });
    } finally {
      _rendering = false;
    }
    // The camera may have moved on while this frame was in flight, and a
    // coarse frame has to be followed by a sharp one once movement stops.
    if (mounted &&
        _keyFor(size, widget.interacting ? 0.5 : 1.0) != _renderedKey) {
      unawaited(Future.microtask(() => _render(size)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _lastSize = size;
        WidgetsBinding.instance.addPostFrameCallback((_) => _render(_lastSize));

        final image = _image;
        if (image == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return RawImage(
          image: image,
          width: size.width,
          height: size.height,
          fit: BoxFit.fill,
          // A half-resolution frame stretched to fit reads better smoothed.
          filterQuality: FilterQuality.low,
        );
      },
    );
  }
}

/// A software rasteriser with a depth buffer.
///
/// The canvas painter sorts whole faces by depth and draws them back to front.
/// That cannot resolve geometry that interpenetrates or sits coplanar — window
/// frames flush with a wall, roof details flush with a roof — because the
/// answer differs *within* a face. Those cases showed up as notches and stray
/// slivers along polygon edges. Depth per pixel is the only thing that fixes
/// it, so this walks the triangles itself and keeps a z value per pixel.
///
/// It also buys two things the canvas path could not do: perspective-correct
/// texture sampling, and per-pixel normal mapping.
class RasterResult {
  const RasterResult({
    required this.pixels,
    required this.width,
    required this.height,
    required this.drawnFaces,
    required this.totalFaces,
  });

  /// RGBA, row major, ready for [ui.decodeImageFromPixels].
  final Uint8List pixels;
  final int width;
  final int height;
  final int drawnFaces;
  final int totalFaces;

  bool get capped => drawnFaces < totalFaces;
}

/// Rasterises [mesh] into an RGBA buffer.
///
/// Pure and synchronous so it can run on a worker isolate; nothing here touches
/// `dart:ui`.
/// A mesh flattened into plain data a worker isolate can be handed.
///
/// [MeshModel] holds a `ui.Image` per material, which cannot cross an isolate
/// boundary. The rasteriser never needed it -- it samples the CPU-side pixel
/// buffers -- so this carries only what shading actually reads, with per-face
/// lookups (material, UV set, vertex tint) resolved up front.
class RasterScene {
  const RasterScene({
    required this.positions,
    required this.triangleIndices,
    required this.triangleMaterial,
    required this.triangleUvs,
    required this.triangleHasUv,
    required this.triangleTint,
    required this.materials,
    required this.totalTriangles,
  });

  /// x, y, z per vertex.
  final Float32List positions;

  /// The same scene with different vertex positions.
  ///
  /// Animation replaces the positions 30 times a second and nothing else:
  /// rebuilding the triangle indices, UVs and material table each frame walks
  /// every face and reallocates about a megabyte, which is most of the cost of
  /// a frame. The buffers here are shared, not copied.
  RasterScene withPositions(Float32List replacement) => RasterScene(
    positions: replacement,
    triangleIndices: triangleIndices,
    triangleMaterial: triangleMaterial,
    triangleTint: triangleTint,
    triangleUvs: triangleUvs,
    triangleHasUv: triangleHasUv,
    materials: materials,
    totalTriangles: totalTriangles,
  );

  /// Three vertex indices per triangle.
  final Int32List triangleIndices;
  final Int32List triangleMaterial;

  /// Six values per triangle: u, v for each corner.
  final Float32List triangleUvs;
  final Uint8List triangleHasUv;

  /// Packed 0xRRGGBB vertex tint per triangle, or -1 for none.
  final Int32List triangleTint;

  final List<RasterMaterial> materials;
  final int totalTriangles;

  static RasterScene fromMesh(MeshModel mesh, {String? uvSetOverride}) {
    final triangles = <int>[];
    final triMaterial = <int>[];
    final triUvs = <double>[];
    final triHasUv = <int>[];
    final triTint = <int>[];

    for (final face in mesh.faces) {
      final indices = face.indices;
      if (indices.length < 3) continue;
      var valid = true;
      for (final index in indices) {
        if (index < 0 || index >= mesh.vertices.length) {
          valid = false;
          break;
        }
      }
      if (!valid) continue;

      final material =
          (face.materialIndex >= 0 &&
              face.materialIndex < mesh.materials.length)
          ? mesh.materials[face.materialIndex]
          : null;
      final uvs = face.uvsFor(uvSetOverride ?? material?.uvSet);
      final hasUv = uvs.length == 3;
      final tint = mesh.averageFaceVertexColor(face);
      final packedTint = tint == null
          ? -1
          : (((tint.r * 255).round() & 0xff) << 16) |
                (((tint.g * 255).round() & 0xff) << 8) |
                ((tint.b * 255).round() & 0xff);

      // Fan triangulation: an OBJ face may be a polygon.
      for (var i = 1; i + 1 < indices.length; i += 1) {
        triangles.addAll([indices[0], indices[i], indices[i + 1]]);
        triMaterial.add(face.materialIndex);
        triTint.add(packedTint);
        if (hasUv && i == 1) {
          triUvs.addAll([
            uvs[0].x,
            uvs[0].y,
            uvs[1].x,
            uvs[1].y,
            uvs[2].x,
            uvs[2].y,
          ]);
          triHasUv.add(1);
        } else {
          // Only the first triangle of a polygon carries the face's UVs;
          // beyond that there is nothing meaningful to assign.
          triUvs.addAll([0, 0, 0, 0, 0, 0]);
          triHasUv.add(hasUv && indices.length == 3 ? 1 : 0);
        }
      }
    }

    final positions = Float32List(mesh.vertices.length * 3);
    for (var i = 0; i < mesh.vertices.length; i += 1) {
      positions[i * 3] = mesh.vertices[i].x;
      positions[i * 3 + 1] = mesh.vertices[i].y;
      positions[i * 3 + 2] = mesh.vertices[i].z;
    }

    return RasterScene(
      positions: positions,
      triangleIndices: Int32List.fromList(triangles),
      triangleMaterial: Int32List.fromList(triMaterial),
      triangleUvs: Float32List.fromList(triUvs),
      triangleHasUv: Uint8List.fromList(triHasUv),
      triangleTint: Int32List.fromList(triTint),
      materials: [
        for (var i = 0; i < mesh.materials.length; i += 1)
          RasterMaterial.from(mesh, i),
      ],
      totalTriangles: triMaterial.length,
    );
  }
}

class RasterMaterial {
  const RasterMaterial({
    required this.baseArgbTextured,
    required this.baseArgbFlat,
    required this.opacity,
    required this.texturePixels,
    required this.textureWidth,
    required this.textureHeight,
    required this.normalPixels,
    required this.normalWidth,
    required this.normalHeight,
    required this.emissivePixels,
    required this.emissiveWidth,
    required this.emissiveHeight,
    required this.emissiveFactor,
    required this.specularFactor,
    required this.roughness,
    required this.texturesMissing,
  });

  factory RasterMaterial.from(MeshModel mesh, int index) {
    final material = mesh.materials[index];
    int pack(Color color) =>
        (((color.r * 255).round() & 0xff) << 16) |
        (((color.g * 255).round() & 0xff) << 8) |
        ((color.b * 255).round() & 0xff);
    return RasterMaterial(
      baseArgbTextured: pack(mesh.colorForMaterial(index, textured: true)),
      baseArgbFlat: pack(mesh.colorForMaterial(index, textured: false)),
      opacity: mesh.opacityForMaterial(index),
      texturePixels: material.texturePixels,
      textureWidth: material.textureWidth,
      textureHeight: material.textureHeight,
      normalPixels: material.normalPixels,
      normalWidth: material.normalWidth,
      normalHeight: material.normalHeight,
      emissivePixels: material.emissivePixels,
      emissiveWidth: material.emissiveWidth,
      emissiveHeight: material.emissiveHeight,
      emissiveFactor: material.emissiveFactor,
      specularFactor: material.specularFactor,
      roughness: material.roughness,
      texturesMissing: material.texturesMissing,
    );
  }

  final int baseArgbTextured;
  final int baseArgbFlat;
  final double opacity;
  final Uint8List? texturePixels;
  final int textureWidth;
  final int textureHeight;
  final Uint8List? normalPixels;
  final int normalWidth;
  final int normalHeight;
  final Uint8List? emissivePixels;
  final int emissiveWidth;
  final int emissiveHeight;
  final double emissiveFactor;
  final double specularFactor;
  final double roughness;
  final bool texturesMissing;

  bool get hasNormalMap => normalPixels != null && normalWidth > 0;
  bool get hasEmissiveMap => emissivePixels != null && emissiveWidth > 0;

  /// Emissive texel at (u, v) packed 0xRRGGBB, or null.
  int? sampleEmissive(double u, double v) {
    final pixels = emissivePixels;
    if (pixels == null || emissiveWidth <= 0 || emissiveHeight <= 0) {
      return null;
    }
    var fu = u - u.floorToDouble();
    var fv = v - v.floorToDouble();
    if (fu < 0) fu += 1;
    if (fv < 0) fv += 1;
    final x = (fu * (emissiveWidth - 1)).toInt();
    final y = (fv * (emissiveHeight - 1)).toInt();
    final index = (y * emissiveWidth + x) * 4;
    if (index + 2 >= pixels.length) return null;
    return (pixels[index] << 16) | (pixels[index + 1] << 8) | pixels[index + 2];
  }

  Vec3? sampleNormal(double u, double v) {
    final pixels = normalPixels;
    if (pixels == null || normalWidth <= 0 || normalHeight <= 0) return null;
    var fu = u - u.floorToDouble();
    var fv = v - v.floorToDouble();
    if (fu < 0) fu += 1;
    if (fv < 0) fv += 1;
    final x = (fu * (normalWidth - 1)).toInt();
    final y = (fv * (normalHeight - 1)).toInt();
    final index = (y * normalWidth + x) * 4;
    if (index + 2 >= pixels.length) return null;
    return Vec3(
      pixels[index] / 127.5 - 1.0,
      pixels[index + 1] / 127.5 - 1.0,
      pixels[index + 2] / 127.5 - 1.0,
    );
  }
}

/// Rasterises [mesh]. Convenience wrapper: flattens to a [RasterScene] and
/// renders it.
RasterResult rasterizeMesh({
  required MeshModel mesh,
  required double yaw,
  required double pitch,
  required double zoom,
  required int width,
  required int height,
  required RenderMode renderMode,
  required LightingMode lightingMode,
  required bool cullBackFaces,
  bool useBaseTexture = true,
  bool useNormalMaps = true,
  bool useEmissiveMaps = true,
  bool useSpecular = true,
  String? uvSetOverride,
  int backgroundArgb = 0xffe9edf3,
  int maxFaces = maxRenderedFaces,
}) {
  return rasterizeScene(
    RasterRequest(
      scene: RasterScene.fromMesh(mesh, uvSetOverride: uvSetOverride),
      yaw: yaw,
      pitch: pitch,
      zoom: zoom,
      width: width,
      height: height,
      renderMode: renderMode,
      lightingMode: lightingMode,
      cullBackFaces: cullBackFaces,
      useBaseTexture: useBaseTexture,
      useNormalMaps: useNormalMaps,
      useEmissiveMaps: useEmissiveMaps,
      useSpecular: useSpecular,
      backgroundArgb: backgroundArgb,
      maxFaces: maxFaces,
    ),
  );
}

/// Everything one frame needs, in a single sendable object.
class RasterRequest {
  const RasterRequest({
    required this.scene,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.width,
    required this.height,
    required this.renderMode,
    required this.lightingMode,
    required this.cullBackFaces,
    this.useBaseTexture = true,
    this.useNormalMaps = true,
    this.useEmissiveMaps = true,
    this.useSpecular = true,
    this.backgroundArgb = 0xffe9edf3,
    this.maxFaces = maxRenderedFaces,
  });

  final RasterScene scene;
  final double yaw;
  final double pitch;
  final double zoom;
  final int width;
  final int height;
  final RenderMode renderMode;
  final LightingMode lightingMode;
  final bool cullBackFaces;

  /// The shading channels, each switchable on its own.
  ///
  /// Turning one off is how you find out what it was contributing: a model
  /// that looks wrong with normal maps on and right with them off has a bad
  /// tangent frame, not a bad texture.
  final bool useBaseTexture;
  final bool useNormalMaps;
  final bool useEmissiveMaps;
  final bool useSpecular;
  final int backgroundArgb;
  final int maxFaces;
}

/// Renders a frame. Pure, and free of `dart:ui`, so it runs equally well on a
/// worker isolate; see [rasterizeSceneInIsolate].
RasterResult rasterizeScene(RasterRequest request) {
  final scene = request.scene;
  final width = request.width;
  final height = request.height;
  final pixels = Uint8List(width * height * 4);
  final depth = Float32List(width * height);

  final bgR = (request.backgroundArgb >> 16) & 0xff;
  final bgG = (request.backgroundArgb >> 8) & 0xff;
  final bgB = request.backgroundArgb & 0xff;
  final bgA = (request.backgroundArgb >> 24) & 0xff;
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = bgR;
    pixels[i + 1] = bgG;
    pixels[i + 2] = bgB;
    pixels[i + 3] = bgA;
  }
  // Larger is nearer, so the buffer starts at "infinitely far".
  depth.fillRange(0, depth.length, -double.infinity);

  final vertexCount = scene.positions.length ~/ 3;
  final screenX = Float32List(vertexCount);
  final screenY = Float32List(vertexCount);
  final invW = Float32List(vertexCount);
  final viewX = Float32List(vertexCount);
  final viewY = Float32List(vertexCount);
  final viewZ = Float32List(vertexCount);

  final centerX = width / 2;
  final centerY = height / 2;
  final scale = math.min(width, height) * .38 * request.zoom;
  final sy = math.sin(request.yaw);
  final cy = math.cos(request.yaw);
  final sx = math.sin(request.pitch);
  final cx = math.cos(request.pitch);

  for (var i = 0; i < vertexCount; i += 1) {
    final vx = scene.positions[i * 3];
    final vy = scene.positions[i * 3 + 1];
    final vz = scene.positions[i * 3 + 2];
    final x1 = vx * cy + vz * sy;
    final z1 = -vx * sy + vz * cy;
    final y1 = vy * cx - z1 * sx;
    final z2 = vy * sx + z1 * cx;
    final perspective = 2.8 / (2.8 + z2);
    viewX[i] = x1;
    viewY[i] = y1;
    viewZ[i] = z2;
    invW[i] = perspective;
    screenX[i] = centerX + x1 * scale * perspective;
    screenY[i] = centerY - y1 * scale * perspective;
  }

  final triangleCount = scene.totalTriangles;
  var order = List<int>.generate(triangleCount, (i) => i);
  if (request.maxFaces >= 0 && order.length > request.maxFaces) {
    // Order no longer matters for correctness, but a budget still does: keep
    // the nearest triangles when a mesh is enormous.
    final nearest = Float32List(triangleCount);
    for (var i = 0; i < triangleCount; i += 1) {
      final a = scene.triangleIndices[i * 3];
      final b = scene.triangleIndices[i * 3 + 1];
      final c = scene.triangleIndices[i * 3 + 2];
      nearest[i] = math.max(invW[a], math.max(invW[b], invW[c]));
    }
    order.sort((a, b) => nearest[b].compareTo(nearest[a]));
    order = order.sublist(0, request.maxFaces);
  }

  final (lx, ly, lz) = request.lightingMode == LightingMode.top
      ? (0.0, 1.0, 0.0)
      : (-0.45, 0.75, -0.5);
  final lightDirection = Vec3(lx, ly, lz);
  final textured = request.renderMode == RenderMode.textured;

  var drawn = 0;
  for (final triangleIndex in order) {
    final i0 = scene.triangleIndices[triangleIndex * 3];
    final i1 = scene.triangleIndices[triangleIndex * 3 + 1];
    final i2 = scene.triangleIndices[triangleIndex * 3 + 2];

    final x0 = screenX[i0], y0 = screenY[i0];
    final x1 = screenX[i1], y1 = screenY[i1];
    final x2 = screenX[i2], y2 = screenY[i2];

    final area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
    if (area == 0) continue;
    if (request.cullBackFaces && area < 0) continue;
    drawn += 1;

    final materialIndex = scene.triangleMaterial[triangleIndex];
    final material =
        (materialIndex >= 0 && materialIndex < scene.materials.length)
        ? scene.materials[materialIndex]
        : null;
    final hasUvs = scene.triangleHasUv[triangleIndex] == 1;
    final uvBase = triangleIndex * 6;
    final uvs = hasUvs
        ? <Vec2>[
            Vec2(scene.triangleUvs[uvBase], scene.triangleUvs[uvBase + 1]),
            Vec2(scene.triangleUvs[uvBase + 2], scene.triangleUvs[uvBase + 3]),
            Vec2(scene.triangleUvs[uvBase + 4], scene.triangleUvs[uvBase + 5]),
          ]
        : const <Vec2>[];

    final geometricNormal = _rasterFaceNormal(viewX, viewY, viewZ, i0, i1, i2);
    final viewTriangle = [
      Vec3(viewX[i0], viewY[i0], viewZ[i0]),
      Vec3(viewX[i1], viewY[i1], viewZ[i1]),
      Vec3(viewX[i2], viewY[i2], viewZ[i2]),
    ];
    final faceLight = request.lightingMode == LightingMode.unlit
        ? 1.0
        : faceDiffuseWithNormalMap(
            geometricNormal: geometricNormal,
            lightDirection: lightDirection,
            viewPositions: viewTriangle,
            uvs: uvs,
          );

    final perPixelNormals =
        request.useNormalMaps &&
        request.lightingMode != LightingMode.unlit &&
        hasUvs &&
        material != null &&
        material.hasNormalMap &&
        !isDegenerateUvTriangle(uvs);

    final baseArgb = material == null
        ? 0xb4b4b4
        : (textured ? material.baseArgbTextured : material.baseArgbFlat);
    final opacity = material?.opacity ?? 1.0;
    final packedTint = scene.triangleTint[triangleIndex];

    var minX = math.min(x0, math.min(x1, x2)).floor();
    var maxX = math.max(x0, math.max(x1, x2)).ceil();
    var minY = math.min(y0, math.min(y1, y2)).floor();
    var maxY = math.max(y0, math.max(y1, y2)).ceil();
    if (minX < 0) minX = 0;
    if (minY < 0) minY = 0;
    if (maxX > width - 1) maxX = width - 1;
    if (maxY > height - 1) maxY = height - 1;
    if (minX > maxX || minY > maxY) continue;

    final invArea = 1.0 / area;
    final w0 = invW[i0], w1 = invW[i1], w2 = invW[i2];

    // Everything constant across the face, hoisted: doing this per pixel cost
    // more than the shading itself.
    final flatR = (baseArgb >> 16) & 0xff;
    final flatG = (baseArgb >> 8) & 0xff;
    final flatB = baseArgb & 0xff;
    final tinted = packedTint >= 0;
    final tintRFixed = tinted ? ((packedTint >> 16) & 0xff) : 256;
    final tintGFixed = tinted ? ((packedTint >> 8) & 0xff) : 256;
    final tintBFixed = tinted ? (packedTint & 0xff) : 256;
    final opaque = opacity >= 0.999;
    final inverseOpacity = 1 - opacity;
    final lightFixed = (faceLight * 256).toInt();

    // Blinn-Phong specular. The view direction is fixed (the camera looks
    // down +z), so the half vector is constant per face and only the normal
    // varies -- cheap enough to afford per pixel when a normal map is active.
    final specularStrength =
        textured &&
            request.useSpecular &&
            request.lightingMode != LightingMode.unlit
        ? (material?.specularFactor ?? 0).clamp(0.0, 1.0)
        : 0.0;
    final shininess = material == null
        ? 8.0
        : 4 + (1 - material.roughness.clamp(0.0, 1.0)) * 120;
    final emissivePixels = textured && request.useEmissiveMaps
        ? material?.emissivePixels
        : null;
    final emissiveFactor = material?.emissiveFactor ?? 0;
    final emissiveWidth = material?.emissiveWidth ?? 0;
    // Exporters routinely leave the factor at 0 while still assigning an
    // emissive texture. Honouring that literally would hide every emissive map
    // in the library, so a map with no factor renders at full strength.
    final emissiveScale = emissiveFactor <= 0
        ? 1.0
        : emissiveFactor.clamp(0.0, 4.0);

    final texPixels = textured && request.useBaseTexture && hasUvs
        ? material?.texturePixels
        : null;
    final texWidth = material?.textureWidth ?? 0;
    final texMaxX = texWidth - 1;
    final texMaxY = (material?.textureHeight ?? 0) - 1;

    final u0w = hasUvs ? uvs[0].x * w0 : 0.0;
    final v0w = hasUvs ? uvs[0].y * w0 : 0.0;
    final u1w = hasUvs ? uvs[1].x * w1 : 0.0;
    final v1w = hasUvs ? uvs[1].y * w1 : 0.0;
    final u2w = hasUvs ? uvs[2].x * w2 : 0.0;
    final v2w = hasUvs ? uvs[2].y * w2 : 0.0;

    // Barycentric weights are affine in screen space, so step them rather than
    // recomputing two edge functions per pixel.
    final b0dx = (y1 - y2) * invArea;
    final b1dx = (y2 - y0) * invArea;
    final b0dy = (x2 - x1) * invArea;
    final b1dy = (x0 - x2) * invArea;

    final startX = minX + 0.5;
    final startY = minY + 0.5;
    var rowB0 =
        ((x1 - startX) * (y2 - startY) - (x2 - startX) * (y1 - startY)) *
        invArea;
    var rowB1 =
        ((x2 - startX) * (y0 - startY) - (x0 - startX) * (y2 - startY)) *
        invArea;

    for (var py = minY; py <= maxY; py += 1) {
      var b0 = rowB0;
      var b1 = rowB1;
      var offset = py * width + minX;
      for (var px = minX; px <= maxX; px += 1, offset += 1) {
        final b2 = 1.0 - b0 - b1;
        if (b0 >= 0 && b1 >= 0 && b2 >= 0) {
          final pixelInvW = b0 * w0 + b1 * w1 + b2 * w2;
          if (pixelInvW > depth[offset]) {
            int r = flatR, g = flatG, b = flatB;
            double u = 0, v = 0;
            if (texPixels != null || perPixelNormals) {
              u = (b0 * u0w + b1 * u1w + b2 * u2w) / pixelInvW;
              v = (b0 * v0w + b1 * v1w + b2 * v2w) / pixelInvW;
            }
            if (texPixels != null) {
              var fu = u - u.floorToDouble();
              var fv = v - v.floorToDouble();
              if (fu < 0) fu += 1;
              if (fv < 0) fv += 1;
              final texelIndex =
                  (((fv * texMaxY).toInt() * texWidth) +
                      (fu * texMaxX).toInt()) *
                  4;
              if (texelIndex >= 0 && texelIndex + 2 < texPixels.length) {
                r = texPixels[texelIndex];
                g = texPixels[texelIndex + 1];
                b = texPixels[texelIndex + 2];
              }
            }
            if (tinted) {
              r = (r * tintRFixed) >> 8;
              g = (g * tintGFixed) >> 8;
              b = (b * tintBFixed) >> 8;
            }

            var shade = lightFixed;
            Vec3? pixelNormal;
            if (perPixelNormals) {
              final sampled = material.sampleNormal(u, v);
              if (sampled != null) {
                pixelNormal = sampled;
                shade =
                    (faceDiffuseWithNormalMap(
                              geometricNormal: geometricNormal,
                              lightDirection: lightDirection,
                              viewPositions: viewTriangle,
                              uvs: uvs,
                              sampledNormal: sampled,
                            ) *
                            256)
                        .toInt();
              }
            }

            r = (r * shade) >> 8;
            g = (g * shade) >> 8;
            b = (b * shade) >> 8;

            if (specularStrength > 0) {
              final highlight = _specularTerm(
                normal: pixelNormal ?? geometricNormal,
                lightDirection: lightDirection,
                shininess: shininess,
              );
              if (highlight > 0) {
                final add = (highlight * specularStrength * 255).toInt();
                r += add;
                g += add;
                b += add;
              }
            }

            if (emissivePixels != null && emissiveWidth > 0) {
              final emissive = material!.sampleEmissive(u, v);
              if (emissive != null) {
                // Additive: an emissive surface is lit by itself, so it does
                // not go dark when the geometric light misses it.
                r += (((emissive >> 16) & 0xff) * emissiveScale).toInt();
                g += (((emissive >> 8) & 0xff) * emissiveScale).toInt();
                b += ((emissive & 0xff) * emissiveScale).toInt();
              }
            }

            if (r > 255) r = 255;
            if (g > 255) g = 255;
            if (b > 255) b = 255;

            final target = offset * 4;
            if (opaque) {
              pixels[target] = r;
              pixels[target + 1] = g;
              pixels[target + 2] = b;
              pixels[target + 3] = 255;
            } else {
              // Translucent faces blend against whatever is already there.
              // Without sorting that is approximate: the price of correct
              // opaque depth.
              pixels[target] = (r * opacity + pixels[target] * inverseOpacity)
                  .toInt();
              pixels[target + 1] =
                  (g * opacity + pixels[target + 1] * inverseOpacity).toInt();
              pixels[target + 2] =
                  (b * opacity + pixels[target + 2] * inverseOpacity).toInt();
              pixels[target + 3] = 255;
            }
            depth[offset] = pixelInvW;
          }
        }
        b0 += b0dx;
        b1 += b1dx;
      }
      rowB0 += b0dy;
      rowB1 += b1dy;
    }
  }

  return RasterResult(
    pixels: pixels,
    width: width,
    height: height,
    drawnFaces: drawn,
    totalFaces: triangleCount,
  );
}

/// Renders a frame on a worker isolate, so a full-resolution frame does not
/// stall the window.
Future<RasterResult> rasterizeSceneInIsolate(RasterRequest request) {
  return Isolate.run(() => rasterizeScene(request));
}

/// Blinn-Phong highlight for a normal under a light.
///
/// The camera looks down +z here, so the view direction is constant and the
/// half vector needs no per-pixel camera maths.
double _specularTerm({
  required Vec3 normal,
  required Vec3 lightDirection,
  required double shininess,
}) {
  final lightLength = math.sqrt(
    lightDirection.x * lightDirection.x +
        lightDirection.y * lightDirection.y +
        lightDirection.z * lightDirection.z,
  );
  final normalLength = math.sqrt(
    normal.x * normal.x + normal.y * normal.y + normal.z * normal.z,
  );
  if (lightLength < 1e-9 || normalLength < 1e-9) return 0;

  // View direction towards the camera, plus the light, normalised.
  final hx = lightDirection.x / lightLength;
  final hy = lightDirection.y / lightLength;
  final hz = lightDirection.z / lightLength - 1;
  final halfLength = math.sqrt(hx * hx + hy * hy + hz * hz);
  if (halfLength < 1e-9) return 0;

  final cosine =
      ((normal.x * hx + normal.y * hy + normal.z * hz) /
              (normalLength * halfLength))
          .abs();
  return math.pow(cosine, shininess).toDouble();
}

Vec3 _rasterFaceNormal(
  Float32List viewX,
  Float32List viewY,
  Float32List viewZ,
  int i0,
  int i1,
  int i2,
) {
  final ux = viewX[i1] - viewX[i0];
  final uy = viewY[i1] - viewY[i0];
  final uz = viewZ[i1] - viewZ[i0];
  final vx = viewX[i2] - viewX[i0];
  final vy = viewY[i2] - viewY[i0];
  final vz = viewZ[i2] - viewZ[i0];
  return Vec3(uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx);
}

class MeshPainter extends CustomPainter {
  MeshPainter({
    required this.mesh,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.renderMode,
    required this.lightingMode,
    required this.cullBackFaces,
    this.useNormalMaps = true,
    this.uvSetOverride,
  });

  final MeshModel mesh;
  final double yaw;
  final double pitch;
  final double zoom;
  final RenderMode renderMode;
  final LightingMode lightingMode;
  final String? uvSetOverride;
  final bool cullBackFaces;
  final bool useNormalMaps;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scale = math.min(size.width, size.height) * .38 * zoom;
    final sy = math.sin(yaw);
    final cy = math.cos(yaw);
    final sx = math.sin(pitch);
    final cx = math.cos(pitch);
    final projected = <_Projected>[];
    final viewVertices = <Vec3>[];

    for (final vertex in mesh.vertices) {
      final x1 = vertex.x * cy + vertex.z * sy;
      final z1 = -vertex.x * sy + vertex.z * cy;
      final y1 = vertex.y * cx - z1 * sx;
      final z2 = vertex.y * sx + z1 * cx;
      final perspective = 2.8 / (2.8 + z2);
      viewVertices.add(Vec3(x1, y1, z2));
      projected.add(
        _Projected(
          center.dx + x1 * scale * perspective,
          center.dy - y1 * scale * perspective,
          z2,
        ),
      );
    }

    final facePaint = Paint()..style = PaintingStyle.fill;

    // Flat palette faces are the bulk of this kind of content, and they all
    // draw the same way: one triangle, one colour. Collect runs of them and
    // issue a single drawVertices instead of a path per face. The batch is
    // flushed whenever a differently-drawn face comes up, so the painter's
    // back-to-front order still holds.
    final batchPositions = <double>[];
    final batchColors = <int>[];
    final batchPaint = Paint()
      ..style = PaintingStyle.fill
      // Interior edges of a shared mesh line up exactly; antialiasing them
      // leaves visible seams between triangles.
      ..isAntiAlias = false;

    void flushFlatBatch() {
      if (batchPositions.isEmpty) return;
      final vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        Float32List.fromList(batchPositions),
        colors: Int32List.fromList(batchColors),
      );
      canvas.drawVertices(vertices, BlendMode.dst, batchPaint);
      batchPositions.clear();
      batchColors.clear();
    }

    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xff18324a).withValues(alpha: .62);
    final drawEdges =
        renderMode == RenderMode.wireframe || renderMode == RenderMode.solid;

    // Depth once per face, not once per comparison: the old comparator
    // recomputed both sides on every compare.
    final faces = mesh.faces;
    final depths = List<double>.filled(faces.length, 0);
    final visible = List<bool>.filled(faces.length, false);
    for (var index = 0; index < faces.length; index += 1) {
      final face = faces[index];
      if (face.indices.any((i) => i < 0 || i >= projected.length)) continue;
      depths[index] = _faceDepth(projected, face);
      if (cullBackFaces && face.indices.length >= 3) {
        final p0 = projected[face.indices[0]];
        final p1 = projected[face.indices[1]];
        final p2 = projected[face.indices[2]];
        if (isBackFacingTriangle(p0.x, p0.y, p1.x, p1.y, p2.x, p2.y)) {
          continue;
        }
      }
      visible[index] = true;
    }

    final order = selectRenderedFaceOrder(
      depths: depths,
      visible: visible,
      budget: maxRenderedFaces,
    );

    for (final faceIndex in order) {
      final face = faces[faceIndex];
      final material =
          (face.materialIndex >= 0 &&
              face.materialIndex < mesh.materials.length)
          ? mesh.materials[face.materialIndex]
          : null;
      final textureUvs = face.uvsFor(uvSetOverride ?? material?.uvSet);
      final light = _faceLight(
        viewVertices,
        face,
        lightingMode,
        material: material,
        uvs: textureUvs,
        useNormalMap: useNormalMaps,
      );
      // Synty-style palette models map an entire face to one texel, which
      // makes the UV triangle degenerate. The textured path bails out on that
      // (its inverse transform does not exist), so those faces used to render
      // as the bare base colour -- half of every model, unpainted. Sample the
      // texel and fill instead: same result, far cheaper.
      final flatTexel =
          renderMode == RenderMode.textured &&
              material != null &&
              textureUvs.length == 3 &&
              isDegenerateUvTriangle(textureUvs)
          // If the readback failed, the average texture colour still beats
          // showing the untextured base.
          ? (material.sampleTexture(textureUvs[0]) ?? material.textureColor)
          : null;

      if (flatTexel != null) {
        var faceColor = flatTexel;
        final vertexTint = mesh.averageFaceVertexColor(face);
        if (vertexTint != null) {
          faceColor = _multiplyColor(faceColor, vertexTint);
        }
        faceColor = _shadeColor(faceColor, light);
        final shaded = faceColor.withValues(
          alpha: mesh.opacityForMaterial(face.materialIndex),
        );

        if (face.indices.length == 3 && !drawEdges) {
          final p0 = projected[face.indices[0]];
          final p1 = projected[face.indices[1]];
          final p2 = projected[face.indices[2]];
          batchPositions.addAll([p0.x, p0.y, p1.x, p1.y, p2.x, p2.y]);
          final argb = shaded.toARGB32();
          batchColors.addAll([argb, argb, argb]);
          continue;
        }

        flushFlatBatch();
        final path = Path();
        final first = projected[face.indices.first];
        path.moveTo(first.x, first.y);
        for (final vertexIndex in face.indices.skip(1)) {
          final point = projected[vertexIndex];
          path.lineTo(point.x, point.y);
        }
        path.close();
        facePaint.color = shaded;
        canvas.drawPath(path, facePaint);
        if (drawEdges) canvas.drawPath(path, edgePaint);
        continue;
      }

      // Anything drawn another way has to wait for the batch to land first.
      flushFlatBatch();

      if (renderMode == RenderMode.textured &&
          material?.textureImage != null &&
          textureUvs.length == 3) {
        final p0 = projected[face.indices[0]];
        final p1 = projected[face.indices[1]];
        final p2 = projected[face.indices[2]];
        final vertexTint = mesh.averageFaceVertexColor(face);
        final texturedBase = Path()
          ..moveTo(p0.x, p0.y)
          ..lineTo(p1.x, p1.y)
          ..lineTo(p2.x, p2.y)
          ..close();

        // Lay down an opaque base first so transparent texels don't punch
        // through to the clear background.
        var baseColor = mesh.colorForMaterial(
          face.materialIndex,
          textured: false,
        );
        final materialOpacity = mesh.opacityForMaterial(face.materialIndex);
        if (vertexTint != null) {
          baseColor = _multiplyColor(baseColor, vertexTint);
        }
        facePaint.color = baseColor.withValues(alpha: materialOpacity);
        canvas.drawPath(texturedBase, facePaint);

        _drawTexturedTriangle(
          canvas,
          image: material!.textureImage!,
          a: Offset(p0.x, p0.y),
          b: Offset(p1.x, p1.y),
          c: Offset(p2.x, p2.y),
          uvA: textureUvs[0],
          uvB: textureUvs[1],
          uvC: textureUvs[2],
          alpha: materialOpacity,
        );
        if (vertexTint != null && !_isApproximatelyWhite(vertexTint)) {
          canvas.drawPath(
            texturedBase,
            Paint()
              ..color = vertexTint
              ..blendMode = BlendMode.modulate,
          );
        }
        if (light < 0.999) {
          canvas.drawPath(
            texturedBase,
            Paint()..color = Colors.black.withValues(alpha: (1 - light) * .7),
          );
        }
        if (drawEdges) {
          canvas.drawPath(
            Path()
              ..moveTo(p0.x, p0.y)
              ..lineTo(p1.x, p1.y)
              ..lineTo(p2.x, p2.y)
              ..close(),
            edgePaint,
          );
        }
        continue;
      }
      final path = Path();
      final first = projected[face.indices.first];
      path.moveTo(first.x, first.y);
      for (final vertexIndex in face.indices.skip(1)) {
        final point = projected[vertexIndex];
        path.lineTo(point.x, point.y);
      }
      path.close();
      if (renderMode != RenderMode.wireframe) {
        var faceColor = mesh.colorForMaterial(
          face.materialIndex,
          textured: renderMode == RenderMode.textured,
        );
        final materialOpacity = mesh.opacityForMaterial(face.materialIndex);
        final vertexTint = mesh.averageFaceVertexColor(face);
        if (vertexTint != null) {
          faceColor = _multiplyColor(faceColor, vertexTint);
        }
        faceColor = _shadeColor(faceColor, light);
        // Opaque unless the material itself asks for transparency. The old
        // blanket .92 in textured mode let interior geometry bleed through
        // solid walls, which reads as a broken asset.
        final fillAlpha = renderMode == RenderMode.solid
            ? 1.0
            : materialOpacity;
        facePaint.color = faceColor.withValues(alpha: fillAlpha);
        canvas.drawPath(path, facePaint);
      }
      if (drawEdges) {
        canvas.drawPath(path, edgePaint);
      }
    }
    flushFlatBatch();
  }

  static bool _isApproximatelyWhite(Color color) {
    final red = (color.r * 255).round().clamp(0, 255);
    final green = (color.g * 255).round().clamp(0, 255);
    final blue = (color.b * 255).round().clamp(0, 255);
    return red >= 250 && green >= 250 && blue >= 250;
  }

  static Color _multiplyColor(Color a, Color b) {
    final aAlpha = (a.a * 255).round().clamp(0, 255);
    final aRed = (a.r * 255).round().clamp(0, 255);
    final aGreen = (a.g * 255).round().clamp(0, 255);
    final aBlue = (a.b * 255).round().clamp(0, 255);
    final bAlpha = (b.a * 255).round().clamp(0, 255);
    final bRed = (b.r * 255).round().clamp(0, 255);
    final bGreen = (b.g * 255).round().clamp(0, 255);
    final bBlue = (b.b * 255).round().clamp(0, 255);
    final alpha = (aAlpha * bAlpha / 255).round();
    final red = (aRed * bRed / 255).round();
    final green = (aGreen * bGreen / 255).round();
    final blue = (aBlue * bBlue / 255).round();
    return Color.fromARGB(alpha, red, green, blue);
  }

  static Color _shadeColor(Color color, double light) {
    final factor = light.clamp(0.0, 1.0);
    return Color.fromARGB(
      (color.a * 255).round().clamp(0, 255),
      ((color.r * 255) * factor).round().clamp(0, 255),
      ((color.g * 255) * factor).round().clamp(0, 255),
      ((color.b * 255) * factor).round().clamp(0, 255),
    );
  }

  static double _faceLight(
    List<Vec3> vertices,
    MeshFace face,
    LightingMode mode, {
    MeshMaterial? material,
    List<Vec2> uvs = const [],
    bool useNormalMap = true,
  }) {
    if (mode == LightingMode.unlit || face.indices.length < 3) return 1;
    final a = vertices[face.indices[0]];
    final b = vertices[face.indices[1]];
    final c = vertices[face.indices[2]];
    final ux = b.x - a.x;
    final uy = b.y - a.y;
    final uz = b.z - a.z;
    final vx = c.x - a.x;
    final vy = c.y - a.y;
    final vz = c.z - a.z;
    final nx = uy * vz - uz * vy;
    final ny = uz * vx - ux * vz;
    final nz = ux * vy - uy * vx;
    final normalLength = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (normalLength < 1e-9) return 1;

    final (lx, ly, lz) = mode == LightingMode.top
        ? (0.0, 1.0, 0.0)
        : (-0.45, 0.75, -0.5);

    final sampled = useNormalMap && material != null && material.hasNormalMap
        ? material.sampleNormal(
            Vec2(
              (uvs[0].x + uvs[1].x + uvs[2].x) / 3,
              (uvs[0].y + uvs[1].y + uvs[2].y) / 3,
            ),
          )
        : null;

    return faceDiffuseWithNormalMap(
      geometricNormal: Vec3(nx, ny, nz),
      lightDirection: Vec3(lx, ly, lz),
      viewPositions: [a, b, c],
      uvs: uvs,
      sampledNormal: uvs.length == 3 ? sampled : null,
    );
  }

  static void _drawTexturedTriangle(
    Canvas canvas, {
    required ui.Image image,
    required Offset a,
    required Offset b,
    required Offset c,
    required Vec2 uvA,
    required Vec2 uvB,
    required Vec2 uvC,
    double alpha = 1.0,
  }) {
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    final s0 = Offset(uvA.x * w, uvA.y * h);
    final s1 = Offset(uvB.x * w, uvB.y * h);
    final s2 = Offset(uvC.x * w, uvC.y * h);

    final du1 = s1.dx - s0.dx;
    final dv1 = s1.dy - s0.dy;
    final du2 = s2.dx - s0.dx;
    final dv2 = s2.dy - s0.dy;
    final det = du1 * dv2 - dv1 * du2;
    if (det.abs() < 1e-6) return;

    final invDet = 1.0 / det;
    final dx1 = b.dx - a.dx;
    final dy1 = b.dy - a.dy;
    final dx2 = c.dx - a.dx;
    final dy2 = c.dy - a.dy;

    final m0 = (dx1 * dv2 - dx2 * dv1) * invDet;
    final m4 = (dx2 * du1 - dx1 * du2) * invDet;
    final m1 = (dy1 * dv2 - dy2 * dv1) * invDet;
    final m5 = (dy2 * du1 - dy1 * du2) * invDet;
    final m12 = a.dx - (m0 * s0.dx + m4 * s0.dy);
    final m13 = a.dy - (m1 * s0.dx + m5 * s0.dy);

    final clip = Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(b.dx, b.dy)
      ..lineTo(c.dx, c.dy)
      ..close();

    canvas.save();
    canvas.clipPath(clip);
    canvas.transform(
      Float64List.fromList([
        m0,
        m1,
        0,
        0,
        m4,
        m5,
        0,
        0,
        0,
        0,
        1,
        0,
        m12,
        m13,
        0,
        1,
      ]),
    );
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()
        ..color = Color.fromARGB(
          (alpha.clamp(0.0, 1.0) * 255).round(),
          255,
          255,
          255,
        )
        ..blendMode = BlendMode.modulate,
    );
    canvas.restore();
  }

  static double _faceDepth(List<_Projected> projected, MeshFace face) {
    var depth = 0.0;
    for (final index in face.indices) {
      depth += projected[index].z;
    }
    return depth / face.indices.length;
  }

  @override
  bool shouldRepaint(covariant MeshPainter oldDelegate) {
    return oldDelegate.mesh != mesh ||
        oldDelegate.yaw != yaw ||
        oldDelegate.pitch != pitch ||
        oldDelegate.zoom != zoom ||
        oldDelegate.renderMode != renderMode ||
        oldDelegate.lightingMode != lightingMode ||
        oldDelegate.cullBackFaces != cullBackFaces ||
        oldDelegate.useNormalMaps != useNormalMaps ||
        oldDelegate.uvSetOverride != uvSetOverride;
  }
}

/// Upper bound on triangles drawn per frame. When a mesh exceeds it the
/// viewer draws the nearest [maxRenderedFaces] and says so in the overlay --
/// it must never quietly drop geometry in an inspection tool.
const maxRenderedFaces = 14000;

/// Diffuse term for a face, optionally perturbed by a normal map.
///
/// Shading here is per face, not per pixel: this renderer draws a triangle at a
/// time, so a normal map can tilt a whole face but cannot add detail inside it.
/// Faces pinned to a single texel (the palette case) have no UV gradient and
/// therefore no tangent frame, so they keep their geometric normal.
double faceDiffuseWithNormalMap({
  required Vec3 geometricNormal,
  required Vec3 lightDirection,
  required List<Vec3> viewPositions,
  required List<Vec2> uvs,
  Vec3? sampledNormal,
}) {
  Vec3 normal = geometricNormal;

  if (sampledNormal != null && uvs.length == 3 && viewPositions.length == 3) {
    // Tangent from the triangle's position and UV derivatives.
    final e1 = Vec3(
      viewPositions[1].x - viewPositions[0].x,
      viewPositions[1].y - viewPositions[0].y,
      viewPositions[1].z - viewPositions[0].z,
    );
    final e2 = Vec3(
      viewPositions[2].x - viewPositions[0].x,
      viewPositions[2].y - viewPositions[0].y,
      viewPositions[2].z - viewPositions[0].z,
    );
    final du1 = uvs[1].x - uvs[0].x;
    final dv1 = uvs[1].y - uvs[0].y;
    final du2 = uvs[2].x - uvs[0].x;
    final dv2 = uvs[2].y - uvs[0].y;
    final determinant = du1 * dv2 - du2 * dv1;

    if (determinant.abs() > 1e-9) {
      final inverse = 1.0 / determinant;
      final tangent = Vec3(
        (e1.x * dv2 - e2.x * dv1) * inverse,
        (e1.y * dv2 - e2.y * dv1) * inverse,
        (e1.z * dv2 - e2.z * dv1) * inverse,
      );
      final bitangent = Vec3(
        (e2.x * du1 - e1.x * du2) * inverse,
        (e2.y * du1 - e1.y * du2) * inverse,
        (e2.z * du1 - e1.z * du2) * inverse,
      );

      Vec3 unit(Vec3 v) {
        final length = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
        if (length < 1e-9) return v;
        return Vec3(v.x / length, v.y / length, v.z / length);
      }

      final t = unit(tangent);
      final b = unit(bitangent);
      final n = unit(geometricNormal);
      final perturbed = Vec3(
        t.x * sampledNormal.x + b.x * sampledNormal.y + n.x * sampledNormal.z,
        t.y * sampledNormal.x + b.y * sampledNormal.y + n.y * sampledNormal.z,
        t.z * sampledNormal.x + b.z * sampledNormal.y + n.z * sampledNormal.z,
      );
      normal = unit(perturbed);
    }
  }

  final normalLength = math.sqrt(
    normal.x * normal.x + normal.y * normal.y + normal.z * normal.z,
  );
  final lightLength = math.sqrt(
    lightDirection.x * lightDirection.x +
        lightDirection.y * lightDirection.y +
        lightDirection.z * lightDirection.z,
  );
  if (normalLength < 1e-9 || lightLength < 1e-9) return 1;

  final diffuse =
      ((normal.x * lightDirection.x +
                  normal.y * lightDirection.y +
                  normal.z * lightDirection.z) /
              (normalLength * lightLength))
          .abs();
  return 0.42 + diffuse * 0.58;
}

/// Whether a face's three UV corners land on (effectively) one texel.
///
/// True for flat-colour palette faces, which is most of a Synty model. Such a
/// triangle has no invertible UV-to-screen transform, so it cannot be drawn by
/// sampling across the triangle; it has to be filled with the single colour.
bool isDegenerateUvTriangle(List<Vec2> uvs, {double epsilon = 1e-6}) {
  if (uvs.length < 3) return true;
  final area =
      (uvs[1].x - uvs[0].x) * (uvs[2].y - uvs[0].y) -
      (uvs[2].x - uvs[0].x) * (uvs[1].y - uvs[0].y);
  return area.abs() < epsilon;
}

/// Screen-space signed area of a projected triangle.
///
/// Convention: an outward-facing surface of a solid projects to a *positive*
/// signed area under this renderer's Y-flipping projection, so a negative area
/// means the triangle is turned away from the camera.
///
/// Do not re-derive this from a single plane fixture: a lone two-sided triangle
/// tells you nothing about which side is "out", and getting this backwards
/// culls the outside of every closed model and shows you its interior.
/// test/renderer_geometry_test.dart pins it against a cube whose winding is
/// derived from outward geometric normals.
double triangleSignedArea(
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
) {
  return (bx - ax) * (cy - ay) - (cx - ax) * (by - ay);
}

bool isBackFacingTriangle(
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
) {
  return triangleSignedArea(ax, ay, bx, by, cx, cy) < 0;
}

/// Chooses which faces to draw and in what order: back-to-front over the
/// visible set, capped to [budget] by dropping the farthest faces. Depth-
/// priority beats the index stride this replaced, which sampled the mesh
/// uniformly and left holes everywhere.
List<int> selectRenderedFaceOrder({
  required List<double> depths,
  required List<bool> visible,
  required int budget,
}) {
  final order = <int>[];
  for (var index = 0; index < depths.length; index += 1) {
    if (visible[index]) order.add(index);
  }
  // Larger depth is farther from the camera, so descending is back-to-front.
  order.sort((a, b) => depths[b].compareTo(depths[a]));
  if (budget >= 0 && order.length > budget) {
    return order.sublist(order.length - budget);
  }
  return order;
}

enum AssetSortMode { path, name, size, modified, type }

extension AssetSortModeLabel on AssetSortMode {
  String get label => switch (this) {
    AssetSortMode.path => 'Path',
    AssetSortMode.name => 'Name',
    AssetSortMode.size => 'Size',
    AssetSortMode.modified => 'Modified',
    AssetSortMode.type => 'Type',
  };
}

/// Sorts a copy of [assets]. Ties always fall back to the relative path so the
/// order is total and does not wobble between rebuilds.
List<AssetItem> sortAssets(List<AssetItem> assets, AssetSortMode mode) {
  int byPath(AssetItem a, AssetItem b) =>
      a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase());

  final sorted = [...assets];
  sorted.sort((a, b) {
    final primary = switch (mode) {
      AssetSortMode.path => 0,
      AssetSortMode.name => a.name.toLowerCase().compareTo(
        b.name.toLowerCase(),
      ),
      // Largest first: when sorting by size you are usually hunting for the
      // heavy assets.
      AssetSortMode.size => b.size.compareTo(a.size),
      AssetSortMode.modified => b.modified.compareTo(a.modified),
      AssetSortMode.type => a.effectiveType.compareTo(b.effectiveType),
    };
    if (primary != 0) return primary;
    return byPath(a, b);
  });
  return sorted;
}

enum RenderMode { textured, solid, wireframe }

enum LightingMode { corner, top, unlit }

class _Projected {
  const _Projected(this.x, this.y, this.z);
  final double x;
  final double y;
  final double z;
}

class VerticalResizeHandle extends StatelessWidget {
  const VerticalResizeHandle({required this.onDrag, super.key});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        child: Container(
          width: 12,
          decoration: BoxDecoration(
            color: const Color(0xffeef1f6),
            border: Border(
              left: BorderSide(color: Colors.black.withValues(alpha: .08)),
              right: BorderSide(color: Colors.black.withValues(alpha: .08)),
            ),
          ),
          child: Center(
            child: Container(
              width: 3,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AssetDetailsPanel extends StatelessWidget {
  const AssetDetailsPanel({
    required this.item,
    required this.allAssets,
    required this.catalogRevision,
    required this.onActivateAsset,
    super.key,
  });

  final AssetItem item;
  final List<AssetItem> allAssets;
  final int catalogRevision;
  final ValueChanged<AssetItem> onActivateAsset;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xfff8fafc),
        border: Border.all(color: Colors.black12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: ListView(
          children: [
            Text(
              item.name,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            CopyablePathText(
              path: item.path,
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 14),
            DetailRow(
              label: 'Type',
              value: '${item.effectiveType} / ${item.ext}',
            ),
            DetailRow(label: 'Source', value: item.sourceName),
            DetailRow(
              label: 'Folder',
              value: isZipVirtualPath(item.path)
                  ? item.relativePath
                  : parentPath(item.path),
              isPath: true,
              // The details panel is narrow and these paths are long. Two
              // lines cut a zip entry path down to something unreadable;
              // four fits the ones that actually occur.
              pathMaxLines: 4,
            ),
            DetailRow(label: 'Size', value: formatBytes(item.size)),
            DetailRow(
              label: 'Modified',
              value: item.modified.toLocal().toString(),
            ),
            const SizedBox(height: 12),
            const Text('Tags', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: item.tags.map((tag) => Chip(label: Text(tag))).toList(),
            ),
            if (item.type == 'model') ...[
              const SizedBox(height: 14),
              ModelTextureDiagnostics(
                asset: item,
                allAssets: allAssets,
                catalogRevision: catalogRevision,
                onActivateAsset: onActivateAsset,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A path that may not fit its column: shows the full value on hover and
/// offers a one-click copy, so a truncated path is still usable.
class CopyablePathText extends StatelessWidget {
  const CopyablePathText({
    required this.path,
    this.maxLines = 2,
    this.style,
    super.key,
  });

  final String path;
  final int maxLines;
  final TextStyle? style;

  /// Trims from the *front* until the text fits.
  ///
  /// Two long paths under the same root differ at the end, so cutting the tail
  /// renders them identical on screen -- which is exactly what the source
  /// folder list used to do.
  String fitPathToWidth(String value, double width, TextStyle? textStyle) {
    bool fits(String candidate) {
      final painter = TextPainter(
        text: TextSpan(text: candidate, style: textStyle),
        maxLines: maxLines,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      return !painter.didExceedMaxLines;
    }

    if (width <= 0 || width.isInfinite || fits(value)) return value;
    // A path tail has no spaces, so without a break opportunity it cannot wrap
    // and only one line's worth survives however many lines are allowed.

    // Binary search for the shortest head that has to go.
    var low = 0;
    var high = value.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (fits(breakableAtSeparators('...${value.substring(mid)}'))) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    // Prefer cutting at a folder boundary: "...\FBX\wall.fbx" reads better
    // than "...BX\wall.fbx".
    final separator = value.indexOf(RegExp(r'[\\/]'), low);
    if (separator >= 0 &&
        fits(breakableAtSeparators('...${value.substring(separator)}'))) {
      return '...${value.substring(separator)}';
    }
    return '...${value.substring(low)}';
  }

  /// Inserts zero-width spaces after path separators so a long path can wrap
  /// at folder boundaries instead of being stuck on one line.
  static String breakableAtSeparators(String value) =>
      value.replaceAllMapped(RegExp(r'[\\/]'), (match) => '${match[0]}\u200b');

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ?? DefaultTextStyle.of(context).style;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Tooltip(
            message: path,
            waitDuration: const Duration(milliseconds: 400),
            child: LayoutBuilder(
              builder: (context, constraints) => Text(
                breakableAtSeparators(
                  fitPathToWidth(path, constraints.maxWidth, effectiveStyle),
                ),
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Copy full path',
          icon: const Icon(Icons.content_copy, size: 16),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: path));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Copied: $path'),
                duration: const Duration(seconds: 2),
              ),
            );
          },
        ),
      ],
    );
  }
}

class DetailRow extends StatelessWidget {
  const DetailRow({
    required this.label,
    required this.value,
    this.isPath = false,
    this.pathMaxLines = 2,
    super.key,
  });

  final String label;
  final String value;

  /// Render the value as a hoverable, copyable path.
  final bool isPath;

  /// How many lines a path may use before it is trimmed from the front.
  final int pathMaxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.black54,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: isPath
                ? CopyablePathText(path: value, maxLines: pathMaxLines)
                : Text(value),
          ),
        ],
      ),
    );
  }
}

class ModelTextureDiagnostics extends StatefulWidget {
  const ModelTextureDiagnostics({
    required this.asset,
    required this.allAssets,
    required this.catalogRevision,
    required this.onActivateAsset,
    super.key,
  });

  final AssetItem asset;
  final List<AssetItem> allAssets;
  final int catalogRevision;
  final ValueChanged<AssetItem> onActivateAsset;

  @override
  State<ModelTextureDiagnostics> createState() =>
      _ModelTextureDiagnosticsState();
}

class _ModelTextureDiagnosticsState extends State<ModelTextureDiagnostics> {
  // Held in state, never built inline: creating this future in build() made
  // every unrelated rebuild re-run the FBX importer.
  Future<List<TextureDiscoveryEntry>>? referencesFuture;
  Future<MeshModel>? meshFuture;

  @override
  void initState() {
    super.initState();
    referencesFuture = _loadReferences();
    meshFuture = _loadMesh();
  }

  @override
  void didUpdateWidget(covariant ModelTextureDiagnostics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id ||
        oldWidget.catalogRevision != widget.catalogRevision) {
      referencesFuture = _loadReferences();
      meshFuture = _loadMesh();
    }
  }

  Future<List<TextureDiscoveryEntry>>? _loadReferences() {
    if (widget.asset.ext != 'fbx') return null;
    return loadModelTextureReferenceEntries(widget.asset, widget.allAssets);
  }

  /// The mesh itself, so the panel can tell "this material is a flat colour"
  /// apart from "this model's textures are missing". Shares the cached import.
  Future<MeshModel>? _loadMesh() {
    if (!_previewableModelExts.contains(widget.asset.ext)) return null;
    return MeshLoadCache.load(widget.asset, allAssets: widget.allAssets);
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final allAssets = widget.allAssets;
    final onActivateAsset = widget.onActivateAsset;
    final nearby = findNearbyTextures(asset, allAssets);
    if (_previewableModelExts.contains(asset.ext)) {
      return FutureBuilder<MeshModel>(
        future: meshFuture,
        builder: (context, meshSnapshot) =>
            FutureBuilder<List<TextureDiscoveryEntry>>(
              future: referencesFuture,
              builder: (context, snapshot) {
                final referenced =
                    snapshot.data ?? const <TextureDiscoveryEntry>[];
                final pathKeys = referenced
                    .where((entry) => entry.copyPath.isNotEmpty)
                    .map((entry) => normalizePathKey(entry.copyPath))
                    .toSet();
                final nearbyEntries = nearby
                    .where(
                      (texture) =>
                          !pathKeys.contains(normalizePathKey(texture.path)),
                    )
                    .map(
                      (texture) => TextureDiscoveryEntry(
                        label: texture.relativePath,
                        copyPath: texture.path,
                        jumpAsset: texture,
                      ),
                    )
                    .toList();
                final combined = [...referenced, ...nearbyEntries];
                return TextureDiscoveryBox(
                  title: snapshot.connectionState == ConnectionState.done
                      ? 'Texture discovery'
                      : 'Texture discovery...',
                  message: combined.isEmpty
                      ? 'No texture references and no nearby candidates.'
                      : '${referenced.length} model references · '
                            '${nearby.length} nearby scanned candidates.',
                  entries: combined,
                  onActivateAsset: onActivateAsset,
                  mesh: snapshot.connectionState == ConnectionState.done
                      ? meshSnapshot.data
                      : null,
                );
              },
            ),
      );
    }
    return TextureDiscoveryBox(
      title: 'Texture discovery',
      message: nearby.isEmpty
          ? 'No scanned nearby textures found. For FBX this usually means textures are embedded, missing, or in a folder not scanned yet.'
          : '${nearby.length} nearby texture candidates found.',
      entries: nearby
          .map(
            (texture) => TextureDiscoveryEntry(
              label: texture.relativePath,
              copyPath: texture.path,
              jumpAsset: texture,
            ),
          )
          .toList(),
      onActivateAsset: onActivateAsset,
    );
  }
}

/// A texture reference, with the file name kept readable.
///
/// These are long -- a zip entry path runs to a hundred characters -- and the
/// panel is narrow, so a single ellipsised line showed the folders and cut off
/// the one part that identifies the file. The name goes on its own line and
/// the folders sit under it, dimmed, wrapping if there is room.
class TextureEntryLabel extends StatelessWidget {
  const TextureEntryLabel({
    required this.label,
    required this.linked,
    super.key,
  });

  final String label;

  /// Whether this points at an asset the panel can jump to.
  final bool linked;

  @override
  Widget build(BuildContext context) {
    final (folder, name) = splitTextureLabel(label);
    final linkColor = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: linked ? linkColor : Colors.black87,
            decoration: linked ? TextDecoration.underline : TextDecoration.none,
          ),
        ),
        if (folder.isNotEmpty)
          Text(
            folder,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.black45),
          ),
      ],
    );
  }
}

/// Splits a texture reference into (folders, file name).
///
/// Handles the arrow form the resolver writes ("asked -> found") by keeping
/// the resolved side, and the trailing marker it adds ("(missing)") by leaving
/// it on the name, where it is the point.
(String, String) splitTextureLabel(String label) {
  var value = label.trim();
  final arrow = value.lastIndexOf(' -> ');
  if (arrow >= 0) value = value.substring(arrow + 4).trim();
  final separator = value.lastIndexOf(RegExp(r'[\\/]'));
  if (separator < 0) return ('', value);
  return (value.substring(0, separator), value.substring(separator + 1));
}

class TextureDiscoveryEntry {
  const TextureDiscoveryEntry({
    required this.label,
    required this.copyPath,
    this.resolved = true,
    this.jumpAsset,
  });

  final String label;
  final String copyPath;

  /// Whether the reference points at a texture that actually exists. Callers
  /// must read this rather than parsing [label], which is display text.
  final bool resolved;
  final AssetItem? jumpAsset;
}

/// Model formats the preview can import and therefore introspect.
///
/// OBJ is here because the parser now keeps `vt` and `usemtl`; before that it
/// produced geometry with no texture information, so there was nothing for the
/// discovery panel to say about one.
const _previewableModelExts = {'fbx', 'obj'};

/// One material, with its resolved texture shown rather than described.
///
/// "Is this model textured?" is a question a swatch answers instantly, and a
/// list of paths does not: a model can resolve its atlas correctly and still
/// look grey, because that is the part of the atlas it uses.
/// The one-line status under a material's swatch.
///
/// "flat colour" and "asked for a texture and did not get one" look identical
/// on screen but mean opposite things: the first is how a collision hull is
/// supposed to look, the second is a broken link worth chasing.
String materialSummaryLine(MeshMaterial material, {int? width, int? height}) {
  final extras = <String>[
    if (material.hasNormalMap) 'normal map',
    if (material.hasEmissiveMap) 'emissive map',
  ];
  final suffix = extras.isEmpty ? '' : ', ${extras.join(', ')}';

  if (width != null && height != null) {
    final embedded = material.hasEmbeddedTexture ? ' (embedded)' : '';
    return 'textured ${width}x$height$embedded$suffix';
  }
  if (material.texturesMissing) {
    final count = material.textures.length;
    final noun = count == 1 ? 'texture' : 'textures';
    return 'missing: asks for $count $noun, none found$suffix';
  }
  return 'flat colour, no texture$suffix';
}

/// Picks a texture for a model by hand, from what was scanned beside it.
///
/// Automatic resolution covers the models that say what they want. This covers
/// the ones that do not: an OBJ with no `mtllib`, or a model whose pack is
/// missing. The candidates are the same nearby textures the discovery panel
/// lists, so the answer is already on screen -- this applies one.
class TexturePickerButton extends StatelessWidget {
  const TexturePickerButton({
    required this.candidates,
    required this.chosenPath,
    required this.onChosen,
    super.key,
  });

  final List<AssetItem> candidates;
  final String? chosenPath;

  /// Null clears the choice and goes back to whatever resolved on its own.
  final ValueChanged<String?> onChosen;

  @override
  Widget build(BuildContext context) {
    if (candidates.isEmpty) return const SizedBox.shrink();
    final chosen = chosenPath;
    final chosenName = chosen == null
        ? null
        : candidates
              .where((asset) => asset.path == chosen)
              .map((asset) => asset.name)
              .firstOrNull;

    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.black12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              chosenName == null ? 'Texture: auto' : 'Texture: $chosenName',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: chosenName == null ? Colors.black54 : Colors.black87,
              ),
            ),
          ),
          PopupMenuButton<String?>(
            tooltip: 'Apply a scanned texture to this model',
            icon: const Icon(Icons.texture, size: 18),
            onSelected: onChosen,
            itemBuilder: (context) => [
              const PopupMenuItem<String?>(
                value: null,
                child: Text('Auto (whatever the model asks for)'),
              ),
              const PopupMenuDivider(),
              for (final asset in candidates.take(40))
                PopupMenuItem<String?>(
                  value: asset.path,
                  child: Text(
                    asset.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Makes this model the one animation clips are played on.
///
/// Only offered for a model that actually carries skin weights: a prop has
/// nothing for a clip to move, and offering it would just fail later.
class AnimationCharacterButton extends StatelessWidget {
  const AnimationCharacterButton({
    required this.isChosen,
    required this.onPressed,
    super.key,
  });

  final bool isChosen;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(isChosen ? Icons.person : Icons.person_outline, size: 18),
      label: Text(isChosen ? 'Animation character' : 'Use for animations'),
    );
  }
}

/// The strip of controls above the 3D viewport.
///
/// These used to float over the model in the top-right corner, which is where
/// a model's head usually is. Wrapping keeps every control reachable at any
/// panel width instead of running off the edge.
class ModelToolbarBar extends StatelessWidget {
  const ModelToolbarBar({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xfff4f6fa),
        border: Border(bottom: BorderSide(color: Colors.black12)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      ),
    );
  }
}

/// One switchable shading channel.
class ShadingChannel {
  const ShadingChannel({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
}

/// The per-channel switches over the 3D preview.
///
/// Only channels the model actually carries are listed, so the panel is empty
/// for a flat-colour collision hull and four rows deep for a full PBR-ish
/// material. Switching one off answers "what is this channel doing?", which
/// staring at the combined result cannot.
class ShadingChannelPanel extends StatelessWidget {
  const ShadingChannelPanel({required this.channels, super.key});

  final List<ShadingChannel> channels;

  @override
  Widget build(BuildContext context) {
    if (channels.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final channel in channels)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(channel.label),
                Switch(value: channel.value, onChanged: channel.onChanged),
              ],
            ),
        ],
      ),
    );
  }
}

class MaterialSummaryRow extends StatelessWidget {
  const MaterialSummaryRow({required this.material, super.key});

  final MeshMaterial material;

  @override
  Widget build(BuildContext context) {
    final image = material.textureImage;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: material.color,
              border: Border.all(color: Colors.black26),
              borderRadius: BorderRadius.circular(4),
            ),
            clipBehavior: Clip.antiAlias,
            child: image == null
                ? null
                : RawImage(image: image, fit: BoxFit.cover),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  material.name.isEmpty ? '(unnamed material)' : material.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
                Text(
                  materialSummaryLine(
                    material,
                    width: image?.width,
                    height: image?.height,
                  ),
                  style: TextStyle(
                    fontSize: 11,
                    color: image == null && material.texturesMissing
                        ? const Color(0xffb3261e)
                        : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class TextureDiscoveryBox extends StatelessWidget {
  const TextureDiscoveryBox({
    required this.title,
    required this.message,
    required this.entries,
    required this.onActivateAsset,
    this.mesh,
    super.key,
  });

  /// Present once the model has been read, so the box can show what the
  /// material actually is instead of only listing paths.
  final MeshModel? mesh;

  final String title;
  final String message;
  final List<TextureDiscoveryEntry> entries;

  /// A model whose materials carry no texture at all is not a problem to be
  /// solved -- Synty collision hulls, for instance, are a flat colour. Saying
  /// so beats implying something is missing.
  /// Every material asked for textures and none of them resolved.
  ///
  /// Distinct from [_isDeliberatelyUntextured]: this model is meant to be
  /// textured and the links are broken.
  bool get _allTextureLinksBroken =>
      mesh != null &&
      mesh!.materials.isNotEmpty &&
      mesh!.materials.every((material) => material.texturesMissing);

  bool get _isDeliberatelyUntextured =>
      mesh != null &&
      mesh!.materials.isNotEmpty &&
      mesh!.materials.every(
        (material) =>
            material.textures.isEmpty &&
            material.resolvedTextures.isEmpty &&
            !material.hasEmbeddedTexture,
      );
  final ValueChanged<AssetItem> onActivateAsset;

  String _copyablePath(String value) {
    var path = value;
    final arrowIndex = path.indexOf(' -> ');
    if (arrowIndex >= 0) {
      path = path.substring(arrowIndex + 4);
    }
    final markerIndex = path.indexOf(' (');
    if (markerIndex >= 0) {
      path = path.substring(0, markerIndex);
    }
    return path.trim();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              _allTextureLinksBroken
                  ? 'This model is meant to be textured, but none of the '
                        'images its materials name could be found. It is '
                        'rendering as flat colour because the links are '
                        'broken, not because it has no textures.'
                  : _isDeliberatelyUntextured
                  ? 'This model has no textures: its material is a flat '
                        'colour. Collision hulls and blockout meshes normally '
                        'look like this.'
                  : message,
              style: TextStyle(
                color: _allTextureLinksBroken
                    ? const Color(0xffb3261e)
                    : Colors.black54,
              ),
            ),
            if (mesh != null && mesh!.materials.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final material in mesh!.materials.take(4))
                MaterialSummaryRow(material: material),
            ],
            const SizedBox(height: 8),
            for (final entry in entries.take(10))
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: entry.jumpAsset == null
                          ? null
                          : () => onActivateAsset(entry.jumpAsset!),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: TextureEntryLabel(
                          label: entry.label,
                          linked: entry.jumpAsset != null,
                        ),
                      ),
                    ),
                  ),
                  if (entry.jumpAsset != null)
                    IconButton(
                      tooltip: 'Open texture asset',
                      icon: const Icon(Icons.open_in_new, size: 16),
                      onPressed: () => onActivateAsset(entry.jumpAsset!),
                    ),
                  IconButton(
                    tooltip: 'Copy texture path',
                    icon: const Icon(Icons.content_copy, size: 16),
                    onPressed: () async {
                      final copyPath = entry.copyPath.isEmpty
                          ? _copyablePath(entry.label)
                          : entry.copyPath;
                      if (copyPath.isEmpty) return;
                      await Clipboard.setData(ClipboardData(text: copyPath));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Texture path copied.')),
                      );
                    },
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

Future<List<String>> loadModelTextureReferences(
  AssetItem asset,
  List<AssetItem> allAssets,
) async {
  final entries = await loadModelTextureReferenceEntries(asset, allAssets);
  return entries.map((entry) => entry.label).toList();
}

/// Number of texture-reference scans started. Test visibility only: the
/// diagnostics panel must not restart one per rebuild.
int textureReferenceScanCount = 0;

Future<List<TextureDiscoveryEntry>> loadModelTextureReferenceEntries(
  AssetItem asset,
  List<AssetItem> allAssets,
) async {
  if (!_previewableModelExts.contains(asset.ext)) return const [];
  textureReferenceScanCount += 1;
  // Shares the import with the 3D preview instead of spawning a second helper.
  final mesh = await MeshLoadCache.load(asset, allAssets: allAssets);
  return mesh.allTexturePaths.map((path) {
    final resolved = resolveTextureReference(
      asset.path,
      path,
      allAssets: allAssets,
      allowFallbackLookup: false,
    );
    final existingPath = resolved ?? path;
    final exists = isZipVirtualPath(existingPath)
        ? allAssets.any(
            (candidate) =>
                normalizePathKey(candidate.path) ==
                normalizePathKey(existingPath),
          )
        : File(existingPath).existsSync();
    AssetItem? jumpAsset;
    if (exists) {
      final key = normalizePathKey(existingPath);
      for (final candidate in allAssets) {
        if (normalizePathKey(candidate.path) == key) {
          jumpAsset = candidate;
          break;
        }
      }
    }
    // The label is built from `exists`; nothing may parse it back out.
    late final String label;
    if (resolved == null || resolved == path) {
      label = '$path ${exists ? "(found)" : "(missing)"}';
    } else {
      label = '$path -> $resolved ${exists ? "(found)" : "(missing)"}';
    }
    return TextureDiscoveryEntry(
      label: label,
      copyPath: existingPath,
      resolved: exists,
      jumpAsset: jumpAsset,
    );
  }).toList();
}

/// The one place asset ids are built.
///
/// Identity is *where an asset is*, never what it currently contains. Ids used
/// to embed size and modified time, so editing a file changed its id and it
/// silently dropped out of saved projects and lost its ignore flag.
///
/// Rules:
///  - separators normalised to `/`
///  - lowercased, because the app is Windows-first and its paths are
///    case-insensitive (a Linux port would need to revisit this)
///  - [relativePath] is relative to [sourceRoot] and must NOT carry the
///    `sourceName/` display prefix, which duplicates the source root
///  - readable, not hashed: these strings show up in the database and in bug
///    reports, and a debuggable id is worth more than a short one
///
/// ZIP entries pass a relative path of the form `pack.zip!/Textures/wall.png`.
String buildAssetId({
  required String sourceRoot,
  required String relativePath,
}) {
  String normalize(String value) =>
      value.trim().replaceAll('\\', '/').toLowerCase();
  return 'asset:v2:${normalize(sourceRoot)}|${normalize(relativePath)}';
}

/// Strips the `sourceName/` display prefix that [AssetItem.relativePath]
/// carries, so stored rows can be mapped back to an id.
String assetIdRelativePathFromStored({
  required String relativePath,
  required String sourceName,
}) {
  final prefix = '$sourceName/';
  final normalized = relativePath.replaceAll('\\', '/');
  if (normalized.toLowerCase().startsWith(prefix.toLowerCase())) {
    return normalized.substring(prefix.length);
  }
  return normalized;
}

String normalizePathKey(String value) {
  return value.trim().toLowerCase().replaceAll('/', '\\');
}

// Shared by the texture scoring paths, which run per candidate per material.
// Rebuilding these inside the scorers dominated relink cost.
final _extensionPattern = RegExp(r'\.[^.]+$');
final _nonAlphanumericPattern = RegExp(r'[^a-z0-9]+');
final _texturePrefixPattern = RegExp(r'^(?:t|tx|tex|texture)_');

/// The marker a download folder adds to a second copy of a file.
///
/// Deliberately narrow: a trailing `_01` is part of the name, so only a
/// number set off by a space or parentheses counts, plus a literal `copy`.
final _duplicateCopyPattern = RegExp(
  r'(?:[ ]+[(]?[0-9]{1,2}[)]?|[ _-]*copy)+$',
);

/// Texture names that mean the same thing rarely spell it the same way.
///
/// A model may ask for `PolygonApocalypse_Texture_01_A 1` while its own pack
/// ships `T_PolygonApocalypse_01`: an exporter prefix, a dropped variant
/// letter, and a duplicate-copy suffix Windows added on the way through a
/// download folder. Stripping that noise is what lets the two be compared.
String stripTextureNameNoise(String base) {
  var value = base.toLowerCase().trim();
  value = value.replaceFirst(_texturePrefixPattern, '');
  value = value.replaceFirst(_duplicateCopyPattern, '');
  return value.trim();
}

/// The parts of a texture name that actually distinguish it.
///
/// Single characters and the word "texture" are dropped: a variant letter and
/// a word that appears in most of the library identify nothing on their own.
/// Numbers are kept, but callers must not treat a shared number as evidence --
/// a pack is full of `_01`.
List<String> textureNameTokens(String base) {
  const generic = {'texture', 'textures', 'tex', 'mat', 'material', 'diffuse'};
  return [
    for (final token in stripTextureNameNoise(
      base,
    ).split(_nonAlphanumericPattern))
      if (token.length > 1 && !generic.contains(token)) token,
  ];
}

/// Whether a token carries identity rather than just position in a set.
bool _isDistinctiveToken(String token) =>
    token.length >= 4 && !RegExp(r'^[0-9]+$').hasMatch(token);

/// Words that name which *channel* a texture is, not what it depicts.
const _textureChannelWords = {
  'emissive',
  'emission',
  'glow',
  'normal',
  'normals',
  'bump',
  'specular',
  'spec',
  'gloss',
  'roughness',
  'metallic',
  'metalness',
  'occlusion',
  'opacity',
  'alpha',
  'height',
  'displacement',
};

/// The channel a texture name declares itself to be, or the empty string.
String textureChannelWord(String base) {
  for (final token in textureNameTokens(base)) {
    if (_textureChannelWords.contains(token)) return token;
  }
  return '';
}

/// Whether two texture names describe the same channel.
///
/// `PolygonApocalypse_Emissive_01` and `PolygonApocalypse_01` share every
/// distinctive word they have, so word overlap alone would bind an emissive
/// slot to the base atlas -- and an emissive map added at full strength over
/// its own base colour washes a model out to grey. A name that declares a
/// channel may only match one that declares the same channel, and a name that
/// declares none may only match another that declares none.
bool textureChannelsAgree(String requestedBase, String candidateBase) =>
    textureChannelWord(requestedBase) == textureChannelWord(candidateBase);

final _pathSeparatorPattern = RegExp(r'[\\/]');
final _paletteTailPattern = RegExp(r'(?:^|_)(texture|tex)(?:_|$).*');

String? resolveTextureReference(
  String modelPath,
  String texturePath, {
  List<AssetItem> allAssets = const [],
  bool allowFallbackLookup = true,
}) {
  final trimmed = texturePath.trim();
  if (trimmed.isEmpty) return null;
  final isAbsolute =
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(trimmed) || trimmed.startsWith(r'\\');
  if (isAbsolute && File(trimmed).existsSync()) {
    fbxLog('Resolved absolute texture path: $trimmed');
    return trimmed;
  }

  final zipModel = parseZipVirtualPath(modelPath);
  if (zipModel != null && !isAbsolute) {
    final zipRelativeEntry = resolveZipRelativeEntryPath(
      zipModel.entryPath,
      trimmed,
    );
    final zipVirtualCandidate = buildZipVirtualPath(
      zipModel.zipPath,
      zipRelativeEntry,
    );
    final hasZipCandidate = allAssets.any(
      (asset) =>
          normalizePathKey(asset.path) == normalizePathKey(zipVirtualCandidate),
    );
    if (hasZipCandidate) {
      fbxLog(
        'Resolved ZIP-relative texture path: $trimmed -> $zipVirtualCandidate',
      );
      return zipVirtualCandidate;
    }
  }

  final relativeCandidate = isAbsolute
      ? trimmed
      : '${parentPath(modelPath)}${Platform.pathSeparator}${trimmed.replaceAll('/', Platform.pathSeparator)}';
  if (File(relativeCandidate).existsSync()) {
    fbxLog('Resolved relative texture path: $trimmed -> $relativeCandidate');
    return relativeCandidate;
  }
  final relinked = findDeterministicTextureRelink(
    modelPath,
    trimmed,
    allAssets,
  );
  if (relinked != null) {
    fbxLog('Resolved deterministic texture relink: $trimmed -> $relinked');
    return relinked;
  }
  if (!allowFallbackLookup) {
    fbxLog(
      'Failed to resolve texture without fallback: $trimmed (model: $modelPath)',
    );
    return null;
  }
  final fallback = findFallbackTexture(modelPath, trimmed, allAssets);
  fbxLog(
    fallback == null
        ? 'Failed to resolve texture: $trimmed (model: $modelPath)'
        : 'Resolved fallback texture path: $trimmed -> $fallback',
  );
  return fallback;
}

/// Directory names from a texture reference that could identify the pack it
/// belongs to.
///
/// Generic folders carry no identity: half the packs in a library have a
/// `Textures` folder, so matching on that would relink across unrelated packs.
Set<String> texturePackHints(String texturePath) {
  const generic = {
    'textures',
    'texture',
    'misc',
    'materials',
    'material',
    'sourcefiles',
    'source files',
    'assets',
    'content',
    'maps',
  };
  final segments = texturePath
      .replaceAll('\\', '/')
      .split('/')
      .map((segment) => segment.trim().toLowerCase())
      .toList();
  if (segments.isNotEmpty) segments.removeLast(); // the file name itself
  return segments
      .where(
        (segment) =>
            segment.isNotEmpty &&
            segment != '.' &&
            segment != '..' &&
            !generic.contains(segment),
      )
      .toSet();
}

/// Whether [candidatePath] may satisfy a reference that points outside its own
/// archive.
///
/// Synty source files routinely reference a sibling pack, so refusing to leave
/// the archive leaves those models untextured. Crossing needs strong evidence:
/// the file names match exactly, and the reference names a folder that also
/// appears in the candidate's path. Without the second test, a texture called
/// `Texture_01_A.png` would match the same name in a dozen unrelated packs.
bool canRelinkAcrossContainers({
  required String texturePath,
  required String candidatePath,
  required String requestedBase,
  required String candidateBase,
}) {
  if (requestedBase != candidateBase) return false;
  final hints = texturePackHints(texturePath);
  if (hints.isEmpty) return false;
  final candidateLower = candidatePath.toLowerCase().replaceAll('\\', '/');
  return hints.any((hint) => candidateLower.contains(hint));
}

String? findDeterministicTextureRelink(
  String modelPath,
  String texturePath,
  List<AssetItem> allAssets,
) {
  if (allAssets.isEmpty) return null;
  final modelPathLower = modelPath.toLowerCase().replaceAll('\\', '/');
  final zipModel = parseZipVirtualPath(modelPath);
  bool sameContainer(AssetItem asset) {
    if (!textureExts.contains(asset.ext)) return false;
    if (zipModel != null) {
      final zipCandidate = parseZipVirtualPath(asset.path);
      return zipCandidate != null &&
          normalizePathKey(zipCandidate.zipPath) ==
              normalizePathKey(zipModel.zipPath);
    }
    if (isZipVirtualPath(asset.path)) return false;
    final sourceLower = asset.sourceRoot.toLowerCase().replaceAll('\\', '/');
    return modelPathLower.startsWith(sourceLower);
  }

  final sourceCandidates = allAssets.where(sameContainer).toList();

  final requestedBase = texturePath
      .split(_pathSeparatorPattern)
      .last
      .toLowerCase()
      .replaceAll(_extensionPattern, '');
  if (requestedBase.isEmpty) return null;

  String normalize(String value) {
    return value.toLowerCase().replaceAll(_nonAlphanumericPattern, '');
  }

  final requestedNormalized = normalize(requestedBase);
  final strippedSuffix = requestedBase.contains('_')
      ? requestedBase.substring(0, requestedBase.lastIndexOf('_'))
      : requestedBase;

  String paletteTail(String value) {
    final match = _paletteTailPattern.firstMatch(value);
    if (match == null) return '';
    return normalize(value.substring(match.start));
  }

  final requestedPaletteTail = paletteTail(requestedBase);

  int score(AssetItem asset) {
    final base = asset.name.toLowerCase().replaceAll(_extensionPattern, '');
    final normalized = normalize(base);
    var value = 0;
    if (base == requestedBase) value += 120;
    if (normalized == requestedNormalized) value += 95;

    // Many source FBX files keep author-variant suffixes (eg. _Mike).
    if (strippedSuffix.isNotEmpty && base == strippedSuffix) value += 90;

    // Synty palette/source textures commonly replace author suffixes with
    // exported variants, eg. Texture_01.psd -> Texture_01_A.png.
    if (base.startsWith('${requestedBase}_')) value += 75;
    if (strippedSuffix.isNotEmpty && base.startsWith('${strippedSuffix}_')) {
      value += 70;
    }
    final candidatePaletteTail = paletteTail(base);
    if (requestedPaletteTail.isNotEmpty &&
        candidatePaletteTail == requestedPaletteTail) {
      value += 105;
    }

    // Common singular/plural drift eg. window -> windows.
    if (base == '${requestedBase}s' || '${base}s' == requestedBase) {
      value += 80;
    }

    // Nothing above matched by name. Inside one container the art is one
    // consistent set, so shared distinctive words are real evidence -- but a
    // shared number alone is not, or every `_01` in the pack would match.
    if (value == 0 && textureChannelsAgree(requestedBase, base)) {
      final requestedTokens = textureNameTokens(requestedBase).toSet();
      final candidateTokens = textureNameTokens(base).toSet();
      final shared = requestedTokens.intersection(candidateTokens);
      if (shared.any(_isDistinctiveToken)) {
        value += 70 + math.min(30, (shared.length - 1) * 20);
      }
    }

    final dirLower = parentPath(asset.path).toLowerCase().replaceAll('\\', '/');
    if (dirLower.contains('/textures')) value += 20;
    // Synty demo packs keep their atlas in Demo_Textures, not Textures.
    if (dirLower.contains('textures')) value += 5;

    final modelDirLower = parentPath(
      modelPath,
    ).toLowerCase().replaceAll('\\', '/');
    if (dirLower == modelDirLower) value += 30;
    return value;
  }

  // Score once per candidate, then break ties on the normalized path so the
  // winner cannot depend on catalog order or on List.sort being stable
  // (it is not).
  final scored =
      [
        for (final asset in sourceCandidates)
          (asset: asset, score: score(asset)),
      ]..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return normalizePathKey(
          a.asset.path,
        ).compareTo(normalizePathKey(b.asset.path));
      });

  // May be empty: the model's own archive need not contain any texture.
  if (scored.isNotEmpty && scored.first.score >= 80) {
    return scored.first.asset.path;
  }

  // Nothing good enough beside the model. The reference may legitimately point
  // at another pack, so try that, on the stricter rules above.
  final crossContainer =
      [
        for (final asset in allAssets)
          if (textureExts.contains(asset.ext) && !sameContainer(asset))
            if (canRelinkAcrossContainers(
              texturePath: texturePath,
              candidatePath: asset.path,
              requestedBase: requestedBase,
              candidateBase: asset.name.toLowerCase().replaceAll(
                _extensionPattern,
                '',
              ),
            ))
              asset,
      ]..sort(
        (a, b) => normalizePathKey(a.path).compareTo(normalizePathKey(b.path)),
      );
  if (crossContainer.isNotEmpty) return crossContainer.first.path;
  return null;
}

String? findFallbackTexture(
  String modelPath,
  String texturePath,
  List<AssetItem> allAssets,
) {
  final supported = allAssets
      .where((asset) => imageExts.contains(asset.ext))
      .toList();
  if (supported.isEmpty) return null;
  final modelDir = parentPath(modelPath).toLowerCase();
  final modelParent = parentPath(parentPath(modelPath)).toLowerCase();
  final sourceTokens = tokenSet(texturePath);
  if (sourceTokens.isEmpty) return null;

  final textureBase = texturePath
      .split(_pathSeparatorPattern)
      .last
      .toLowerCase()
      .replaceAll(_extensionPattern, '');

  int score(AssetItem asset) {
    final assetTokens = tokenSet(asset.name);
    var value = sourceTokens.intersection(assetTokens).length * 10;
    final lower = asset.path.toLowerCase().replaceAll('\\', '/');
    if (lower.contains('/textures/')) value += 5;
    final dir = parentPath(asset.path).toLowerCase();
    if (dir == '$modelParent${Platform.pathSeparator}textures'.toLowerCase()) {
      value += 10;
    }
    if (dir == modelDir) value += 6;
    final assetBase = asset.name.toLowerCase().replaceAll(
      _extensionPattern,
      '',
    );
    if (textureBase == assetBase) value += 25;
    return value;
  }

  // Same decorate-sort-undecorate and tie-break as the deterministic relink.
  final scored =
      [for (final asset in supported) (asset: asset, score: score(asset))]
        ..sort((a, b) {
          final byScore = b.score.compareTo(a.score);
          if (byScore != 0) return byScore;
          return normalizePathKey(
            a.asset.path,
          ).compareTo(normalizePathKey(b.asset.path));
        });

  final best = scored.first;
  return best.score > 0 ? best.asset.path : null;
}

Set<String> tokenSet(String value) {
  return value
      .toLowerCase()
      .replaceAll(_extensionPattern, '')
      .split(_nonAlphanumericPattern)
      .where(
        (token) =>
            token.length > 2 && token != 'texture' && token != 'textures',
      )
      .toSet();
}

Future<Color?> firstTextureAverageColor(List<String> paths) async {
  for (final path in paths) {
    if (!imageExts.contains(extensionOf(path))) continue;
    final color = await averageImageColor(path);
    if (color != null) return color;
  }
  return null;
}

Future<ui.Image?> firstTextureImage(List<String> paths) async {
  for (final path in paths) {
    if (!imageExts.contains(extensionOf(path))) continue;
    try {
      final bytes = await readAssetBytes(path);
      if (bytes == null || bytes.isEmpty) continue;
      final image = await decodeImage(bytes);
      fbxLog('Decoded texture image: $path (${image.width}x${image.height})');
      return image;
    } catch (error) {
      fbxLog('Texture decode failed: $path ($error)');
      // Try the next texture candidate.
    }
  }
  if (paths.isNotEmpty) {
    fbxLog(
      'No decodable texture image found in candidates: ${paths.join('; ')}',
    );
  }
  return null;
}

Future<ui.Image> createCheckerboardTextureImage({
  int size = 128,
  int cells = 8,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final dark = Paint()..color = const Color(0xff9ca3af);
  final light = Paint()..color = const Color(0xffe5e7eb);
  final cellSize = size / cells;

  for (var y = 0; y < cells; y += 1) {
    for (var x = 0; x < cells; x += 1) {
      final paint = (x + y).isEven ? light : dark;
      canvas.drawRect(
        Rect.fromLTWH(x * cellSize, y * cellSize, cellSize, cellSize),
        paint,
      );
    }
  }

  final picture = recorder.endRecording();
  return picture.toImage(size, size);
}

Future<Color?> averageImageColor(String path) async {
  try {
    final bytes = await readAssetBytes(path);
    if (bytes == null || bytes.isEmpty) return null;
    final image = await decodeImage(bytes);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    if (byteData == null) return null;
    final data = byteData.buffer.asUint8List();
    var r = 0;
    var g = 0;
    var b = 0;
    var samples = 0;
    final stride = math.max(4, (data.length / 256).floor() ~/ 4 * 4);
    for (var index = 0; index + 3 < data.length; index += stride) {
      if (data[index + 3] < 16) continue;
      r += data[index];
      g += data[index + 1];
      b += data[index + 2];
      samples += 1;
    }
    if (samples == 0) return null;
    return Color.fromARGB(255, r ~/ samples, g ~/ samples, b ~/ samples);
  } catch (_) {
    return null;
  }
}

Future<ui.Image> decodeImage(Uint8List bytes) {
  return ui
      .instantiateImageCodec(bytes)
      .then((codec) async {
        final frame = await codec.getNextFrame();
        return frame.image;
      })
      .onError((error, stackTrace) async {
        final decoded = img.decodeImage(bytes);
        if (decoded == null) {
          throw error ?? Exception('Unsupported image format.');
        }
        final pngBytes = Uint8List.fromList(img.encodePng(decoded));
        final codec = await ui.instantiateImageCodec(pngBytes);
        final frame = await codec.getNextFrame();
        return frame.image;
      });
}

/// A scan running on a worker isolate.
///
/// Scanning walks a directory tree, stats every file and inflates every ZIP it
/// finds. On the UI isolate that froze the window for as long as the scan took,
/// with no way to stop it. Here it runs elsewhere and can be abandoned.
class ScanHandle {
  ScanHandle._(this._isolate, this._port, this._completer);

  final Isolate _isolate;
  final ReceivePort _port;
  final Completer<ScanResult> _completer;

  /// Completes with the scan, or with [ScanCancelledException] if abandoned.
  Future<ScanResult> get result => _completer.future;

  var _cancelled = false;
  bool get cancelled => _cancelled;

  /// Abandons the scan. The worker only reads the filesystem and returns a
  /// list, so there is nothing half-written to clean up.
  ///
  /// The waiting future is settled here rather than left to the port: closing
  /// the port silences the listener, so anyone awaiting the result would hang
  /// forever instead of learning the scan was stopped.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _isolate.kill(priority: Isolate.immediate);
    if (!_completer.isCompleted) {
      _completer.completeError(const ScanCancelledException());
    }
    _port.close();
  }
}

class ScanCancelledException implements Exception {
  const ScanCancelledException();
  @override
  String toString() => 'Scan cancelled';
}

class ScanBootstrap {
  const ScanBootstrap(this.sendPort, this.rootPath);
  final SendPort sendPort;
  final String rootPath;
}

/// Worker entry point. Top-level by necessity: isolates are spawned by
/// function reference, and a closure here would capture its surroundings.
Future<void> scanWorkerEntry(ScanBootstrap bootstrap) async {
  try {
    final result = await scanAssetFolder(
      bootstrap.rootPath,
      onStatus: bootstrap.sendPort.send,
    );
    bootstrap.sendPort.send(result);
  } catch (error) {
    bootstrap.sendPort.send('scan failed: $error');
  }
}

/// Starts a scan on a worker isolate, reporting progress as it goes.
Future<ScanHandle> startFolderScan(
  String rootPath, {
  required void Function(ScanStatus status) onStatus,
}) async {
  final port = ReceivePort();
  final completer = Completer<ScanResult>();

  // A caller that cancels without awaiting the result should not produce an
  // unhandled async error. Real awaiters still see the exception; this only
  // stops an abandoned future from being reported as unhandled.
  completer.future.then((_) {}, onError: (Object _) {});

  // One listener only: a ReceivePort allows a single subscription, and the
  // isolate's exit notification arrives on this same port as a null.
  port.listen((message) {
    if (message is ScanStatus) {
      onStatus(message);
      return;
    }
    if (message is ScanResult) {
      if (!completer.isCompleted) completer.complete(message);
      port.close();
      return;
    }
    if (message == null) {
      // The worker exited without a result: killed, or it died.
      if (!completer.isCompleted) {
        completer.completeError(const ScanCancelledException());
      }
      port.close();
      return;
    }
    if (!completer.isCompleted) {
      completer.completeError(StateError(message.toString()));
    }
    port.close();
  });

  final isolate = await Isolate.spawn(
    scanWorkerEntry,
    ScanBootstrap(port.sendPort, rootPath),
    onExit: port.sendPort,
    errorsAreFatal: true,
  );

  return ScanHandle._(isolate, port, completer);
}

Future<ScanResult> scanAssetFolder(
  String rootPath, {
  required ValueChanged<ScanStatus> onStatus,
}) async {
  final root = Directory(rootPath);
  final sourceName =
      root.uri.pathSegments.where((segment) => segment.isNotEmpty).lastOrNull ??
      rootPath;
  final assets = <AssetItem>[];
  var checked = 0;
  var skippedUnsupported = 0;
  var skippedBinaryObj = 0;

  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    if (hasIgnoredFolder(entity.path, rootPath)) continue;
    checked += 1;

    final ext = extensionOf(entity.path);
    if (archiveExts.contains(ext)) {
      final zipStat = await entity.stat();
      final zipResult = await scanZipAssetEntries(
        zipPath: entity.path,
        rootPath: rootPath,
        sourceName: sourceName,
        zipModified: zipStat.modified,
      );
      assets.addAll(zipResult.assets);
      skippedUnsupported += zipResult.skippedUnsupported;
      skippedBinaryObj += zipResult.skippedBinaryObj;
      checked += zipResult.entriesInspected;
      continue;
    }

    final type = typeForExt(ext);
    if (type == 'other') {
      skippedUnsupported += 1;
      continue;
    }
    if (isAppleDoubleName(entity.uri.pathSegments.last)) {
      skippedUnsupported += 1;
      continue;
    }
    if (ext == 'obj' && await isLikelyBinaryObj(entity)) {
      skippedBinaryObj += 1;
      continue;
    }

    final stat = await entity.stat();
    final relativePath = relativeTo(entity.path, rootPath);
    assets.add(
      AssetItem(
        id: buildAssetId(sourceRoot: rootPath, relativePath: relativePath),
        name: entity.uri.pathSegments.last,
        path: entity.path,
        relativePath: '$sourceName/$relativePath',
        sourceRoot: rootPath,
        sourceName: sourceName,
        ext: ext,
        type: type,
        size: stat.size,
        modified: stat.modified,
        tags: inferTags(entity.uri.pathSegments.last, relativePath, type, ext),
      ),
    );

    if (checked % 250 == 0) {
      onStatus(
        ScanStatus(
          'Scanning $sourceName',
          '$checked files checked, ${assets.length} assets cataloged',
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }
  }

  return ScanResult(
    assets: assets,
    skippedUnsupported: skippedUnsupported,
    skippedBinaryObj: skippedBinaryObj,
  );
}

Future<ZipAssetScanResult> scanZipAssetEntries({
  required String zipPath,
  required String rootPath,
  required String sourceName,
  required DateTime zipModified,
}) async {
  final zipFile = File(zipPath);
  if (!zipFile.existsSync()) {
    return const ZipAssetScanResult(
      assets: [],
      skippedUnsupported: 0,
      skippedBinaryObj: 0,
      entriesInspected: 0,
    );
  }

  final zipSize = await zipFile.length();
  if (zipSize > maxZipIntrospectionBytes) {
    fbxLog(
      'Skipping ZIP introspection for large archive: $zipPath ($zipSize bytes)',
    );
    return const ZipAssetScanResult(
      assets: [],
      skippedUnsupported: 0,
      skippedBinaryObj: 0,
      entriesInspected: 0,
    );
  }

  try {
    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    final zipRelative = relativeTo(zipPath, rootPath).replaceAll('\\', '/');
    final assets = <AssetItem>[];
    var skippedUnsupported = 0;
    var skippedBinaryObj = 0;
    var entriesInspected = 0;

    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      if (entriesInspected >= maxZipEntriesToInspect) break;
      entriesInspected += 1;

      final entryPath = entry.name.replaceAll('\\', '/');
      if (entryPath.isEmpty) continue;
      if (hasIgnoredArchiveFolder(entryPath)) continue;

      final ext = extensionOf(entryPath);
      final type = typeForExt(ext);
      if (type == 'other') {
        skippedUnsupported += 1;
        continue;
      }

      if (ext == 'obj') {
        final content = entry.content;
        if (isLikelyBinaryObjBytes(content)) {
          skippedBinaryObj += 1;
          continue;
        }
      }

      final name = entryPath.split('/').last;
      if (isAppleDoubleName(name)) {
        skippedUnsupported += 1;
        continue;
      }
      final relativePath = '$sourceName/$zipRelative!/$entryPath';
      assets.add(
        AssetItem(
          id: buildAssetId(
            sourceRoot: rootPath,
            relativePath: '$zipRelative!/$entryPath',
          ),
          name: name,
          path: buildZipVirtualPath(zipPath, entryPath),
          relativePath: relativePath,
          sourceRoot: rootPath,
          sourceName: sourceName,
          ext: ext,
          type: type,
          size: entry.size,
          modified: zipModified,
          tags: inferTags(name, relativePath, type, ext),
        ),
      );
    }

    return ZipAssetScanResult(
      assets: assets,
      skippedUnsupported: skippedUnsupported,
      skippedBinaryObj: skippedBinaryObj,
      entriesInspected: entriesInspected,
    );
  } catch (error) {
    fbxLog('ZIP introspection failed for $zipPath: $error');
    return const ZipAssetScanResult(
      assets: [],
      skippedUnsupported: 0,
      skippedBinaryObj: 0,
      entriesInspected: 0,
    );
  }
}

/// Images that live in a texture folder are textures in practice: Synty and
/// most other packs put them under `Textures/`, and 1,925 of the 2,104 images
/// in the reference catalog sit there. The authoritative signal is being
/// referenced by a model, which is only known once that model has been read.
final _textureFolderPattern = RegExp(
  r'(^|[\\/])(textures?|materials?)([\\/]|$)',
  caseSensitive: false,
);

bool looksLikeTextureLocation(String relativePath) =>
    _textureFolderPattern.hasMatch(relativePath.replaceAll('\\', '/'));

/// AppleDouble sidecars: macOS writes a `._name` stub beside the real file
/// (and a `__MACOSX/` mirror inside archives) holding resource-fork metadata.
/// They carry the extension of the file they shadow but none of its content,
/// so a 268-byte "mp3" reaches the audio plugin and takes the process down.
bool isAppleDoubleName(String fileName) => fileName.startsWith('._');

bool hasIgnoredArchiveFolder(String archiveEntryPath) {
  final parts = archiveEntryPath.replaceAll('\\', '/').split('/');
  return parts.any((part) => ignoredFolderNames.contains(part.toLowerCase()));
}

String buildZipVirtualPath(String zipPath, String entryPath) {
  return 'zip:$zipPath::${entryPath.replaceAll('\\', '/')}';
}

bool isZipVirtualPath(String path) {
  return path.startsWith('zip:') && path.contains('::');
}

String resolveZipRelativeEntryPath(String modelEntryPath, String textureRef) {
  final normalizedTexture = textureRef.replaceAll('\\', '/').trim();
  final baseDirParts = modelEntryPath
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .toList();
  if (baseDirParts.isNotEmpty) {
    baseDirParts.removeLast();
  }
  final resolved = <String>[...baseDirParts];
  for (final segment in normalizedTexture.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (resolved.isNotEmpty) {
        resolved.removeLast();
      }
      continue;
    }
    resolved.add(segment);
  }
  return resolved.join('/');
}

class ZipVirtualPath {
  const ZipVirtualPath({required this.zipPath, required this.entryPath});

  final String zipPath;
  final String entryPath;
}

final _zipArchiveCache = <String, Archive>{};

ZipVirtualPath? parseZipVirtualPath(String value) {
  if (!isZipVirtualPath(value)) return null;
  final separator = value.indexOf('::');
  if (separator < 4 || separator >= value.length - 2) return null;
  final zipPath = value.substring(4, separator);
  final entryPath = value.substring(separator + 2).replaceAll('\\', '/');
  if (zipPath.isEmpty || entryPath.isEmpty) return null;
  return ZipVirtualPath(zipPath: zipPath, entryPath: entryPath);
}

Future<Archive?> _readArchiveFromDisk(String zipPath) async {
  final file = File(zipPath);
  if (!file.existsSync()) return null;
  final length = await file.length();
  if (length > maxZipIntrospectionBytes) return null;
  final bytes = await file.readAsBytes();
  return ZipDecoder().decodeBytes(bytes, verify: false);
}

Future<Archive?> _loadCachedArchive(String zipPath) async {
  final cacheKey = normalizePathKey(zipPath);
  final cached = _zipArchiveCache[cacheKey];
  if (cached != null) {
    // Promote recently-used entries to the end for LRU eviction.
    _zipArchiveCache.remove(cacheKey);
    _zipArchiveCache[cacheKey] = cached;
    return cached;
  }
  final archive = await _readArchiveFromDisk(zipPath);
  if (archive != null) {
    _zipArchiveCache[cacheKey] = archive;
    while (_zipArchiveCache.length > maxZipArchiveCacheEntries) {
      _zipArchiveCache.remove(_zipArchiveCache.keys.first);
    }
  }
  return archive;
}

Uint8List? _archiveEntryToBytes(ArchiveFile entry) {
  return entry.content;
}

Future<Uint8List?> readZipVirtualAssetBytesByPath(String virtualPath) async {
  final parsed = parseZipVirtualPath(virtualPath);
  if (parsed == null) return null;
  final archive = await _loadCachedArchive(parsed.zipPath);
  if (archive == null) return null;
  final entry = archive.findFile(parsed.entryPath);
  if (entry == null || !entry.isFile) return null;
  return _archiveEntryToBytes(entry);
}

Future<Uint8List?> readAssetBytes(String path) async {
  if (isZipVirtualPath(path)) {
    return readZipVirtualAssetBytesByPath(path);
  }
  final file = File(path);
  if (!file.existsSync()) return null;
  return file.readAsBytes();
}

bool hasIgnoredFolder(String filePath, String rootPath) {
  final relative = relativeTo(filePath, rootPath).replaceAll('\\', '/');
  final parts = relative.split('/');
  return parts.any((part) => ignoredFolderNames.contains(part.toLowerCase()));
}

String relativeTo(String path, String root) {
  final normalizedRoot = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  if (path.toLowerCase().startsWith(normalizedRoot.toLowerCase())) {
    return path.substring(normalizedRoot.length).replaceAll('\\', '/');
  }
  return path.replaceAll('\\', '/');
}

String extensionOf(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

String typeForExt(String ext) {
  if (imageExts.contains(ext)) return 'image';
  if (audioExts.contains(ext)) return 'audio';
  if (modelExts.contains(ext)) return 'model';
  return 'other';
}

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  final decimals = unitIndex == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
}

Future<bool> isLikelyBinaryObj(File file) async {
  final stream = file.openRead(0, 4096);
  var total = 0;
  var suspicious = 0;
  await for (final chunk in stream) {
    for (final byte in chunk) {
      total += 1;
      if (byte == 0) return true;
      final textByte =
          byte == 9 ||
          byte == 10 ||
          byte == 13 ||
          (byte >= 32 && byte <= 126) ||
          byte >= 128;
      if (!textByte) suspicious += 1;
    }
  }
  if (total == 0) return false;
  return suspicious / total > .08;
}

bool isLikelyBinaryObjBytes(List<int> bytes) {
  var total = 0;
  var suspicious = 0;
  for (final byte in bytes.take(4096)) {
    total += 1;
    if (byte == 0) return true;
    final textByte =
        byte == 9 ||
        byte == 10 ||
        byte == 13 ||
        (byte >= 32 && byte <= 126) ||
        byte >= 128;
    if (!textByte) suspicious += 1;
  }
  if (total == 0) return false;
  return suspicious / total > .08;
}

enum CopyOutcome { copied, renamed, skippedMissingSource, failed }

class CopyResultEntry {
  const CopyResultEntry({
    required this.asset,
    required this.outcome,
    this.destinationPath,
    this.detail,
  });

  final AssetItem asset;
  final CopyOutcome outcome;
  final String? destinationPath;

  /// Reason for a skip, or the error text for a failure.
  final String? detail;
}

class CopyReport {
  const CopyReport(this.entries);

  final List<CopyResultEntry> entries;

  int _countOf(CopyOutcome outcome) =>
      entries.where((entry) => entry.outcome == outcome).length;

  /// Files actually written, including the ones written under a new name.
  int get copiedCount =>
      _countOf(CopyOutcome.copied) + _countOf(CopyOutcome.renamed);
  int get renamedCount => _countOf(CopyOutcome.renamed);
  int get skippedCount => _countOf(CopyOutcome.skippedMissingSource);
  int get failedCount => _countOf(CopyOutcome.failed);

  String get summaryLine {
    final parts = <String>['$copiedCount copied'];
    if (renamedCount > 0) {
      parts.add('$renamedCount renamed to avoid overwrite');
    }
    if (skippedCount > 0) {
      parts.add('$skippedCount skipped (source missing)');
    }
    if (failedCount > 0) {
      parts.add('$failedCount failed');
    }
    return parts.join(' · ');
  }
}

/// Returns [desiredPath] if it is free, otherwise the same path with an
/// incrementing ` (n)` suffix inserted before the extension. Mirrors the
/// Windows Explorer convention so renamed output reads as familiar.
String resolveNonCollidingPath(String desiredPath) {
  if (!File(desiredPath).existsSync() && !Directory(desiredPath).existsSync()) {
    return desiredPath;
  }

  final separatorIndex = desiredPath.lastIndexOf(RegExp(r'[\\/]'));
  final directory = separatorIndex < 0
      ? ''
      : desiredPath.substring(0, separatorIndex + 1);
  final fileName = desiredPath.substring(separatorIndex + 1);

  // A leading dot belongs to the name (.gitignore), not to an extension.
  final dotIndex = fileName.lastIndexOf('.');
  final hasExtension = dotIndex > 0;
  final stem = hasExtension ? fileName.substring(0, dotIndex) : fileName;
  final extension = hasExtension ? fileName.substring(dotIndex) : '';

  for (var suffix = 2; ; suffix += 1) {
    final candidate = '$directory$stem ($suffix)$extension';
    if (!File(candidate).existsSync() && !Directory(candidate).existsSync()) {
      return candidate;
    }
  }
}

Future<CopyReport> copyAssetsToTarget(
  List<AssetItem> selected,
  String target,
) async {
  final entries = <CopyResultEntry>[];
  final destinationRoot = Directory(target);
  if (!destinationRoot.existsSync()) {
    destinationRoot.createSync(recursive: true);
  }

  for (final asset in selected) {
    try {
      if (isZipVirtualPath(asset.path)) {
        final bytes = await readZipVirtualAssetBytesByPath(asset.path);
        if (bytes == null || bytes.isEmpty) {
          entries.add(
            CopyResultEntry(
              asset: asset,
              outcome: CopyOutcome.skippedMissingSource,
              detail: 'ZIP entry could not be read.',
            ),
          );
          continue;
        }
        final zipParts = parseZipVirtualPath(asset.path);
        final relativeOutput = safeZipEntryRelativePath(
          zipParts?.entryPath ?? asset.name,
          fallbackName: asset.name,
        );
        final desired =
            '$target${Platform.pathSeparator}${relativeOutput.replaceAll('/', Platform.pathSeparator)}';
        File(desired).parent.createSync(recursive: true);
        final resolved = resolveNonCollidingPath(desired);
        await File(resolved).writeAsBytes(bytes, flush: true);
        entries.add(
          CopyResultEntry(
            asset: asset,
            outcome: resolved == desired
                ? CopyOutcome.copied
                : CopyOutcome.renamed,
            destinationPath: resolved,
          ),
        );
        continue;
      }

      final source = File(asset.path);
      if (!source.existsSync()) {
        entries.add(
          CopyResultEntry(
            asset: asset,
            outcome: CopyOutcome.skippedMissingSource,
            detail: 'Source file no longer exists.',
          ),
        );
        continue;
      }
      final desired = '$target${Platform.pathSeparator}${asset.name}';
      final resolved = resolveNonCollidingPath(desired);
      await source.copy(resolved);
      entries.add(
        CopyResultEntry(
          asset: asset,
          outcome: resolved == desired
              ? CopyOutcome.copied
              : CopyOutcome.renamed,
          destinationPath: resolved,
        ),
      );
    } catch (error) {
      // One unwritable file must not end the batch.
      entries.add(
        CopyResultEntry(
          asset: asset,
          outcome: CopyOutcome.failed,
          detail: error.toString(),
        ),
      );
    }
  }
  return CopyReport(entries);
}

String safeZipEntryRelativePath(
  String entryPath, {
  required String fallbackName,
}) {
  String cleanSegment(String segment) {
    final sanitized = segment.replaceAll(RegExp(r'[<>:"|?*]'), '_').trim();
    if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
      return '';
    }
    return sanitized;
  }

  final normalized = entryPath.replaceAll('\\', '/').trim();
  final parts = <String>[];
  for (final raw in normalized.split('/')) {
    if (raw.isEmpty || raw == '.') continue;
    if (raw == '..') {
      if (parts.isNotEmpty) {
        parts.removeLast();
      }
      continue;
    }
    final cleaned = cleanSegment(raw);
    if (cleaned.isNotEmpty) {
      parts.add(cleaned);
    }
  }

  if (parts.isEmpty) {
    final fallback = cleanSegment(fallbackName);
    return fallback.isEmpty ? 'asset.bin' : fallback;
  }
  return parts.join('/');
}

class ZipAssetScanResult {
  const ZipAssetScanResult({
    required this.assets,
    required this.skippedUnsupported,
    required this.skippedBinaryObj,
    required this.entriesInspected,
  });

  final List<AssetItem> assets;
  final int skippedUnsupported;
  final int skippedBinaryObj;
  final int entriesInspected;
}

List<String> inferTags(
  String name,
  String relativePath,
  String type,
  String ext,
) {
  final words = '$name $relativePath'
      .toLowerCase()
      .replaceAll(RegExp(r'\.[^.]+$'), '')
      .split(RegExp(r'[^a-z0-9]+'))
      .where(
        (word) =>
            word.length > 2 &&
            !{
              'assets',
              'models',
              'images',
              'audio',
              'music',
              'textures',
            }.contains(word),
      );
  return {type, ext, ...words.take(8)}.toList();
}

/// Whether two assets live in the same archive, or under the same scan root.
///
/// The bound on "nearby": inside one pack the art is one set, across packs it
/// is a coincidence of naming.
bool _shareARoot(AssetItem a, AssetItem b) {
  final zipA = parseZipVirtualPath(a.path);
  final zipB = parseZipVirtualPath(b.path);
  if (zipA != null || zipB != null) {
    if (zipA == null || zipB == null) return false;
    return normalizePathKey(zipA.zipPath) == normalizePathKey(zipB.zipPath);
  }
  return normalizePathKey(a.sourceRoot) == normalizePathKey(b.sourceRoot);
}

List<AssetItem> findNearbyTextures(AssetItem model, List<AssetItem> allAssets) {
  final modelDir = parentPath(model.path);
  final modelParent = parentPath(modelDir);
  final modelGrandParent = parentPath(modelParent);
  final nameTokens = model.name
      .toLowerCase()
      .replaceAll(RegExp(r'\.[^.]+$'), '')
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) => token.length > 2)
      .toSet();

  final candidates = allAssets.where((asset) {
    if (!textureExts.contains(asset.ext)) return false;
    final textureDir = parentPath(asset.path);
    if (textureDir == modelDir) return true;
    if (textureDir == '$modelParent${Platform.pathSeparator}Textures') {
      return true;
    }
    if (textureDir == '$modelGrandParent${Platform.pathSeparator}Textures') {
      return true;
    }

    // Any folder whose name says "texture", anywhere under the same root.
    // Matching the literal folder `Textures` missed `Demo_Textures`, which is
    // where the Synty animation pack keeps the only atlas its character has --
    // so the picker offered nothing for exactly the model that needed it.
    final directoryName = textureDir.split(RegExp(r'[\\/]')).last.toLowerCase();
    if (directoryName.contains('texture') && _shareARoot(model, asset)) {
      return true;
    }

    final lowerPath = asset.path.toLowerCase().replaceAll('\\', '/');
    if (lowerPath.contains('/textures/')) {
      final textureTokens = asset.name
          .toLowerCase()
          .split(RegExp(r'[^a-z0-9]+'))
          .toSet();
      return textureTokens.intersection(nameTokens).isNotEmpty;
    }
    return false;
  }).toList()..sort((a, b) => a.relativePath.compareTo(b.relativePath));
  return candidates;
}

String parentPath(String path) {
  final separator = Platform.pathSeparator;
  final normalized = path.replaceAll(RegExp(r'[\\/]'), separator);
  final index = normalized.lastIndexOf(separator);
  if (index <= 0) return normalized;
  return normalized.substring(0, index);
}

/// One unit of classification work: FBX assets that all live in the same
/// container, so a worker isolate opens that archive once for the whole chunk.
class FbxClassifyChunk {
  const FbxClassifyChunk({
    required this.helperPath,
    required this.containerPath,
    required this.assetIds,
    required this.assetPaths,
  });

  final String helperPath;

  /// The `.zip` these assets live in, or null for loose files on disk.
  final String? containerPath;
  final List<String> assetIds;
  final List<String> assetPaths;

  int get length => assetIds.length;
}

/// Classifies a chunk of FBX files. Runs in a worker isolate: reading and
/// inflating archive entries is real CPU work, and doing it on the UI isolate
/// is what made classification stutter.
///
/// Must stay a top-level function taking only sendable data.
Future<Map<String, String>> classifyFbxChunk(FbxClassifyChunk chunk) async {
  final kinds = <String, String>{};

  Archive? archive;
  if (chunk.containerPath != null) {
    try {
      final file = File(chunk.containerPath!);
      if (file.existsSync() &&
          await file.length() <= maxZipIntrospectionBytes) {
        // Opened once for the whole chunk; entries inflate individually.
        archive = ZipDecoder().decodeBytes(
          await file.readAsBytes(),
          verify: false,
        );
      }
    } catch (_) {
      archive = null;
    }
  }

  for (var index = 0; index < chunk.assetIds.length; index += 1) {
    final assetId = chunk.assetIds[index];
    final assetPath = chunk.assetPaths[index];
    try {
      Uint8List? bytes;
      if (isZipVirtualPath(assetPath)) {
        final parsed = parseZipVirtualPath(assetPath);
        final entry = archive != null && parsed != null
            ? archive.findFile(parsed.entryPath)
            : null;
        if (entry == null || !entry.isFile) {
          kinds[assetId] = 'unreadable';
          continue;
        }
        bytes = entry.content;
      }

      final result = await runMeshImporter(
        chunk.helperPath,
        assetPath,
        inputBytes: bytes,
        probeOnly: true,
      );
      if (result.exitCode != 0) {
        kinds[assetId] = 'unreadable';
        continue;
      }
      final json = jsonDecode(result.stdout) as Map<String, dynamic>;
      kinds[assetId] = json['kind'] == 'animation' ? 'animation' : 'mesh';
    } catch (_) {
      kinds[assetId] = 'unreadable';
    }
  }
  return kinds;
}

/// Hands a chunk to a worker isolate.
///
/// Must stay top-level. Building this closure inside a State method captures
/// the enclosing `this`, which drags the whole widget tree into the isolate
/// message and fails with "object is unsendable".
Future<Map<String, String>> runFbxClassifyChunk(FbxClassifyChunk chunk) {
  return Isolate.run(() => classifyFbxChunk(chunk));
}

/// Splits pending work into per-container chunks.
///
/// Grouping by container matters: a chunk spanning three archives would make
/// its worker open all three.
List<FbxClassifyChunk> buildFbxClassifyChunks({
  required List<AssetItem> assets,
  required String helperPath,
  int chunkSize = fbxClassifyChunkSize,
}) {
  final byContainer = <String?, List<AssetItem>>{};
  for (final asset in assets) {
    final container = isZipVirtualPath(asset.path)
        ? parseZipVirtualPath(asset.path)?.zipPath
        : null;
    (byContainer[container] ??= <AssetItem>[]).add(asset);
  }

  final chunks = <FbxClassifyChunk>[];
  for (final entry in byContainer.entries) {
    for (var start = 0; start < entry.value.length; start += chunkSize) {
      final slice = entry.value.sublist(
        start,
        math.min(start + chunkSize, entry.value.length),
      );
      chunks.add(
        FbxClassifyChunk(
          helperPath: helperPath,
          containerPath: entry.key,
          assetIds: [for (final asset in slice) asset.id],
          assetPaths: [for (final asset in slice) asset.path],
        ),
      );
    }
  }
  return chunks;
}

/// Asks the importer only what an FBX contains, skipping geometry extraction
/// and the JSON payload. Roughly 4x faster than a full import and returns tens
/// of bytes instead of megabytes, which is what makes classifying a whole
/// catalog viable.
///
/// Returns 'mesh', 'animation', or 'unreadable'.
Future<String> probeFbxContentKind(AssetItem asset) async {
  if (asset.ext != 'fbx') return 'mesh';
  final helper = meshImporterPath();
  if (!File(helper).existsSync()) return 'unreadable';
  try {
    final bytes = isZipVirtualPath(asset.path)
        ? await readZipVirtualAssetBytesByPath(asset.path)
        : null;
    if (isZipVirtualPath(asset.path) && (bytes == null || bytes.isEmpty)) {
      return 'unreadable';
    }
    final result = await runMeshImporter(
      helper,
      asset.path,
      inputBytes: bytes,
      probeOnly: true,
    );
    if (result.exitCode != 0) return 'unreadable';
    final json = jsonDecode(result.stdout) as Map<String, dynamic>;
    return json['kind'] == 'animation' ? 'animation' : 'mesh';
  } catch (_) {
    return 'unreadable';
  }
}

/// Shares one in-flight mesh import between everything that needs it.
///
/// Both the 3D preview and the texture diagnostics panel want the same parsed
/// mesh, and every widget rebuild used to launch its own importer subprocess.
/// Caching the [Future] (not the value) means widgets asking during the same
/// frame join one import instead of racing several.
class MeshLoadCache {
  MeshLoadCache._();

  static const maxEntries = 8;
  static final _entries = <String, Future<MeshModel>>{};

  /// Number of imports actually started. Test visibility only.
  static int importCount = 0;

  static String _keyFor(AssetItem asset, int fallbackCheckerSquareSize) =>
      '${asset.id}|$fallbackCheckerSquareSize';

  static Future<MeshModel> load(
    AssetItem asset, {
    List<AssetItem> allAssets = const [],
    int fallbackCheckerSquareSize = 16,
  }) {
    final key = _keyFor(asset, fallbackCheckerSquareSize);
    final cached = _entries.remove(key);
    if (cached != null) {
      // Reinsert to promote for LRU eviction.
      _entries[key] = cached;
      return cached;
    }

    importCount += 1;
    final future = loadMesh(
      asset,
      allAssets: allAssets,
      fallbackCheckerSquareSize: fallbackCheckerSquareSize,
    );
    _entries[key] = future;
    // Do not keep a failure cached forever; the next selection should retry.
    // Consumers still receive the error - this listener only stops it being
    // reported as unhandled.
    future.then<void>(
      (_) {},
      onError: (Object _) {
        _entries.remove(key);
      },
    );

    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return future;
  }

  /// Call when the catalog changes: relink results depend on its contents.
  static void clear() {
    _entries.clear();
  }
}

/// Puts one chosen image on every material of a mesh.
///
/// The last resort when automatic resolution has nothing to work with: an OBJ
/// that names no material at all, or a model whose pack is not in the library.
/// The UVs are the model's own, so a correct atlas lands correctly; a wrong
/// one is obvious at a glance, which is the point of choosing by hand.
Future<MeshModel> applyChosenTexture(MeshModel mesh, String texturePath) async {
  final bytes = await readAssetBytes(texturePath);
  if (bytes == null || bytes.isEmpty) return mesh;
  final image = await decodeImage(bytes);
  Uint8List? pixels;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    pixels = data?.buffer.asUint8List();
  } catch (error) {
    fbxLog('Chosen texture readback failed: $error');
  }

  final materials = mesh.materials.isEmpty
      ? [const MeshMaterial(name: '', color: Color(0xffb9c2cc), textures: [])]
      : mesh.materials;
  return mesh.withMaterials([
    for (final material in materials)
      material.withBaseTexture(path: texturePath, image: image, pixels: pixels),
  ]);
}

Future<MeshModel> loadMesh(
  AssetItem asset, {
  List<AssetItem> allAssets = const [],
  int fallbackCheckerSquareSize = 16,
}) async {
  if (asset.ext == 'obj') {
    if (isZipVirtualPath(asset.path)) {
      final bytes = await readZipVirtualAssetBytesByPath(asset.path);
      if (bytes == null || bytes.isEmpty) {
        throw const FormatException('Could not read OBJ bytes from ZIP entry.');
      }
      final objText = utf8.decode(bytes, allowMalformed: true);
      return parseObjMesh(objText, asset.name);
    }
    return parseObjMesh(await File(asset.path).readAsString(), asset.name);
  }
  if (asset.ext == 'fbx') {
    fbxLog('Loading FBX mesh: ${asset.path}');
    final zipBytes = isZipVirtualPath(asset.path)
        ? await readZipVirtualAssetBytesByPath(asset.path)
        : null;
    if (isZipVirtualPath(asset.path) &&
        (zipBytes == null || zipBytes.isEmpty)) {
      throw const FormatException('Could not read FBX bytes from ZIP entry.');
    }
    return importFbxWithUfbx(
      asset.path,
      asset.name,
      inputBytes: zipBytes,
      allAssets: allAssets,
      fallbackCheckerSquareSize: fallbackCheckerSquareSize,
    );
  }
  throw FormatException(
    '${asset.ext.toUpperCase()} rendering is not implemented yet.',
  );
}

Future<MeshModel> importFbxWithUfbx(
  String path,
  String name, {
  Uint8List? inputBytes,
  List<AssetItem> allAssets = const [],
  int fallbackCheckerSquareSize = 16,
}) async {
  final helper = meshImporterPath();
  fbxLog('Using importer helper: $helper');
  if (!File(helper).existsSync()) {
    fbxLog('Importer helper missing: $helper');
    throw FormatException('FBX importer helper was not found at $helper.');
  }
  fbxLog('Launching importer for: $path');
  final result = await runMeshImporter(helper, path, inputBytes: inputBytes);
  if (result.exitCode != 0) {
    final error = result.stderr.trim();
    fbxLog('Importer failed (${result.exitCode}): $error');
    throw FormatException(error.isEmpty ? 'ufbx importer failed.' : error);
  }
  fbxLog('Importer completed for: $path');

  final json = jsonDecode(result.stdout) as Map<String, dynamic>;
  fbxLog(
    'Importer JSON counts: vertices=${(json['vertices'] as List<dynamic>?)?.length ?? 0}, vertexColors=${(json['vertexColors'] as List<dynamic>?)?.length ?? 0}, faces=${(json['faces'] as List<dynamic>?)?.length ?? 0}, materials=${(json['materials'] as List<dynamic>?)?.length ?? 0}, textureFiles=${(json['textureFiles'] as List<dynamic>?)?.length ?? 0}, sceneTextures=${(json['sceneTextures'] as List<dynamic>?)?.length ?? 0}',
  );
  return meshModelFromImporterJson(
    json,
    modelPath: path,
    name: name,
    allAssets: allAssets,
    fallbackCheckerSquareSize: fallbackCheckerSquareSize,
  );
}

class MeshImporterResult {
  const MeshImporterResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// The helper always emits UTF-8. Both branches below must decode it as such:
/// `Process.run` would otherwise fall back to `systemEncoding` (the Windows
/// ANSI codepage), which mangles non-ASCII material names and texture paths.
Future<MeshImporterResult> runMeshImporter(
  String helper,
  String sourcePath, {
  Uint8List? inputBytes,
  bool probeOnly = false,
}) async {
  final arguments = <String>[
    if (inputBytes != null) '--stdin',
    if (probeOnly) '--probe',
    sourcePath,
  ];
  final process = await Process.start(helper, arguments);
  if (inputBytes != null) {
    process.stdin.add(inputBytes);
  }
  await process.stdin.close();
  final stdoutBytes = await process.stdout.expand((chunk) => chunk).toList();
  final stderrBytes = await process.stderr.expand((chunk) => chunk).toList();
  final exitCode = await process.exitCode;
  return MeshImporterResult(
    exitCode: exitCode,
    stdout: utf8.decode(stdoutBytes, allowMalformed: true),
    stderr: utf8.decode(stderrBytes, allowMalformed: true),
  );
}

Future<MeshModel> meshModelFromImporterJson(
  Map<String, dynamic> json, {
  required String modelPath,
  required String name,
  List<AssetItem> allAssets = const [],
  int fallbackCheckerSquareSize = 16,
}) async {
  if (json['kind'] == 'animation') {
    final names = ((json['animationNames'] as List<dynamic>?) ?? const [])
        .map((value) => value.toString())
        .where((value) => value.trim().isNotEmpty)
        .toList();
    return MeshModel(
      name: name,
      vertices: const [],
      faces: const [],
      kind: FbxContentKind.animation,
      animationStacks: (json['animationStacks'] as num?)?.toInt() ?? 0,
      skeleton: SkeletonAnimation.fromJson(
        json['skeleton'] as Map<String, dynamic>?,
      ),
      boneCount: (json['bones'] as num?)?.toInt() ?? 0,
      durationSeconds: (json['durationSeconds'] as num?)?.toDouble() ?? 0,
      animationNames: names,
    );
  }

  final vertices = (json['vertices'] as List<dynamic>).map((item) {
    final values = item as List<dynamic>;
    return Vec3(
      (values[0] as num).toDouble(),
      (values[1] as num).toDouble(),
      (values[2] as num).toDouble(),
    );
  }).toList();
  final importedFaces = json['faces'] as List<dynamic>;
  final namedUvsByFace = List.generate(
    importedFaces.length,
    (_) => <String, List<Vec2>>{},
  );
  for (final item in ((json['uvSets'] as List<dynamic>?) ?? const [])) {
    final uvSet = item as Map<String, dynamic>;
    final name = (uvSet['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) continue;
    final uvFaces = (uvSet['faces'] as List<dynamic>?) ?? const [];
    for (
      var faceIndex = 0;
      faceIndex < uvFaces.length && faceIndex < namedUvsByFace.length;
      faceIndex += 1
    ) {
      final values = uvFaces[faceIndex] as List<dynamic>;
      if (values.length < 6) continue;
      namedUvsByFace[faceIndex][name] = [
        Vec2((values[0] as num).toDouble(), (values[1] as num).toDouble()),
        Vec2((values[2] as num).toDouble(), (values[3] as num).toDouble()),
        Vec2((values[4] as num).toDouble(), (values[5] as num).toDouble()),
      ];
    }
  }
  final faces = importedFaces.indexed.map((entry) {
    final faceIndex = entry.$1;
    final item = entry.$2;
    final values = item as List<dynamic>;
    return MeshFace(
      [
        (values[0] as num).toInt(),
        (values[1] as num).toInt(),
        (values[2] as num).toInt(),
      ],
      values.length > 3 ? (values[3] as num).toInt() : 0,
      values.length >= 10
          ? [
              Vec2(
                (values[4] as num).toDouble(),
                (values[5] as num).toDouble(),
              ),
              Vec2(
                (values[6] as num).toDouble(),
                (values[7] as num).toDouble(),
              ),
              Vec2(
                (values[8] as num).toDouble(),
                (values[9] as num).toDouble(),
              ),
            ]
          : const [],
      namedUvsByFace[faceIndex],
    );
  }).toList();
  final skin = SkinBinding.fromJson(json['skin'] as Map<String, dynamic>?);
  final restSkeleton = SkeletonAnimation.fromJson(
    json['skeleton'] as Map<String, dynamic>?,
  );
  final vertexColors = ((json['vertexColors'] as List<dynamic>?) ?? const [])
      .map((item) {
        final values = item as List<dynamic>;
        final r = (((values[0] as num).toDouble()).clamp(0, 1) * 255).round();
        final g = (((values[1] as num).toDouble()).clamp(0, 1) * 255).round();
        final b = (((values[2] as num).toDouble()).clamp(0, 1) * 255).round();
        final a = values.length > 3
            ? (((values[3] as num).toDouble()).clamp(0, 1) * 255).round()
            : 255;
        return Color.fromARGB(a, r, g, b);
      })
      .toList();
  if (vertexColorSetIsUnusable(vertexColors)) {
    fbxLog(
      'Discarding ${vertexColors.length} vertex colors for $name: the whole '
      'set is black or fully transparent, which would render the mesh black.',
    );
    vertexColors.clear();
  }
  final nonWhiteVertexColors = vertexColors.where((color) {
    final r = (color.r * 255).round().clamp(0, 255);
    final g = (color.g * 255).round().clamp(0, 255);
    final b = (color.b * 255).round().clamp(0, 255);
    return r < 250 || g < 250 || b < 250;
  }).length;
  if (vertexColors.isNotEmpty) {
    fbxLog(
      'Vertex color stats for $name: total=${vertexColors.length}, nonWhite=$nonWhiteVertexColors',
    );
  }
  final materials = <MeshMaterial>[];
  for (final item in ((json['materials'] as List<dynamic>?) ?? const [])) {
    final material = item as Map<String, dynamic>;
    final color =
        (material['color'] as List<dynamic>?) ?? const [0.56, 0.72, 0.85];
    final opacity = ((material['opacity'] as num?)?.toDouble() ?? 1.0).clamp(
      0.0,
      1.0,
    );
    final roughness = ((material['roughness'] as num?)?.toDouble() ?? 0.7)
        .clamp(0.0, 1.0);
    final metalness = ((material['metalness'] as num?)?.toDouble() ?? 0.0)
        .clamp(0.0, 1.0);
    final specularFactor =
        ((material['specularFactor'] as num?)?.toDouble() ?? 0.2).clamp(
          0.0,
          2.0,
        );
    final emissiveFactor =
        ((material['emissiveFactor'] as num?)?.toDouble() ?? 0.0).clamp(
          0.0,
          8.0,
        );
    final emissiveValues =
        (material['emissiveColor'] as List<dynamic>?) ?? const [0.0, 0.0, 0.0];
    final emissiveColor = Color.fromARGB(
      255,
      (((emissiveValues[0] as num).toDouble()).clamp(0, 1) * 255).round(),
      (((emissiveValues[1] as num).toDouble()).clamp(0, 1) * 255).round(),
      (((emissiveValues[2] as num).toDouble()).clamp(0, 1) * 255).round(),
    );
    final textureRefs = ((material['textures'] as List<dynamic>?) ?? const [])
        .cast<String>();
    final uvSet = (material['uvSet'] as String?)?.trim() ?? '';
    final embeddedTextureBase64 =
        (material['embeddedTextureBase64'] as String?) ?? '';
    final resolvedTextures = textureRefs
        .map(
          (texture) => resolveTextureReference(
            modelPath,
            texture,
            allAssets: allAssets,
            allowFallbackLookup: false,
          ),
        )
        .whereType<String>()
        .toList();
    fbxLog(
      'Material ${(material['name'] as String?) ?? 'Material'} refs=${textureRefs.length} resolved=${resolvedTextures.length}',
    );
    final textureColor = await firstTextureAverageColor(resolvedTextures);
    ui.Image? textureImage;
    if (embeddedTextureBase64.isNotEmpty) {
      try {
        textureImage = await decodeImage(base64Decode(embeddedTextureBase64));
        fbxLog(
          'Decoded embedded texture for ${(material['name'] as String?) ?? 'Material'} '
          '(${textureImage.width}x${textureImage.height})',
        );
      } catch (error) {
        fbxLog('Embedded texture decode failed: $error');
      }
    }
    textureImage ??= await firstTextureImage(resolvedTextures);

    // Read the texture back once so single-texel faces can be filled directly.
    Uint8List? texturePixels;
    if (textureImage != null) {
      try {
        final data = await textureImage.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        texturePixels = data?.buffer.asUint8List();
      } catch (error) {
        fbxLog('Texture readback failed: $error');
      }
    }

    // Normal map: resolved through the same pipeline as the base texture, and
    // read back to CPU because shading here is computed per face, not on the
    // GPU.
    final normalRef = (material['normalTexture'] as String?)?.trim() ?? '';
    Uint8List? normalPixels;
    var normalWidth = 0;
    var normalHeight = 0;
    if (normalRef.isNotEmpty) {
      final resolvedNormal = resolveTextureReference(
        modelPath,
        normalRef,
        allAssets: allAssets,
        allowFallbackLookup: false,
      );
      if (resolvedNormal != null) {
        try {
          final normalImage = await firstTextureImage([resolvedNormal]);
          if (normalImage != null) {
            final data = await normalImage.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            normalPixels = data?.buffer.asUint8List();
            normalWidth = normalImage.width;
            normalHeight = normalImage.height;
            fbxLog(
              'Normal map for ${(material['name'] as String?) ?? 'Material'}: '
              '$resolvedNormal (${normalWidth}x$normalHeight)',
            );
          }
        } catch (error) {
          fbxLog('Normal map decode failed: $error');
        }
      } else {
        fbxLog('Normal map referenced but not resolved: $normalRef');
      }
    }

    // Emissive: same resolution path, sampled additively so lit signage and
    // screens are not flattened to their base colour.
    final emissiveRef = (material['emissiveTexture'] as String?)?.trim() ?? '';
    Uint8List? emissivePixels;
    var emissiveWidth = 0;
    var emissiveHeight = 0;
    if (emissiveRef.isNotEmpty) {
      final resolvedEmissive = resolveTextureReference(
        modelPath,
        emissiveRef,
        allAssets: allAssets,
        allowFallbackLookup: false,
      );
      if (resolvedEmissive != null) {
        try {
          final emissiveImage = await firstTextureImage([resolvedEmissive]);
          if (emissiveImage != null) {
            final data = await emissiveImage.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            emissivePixels = data?.buffer.asUint8List();
            emissiveWidth = emissiveImage.width;
            emissiveHeight = emissiveImage.height;
          }
        } catch (error) {
          fbxLog('Emissive decode failed: $error');
        }
      }
    }

    materials.add(
      MeshMaterial(
        name: (material['name'] as String?) ?? 'Material',
        color: Color.fromARGB(
          255,
          (((color[0] as num).toDouble()).clamp(0, 1) * 255).round(),
          (((color[1] as num).toDouble()).clamp(0, 1) * 255).round(),
          (((color[2] as num).toDouble()).clamp(0, 1) * 255).round(),
        ),
        textures: textureRefs,
        resolvedTextures: resolvedTextures,
        textureColor: textureColor,
        textureImage: textureImage,
        texturePixels: texturePixels,
        normalTexture: normalRef,
        emissiveTexture: emissiveRef,
        emissivePixels: emissivePixels,
        emissiveWidth: emissiveWidth,
        emissiveHeight: emissiveHeight,
        normalPixels: normalPixels,
        normalWidth: normalWidth,
        normalHeight: normalHeight,
        textureWidth: textureImage?.width ?? 0,
        textureHeight: textureImage?.height ?? 0,
        opacity: opacity,
        roughness: roughness,
        metalness: metalness,
        specularFactor: specularFactor,
        emissiveFactor: emissiveFactor,
        emissiveColor: emissiveColor,
        shaderType: (material['shaderType'] as num?)?.toInt() ?? -1,
        shadingModel: (material['shadingModel'] as String?) ?? '',
        uvSet: uvSet,
        hasEmbeddedTexture: embeddedTextureBase64.isNotEmpty,
      ),
    );
  }
  final textureFiles = ((json['textureFiles'] as List<dynamic>?) ?? const [])
      .cast<String>()
      .where((path) => path.isNotEmpty)
      .toList();
  final sceneTextureRefs =
      ((json['sceneTextures'] as List<dynamic>?) ?? const [])
          .map((item) {
            if (item is String) {
              return item;
            }
            if (item is! Map<String, dynamic>) {
              return null;
            }
            final filename = (item['filename'] as String?)?.trim() ?? '';
            final relative =
                (item['relativeFilename'] as String?)?.trim() ?? '';
            final absolute =
                (item['absoluteFilename'] as String?)?.trim() ?? '';
            return [
              filename,
              relative,
              absolute,
            ].firstWhere((value) => value.isNotEmpty, orElse: () => '');
          })
          .whereType<String>()
          .where((path) => path.isNotEmpty)
          .toList();
  if (sceneTextureRefs.isNotEmpty) {
    fbxLog(
      'Scene texture references: ${sceneTextureRefs.take(6).join(' | ')}${sceneTextureRefs.length > 6 ? ' ...' : ''}',
    );
  }

  if (materials.isEmpty && faces.any((face) => face.uvsFor(null).length == 3)) {
    final declaredResolved = <String>{};
    for (final texture in [...textureFiles, ...sceneTextureRefs]) {
      final resolved = resolveTextureReference(
        modelPath,
        texture,
        allAssets: allAssets,
        allowFallbackLookup: false,
      );
      if (resolved != null) {
        declaredResolved.add(resolved);
      }
    }

    if (declaredResolved.isNotEmpty) {
      final resolvedList = declaredResolved.toList();
      final declaredColor = await firstTextureAverageColor(resolvedList);
      final declaredImage = await firstTextureImage(resolvedList);
      materials.add(
        MeshMaterial(
          name: 'DeclaredTexture',
          color: const Color(0xff8fb8d8),
          textures: [...textureFiles, ...sceneTextureRefs],
          resolvedTextures: resolvedList,
          textureColor: declaredColor,
          textureImage: declaredImage,
          opacity: 1.0,
          roughness: 0.7,
          metalness: 0.0,
          specularFactor: 0.2,
          emissiveFactor: 0.0,
          emissiveColor: const Color(0xff000000),
          shaderType: -1,
          shadingModel: 'declared',
        ),
      );
      fbxLog('Applied declared FBX texture reference: ${resolvedList.first}');
    }
  }

  if (materials.isEmpty && faces.any((face) => face.uvsFor(null).length == 3)) {
    const checkerTextureSize = 256;
    final checkerCells = math.max(
      2,
      (checkerTextureSize / fallbackCheckerSquareSize).round(),
    );
    final checkerImage = await createCheckerboardTextureImage(
      size: checkerTextureSize,
      cells: checkerCells,
    );
    materials.add(
      MeshMaterial(
        name: 'CheckerFallback',
        color: const Color(0xff8fb8d8),
        textures: const [],
        resolvedTextures: const [],
        textureColor: const Color(0xffcbd5e1),
        textureImage: checkerImage,
        opacity: 1.0,
        roughness: 0.7,
        metalness: 0.0,
        specularFactor: 0.2,
        emissiveFactor: 0.0,
        emissiveColor: const Color(0xff000000),
        shaderType: -1,
        shadingModel: 'checker',
      ),
    );
    fbxLog(
      'Applied checkerboard fallback texture for materialless FBX: $modelPath',
    );
  }

  if (vertices.isEmpty || faces.isEmpty) {
    throw const FormatException('ufbx returned no renderable geometry.');
  }
  final uvFaces = faces.where((face) => face.uvsFor(null).length == 3).length;
  final texturedMaterials = materials
      .where((material) => material.textureImage != null)
      .length;
  fbxLog(
    'Mesh summary for $name: vertices=${vertices.length}, faces=${faces.length}, uvFaces=$uvFaces, materials=${materials.length}, texturedMaterials=$texturedMaterials, vertexColors=${vertexColors.length}, nonWhiteVertexColors=$nonWhiteVertexColors',
  );
  return MeshModel(
    name: name,
    vertices: vertices,
    faces: faces,
    materials: materials,
    textureFiles: textureFiles,
    vertexColors: vertexColors,
    skin: skin,
    skeleton: restSkeleton,
  );
}

String meshImporterPath() {
  final executableDir = File(Platform.resolvedExecutable).parent.path;
  final packaged =
      '$executableDir${Platform.pathSeparator}asset_atlas_mesh_importer.exe';
  if (File(packaged).existsSync()) return packaged;

  // flutter_test runs from the project but uses flutter_tester.exe from the SDK,
  // so the packaged sibling lookup cannot find a locally-built native helper.
  final developmentBuild = File(
    'build${Platform.pathSeparator}windows${Platform.pathSeparator}x64'
    '${Platform.pathSeparator}runner${Platform.pathSeparator}Release'
    '${Platform.pathSeparator}asset_atlas_mesh_importer.exe',
  ).absolute.path;
  if (File(developmentBuild).existsSync()) return developmentBuild;
  return packaged;
}

String? findModelFallbackTexture(String modelPath, List<AssetItem> allAssets) {
  final modelDir = parentPath(modelPath).toLowerCase();
  final modelPathLower = modelPath.toLowerCase().replaceAll('\\', '/');
  final genericTokens = {
    'sm',
    'fbx',
    'obj',
    'mesh',
    'meshes',
    'model',
    'models',
    'asset',
    'assets',
    'content',
    'sourceart',
    'source',
    'marketplace',
    'material',
    'materials',
    'levelprototyping',
    'interactable',
    'texture',
    'textures',
  };

  Set<String> semanticTokens(String value) {
    return tokenSet(
      value,
    ).where((token) => !genericTokens.contains(token)).toSet();
  }

  String relativeFromRoot(String fullPath, String rootPath) {
    final full = fullPath.toLowerCase().replaceAll('\\', '/');
    final root = rootPath.toLowerCase().replaceAll('\\', '/');
    if (full == root) return '';
    if (full.startsWith('$root/')) {
      return full.substring(root.length + 1);
    }
    return full;
  }

  final modelNameTokens = semanticTokens(
    modelPath.split(RegExp(r'[\\/]')).last,
  );
  final baseCandidates = allAssets.where((asset) {
    if (!imageExts.contains(asset.ext)) return false;
    final dir = parentPath(asset.path).toLowerCase();
    if (dir == modelDir) return true;
    final lowerPath = asset.path.toLowerCase().replaceAll('\\', '/');
    return lowerPath.contains('/textures/');
  }).toList();

  if (baseCandidates.isEmpty) return null;

  final sameSourceCandidates = baseCandidates.where((asset) {
    final sourceLower = asset.sourceRoot.toLowerCase().replaceAll('\\', '/');
    return modelPathLower.startsWith(sourceLower);
  }).toList();
  final candidates = sameSourceCandidates.isNotEmpty
      ? sameSourceCandidates
      : baseCandidates;

  String? modelSourceRoot;
  for (final candidate in candidates) {
    final root = candidate.sourceRoot.toLowerCase().replaceAll('\\', '/');
    if (modelPathLower.startsWith(root)) {
      modelSourceRoot = root;
      break;
    }
  }
  final modelRelativePath = modelSourceRoot == null
      ? modelPathLower
      : relativeFromRoot(modelPathLower, modelSourceRoot);
  final modelRelativeSegments = modelRelativePath.split('/');
  final modelTokens = semanticTokens(modelRelativePath);

  int score(AssetItem asset) {
    final assetPathLower = asset.path.toLowerCase().replaceAll('\\', '/');
    final assetRelativePath = modelSourceRoot == null
        ? assetPathLower
        : relativeFromRoot(assetPathLower, modelSourceRoot);
    final assetRelativeSegments = assetRelativePath.split('/');
    final assetNameTokens = semanticTokens(asset.name);
    final assetPathTokens = semanticTokens(assetRelativePath);
    final nameOverlap = modelNameTokens.intersection(assetNameTokens).length;
    final pathOverlap = modelTokens.intersection(assetPathTokens).length;

    var value = nameOverlap * 24 + pathOverlap * 14;

    // If there is no semantic overlap at all, do not allow weak path bonuses
    // to force an unrelated texture.
    if (nameOverlap == 0 && pathOverlap == 0) {
      return 0;
    }

    if (parentPath(asset.path).toLowerCase() == modelDir) value += 6;
    if (assetPathLower.contains('/textures/')) {
      value += 4;
    }

    // Prefer textures that are path-wise close under the same source root.
    var sharedPrefix = 0;
    final maxPrefix = math.min(
      modelRelativeSegments.length,
      assetRelativeSegments.length,
    );
    while (sharedPrefix < maxPrefix &&
        modelRelativeSegments[sharedPrefix] ==
            assetRelativeSegments[sharedPrefix]) {
      sharedPrefix += 1;
    }
    value += math.min(sharedPrefix * 2, 12);

    return value;
  }

  final scored = <({AssetItem asset, int score})>[];
  for (final candidate in candidates) {
    scored.add((asset: candidate, score: score(candidate)));
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  final top = scored.take(5).toList();
  for (final entry in top) {
    fbxLog('Fallback candidate score=${entry.score} path=${entry.asset.path}');
  }

  final bestScore = top.isEmpty ? 0 : top.first.score;
  final secondBest = top.length > 1 ? top[1].score : 0;
  if (top.isEmpty || bestScore < 18 || (bestScore - secondBest) < 6) {
    fbxLog(
      'Fallback rejected due to low confidence or ambiguity (bestScore=$bestScore, secondBest=$secondBest) for model=$modelPath',
    );
    return null;
  }

  final selected = top.first.asset.path;
  fbxLog('Fallback selected texture: $selected');
  return selected;
}

/// Parses an OBJ, including the parts the first version threw away.
///
/// `vt` lines and the `v/vt/vn` corner references were being dropped, so an
/// OBJ could never be textured no matter what else resolved -- a Synty barn
/// carries 12k texture coordinates and arrived with none. `usemtl` splits the
/// mesh into materials and `mtllib` records the sidecar so the texture
/// resolver can chase it; an OBJ that names neither still parses, it just gets
/// one unnamed material.
MeshModel parseObjMesh(String text, String name) {
  final vertices = <Vec3>[];
  final texCoords = <Vec2>[];
  final faces = <MeshFace>[];
  final materialNames = <String>[];
  final materialLibraries = <String>[];
  var currentMaterial = 0;

  int? resolveIndex(String token, int count) {
    final raw = int.tryParse(token);
    if (raw == null || raw == 0) return null;
    // OBJ indices are 1-based, and negative counts back from the current end.
    final index = raw < 0 ? count + raw : raw - 1;
    return index >= 0 && index < count ? index : null;
  }

  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.startsWith('v ')) {
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 4) {
        vertices.add(
          Vec3(
            double.parse(parts[1]),
            double.parse(parts[2]),
            double.parse(parts[3]),
          ),
        );
      }
    } else if (line.startsWith('vt ')) {
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 3) {
        // OBJ's V axis points up; the sampler's points down.
        texCoords.add(
          Vec2(
            double.tryParse(parts[1]) ?? 0,
            1 - (double.tryParse(parts[2]) ?? 0),
          ),
        );
      }
    } else if (line.startsWith('mtllib ')) {
      final library = line.substring(7).trim();
      if (library.isNotEmpty && !materialLibraries.contains(library)) {
        materialLibraries.add(library);
      }
    } else if (line.startsWith('usemtl ')) {
      final material = line.substring(7).trim();
      final existing = materialNames.indexOf(material);
      if (existing >= 0) {
        currentMaterial = existing;
      } else {
        materialNames.add(material);
        currentMaterial = materialNames.length - 1;
      }
    } else if (line.startsWith('f ')) {
      final indices = <int>[];
      final uvs = <Vec2?>[];
      for (final token in line.substring(2).trim().split(RegExp(r'\s+'))) {
        final fields = token.split('/');
        final vertexIndex = resolveIndex(fields.first, vertices.length);
        if (vertexIndex == null) continue;
        indices.add(vertexIndex);
        // The middle field is the texture coordinate; "v//vn" leaves it empty.
        final uvIndex = fields.length > 1 && fields[1].isNotEmpty
            ? resolveIndex(fields[1], texCoords.length)
            : null;
        uvs.add(uvIndex == null ? null : texCoords[uvIndex]);
      }
      _addTriangulatedFace(indices, faces, uvs: uvs, material: currentMaterial);
    }
  }
  if (vertices.isEmpty || faces.isEmpty) {
    throw const FormatException('No OBJ geometry found.');
  }

  final materials = [
    for (final materialName in materialNames)
      MeshMaterial(
        name: materialName,
        color: const Color(0xffb9c2cc),
        textures: const [],
      ),
  ];
  return MeshModel.normalized(
    name: name,
    vertices: vertices,
    faces: faces,
    materials: materials.isEmpty
        ? const [MeshMaterial(name: '', color: Color(0xffb9c2cc), textures: [])]
        : materials,
    textureFiles: materialLibraries,
  );
}

void _addTriangulatedFace(
  List<int> indices,
  List<MeshFace> faces, {
  List<Vec2?> uvs = const [],
  int material = 0,
}) {
  if (indices.length < 3) return;
  // A fan from the first corner. The UVs have to be fanned the same way, and
  // a partly-textured polygon contributes none rather than a mix.
  for (var i = 1; i < indices.length - 1; i += 1) {
    final corners = [0, i, i + 1];
    final faceUvs = <Vec2>[];
    if (uvs.length == indices.length) {
      for (final corner in corners) {
        final uv = uvs[corner];
        if (uv == null) {
          faceUvs.clear();
          break;
        }
        faceUvs.add(uv);
      }
    }
    faces.add(
      MeshFace(
        [indices[0], indices[i], indices[i + 1]],
        material,
        faceUvs.length == 3 ? faceUvs : const [],
      ),
    );
  }
}

/// How much of a vertex-colour set must be black before it is discarded.
const unusableVertexColorFraction = 0.9;

/// Whether a vertex-colour set should be thrown away rather than applied.
///
/// Vertex colours multiply the shaded surface, so a set that is essentially
/// all black renders the mesh black however well its textures resolved. No
/// asset means that: it is what an exporter writes for a colour layer nothing
/// ever filled in.
///
/// A threshold rather than an exact test, because `PolygonSyntyCharacter.fbx`
/// ships 14,688 vertex colours of which 14,628 are black and exactly 60 are
/// white -- and those 60 strays were enough to defeat an all-or-nothing rule
/// while leaving 99.6% of the model rendering black.
///
/// Black *parts* of a model are real art. A model that is almost entirely
/// black is not, and drawing it black helps nobody.
bool vertexColorSetIsUnusable(List<Color> colors) {
  if (colors.isEmpty) return false;
  var black = 0;
  for (final color in colors) {
    final isBlack =
        (color.r * 255).round() <= 2 &&
        (color.g * 255).round() <= 2 &&
        (color.b * 255).round() <= 2;
    // Fully transparent is the same kind of artifact.
    if (isBlack || (color.a * 255).round() <= 2) black += 1;
  }
  return black >= colors.length * unusableVertexColorFraction;
}

/// Settings key for the model clips are played on.
const animationCharacterKey = 'animation.character.path';

/// The model animation clips are played on, and the clip preview's fallback.
///
/// Held here rather than threaded through the widget tree because a clip and
/// the character it plays on are selected in completely different places: you
/// pick the character once from a model's own preview, then click clips.
class AnimationCharacter {
  AnimationCharacter._();

  static final AnimationCharacter instance = AnimationCharacter._();

  /// Notifies when the choice changes, so an open clip preview re-poses.
  final ValueNotifier<String?> path = ValueNotifier<String?>(null);

  Future<void> load() async {
    try {
      path.value = await AssetAtlasDatabase.instance.readSetting(
        animationCharacterKey,
      );
    } catch (error) {
      // A missing settings row is not worth failing startup over.
      fbxLog('Could not read the animation character: $error');
    }
  }

  Future<void> set(String? assetPath) async {
    path.value = assetPath;
    try {
      await AssetAtlasDatabase.instance.writeSetting(
        animationCharacterKey,
        assetPath,
      );
    } catch (error) {
      fbxLog('Could not save the animation character: $error');
    }
  }
}

/// How a mesh's vertices follow a rig.
///
/// Emitted once with the character; a clip supplies only the bone matrices, so
/// posing is a weighted matrix blend per vertex and nothing else.
class SkinBinding {
  const SkinBinding({
    required this.boneNames,
    required this.bindInverse,
    required this.influences,
    required this.vertexSkin,
    this.bonePaths = const [],
    this.normalizeCenter = const Vec3(0, 0, 0),
    this.normalizeScale = 1,
  });

  /// Reads the `skin` object the importer emits. Null when absent or unusable.
  static SkinBinding? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final boneList = (json['bones'] as List<dynamic>?) ?? const [];
    if (boneList.isEmpty) return null;

    final names = <String>[];
    final paths = <String>[];
    final bind = Float32List(boneList.length * 12);
    for (var i = 0; i < boneList.length; i += 1) {
      final bone = boneList[i] as Map<String, dynamic>;
      names.add((bone['name'] ?? '').toString());
      paths.add((bone['path'] ?? '').toString());
      final matrix = (bone['bindInverse'] as List<dynamic>?) ?? const [];
      if (matrix.length != 12) return null;
      for (var j = 0; j < 12; j += 1) {
        bind[i * 12 + j] = (matrix[j] as num).toDouble();
      }
    }

    final rawInfluences = (json['vertices'] as List<dynamic>?) ?? const [];
    final influences = Float32List(rawInfluences.length);
    for (var i = 0; i < rawInfluences.length; i += 1) {
      influences[i] = (rawInfluences[i] as num).toDouble();
    }

    final rawVertexSkin = (json['vertexSkin'] as List<dynamic>?) ?? const [];
    final vertexSkin = Int32List(rawVertexSkin.length);
    for (var i = 0; i < rawVertexSkin.length; i += 1) {
      vertexSkin[i] = (rawVertexSkin[i] as num).toInt();
    }
    if (vertexSkin.isEmpty || influences.isEmpty) return null;

    final center = (json['normalizeCenter'] as List<dynamic>?) ?? const [];
    return SkinBinding(
      boneNames: names,
      bonePaths: paths,
      bindInverse: bind,
      influences: influences,
      vertexSkin: vertexSkin,
      normalizeCenter: center.length == 3
          ? Vec3(
              (center[0] as num).toDouble(),
              (center[1] as num).toDouble(),
              (center[2] as num).toDouble(),
            )
          : const Vec3(0, 0, 0),
      normalizeScale: (json['normalizeScale'] as num?)?.toDouble() ?? 1,
    );
  }

  final List<String> boneNames;

  /// Each bone's chain from the root, parallel to [boneNames].
  final List<String> bonePaths;

  /// The framing transform the importer applied to the vertices.
  ///
  /// Every mesh is recentred and rescaled into a unit box so the viewer can
  /// frame it, but the bind matrices are written against the file's own
  /// coordinates. The importer folds the inverse into [bindInverse], so a
  /// posed vertex comes out in file coordinates and has to be put back:
  /// `(p - normalizeCenter) * normalizeScale`. Skipping that step left a
  /// character's mesh 0.89m from its skeleton, which tore it apart.
  final Vec3 normalizeCenter;
  final double normalizeScale;

  /// Per bone, a column-major 3x4 taking a mesh vertex into bone space at the
  /// bind pose. The mesh's own geometry-to-world is already folded in, so it
  /// applies to the vertices as imported.
  final Float32List bindInverse;

  /// Four (bone, weight) pairs per skinned vertex, zero-weight padded.
  final Float32List influences;

  /// Per mesh vertex, an index into [influences] blocks, or -1.
  final Int32List vertexSkin;
}

/// Applies `matrix` (column-major 3x4) to a point.
Vec3 transformByMatrix(Float32List matrix, int offset, Vec3 point) {
  return Vec3(
    matrix[offset] * point.x +
        matrix[offset + 3] * point.y +
        matrix[offset + 6] * point.z +
        matrix[offset + 9],
    matrix[offset + 1] * point.x +
        matrix[offset + 4] * point.y +
        matrix[offset + 7] * point.z +
        matrix[offset + 10],
    matrix[offset + 2] * point.x +
        matrix[offset + 5] * point.y +
        matrix[offset + 8] * point.z +
        matrix[offset + 11],
  );
}

/// Inverts a column-major 3x4 affine matrix into `out` at `outOffset`.
///
/// Returns false and leaves `out` untouched when the matrix is singular,
/// which a degenerate bone can be.
bool invertMatrix(Float32List a, int aOffset, Float32List out, int outOffset) {
  final m00 = a[aOffset], m01 = a[aOffset + 1], m02 = a[aOffset + 2];
  final m10 = a[aOffset + 3], m11 = a[aOffset + 4], m12 = a[aOffset + 5];
  final m20 = a[aOffset + 6], m21 = a[aOffset + 7], m22 = a[aOffset + 8];
  final tx = a[aOffset + 9], ty = a[aOffset + 10], tz = a[aOffset + 11];

  // Columns are the basis vectors, so the determinant is their triple product.
  final det =
      m00 * (m11 * m22 - m12 * m21) -
      m10 * (m01 * m22 - m02 * m21) +
      m20 * (m01 * m12 - m02 * m11);
  if (det.abs() < 1e-12) return false;
  final inv = 1.0 / det;

  final i00 = (m11 * m22 - m12 * m21) * inv;
  final i01 = (m02 * m21 - m01 * m22) * inv;
  final i02 = (m01 * m12 - m02 * m11) * inv;
  final i10 = (m12 * m20 - m10 * m22) * inv;
  final i11 = (m00 * m22 - m02 * m20) * inv;
  final i12 = (m02 * m10 - m00 * m12) * inv;
  final i20 = (m10 * m21 - m11 * m20) * inv;
  final i21 = (m01 * m20 - m00 * m21) * inv;
  final i22 = (m00 * m11 - m01 * m10) * inv;

  out[outOffset] = i00;
  out[outOffset + 1] = i01;
  out[outOffset + 2] = i02;
  out[outOffset + 3] = i10;
  out[outOffset + 4] = i11;
  out[outOffset + 5] = i12;
  out[outOffset + 6] = i20;
  out[outOffset + 7] = i21;
  out[outOffset + 8] = i22;
  out[outOffset + 9] = -(i00 * tx + i10 * ty + i20 * tz);
  out[outOffset + 10] = -(i01 * tx + i11 * ty + i21 * tz);
  out[outOffset + 11] = -(i02 * tx + i12 * ty + i22 * tz);
  return true;
}

/// Multiplies two column-major 3x4 matrices into `out` at `outOffset`.
void multiplyMatrices(
  Float32List a,
  int aOffset,
  Float32List b,
  int bOffset,
  Float32List out,
  int outOffset,
) {
  for (var column = 0; column < 4; column += 1) {
    final bx = b[bOffset + column * 3];
    final by = b[bOffset + column * 3 + 1];
    final bz = b[bOffset + column * 3 + 2];
    // The fourth column is a point, so it picks up the translation; the first
    // three are directions and do not.
    final translate = column == 3 ? 1.0 : 0.0;
    for (var row = 0; row < 3; row += 1) {
      out[outOffset + column * 3 + row] =
          a[aOffset + row] * bx +
          a[aOffset + 3 + row] * by +
          a[aOffset + 6 + row] * bz +
          a[aOffset + 9 + row] * translate;
    }
  }
}

/// Characters shipped alongside a clip, any of which may be its reference.
///
/// Retargeting needs to know what the clip's rig looks like in the same
/// physical pose the character is bound in -- both T-posed, in practice. A
/// clip file cannot supply that: its own rest pose is wherever the animator
/// left the rig, which for a locomotion pack is a standing idle.
///
/// An animation pack ships a character on its own rig for exactly this reason,
/// so references are looked for beside the clip, in the same archive. There
/// can be more than one: the base locomotion pack ships clips for two rig
/// families side by side, `Animations/Polygon` and `Animations/Sidekick`, with
/// `PolygonSyntyCharacter` and `SidekickSyntyCharacter` to match. Picking the
/// wrong one corrects against a rig the clip was never authored for, which
/// mangles the result as thoroughly as no correction at all -- so the caller
/// measures each against the clip rather than guessing from the name.
List<AssetItem> findClipReferenceCharacters(
  String clipPath,
  List<AssetItem> allAssets,
) {
  final clipZip = parseZipVirtualPath(clipPath);
  final clipRoot = clipZip == null ? parentPath(clipPath) : null;

  final candidates = <AssetItem>[];
  for (final asset in allAssets) {
    if (asset.ext != 'fbx') continue;
    if (normalizePathKey(asset.path) == normalizePathKey(clipPath)) continue;
    final lower = asset.path.toLowerCase().replaceAll(r'\', '/');
    if (!lower.contains('/character')) continue;

    if (clipZip != null) {
      final zip = parseZipVirtualPath(asset.path);
      if (zip == null ||
          normalizePathKey(zip.zipPath) != normalizePathKey(clipZip.zipPath)) {
        continue;
      }
    } else if (clipRoot == null || !asset.path.startsWith(clipRoot)) {
      continue;
    }
    candidates.add(asset);
  }
  // Deterministic order: the caller measures each, and ties must not depend
  // on scan order.
  candidates.sort(
    (a, b) => normalizePathKey(a.path).compareTo(normalizePathKey(b.path)),
  );
  return candidates;
}

/// Transfers a clip's pose onto a character whose rig holds its bones at
/// different angles.
///
/// Two Synty rigs can share every bone name, every parent and the whole
/// hierarchy and still be incompatible: the newer character packs re-oriented
/// the joint axes, so `Hand_L` points 169 degrees away from where the older
/// animation rig puts it. Applying a clip's bone transforms directly to such a
/// character tears the mesh apart.
///
/// The fix is to work in each bone's *local* frame and go through a reference
/// pose. For every bone, `correction` is the constant that takes the reference
/// rig's local frame to the character's own bind:
///
///     correction = inverse(referenceLocal) * characterBindLocal
///     characterLocal(t) = clipLocal(t) * correction
///
/// At the reference pose the correction cancels and the character stands in
/// its bind, which is what makes this safe: a rig it cannot interpret comes
/// out unposed rather than mangled.
///
/// [sourceReference] is the clip rig's own rest pose unless a better one is
/// supplied. A reference in the same *physical* pose as the character's bind
/// (both T-posed, say) makes the character adopt the clip's pose; the clip's
/// own rest, which for a locomotion pack is a standing idle, makes it perform
/// the clip's motion starting from its bind.
class RetargetPlan {
  RetargetPlan._(
    this._correction,
    this._clipBone,
    this._clipParents,
    this._parent,
    this._order,
  );

  /// Builds the plan once for a character and clip; it does not change frame
  /// to frame, and computing it per frame would dominate playback.
  ///
  /// Returns null when the character carries no rest pose to correct against.
  static RetargetPlan? build({
    required SkeletonAnimation characterRest,
    required SkeletonAnimation clip,
    SkeletonAnimation? sourceReference,
  }) {
    final bind = characterRest.rest ?? characterRest.positions.firstOrNull;
    if (bind == null) return null;
    // The reference may be a different rig from the clip -- that is the point
    // of supplying one -- so it carries its own bone list to look up in.
    final referenceRig = sourceReference ?? clip;
    final reference = referenceRig.rest;
    if (reference == null) return null;

    final bones = characterRest.bones;
    final count = bones.length;
    final parent = Int32List(count);
    final clipBone = Int32List(count);
    final correction = Float32List(count * 12);

    // Parents before children, so a bone's world transform is ready when its
    // children need it.
    final order = Int32List(count);
    var filled = 0;
    final placed = List<bool>.filled(count, false);
    void visit(int index) {
      if (placed[index]) return;
      final up = bones[index].parent;
      if (up >= 0 && up < count) visit(up);
      placed[index] = true;
      order[filled++] = index;
    }

    for (var i = 0; i < count; i += 1) {
      visit(i);
    }

    final scratch = Float32List(24);
    for (var i = 0; i < count; i += 1) {
      parent[i] = bones[i].parent;
      clipBone[i] = clip.indexOfBone(bones[i].name, path: bones[i].path);

      // Both frames reduced to parent-relative, which is where a rotation
      // means the same thing in either rig.
      _localOf(bind, i, parent[i], scratch, 0);
      final k = clipBone[i];
      if (k < 0) {
        // Nothing drives this bone; leave it at its bind.
        for (var j = 0; j < 12; j += 1) {
          correction[i * 12 + j] = scratch[j];
        }
        continue;
      }
      final r = identical(referenceRig, clip)
          ? k
          : referenceRig.indexOfBone(bones[i].name, path: bones[i].path);
      if (r < 0) {
        for (var j = 0; j < 12; j += 1) {
          correction[i * 12 + j] = scratch[j];
        }
        continue;
      }
      _localOf(reference, r, referenceRig.bones[r].parent, scratch, 12);

      final inverse = Float32List(12);
      if (!invertMatrix(scratch, 12, inverse, 0)) {
        for (var j = 0; j < 12; j += 1) {
          correction[i * 12 + j] = scratch[j];
        }
        continue;
      }
      multiplyMatrices(inverse, 0, scratch, 0, correction, i * 12);
    }

    final clipParents = Int32List(clip.bones.length);
    for (var i = 0; i < clip.bones.length; i += 1) {
      clipParents[i] = clip.bones[i].parent;
    }
    return RetargetPlan._(correction, clipBone, clipParents, parent, order);
  }

  final Float32List _correction;
  final Int32List _clipBone;
  final Int32List _clipParents;
  final Int32List _parent;
  final Int32List _order;

  int get boneCount => _clipBone.length;

  /// The character's bone world transforms for one frame of the clip.
  Float32List worldForFrame(
    SkeletonAnimation clip,
    int frame,
    Float32List out,
  ) {
    if (frame < 0 || frame >= clip.frameCount) return out;
    final frameData = clip.positions[frame];
    final local = Float32List(12);
    final scratch = Float32List(12);

    for (final index in _order) {
      final k = _clipBone[index];
      if (k < 0) {
        for (var j = 0; j < 12; j += 1) {
          local[j] = _correction[index * 12 + j];
        }
      } else {
        _localOf(frameData, k, _clipParents[k], scratch, 0);
        multiplyMatrices(scratch, 0, _correction, index * 12, local, 0);
      }

      final up = _parent[index];
      if (up < 0 || up >= boneCount) {
        for (var j = 0; j < 12; j += 1) {
          out[index * 12 + j] = local[j];
        }
      } else {
        multiplyMatrices(out, up * 12, local, 0, out, index * 12);
      }
    }
    return out;
  }
}

/// Reduces a world transform to its parent-relative form.
void _localOf(
  Float32List world,
  int bone,
  int parent,
  Float32List out,
  int outOffset,
) {
  if (parent < 0) {
    for (var j = 0; j < 12; j += 1) {
      out[outOffset + j] = world[bone * 12 + j];
    }
    return;
  }
  final inverse = Float32List(12);
  if (!invertMatrix(world, parent * 12, inverse, 0)) {
    for (var j = 0; j < 12; j += 1) {
      out[outOffset + j] = world[bone * 12 + j];
    }
    return;
  }
  multiplyMatrices(inverse, 0, world, bone * 12, out, outOffset);
}

/// Above this many degrees apart, a clip's bone transforms cannot be applied
/// to a character directly.
///
/// The older Synty character rig sits about 19 degrees from the animation rig
/// and poses correctly; the newer packs sit at 89 and tear apart. Forty is
/// clear of both.
const maxDirectPoseAngle = 40.0;

/// How far apart two rigs hold the same bones, in degrees.
///
/// Near zero means the clip's transforms can be used directly. The older Synty
/// character rig sits about 26 degrees from the animation rig; the newer packs
/// sit at 89, which is what tore the mesh apart when posed directly.
double rigAxisDifference(
  SkeletonAnimation characterRest,
  SkeletonAnimation clip,
) {
  final bind = characterRest.rest ?? characterRest.positions.firstOrNull;
  final reference = clip.rest;
  if (bind == null || reference == null) return 0;

  final angles = <double>[];
  for (var i = 0; i < characterRest.bones.length; i += 1) {
    final bone = characterRest.bones[i];
    final k = clip.indexOfBone(bone.name, path: bone.path);
    if (k < 0) continue;
    // The x column of each frame, compared as directions.
    var ax = bind[i * 12], ay = bind[i * 12 + 1], az = bind[i * 12 + 2];
    var bx = reference[k * 12], by = reference[k * 12 + 1];
    var bz = reference[k * 12 + 2];
    final la = math.sqrt(ax * ax + ay * ay + az * az);
    final lb = math.sqrt(bx * bx + by * by + bz * bz);
    if (la < 1e-9 || lb < 1e-9) continue;
    ax /= la;
    ay /= la;
    az /= la;
    bx /= lb;
    by /= lb;
    bz /= lb;
    final dot = (ax * bx + ay * by + az * bz).clamp(-1.0, 1.0);
    angles.add(math.acos(dot) * 180 / math.pi);
  }
  // No shared bones is not a perfect match, it is no comparison at all.
  // Returning zero here made a rig with nothing in common look like the best
  // possible reference, which is how a Sidekick character got chosen to
  // correct a Polygon clip.
  if (angles.length < minimumRigOverlap) return double.infinity;
  angles.sort();
  return angles[angles.length ~/ 2];
}

/// How many bones two rigs must share before they can be compared at all.
const minimumRigOverlap = 4;

/// How many bones a character's rig shares with a clip.
///
/// The Synty families do not overlap at all -- Polygon has 52 bones, Sidekick
/// 121, and not one name in common -- so this separates "a different pose of
/// the same rig" from "a different rig entirely".
int rigBoneOverlap(SkeletonAnimation rig, SkeletonAnimation clip) {
  var shared = 0;
  for (final bone in rig.bones) {
    if (clip.indexOfBone(bone.name, path: bone.path) >= 0) shared += 1;
  }
  return shared;
}

/// Poses a character's vertices into a packed buffer.
///
/// The buffer form exists because animation calls this every frame: returning
/// a `List<Vec3>` allocates one object per vertex, and at 14,688 vertices and
/// 30fps that is half a million short-lived objects a second.
///
/// [out] must hold `character.vertices.length * 3` floats; it is returned for
/// convenience so callers can keep one buffer alive across frames.
Float32List poseSkinnedPositions({
  required MeshModel character,
  required SkeletonAnimation clip,
  required int frame,
  required Float32List out,
  RetargetPlan? plan,
  Float32List? boneWorld,
}) {
  final vertices = character.vertices;
  final skin = character.skin;
  if (skin == null || frame < 0 || frame >= clip.frameCount) {
    for (var v = 0; v < vertices.length; v += 1) {
      out[v * 3] = vertices[v].x;
      out[v * 3 + 1] = vertices[v].y;
      out[v * 3 + 2] = vertices[v].z;
    }
    return out;
  }

  final boneCount = skin.boneNames.length;
  final skinMatrices = Float32List(boneCount * 12);
  final usable = List<bool>.filled(boneCount, false);

  // Two ways to get a bone's animated transform. A retarget plan corrects for
  // rigs that hold their bones at different angles; without one the clip's
  // transforms are used directly, which is right only when both rigs agree.
  final rest = character.skeleton;
  if (plan != null && boneWorld != null && rest != null) {
    plan.worldForFrame(clip, frame, boneWorld);
    for (var i = 0; i < boneCount; i += 1) {
      final bone = rest.indexOfBone(
        skin.boneNames[i],
        path: i < skin.bonePaths.length ? skin.bonePaths[i] : null,
      );
      if (bone < 0) continue;
      multiplyMatrices(
        boneWorld,
        bone * 12,
        skin.bindInverse,
        i * 12,
        skinMatrices,
        i * 12,
      );
      usable[i] = true;
    }
  } else {
    final clipFrame = clip.positions[frame];
    for (var i = 0; i < boneCount; i += 1) {
      final clipBone = clip.indexOfBone(
        skin.boneNames[i],
        path: i < skin.bonePaths.length ? skin.bonePaths[i] : null,
      );
      if (clipBone < 0) continue;
      multiplyMatrices(
        clipFrame,
        clipBone * 12,
        skin.bindInverse,
        i * 12,
        skinMatrices,
        i * 12,
      );
      usable[i] = true;
    }
  }

  for (var v = 0; v < vertices.length; v += 1) {
    final vertex = vertices[v];
    final block = v < skin.vertexSkin.length ? skin.vertexSkin[v] : -1;
    var x = 0.0;
    var y = 0.0;
    var z = 0.0;
    var total = 0.0;
    if (block >= 0) {
      for (var k = 0; k < 4; k += 1) {
        final base = block * 8 + k * 2;
        if (base + 1 >= skin.influences.length) break;
        final weight = skin.influences[base + 1];
        if (weight <= 0) continue;
        final bone = skin.influences[base].toInt();
        if (bone < 0 || bone >= boneCount || !usable[bone]) continue;
        final offset = bone * 12;
        x +=
            (skinMatrices[offset] * vertex.x +
                skinMatrices[offset + 3] * vertex.y +
                skinMatrices[offset + 6] * vertex.z +
                skinMatrices[offset + 9]) *
            weight;
        y +=
            (skinMatrices[offset + 1] * vertex.x +
                skinMatrices[offset + 4] * vertex.y +
                skinMatrices[offset + 7] * vertex.z +
                skinMatrices[offset + 10]) *
            weight;
        z +=
            (skinMatrices[offset + 2] * vertex.x +
                skinMatrices[offset + 5] * vertex.y +
                skinMatrices[offset + 8] * vertex.z +
                skinMatrices[offset + 11]) *
            weight;
        total += weight;
      }
    }
    // A vertex with no usable influence keeps its bind position; collapsing it
    // to the origin would drag a spike across the model.
    if (total > 0) {
      // Back into the viewer's framing; see SkinBinding.normalizeCenter.
      out[v * 3] = (x / total - skin.normalizeCenter.x) * skin.normalizeScale;
      out[v * 3 + 1] =
          (y / total - skin.normalizeCenter.y) * skin.normalizeScale;
      out[v * 3 + 2] =
          (z / total - skin.normalizeCenter.z) * skin.normalizeScale;
    } else {
      out[v * 3] = vertex.x;
      out[v * 3 + 1] = vertex.y;
      out[v * 3 + 2] = vertex.z;
    }
  }
  return out;
}

/// Poses a character's vertices with one frame of a clip.
///
/// Convenience wrapper over [poseSkinnedPositions] for callers that want a
/// vertex list rather than a packed buffer; playback uses the buffer form.
List<Vec3> poseSkinnedVertices({
  required MeshModel character,
  required SkeletonAnimation clip,
  required int frame,
  RetargetPlan? plan,
}) {
  if (character.skin == null || frame < 0 || frame >= clip.frameCount) {
    return character.vertices;
  }
  final packed = poseSkinnedPositions(
    character: character,
    clip: clip,
    frame: frame,
    out: Float32List(character.vertices.length * 3),
    plan: plan,
    boneWorld: plan == null
        ? null
        : Float32List((character.skeleton?.bones.length ?? 0) * 12),
  );
  return [
    for (var v = 0; v < character.vertices.length; v += 1)
      Vec3(packed[v * 3], packed[v * 3 + 1], packed[v * 3 + 2]),
  ];
}

/// One bone of a rig: a name, and where it hangs.
class SkeletonBone {
  const SkeletonBone({
    required this.name,
    required this.parent,
    this.path = '',
  });

  final String name;

  /// The chain from the root, "Hips/Spine_01/Clavicle_L/...".
  ///
  /// Bone names repeat within a rig -- both hands carry a `Finger_03` -- so
  /// the path is the reliable key when joining two rigs.
  final String path;

  /// Index into the owning [SkeletonAnimation.bones], or -1 for a root.
  final int parent;
}

/// Strips the suffix the importer adds to distinguish same-named bones.
///
/// These rigs name both hands' bones identically -- `IndexFinger_01` appears
/// under `Hand_L` and `Hand_R` -- and ufbx renames whichever it meets second
/// to `IndexFinger_01_1`. Which one that is depends on node order, and node
/// order differs between a character file and a clip file: one file's
/// `Hand_R/IndexFinger_01_1` is the other's `Hand_R/IndexFinger_01`.
///
/// Only a single trailing digit is removed. Synty's own numbering is
/// two digits (`Spine_01`, `IndexFinger_02`), so it survives, while the
/// importer's `_1` does not. The parent chain still separates left from
/// right, which is the whole reason paths beat names here.
String normalizeBonePath(String path) {
  if (path.isEmpty) return path;
  return path
      .split('/')
      .map((segment) {
        final match = RegExp(r'^(.*[^_])_[0-9]$').firstMatch(segment);
        return match == null ? segment : match.group(1)!;
      })
      .join('/');
}

/// A rig and the motion sampled onto it.
///
/// Positions only, in world space, one sample per frame. That is everything a
/// stick-figure preview draws, and it means no curve evaluation or parent
/// composition happens in Dart -- ufbx did both when the file was imported.
class SkeletonAnimation {
  const SkeletonAnimation({
    required this.bones,
    required this.positions,
    required this.frameRate,
    this.rest,
  });

  /// Reads the `skeleton` object the importer emits. Null when absent.
  static SkeletonAnimation? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final boneList = (json['bones'] as List<dynamic>?) ?? const [];
    if (boneList.isEmpty) return null;

    final bones = [
      for (final entry in boneList)
        SkeletonBone(
          name: ((entry as Map<String, dynamic>)['name'] ?? '').toString(),
          parent: (entry['parent'] as num?)?.toInt() ?? -1,
          path: (entry['path'] ?? '').toString(),
        ),
    ];

    final frameList = (json['frames'] as List<dynamic>?) ?? const [];
    final stride = bones.length * ((json['stride'] as num?)?.toInt() ?? 12);
    final positions = <Float32List>[];
    for (final frame in frameList) {
      final values = frame as List<dynamic>;
      // A frame that does not match the bone count cannot be indexed safely.
      if (values.length != stride) continue;
      final packed = Float32List(stride);
      for (var i = 0; i < stride; i += 1) {
        packed[i] = (values[i] as num).toDouble();
      }
      positions.add(packed);
    }
    if (positions.isEmpty) return null;

    final restValues = (json['rest'] as List<dynamic>?) ?? const [];
    Float32List? rest;
    if (restValues.length == stride) {
      rest = Float32List(stride);
      for (var i = 0; i < stride; i += 1) {
        rest[i] = (restValues[i] as num).toDouble();
      }
    }

    return SkeletonAnimation(
      bones: bones,
      positions: positions,
      frameRate: (json['frameRate'] as num?)?.toDouble() ?? 30,
      rest: rest,
    );
  }

  final List<SkeletonBone> bones;

  /// One entry per frame, each `bones.length * 12` floats: a column-major
  /// 3x4 world matrix per bone. The last three are the bone's position, which
  /// is all the stick-figure view reads.
  final List<Float32List> positions;
  final double frameRate;

  /// The rig's own rest pose, unevaluated, as `bones.length * 12` floats.
  ///
  /// Two rigs can share every bone name and still hold those bones at
  /// different angles. Transferring a pose between them needs each rig's own
  /// rest as the reference, which is what this is.
  final Float32List? rest;

  int get frameCount => positions.length;

  /// The world position of one bone in one frame.
  ({double x, double y, double z}) bonePosition(int frame, int bone) {
    final values = positions[frame];
    final base = bone * 12;
    return (x: values[base + 9], y: values[base + 10], z: values[base + 11]);
  }

  /// The bone of this rig with the given name, or -1.
  ///
  /// Names are how a clip and a character are joined: Synty rigs share them
  /// exactly, so no mapping table is needed.
  int indexOfBone(String name, {String? path}) {
    if (path != null && path.isNotEmpty) {
      for (var i = 0; i < bones.length; i += 1) {
        if (bones[i].path == path) return i;
      }
      // The same rig can be numbered differently in two files, so compare
      // again with the importer's duplicate suffixes removed.
      final wanted = normalizeBonePath(path);
      for (var i = 0; i < bones.length; i += 1) {
        if (normalizeBonePath(bones[i].path) == wanted) return i;
      }
    }
    // Last resort. A bare name is ambiguous in these rigs -- both hands carry
    // an `IndexFinger_01` -- so this can pick the wrong side, and only runs
    // when neither path form matched.
    for (var i = 0; i < bones.length; i += 1) {
      if (bones[i].name == name) return i;
    }
    return -1;
  }

  /// The frame nearest a time in seconds, clamped to the clip.
  int frameAt(double seconds) {
    if (frameCount <= 1 || frameRate <= 0) return 0;
    final index = (seconds * frameRate).round();
    return index.clamp(0, frameCount - 1);
  }

  /// The axis-aligned bounds of every frame, so the view does not rescale as
  /// the clip plays.
  ({double minX, double maxX, double minY, double maxY}) get bounds {
    var minX = double.infinity;
    var maxX = -double.infinity;
    var minY = double.infinity;
    var maxY = -double.infinity;
    for (final frame in positions) {
      for (var i = 0; i + 11 < frame.length; i += 12) {
        minX = math.min(minX, frame[i + 9]);
        maxX = math.max(maxX, frame[i + 9]);
        minY = math.min(minY, frame[i + 10]);
        maxY = math.max(maxY, frame[i + 10]);
      }
    }
    if (!minX.isFinite) return (minX: 0, maxX: 1, minY: 0, maxY: 1);
    return (minX: minX, maxX: maxX, minY: minY, maxY: maxY);
  }
}

/// What an FBX turned out to contain. A file with a skeleton and curves but no
/// geometry is a legitimate asset, not an import failure.
enum FbxContentKind { mesh, animation }

class MeshModel {
  MeshModel({
    required this.name,
    required this.vertices,
    required this.faces,
    this.materials = const [],
    this.textureFiles = const [],
    this.vertexColors = const [],
    this.kind = FbxContentKind.mesh,
    this.animationStacks = 0,
    this.skeleton,
    this.skin,
    this.boneCount = 0,
    this.durationSeconds = 0,
    this.animationNames = const [],
  });

  /// True when the file carries animation or skeleton data and nothing to draw.
  bool get isAnimationOnly => kind == FbxContentKind.animation;

  factory MeshModel.normalized({
    required String name,
    required List<Vec3> vertices,
    required List<MeshFace> faces,
    List<Color> vertexColors = const [],
    List<MeshMaterial> materials = const [],
    List<String> textureFiles = const [],
  }) {
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    var maxZ = -double.infinity;
    for (final vertex in vertices) {
      minX = math.min(minX, vertex.x);
      minY = math.min(minY, vertex.y);
      minZ = math.min(minZ, vertex.z);
      maxX = math.max(maxX, vertex.x);
      maxY = math.max(maxY, vertex.y);
      maxZ = math.max(maxZ, vertex.z);
    }
    final center = Vec3(
      (minX + maxX) / 2,
      (minY + maxY) / 2,
      (minZ + maxZ) / 2,
    );
    final scale =
        2 /
        math.max(
          math.max(maxX - minX, maxY - minY),
          math.max(maxZ - minZ, .0001),
        );
    return MeshModel(
      name: name,
      vertices: vertices
          .map(
            (v) => Vec3(
              (v.x - center.x) * scale,
              (v.y - center.y) * scale,
              (v.z - center.z) * scale,
            ),
          )
          .toList(),
      faces: faces,
      vertexColors: vertexColors,
      materials: materials,
      textureFiles: textureFiles,
    );
  }

  /// The rig and its sampled motion, when the file carries one.
  final SkeletonAnimation? skeleton;

  /// How this mesh's vertices follow that rig, when it is skinned.
  final SkinBinding? skin;

  /// This mesh with different vertex positions. Everything else is shared,
  /// so posing a character per frame does not rebuild its materials.
  MeshModel withVertices(List<Vec3> replacements) => MeshModel(
    name: name,
    vertices: replacements,
    faces: faces,
    materials: materials,
    textureFiles: textureFiles,
    vertexColors: vertexColors,
    kind: kind,
    animationStacks: animationStacks,
    skeleton: skeleton,
    skin: skin,
    boneCount: boneCount,
    durationSeconds: durationSeconds,
    animationNames: animationNames,
  );

  /// This mesh with its materials replaced. Geometry is untouched.
  MeshModel withMaterials(List<MeshMaterial> replacements) => MeshModel(
    name: name,
    vertices: vertices,
    faces: faces,
    materials: replacements,
    textureFiles: textureFiles,
    vertexColors: vertexColors,
    kind: kind,
    animationStacks: animationStacks,
    skeleton: skeleton,
    skin: skin,
    boneCount: boneCount,
    durationSeconds: durationSeconds,
    animationNames: animationNames,
  );

  final String name;
  final List<Vec3> vertices;
  final List<MeshFace> faces;
  final List<MeshMaterial> materials;
  final List<String> textureFiles;
  final FbxContentKind kind;
  final int animationStacks;
  final int boneCount;
  final double durationSeconds;
  final List<String> animationNames;
  final List<Color> vertexColors;

  List<String> get availableUvSets {
    final names = <String>{};
    for (final face in faces) {
      names.addAll(face.uvSets.keys.where((name) => name.trim().isNotEmpty));
    }
    return names.toList()..sort();
  }

  Color colorForMaterial(int materialIndex, {bool textured = false}) {
    if (materialIndex >= 0 && materialIndex < materials.length) {
      final material = materials[materialIndex];
      final base = textured && material.textureColor != null
          ? material.textureColor!
          : material.color;

      final baseRed = (base.r * 255).round().clamp(0, 255);
      final baseGreen = (base.g * 255).round().clamp(0, 255);
      final baseBlue = (base.b * 255).round().clamp(0, 255);
      final emissiveRed = (material.emissiveColor.r * 255).round().clamp(
        0,
        255,
      );
      final emissiveGreen = (material.emissiveColor.g * 255).round().clamp(
        0,
        255,
      );
      final emissiveBlue = (material.emissiveColor.b * 255).round().clamp(
        0,
        255,
      );

      var brightness = 0.88 + material.specularFactor.clamp(0.0, 1.0) * 0.22;
      brightness *= 1.0 - material.metalness.clamp(0.0, 1.0) * 0.08;
      brightness *= 0.82 + (1.0 - material.roughness.clamp(0.0, 1.0)) * 0.18;
      final emissiveWeight = material.emissiveFactor.clamp(0.0, 8.0) * 0.3;

      final red = (baseRed * brightness + emissiveRed * emissiveWeight)
          .round()
          .clamp(0, 255);
      final green = (baseGreen * brightness + emissiveGreen * emissiveWeight)
          .round()
          .clamp(0, 255);
      final blue = (baseBlue * brightness + emissiveBlue * emissiveWeight)
          .round()
          .clamp(0, 255);

      return Color.fromARGB(
        (base.a * 255).round().clamp(0, 255),
        red,
        green,
        blue,
      );
    }
    return const Color(0xff8fb8d8);
  }

  double opacityForMaterial(int materialIndex) {
    if (materialIndex >= 0 && materialIndex < materials.length) {
      final opacity = materials[materialIndex].opacity.clamp(0.0, 1.0);
      // Some FBX exports still encode transparency in a way that collapses
      // to near-zero; avoid disappearing meshes.
      if (opacity <= 0.03) return 1.0;
      return opacity;
    }
    return 1.0;
  }

  List<String> get allTexturePaths {
    final paths = <String>{...textureFiles};
    for (final material in materials) {
      paths.addAll(material.textures);
      paths.addAll(material.resolvedTextures);
    }
    return paths.where((path) => path.trim().isNotEmpty).toList();
  }

  Color? averageFaceVertexColor(MeshFace face) {
    if (vertexColors.length != vertices.length) return null;
    if (face.indices.isEmpty) return null;
    var red = 0;
    var green = 0;
    var blue = 0;
    var alpha = 0;
    var count = 0;
    for (final index in face.indices) {
      if (index < 0 || index >= vertexColors.length) continue;
      final color = vertexColors[index];
      red += (color.r * 255).round().clamp(0, 255);
      green += (color.g * 255).round().clamp(0, 255);
      blue += (color.b * 255).round().clamp(0, 255);
      alpha += (color.a * 255).round().clamp(0, 255);
      count += 1;
    }
    if (count == 0) return null;
    return Color.fromARGB(
      (alpha / count).round(),
      (red / count).round(),
      (green / count).round(),
      (blue / count).round(),
    );
  }
}

class MeshMaterial {
  const MeshMaterial({
    required this.name,
    required this.color,
    required this.textures,
    this.resolvedTextures = const [],
    this.textureColor,
    this.textureImage,
    this.texturePixels,
    this.textureWidth = 0,
    this.textureHeight = 0,
    this.normalTexture = '',
    this.normalPixels,
    this.normalWidth = 0,
    this.normalHeight = 0,
    this.emissiveTexture = '',
    this.emissivePixels,
    this.emissiveWidth = 0,
    this.emissiveHeight = 0,
    this.opacity = 1.0,
    this.roughness = 0.7,
    this.metalness = 0.0,
    this.specularFactor = 0.2,
    this.emissiveFactor = 0.0,
    this.emissiveColor = const Color(0xff000000),
    this.shaderType = -1,
    this.shadingModel = '',
    this.uvSet = '',
    this.hasEmbeddedTexture = false,
  });

  /// This material with a different base texture, everything else kept.
  ///
  /// Used when the user picks a texture by hand: a model whose materials name
  /// nothing (an OBJ with no `mtllib`) or name a file that is not in the
  /// library still has UVs, so a chosen atlas maps onto it correctly.
  MeshMaterial withBaseTexture({
    required String path,
    required ui.Image image,
    required Uint8List? pixels,
  }) {
    return MeshMaterial(
      name: name,
      color: color,
      textures: textures,
      resolvedTextures: [path],
      textureColor: textureColor,
      textureImage: image,
      texturePixels: pixels,
      textureWidth: image.width,
      textureHeight: image.height,
      normalTexture: normalTexture,
      normalPixels: normalPixels,
      normalWidth: normalWidth,
      normalHeight: normalHeight,
      emissiveTexture: emissiveTexture,
      emissivePixels: emissivePixels,
      emissiveWidth: emissiveWidth,
      emissiveHeight: emissiveHeight,
      opacity: opacity,
      roughness: roughness,
      metalness: metalness,
      specularFactor: specularFactor,
      emissiveFactor: emissiveFactor,
      emissiveColor: emissiveColor,
      shaderType: shaderType,
      shadingModel: shadingModel,
      uvSet: uvSet,
      hasEmbeddedTexture: hasEmbeddedTexture,
    );
  }

  final String name;
  final Color color;
  final List<String> textures;
  final List<String> resolvedTextures;
  final Color? textureColor;
  final ui.Image? textureImage;

  /// Raw RGBA of [textureImage], kept so a single texel can be read without
  /// going through the GPU. Synty-style models map a whole face to one texel,
  /// and those faces are drawn as a flat fill rather than a texture draw.
  final Uint8List? texturePixels;
  final int textureWidth;
  final int textureHeight;

  /// The normal map this material asked for, and its pixels once resolved.
  final String normalTexture;
  final Uint8List? normalPixels;
  final int normalWidth;
  final int normalHeight;

  bool get hasNormalMap => normalPixels != null && normalWidth > 0;

  /// Emissive map: light the material gives off, added after shading.
  final String emissiveTexture;
  final Uint8List? emissivePixels;
  final int emissiveWidth;
  final int emissiveHeight;

  bool get hasEmissiveMap => emissivePixels != null && emissiveWidth > 0;

  /// True when the material named textures and none of them could be found.
  /// Such a model renders as flat base colour, which reads as broken rather
  /// than as "the textures are elsewhere".
  bool get texturesMissing => textures.isNotEmpty && resolvedTextures.isEmpty;

  /// Emissive texel at (u, v) packed 0xRRGGBB, or null.
  int? sampleEmissiveRgb(double u, double v) {
    final pixels = emissivePixels;
    if (pixels == null || emissiveWidth <= 0 || emissiveHeight <= 0) {
      return null;
    }
    var fu = u - u.floorToDouble();
    var fv = v - v.floorToDouble();
    if (fu < 0) fu += 1;
    if (fv < 0) fv += 1;
    final x = (fu * (emissiveWidth - 1)).toInt();
    final y = (fv * (emissiveHeight - 1)).toInt();
    final index = (y * emissiveWidth + x) * 4;
    if (index + 2 >= pixels.length) return null;
    return (pixels[index] << 16) | (pixels[index + 1] << 8) | pixels[index + 2];
  }

  /// Tangent-space normal at [uv], decoded from the usual RGB encoding where
  /// (0.5, 0.5, 1.0) means "straight out of the surface".
  Vec3? sampleNormal(Vec2 uv) {
    final pixels = normalPixels;
    if (pixels == null || normalWidth <= 0 || normalHeight <= 0) return null;
    double wrap(double value) {
      final fraction = value - value.floorToDouble();
      return fraction < 0 ? fraction + 1 : fraction;
    }

    final x = (wrap(uv.x) * (normalWidth - 1)).round().clamp(
      0,
      normalWidth - 1,
    );
    final y = (wrap(uv.y) * (normalHeight - 1)).round().clamp(
      0,
      normalHeight - 1,
    );
    final index = (y * normalWidth + x) * 4;
    if (index + 2 >= pixels.length) return null;
    return Vec3(
      pixels[index] / 127.5 - 1.0,
      pixels[index + 1] / 127.5 - 1.0,
      pixels[index + 2] / 127.5 - 1.0,
    );
  }

  /// Texel at (u, v) packed as 0xRRGGBB, or null when there is nothing to
  /// sample. Used by the rasteriser's inner loop, where allocating a [Color]
  /// per pixel would cost more than the shading.
  int? sampleTextureRgb(double u, double v) {
    final pixels = texturePixels;
    if (pixels == null || textureWidth <= 0 || textureHeight <= 0) return null;
    var fu = u - u.floorToDouble();
    var fv = v - v.floorToDouble();
    if (fu < 0) fu += 1;
    if (fv < 0) fv += 1;
    var x = (fu * (textureWidth - 1)).round();
    var y = (fv * (textureHeight - 1)).round();
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > textureWidth - 1) x = textureWidth - 1;
    if (y > textureHeight - 1) y = textureHeight - 1;
    final index = (y * textureWidth + x) * 4;
    if (index + 2 >= pixels.length) return null;
    return (pixels[index] << 16) | (pixels[index + 1] << 8) | pixels[index + 2];
  }

  /// The colour at [uv], or null when there is nothing to sample.
  Color? sampleTexture(Vec2 uv) {
    final pixels = texturePixels;
    if (pixels == null || textureWidth <= 0 || textureHeight <= 0) return null;
    // UVs outside 0..1 wrap, which is what a tiling material expects.
    double wrap(double value) {
      final fraction = value - value.floorToDouble();
      return fraction < 0 ? fraction + 1 : fraction;
    }

    final x = (wrap(uv.x) * (textureWidth - 1)).round().clamp(
      0,
      textureWidth - 1,
    );
    final y = (wrap(uv.y) * (textureHeight - 1)).round().clamp(
      0,
      textureHeight - 1,
    );
    final index = (y * textureWidth + x) * 4;
    if (index + 3 >= pixels.length) return null;
    return Color.fromARGB(
      pixels[index + 3],
      pixels[index],
      pixels[index + 1],
      pixels[index + 2],
    );
  }

  final double opacity;
  final double roughness;
  final double metalness;
  final double specularFactor;
  final double emissiveFactor;
  final Color emissiveColor;
  final int shaderType;
  final String shadingModel;
  final String uvSet;
  final bool hasEmbeddedTexture;
}

class MeshFace {
  const MeshFace(
    this.indices, [
    this.materialIndex = 0,
    this.uvs = const [],
    this.uvSets = const {},
  ]);
  final List<int> indices;
  final int materialIndex;
  final List<Vec2> uvs;
  final Map<String, List<Vec2>> uvSets;

  List<Vec2> uvsFor(String? requestedSet) {
    final name = requestedSet?.trim() ?? '';
    if (name.isNotEmpty) {
      final selected = uvSets[name];
      if (selected != null && selected.length == 3) return selected;
    }
    if (uvs.length == 3) return uvs;
    for (final candidate in uvSets.values) {
      if (candidate.length == 3) return candidate;
    }
    return const [];
  }
}

class Vec2 {
  const Vec2(this.x, this.y);
  final double x;
  final double y;
}

class Vec3 {
  const Vec3(this.x, this.y, this.z);
  final double x;
  final double y;
  final double z;
}

class AssetItem {
  AssetItem({
    required this.id,
    required this.name,
    required this.path,
    required this.relativePath,
    required this.sourceRoot,
    required this.sourceName,
    required this.ext,
    required this.type,
    required this.size,
    required this.modified,
    required this.tags,
    this.ignored = false,
    this.modelKind,
    this.referencedByModel = false,
  });

  final String id;
  final String name;
  final String path;
  final String relativePath;
  final String sourceRoot;
  final String sourceName;
  final String ext;
  final String type;
  final int size;
  final DateTime modified;
  final List<String> tags;
  bool ignored;

  /// For model assets: what the file actually turned out to contain, once
  /// something has looked. Null means not classified yet -- classifying an FBX
  /// costs an importer run, so it happens lazily and is persisted.
  String? modelKind;

  /// Set once some model has been read and found to use this image. Persisted,
  /// because it is only learned by importing a model.
  bool referencedByModel;

  /// The type to show and filter by. An FBX holding only a skeleton and curves
  /// is an animation, not a model, but only a parse can tell you that.
  String get effectiveType {
    if (modelKind == 'animation') return 'animation';
    if (type == 'image' &&
        (referencedByModel || looksLikeTextureLocation(relativePath))) {
      return 'texture';
    }
    return type;
  }

  String? _searchText;

  /// Name, path and tags folded to lowercase once, on first use. Search
  /// used to lowercase all three for every asset on every keystroke.
  String get searchText => _searchText ??=
      '$name\u0000$relativePath\u0000${tags.join(' ')}'.toLowerCase();
}

class ScanResult {
  const ScanResult({
    required this.assets,
    required this.skippedUnsupported,
    required this.skippedBinaryObj,
  });

  final List<AssetItem> assets;
  final int skippedUnsupported;
  final int skippedBinaryObj;
}

class ScanStatus {
  const ScanStatus(this.label, this.detail);

  final String label;
  final String detail;
}

class PersistedCatalog {
  const PersistedCatalog({required this.assets, required this.sourceRoots});

  final List<AssetItem> assets;
  final Set<String> sourceRoots;
}

class AssetAtlasDatabase {
  AssetAtlasDatabase._();

  static final instance = AssetAtlasDatabase._();
  Database? _db;

  /// Schema history:
  ///   v1 - initial catalog, sources, projects, membership
  ///   v2 - indexes on the columns the app filters and joins by
  ///   v3 - asset ids rebuilt from source root + relative path, so editing a
  ///        file no longer orphans it from projects and ignore flags
  ///   v4 - model_kind, cached FBX classification (mesh vs animation-only)
  ///   v5 - referenced_by_model, images a model was found to use
  static const schemaVersion = 6;

  /// Indexes are created identically by [_createSchema] and by the v2 upgrade
  /// so a fresh install and an upgraded install converge; see
  /// test/database_test.dart, which asserts they match.
  static const _indexStatements = [
    'CREATE INDEX IF NOT EXISTS idx_catalog_assets_source_root '
        'ON catalog_assets(source_root)',
    'CREATE INDEX IF NOT EXISTS idx_catalog_assets_type '
        'ON catalog_assets(type)',
    'CREATE INDEX IF NOT EXISTS idx_project_assets_project '
        'ON project_assets(project_id)',
  ];

  /// [databasePath] is a test seam; production passes nothing and the database
  /// lives in the app support directory.
  Future<void> initialize({String? databasePath}) async {
    if (_db != null) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final String dbPath;
    if (databasePath != null) {
      dbPath = databasePath;
    } else {
      final supportDir = await getApplicationSupportDirectory();
      dbPath =
          '${supportDir.path}${Platform.pathSeparator}asset_atlas_native.db';
    }
    _db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            for (final statement in _indexStatements) {
              await db.execute(statement);
            }
          }
          if (oldVersion < 3) {
            await _migrateAssetIdsToV3(db);
          }
          if (oldVersion < 4) {
            await db.execute(
              'ALTER TABLE catalog_assets ADD COLUMN model_kind TEXT',
            );
          }
          if (oldVersion < 5) {
            await db.execute(
              'ALTER TABLE catalog_assets '
              'ADD COLUMN referenced_by_model INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (oldVersion < 6) {
            await db.execute('''
            CREATE TABLE settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
            ''');
          }
        },
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE catalog_assets (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              path TEXT NOT NULL,
              relative_path TEXT NOT NULL,
              source_root TEXT NOT NULL,
              source_name TEXT NOT NULL,
              ext TEXT NOT NULL,
              type TEXT NOT NULL,
              size INTEGER NOT NULL,
              modified_ms INTEGER NOT NULL,
              tags_json TEXT NOT NULL,
              ignored INTEGER NOT NULL DEFAULT 0,
              model_kind TEXT,
              referenced_by_model INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('''
            CREATE TABLE catalog_sources (
              root_path TEXT PRIMARY KEY
            )
          ''');
          await db.execute('''
            CREATE TABLE projects (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              root_path TEXT,
              created_ms INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE project_assets (
              project_id TEXT NOT NULL,
              asset_id TEXT NOT NULL,
              PRIMARY KEY (project_id, asset_id)
            )
          ''');
          await db.execute('''
            CREATE TABLE settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
          for (final statement in _indexStatements) {
            await db.execute(statement);
          }
        },
      ),
    );
  }

  /// Reads one setting, or null when it was never written.
  Future<String?> readSetting(String key) async {
    await initialize();
    final rows = await _db!.query(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// Writes one setting. A null value clears it.
  Future<void> writeSetting(String key, String? value) async {
    await initialize();
    if (value == null) {
      await _db!.delete('settings', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await _db!.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<PersistedCatalog> loadCatalog() async {
    await initialize();
    final db = _db!;
    final rows = await db.query('catalog_assets');
    final sourceRows = await db.query('catalog_sources');
    final assets = rows.map((row) {
      return AssetItem(
        id: row['id'] as String,
        name: row['name'] as String,
        path: row['path'] as String,
        relativePath: row['relative_path'] as String,
        sourceRoot: row['source_root'] as String,
        sourceName: row['source_name'] as String,
        ext: row['ext'] as String,
        type: row['type'] as String,
        size: row['size'] as int,
        modified: DateTime.fromMillisecondsSinceEpoch(
          row['modified_ms'] as int,
        ),
        tags: ((jsonDecode(row['tags_json'] as String) as List<dynamic>)
            .cast<String>()),
        ignored: (row['ignored'] as int) == 1,
        modelKind: row['model_kind'] as String?,
        referencedByModel: (row['referenced_by_model'] as int? ?? 0) == 1,
      );
    }).toList();
    final sourceRoots = sourceRows
        .map((row) => row['root_path'] as String)
        .toSet();

    // Catalogs scanned before AppleDouble filtering existed still hold these
    // sidecars, and one of them crashed the audio plugin. Drop them here too
    // rather than waiting for a full re-scan.
    final stale = assets
        .where(
          (asset) =>
              isAppleDoubleName(asset.name) ||
              asset.relativePath.toLowerCase().contains('__macosx/'),
        )
        .toList();
    if (stale.isNotEmpty) {
      assets.removeWhere(stale.contains);
      unawaited(
        deleteAssetsByIds([for (final asset in stale) asset.id]).catchError((
          Object error,
        ) {
          fbxLog('Could not drop AppleDouble rows: $error');
        }),
      );
      fbxLog('Dropped ${stale.length} AppleDouble entries from the catalog.');
    }

    return PersistedCatalog(assets: assets, sourceRoots: sourceRoots);
  }

  /// Rebuilds every asset id in the content-independent v2 format and
  /// remaps project membership onto the new ids.
  ///
  /// Runs inside sqflite's upgrade transaction, so catalog_assets and
  /// project_assets cannot end up disagreeing: either both are rewritten or
  /// neither is. Membership rows whose asset is already gone are dropped and
  /// counted rather than left dangling.
  static Future<void> _migrateAssetIdsToV3(Database db) async {
    final rows = await db.query(
      'catalog_assets',
      columns: ['id', 'source_root', 'source_name', 'relative_path'],
    );

    final newIdByOldId = <String, String>{};
    final claimedNewIds = <String>{};
    var droppedDuplicates = 0;

    for (final row in rows) {
      final oldId = row['id'] as String;
      final newId = buildAssetId(
        sourceRoot: row['source_root'] as String,
        relativePath: assetIdRelativePathFromStored(
          relativePath: row['relative_path'] as String,
          sourceName: row['source_name'] as String,
        ),
      );
      if (!claimedNewIds.add(newId)) {
        // Two rows describing the same place: keep the first, drop the rest.
        await db.delete('catalog_assets', where: 'id = ?', whereArgs: [oldId]);
        droppedDuplicates += 1;
        continue;
      }
      newIdByOldId[oldId] = newId;
    }

    // Batched: a real catalog is tens of thousands of rows, and one statement
    // per row turned this into a visible freeze on first launch.
    final updates = db.batch();
    for (final entry in newIdByOldId.entries) {
      if (entry.key == entry.value) continue;
      updates.rawUpdate('UPDATE catalog_assets SET id = ? WHERE id = ?', [
        entry.value,
        entry.key,
      ]);
    }
    await updates.commit(noResult: true);

    final membership = await db.query('project_assets');
    await db.delete('project_assets');
    var droppedMembership = 0;
    final inserts = db.batch();
    for (final row in membership) {
      final mapped = newIdByOldId[row['asset_id'] as String];
      if (mapped == null) {
        droppedMembership += 1;
        continue;
      }
      inserts.insert('project_assets', {
        'project_id': row['project_id'],
        'asset_id': mapped,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await inserts.commit(noResult: true);

    fbxLog(
      'Migrated ${newIdByOldId.length} asset ids to v3 '
      '(dropped $droppedDuplicates duplicate assets, '
      '$droppedMembership orphaned membership rows).',
    );
  }

  /// Releases the handle so a later [initialize] can open a different file.
  /// Used by tests, which each need their own database.
  Future<void> close() async {
    final db = _db;
    _db = null;
    await db?.close();
  }

  Map<String, Object?> _rowFor(AssetItem asset) => {
    'id': asset.id,
    'name': asset.name,
    'path': asset.path,
    'relative_path': asset.relativePath,
    'source_root': asset.sourceRoot,
    'source_name': asset.sourceName,
    'ext': asset.ext,
    'type': asset.type,
    'size': asset.size,
    'modified_ms': asset.modified.millisecondsSinceEpoch,
    'tags_json': jsonEncode(asset.tags),
    'ignored': asset.ignored ? 1 : 0,
    'model_kind': asset.modelKind,
    'referenced_by_model': asset.referencedByModel ? 1 : 0,
  };

  /// Full replace. Only correct after a scan, where the catalog really did
  /// change wholesale - never for a single-field edit.
  Future<void> saveCatalog({
    required List<AssetItem> assets,
    required List<String> sourceRoots,
  }) async {
    await initialize();
    final db = _db!;
    await db.transaction((txn) async {
      await txn.delete('catalog_assets');
      await txn.delete('catalog_sources');
      final batch = txn.batch();
      for (final rootPath in sourceRoots) {
        batch.insert('catalog_sources', {'root_path': rootPath});
      }
      for (final asset in assets) {
        batch.insert(
          'catalog_assets',
          _rowFor(asset),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      // noResult: collecting per-row results for a 100k-row catalog allocates
      // a list nobody reads.
      await batch.commit(noResult: true);
    });
  }

  /// One row, one statement. Toggling an ignore flag used to delete and
  /// reinsert the entire catalog.
  Future<void> updateAssetIgnored({
    required String assetId,
    required bool ignored,
  }) async {
    await initialize();
    await _db!.update(
      'catalog_assets',
      {'ignored': ignored ? 1 : 0},
      where: 'id = ?',
      whereArgs: [assetId],
    );
  }

  Future<void> updateAssetModelKind({
    required String assetId,
    required String modelKind,
  }) async {
    await initialize();
    await _db!.update(
      'catalog_assets',
      {'model_kind': modelKind},
      where: 'id = ?',
      whereArgs: [assetId],
    );
  }

  /// Writes a chunk of classifications in one transaction. Doing this per
  /// asset meant tens of thousands of separate writes.
  Future<void> updateAssetModelKinds(Map<String, String> kindByAssetId) async {
    if (kindByAssetId.isEmpty) return;
    await initialize();
    await _db!.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in kindByAssetId.entries) {
        batch.update(
          'catalog_assets',
          {'model_kind': entry.value},
          where: 'id = ?',
          whereArgs: [entry.key],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Records that a model uses these images, so they read as textures rather
  /// than as ordinary pictures.
  Future<void> markAssetsReferencedByModel(List<String> assetIds) async {
    if (assetIds.isEmpty) return;
    await initialize();
    await _db!.transaction((txn) async {
      final batch = txn.batch();
      for (final id in assetIds) {
        batch.update(
          'catalog_assets',
          {'referenced_by_model': 1},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> deleteAssetsByIds(List<String> assetIds) async {
    if (assetIds.isEmpty) return;
    await initialize();
    await _db!.transaction((txn) async {
      final batch = txn.batch();
      for (final id in assetIds) {
        batch.delete('catalog_assets', where: 'id = ?', whereArgs: [id]);
        batch.delete('project_assets', where: 'asset_id = ?', whereArgs: [id]);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> upsertAssets(List<AssetItem> assets) async {
    if (assets.isEmpty) return;
    await initialize();
    await _db!.transaction((txn) async {
      final batch = txn.batch();
      for (final asset in assets) {
        batch.insert(
          'catalog_assets',
          _rowFor(asset),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> deleteAssetsForSourceRoot(String rootPath) async {
    await initialize();
    await _db!.transaction((txn) async {
      await txn.delete(
        'catalog_assets',
        where: 'source_root = ?',
        whereArgs: [rootPath],
      );
      await txn.delete(
        'catalog_sources',
        where: 'root_path = ?',
        whereArgs: [rootPath],
      );
    });
  }

  Future<void> replaceSourceRoots(List<String> rootPaths) async {
    await initialize();
    await _db!.transaction((txn) async {
      await txn.delete('catalog_sources');
      final batch = txn.batch();
      for (final rootPath in rootPaths) {
        batch.insert('catalog_sources', {'root_path': rootPath});
      }
      await batch.commit(noResult: true);
    });
  }

  Future<String> saveProject({
    required String name,
    required String? rootPath,
    required int createdMs,
  }) async {
    await initialize();
    final db = _db!;
    final projectId = '${DateTime.now().millisecondsSinceEpoch}-$name';
    await db.insert('projects', {
      'id': projectId,
      'name': name,
      'root_path': rootPath,
      'created_ms': createdMs,
    });
    return projectId;
  }

  Future<PersistedProject?> findProjectByName(String name) async {
    await initialize();
    final db = _db!;
    final rows = await db.query(
      'projects',
      where: 'LOWER(name) = LOWER(?)',
      whereArgs: [name],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return PersistedProject(
      id: row['id'] as String,
      name: row['name'] as String,
      rootPath: row['root_path'] as String?,
      createdMs: row['created_ms'] as int,
    );
  }

  Future<List<PersistedProject>> listProjects() async {
    await initialize();
    final db = _db!;
    final rows = await db.query('projects', orderBy: 'created_ms DESC');
    return rows
        .map(
          (row) => PersistedProject(
            id: row['id'] as String,
            name: row['name'] as String,
            rootPath: row['root_path'] as String?,
            createdMs: row['created_ms'] as int,
          ),
        )
        .toList();
  }

  Future<Set<String>> loadProjectAssetIds(String projectId) async {
    await initialize();
    final db = _db!;
    final rows = await db.query(
      'project_assets',
      columns: ['asset_id'],
      where: 'project_id = ?',
      whereArgs: [projectId],
    );
    return rows.map((row) => row['asset_id'] as String).toSet();
  }

  Future<void> replaceProjectAssetIds({
    required String projectId,
    required List<String> assetIds,
  }) async {
    await initialize();
    final db = _db!;
    await db.transaction((txn) async {
      await txn.delete(
        'project_assets',
        where: 'project_id = ?',
        whereArgs: [projectId],
      );
      for (final assetId in assetIds.toSet()) {
        await txn.insert('project_assets', {
          'project_id': projectId,
          'asset_id': assetId,
        });
      }
    });
  }

  Future<void> updateProject({
    required String projectId,
    required String name,
    required String? rootPath,
  }) async {
    await initialize();
    final db = _db!;
    await db.update(
      'projects',
      {'name': name, 'root_path': rootPath},
      where: 'id = ?',
      whereArgs: [projectId],
    );
  }

  Future<void> deleteProject(String projectId) async {
    await initialize();
    final db = _db!;
    await db.transaction((txn) async {
      await txn.delete(
        'project_assets',
        where: 'project_id = ?',
        whereArgs: [projectId],
      );
      await txn.delete('projects', where: 'id = ?', whereArgs: [projectId]);
    });
  }
}

enum _ProjectDialogAction { load, rename, delete }

class _ProjectDialogResult {
  const _ProjectDialogResult({required this.action, required this.project});

  final _ProjectDialogAction action;
  final PersistedProject project;
}

class PersistedProject {
  const PersistedProject({
    required this.id,
    required this.name,
    required this.rootPath,
    required this.createdMs,
  });

  final String id;
  final String name;
  final String? rootPath;
  final int createdMs;
}

