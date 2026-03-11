const DEFAULT_FILE_TYPES = [
  "zip", "dmg", "iso", "pkg", "tar.gz", "7z", "rar",
  "mp4", "mkv", "avi", "mov", "mp3", "flac",
  "exe", "msi", "deb", "AppImage"
];

const elements = {
  enabled: document.getElementById("enabled"),
  fileTypes: document.getElementById("fileTypes"),
  minSize: document.getElementById("minSize"),
  minSizeValue: document.getElementById("minSizeValue"),
  save: document.getElementById("save"),
  statusDot: document.getElementById("statusDot"),
  statusText: document.getElementById("statusText")
};

function loadSettings() {
  chrome.storage.sync.get({
    enabled: true,
    fileTypes: DEFAULT_FILE_TYPES,
    minSizeMB: 5
  }, (settings) => {
    elements.enabled.checked = settings.enabled;
    elements.fileTypes.value = settings.fileTypes.join(", ");
    elements.minSize.value = settings.minSizeMB;
    elements.minSizeValue.textContent = settings.minSizeMB;
  });
}

function saveSettings() {
  const fileTypes = elements.fileTypes.value
    .split(",")
    .map(s => s.trim())
    .filter(Boolean);

  chrome.storage.sync.set({
    enabled: elements.enabled.checked,
    fileTypes,
    minSizeMB: parseInt(elements.minSize.value, 10)
  }, () => {
    elements.save.textContent = "Saved";
    setTimeout(() => { elements.save.textContent = "Save"; }, 1200);
  });
}

function updateStatus() {
  chrome.runtime.sendMessage({ type: "getStatus" }, (response) => {
    if (chrome.runtime.lastError || !response) {
      elements.statusDot.className = "status-dot disconnected";
      elements.statusText.textContent = "Disconnected";
      return;
    }
    const connected = response.connected;
    elements.statusDot.className = `status-dot ${connected ? "connected" : "disconnected"}`;
    elements.statusText.textContent = connected ? "Connected" : "Disconnected";
  });
}

elements.minSize.addEventListener("input", () => {
  elements.minSizeValue.textContent = elements.minSize.value;
});

elements.save.addEventListener("click", saveSettings);

document.addEventListener("DOMContentLoaded", () => {
  loadSettings();
  updateStatus();
});
