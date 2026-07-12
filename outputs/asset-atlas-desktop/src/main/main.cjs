const { app, BrowserWindow, dialog, ipcMain } = require("electron");
const fs = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const IMAGE_EXTS = new Set(["png", "jpg", "jpeg", "webp", "gif", "bmp"]);
const AUDIO_EXTS = new Set(["wav", "mp3", "flac", "ogg", "midi", "mid"]);
const MODEL_EXTS = new Set(["obj", "fbx", "gltf", "glb", "blend", "dae", "stl"]);

let mainWindow;

async function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1320,
    height: 860,
    minWidth: 980,
    minHeight: 680,
    show: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      preload: path.join(__dirname, "preload.cjs")
    }
  });

  mainWindow.once("ready-to-show", () => mainWindow.show());
  await mainWindow.loadFile(path.join(__dirname, "..", "renderer", "index.html"));
}

app.whenReady().then(createWindow);

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});

ipcMain.handle("folders:scan", async () => {
  const skipped = { unsupported: 0, binaryObj: 0, inaccessible: 0 };
  try {
    sendScanProgress({ label: "Waiting for folder", detail: "Choose an asset folder to scan" });
    const selection = await dialog.showOpenDialog(mainWindow, {
      title: "Select asset folder",
      properties: ["openDirectory"]
    });
    if (selection.canceled) return { canceled: true, assets: [], sources: [], skipped };

    const assets = [];

    for (const rootPath of selection.filePaths) {
      const sourceName = path.basename(rootPath);
      sendScanProgress({ label: `Scanning ${sourceName}`, detail: "Checking nested folders" });
      const files = await walkFiles(rootPath, skipped);
      for (let index = 0; index < files.length; index += 1) {
        const filePath = files[index];
        const asset = await toAsset(filePath, rootPath, sourceName);
        if (asset?.inaccessible) {
          skipped.inaccessible += 1;
          continue;
        }
        if (!asset) {
          skipped.unsupported += 1;
          continue;
        }
        if (asset.ext === "obj" && await isLikelyBinaryFile(filePath)) {
          skipped.binaryObj += 1;
          continue;
        }
        assets.push(asset);
        if (index % 100 === 0 || index === files.length - 1) {
          sendScanProgress({
            label: `Cataloging ${sourceName}`,
            detail: `${index + 1} of ${files.length} files checked · ${assets.length} assets`
          });
        }
      }
    }

    sendScanProgress({ label: "Scan complete", detail: `${assets.length} assets cataloged` });
    return {
      canceled: false,
      assets,
      sources: selection.filePaths.map(rootPath => ({
        name: path.basename(rootPath),
        rootPath
      })),
      skipped
    };
  } catch (error) {
    console.error("Asset scan failed", error);
    return {
      canceled: false,
      assets: [],
      sources: [],
      skipped,
      error: error?.message || String(error)
    };
  }
});

ipcMain.handle("folders:choose", async () => {
  const selection = await dialog.showOpenDialog(mainWindow, {
    title: "Select folder",
    properties: ["openDirectory"]
  });
  if (selection.canceled) return null;
  return selection.filePaths[0];
});

ipcMain.handle("assets:copy", async (_event, { assetPaths, targetFolder }) => {
  let destination = targetFolder;
  if (!destination) {
    const selection = await dialog.showOpenDialog(mainWindow, {
      title: "Select destination folder",
      properties: ["openDirectory", "createDirectory"]
    });
    if (selection.canceled) return { canceled: true, copied: 0, targetFolder: null };
    destination = selection.filePaths[0];
  }

  let copied = 0;
  for (const assetPath of assetPaths) {
    const targetPath = path.join(destination, path.basename(assetPath));
    await fs.copyFile(assetPath, targetPath);
    copied += 1;
  }
  return { canceled: false, copied, targetFolder: destination };
});

ipcMain.handle("assets:read-text", async (_event, filePath) => {
  return fs.readFile(filePath, "utf8");
});

ipcMain.handle("assets:read-binary", async (_event, filePath) => {
  const buffer = await fs.readFile(filePath);
  return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
});

async function walkFiles(rootPath, skipped, found = []) {
  let entries;
  try {
    entries = await fs.readdir(rootPath, { withFileTypes: true });
  } catch {
    skipped.inaccessible += 1;
    return found;
  }

  for (const entry of entries) {
    const entryPath = path.join(rootPath, entry.name);
    if (entry.isDirectory()) {
      await walkFiles(entryPath, skipped, found);
    } else if (entry.isFile()) {
      found.push(entryPath);
      if (found.length % 250 === 0) {
        sendScanProgress({ label: "Scanning folders", detail: `${found.length} files found` });
      }
    }
  }
  return found;
}

async function toAsset(filePath, rootPath, sourceName) {
  let stats;
  try {
    stats = await fs.stat(filePath);
  } catch {
    return { inaccessible: true };
  }

  const ext = path.extname(filePath).slice(1).toLowerCase();
  const type = getType(ext);
  if (type === "other") return null;

  const relativePath = path.relative(rootPath, filePath).replaceAll(path.sep, "/");
  const catalogPath = `${sourceName}/${relativePath}`;

  return {
    id: `${filePath}:${stats.size}:${stats.mtimeMs}`,
    name: path.basename(filePath),
    path: catalogPath,
    nativePath: filePath,
    folder: path.dirname(catalogPath).replaceAll(path.sep, "/"),
    sourceFolder: sourceName,
    sourceRoot: rootPath,
    ext,
    type,
    size: stats.size,
    lastModified: stats.mtimeMs,
    tags: inferTags(path.basename(filePath), catalogPath, type, ext),
    ignored: false,
    previewUrl: pathToFileURL(filePath).toString()
  };
}

function sendScanProgress(payload) {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  mainWindow.webContents.send("folders:scan-progress", payload);
}

function getType(ext) {
  if (IMAGE_EXTS.has(ext)) return "image";
  if (AUDIO_EXTS.has(ext)) return "audio";
  if (MODEL_EXTS.has(ext)) return "model";
  return "other";
}

function inferTags(name, assetPath, type, ext) {
  const words = `${name} ${assetPath}`
    .toLowerCase()
    .replace(/\.[^.]+$/, "")
    .split(/[^a-z0-9]+/)
    .filter(word => word.length > 2 && !["assets", "models", "images", "audio", "music", "textures"].includes(word));
  return [...new Set([type, ext, ...words.slice(0, 8)])];
}

async function isLikelyBinaryFile(filePath) {
  const handle = await fs.open(filePath, "r");
  try {
    const buffer = Buffer.alloc(4096);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    if (!bytesRead) return false;

    let suspicious = 0;
    for (let index = 0; index < bytesRead; index += 1) {
      const byte = buffer[index];
      if (byte === 0) return true;
      const textByte = byte === 9 || byte === 10 || byte === 13 || (byte >= 32 && byte <= 126) || byte >= 128;
      if (!textByte) suspicious += 1;
    }
    return suspicious / bytesRead > 0.08;
  } finally {
    await handle.close();
  }
}
