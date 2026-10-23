chrome.runtime.sendMessage({ kind: 'status' }).then(status => {
  document.getElementById('status').textContent = status.paired
    ? status.live ? '已连接菜单栏工具。' : '已配对，等待菜单栏工具运行。'
    : '尚未配对。';
}).catch(() => { document.getElementById('status').textContent = '请重新加载扩展后再连接。'; });
