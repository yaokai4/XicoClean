/*
 * Xico 下载助手 — content script
 * -------------------------------
 * 在每个页面（含 iframe）里扫描 <video>/<audio>/<source> 的直链，
 * 上报给 background 作为“网络捕获”的补充。
 *
 * 为什么需要它：
 *   有些页面直接把可播放的 mp4/webm 放在 <video src>，
 *   而不发出独立的媒体网络请求（或用 blob:/MSE，网络层看不到真实直链）。
 *   DOM 扫描能补上这类情况；同时它还负责响应 popup 的“重新扫描”请求，
 *   并把当前页 URL / 标题交给 popup 做兜底下载。
 */

'use strict';

(function () {
  // blob: 与 data: 无法交给外部程序下载，直接丢弃。
  function usableSrc(s) {
    return typeof s === 'string' && /^https?:\/\//i.test(s);
  }

  /** 收集当前文档里所有 <video>/<audio> 及其 <source> 子元素的直链。 */
  function collectMedia() {
    const items = [];
    const seen = new Set();

    const push = (url, width, height) => {
      if (!usableSrc(url) || seen.has(url)) return;
      seen.add(url);
      items.push({ url, width: width || 0, height: height || 0 });
    };

    const mediaEls = document.querySelectorAll('video, audio');
    mediaEls.forEach((el) => {
      // currentSrc 是浏览器实际选中的源，最可靠。
      push(el.currentSrc, el.videoWidth, el.videoHeight);
      push(el.src, el.videoWidth, el.videoHeight);
      el.querySelectorAll('source').forEach((srcEl) => {
        push(srcEl.src || srcEl.getAttribute('src'));
      });
    });

    return items;
  }

  /** 把收集到的直链推给 background。 */
  function report() {
    const items = collectMedia();
    if (!items.length) return;
    try {
      chrome.runtime.sendMessage({
        type: 'domMedia',
        items,
        pageUrl: location.href,
        pageTitle: document.title,
      });
    } catch (_) {
      /* 扩展上下文失效（如刷新时）忽略 */
    }
  }

  // 首次延迟扫描（等播放器把 <video> 挂上）。
  setTimeout(report, 800);
  setTimeout(report, 2500);

  // 监听 DOM 变化：SPA / 懒加载的播放器出现时补扫。
  let debounce = null;
  const observer = new MutationObserver(() => {
    if (debounce) return;
    debounce = setTimeout(() => {
      debounce = null;
      report();
    }, 600);
  });
  try {
    observer.observe(document.documentElement, { childList: true, subtree: true });
  } catch (_) {
    /* 某些文档 documentElement 尚不可用，忽略 */
  }

  // 响应 popup 的“立即重扫”请求，同步回传当前 DOM 媒体 + 页面信息。
  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg && msg.type === 'rescan') {
      const items = collectMedia();
      // 同时也 push 给 background，保持两边一致。
      if (items.length) {
        try {
          chrome.runtime.sendMessage({
            type: 'domMedia',
            items,
            pageUrl: location.href,
            pageTitle: document.title,
          });
        } catch (_) {}
      }
      sendResponse({
        ok: true,
        items,
        pageUrl: location.href,
        pageTitle: document.title,
      });
    }
    // 返回 true 保持 sendResponse 通道（同步已回，但保险）
    return true;
  });
})();
