import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");
const DIST = join(ROOT, "dist");

const BROWSERS = ["chrome", "firefox", "edge"];
const EXPECTED_FILES = [
  "manifest.json",
  "background.js",
  "popup.html",
  "popup.js",
  "popup.css",
  "icons/icon16.png",
  "icons/icon48.png",
  "icons/icon128.png",
];

before(() => {
  execSync("npm run build", { cwd: ROOT, stdio: "pipe" });
});

describe("build output structure", () => {
  for (const browser of BROWSERS) {
    it(`produces dist/${browser}/ directory`, () => {
      const dir = join(DIST, browser);
      assert.ok(existsSync(dir), `dist/${browser}/ should exist`);
      assert.ok(statSync(dir).isDirectory(), `dist/${browser}/ should be a directory`);
    });

    it(`dist/${browser}/ contains all expected files`, () => {
      for (const file of EXPECTED_FILES) {
        const filePath = join(DIST, browser, file);
        assert.ok(existsSync(filePath), `dist/${browser}/${file} should exist`);
      }
    });
  }

  for (const browser of BROWSERS) {
    it(`produces dist/${browser}.zip`, () => {
      const zipPath = join(DIST, `${browser}.zip`);
      assert.ok(existsSync(zipPath), `dist/${browser}.zip should exist`);
      assert.ok(statSync(zipPath).size > 0, `dist/${browser}.zip should not be empty`);
    });
  }
});

describe("manifest validity", () => {
  for (const browser of BROWSERS) {
    it(`dist/${browser}/manifest.json is valid JSON`, () => {
      const manifestPath = join(DIST, browser, "manifest.json");
      const content = readFileSync(manifestPath, "utf8");
      const manifest = JSON.parse(content);
      assert.ok(manifest, "manifest should parse as JSON");
    });
  }
});

describe("Chrome manifest", () => {
  let manifest;
  before(() => {
    manifest = JSON.parse(readFileSync(join(DIST, "chrome", "manifest.json"), "utf8"));
  });

  it("uses manifest_version 3", () => {
    assert.equal(manifest.manifest_version, 3);
  });

  it("has service_worker background", () => {
    assert.equal(manifest.background.service_worker, "background.js");
  });

  it("has required permissions", () => {
    const required = ["downloads", "webRequest", "nativeMessaging", "storage"];
    for (const perm of required) {
      assert.ok(manifest.permissions.includes(perm), `should have ${perm} permission`);
    }
  });

  it("has host_permissions <all_urls>", () => {
    assert.ok(manifest.host_permissions.includes("<all_urls>"));
  });

  it("has action with popup and icons", () => {
    assert.equal(manifest.action.default_popup, "popup.html");
    assert.ok(manifest.action.default_icon["16"]);
    assert.ok(manifest.action.default_icon["48"]);
    assert.ok(manifest.action.default_icon["128"]);
  });

  it("has top-level icons", () => {
    assert.ok(manifest.icons["16"]);
    assert.ok(manifest.icons["48"]);
    assert.ok(manifest.icons["128"]);
  });

  it("does not have background.scripts (Chrome uses service_worker only)", () => {
    assert.equal(manifest.background.scripts, undefined);
  });

  it("does not have browser_specific_settings (Chrome-only manifest)", () => {
    assert.equal(manifest.browser_specific_settings, undefined);
  });
});

describe("Chrome extension code", () => {
  let bgCode;
  let popupCode;
  let popupCss;
  let popupHtml;

  before(() => {
    bgCode = readFileSync(join(DIST, "chrome", "background.js"), "utf8");
    popupCode = readFileSync(join(DIST, "chrome", "popup.js"), "utf8");
    popupCss = readFileSync(join(DIST, "chrome", "popup.css"), "utf8");
    popupHtml = readFileSync(join(DIST, "chrome", "popup.html"), "utf8");
  });

  it("background.js uses onDeterminingFilename for download interception", () => {
    assert.ok(bgCode.includes("onDeterminingFilename"), "should use onDeterminingFilename");
  });

  it("background.js uses onSendHeaders for header caching", () => {
    assert.ok(bgCode.includes("onSendHeaders"), "should use onSendHeaders");
  });

  it("background.js connects via connectNative with correct host", () => {
    assert.ok(bgCode.includes('connectNative'), "should use connectNative");
    assert.ok(bgCode.includes('com.macdownloadmanager.helper'), "should use correct native host ID");
  });

  it("background.js shows badge for connection status", () => {
    assert.ok(bgCode.includes('setBadgeText'), "should set badge text");
    assert.ok(bgCode.includes('"!"'), "should show '!' when disconnected");
  });

  it("background.js supports auto-reconnect on disconnect", () => {
    assert.ok(bgCode.includes('onDisconnect'), "should handle disconnect");
    assert.ok(bgCode.includes('setTimeout'), "should auto-reconnect after timeout");
  });

  it("background.js caches Cookie, Authorization, Referer, User-Agent headers", () => {
    assert.ok(bgCode.includes('"cookie"'), "should cache cookie header");
    assert.ok(bgCode.includes('"authorization"'), "should cache authorization header");
    assert.ok(bgCode.includes('"referer"'), "should cache referer header");
    assert.ok(bgCode.includes('"user-agent"'), "should cache user-agent header");
  });

  it("popup.js loads/saves settings via chrome.storage.sync", () => {
    assert.ok(popupCode.includes("chrome.storage.sync.get"), "should load settings from sync");
    assert.ok(popupCode.includes("chrome.storage.sync.set"), "should save settings to sync");
  });

  it("popup.html has enable toggle", () => {
    assert.ok(popupHtml.includes('id="enabled"'), "should have enabled toggle");
    assert.ok(popupHtml.includes('type="checkbox"'), "should have checkbox input");
  });

  it("popup.html has file types input", () => {
    assert.ok(popupHtml.includes('id="fileTypes"'), "should have file types input");
  });

  it("popup.html has min size slider", () => {
    assert.ok(popupHtml.includes('id="minSize"'), "should have min size slider");
    assert.ok(popupHtml.includes('type="range"'), "should have range input");
  });

  it("popup.html has connection status indicator", () => {
    assert.ok(popupHtml.includes('id="statusDot"'), "should have status dot");
    assert.ok(popupHtml.includes('id="statusText"'), "should have status text");
  });

  it("popup.css supports dark mode via prefers-color-scheme", () => {
    assert.ok(popupCss.includes("prefers-color-scheme: dark"), "should have dark mode media query");
  });
});

describe("Firefox extension code", () => {
  let bgCode;
  let popupCode;

  before(() => {
    bgCode = readFileSync(join(DIST, "firefox", "background.js"), "utf8");
    popupCode = readFileSync(join(DIST, "firefox", "popup.js"), "utf8");
  });

  it("background.js uses browser.* namespace (not chrome.*)", () => {
    assert.ok(bgCode.includes("browser."), "should use browser.* namespace");
    assert.ok(!bgCode.includes("chrome."), "should not use chrome.* namespace");
  });

  it("background.js uses onCreated for download interception (not onDeterminingFilename)", () => {
    assert.ok(bgCode.includes("onCreated"), "should use onCreated");
    assert.ok(!bgCode.includes("onDeterminingFilename"), "should not use onDeterminingFilename");
  });

  it("background.js cancels and erases intercepted downloads", () => {
    assert.ok(bgCode.includes("downloads.cancel"), "should cancel downloads");
    assert.ok(bgCode.includes("downloads.erase"), "should erase downloads");
  });

  it("background.js uses browser.webRequest.onSendHeaders for header caching", () => {
    assert.ok(bgCode.includes("browser.webRequest.onSendHeaders"), "should use browser.webRequest.onSendHeaders");
  });

  it("background.js uses browser.runtime.connectNative for native messaging", () => {
    assert.ok(bgCode.includes("browser.runtime.connectNative"), "should use browser.runtime.connectNative");
    assert.ok(bgCode.includes("com.macdownloadmanager.helper"), "should use correct native host ID");
  });

  it("background.js shows badge for connection status", () => {
    assert.ok(bgCode.includes("setBadgeText"), "should set badge text");
    assert.ok(bgCode.includes('"!"'), "should show '!' when disconnected");
  });

  it("background.js supports auto-reconnect on disconnect", () => {
    assert.ok(bgCode.includes("onDisconnect"), "should handle disconnect");
    assert.ok(bgCode.includes("setTimeout"), "should auto-reconnect after timeout");
  });

  it("background.js caches Cookie, Authorization, Referer, User-Agent headers", () => {
    assert.ok(bgCode.includes('"cookie"'), "should cache cookie header");
    assert.ok(bgCode.includes('"authorization"'), "should cache authorization header");
    assert.ok(bgCode.includes('"referer"'), "should cache referer header");
    assert.ok(bgCode.includes('"user-agent"'), "should cache user-agent header");
  });

  it("popup.js uses browser.storage.sync (not chrome.storage.sync)", () => {
    assert.ok(popupCode.includes("browser.storage.sync"), "should use browser.storage.sync");
    assert.ok(!popupCode.includes("chrome.storage"), "should not use chrome.storage");
  });

  it("popup.js uses browser.runtime.sendMessage", () => {
    assert.ok(popupCode.includes("browser.runtime.sendMessage"), "should use browser.runtime.sendMessage");
  });
});

describe("Firefox manifest", () => {
  let manifest;
  before(() => {
    manifest = JSON.parse(readFileSync(join(DIST, "firefox", "manifest.json"), "utf8"));
  });

  it("uses manifest_version 3", () => {
    assert.equal(manifest.manifest_version, 3);
  });

  it("has background.scripts array (not service_worker)", () => {
    assert.ok(Array.isArray(manifest.background.scripts));
    assert.ok(manifest.background.scripts.includes("background.js"));
    assert.equal(manifest.background.service_worker, undefined);
  });

  it("has browser_specific_settings.gecko.id", () => {
    assert.ok(manifest.browser_specific_settings);
    assert.ok(manifest.browser_specific_settings.gecko);
    assert.ok(manifest.browser_specific_settings.gecko.id);
  });

  it("has required permissions", () => {
    const required = ["downloads", "webRequest", "nativeMessaging", "storage"];
    for (const perm of required) {
      assert.ok(manifest.permissions.includes(perm), `should have ${perm} permission`);
    }
  });

  it("has host_permissions <all_urls>", () => {
    assert.ok(manifest.host_permissions.includes("<all_urls>"));
  });
});

describe("Edge manifest", () => {
  let manifest;
  before(() => {
    manifest = JSON.parse(readFileSync(join(DIST, "edge", "manifest.json"), "utf8"));
  });

  it("uses manifest_version 3", () => {
    assert.equal(manifest.manifest_version, 3);
  });

  it("has service_worker background", () => {
    assert.equal(manifest.background.service_worker, "background.js");
  });

  it("has Edge-specific name", () => {
    assert.ok(manifest.name.toLowerCase().includes("edge"), "Edge manifest should have Edge in name");
  });

  it("has same permissions as Chrome", () => {
    const chromeManifest = JSON.parse(
      readFileSync(join(DIST, "chrome", "manifest.json"), "utf8")
    );
    assert.deepEqual(manifest.permissions, chromeManifest.permissions);
  });

  it("does not have background.scripts (Edge uses service_worker only)", () => {
    assert.equal(manifest.background.scripts, undefined);
  });

  it("does not have browser_specific_settings (Edge-only manifest)", () => {
    assert.equal(manifest.browser_specific_settings, undefined);
  });

  it("has same host_permissions as Chrome", () => {
    const chromeManifest = JSON.parse(
      readFileSync(join(DIST, "chrome", "manifest.json"), "utf8")
    );
    assert.deepEqual(manifest.host_permissions, chromeManifest.host_permissions);
  });

  it("has action with popup and icons", () => {
    assert.equal(manifest.action.default_popup, "popup.html");
    assert.ok(manifest.action.default_icon["16"]);
    assert.ok(manifest.action.default_icon["48"]);
    assert.ok(manifest.action.default_icon["128"]);
  });

  it("has Edge-specific description", () => {
    assert.ok(
      manifest.description.toLowerCase().includes("edge"),
      "Edge manifest should mention Edge in description"
    );
  });

  it("differs from Chrome only in name and description", () => {
    const chromeManifest = JSON.parse(
      readFileSync(join(DIST, "chrome", "manifest.json"), "utf8")
    );
    const edgeCopy = { ...manifest, name: chromeManifest.name, description: chromeManifest.description };
    assert.deepEqual(edgeCopy, chromeManifest);
  });
});

describe("Edge extension code", () => {
  let bgCode;
  let popupCode;

  before(() => {
    bgCode = readFileSync(join(DIST, "edge", "background.js"), "utf8");
    popupCode = readFileSync(join(DIST, "edge", "popup.js"), "utf8");
  });

  it("background.js uses chrome.* namespace", () => {
    assert.ok(bgCode.includes("chrome."), "should use chrome.* namespace");
    assert.ok(!bgCode.includes("browser."), "should not use browser.* namespace in Edge");
  });

  it("background.js uses onDeterminingFilename for download interception", () => {
    assert.ok(bgCode.includes("onDeterminingFilename"), "should use onDeterminingFilename (same as Chrome)");
  });

  it("background.js uses chrome.webRequest.onSendHeaders for header caching", () => {
    assert.ok(bgCode.includes("chrome.webRequest.onSendHeaders"), "should use chrome.webRequest.onSendHeaders");
  });

  it("background.js connects via connectNative with correct host", () => {
    assert.ok(bgCode.includes("connectNative"), "should use connectNative");
    assert.ok(bgCode.includes("com.macdownloadmanager.helper"), "should use correct native host ID");
  });

  it("popup.js uses chrome.storage.sync for settings", () => {
    assert.ok(popupCode.includes("chrome.storage.sync.get"), "should load settings via chrome.storage.sync");
    assert.ok(popupCode.includes("chrome.storage.sync.set"), "should save settings via chrome.storage.sync");
  });

  it("popup.html exists with enable toggle and settings", () => {
    const popupHtml = readFileSync(join(DIST, "edge", "popup.html"), "utf8");
    assert.ok(popupHtml.includes('id="enabled"'), "should have enabled toggle");
    assert.ok(popupHtml.includes('id="fileTypes"'), "should have file types input");
    assert.ok(popupHtml.includes('id="minSize"'), "should have min size slider");
    assert.ok(popupHtml.includes('id="statusDot"'), "should have status indicator");
  });

  it("popup.css supports dark mode", () => {
    const popupCss = readFileSync(join(DIST, "edge", "popup.css"), "utf8");
    assert.ok(popupCss.includes("prefers-color-scheme: dark"), "should have dark mode media query");
  });

  it("background.js is identical to Chrome background.js", () => {
    const chromeBg = readFileSync(join(DIST, "chrome", "background.js"), "utf8");
    assert.equal(bgCode, chromeBg, "Edge and Chrome background.js should be identical");
  });

  it("popup.js is identical to Chrome popup.js", () => {
    const chromePopup = readFileSync(join(DIST, "chrome", "popup.js"), "utf8");
    assert.equal(popupCode, chromePopup, "Edge and Chrome popup.js should be identical");
  });
});

describe("version injection", () => {
  let pkgVersion;
  before(() => {
    const pkg = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
    pkgVersion = pkg.version;
  });

  for (const browser of BROWSERS) {
    it(`dist/${browser}/manifest.json has version from package.json`, () => {
      const manifest = JSON.parse(
        readFileSync(join(DIST, browser, "manifest.json"), "utf8")
      );
      assert.equal(manifest.version, pkgVersion);
    });
  }
});

describe("icon files", () => {
  const sizes = { "icon16.png": 16, "icon48.png": 48, "icon128.png": 128 };

  for (const browser of BROWSERS) {
    for (const [file, expectedSize] of Object.entries(sizes)) {
      it(`dist/${browser}/icons/${file} exists and is non-empty`, () => {
        const iconPath = join(DIST, browser, "icons", file);
        assert.ok(existsSync(iconPath), `${file} should exist for ${browser}`);
        assert.ok(statSync(iconPath).size > 0, `${file} should not be empty`);
      });
    }
  }
});
