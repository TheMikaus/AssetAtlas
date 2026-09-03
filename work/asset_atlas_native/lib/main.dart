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
const appVersion = '1.9.0';
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
                      onTypeChanged: (value) =>
                          setState(() => typeFilter = value),
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

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  MeshPainter(
    mesh: mesh,
    yaw: -0.6,
    pitch: 0.35,
    zoom: 1,
    renderMode: RenderMode.textured,
    lightingMode: LightingMode.corner,
    cullBackFaces: true,
  ).paint(canvas, Size(size.toDouble(), size.toDouble()));
  return recorder.endRecording().toImage(size, size);
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
  bool useNormalMaps = true;

  Future<MeshModel> _loadCurrentMesh() {
    return MeshLoadCache.load(
      widget.asset,
      allAssets: widget.allAssets,
      fallbackCheckerSquareSize: checkerSquareSize,
    );
  }

  @override
  void initState() {
    super.initState();
    meshFuture = _loadCurrentMesh();
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
              return AnimationClipPreview(mesh: mesh);
            }
            return Stack(
              children: [
                Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
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
                      setState(() {
                        yaw += details.delta.dx * .01;
                        pitch = (pitch + details.delta.dy * .01)
                            .clamp(-1.45, 1.45)
                            .toDouble();
                      });
                    },
                    child: CustomPaint(
                      painter: MeshPainter(
                        mesh: mesh,
                        yaw: yaw,
                        pitch: pitch,
                        zoom: zoom,
                        renderMode: renderMode,
                        uvSetOverride: uvSetOverride,
                        lightingMode: lightingMode,
                        cullBackFaces: cullBackFaces,
                        useNormalMaps: useNormalMaps,
                      ),
                      child: Align(
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
                    ),
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
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
                      const SizedBox(height: 8),
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
                      const SizedBox(height: 8),
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
                      const SizedBox(height: 8),
                      // Only shown when there is a normal map to apply: an
                      // inert control invites the question "why is nothing
                      // happening".
                      if (mesh.materials.any(
                        (material) => material.hasNormalMap,
                      )) ...[
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
                              const Text('Normal map'),
                              Switch(
                                value: useNormalMaps,
                                onChanged: (next) =>
                                    setState(() => useNormalMaps = next),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
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
                        const SizedBox(height: 8),
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
                                  if (next == null ||
                                      next == checkerSquareSize) {
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
class AnimationClipPreview extends StatelessWidget {
  const AnimationClipPreview({required this.mesh, super.key});

  final MeshModel mesh;

  String get _duration {
    if (mesh.durationSeconds <= 0) return 'unknown';
    return '${mesh.durationSeconds.toStringAsFixed(2)}s';
  }

  @override
  Widget build(BuildContext context) {
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
      value.replaceAllMapped(
        RegExp(r'[\\/]'),
        (match) => '${match[0]}\u200b',
      );

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
    super.key,
  });

  final String label;
  final String value;

  /// Render the value as a hoverable, copyable path.
  final bool isPath;

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
          Expanded(child: isPath ? CopyablePathText(path: value) : Text(value)),
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
    if (widget.asset.ext != 'fbx') return null;
    return MeshLoadCache.load(widget.asset, allAssets: widget.allAssets);
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final allAssets = widget.allAssets;
    final onActivateAsset = widget.onActivateAsset;
    final nearby = findNearbyTextures(asset, allAssets);
    if (asset.ext == 'fbx') {
      return FutureBuilder<MeshModel>(
        future: meshFuture,
        builder: (context, meshSnapshot) => FutureBuilder<
          List<TextureDiscoveryEntry>
        >(
        future: referencesFuture,
        builder: (context, snapshot) {
          final referenced = snapshot.data ?? const <TextureDiscoveryEntry>[];
          final pathKeys = referenced
              .where((entry) => entry.copyPath.isNotEmpty)
              .map((entry) => normalizePathKey(entry.copyPath))
              .toSet();
          final nearbyEntries = nearby
              .where(
                (texture) => !pathKeys.contains(normalizePathKey(texture.path)),
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
                : '${referenced.length} FBX references · ${nearby.length} nearby scanned candidates.',
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

/// One material, with its resolved texture shown rather than described.
///
/// "Is this model textured?" is a question a swatch answers instantly, and a
/// list of paths does not: a model can resolve its atlas correctly and still
/// look grey, because that is the part of the atlas it uses.
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
                  image != null
                      ? 'textured ${image.width}x${image.height}'
                          '${material.hasEmbeddedTexture ? " (embedded)" : ""}'
                      : 'flat colour, no texture',
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
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
              _isDeliberatelyUntextured
                  ? 'This model has no textures: its material is a flat '
                        'colour. Collision hulls and blockout meshes normally '
                        'look like this.'
                  : message,
              style: const TextStyle(color: Colors.black54),
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
                        child: Text(
                          entry.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: entry.jumpAsset == null
                                ? Colors.black87
                                : Theme.of(context).colorScheme.primary,
                            decoration: entry.jumpAsset == null
                                ? TextDecoration.none
                                : TextDecoration.underline,
                          ),
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
  if (asset.ext != 'fbx') return const [];
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

String? findDeterministicTextureRelink(
  String modelPath,
  String texturePath,
  List<AssetItem> allAssets,
) {
  if (allAssets.isEmpty) return null;
  final modelPathLower = modelPath.toLowerCase().replaceAll('\\', '/');
  final zipModel = parseZipVirtualPath(modelPath);
  final sourceCandidates = allAssets.where((asset) {
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
  }).toList();
  if (sourceCandidates.isEmpty) return null;

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

    final dirLower = parentPath(asset.path).toLowerCase().replaceAll('\\', '/');
    if (dirLower.contains('/textures')) value += 20;

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

  final best = scored.first;
  if (best.score < 80) return null;
  return best.asset.path;
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

MeshModel parseObjMesh(String text, String name) {
  final vertices = <Vec3>[];
  final faces = <MeshFace>[];
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
    } else if (line.startsWith('f ')) {
      final indices = <int>[];
      for (final token in line.substring(2).trim().split(RegExp(r'\s+'))) {
        final rawIndex = int.tryParse(token.split('/').first);
        if (rawIndex == null) continue;
        indices.add(rawIndex < 0 ? vertices.length + rawIndex : rawIndex - 1);
      }
      _addTriangulatedFace(indices, faces);
    }
  }
  if (vertices.isEmpty || faces.isEmpty) {
    throw const FormatException('No OBJ geometry found.');
  }
  return MeshModel.normalized(name: name, vertices: vertices, faces: faces);
}

void _addTriangulatedFace(List<int> indices, List<MeshFace> faces) {
  final clean = indices.where((index) => index >= 0).toList();
  if (clean.length < 3) return;
  for (var i = 1; i < clean.length - 1; i += 1) {
    faces.add(MeshFace([clean[0], clean[i], clean[i + 1]]));
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
    );
  }

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
  String get searchText =>
      _searchText ??=
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
  static const schemaVersion = 5;

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
          for (final statement in _indexStatements) {
            await db.execute(statement);
          }
        },
      ),
    );
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
        batch.delete(
          'project_assets',
          where: 'asset_id = ?',
          whereArgs: [id],
        );
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








