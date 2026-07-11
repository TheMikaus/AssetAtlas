const IMAGE_EXTS = new Set(["png", "jpg", "jpeg", "webp", "gif", "bmp"]);
const AUDIO_EXTS = new Set(["wav", "mp3", "flac", "ogg", "midi", "mid"]);
const MODEL_EXTS = new Set(["obj", "fbx", "gltf", "glb", "blend", "dae", "stl"]);
const STORAGE_KEY = "asset-atlas-state-v1";
const desktopApi = window.assetAtlasDesktop || null;

const state = {
  assets: [],
  selectedIds: new Set(),
  activeId: null,
  view: "flat",
  query: "",
  hideIgnored: true,
  selectionOnly: false,
  typeFilter: "all",
  tagFilter: "all",
  projectFilter: "all",
  activeProjectId: null,
  projects: [],
  modelRotations: {},
  lastImport: null,
  sources: [],
  scanStatus: null,
  stageHeight: 360,
  previewSplit: 56
};

const els = {
  demoButton: document.querySelector("#demoButton"),
  scanButton: document.querySelector("#scanButton"),
  folderInput: document.querySelector("#folderInput"),
  searchInput: document.querySelector("#searchInput"),
  hideIgnored: document.querySelector("#hideIgnored"),
  selectionOnly: document.querySelector("#selectionOnly"),
  projectFilter: document.querySelector("#projectFilter"),
  typeFilters: document.querySelector("#typeFilters"),
  sourceFolders: document.querySelector("#sourceFolders"),
  tagFilters: document.querySelector("#tagFilters"),
  viewMode: document.querySelector("#viewMode"),
  summary: document.querySelector("#summary"),
  scanStatus: document.querySelector("#scanStatus"),
  emptyState: document.querySelector("#emptyState"),
  assetGroups: document.querySelector("#assetGroups"),
  assetStage: document.querySelector(".asset-stage"),
  stageSplitter: document.querySelector("#stageSplitter"),
  listResizeHandle: document.querySelector("#listResizeHandle"),
  previewPane: document.querySelector("#previewPane"),
  detailsPane: document.querySelector("#detailsPane"),
  copySelected: document.querySelector("#copySelected"),
  projectName: document.querySelector("#projectName"),
  projectRoot: document.querySelector("#projectRoot"),
  saveProject: document.querySelector("#saveProject"),
  projectList: document.querySelector("#projectList"),
  activeProjectPanel: document.querySelector("#activeProjectPanel"),
  template: document.querySelector("#assetCardTemplate")
};

loadState();
bindEvents();
render();

function bindEvents() {
  document.body.classList.toggle("desktop-mode", Boolean(desktopApi?.isDesktop));
  if (desktopApi?.isDesktop) {
    els.scanButton.textContent = "Scan desktop folder";
    els.folderInput.closest(".file-fallback")?.setAttribute("hidden", "");
    desktopApi.onScanProgress?.(status => setScanStatus(status));
  }
  els.demoButton.addEventListener("click", loadDemoCatalog);
  els.scanButton.addEventListener("click", scanWithDirectoryPicker);
  els.folderInput.addEventListener("change", async event => {
    await addFiles([...event.target.files], "Imported folder");
    event.target.value = "";
  });
  els.searchInput.addEventListener("input", event => {
    state.query = event.target.value.trim().toLowerCase();
    render();
  });
  els.hideIgnored.addEventListener("change", event => {
    state.hideIgnored = event.target.checked;
    saveState();
    render();
  });
  els.selectionOnly.addEventListener("change", event => {
    state.selectionOnly = event.target.checked;
    render();
  });
  els.projectFilter.addEventListener("click", event => {
    const button = event.target.closest("button[data-project-filter]");
    if (!button) return;
    state.projectFilter = button.dataset.projectFilter;
    render();
  });
  els.viewMode.addEventListener("click", event => {
    const button = event.target.closest("button[data-view]");
    if (!button) return;
    state.view = button.dataset.view;
    render();
  });
  els.copySelected.addEventListener("click", copySelectedAssets);
  els.saveProject.addEventListener("click", saveProject);
  bindLayoutResizers();
}

function loadDemoCatalog() {
  const now = Date.now();
  const demoAssets = [
    makeDemoAsset({
      id: "demo-texture-forest",
      name: "forest_floor_albedo.png",
      path: "NaturePack/Textures/forest_floor_albedo.png",
      folder: "NaturePack/Textures",
      sourceFolder: "Demo Catalog",
      ext: "png",
      type: "image",
      tags: ["image", "png", "forest", "floor", "texture", "nature"],
      size: 1482000,
      lastModified: now - 86400000,
      previewUrl: svgDataUrl("Forest Floor", "#d9ead3", "#31572c")
    }),
    makeDemoAsset({
      id: "demo-sprite-mage",
      name: "mage_idle_01.png",
      path: "Characters/Mage/Sprites/mage_idle_01.png",
      folder: "Characters/Mage/Sprites",
      sourceFolder: "Demo Catalog",
      ext: "png",
      type: "image",
      tags: ["image", "png", "mage", "idle", "character", "sprite"],
      size: 482000,
      lastModified: now - 18200000,
      previewUrl: svgDataUrl("Mage Idle", "#e8ddff", "#4a2d86")
    }),
    makeDemoAsset({
      id: "demo-sfx-laser",
      name: "laser_shot_03.wav",
      path: "SciFiSFX/Weapons/laser_shot_03.wav",
      folder: "SciFiSFX/Weapons",
      sourceFolder: "Demo Catalog",
      ext: "wav",
      type: "audio",
      tags: ["audio", "wav", "laser", "weapon", "sfx", "scifi"],
      size: 214000,
      lastModified: now - 26600000
    }),
    makeDemoAsset({
      id: "demo-music-cave",
      name: "crystal_cave_loop.ogg",
      path: "Music/Loops/crystal_cave_loop.ogg",
      folder: "Music/Loops",
      sourceFolder: "Demo Catalog",
      ext: "ogg",
      type: "audio",
      tags: ["audio", "ogg", "music", "loop", "cave", "ambient"],
      size: 5824000,
      lastModified: now - 38600000
    }),
    makeDemoAsset({
      id: "demo-model-ship",
      name: "scout_ship.obj",
      path: "Vehicles/Ships/scout_ship.obj",
      folder: "Vehicles/Ships",
      sourceFolder: "Demo Catalog",
      ext: "obj",
      type: "model",
      tags: ["model", "obj", "ship", "vehicle", "scifi"],
      size: 982000,
      lastModified: now - 56600000,
      fileText: "v -1 -0.5 0\nv 1 -0.5 0\nv 0 0.9 0\nv 0 -0.1 1\nf 1 2 3\nf 1 2 4\nf 2 3 4\nf 3 1 4"
    }),
    makeDemoAsset({
      id: "demo-model-tree",
      name: "lowpoly_pine.obj",
      path: "NaturePack/Models/lowpoly_pine.obj",
      folder: "NaturePack/Models",
      sourceFolder: "Demo Catalog",
      ext: "obj",
      type: "model",
      tags: ["model", "obj", "tree", "pine", "nature", "lowpoly"],
      size: 643000,
      lastModified: now - 66600000,
      fileText: "v 0 1.2 0\nv -0.7 0.1 0\nv 0.7 0.1 0\nv 0 -0.2 0.7\nv 0 -1 0\nf 1 2 4\nf 1 4 3\nf 1 3 2\nf 2 3 5\nf 3 4 5\nf 4 2 5"
    }),
    makeDemoAsset({
      id: "demo-model-crate-fbx",
      name: "simple_crate.fbx",
      path: "Props/Crates/simple_crate.fbx",
      folder: "Props/Crates",
      sourceFolder: "Demo Catalog",
      ext: "fbx",
      type: "model",
      tags: ["model", "fbx", "crate", "prop"],
      size: 734000,
      lastModified: now - 76600000,
      fileText: `; FBX 7.4.0 project file
Vertices: *24 {
  a: -1,-1,-1, 1,-1,-1, 1,1,-1, -1,1,-1, -1,-1,1, 1,-1,1, 1,1,1, -1,1,1
}
PolygonVertexIndex: *24 {
  a: 0,1,2,-4,4,5,6,-8,0,4,7,-4,1,5,6,-3,3,2,6,-8,0,1,5,-5
}`
    })
  ];

  const known = new Map(state.assets.map(asset => [asset.id, asset]));
  for (const asset of demoAssets) {
    if (!known.has(asset.id)) state.assets.push(asset);
  }
  upsertSource("Demo Catalog", "Demo Catalog");
  state.activeId = demoAssets[0].id;
  render();
}

function makeDemoAsset(asset) {
  const text = asset.fileText || `${asset.name}\nDemo placeholder asset.`;
  return {
    ignored: false,
    previewUrl: "",
    ...asset,
    file: new Blob([text], { type: "text/plain" })
  };
}

function svgDataUrl(label, fill, ink) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="480" height="300" viewBox="0 0 480 300">
    <rect width="480" height="300" rx="18" fill="${fill}"/>
    <circle cx="120" cy="120" r="54" fill="white" opacity=".65"/>
    <rect x="204" y="86" width="176" height="22" rx="11" fill="${ink}" opacity=".22"/>
    <rect x="204" y="124" width="132" height="22" rx="11" fill="${ink}" opacity=".18"/>
    <text x="40" y="252" fill="${ink}" font-size="34" font-family="Arial, sans-serif" font-weight="700">${label}</text>
  </svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

async function scanWithDirectoryPicker() {
  if (desktopApi?.isDesktop) {
    try {
      setScanStatus({ label: "Scanning desktop folder", detail: "Native folder picker is opening" });
      const result = await desktopApi.scanFolders();
      if (result.canceled) {
        setScanStatus(null);
        return;
      }
      if (result.error) {
        setScanStatus({ label: "Scan failed", detail: result.error });
        return;
      }
      const skipped = result.skipped || { unsupported: 0, binaryObj: 0, inaccessible: 0 };
      setScanStatus({
        label: "Cataloging desktop assets",
        detail: `${result.assets.length} supported assets found`
      });
      mergeScannedAssets(result.assets, {
        sourceName: result.sources.map(source => source.name).join(", ") || "Desktop folders",
        scanned: result.assets.length + skipped.unsupported + skipped.binaryObj + skipped.inaccessible,
        binaryObjSkipped: skipped.binaryObj
      });
      setScanStatus({
        label: "Finished desktop scan",
        detail: `${result.assets.length} cataloged · ${skipped.unsupported + skipped.binaryObj + skipped.inaccessible} skipped`
      });
      setTimeout(() => {
        if (state.scanStatus?.label === "Finished desktop scan") setScanStatus(null);
      }, 3500);
    } catch (error) {
      console.error(error);
      setScanStatus({ label: "Scan failed", detail: error?.message || String(error) });
    }
    return;
  }

  if (!window.showDirectoryPicker) {
    alert("This browser cannot scan directories directly. Use Import folders instead.");
    return;
  }

  try {
    setScanStatus({ label: "Waiting for folder", detail: "Choose a source folder to scan" });
    const rootHandle = await window.showDirectoryPicker({ mode: "read" });
    const files = [];
    setScanStatus({ label: `Scanning ${rootHandle.name}`, detail: "Checking nested folders" });
    await collectFiles(rootHandle, rootHandle.name, files);
    await addFiles(files, rootHandle.name);
  } catch (error) {
    setScanStatus(null);
    if (error.name !== "AbortError") console.error(error);
  }
}

async function collectFiles(directoryHandle, prefix, files) {
  for await (const [name, handle] of directoryHandle.entries()) {
    if (handle.kind === "directory") {
      setScanStatus({ label: `Scanning ${prefix}/${name}`, detail: `${files.length} files found` });
      await collectFiles(handle, `${prefix}/${name}`, files);
    } else {
      const file = await handle.getFile();
      file.assetHandle = handle;
      file.assetPath = `${prefix}/${name}`;
      files.push(file);
    }
  }
}

async function addFiles(files, sourceName) {
  setScanStatus({ label: `Cataloging ${sourceName}`, detail: `0 of ${files.length} files checked` });
  const supported = [];
  let binaryObjSkipped = 0;
  for (let index = 0; index < files.length; index += 1) {
    const asset = toAsset(files[index], sourceName);
    if (asset.type !== "other") {
      if (asset.ext === "obj" && await isLikelyBinaryFile(files[index])) {
        binaryObjSkipped += 1;
      } else {
        supported.push(asset);
      }
    }
    if (index % 50 === 0 || index === files.length - 1) {
      setScanStatus({
        label: `Cataloging ${sourceName}`,
        detail: `${index + 1} of ${files.length} files checked · ${supported.length} supported`
      });
      await yieldToUi();
    }
  }
  let added = 0;
  let updated = 0;

  const known = new Map(state.assets.map(asset => [asset.id, asset]));
  const result = mergeAssetsIntoCatalog(supported, known, sourceName);
  added = result.added;
  updated = result.updated;

  state.lastImport = {
    sourceName,
    scanned: files.length,
    cataloged: supported.length,
    skipped: files.length - supported.length,
    binaryObjSkipped,
    added,
    updated,
    at: Date.now()
  };
  saveState();
  render();
  setScanStatus({
    label: `Finished ${sourceName}`,
    detail: `${supported.length} cataloged · ${files.length - supported.length} skipped${binaryObjSkipped ? ` · ${binaryObjSkipped} binary OBJ` : ""}`
  });
  setTimeout(() => {
    if (state.scanStatus?.label === `Finished ${sourceName}`) setScanStatus(null);
  }, 3500);
}

function mergeScannedAssets(assets, importInfo) {
  const known = new Map(state.assets.map(asset => [asset.id, asset]));
  const result = mergeAssetsIntoCatalog(assets.map(hydrateDesktopAsset), known, importInfo.sourceName);
  state.lastImport = {
    sourceName: importInfo.sourceName,
    scanned: importInfo.scanned,
    cataloged: assets.length,
    skipped: importInfo.scanned - assets.length,
    binaryObjSkipped: importInfo.binaryObjSkipped || 0,
    added: result.added,
    updated: result.updated,
    at: Date.now()
  };
  saveState();
  render();
}

function mergeAssetsIntoCatalog(assets, known, sourceName) {
  let added = 0;
  let updated = 0;

  for (const asset of assets) {
    upsertSource(asset.sourceFolder, sourceName);
    const existing = known.get(asset.id);
    if (existing) {
      Object.assign(existing, asset, {
        ignored: existing.ignored,
        tags: existing.tags?.length ? existing.tags : asset.tags
      });
      updated += 1;
    } else {
      state.assets.push(asset);
      added += 1;
    }
  }
  return { added, updated };
}

function hydrateDesktopAsset(asset) {
  if (!desktopApi?.isDesktop || !asset.nativePath) return asset;
  return {
    ...asset,
    file: {
      text: () => desktopApi.readText(asset.nativePath),
      arrayBuffer: () => desktopApi.readBinary(asset.nativePath)
    }
  };
}

function toAsset(file, sourceName) {
  const path = file.assetPath || file.webkitRelativePath || file.name;
  const ext = extension(file.name);
  const type = getType(ext);
  const sourceFolder = getSourceFolder(path, sourceName);
  const tags = inferTags(file.name, path, type, ext);

  return {
    id: `${path}:${file.size}:${file.lastModified}`,
    name: file.name,
    path,
    folder: path.includes("/") ? path.split("/").slice(0, -1).join("/") : sourceName,
    sourceFolder,
    ext,
    type,
    size: file.size,
    lastModified: file.lastModified,
    tags,
    ignored: false,
    file,
    handle: file.assetHandle || null,
    previewUrl: URL.createObjectURL(file)
  };
}

function getSourceFolder(path, fallback) {
  const normalized = path.replaceAll("\\", "/");
  return normalized.includes("/") ? normalized.split("/")[0] : fallback;
}

async function isLikelyBinaryFile(file) {
  if (!file?.slice) return false;
  const bytes = new Uint8Array(await file.slice(0, 4096).arrayBuffer());
  if (!bytes.length) return false;

  let suspicious = 0;
  for (const byte of bytes) {
    if (byte === 0) return true;
    const isAllowedTextByte = byte === 9 || byte === 10 || byte === 13 || (byte >= 32 && byte <= 126) || byte >= 128;
    if (!isAllowedTextByte) suspicious += 1;
  }
  return suspicious / bytes.length > 0.08;
}

function getType(ext) {
  if (IMAGE_EXTS.has(ext)) return "image";
  if (AUDIO_EXTS.has(ext)) return "audio";
  if (MODEL_EXTS.has(ext)) return "model";
  return "other";
}

function inferTags(name, path, type, ext) {
  const words = `${name} ${path}`
    .toLowerCase()
    .replace(/\.[^.]+$/, "")
    .split(/[^a-z0-9]+/)
    .filter(word => word.length > 2 && !["assets", "models", "images", "audio", "music", "textures"].includes(word));

  return [...new Set([type, ext, ...words.slice(0, 8)])];
}

function visibleAssets() {
  const activeProject = getActiveProject();
  return state.assets.filter(asset => {
    const haystack = `${asset.name} ${asset.path} ${asset.tags.join(" ")}`.toLowerCase();
    if (state.hideIgnored && asset.ignored) return false;
    if (state.selectionOnly && !state.selectedIds.has(asset.id)) return false;
    if (state.projectFilter === "in" && !isAssetInProject(asset.id, activeProject)) return false;
    if (state.projectFilter === "out" && isAssetInProject(asset.id, activeProject)) return false;
    if (state.typeFilter !== "all" && asset.type !== state.typeFilter) return false;
    if (state.tagFilter !== "all" && !asset.tags.includes(state.tagFilter)) return false;
    return !state.query || haystack.includes(state.query);
  });
}

function render() {
  els.searchInput.value = state.query;
  els.hideIgnored.checked = state.hideIgnored;
  els.selectionOnly.checked = state.selectionOnly;

  [...els.viewMode.querySelectorAll("button")].forEach(button => {
    button.classList.toggle("active", button.dataset.view === state.view);
  });
  [...els.projectFilter.querySelectorAll("button")].forEach(button => {
    button.classList.toggle("active", button.dataset.projectFilter === state.projectFilter);
    button.disabled = button.dataset.projectFilter !== "all" && !getActiveProject();
  });
  renderScanStatus();
  applyStageLayout();

  renderFilters();
  renderSourceFolders();
  renderProjects();
  renderActiveProjectPanel();
  renderAssets();
  renderInspector();
  saveState();
}

function applyStageLayout() {
  els.assetStage.style.setProperty("--stage-height", `${state.stageHeight}px`);
  els.assetStage.style.setProperty("--preview-width", `${state.previewSplit}%`);
}

function bindLayoutResizers() {
  els.listResizeHandle.addEventListener("pointerdown", event => {
    event.preventDefault();
    const startY = event.clientY;
    const startHeight = state.stageHeight;
    els.listResizeHandle.setPointerCapture(event.pointerId);

    const move = moveEvent => {
      const nextHeight = Math.max(220, Math.min(window.innerHeight - 220, startHeight + moveEvent.clientY - startY));
      state.stageHeight = nextHeight;
      applyStageLayout();
      redrawActivePreview();
    };
    const up = () => {
      els.listResizeHandle.removeEventListener("pointermove", move);
      els.listResizeHandle.removeEventListener("pointerup", up);
      saveState();
    };
    els.listResizeHandle.addEventListener("pointermove", move);
    els.listResizeHandle.addEventListener("pointerup", up);
  });

  els.stageSplitter.addEventListener("pointerdown", event => {
    event.preventDefault();
    const rect = els.assetStage.getBoundingClientRect();
    els.stageSplitter.setPointerCapture(event.pointerId);

    const move = moveEvent => {
      const x = moveEvent.clientX - rect.left;
      const nextSplit = Math.max(25, Math.min(75, (x / rect.width) * 100));
      state.previewSplit = nextSplit;
      applyStageLayout();
      redrawActivePreview();
    };
    const up = () => {
      els.stageSplitter.removeEventListener("pointermove", move);
      els.stageSplitter.removeEventListener("pointerup", up);
      saveState();
    };
    els.stageSplitter.addEventListener("pointermove", move);
    els.stageSplitter.addEventListener("pointerup", up);
  });
}

function redrawActivePreview() {
  const asset = state.assets.find(item => item.id === state.activeId);
  const canvas = els.previewPane.querySelector("canvas");
  if (asset && canvas) drawModelPreview(asset, canvas, getModelRotation(asset.id));
}

function renderFilters() {
  const types = ["all", "image", "audio", "model"];
  const tags = ["all", ...new Set(state.assets.flatMap(asset => asset.tags))].sort();
  renderFilterButtons(els.typeFilters, types, state.typeFilter, value => {
    state.typeFilter = value;
    render();
  });
  renderFilterButtons(els.tagFilters, tags, state.tagFilter, value => {
    state.tagFilter = value;
    render();
  });
}

function renderSourceFolders() {
  const sources = sourceSummaries();
  els.sourceFolders.replaceChildren();
  if (!sources.length) {
    const empty = document.createElement("p");
    empty.className = "source-empty";
    empty.textContent = "No folders imported.";
    els.sourceFolders.append(empty);
    return;
  }

  sources.forEach(source => {
    const row = document.createElement("div");
    row.className = "source-row";
    row.innerHTML = `<div><strong>${escapeHtml(source.name)}</strong><span>${source.count} assets</span></div>`;
    const removeButton = document.createElement("button");
    removeButton.type = "button";
    removeButton.className = "danger";
    removeButton.textContent = "Remove";
    removeButton.addEventListener("click", () => removeSourceFolder(source.name));
    row.append(removeButton);
    els.sourceFolders.append(row);
  });
}

function sourceSummaries() {
  const counts = new Map();
  state.assets.forEach(asset => {
    const name = asset.sourceFolder || getSourceFolder(asset.path, "Unknown");
    asset.sourceFolder = name;
    counts.set(name, (counts.get(name) || 0) + 1);
  });
  state.sources = state.sources.filter(source => counts.has(source.name));
  counts.forEach((count, name) => upsertSource(name, name));
  return [...counts.entries()]
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

function upsertSource(name, label = name) {
  if (!name || state.sources.some(source => source.name === name)) return;
  state.sources.push({ name, label, addedAt: Date.now() });
}

function removeSourceFolder(sourceName) {
  const count = state.assets.filter(asset => asset.sourceFolder === sourceName).length;
  if (!count) return;
  const confirmed = confirm(`Remove source folder "${sourceName}" and its ${count} cataloged asset${count === 1 ? "" : "s"} from this browser?`);
  if (!confirmed) return;

  const removedIds = new Set(state.assets.filter(asset => asset.sourceFolder === sourceName).map(asset => asset.id));
  state.assets = state.assets.filter(asset => asset.sourceFolder !== sourceName);
  state.sources = state.sources.filter(source => source.name !== sourceName);
  removedIds.forEach(id => {
    state.selectedIds.delete(id);
    delete state.modelRotations[id];
  });
  state.projects.forEach(project => {
    project.assetIds = project.assetIds.filter(id => !removedIds.has(id));
    project.copiedAssetIds = project.copiedAssetIds.filter(id => !removedIds.has(id));
  });
  if (removedIds.has(state.activeId)) {
    state.activeId = state.assets[0]?.id || null;
  }
  saveState();
  render();
}

function renderFilterButtons(container, values, activeValue, onSelect) {
  container.replaceChildren();
  values.forEach(value => {
    const button = document.createElement("button");
    button.textContent = value;
    button.classList.toggle("active", value === activeValue);
    button.addEventListener("click", () => onSelect(value));
    container.append(button);
  });
}

function renderAssets() {
  const assets = visibleAssets();
  els.emptyState.hidden = state.assets.length > 0;
  els.assetGroups.replaceChildren();

  const total = state.assets.length;
  const selected = state.selectedIds.size;
  const ignored = state.assets.filter(asset => asset.ignored).length;
  const importText = state.lastImport
    ? ` · last import ${state.lastImport.cataloged}/${state.lastImport.scanned} cataloged`
    : "";
  els.summary.textContent = `${assets.length} shown · ${total} cataloged · ${selected} selected · ${ignored} ignored${importText}`;

  const groups = groupAssets(assets);
  for (const [name, groupAssets] of groups) {
    const group = document.createElement("section");
    group.className = "group";
    group.innerHTML = `<h3>${escapeHtml(name)} (${groupAssets.length})</h3>`;
    const grid = document.createElement("div");
    grid.className = "asset-grid";
    groupAssets.forEach(asset => grid.append(renderAssetCard(asset)));
    group.append(grid);
    els.assetGroups.append(group);
  }
}

function setScanStatus(status) {
  state.scanStatus = status;
  renderScanStatus();
  const busy = !!status && !status.label.startsWith("Finished");
  els.scanButton.disabled = busy;
  els.folderInput.disabled = busy;
}

function renderScanStatus() {
  if (!state.scanStatus) {
    els.scanStatus.hidden = true;
    els.scanStatus.replaceChildren();
    return;
  }
  els.scanStatus.hidden = false;
  els.scanStatus.innerHTML = `<strong>${escapeHtml(state.scanStatus.label)}</strong><span>${escapeHtml(state.scanStatus.detail || "")}</span>`;
}

function yieldToUi() {
  return new Promise(resolve => setTimeout(resolve, 0));
}

function groupAssets(assets) {
  if (state.view === "flat") return [["All assets", assets]];
  const map = new Map();
  for (const asset of assets) {
    const keys = state.view === "tag" ? asset.tags : [state.view === "folder" ? asset.folder : asset.type];
    for (const key of keys) {
      if (!map.has(key)) map.set(key, []);
      map.get(key).push(asset);
    }
  }
  return [...map.entries()].sort(([a], [b]) => a.localeCompare(b));
}

function renderAssetCard(asset) {
  const node = els.template.content.firstElementChild.cloneNode(true);
  node.classList.toggle("active", asset.id === state.activeId);
  node.classList.toggle("ignored", asset.ignored);
  node.querySelector(".select-input").checked = state.selectedIds.has(asset.id);
  node.querySelector(".ignore-input").checked = asset.ignored;
  node.querySelector(".asset-name").textContent = asset.name;
  node.querySelector(".asset-path").textContent = asset.path;

  const thumb = node.querySelector(".thumb");
  renderThumb(asset, thumb);

  const tags = node.querySelector(".asset-tags");
  asset.tags.slice(0, 4).forEach(tag => tags.append(tagNode(tag)));
  if (asset.ignored) tags.append(tagNode("ignored", "ignored"));

  node.addEventListener("click", event => {
    if (event.target.matches("input")) return;
    state.activeId = asset.id;
    render();
  });
  node.querySelector(".select-input").addEventListener("change", event => {
    if (event.target.checked) state.selectedIds.add(asset.id);
    else state.selectedIds.delete(asset.id);
    render();
  });
  node.querySelector(".ignore-input").addEventListener("change", event => {
    setIgnoredFromItem(asset.id, event.target.checked);
  });
  return node;
}

function setIgnoredFromItem(assetId, ignored) {
  const affectedIds = state.selectedIds.size > 1 && state.selectedIds.has(assetId)
    ? state.selectedIds
    : new Set([assetId]);

  state.assets.forEach(asset => {
    if (affectedIds.has(asset.id)) asset.ignored = ignored;
  });
  render();
}

function renderThumb(asset, container) {
  container.replaceChildren();
  if (asset.type === "image") {
    const img = document.createElement("img");
    img.src = asset.previewUrl;
    img.alt = asset.name;
    container.append(img);
  } else if (asset.type === "audio") {
    container.textContent = "AUDIO";
  } else if (asset.type === "model" && ["obj", "fbx"].includes(asset.ext)) {
    const canvas = document.createElement("canvas");
    container.append(canvas);
    drawModelPreview(asset, canvas);
  } else if (asset.type === "model") {
    container.textContent = asset.ext.toUpperCase();
  }
}

function tagNode(label, className = "") {
  const span = document.createElement("span");
  span.className = `tag ${className}`.trim();
  span.textContent = label;
  return span;
}

function renderInspector() {
  const asset = state.assets.find(item => item.id === state.activeId);
  els.previewPane.replaceChildren();
  els.detailsPane.replaceChildren();
  if (!asset) {
    els.previewPane.innerHTML = `<p class="muted">Select an asset to inspect it.</p>`;
    return;
  }

  if (asset.type === "image") {
    const img = document.createElement("img");
    img.src = asset.previewUrl;
    img.alt = asset.name;
    els.previewPane.append(img);
  } else if (asset.type === "audio") {
    const audio = document.createElement("audio");
    audio.controls = true;
    audio.src = asset.previewUrl;
    els.previewPane.append(audio);
  } else if (asset.type === "model" && desktopApi?.isDesktop && ["fbx", "glb", "gltf"].includes(asset.ext)) {
    const stack = document.createElement("div");
    stack.className = "preview-stack";
    els.previewPane.append(stack);
    renderDesktopModelPreview(asset, stack);
  } else if (asset.type === "model" && ["obj", "fbx"].includes(asset.ext)) {
    const stack = document.createElement("div");
    stack.className = "preview-stack";
    const canvas = document.createElement("canvas");
    stack.append(canvas);
    stack.append(renderModelControls(asset, canvas));
    els.previewPane.append(stack);
    drawModelPreview(asset, canvas, getModelRotation(asset.id));
    bindModelDrag(asset, canvas);
    bindResponsivePreview(asset, canvas);
  } else {
    els.previewPane.innerHTML = `<p class="muted">${asset.ext.toUpperCase()} model preview will be added in the desktop build.</p>`;
  }

  [
    ["Name", asset.name],
    ["Path", asset.path],
    ["Source Folder", asset.sourceFolder || "Unknown"],
    ["Type", asset.type],
    ["Size", formatBytes(asset.size)],
    ["Modified", new Date(asset.lastModified).toLocaleString()]
  ].forEach(([label, value]) => {
    const row = document.createElement("div");
    row.className = "detail-row";
    row.innerHTML = `<span>${label}</span>${escapeHtml(value)}`;
    els.detailsPane.append(row);
  });

  const tagSection = document.createElement("div");
  tagSection.className = "detail-row";
  tagSection.innerHTML = "<span>Tags</span>";
  const tagList = document.createElement("div");
  tagList.className = "detail-tags";
  if (asset.tags.length) {
    asset.tags.forEach(tag => tagList.append(removableTagNode(asset, tag)));
  } else {
    tagList.append(tagNode("none"));
  }
  tagSection.append(tagList);
  els.detailsPane.append(tagSection);

  const editor = document.createElement("div");
  editor.className = "tag-editor";
  editor.innerHTML = `<input type="text" placeholder="Add tag" /><button>Add</button>`;
  const addTag = () => {
    const value = editor.querySelector("input").value.trim().toLowerCase();
    if (value && !asset.tags.includes(value)) asset.tags.push(value);
    editor.querySelector("input").value = "";
    render();
  };
  editor.querySelector("button").addEventListener("click", addTag);
  editor.querySelector("input").addEventListener("keydown", event => {
    if (event.key === "Enter") addTag();
  });
  els.detailsPane.append(editor);
}

async function renderDesktopModelPreview(asset, container) {
  container.innerHTML = `<p class="muted">Loading ${escapeHtml(asset.ext.toUpperCase())} model...</p>`;
  try {
    const viewer = await import("./model-viewer.mjs");
    await viewer.renderDesktopModel({ asset, container, desktopApi });
  } catch (error) {
    console.error(error);
    container.innerHTML = `<p class="muted">${escapeHtml(asset.ext.toUpperCase())} preview failed: ${escapeHtml(error.message || "unknown error")}</p>`;
  }
}

function removableTagNode(asset, label) {
  const button = document.createElement("button");
  button.className = "tag removable";
  button.type = "button";
  button.textContent = `${label} ×`;
  button.title = `Remove ${label}`;
  button.addEventListener("click", () => {
    asset.tags = asset.tags.filter(tag => tag !== label);
    if (state.tagFilter === label) state.tagFilter = "all";
    render();
  });
  return button;
}

function getModelRotation(assetId) {
  return state.modelRotations[assetId] || 0;
}

function setModelRotation(assetId, rotation, canvas, file) {
  const normalized = ((rotation % 360) + 360) % 360;
  state.modelRotations[assetId] = normalized;
  const asset = state.assets.find(item => item.id === assetId);
  if (asset) drawModelPreview(asset, canvas, normalized);
}

function renderModelControls(asset, canvas) {
  const controls = document.createElement("label");
  controls.className = "model-controls";
  controls.innerHTML = `<span>Rotate</span><input type="range" min="0" max="359" value="${getModelRotation(asset.id)}" />`;
  const input = controls.querySelector("input");
  input.addEventListener("input", event => {
    setModelRotation(asset.id, Number(event.target.value), canvas);
  });
  return controls;
}

function bindModelDrag(asset, canvas) {
  let dragging = false;
  let lastX = 0;

  canvas.addEventListener("pointerdown", event => {
    dragging = true;
    lastX = event.clientX;
    canvas.setPointerCapture(event.pointerId);
  });

  canvas.addEventListener("pointermove", event => {
    if (!dragging) return;
    const delta = event.clientX - lastX;
    lastX = event.clientX;
    setModelRotation(asset.id, getModelRotation(asset.id) + delta, canvas);
  });

  canvas.addEventListener("pointerup", () => {
    dragging = false;
  });

  canvas.addEventListener("pointercancel", () => {
    dragging = false;
  });
}

async function drawModelPreview(asset, canvas, rotation = 25) {
  resizeCanvasToDisplaySize(canvas);
  const context = canvas.getContext("2d");
  context.clearRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = "#f1f4f9";
  context.fillRect(0, 0, canvas.width, canvas.height);

  try {
    const geometry = asset.ext === "fbx" ? await parseFbxFile(asset.file) : parseObj(await asset.file.text());
    const { vertices, faces, unsupportedReason } = geometry;
    if (unsupportedReason) {
      drawModelMessage(context, canvas.width, canvas.height, unsupportedReason);
      return;
    }
    drawWireframe(context, vertices, faces, canvas.width, canvas.height, rotation);
  } catch {
    drawModelMessage(context, canvas.width, canvas.height, `${asset.ext.toUpperCase()} preview unavailable`);
  }
}

async function parseFbxFile(file) {
  const buffer = await file.arrayBuffer();
  if (isBinaryFbx(buffer)) return parseBinaryFbx(buffer);
  return parseFbx(new TextDecoder("utf-8").decode(buffer));
}

function isBinaryFbx(buffer) {
  const header = new TextDecoder("ascii").decode(buffer.slice(0, 18));
  return header.startsWith("Kaydara FBX Binary");
}

function resizeCanvasToDisplaySize(canvas) {
  const rect = canvas.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  const width = Math.max(1, Math.round(rect.width * ratio));
  const height = Math.max(1, Math.round(rect.height * ratio));
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }
}

function bindResponsivePreview(asset, canvas) {
  if (typeof ResizeObserver === "undefined") {
    window.addEventListener("resize", () => drawModelPreview(asset, canvas, getModelRotation(asset.id)), { passive: true });
    return;
  }

  const observer = new ResizeObserver(() => {
    drawModelPreview(asset, canvas, getModelRotation(asset.id));
  });
  observer.observe(canvas);
}

function parseObj(text) {
  const vertices = [];
  const faces = [];
  for (const line of text.split(/\r?\n/)) {
    const parts = line.trim().split(/\s+/);
    if (parts[0] === "v") vertices.push(parts.slice(1, 4).map(Number));
    if (parts[0] === "f") faces.push(parts.slice(1).map(part => Number(part.split("/")[0]) - 1));
  }
  return { vertices, faces };
}

function parseFbx(text) {
  if (text.startsWith("Kaydara FBX Binary")) {
    return {
      vertices: [],
      faces: [],
      unsupportedReason: "Binary FBX geometry could not be read"
    };
  }

  const verticesBlock = readFbxNumberArray(text, "Vertices");
  const indicesBlock = readFbxNumberArray(text, "PolygonVertexIndex");
  if (!verticesBlock.length || !indicesBlock.length) {
    return {
      vertices: [],
      faces: [],
      unsupportedReason: "FBX geometry not found"
    };
  }

  const vertices = [];
  for (let index = 0; index < verticesBlock.length; index += 3) {
    vertices.push([verticesBlock[index], verticesBlock[index + 1], verticesBlock[index + 2]]);
  }

  const faces = [];
  let face = [];
  indicesBlock.forEach(rawIndex => {
    if (rawIndex < 0) {
      face.push(Math.abs(rawIndex) - 1);
      if (face.length > 1) faces.push(face);
      face = [];
    } else {
      face.push(rawIndex);
    }
  });

  return { vertices, faces };
}

function parseBinaryFbx(buffer) {
  const view = new DataView(buffer);
  const version = view.getUint32(23, true);
  const largeOffsets = version >= 7500;
  let foundVertices = null;
  let foundIndices = null;
  let unsupportedReason = "";

  function readOffset(offset) {
    if (!largeOffsets) return [view.getUint32(offset, true), offset + 4];
    const low = view.getUint32(offset, true);
    const high = view.getUint32(offset + 4, true);
    return [high * 2 ** 32 + low, offset + 8];
  }

  function readArray(type, offset) {
    const length = view.getUint32(offset, true);
    const encoding = view.getUint32(offset + 4, true);
    const byteLength = view.getUint32(offset + 8, true);
    let cursor = offset + 12;
    if (encoding !== 0) {
      unsupportedReason = "Compressed binary FBX arrays need the desktop renderer";
      return [[], cursor + byteLength];
    }

    const values = [];
    const readers = {
      f: [4, position => view.getFloat32(position, true)],
      d: [8, position => view.getFloat64(position, true)],
      i: [4, position => view.getInt32(position, true)],
      l: [8, position => Number(view.getBigInt64(position, true))],
      b: [1, position => view.getUint8(position)]
    };
    const reader = readers[type];
    if (!reader) return [values, cursor + byteLength];

    const [stride, read] = reader;
    for (let index = 0; index < length; index += 1) {
      values.push(read(cursor + index * stride));
    }
    return [values, cursor + byteLength];
  }

  function skipProperty(type, offset) {
    if ("fdilb".includes(type)) return offset + ({ f: 4, d: 8, i: 4, l: 8, b: 1 })[type];
    if (type === "Y") return offset + 2;
    if (type === "C") return offset + 1;
    if (type === "S" || type === "R") return offset + 4 + view.getUint32(offset, true);
    return offset;
  }

  function readNode(offset, limit) {
    let cursor = offset;
    while (cursor < limit) {
      let endOffset;
      [endOffset, cursor] = readOffset(cursor);
      let propCount;
      [propCount, cursor] = readOffset(cursor);
      let propListLength;
      [propListLength, cursor] = readOffset(cursor);
      const nameLength = view.getUint8(cursor);
      cursor += 1;

      if (!endOffset || endOffset <= cursor || nameLength === 0) return endOffset || limit;

      const name = new TextDecoder("ascii").decode(buffer.slice(cursor, cursor + nameLength));
      cursor += nameLength;

      let firstProperty = null;
      for (let index = 0; index < propCount; index += 1) {
        const type = String.fromCharCode(view.getUint8(cursor));
        cursor += 1;
        if ("fdilb".includes(type)) {
          const [values, nextOffset] = readArray(type, cursor);
          if (index === 0) firstProperty = values;
          cursor = nextOffset;
        } else {
          cursor = skipProperty(type, cursor);
        }
      }

      if (name === "Vertices" && firstProperty?.length) foundVertices = firstProperty;
      if (name === "PolygonVertexIndex" && firstProperty?.length) foundIndices = firstProperty;

      if (cursor < endOffset) readNode(cursor, endOffset);
      cursor = endOffset;
    }
    return cursor;
  }

  try {
    readNode(27, buffer.byteLength);
  } catch {
    return { vertices: [], faces: [], unsupportedReason: "Binary FBX parse failed" };
  }

  if (unsupportedReason) return { vertices: [], faces: [], unsupportedReason };
  if (!foundVertices?.length || !foundIndices?.length) {
    return { vertices: [], faces: [], unsupportedReason: "FBX geometry not found" };
  }
  return fbxArraysToGeometry(foundVertices, foundIndices);
}

function fbxArraysToGeometry(vertexValues, indexValues) {
  const vertices = [];
  for (let index = 0; index < vertexValues.length; index += 3) {
    vertices.push([vertexValues[index], vertexValues[index + 1], vertexValues[index + 2]]);
  }

  const faces = [];
  let face = [];
  indexValues.forEach(rawIndex => {
    if (rawIndex < 0) {
      face.push(Math.abs(rawIndex) - 1);
      if (face.length > 1) faces.push(face);
      face = [];
    } else {
      face.push(rawIndex);
    }
  });
  return { vertices, faces };
}

function readFbxNumberArray(text, key) {
  const match = text.match(new RegExp(`${key}:\\s*\\*?\\d*\\s*\\{[\\s\\S]*?a:\\s*([^}]*)\\}`, "i"));
  if (!match) return [];
  return match[1]
    .split(/[\s,]+/)
    .map(value => Number(value.trim()))
    .filter(value => Number.isFinite(value));
}

function drawModelMessage(context, width, height, message) {
  context.fillStyle = "#667085";
  context.font = "14px sans-serif";
  context.textAlign = "center";
  context.fillText(message, width / 2, height / 2);
}

function drawWireframe(context, vertices, faces, width, height, rotation) {
  if (!vertices.length) return;
  const radians = rotation * Math.PI / 180;
  const rotated = vertices.map(vertex => {
    const [x, y, z = 0] = vertex;
    const rx = x * Math.cos(radians) - z * Math.sin(radians);
    const rz = x * Math.sin(radians) + z * Math.cos(radians);
    return [rx, y, rz];
  });
  const xs = rotated.map(v => v[0]);
  const ys = rotated.map(v => v[1]);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const scale = Math.min(width / Math.max(1, maxX - minX), height / Math.max(1, maxY - minY)) * .72;
  const project = vertex => [
    width / 2 + (vertex[0] - (minX + maxX) / 2) * scale,
    height / 2 - (vertex[1] - (minY + maxY) / 2) * scale + vertex[2] * scale * .18
  ];

  context.strokeStyle = "#2458d3";
  context.lineWidth = 1.2;
  for (const face of faces.slice(0, 2200)) {
    context.beginPath();
    face.forEach((index, offset) => {
      const [x, y] = project(rotated[index] || [0, 0, 0]);
      if (offset === 0) context.moveTo(x, y);
      else context.lineTo(x, y);
    });
    context.closePath();
    context.stroke();
  }
}

async function copySelectedAssets() {
  const selected = state.assets.filter(asset => state.selectedIds.has(asset.id) && !asset.ignored);
  if (!selected.length) {
    alert("Select at least one non-ignored asset first.");
    return;
  }
  if (desktopApi?.isDesktop) {
    const project = getActiveProject();
    const result = await desktopApi.copyAssets({
      assetPaths: selected.map(asset => asset.nativePath).filter(Boolean),
      targetFolder: project?.rootFolder && project.rootFolder !== "Not set" ? project.rootFolder : null
    });
    if (result.canceled) return;
    if (project) {
      const copied = new Set(project.copiedAssetIds);
      const members = new Set(project.assetIds);
      selected.forEach(asset => {
        copied.add(asset.id);
        members.add(asset.id);
      });
      project.rootFolder = result.targetFolder || project.rootFolder;
      project.copiedAssetIds = [...copied];
      project.assetIds = [...members];
    }
    saveState();
    render();
    alert(`Copied ${result.copied} asset${result.copied === 1 ? "" : "s"}.`);
    return;
  }
  if (!window.showDirectoryPicker) {
    alert("Copying to a folder needs a browser with the File System Access API.");
    return;
  }

  try {
    const target = await window.showDirectoryPicker({ mode: "readwrite" });
    for (const asset of selected) {
      const writableFile = await target.getFileHandle(uniqueCopyName(asset), { create: true });
      const writable = await writableFile.createWritable();
      await writable.write(asset.file);
      await writable.close();
    }
    const project = getActiveProject();
    if (project) {
      const copied = new Set(project.copiedAssetIds);
      const members = new Set(project.assetIds);
      selected.forEach(asset => {
        copied.add(asset.id);
        members.add(asset.id);
      });
      project.copiedAssetIds = [...copied];
      project.assetIds = [...members];
    }
    saveState();
    render();
    alert(`Copied ${selected.length} asset${selected.length === 1 ? "" : "s"}.`);
  } catch (error) {
    if (error.name !== "AbortError") console.error(error);
  }
}

function uniqueCopyName(asset) {
  const folderHint = asset.folder.split("/").at(-1)?.replace(/[^a-z0-9_-]+/gi, "-") || "asset";
  return `${folderHint}-${asset.name}`;
}

function saveProject() {
  const name = els.projectName.value.trim();
  if (!name) return;
  const assetIds = [...state.selectedIds];
  const rootFolder = els.projectRoot.value.trim() || "Not set";
  const project = {
    id: `project-${Date.now()}`,
    name,
    rootFolder,
    assetIds,
    copiedAssetIds: assetIds,
    createdAt: Date.now()
  };
  state.projects.push(project);
  state.activeProjectId = project.id;
  els.projectName.value = "";
  els.projectRoot.value = "";
  loadProject(project.id);
  saveState();
}

function renderProjects() {
  els.projectList.replaceChildren();
  state.projects.forEach(project => {
    normalizeProject(project);
    const item = document.createElement("button");
    item.type = "button";
    item.className = "project-pill";
    item.classList.toggle("active", project.id === state.activeProjectId);
    item.innerHTML = `${escapeHtml(project.name)}<span>${project.assetIds.length} assets · ${project.rootFolder || "No root set"}</span>`;
    item.addEventListener("click", () => loadProject(project.id));
    els.projectList.append(item);
  });
}

function loadProject(projectId) {
  const project = state.projects.find(item => item.id === projectId);
  if (!project) return;
  normalizeProject(project);
  state.activeProjectId = project.id;
  state.selectedIds = new Set(project.assetIds);
  if (state.projectFilter !== "out") state.projectFilter = "in";
  const firstExisting = project.assetIds.find(id => state.assets.some(asset => asset.id === id));
  if (firstExisting) state.activeId = firstExisting;
  render();
}

function renderActiveProjectPanel() {
  const project = getActiveProject();
  if (!project) {
    els.activeProjectPanel.hidden = true;
    els.activeProjectPanel.replaceChildren();
    return;
  }

  normalizeProject(project);
  els.activeProjectPanel.hidden = false;
  els.activeProjectPanel.innerHTML = `
    <div><strong>${escapeHtml(project.name)}</strong><span>Loaded project</span></div>
    <div><strong>${escapeHtml(project.rootFolder || "Not set")}</strong><span>Root folder</span></div>
    <div><strong>${project.copiedAssetIds.length}</strong><span>Copied assets</span></div>
  `;

  const rootEditor = document.createElement("div");
  rootEditor.className = "root-editor";
  rootEditor.innerHTML = `<input type="text" value="${escapeHtml(project.rootFolder || "")}" aria-label="Project root folder" />`;

  const rootButton = document.createElement("button");
  rootButton.type = "button";
  rootButton.textContent = "Browse root";
  rootButton.addEventListener("click", () => browseActiveProjectRoot(rootEditor.querySelector("input")));
  rootEditor.append(rootButton);

  const saveRootButton = document.createElement("button");
  saveRootButton.type = "button";
  saveRootButton.textContent = "Save root";
  saveRootButton.addEventListener("click", () => {
    project.rootFolder = rootEditor.querySelector("input").value.trim() || "Not set";
    saveState();
    render();
  });
  rootEditor.append(saveRootButton);
  els.activeProjectPanel.append(rootEditor);

  const clearButton = document.createElement("button");
  clearButton.type = "button";
  clearButton.textContent = "Clear project";
  clearButton.addEventListener("click", () => {
    state.activeProjectId = null;
    state.projectFilter = "all";
    render();
  });
  els.activeProjectPanel.append(clearButton);

  const deleteButton = document.createElement("button");
  deleteButton.type = "button";
  deleteButton.className = "danger";
  deleteButton.textContent = "Delete project";
  deleteButton.addEventListener("click", () => deleteProject(project.id));
  els.activeProjectPanel.append(deleteButton);
}

async function browseActiveProjectRoot(input) {
  const project = getActiveProject();
  if (!project) return;

  if (desktopApi?.isDesktop) {
    const folder = await desktopApi.chooseFolder();
    if (!folder) return;
    project.rootFolder = folder;
    input.value = folder;
    saveState();
    render();
    return;
  }

  if (window.showDirectoryPicker) {
    try {
      const handle = await window.showDirectoryPicker({ mode: "read" });
      project.rootFolder = handle.name;
      input.value = handle.name;
      saveState();
      render();
      return;
    } catch (error) {
      if (error.name === "AbortError") return;
      input.focus();
      return;
    }
  }
  input.focus();
}

function deleteProject(projectId) {
  const project = state.projects.find(item => item.id === projectId);
  if (!project) return;
  const confirmed = confirm(`Delete project "${project.name}"? This removes its saved tracking info only.`);
  if (!confirmed) return;

  state.projects = state.projects.filter(item => item.id !== projectId);
  if (state.activeProjectId === projectId) {
    state.activeProjectId = null;
    state.projectFilter = "all";
    state.selectedIds.clear();
  }
  saveState();
  render();
}

function getActiveProject() {
  const project = state.projects.find(item => item.id === state.activeProjectId);
  if (project) normalizeProject(project);
  return project || null;
}

function isAssetInProject(assetId, project = getActiveProject()) {
  return !!project && project.assetIds.includes(assetId);
}

function normalizeProject(project) {
  project.id ||= `project-${project.createdAt || Date.now()}-${project.name}`;
  project.rootFolder ||= "Not set";
  project.assetIds ||= [];
  project.copiedAssetIds ||= [...project.assetIds];
}

function loadState() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
    state.projects = saved.projects || [];
    state.projects.forEach(normalizeProject);
    state.activeProjectId = saved.activeProjectId || null;
    state.projectFilter = saved.projectFilter || "all";
    state.modelRotations = saved.modelRotations || {};
    state.sources = saved.sources || [];
    state.hideIgnored = saved.hideIgnored ?? true;
  } catch {
    state.projects = [];
  }
  state.assets = state.assets.map(hydrateDesktopAsset);
}

function saveState() {
  const metadata = {
    activeProjectId: state.activeProjectId,
    hideIgnored: state.hideIgnored,
    modelRotations: state.modelRotations,
    projectFilter: state.projectFilter,
    projects: state.projects,
    sources: state.sources
  };
  localStorage.setItem(STORAGE_KEY, JSON.stringify(metadata));
}

function extension(name) {
  return name.includes(".") ? name.split(".").pop().toLowerCase() : "";
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB"];
  let value = bytes / 1024;
  let unit = units.shift();
  while (value >= 1024 && units.length) {
    value /= 1024;
    unit = units.shift();
  }
  return `${value.toFixed(value >= 10 ? 1 : 2)} ${unit}`;
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, char => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#039;"
  })[char]);
}

window.assetAtlasDebug = {
  state,
  addFiles,
  render
};
