import assert from 'node:assert/strict';
import { chooseVideoState } from '../BrowserExtension/activity.mjs';

const now = 10000;
const report = { tabId: 7, frameId: 0, receivedAt: now, visible: true, fullscreenVideo: true, viewportVideo: false };
const base = { activeTabId: 7, focused: true, windowFullscreen: true, reports: [report], now };
assert.equal(chooseVideoState(base).fullscreenVideo, true);
assert.equal(chooseVideoState({ ...base, focused: false }).fullscreenVideo, false);
assert.equal(chooseVideoState({ ...base, activeTabId: 8 }).fullscreenVideo, false);
assert.equal(chooseVideoState({ ...base, now: now + 4000 }).fullscreenVideo, false);
assert.equal(chooseVideoState({ ...base, reports: [{ ...report, visible: false }] }).fullscreenVideo, false);
assert.deepEqual(chooseVideoState({ ...base, reports: [] }), { fullscreenVideo: false, viewportVideo: false });
assert.equal(chooseVideoState({ ...base, reports: [{ ...report, frameId: 3 }] }).fullscreenVideo, true);
const viewport = { ...report, fullscreenVideo: false, viewportVideo: true };
assert.equal(chooseVideoState({ ...base, reports: [viewport] }).viewportVideo, true);
assert.equal(chooseVideoState({ ...base, windowFullscreen: false, reports: [viewport] }).viewportVideo, false);
assert.equal(chooseVideoState({ ...base, reports: [{ ...viewport, frameId: 3 }] }).viewportVideo, false);
console.log('PASS: 10 browser activity checks');
