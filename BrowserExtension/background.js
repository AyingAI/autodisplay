import { chooseVideoState } from './activity.mjs';

const baseURL = 'http://127.0.0.1:48741';
const frames = new Map();
let configuration;
let pendingReport;
let sending = false;
let sendAgain = false;
let lastSuccess = 0;

async function config() {
  if (!configuration) configuration = (await chrome.storage.local.get('connection')).connection;
  return configuration;
}

function headers(connection) {
  return {
    'Content-Type': 'application/json',
    'X-AutoDisplay-Extension': chrome.runtime.id,
    ...(connection ? {
      'X-AutoDisplay-Client': connection.client,
      'X-AutoDisplay-Token': connection.token
    } : {})
  };
}

async function pair(message, sender) {
  const url = new URL(sender.url || 'about:blank');
  if (url.origin !== baseURL || url.pathname !== '/pair' || sender.frameId !== 0) {
    throw new Error('请从 AutoDisplay 菜单打开连接页面');
  }
  const browser = { chrome: 'com.google.Chrome', dia: 'company.thebrowser.dia' }[message.browser];
  if (!browser) throw new Error('请选择当前浏览器对应的连接入口');
  const existing = await config();
  const client = existing?.client || crypto.randomUUID();
  const response = await fetch(`${baseURL}/pair`, {
    method: 'POST', headers: headers(), body: JSON.stringify({ browser, client }),
    signal: AbortSignal.timeout(3000)
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || '连接失败');
  configuration = { client, token: result.token, browser: result.browser };
  await chrome.storage.local.set({ connection: configuration });
  await sendState();
  return { ok: true };
}

async function sendState() {
  if (sending) { sendAgain = true; return; }
  sending = true;
  try {
    const connection = await config();
    if (!connection) return;
    const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    const tab = tabs[0];
    const window = tab ? await chrome.windows.get(tab.windowId) : undefined;
    const now = Date.now();
    for (const [key, value] of frames) if (now - value.receivedAt > 10_000) frames.delete(key);
    const state = chooseVideoState({ activeTabId: tab?.id, focused: Boolean(window?.focused),
      windowFullscreen: window?.state === 'fullscreen', reports: [...frames.values()], now });
    const response = await fetch(`${baseURL}/state`, { method: 'POST', headers: headers(connection),
      body: JSON.stringify(state), signal: AbortSignal.timeout(2000) });
    if (response.ok) lastSuccess = Date.now();
  } catch { /* Native app can be stopped; stale signals expire without keeping the screen bright. */ }
  finally {
    sending = false;
    if (sendAgain) { sendAgain = false; scheduleReport(); }
  }
}

function scheduleReport() {
  if (pendingReport) return;
  pendingReport = setTimeout(() => { pendingReport = undefined; sendState(); }, 100);
}

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message?.kind === 'pair') {
    pair(message, sender).then(reply, error => reply({ ok: false, error: error.message }));
    return true;
  }
  if (message?.kind === 'status') {
    config().then(connection => reply({ paired: Boolean(connection), live: Date.now() - lastSuccess < 6000 }));
    return true;
  }
  if (message?.kind === 'state' && sender.tab?.id !== undefined) {
    frames.set(`${sender.tab.id}:${sender.frameId}`, {
      tabId: sender.tab.id, frameId: sender.frameId, receivedAt: Date.now(),
      visible: message.visible === true, fullscreenVideo: message.fullscreenVideo === true,
      viewportVideo: message.viewportVideo === true
    });
    scheduleReport();
  }
});

chrome.tabs.onActivated.addListener(scheduleReport);
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status === 'loading') {
    for (const [key, report] of frames) if (report.tabId === tabId) frames.delete(key);
    scheduleReport();
  }
});
chrome.tabs.onRemoved.addListener(tabId => {
  for (const [key, report] of frames) if (report.tabId === tabId) frames.delete(key);
  scheduleReport();
});
chrome.windows.onFocusChanged.addListener(scheduleReport);
chrome.windows.onBoundsChanged.addListener(scheduleReport);
