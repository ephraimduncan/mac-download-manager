const DOWNLOADABLE_EXTENSIONS = [
  ".zip", ".dmg", ".pkg", ".iso",
  ".tar.gz", ".tgz", ".tar.bz2", ".tar.xz",
  ".7z", ".rar",
  ".mp4", ".mkv", ".avi", ".mov", ".mp3", ".flac",
  ".exe", ".msi", ".deb", ".appimage", ".torrent"
];

function getUrlExtension(url) {
  try {
    const pathname = new URL(url).pathname.toLowerCase();
    for (const ext of DOWNLOADABLE_EXTENSIONS) {
      if (pathname.endsWith(ext)) {
        return ext;
      }
    }
  } catch {}
  return null;
}

function getFilename(url) {
  try {
    const pathname = new URL(url).pathname;
    const segments = pathname.split("/");
    const last = segments[segments.length - 1];
    return last ? decodeURIComponent(last) : "";
  } catch {
    return "";
  }
}

document.addEventListener("click", (event) => {
  if (!(event.target instanceof Element)) return;
  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const link = event.target.closest("a[href]");
  if (!link) return;

  const href = link.href;
  if (!href || href.startsWith("javascript:") || href.startsWith("#")) return;

  const isMagnet = href.startsWith("magnet:");
  const ext = getUrlExtension(href);
  if (!isMagnet && !ext) return;

  event.preventDefault();
  event.stopPropagation();

  const filename = isMagnet ? "" : getFilename(href);
  const referrer = document.location.href;

  browser.runtime.sendMessage({
    type: "interceptedDownload",
    url: href,
    filename: filename,
    referrer: referrer,
  });
}, true);
