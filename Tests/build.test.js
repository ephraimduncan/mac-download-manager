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
const pkg = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));

function browserLabel(browser) {
  return browser.charAt(0).toUpperCase() + browser.slice(1);
}

before(() => {
  execSync("npm run build", { cwd: ROOT, stdio: "pipe" });
});

describe("build output structure", () => {
  for (const browser of BROWSERS) {
    it(`produces dist/${browser}/ directory with expected files`, () => {
      const dir = join(DIST, browser);
      assert.ok(existsSync(dir), `dist/${browser}/ should exist`);
      assert.ok(statSync(dir).isDirectory());

      for (const file of ["manifest.json", "background.js", "popup.html", "popup.js", "popup.css"]) {
        assert.ok(existsSync(join(dir, file)), `dist/${browser}/${file} should exist`);
      }

      for (const icon of ["icon16.png", "icon48.png", "icon128.png"]) {
        const iconPath = join(dir, "icons", icon);
        assert.ok(existsSync(iconPath), `dist/${browser}/icons/${icon} should exist`);
        assert.ok(statSync(iconPath).size > 0);
      }
    });
  }
});

describe("manifest validity and version", () => {
  for (const browser of BROWSERS) {
    it(`dist/${browser}/manifest.json is valid and has correct version`, () => {
      const manifest = JSON.parse(readFileSync(join(DIST, browser, "manifest.json"), "utf8"));
      assert.equal(manifest.manifest_version, 3);
      assert.equal(manifest.version, pkg.version);
      assert.ok(manifest.permissions.includes("nativeMessaging"));
    });
  }
});

describe("versioned ZIP artifacts", () => {
  for (const browser of BROWSERS) {
    it(`produces versioned ZIP for ${browser}`, () => {
      const filename = `MacDownloadManager-${browserLabel(browser)}Extension-${pkg.version}.zip`;
      const zipPath = join(DIST, filename);
      assert.ok(existsSync(zipPath), `${filename} should exist`);
      assert.ok(statSync(zipPath).size > 0, `${filename} should not be empty`);
    });
  }
});
