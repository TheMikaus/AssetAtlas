import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
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
const enableFbxLogs = true;
String fbxLogFilePath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}asset_atlas_fbx.log';
const ignoredFolderNames = {
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
  String? activeProjectName;
  bool loadingPersisted = true;
  String query = '';
  String typeFilter = 'all';
  String modelTextureFilter = 'all';
  bool hideIgnored = true;
  bool scanning = false;
  double assetListHeight = 280;
  ScanStatus status = const ScanStatus('Ready', 'Choose a folder to catalog.');
  final modelHasValidTextures = <String, bool>{};
  final _modelValidationInFlight = <String>{};
  final Queue<AssetItem> _modelValidationQueue = Queue<AssetItem>();
  bool _processingModelValidationQueue = false;
  final List<String> _assetHistory = <String>[];
  int _assetHistoryIndex = -1;

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

  List<AssetItem> get filteredAssets {
    final lower = query.trim().toLowerCase();
    return assets.where((asset) {
      if (hideIgnored && asset.ignored) return false;
      if (typeFilter != 'all' && asset.type != typeFilter) return false;
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
      return asset.name.toLowerCase().contains(lower) ||
          asset.relativePath.toLowerCase().contains(lower) ||
          asset.tags.any((tag) => tag.contains(lower));
    }).toList()..sort((a, b) => a.relativePath.compareTo(b.relativePath));
  }

  void _scheduleModelTextureValidation([Iterable<AssetItem>? subset]) {
    if (modelTextureFilter == 'all') return;
    final models = (subset ?? assets).where((asset) => asset.type == 'model');
    for (final asset in models) {
      if (modelHasValidTextures.containsKey(asset.id)) continue;
      if (_modelValidationInFlight.contains(asset.id)) continue;
      _modelValidationInFlight.add(asset.id);
      _modelValidationQueue.add(asset);
    }
    unawaited(_processModelValidationQueue());
  }

  Future<void> _processModelValidationQueue() async {
    if (_processingModelValidationQueue) return;
    _processingModelValidationQueue = true;
    while (_modelValidationQueue.isNotEmpty) {
      final asset = _modelValidationQueue.removeFirst();
      await _validateModelTexture(asset);
    }
    _processingModelValidationQueue = false;
  }

  Future<void> _validateModelTexture(AssetItem asset) async {
    var hasValidTexture = false;
    try {
      if (asset.ext == 'fbx') {
        final refs = await loadModelTextureReferences(asset, assets);
        hasValidTexture = refs.any((value) => value.contains('(found)'));
      } else {
        hasValidTexture = findNearbyTextures(asset, assets).isNotEmpty;
      }
    } catch (_) {
      hasValidTexture = false;
    }

    if (mounted) {
      setState(() {
        modelHasValidTextures[asset.id] = hasValidTexture;
      });
    }
    _modelValidationInFlight.remove(asset.id);
  }

  @override
  void dispose() {
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
    final projectId = await db.saveProject(
      name: projectName,
      rootPath: sourceRoots.isEmpty ? null : sourceRoots.first,
      assetIds: selectedIds.toList(),
    );
    if (!mounted) return;
    setState(() {
      activeProjectName = projectName;
      status = ScanStatus(
        'Project saved',
        '$projectName (${selectedIds.length} selected assets, id $projectId)',
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

    final projects = await db.listProjects();
    if (!mounted) return;
    if (projects.isEmpty) {
      setState(() {
        status = const ScanStatus('No projects', 'Save a project first.');
      });
      return;
    }

    final chosen = await showDialog<PersistedProject>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Load Project Snapshot'),
        children: [
          for (final project in projects)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(project),
              child: Text(project.name),
            ),
        ],
      ),
    );
    if (!mounted || chosen == null) return;

    final loadedAssetIds = await db.loadProjectAssetIds(chosen.id);
    if (!mounted) return;
    setState(() {
      selectedIds
        ..clear()
        ..addAll(loadedAssetIds.where((id) => assets.any((a) => a.id == id)));
      activeProjectName = chosen.name;
      status = ScanStatus(
        'Project loaded',
        '${chosen.name} (${selectedIds.length} selected assets)',
      );
    });
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

    final result = await scanAssetFolder(
      rootPath,
      onStatus: (next) {
        if (!mounted) return;
        setState(() => status = next);
      },
    );

    if (!mounted) return;
    setState(() {
      sourceRoots.add(rootPath);
      assets.removeWhere((asset) => asset.sourceRoot == rootPath);
      assets.addAll(result.assets);
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
    unawaited(_persistCatalog());
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

    final copied = await copyAssetsToTarget(selected, target);
    if (!mounted) return;
    setState(() {
      status = ScanStatus('Copied assets', '$copied files copied to $target');
    });
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
    setState(() {
      final selected = selectedIds.contains(asset.id)
          ? assets.where((item) => selectedIds.contains(item.id))
          : [asset];
      for (final item in selected) {
        item.ignored = ignored;
      }
    });
    unawaited(_persistCatalog());
  }

  @override
  Widget build(BuildContext context) {
    final visible = filteredAssets;
    final counts = {
      'all': assets.length,
      'image': assets.where((asset) => asset.type == 'image').length,
      'model': assets.where((asset) => asset.type == 'model').length,
      'audio': assets.where((asset) => asset.type == 'audio').length,
    };

    return Scaffold(
      body: Column(
        children: [
          HeaderBar(
            scanning: scanning,
            status: status,
            canGoBack: canGoBackInHistory,
            canGoForward: canGoForwardInHistory,
            onScan: chooseAndScan,
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
                  counts: counts,
                  typeFilter: typeFilter,
                  modelTextureFilter: modelTextureFilter,
                  hideIgnored: hideIgnored,
                  sourceRoots: sourceRoots.toList()..sort(),
                  onTypeChanged: (value) => setState(() => typeFilter = value),
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
                  onRemoveSource: removeSource,
                ),
                Expanded(
                  child: Column(
                    children: [
                      SearchAndSummary(
                        controller: searchController,
                        visibleCount: visible.length,
                        totalCount: assets.length,
                        onChanged: (value) => setState(() => query = value),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(
                              child: PreviewPanel(
                                asset: active,
                                allAssets: assets,
                                onActivateAsset: _activateAsset,
                              ),
                            ),
                            ListResizeHandle(
                              onDrag: (delta) {
                                setState(() {
                                  assetListHeight = (assetListHeight - delta)
                                      .clamp(180, 520)
                                      .toDouble();
                                });
                              },
                            ),
                            SizedBox(
                              height: assetListHeight,
                              child: AssetList(
                                assets: visible,
                                active: active,
                                selectedIds: selectedIds,
                                onActivate: _activateAsset,
                                onSelect: toggleSelected,
                                onIgnoredChanged: setIgnored,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
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
              'Asset Atlas Native',
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
        FilledButton.icon(
          onPressed: scanning ? null : onScan,
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

class FilterPanel extends StatelessWidget {
  const FilterPanel({
    required this.counts,
    required this.typeFilter,
    required this.modelTextureFilter,
    required this.hideIgnored,
    required this.sourceRoots,
    required this.onTypeChanged,
    required this.onModelTextureFilterChanged,
    required this.onHideIgnoredChanged,
    required this.onRemoveSource,
    super.key,
  });

  final Map<String, int> counts;
  final String typeFilter;
  final String modelTextureFilter;
  final bool hideIgnored;
  final List<String> sourceRoots;
  final ValueChanged<String> onTypeChanged;
  final ValueChanged<String> onModelTextureFilterChanged;
  final ValueChanged<bool> onHideIgnoredChanged;
  final ValueChanged<String> onRemoveSource;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      child: Material(
        color: const Color(0xfff7f8fb),
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            const Text('Types', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final type in ['all', 'image', 'model', 'audio'])
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ChoiceChip(
                  selected: typeFilter == type,
                  label: Text('${type.toUpperCase()} (${counts[type] ?? 0})'),
                  onSelected: (_) => onTypeChanged(type),
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
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(root, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: 'Remove source',
                  icon: const Icon(Icons.close),
                  onPressed: () => onRemoveSource(root),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class SearchAndSummary extends StatelessWidget {
  const SearchAndSummary({
    required this.controller,
    required this.visibleCount,
    required this.totalCount,
    required this.onChanged,
    super.key,
  });

  final TextEditingController controller;
  final int visibleCount;
  final int totalCount;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search name, folder, or tag',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: onChanged,
            ),
          ),
          const SizedBox(width: 14),
          Text('$visibleCount visible / $totalCount cataloged'),
        ],
      ),
    );
  }
}

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
  final void Function(AssetItem asset, bool selected) onSelect;
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
        return Material(
          color: isActive
              ? Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: .55)
              : Colors.transparent,
          child: ListTile(
            leading: Checkbox(
              value: selectedIds.contains(asset.id),
              onChanged: (value) => onSelect(asset, value ?? false),
            ),
            title: Text(
              asset.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              asset.relativePath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Copy asset path',
                  icon: const Icon(Icons.content_copy, size: 18),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: asset.path));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Asset path copied.')),
                    );
                  },
                ),
                Text(asset.ext.toUpperCase()),
                const SizedBox(width: 12),
                Tooltip(
                  message: asset.ignored ? 'Ignored' : 'Not ignored',
                  child: Checkbox(
                    value: asset.ignored,
                    onChanged: (value) =>
                        onIgnoredChanged(asset, value ?? false),
                  ),
                ),
              ],
            ),
            onTap: () => onActivate(asset),
          ),
        );
      },
    );
  }
}

class PreviewPanel extends StatefulWidget {
  const PreviewPanel({
    required this.asset,
    required this.allAssets,
    required this.onActivateAsset,
    super.key,
  });

  final AssetItem? asset;
  final List<AssetItem> allAssets;
  final ValueChanged<AssetItem> onActivateAsset;

  @override
  State<PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<PreviewPanel> {
  double detailsWidth = 360;

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
      return ModelPreview(asset: item, allAssets: widget.allAssets);
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
    await player.play(DeviceFileSource(widget.asset.path));
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
  const ModelPreview({required this.asset, required this.allAssets, super.key});

  final AssetItem asset;
  final List<AssetItem> allAssets;

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

  Future<MeshModel> _loadCurrentMesh() {
    return loadMesh(
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
    if (oldWidget.asset.path != widget.asset.path ||
        oldWidget.allAssets.length != widget.allAssets.length) {
      meshFuture = _loadCurrentMesh();
      yaw = -0.6;
      pitch = 0.35;
      zoom = 1;
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
                          child: Text(
                            '${mesh.name} · ${mesh.vertices.length} verts · ${mesh.faces.length} faces',
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

class MeshPainter extends CustomPainter {
  MeshPainter({
    required this.mesh,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.renderMode,
  });

  final MeshModel mesh;
  final double yaw;
  final double pitch;
  final double zoom;
  final RenderMode renderMode;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scale = math.min(size.width, size.height) * .38 * zoom;
    final sy = math.sin(yaw);
    final cy = math.cos(yaw);
    final sx = math.sin(pitch);
    final cx = math.cos(pitch);
    final projected = <_Projected>[];

    for (final vertex in mesh.vertices) {
      final x1 = vertex.x * cy + vertex.z * sy;
      final z1 = -vertex.x * sy + vertex.z * cy;
      final y1 = vertex.y * cx - z1 * sx;
      final z2 = vertex.y * sx + z1 * cx;
      final perspective = 2.8 / (2.8 + z2);
      projected.add(
        _Projected(
          center.dx + x1 * scale * perspective,
          center.dy - y1 * scale * perspective,
          z2,
        ),
      );
    }

    final facePaint = Paint()..style = PaintingStyle.fill;
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xff18324a).withValues(alpha: .62);
    final drawEdges =
        renderMode == RenderMode.wireframe || renderMode == RenderMode.solid;

    final faces = mesh.faces.toList()
      ..sort(
        (a, b) => _faceDepth(projected, b).compareTo(_faceDepth(projected, a)),
      );
    final step = math.max(1, (faces.length / 14000).ceil());
    for (var index = 0; index < faces.length; index += step) {
      final face = faces[index];
      if (face.indices.any((i) => i < 0 || i >= projected.length)) continue;
      final material =
          (face.materialIndex >= 0 &&
              face.materialIndex < mesh.materials.length)
          ? mesh.materials[face.materialIndex]
          : null;
      if (renderMode == RenderMode.textured &&
          material?.textureImage != null &&
          face.uvs.length == 3) {
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
          uvA: face.uvs[0],
          uvB: face.uvs[1],
          uvC: face.uvs[2],
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
        final fillAlpha = renderMode == RenderMode.solid
            ? 1.0
            : (renderMode == RenderMode.textured ? .92 : 1.0) * materialOpacity;
        facePaint.color = faceColor.withValues(alpha: fillAlpha);
        canvas.drawPath(path, facePaint);
      }
      if (drawEdges) {
        canvas.drawPath(path, edgePaint);
      }
    }
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
        oldDelegate.renderMode != renderMode;
  }
}

enum RenderMode { textured, solid, wireframe }

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
    required this.onActivateAsset,
    super.key,
  });

  final AssetItem item;
  final List<AssetItem> allAssets;
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
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.path,
                    style: const TextStyle(color: Colors.black54),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy asset path',
                  icon: const Icon(Icons.content_copy, size: 18),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: item.path));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Asset path copied.')),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 14),
            DetailRow(label: 'Type', value: '${item.type} / ${item.ext}'),
            DetailRow(label: 'Source', value: item.sourceName),
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
                onActivateAsset: onActivateAsset,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class DetailRow extends StatelessWidget {
  const DetailRow({required this.label, required this.value, super.key});

  final String label;
  final String value;

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
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class ModelTextureDiagnostics extends StatelessWidget {
  const ModelTextureDiagnostics({
    required this.asset,
    required this.allAssets,
    required this.onActivateAsset,
    super.key,
  });

  final AssetItem asset;
  final List<AssetItem> allAssets;
  final ValueChanged<AssetItem> onActivateAsset;

  @override
  Widget build(BuildContext context) {
    final nearby = findNearbyTextures(asset, allAssets);
    if (asset.ext == 'fbx') {
      return FutureBuilder<List<TextureDiscoveryEntry>>(
        future: loadModelTextureReferenceEntries(asset, allAssets),
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
                ? 'No FBX texture references or nearby scanned textures found. The material may be embedded, procedural, or untextured.'
                : '${referenced.length} FBX references · ${nearby.length} nearby scanned candidates.',
            entries: combined,
            onActivateAsset: onActivateAsset,
          );
        },
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
    this.jumpAsset,
  });

  final String label;
  final String copyPath;
  final AssetItem? jumpAsset;
}

class TextureDiscoveryBox extends StatelessWidget {
  const TextureDiscoveryBox({
    required this.title,
    required this.message,
    required this.entries,
    required this.onActivateAsset,
    super.key,
  });

  final String title;
  final String message;
  final List<TextureDiscoveryEntry> entries;
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
            Text(message, style: const TextStyle(color: Colors.black54)),
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

Future<List<TextureDiscoveryEntry>> loadModelTextureReferenceEntries(
  AssetItem asset,
  List<AssetItem> allAssets,
) async {
  if (asset.ext != 'fbx') return const [];
  final mesh = await importFbxWithUfbx(
    asset.path,
    asset.name,
    allAssets: allAssets,
  );
  return mesh.allTexturePaths.map((path) {
    final resolved = resolveTextureReference(
      asset.path,
      path,
      allAssets: allAssets,
      allowFallbackLookup: false,
    );
    final existingPath = resolved ?? path;
    final exists = File(existingPath).existsSync();
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
    late final String label;
    if (resolved == null || resolved == path) {
      label = '$path ${exists ? "(found)" : "(missing)"}';
    } else {
      label = '$path -> $resolved ${exists ? "(found)" : "(missing)"}';
    }
    return TextureDiscoveryEntry(
      label: label,
      copyPath: existingPath,
      jumpAsset: jumpAsset,
    );
  }).toList();
}

String normalizePathKey(String value) {
  return value.trim().toLowerCase().replaceAll('/', '\\');
}

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
  final sourceCandidates = allAssets.where((asset) {
    if (!textureExts.contains(asset.ext)) return false;
    final sourceLower = asset.sourceRoot.toLowerCase().replaceAll('\\', '/');
    return modelPathLower.startsWith(sourceLower);
  }).toList();
  if (sourceCandidates.isEmpty) return null;

  final requestedBase = texturePath
      .split(RegExp(r'[\\/]'))
      .last
      .toLowerCase()
      .replaceAll(RegExp(r'\.[^.]+$'), '');
  if (requestedBase.isEmpty) return null;

  String normalize(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  final requestedNormalized = normalize(requestedBase);
  final strippedSuffix = requestedBase.contains('_')
      ? requestedBase.substring(0, requestedBase.lastIndexOf('_'))
      : requestedBase;

  int score(AssetItem asset) {
    final base = asset.name.toLowerCase().replaceAll(RegExp(r'\.[^.]+$'), '');
    final normalized = normalize(base);
    var value = 0;
    if (base == requestedBase) value += 120;
    if (normalized == requestedNormalized) value += 95;

    // Many source FBX files keep author-variant suffixes (eg. _Mike).
    if (strippedSuffix.isNotEmpty && base == strippedSuffix) value += 90;

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

  sourceCandidates.sort((a, b) => score(b).compareTo(score(a)));
  final best = sourceCandidates.first;
  final bestScore = score(best);
  if (bestScore < 80) return null;
  return best.path;
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
    final textureBase = texturePath
        .split(RegExp(r'[\\/]'))
        .last
        .toLowerCase()
        .replaceAll(RegExp(r'\.[^.]+$'), '');
    final assetBase = asset.name.toLowerCase().replaceAll(
      RegExp(r'\.[^.]+$'),
      '',
    );
    if (textureBase == assetBase) value += 25;
    return value;
  }

  supported.sort((a, b) => score(b).compareTo(score(a)));
  return score(supported.first) > 0 ? supported.first.path : null;
}

Set<String> tokenSet(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'\.[^.]+$'), '')
      .split(RegExp(r'[^a-z0-9]+'))
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
      final bytes = await File(path).readAsBytes();
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
    final bytes = await File(path).readAsBytes();
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
    final type = typeForExt(ext);
    if (type == 'other') {
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
        id: '${entity.path}:${stat.size}:${stat.modified.millisecondsSinceEpoch}',
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

Future<int> copyAssetsToTarget(List<AssetItem> selected, String target) async {
  var copied = 0;
  final destinationRoot = Directory(target);
  if (!destinationRoot.existsSync()) {
    destinationRoot.createSync(recursive: true);
  }

  for (final asset in selected) {
    final destination = File('$target${Platform.pathSeparator}${asset.name}');
    await File(asset.path).copy(destination.path);
    copied += 1;
  }
  return copied;
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

Future<MeshModel> loadMesh(
  AssetItem asset, {
  List<AssetItem> allAssets = const [],
  int fallbackCheckerSquareSize = 16,
}) async {
  if (asset.ext == 'obj') {
    return parseObjMesh(await File(asset.path).readAsString(), asset.name);
  }
  if (asset.ext == 'fbx') {
    fbxLog('Loading FBX mesh: ${asset.path}');
    return importFbxWithUfbx(
      asset.path,
      asset.name,
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
  final result = await Process.run(helper, [path]);
  if (result.exitCode != 0) {
    final error = (result.stderr as String).trim();
    fbxLog('Importer failed (${result.exitCode}): $error');
    throw FormatException(error.isEmpty ? 'ufbx importer failed.' : error);
  }
  fbxLog('Importer completed for: $path');

  final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
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

Future<MeshModel> meshModelFromImporterJson(
  Map<String, dynamic> json, {
  required String modelPath,
  required String name,
  List<AssetItem> allAssets = const [],
  int fallbackCheckerSquareSize = 16,
}) async {
  final vertices = (json['vertices'] as List<dynamic>).map((item) {
    final values = item as List<dynamic>;
    return Vec3(
      (values[0] as num).toDouble(),
      (values[1] as num).toDouble(),
      (values[2] as num).toDouble(),
    );
  }).toList();
  final faces = (json['faces'] as List<dynamic>).map((item) {
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
    final textureImage = await firstTextureImage(resolvedTextures);
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
        opacity: opacity,
        roughness: roughness,
        metalness: metalness,
        specularFactor: specularFactor,
        emissiveFactor: emissiveFactor,
        emissiveColor: emissiveColor,
        shaderType: (material['shaderType'] as num?)?.toInt() ?? -1,
        shadingModel: (material['shadingModel'] as String?) ?? '',
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

  if (materials.isEmpty && faces.any((face) => face.uvs.length == 3)) {
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

  if (materials.isEmpty && faces.any((face) => face.uvs.length == 3)) {
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
  final uvFaces = faces.where((face) => face.uvs.length == 3).length;
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
  return '$executableDir${Platform.pathSeparator}asset_atlas_mesh_importer.exe';
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

MeshModel parseFbxMesh(Uint8List bytes, String name) {
  final header = String.fromCharCodes(bytes.take(21));
  if (header.startsWith('Kaydara FBX Binary')) {
    return _parseBinaryFbx(bytes, name);
  }
  return _parseAsciiFbx(String.fromCharCodes(bytes), name);
}

MeshModel _parseAsciiFbx(String text, String name) {
  final vertexMatch = RegExp(
    r'Vertices:\s*\*\d+\s*\{[^}]*?a:\s*([^}]*)\}',
    dotAll: true,
  ).firstMatch(text);
  final indexMatch = RegExp(
    r'PolygonVertexIndex:\s*\*\d+\s*\{[^}]*?a:\s*([^}]*)\}',
    dotAll: true,
  ).firstMatch(text);
  if (vertexMatch == null || indexMatch == null) {
    throw const FormatException('No ASCII FBX mesh geometry found.');
  }

  final vertexNumbers = _parseNumberList(vertexMatch.group(1)!);
  final indexNumbers = _parseNumberList(
    indexMatch.group(1)!,
  ).map((value) => value.toInt()).toList();
  return _meshFromFbxArrays(name, vertexNumbers, indexNumbers);
}

List<double> _parseNumberList(String text) {
  return RegExp(
    r'-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?',
  ).allMatches(text).map((match) => double.parse(match.group(0)!)).toList();
}

MeshModel _parseBinaryFbx(Uint8List bytes, String name) {
  final reader = _FbxReader(bytes);
  reader.offset = 23;
  final version = reader.readUint32();
  final root = _FbxNode('Root', const [], []);
  while (reader.offset < bytes.length) {
    final node = reader.readNode(version);
    if (node == null) break;
    root.children.add(node);
  }

  for (final geometry in root.descendants('Geometry')) {
    final verticesNode = geometry.child('Vertices');
    final indicesNode = geometry.child('PolygonVertexIndex');
    if (verticesNode == null || indicesNode == null) continue;
    final vertices = verticesNode.firstDoubleArray;
    final indices = indicesNode.firstIntArray;
    if (vertices.isNotEmpty && indices.isNotEmpty) {
      return _meshFromFbxArrays(name, vertices, indices);
    }
  }
  throw const FormatException('No binary FBX mesh geometry found.');
}

MeshModel _meshFromFbxArrays(
  String name,
  List<double> vertexNumbers,
  List<int> indexNumbers,
) {
  final vertices = <Vec3>[];
  for (var i = 0; i + 2 < vertexNumbers.length; i += 3) {
    vertices.add(
      Vec3(vertexNumbers[i], vertexNumbers[i + 1], vertexNumbers[i + 2]),
    );
  }

  final faces = <MeshFace>[];
  var polygon = <int>[];
  for (final raw in indexNumbers) {
    if (raw < 0) {
      polygon.add(-raw - 1);
      _addTriangulatedFace(polygon, faces);
      polygon = <int>[];
    } else {
      polygon.add(raw);
    }
  }

  if (vertices.isEmpty || faces.isEmpty) {
    throw const FormatException('No FBX polygon mesh found.');
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

class _FbxReader {
  _FbxReader(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  int offset = 0;

  int readUint8() => bytes[offset++];
  int readUint32() {
    final value = data.getUint32(offset, Endian.little);
    offset += 4;
    return value;
  }

  int readUint64() {
    final value = data.getUint64(offset, Endian.little);
    offset += 8;
    return value;
  }

  int readInt16() {
    final value = data.getInt16(offset, Endian.little);
    offset += 2;
    return value;
  }

  int readInt32() {
    final value = data.getInt32(offset, Endian.little);
    offset += 4;
    return value;
  }

  double readFloat32() {
    final value = data.getFloat32(offset, Endian.little);
    offset += 4;
    return value;
  }

  double readFloat64() {
    final value = data.getFloat64(offset, Endian.little);
    offset += 8;
    return value;
  }

  _FbxNode? readNode(int version) {
    final largeOffsets = version >= 7500;
    final start = offset;
    final endOffset = largeOffsets ? readUint64() : readUint32();
    final propertyCount = largeOffsets ? readUint64() : readUint32();
    final propertyBytes = largeOffsets ? readUint64() : readUint32();
    final nameLength = readUint8();
    if (endOffset == 0 &&
        propertyCount == 0 &&
        propertyBytes == 0 &&
        nameLength == 0) {
      return null;
    }
    if (endOffset <= start || endOffset > bytes.length) {
      throw const FormatException('Invalid FBX node bounds.');
    }

    final nodeName = String.fromCharCodes(
      bytes.sublist(offset, offset + nameLength),
    );
    offset += nameLength;
    final properties = <Object?>[];
    for (var i = 0; i < propertyCount; i += 1) {
      properties.add(readProperty());
    }

    final children = <_FbxNode>[];
    while (offset < endOffset) {
      final childStart = offset;
      final child = readNode(version);
      if (child == null) break;
      children.add(child);
      if (offset == childStart) break;
    }
    offset = endOffset;
    return _FbxNode(nodeName, properties, children);
  }

  Object? readProperty() {
    final code = String.fromCharCode(readUint8());
    switch (code) {
      case 'Y':
        return readInt16();
      case 'C':
        return readUint8() != 0;
      case 'I':
        return readInt32();
      case 'F':
        return readFloat32();
      case 'D':
        return readFloat64();
      case 'L':
        final value = data.getInt64(offset, Endian.little);
        offset += 8;
        return value;
      case 'R':
      case 'S':
        final length = readUint32();
        final value = bytes.sublist(offset, offset + length);
        offset += length;
        return code == 'S' ? String.fromCharCodes(value) : value;
      case 'd':
        return _readDoubleArray(float64: true);
      case 'f':
        return _readDoubleArray(float64: false);
      case 'i':
        return _readIntArray(int64: false);
      case 'l':
        return _readIntArray(int64: true);
      case 'b':
      case 'c':
        return _readIntArray(int64: false);
      default:
        throw FormatException('Unsupported FBX property type $code.');
    }
  }

  List<double> _readDoubleArray({required bool float64}) {
    final length = readUint32();
    final encoding = readUint32();
    final byteLength = readUint32();
    var payload = bytes.sublist(offset, offset + byteLength);
    offset += byteLength;
    if (encoding == 1) payload = Uint8List.fromList(zlib.decode(payload));
    final payloadData = ByteData.sublistView(payload);
    return List<double>.generate(length, (i) {
      final byteOffset = i * (float64 ? 8 : 4);
      return float64
          ? payloadData.getFloat64(byteOffset, Endian.little)
          : payloadData.getFloat32(byteOffset, Endian.little);
    });
  }

  List<int> _readIntArray({required bool int64}) {
    final length = readUint32();
    final encoding = readUint32();
    final byteLength = readUint32();
    var payload = bytes.sublist(offset, offset + byteLength);
    offset += byteLength;
    if (encoding == 1) payload = Uint8List.fromList(zlib.decode(payload));
    final payloadData = ByteData.sublistView(payload);
    return List<int>.generate(length, (i) {
      final byteOffset = i * (int64 ? 8 : 4);
      return int64
          ? payloadData.getInt64(byteOffset, Endian.little)
          : payloadData.getInt32(byteOffset, Endian.little);
    });
  }
}

class _FbxNode {
  _FbxNode(this.name, this.properties, this.children);

  final String name;
  final List<Object?> properties;
  final List<_FbxNode> children;

  _FbxNode? child(String childName) {
    for (final child in children) {
      if (child.name == childName) return child;
    }
    return null;
  }

  Iterable<_FbxNode> descendants(String nodeName) sync* {
    for (final child in children) {
      if (child.name == nodeName) yield child;
      yield* child.descendants(nodeName);
    }
  }

  List<double> get firstDoubleArray {
    for (final property in properties) {
      if (property is List<double>) return property;
    }
    return const [];
  }

  List<int> get firstIntArray {
    for (final property in properties) {
      if (property is List<int>) return property;
    }
    return const [];
  }
}

class MeshModel {
  MeshModel({
    required this.name,
    required this.vertices,
    required this.faces,
    this.materials = const [],
    this.textureFiles = const [],
    this.vertexColors = const [],
  });

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
  final List<Color> vertexColors;

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
    this.opacity = 1.0,
    this.roughness = 0.7,
    this.metalness = 0.0,
    this.specularFactor = 0.2,
    this.emissiveFactor = 0.0,
    this.emissiveColor = const Color(0xff000000),
    this.shaderType = -1,
    this.shadingModel = '',
  });

  final String name;
  final Color color;
  final List<String> textures;
  final List<String> resolvedTextures;
  final Color? textureColor;
  final ui.Image? textureImage;
  final double opacity;
  final double roughness;
  final double metalness;
  final double specularFactor;
  final double emissiveFactor;
  final Color emissiveColor;
  final int shaderType;
  final String shadingModel;
}

class MeshFace {
  const MeshFace(this.indices, [this.materialIndex = 0, this.uvs = const []]);
  final List<int> indices;
  final int materialIndex;
  final List<Vec2> uvs;
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

  Future<void> initialize() async {
    if (_db != null) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final supportDir = await getApplicationSupportDirectory();
    final dbPath =
        '${supportDir.path}${Platform.pathSeparator}asset_atlas_native.db';
    _db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
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
              ignored INTEGER NOT NULL DEFAULT 0
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
      );
    }).toList();
    final sourceRoots = sourceRows
        .map((row) => row['root_path'] as String)
        .toSet();
    return PersistedCatalog(assets: assets, sourceRoots: sourceRoots);
  }

  Future<void> saveCatalog({
    required List<AssetItem> assets,
    required List<String> sourceRoots,
  }) async {
    await initialize();
    final db = _db!;
    await db.transaction((txn) async {
      await txn.delete('catalog_assets');
      await txn.delete('catalog_sources');
      for (final rootPath in sourceRoots) {
        await txn.insert('catalog_sources', {'root_path': rootPath});
      }
      for (final asset in assets) {
        await txn.insert('catalog_assets', {
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
        });
      }
    });
  }

  Future<String> saveProject({
    required String name,
    required String? rootPath,
    required List<String> assetIds,
  }) async {
    await initialize();
    final db = _db!;
    final projectId = '${DateTime.now().millisecondsSinceEpoch}-$name';
    await db.transaction((txn) async {
      await txn.insert('projects', {
        'id': projectId,
        'name': name,
        'root_path': rootPath,
        'created_ms': DateTime.now().millisecondsSinceEpoch,
      });
      for (final assetId in assetIds) {
        await txn.insert('project_assets', {
          'project_id': projectId,
          'asset_id': assetId,
        });
      }
    });
    return projectId;
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
