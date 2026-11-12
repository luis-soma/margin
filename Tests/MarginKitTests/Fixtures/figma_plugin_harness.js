// Runs Margin's Figma plugin (code.js + ui.html) outside Figma, with a fake
// `figma` API and the real network code, for Margin's tests.
// Usage: node figma_plugin_harness.js <plugin dir> [--empty] [--still]
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const dir = process.argv[2];
const empty = process.argv.includes('--empty');
const still = process.argv.includes('--still');

const logFile = path.join(dir, 'harness.log');
const log = (...parts) => fs.appendFileSync(logFile, parts.join(' ') + '\n');
process.on('uncaughtException', (e) => log('uncaught', String(e && e.stack || e)));
process.on('unhandledRejection', (e) => log('unhandled', String(e && e.stack || e)));
const loggedFetch = async (url, options) => {
  if (!String(url).includes('/figma/poll')) log('start', options && options.method || 'GET', url);
  try {
    const response = await fetch(url, Object.assign({ signal: AbortSignal.timeout(4000) }, options || {}));
    if (!String(url).includes('/figma/poll') || options) log('fetch', options && options.method || 'GET', url, '->', response.status);
    return response;
  } catch (error) {
    log('fetch', url, 'failed', String(error), error.cause ? String(error.cause) : '');
    throw error;
  }
};

const MP4 = new Uint8Array([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]);

const page = { type: 'PAGE' };
const frame = {
  id: '139:218', name: 'desktop', type: 'FRAME', parent: page,
  exportAsync: async (settings) => {
    if (settings.format === 'MP4') {
      if (still) throw new Error('Node has no animated content');
      return MP4;
    }
    return PNG;
  },
};
const second = { id: '139:2', name: 'mobile', type: 'FRAME', parent: page, exportAsync: async (settings) => settings.format === 'MP4' ? MP4 : PNG };
const third = { id: '139:3', name: 'tablet', type: 'FRAME', parent: page, exportAsync: async (settings) => { if (settings.format === 'MP4') throw new Error('Node has no animated content'); return PNG; } };
const child = { id: '139:223', name: 'margin', type: 'FRAME', parent: frame, exportAsync: async () => PNG };

let pluginHandler = null;
let uiContext = null;
const figma = {
  fileKey: 'tEO3GjK8Jcijru2LYcHvIL',
  root: { name: 'SVSD Competition' },
  currentPage: { selection: empty ? [] : process.argv.includes('--multi') ? [frame, second, third] : [process.argv.includes('--child') ? child : frame] },
  showUI() {},
  ui: {
    hide() {},
    show() {},
    set onmessage(handler) { pluginHandler = handler; },
    get onmessage() { return pluginHandler; },
    postMessage(message) { log('to ui', message.type, Object.keys(message).join(',')); setTimeout(() => uiContext.onmessage({ data: { pluginMessage: message } }), 0); },
  },
};

const codeContext = vm.createContext({ figma, __html__: '', console, String, setTimeout, clearTimeout, Set });
vm.runInContext(fs.readFileSync(path.join(dir, 'code.js'), 'utf8'), codeContext);

const html = fs.readFileSync(path.join(dir, 'ui.html'), 'utf8');
const script = html.match(/<script>([\s\S]*)<\/script>/)[1];
uiContext = vm.createContext({
  fetch: loggedFetch, console, setTimeout, btoa, JSON, Object, String, Promise, Uint8Array,
  clearTimeout,
  parent: { postMessage(message) { log('to plugin', JSON.stringify(message.pluginMessage)); setTimeout(() => pluginHandler(message.pluginMessage), 0); } },
});
vm.runInContext(script, uiContext);
log('harness running', process.version);
// Report network trouble the plugin swallows.
for (const port of [47821, 47822]) {
  fetch(`http://localhost:${port}/figma/poll?hello=1`, { signal: AbortSignal.timeout(4000) }).then((r) => r.text()).then((t) => log(port, 'says', JSON.stringify(t))).catch((e) => log(port, 'error', String(e), e.cause ? String(e.cause) : ''));
}
