const NATIVE_HOST = "com.macdownloadmanager.helper";

const DEFAULT_FILE_TYPES = [
  "zip", "dmg", "iso", "pkg", "tar.gz", "7z", "rar",
  "mp4", "mkv", "avi", "mov", "mp3", "flac",
  "exe", "msi", "deb", "AppImage", "torrent"
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
  chrome.storage.sync.get(DEFAULT_SETTINGS, (settings) => {
    currentSettings = settings;
  });
}

chrome.storage.onChanged.addListener((changes, area) => {
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

chrome.webRequest.onSendHeaders.addListener(
  cacheHeaders,
  { urls: ["<all_urls>"] },
  ["requestHeaders"]
);

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

chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
  if (!currentSettings.enabled) {
    return;
  }

  if (!shouldIntercept(currentSettings, item.filename, item.fileSize)) {
    return;
  }

  console.log("[MDM] Intercepted download:", item.filename, item.url);

  const cached = headerCache.get(item.url);
  const message = {
    url: item.url,
    headers: cached?.headers || null,
    filename: item.filename,
    fileSize: item.fileSize > 0 ? item.fileSize : null,
    referrer: item.referrer || cached?.headers?.referer || null
  };

  sendNativeMessage(message);

  chrome.downloads.cancel(item.id, () => {
    void chrome.runtime.lastError;
    suggest({ filename: item.filename });
  });

  return true;
});

function connectNative() {
  if (connectPending) {
    console.log("[MDM] connectNative: already pending, skipping");
    return;
  }
  connectPending = true;
  console.log("[MDM] connectNative: attempting connection");

  try {
    nativePort = chrome.runtime.connectNative(NATIVE_HOST);
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
        chrome.action.setBadgeText({
          text: response.activeCount > 0 ? String(response.activeCount) : ""
        });
      }
    });

    nativePort.onDisconnect.addListener(() => {
      const error = chrome.runtime.lastError?.message || "unknown";
      console.log("[MDM] connectNative: disconnected, reason:", error);
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
    chrome.action.setBadgeText({ text: "" });
    chrome.action.setBadgeBackgroundColor({ color: "#4CAF50" });
  } else {
    chrome.action.setBadgeText({ text: "!" });
    chrome.action.setBadgeBackgroundColor({ color: "#F44336" });
  }
}

chrome.runtime.onMessage.addListener((request, _sender, sendResponse) => {
  if (request.type === "getStatus") {
    sendResponse({ connected: nativeConnected });
  } else if (request.type === "interceptedDownload") {
    if (!currentSettings.enabled) return false;
    const isMagnet = typeof request.url === "string" && request.url.startsWith("magnet:");
    if (!isMagnet && !shouldIntercept(currentSettings, request.filename || "", null)) return false;
    const cached = headerCache.get(request.url);
    const message = {
      url: request.url,
      headers: cached?.headers || null,
      filename: request.filename || null,
      fileSize: null,
      referrer: request.referrer || cached?.headers?.referer || null
    };
    sendNativeMessage(message);
  }
  return false;
});

connectNative();
