import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { FBXLoader } from "three/addons/loaders/FBXLoader.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";

export async function renderDesktopModel({ asset, container, desktopApi }) {
  if (container.__assetAtlasCleanup) container.__assetAtlasCleanup();
  container.replaceChildren();

  const canvas = document.createElement("canvas");
  canvas.className = "three-canvas";
  container.append(canvas);

  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
  renderer.setClearColor(0xf1f4f9, 1);
  renderer.setPixelRatio(window.devicePixelRatio || 1);

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(45, 1, 0.01, 100000);
  const controls = new OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true;

  const ambient = new THREE.HemisphereLight(0xffffff, 0x667085, 2.4);
  scene.add(ambient);
  const key = new THREE.DirectionalLight(0xffffff, 1.6);
  key.position.set(3, 5, 4);
  scene.add(key);

  const model = await loadModel(asset, desktopApi);
  scene.add(model);
  frameModel(model, camera, controls);

  const resize = () => {
    const rect = container.getBoundingClientRect();
    const width = Math.max(1, Math.floor(rect.width));
    const height = Math.max(1, Math.floor(rect.height));
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
  };

  const observer = new ResizeObserver(resize);
  observer.observe(container);
  resize();

  let active = true;
  const animate = () => {
    if (!active) return;
    controls.update();
    renderer.render(scene, camera);
    requestAnimationFrame(animate);
  };
  animate();

  container.__assetAtlasCleanup = () => {
    active = false;
    observer.disconnect();
    controls.dispose();
    renderer.dispose();
    disposeObject(model);
    container.__assetAtlasCleanup = null;
  };
}

async function loadModel(asset, desktopApi) {
  const buffer = await desktopApi.readBinary(asset.nativePath);
  const manager = createLocalAssetManager(asset);
  const resourcePath = getAssetDirectoryUrl(asset);
  if (asset.ext === "fbx") {
    return new FBXLoader(manager).parse(buffer, resourcePath);
  }

  if (asset.ext === "glb" || asset.ext === "gltf") {
    return await new Promise((resolve, reject) => {
      const loader = new GLTFLoader(manager);
      loader.parse(buffer, resourcePath, gltf => resolve(gltf.scene), reject);
    });
  }

  throw new Error(`${asset.ext.toUpperCase()} is not handled by the desktop model viewer yet.`);
}

function createLocalAssetManager(asset) {
  const manager = new THREE.LoadingManager();
  manager.setURLModifier(url => resolveLocalReference(url, asset));
  return manager;
}

function resolveLocalReference(url, asset) {
  if (!url || url.startsWith("data:") || url.startsWith("blob:") || /^https?:\/\//i.test(url)) return url;
  if (url.startsWith("file:")) return url;

  const normalized = url.replaceAll("\\", "/").replace(/^\.\/+/, "");
  if (/^[a-z]:\//i.test(normalized)) return windowsPathToFileUrl(normalized);

  try {
    return new URL(normalized, getAssetDirectoryUrl(asset)).href;
  } catch {
    return url;
  }
}

function getAssetDirectoryUrl(asset) {
  const sourceUrl = asset.previewUrl || windowsPathToFileUrl(asset.nativePath);
  return sourceUrl.slice(0, sourceUrl.lastIndexOf("/") + 1);
}

function windowsPathToFileUrl(filePath) {
  const normalized = filePath.replaceAll("\\", "/");
  const prefixed = normalized.startsWith("/") ? normalized : `/${normalized}`;
  return `file://${prefixed.split("/").map(encodeURIComponent).join("/")}`;
}

function frameModel(model, camera, controls) {
  const box = new THREE.Box3().setFromObject(model);
  const size = box.getSize(new THREE.Vector3());
  const center = box.getCenter(new THREE.Vector3());
  const maxSize = Math.max(size.x, size.y, size.z, 1);
  const distance = maxSize / (2 * Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2));

  model.position.sub(center);
  camera.position.set(distance * 0.75, distance * 0.55, distance * 1.3);
  camera.near = Math.max(distance / 1000, 0.01);
  camera.far = distance * 1000;
  camera.updateProjectionMatrix();
  controls.target.set(0, 0, 0);
  controls.update();
}

function disposeObject(object) {
  object.traverse(child => {
    if (child.geometry) child.geometry.dispose();
    if (child.material) {
      const materials = Array.isArray(child.material) ? child.material : [child.material];
      materials.forEach(material => {
        Object.values(material).forEach(value => {
          if (value?.isTexture) value.dispose();
        });
        material.dispose();
      });
    }
  });
}
