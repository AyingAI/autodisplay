export function chooseVideoState({ activeTabId, focused, windowFullscreen, reports, now }) {
  if (!focused || activeTabId === undefined) {
    return { fullscreenVideo: false, viewportVideo: false };
  }
  const visible = reports.filter(report => report.tabId === activeTabId && report.visible &&
    now >= report.receivedAt && now - report.receivedAt < 3500);
  return {
    fullscreenVideo: visible.some(report => report.fullscreenVideo),
    // An ordinary video filling a small iframe must not count as a fullscreen video.
    viewportVideo: windowFullscreen && visible.some(report => report.frameId === 0 && report.viewportVideo)
  };
}
