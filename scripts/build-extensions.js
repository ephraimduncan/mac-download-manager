import { readFileSync, writeFileSync, mkdirSync, cpSync, existsSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");
const SRC_DIR = join(ROOT, "Extension", "src");
const ICONS_DIR = join(ROOT, "Extension", "icons");
const DIST_DIR = join(ROOT, "dist");

const pkg = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
const VERSION = pkg.version;

const BROWSERS = ["chrome", "firefox", "edge"];

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
  manifest.background = { service_worker: "background.js" };
  return manifest;
}

function edgeManifest() {
  const manifest = baseManifest();
  manifest.name = "Mac Download Manager for Edge";
  manifest.description =
    "Intercept downloads and send them to Mac Download Manager for accelerated downloading (Edge)";
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
    cpSync(join(SRC_DIR, file), join(outDir, file));
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

function packageBrowser(browser) {
  const sourceDir = join(DIST_DIR, browser);
  const artifactsDir = DIST_DIR;

  execSync(
    `web-ext build --source-dir "${sourceDir}" --artifacts-dir "${artifactsDir}" --overwrite-dest --filename "${browser}.zip"`,
    { stdio: "pipe" }
  );

  console.log(`Packaged dist/${browser}.zip`);
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
