import { readFileSync, writeFileSync, mkdirSync, cpSync, existsSync, rmSync, renameSync } from "node:fs";
import { join, dirname } from "node:path";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");
const SRC_DIR = join(ROOT, "Extensions", "Shared");
const FIREFOX_SRC_DIR = join(ROOT, "Extensions", "Shared", "firefox");
const ICONS_DIR = join(ROOT, "Extensions", "Shared", "icons");
const DIST_DIR = join(ROOT, "dist");

const pkg = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
const VERSION = pkg.version;

const BROWSERS = ["chrome", "firefox", "edge"];

// Development public key for deterministic Chrome/Edge extension ID.
// This key pins the extension to a stable ID during local development and
// unpacked loading. When the extension is published to the Chrome Web Store
// or Edge Add-ons, the store assigns its own key — remove this field from
// the published manifest and update allowed_origins in the Mac app's
// NativeMessagingRegistration.swift with the store-assigned extension ID.
const CHROME_EXTENSION_KEY =
  "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsDoiCM4T2Ac2b5TfcenK" +
  "Y6qbON5EBkyI9RsdIqQFT0ZL4GhZv3z/tO+JvdIHgYD3fqnsVfSl5YJQH2r7fzO" +
  "z6b6+0bJ7paCnE2TNKIpNFR9XyLFtQory8wUwlgNx11ByW4l8nRkFKPED5xs6KzW" +
  "zN8mb1qD2bHxFy3OFd8DGxdoIyoHu287PHX4UqU/5deTv3QhVro3hHf5szrV9dtJ" +
  "haVfA9nhl2JX6YN/PALW7jsachtZwkpiGvmk8yPD+TTvWoNFU4LABrOl16uRB2e8T" +
  "3s2PVEx3LZ5nmh1q54Ow4ozvWwG8i3XnciFhDjPsy8C/mDuz0EbVBwuK4/fzgkXT" +
  "6QIDAQAB";

const CHROME_EXTENSION_ID = "iomcmbjooojnddcbbillnngpdmionlmo";

const SOURCE_FILES = [
  "background.js",
  "popup.html",
  "popup.js",
  "popup.css",
];

const ICON_FILES = ["icon16.png", "icon48.png", "icon128.png"];

function baseManifest() {
  return {
    manifest_version: 3,
    version: VERSION,
    description:
      "Intercept downloads and send them to Mac Download Manager for accelerated downloading",
    permissions: ["downloads", "webRequest", "nativeMessaging", "storage"],
    host_permissions: ["<all_urls>"],
    action: {
      default_popup: "popup.html",
      default_icon: {
        16: "icons/icon16.png",
        48: "icons/icon48.png",
        128: "icons/icon128.png",
      },
    },
    icons: {
      16: "icons/icon16.png",
      48: "icons/icon48.png",
      128: "icons/icon128.png",
    },
  };
}

function chromeManifest() {
  const manifest = baseManifest();
  manifest.name = "Mac Download Manager";
  manifest.key = CHROME_EXTENSION_KEY;
  manifest.background = { service_worker: "background.js" };
  return manifest;
}

function edgeManifest() {
  const manifest = baseManifest();
  manifest.name = "Mac Download Manager for Edge";
  manifest.description =
    "Intercept downloads and send them to Mac Download Manager for accelerated downloading (Edge)";
  manifest.key = CHROME_EXTENSION_KEY;
  manifest.background = { service_worker: "background.js" };
  return manifest;
}

function firefoxManifest() {
  const manifest = baseManifest();
  manifest.name = "Mac Download Manager";
  manifest.background = { scripts: ["background.js"] };
  manifest.browser_specific_settings = {
    gecko: {
      id: "macdownloadmanager@example.com",
      strict_min_version: "109.0",
    },
  };
  return manifest;
}

const MANIFEST_GENERATORS = {
  chrome: chromeManifest,
  firefox: firefoxManifest,
  edge: edgeManifest,
};

function clean() {
  if (existsSync(DIST_DIR)) {
    rmSync(DIST_DIR, { recursive: true });
  }
}

function buildBrowser(browser) {
  const outDir = join(DIST_DIR, browser);
  const iconsOutDir = join(outDir, "icons");

  mkdirSync(iconsOutDir, { recursive: true });

  for (const file of SOURCE_FILES) {
    const overridePath = browser === "firefox" ? join(FIREFOX_SRC_DIR, file) : null;
    const srcPath = overridePath && existsSync(overridePath) ? overridePath : join(SRC_DIR, file);
    cpSync(srcPath, join(outDir, file));
  }

  for (const icon of ICON_FILES) {
    cpSync(join(ICONS_DIR, icon), join(iconsOutDir, icon));
  }

  const manifest = MANIFEST_GENERATORS[browser]();
  writeFileSync(
    join(outDir, "manifest.json"),
    JSON.stringify(manifest, null, 2) + "\n"
  );

  console.log(`Built ${browser} extension in dist/${browser}/`);
}

function browserLabel(browser) {
  return browser.charAt(0).toUpperCase() + browser.slice(1);
}

function packageBrowser(browser) {
  const sourceDir = join(DIST_DIR, browser);
  const artifactsDir = DIST_DIR;
  const filename = `MacDownloadManager-${browserLabel(browser)}Extension-${VERSION}.zip`;

  execSync(
    `web-ext build --source-dir "${sourceDir}" --artifacts-dir "${artifactsDir}" --overwrite-dest --filename "${filename}"`,
    { stdio: "pipe" }
  );

  // web-ext lowercases the filename; rename to the expected mixed-case name
  const lowered = join(artifactsDir, filename.toLowerCase());
  const expected = join(artifactsDir, filename);
  if (lowered !== expected && existsSync(lowered)) {
    renameSync(lowered, expected);
  }

  console.log(`Packaged dist/${filename}`);
}

function build() {
  console.log(`Building extensions v${VERSION}...`);

  clean();

  for (const browser of BROWSERS) {
    buildBrowser(browser);
  }

  for (const browser of BROWSERS) {
    packageBrowser(browser);
  }

  console.log("Build complete.");
}

build();
