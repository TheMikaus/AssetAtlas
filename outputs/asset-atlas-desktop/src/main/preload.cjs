const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("assetAtlasDesktop", {
  isDesktop: true,
  scanFolders: () => ipcRenderer.invoke("folders:scan"),
  chooseFolder: () => ipcRenderer.invoke("folders:choose"),
  copyAssets: payload => ipcRenderer.invoke("assets:copy", payload),
  readText: filePath => ipcRenderer.invoke("assets:read-text", filePath),
  readBinary: filePath => ipcRenderer.invoke("assets:read-binary", filePath),
  onScanProgress: callback => {
    const listener = (_event, payload) => callback(payload);
    ipcRenderer.on("folders:scan-progress", listener);
    return () => ipcRenderer.removeListener("folders:scan-progress", listener);
  }
});
