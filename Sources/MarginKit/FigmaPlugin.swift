import Foundation

/// Margin's Figma plugin. Margin writes these files to ~/.margin/figma-plugin;
/// you import the manifest once in Figma (Plugins → Development → Import
/// plugin from manifest…) and run it once per file. It stays hidden and
/// exports the selection, including animation as MP4, when Margin asks.
public enum FigmaPlugin {
    public static let ports: [UInt16] = Array(47821...47830)

    public static var manifest: String {
        // Figma accepts host names here, not IP addresses.
        let dev = ports.map { "http://localhost:\($0)" }
        let json: [String: Any] = [
            "name": "Margin",
            "id": "margin-local-capture",
            "api": "1.0.0",
            "main": "code.js",
            "ui": "ui.html",
            "editorType": ["figma", "slides"],
            "documentAccess": "dynamic-page",
            "enablePrivatePluginApi": true,
            "networkAccess": [
                "allowedDomains": ["none"],
                "devAllowedDomains": dev,
                "reasoning": "Sends exports to the Margin app running on this Mac.",
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Writes the plugin and returns the manifest's location.
    @discardableResult
    public static func install(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try code.write(to: directory.appendingPathComponent("code.js"), atomically: true, encoding: .utf8)
        try ui.write(to: directory.appendingPathComponent("ui.html"), atomically: true, encoding: .utf8)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        return manifestURL
    }

    /// Rewrites an installed plugin with this version's code, so a new Margin
    /// brings its plugin along. Figma picks it up the next time it's run.
    public static func refreshIfInstalled(at directory: URL = defaultDirectory) {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else { return }
        try? install(to: directory)
    }

    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".margin/figma-plugin", isDirectory: true)

    public static let code = #"""
// Margin for Figma: runs hidden and exports the selection when Margin asks.
// Every selected frame is exported on its own; video comes from Figma itself
// (exportAsync with format MP4), the same render as Figma's own export.
// Margin starts this plugin when you capture and it closes itself when the
// export is done, so it never sits running in Figma. No window at all.
figma.showUI(__html__, { visible: false, width: 260, height: 72, title: 'Margin' });

// Tell Margin how much is selected, so with nothing selected its shortcut
// goes straight to the capture menu instead of trying an export.
function reportSelection() {
  figma.ui.postMessage({ type: 'selection', count: figma.currentPage.selection.length, editor: figma.editorType || 'figma' });
}
if (typeof figma.on === 'function') {
  figma.on('selectionchange', reportSelection);
  figma.on('currentpagechange', reportSelection);
  setTimeout(reportSelection, 300);
}

const MAX_FRAMES = 12;
const MAX_SLIDES = 60;

// A Figma Slides deck: every slide in order (skipped ones left out), as one stack.
async function exportDeck(request) {
  let slides = [];
  if (typeof figma.getSlideGrid === 'function') {
    for (const row of figma.getSlideGrid()) slides = slides.concat(row);
  } else {
    slides = figma.currentPage.findAll((node) => node.type === 'SLIDE');
  }
  slides = slides.filter((slide) => !slide.isSkippedSlide).slice(0, MAX_SLIDES);
  if (slides.length === 0) return { type: 'result', id: request.id, nothingSelected: true };
  const frames = [];
  const progress = (done) => figma.ui.postMessage({ type: 'progress', id: request.id, done: done, total: slides.length });
  progress(0);
  for (const slide of slides) {
    frames.push(await exportNode(slide, false, new Set()));
    progress(frames.length);
  }
  const first = frames[0];
  return {
    type: 'result', id: request.id, deck: true,
    fileKey: figma.fileKey || null, fileName: figma.root ? figma.root.name : null,
    selectionCount: slides.length, frames: frames,
    nodeId: first.nodeId, nodeName: first.nodeName, nodeType: first.nodeType, png: first.png,
  };
}

function topLevelFrame(node) {
  let current = node;
  while (current.parent && current.parent.type !== 'PAGE' && current.parent.type !== 'SECTION') {
    current = current.parent;
  }
  return current;
}

// Whether a top-level frame animates, read from Figma's Motion API (beta):
// keyframe tracks or animation styles on it or anything inside it. When the
// API isn't there, the frame's timelines decide; without those, it's a still.
function readMotion(node) {
  let known = false;
  try {
    if ('manualKeyframeTracks' in node) {
      known = true;
      const tracks = node.manualKeyframeTracks;
      if (tracks && Object.keys(tracks).length > 0) return { known: true, animated: true };
    }
  } catch (error) { /* not supported here */ }
  try {
    if ('animationStyles' in node) {
      known = true;
      const styles = node.animationStyles;
      if (styles && styles.length > 0) return { known: true, animated: true };
    }
  } catch (error) { /* not supported here */ }
  return { known: known, animated: false };
}

function hasMotion(top) {
  let known = false;
  const stack = [top];
  let seen = 0;
  while (stack.length > 0 && seen < 4000) {
    const node = stack.pop();
    seen += 1;
    const motion = readMotion(node);
    if (motion.animated) return true;
    if (motion.known) known = true;
    if ('children' in node && node.children) {
      for (const child of node.children) stack.push(child);
    }
  }
  if (known) return false;
  try {
    const timelines = top.timelines;
    return !!(timelines && timelines.some((timeline) => timeline && timeline.duration > 0));
  } catch (error) {
    return false;
  }
}

async function exportNode(node, wantVideo, videoDone, detectMotion) {
  const frame = { nodeId: node.id, nodeName: node.name, nodeType: node.type };
  try {
    // Figma draws from vectors, so a small frame can be rendered larger than
    // it shows on screen: at least 2x, up to 4x, aiming for 3200 px on the
    // long side, so a small component is as sharp as a full page.
    const side = Math.max(Number(node.width) || 0, Number(node.height) || 0);
    const scale = side > 0 ? Math.round(Math.min(4, Math.max(2, 3200 / side)) * 100) / 100 : 2;
    frame.png = await node.exportAsync({ format: 'PNG', constraint: { type: 'SCALE', value: scale } });
  } catch (error) {
    frame.pngError = String(error);
  }
  // Margin asks for video outright, or asks the plugin to look for animation.
  const top = (wantVideo || detectMotion) ? topLevelFrame(node) : null;
  if (top && !wantVideo && !videoDone.has(top.id)) wantVideo = hasMotion(top);
  if (wantVideo) {
    // Video export works on top-level frames that hold the animation.
    if (!videoDone.has(top.id)) {
      videoDone.add(top.id);
      try {
        frame.video = await top.exportAsync({ format: 'MP4', quality: 'HIGH', fps: 30 });
        frame.videoNodeId = top.id;
        if (top !== node) {
          frame.nodeId = top.id;
          frame.nodeName = top.name;
          frame.nodeType = top.type;
        }
      } catch (error) {
        frame.videoError = String(error);
      }
    }
  }
  return frame;
}

async function exportSelection(request) {
  const selection = figma.currentPage.selection;
  if (!selection || selection.length === 0) {
    return { type: 'result', id: request.id, nothingSelected: true };
  }
  const videoDone = new Set();
  const frames = [];
  const nodes = selection.slice(0, MAX_FRAMES);
  // With several frames, say how far along we are, so Margin's pill can fill.
  const progress = (done) => {
    if (nodes.length > 1) figma.ui.postMessage({ type: 'progress', id: request.id, done: done, total: nodes.length });
  };
  progress(0);
  for (const node of nodes) {
    frames.push(await exportNode(node, !!request.wantVideo, videoDone, !!request.detectMotion));
    progress(frames.length);
  }
  const first = frames[0];
  return {
    type: 'result',
    id: request.id,
    fileKey: figma.fileKey || null,
    fileName: figma.root ? figma.root.name : null,
    selectionCount: selection.length,
    frames: frames,
    // The first frame again at the top level, for older versions of Margin.
    nodeId: first.nodeId,
    nodeName: first.nodeName,
    nodeType: first.nodeType,
    png: first.png,
    video: first.video,
    videoError: first.videoError,
  };
}

figma.ui.onmessage = async (message) => {
  if (!message) return;
  if (message.type === 'close') { figma.closePlugin(message.reason || undefined); return; }
  if (message.type === 'connected' || message.type === 'disconnected') return;
  if (message.type !== 'export') return;
  let result;
  try {
    result = message.deck ? await exportDeck(message) : await exportSelection(message);
  } catch (error) {
    result = { type: 'result', id: message.id, error: String(error) };
  }
  figma.ui.postMessage(result);
};
"""#

    public static let ui = #"""
<!doctype html>
<meta charset="utf-8">
<style>
  body { margin: 0; font: 12px/1.4 -apple-system, BlinkMacSystemFont, sans-serif; color: #e8e8e8; background: #1e1e1e; }
  .row { display: flex; align-items: center; gap: 10px; padding: 14px 16px; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #888; flex: none; }
  .dot.on { background: #3ecf6e; }
  .detail { color: #9a9a9a; font-size: 11px; }
</style>
<div class="row"><div id="dot" class="dot"></div><div><div id="title">Looking for Margin…</div><div id="detail" class="detail"></div></div></div>
<script>
// Finds Margin on this Mac, asks it for work, sends back exports.
function status(connected, title, detail) {
  if (typeof document === 'undefined') return;
  document.getElementById('dot').className = connected ? 'dot on' : 'dot';
  document.getElementById('title').textContent = title;
  document.getElementById('detail').textContent = detail || '';
}
let lastError = '';
let wasConnected = null;
// How many layers are selected in Figma, sent along with every poll (-1: not known yet),
// and which editor this is ('slides' for a Figma Slides deck).
let selected = -1;
let editor = '';
function setConnected(connected) {
  if (connected === wasConnected) return;
  wasConnected = connected;
  if (connected) {
    status(true, 'Connected to Margin', 'Press the Margin shortcut to capture.');
  } else {
    status(false, 'Looking for Margin…', lastError ? 'Is the Margin app running? (' + lastError + ')' : 'Is the Margin app running?');
  }
  parent.postMessage({ pluginMessage: { type: connected ? 'connected' : 'disconnected' } }, '*');
}

const PORTS = [47821, 47822, 47823, 47824, 47825, 47826, 47827, 47828, 47829, 47830];
let base = null;

async function findMargin() {
  for (const port of PORTS) {
    try {
      const response = await fetch(`http://localhost:${port}/figma/poll?hello=1`);
      const json = await response.json();
      if (json && json.app === 'Margin') { base = `http://localhost:${port}`; return; }
    } catch (error) { lastError = String(error && error.message || error); }
  }
}

// Waits for work: Margin holds the request open until it has a job (or
// about 20 seconds pass), so nothing here depends on timers. Figma's hidden
// plugin window runs timers late or not at all; an open request still
// answers the moment Margin speaks.
// Returns how long to pause before asking again (0: ask right away).
async function poll() {
  if (!base) await findMargin();
  if (!base) { setConnected(false); return 2000; }
  setConnected(true);
  const started = Date.now();
  try {
    const response = await fetch(`${base}/figma/wait?selected=${selected}&editor=${editor}`);
    const json = await response.json();
    if (!json || json.app !== 'Margin') throw new Error('not Margin');
    if (json.request) {
      gotJob = true;
      parent.postMessage({ pluginMessage: { type: 'export', id: json.request.id, wantVideo: !!json.request.wantVideo, detectMotion: !!json.request.detectMotion, deck: !!json.request.deck } }, '*');
      return 0;
    }
    // An instant empty answer means this Margin can't hold requests: poll gently.
    return Date.now() - started < 300 ? 400 : 0;
  } catch (error) {
    lastError = String(error && error.message || error);
    base = null;
    return 2000;
  }
}

// Tells Margin the moment the selection changes, without waiting for a timer.
function sendSelection() {
  if (!base) return;
  fetch(`${base}/figma/selection?selected=${selected}&editor=${editor}`, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: '' }).catch(() => {});
}

function toBase64(bytes) {
  if (!bytes) return null;
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

onmessage = async (event) => {
  const message = event.data && event.data.pluginMessage;
  if (message && message.type === 'selection') { selected = message.count; editor = message.editor || ''; sendSelection(); return; }
  if (!message || !base) return;
  if (message.type === 'progress') {
    try {
      await fetch(`${base}/figma/progress`, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: JSON.stringify(message) });
    } catch (error) { /* only a progress hint */ }
    return;
  }
  if (message.type !== 'result') return;
  const frames = (message.frames || []).map((frame) => Object.assign({}, frame, { png: toBase64(frame.png), video: toBase64(frame.video) }));
  const body = Object.assign({}, message, { png: toBase64(message.png), video: toBase64(message.video), frames: frames });
  try {
    // text/plain keeps this a simple request (no preflight).
    await fetch(`${base}/figma/result`, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: JSON.stringify(body) });
  } catch (error) { /* Margin went away */ }
  await finish();
};

// Done: tell Margin, then close the plugin so nothing stays running in Figma.
let finishing = false;
async function finish(reason) {
  if (finishing) return;
  finishing = true;
  if (base) { try { await fetch(`${base}/figma/bye`, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: '' }); } catch (error) { /* closing anyway */ } }
  parent.postMessage({ pluginMessage: { type: 'close', reason: reason || '' } }, '*');
}

// Started by hand with nothing to do, or Margin isn't running: close after a
// while instead of sitting in Figma's running bar. Margin starts it again on capture.
const startedAt = Date.now();
let gotJob = false;
async function loop() {
  for (;;) {
    if (finishing) return;
    const idle = Date.now() - startedAt;
    if (!gotJob && !base && idle > 6000) { await finish('Margin isn\u2019t running. Open Margin, then capture again.'); return; }
    if (!gotJob && idle > 25000) { await finish(); return; }
    const pause = await poll();
    if (pause > 0) await new Promise((resolve) => setTimeout(resolve, pause));
  }
}
loop();
</script>
"""#
}
