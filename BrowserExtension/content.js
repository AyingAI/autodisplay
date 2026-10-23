(() => {
  const isPairPage = location.hostname === '127.0.0.1' && location.port === '48741' && location.pathname === '/pair';
  if (isPairPage && window.top === window) {
    const container = document.getElementById('autodisplay-connect');
    const result = document.getElementById('autodisplay-result');
    if (!container || !result) return;
    const browser = new URL(location.href).searchParams.get('browser');
    const button = document.createElement('button');
    button.textContent = '连接此浏览器';
    container.replaceChildren(button);
    button.addEventListener('click', async event => {
      if (!event.isTrusted) return;
      button.disabled = true;
      try {
        const response = await chrome.runtime.sendMessage({ kind: 'pair', browser });
        if (!response?.ok) throw new Error(response?.error || '连接失败');
        result.textContent = '已连接。刷新已经打开的视频页面后，全屏播放即可自动调整亮度。';
        button.textContent = '已连接';
      } catch (error) {
        result.textContent = error.message;
        button.disabled = false;
      }
    });
    return;
  }

  function videosIn(root, depth = 0) {
    const videos = [...root.querySelectorAll('video')];
    if (root instanceof HTMLVideoElement) videos.push(root);
    if (depth < 3) {
      if (root.shadowRoot) videos.push(...videosIn(root.shadowRoot, depth + 1));
      for (const host of root.querySelectorAll('media-player, media-controller, mux-player')) {
        if (host.shadowRoot) videos.push(...videosIn(host.shadowRoot, depth + 1));
      }
    }
    return [...new Set(videos)];
  }

  function isWithin(video, root) {
    let node = video;
    for (let depth = 0; node && depth < 12; depth++) {
      if (node === root || root.contains(node)) return true;
      node = node.getRootNode()?.host;
    }
    return false;
  }

  function inspect() {
    const visible = document.visibilityState === 'visible';
    if (!visible) return { visible, fullscreenVideo: false, viewportVideo: false };
    const root = document.fullscreenElement || document.webkitFullscreenElement;
    const videos = videosIn(root || document).filter(video => {
      const rectangle = video.getBoundingClientRect();
      const style = getComputedStyle(video);
      return rectangle.width > 4 && rectangle.height > 4 &&
        style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity) > 0 &&
        (video.videoWidth > 0 || video.readyState > 0);
    });
    const fullscreenVideo = Boolean(root && videos.some(video => isWithin(video, root)));
    const viewportVideo = videos.some(video => {
      const rectangle = video.getBoundingClientRect();
      const width = Math.max(0, Math.min(innerWidth, rectangle.right) - Math.max(0, rectangle.left));
      const height = Math.max(0, Math.min(innerHeight, rectangle.bottom) - Math.max(0, rectangle.top));
      return width >= innerWidth * 0.85 && height >= innerHeight * 0.70 &&
        width * height >= innerWidth * innerHeight * 0.70;
    });
    return { visible, fullscreenVideo, viewportVideo };
  }

  function report() {
    try {
      chrome.runtime.sendMessage({ kind: 'state', ...inspect() }).catch(() => {});
    } catch { /* Extension reload invalidates old content-script contexts. */ }
  }
  document.addEventListener('fullscreenchange', report, true);
  document.addEventListener('webkitfullscreenchange', report, true);
  document.addEventListener('visibilitychange', report, true);
  document.addEventListener('loadedmetadata', report, true);
  window.addEventListener('pagehide', () => {
    try { chrome.runtime.sendMessage({ kind: 'state', visible: false, fullscreenVideo: false, viewportVideo: false }).catch(() => {}); } catch {}
  });
  setInterval(report, 1000);
  report();
})();
