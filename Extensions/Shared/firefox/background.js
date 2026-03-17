const NATIVE_HOST = "com.macdownloadmanager.helper";

const DEFAULT_FILE_TYPES = [
  "zip", "dmg", "iso", "pkg", "tar.gz", "7z", "rar",
  "mp4", "mkv", "avi", "mov", "mp3", "flac",
  "exe", "msi", "deb", "AppImage"
];

const DEFAULT_SETTINGS = {
  enabled: true,
  fileTypes: DEFAULT_FILE_TYPES,
  minSizeMB: 5
};

const HEADER_CACHE_TTL_MS = 30_000;
const HEADER_CLEANUP_INTERVAL_MS = 10_000;

const headerCache = new Map();
let nativePort = null;
let nativeConnected = false;
let connectPending = false;
let pendingMessages = [];
let currentSettings = { ...DEFAULT_SETTINGS };

function loadSettings() {
  browser.storage.sync.get(DEFAULT_SETTINGS).then((settings) => {
    currentSettings = settings;
  });
}

browser.storage.onChanged.addListener((changes, area) => {
  if (area === "sync") {
    loadSettings();
  }
});

loadSettings();

function cacheHeaders(details) {
  const headers = {};
  for (const header of details.requestHeaders || []) {
    const name = header.name.toLowerCase();
    if (["cookie", "authorization", "referer", "user-agent"].includes(name)) {
      headers[name] = header.value;
    }
  }
  headerCache.set(details.url, { headers, timestamp: Date.now() });
}

function cleanHeaderCache() {
  const cutoff = Date.now() - HEADER_CACHE_TTL_MS;
  for (const [url, entry] of headerCache) {
    if (entry.timestamp < cutoff) {
      headerCache.delete(url);
    }
  }
}

setInterval(cleanHeaderCache, HEADER_CLEANUP_INTERVAL_MS);

browser.webRequest.onSendHeaders.addListener(
  cacheHeaders,
  { urls: ["<all_urls>"] },
  ["requestHeaders"]
);

browser.runtime.onInstalled.addListener(async () => {
  try {
    await browser.contextMenus.removeAll();
    try {
      browser.contextMenus.create({
        id: "download-with-mdm",
        title: "Download with Mac Download Manager",
        contexts: ["link"],
      });
    } catch (e) {
      console.log("[MDM] contextMenus.create error:", e.message);
    }
  } catch (e) {
    console.log("[MDM] contextMenus.removeAll error:", e.message);
  }
});

browser.contextMenus.onClicked.addListener(async (info) => {
  try {
    if (info.menuItemId !== "download-with-mdm") return;

    const url = info.linkUrl;
    if (!url) return;

    let parsedUrl;
    try {
      parsedUrl = new URL(url);
    } catch {
      return;
    }
    if (parsedUrl.protocol !== "http:" && parsedUrl.protocol !== "https:") return;

    const rawSegment = parsedUrl.pathname.split("/").pop() || "";
    let filename;
    try {
      filename = decodeURIComponent(rawSegment);
    } catch {
      filename = rawSegment;
    }
    const referrer = info.pageUrl || "";

    // headerCache is empty for context menu items (no prior request was made),
    // so explicitly fetch cookies for the link URL to support authenticated downloads.
    const cached = headerCache.get(url);
    const headers = { ...(cached?.headers || {}) };
    if (!headers.cookie) {
      try {
        const granted = await browser.permissions.request({ permissions: ["cookies"] });
        if (granted) {
          const cookies = await browser.cookies.getAll({ url });
          if (cookies.length > 0) {
            headers.cookie = cookies.map(c => `${c.name}=${c.value}`).join("; ");
          }
        }
      } catch (e) {
        console.log("[MDM] cookies.getAll error:", e.message);
      }
    }

    sendNativeMessage({
      url,
      headers: Object.keys(headers).length > 0 ? headers : null,
      filename,
      fileSize: null,
      referrer,
    });
  } catch (e) {
    console.log("[MDM] contextMenus.onClicked error:", e.message);
  }
});

function getExtension(filename) {
  if (!filename) return "";
  if (filename.endsWith(".tar.gz")) return "tar.gz";
  const dot = filename.lastIndexOf(".");
  return dot >= 0 ? filename.slice(dot + 1).toLowerCase() : "";
}

function shouldIntercept(settings, filename, fileSize) {
  const ext = getExtension(filename);
  const typeMatch = ext && settings.fileTypes.some(t => t.toLowerCase() === ext);
  const sizeMatch = fileSize && fileSize >= settings.minSizeMB * 1024 * 1024;
  return typeMatch || sizeMatch;
}

browser.downloads.onCreated.addListener((downloadItem) => {
  if (!currentSettings.enabled) {
    return;
  }

  const rawFilename = downloadItem.filename || downloadItem.url.split("/").pop() || "";
  const filename = rawFilename.split("/").pop() || rawFilename;

  if (!shouldIntercept(currentSettings, filename, downloadItem.fileSize)) {
    return;
  }

  console.log("[MDM] Intercepted download:", filename, downloadItem.url);

  browser.downloads.cancel(downloadItem.id).then(() => {
    browser.downloads.erase({ id: downloadItem.id });
  }).catch(() => {});

  const cached = headerCache.get(downloadItem.url);
  const message = {
    url: downloadItem.url,
    headers: cached?.headers || null,
    filename,
    fileSize: downloadItem.fileSize > 0 ? downloadItem.fileSize : null,
    referrer: downloadItem.referrer || cached?.headers?.referer || null
  };

  sendNativeMessage(message);
});

function connectNative() {
  if (connectPending) {
    console.log("[MDM] connectNative: already pending, skipping");
    return;
  }
  connectPending = true;
  console.log("[MDM] connectNative: attempting connection");

  try {
    nativePort = browser.runtime.connectNative(NATIVE_HOST);
    nativeConnected = true;
    connectPending = false;
    console.log("[MDM] connectNative: connected");
    updateBadge();

    if (pendingMessages.length > 0) {
      console.log("[MDM] connectNative: flushing", pendingMessages.length, "pending messages");
    }
    for (const msg of pendingMessages) {
      nativePort.postMessage(msg);
    }
    pendingMessages = [];

    nativePort.onMessage.addListener((response) => {
      if (response.activeCount !== undefined) {
        browser.action.setBadgeText({
          text: response.activeCount > 0 ? String(response.activeCount) : ""
        });
      }
    });

    nativePort.onDisconnect.addListener(() => {
      console.log("[MDM] connectNative: disconnected");
      nativeConnected = false;
      nativePort = null;
      connectPending = false;
      updateBadge();
      setTimeout(connectNative, 5000);
    });
  } catch (e) {
    console.log("[MDM] connectNative: caught error:", e.message);
    nativeConnected = false;
    nativePort = null;
    connectPending = false;
    updateBadge();
    setTimeout(connectNative, 5000);
  }
}

function sendNativeMessage(message) {
  if (nativePort && nativeConnected) {
    console.log("[MDM] sendNativeMessage: posting to native host");
    nativePort.postMessage(message);
  } else {
    console.log("[MDM] sendNativeMessage: disconnected, queuing (pending=" + (pendingMessages.length + 1) + ")");
    pendingMessages.push(message);
    connectNative();
  }
}

function updateBadge() {
  if (nativeConnected) {
    browser.action.setBadgeText({ text: "" });
    browser.action.setBadgeBackgroundColor({ color: "#4CAF50" });
  } else {
    browser.action.setBadgeText({ text: "!" });
    browser.action.setBadgeBackgroundColor({ color: "#F44336" });
  }
}

browser.runtime.onMessage.addListener((request, _sender, sendResponse) => {
  if (request.type === "getStatus") {
    sendResponse({ connected: nativeConnected });
  }
  return false;
});

connectNative();
