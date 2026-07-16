/*
 * Xico 下载助手 — background service worker (MV3)
 * ------------------------------------------------
 * 职责：
 *   1) 用 chrome.webRequest.onBeforeRequest 观察每个标签页发出的媒体请求，
 *      记录“最佳候选”媒体地址（尤其 video.twimg.com 的 X/Twitter 视频）。
 *   2) 用 content.js 上报的 <video>/<source> 直链做补充。
 *   3) 按“可播放的真实媒体文件”优先级排序，暴露给 popup。
 *
 * MV3 约束说明：
 *   - service worker 没有持久 DOM，随时可能被浏览器休眠回收。
 *   - 我们用一个内存 Map（capturedByTab）保存捕获结果；它只在 worker 存活期间有效。
 *   - 这没关系：媒体请求会在用户播放/加载页面时持续发生，worker 被唤醒后
 *     onBeforeRequest 会重新填充数据。真正需要跨唤醒保活的东西这里没有。
 *   - 我们额外把每个标签的候选镜像进 chrome.storage.session（若可用），
 *     让 popup 在 worker 刚被唤醒、内存还空的一瞬间也能拿到上次结果。
 */

'use strict';

// tabId -> Array<Candidate>
// Candidate = { url, container, kind, width, height, source, score, ts }
const capturedByTab = new Map();

const MAX_PER_TAB = 30;

// chrome.storage.session 在部分旧浏览器里不存在；做个安全包装。
const sessionStore = (chrome.storage && chrome.storage.session) || null;

// ---------------------------------------------------------------------------
// URL 分类 / 打分
// ---------------------------------------------------------------------------

// 视频/流媒体容器后缀
const VIDEO_EXTS = ['m3u8', 'mpd', 'mp4', 'm4v', 'mov', 'webm', 'ts', 'm4s', 'flv'];
// 音频容器后缀
const AUDIO_EXTS = ['m4a', 'mp3', 'aac', 'opus', 'ogg', 'oga', 'wav', 'flac'];
// 明确要排除的“非主媒体”（缩略图、封面、字幕、图标等）
const EXCLUDE_EXTS = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'ico', 'svg', 'vtt', 'srt', 'css', 'js', 'woff', 'woff2', 'ttf'];

// X / Twitter 视频 CDN
const TWITTER_VIDEO_HOST = 'video.twimg.com';

/** 取 URL 的 host（失败返回空串）。 */
function hostOf(url) {
  try {
    return new URL(url).host.toLowerCase();
  } catch (_) {
    return '';
  }
}

/** 取 URL 的 pathname（小写，无 query/hash）；失败时退回粗切。 */
function pathOf(url) {
  try {
    return new URL(url).pathname.toLowerCase();
  } catch (_) {
    return String(url).split('?')[0].split('#')[0].toLowerCase();
  }
}

/** 从 pathname 末尾取扩展名（无点）。 */
function extOf(url) {
  const p = pathOf(url);
  const seg = p.substring(p.lastIndexOf('/') + 1);
  const dot = seg.lastIndexOf('.');
  return dot >= 0 ? seg.substring(dot + 1) : '';
}

/**
 * 判断 URL 是否是我们关心的媒体，并归一化出容器与 kind。
 * 返回 null 表示不关心。
 */
function classify(url) {
  const host = hostOf(url);
  const path = pathOf(url);
  const ext = extOf(url);

  if (EXCLUDE_EXTS.includes(ext)) return null;

  // 有些 CDN 把真实后缀藏在路径中间（如 .../file.mp4/seg-1.ts?token=）
  const pathHasVideo = VIDEO_EXTS.some((e) => path.includes('.' + e));
  const pathHasAudio = AUDIO_EXTS.some((e) => path.includes('.' + e));

  let container = null;
  let kind = null;

  if (VIDEO_EXTS.includes(ext) || pathHasVideo) {
    container = VIDEO_EXTS.includes(ext) ? ext : VIDEO_EXTS.find((e) => path.includes('.' + e));
    kind = 'video';
  } else if (AUDIO_EXTS.includes(ext) || pathHasAudio) {
    container = AUDIO_EXTS.includes(ext) ? ext : AUDIO_EXTS.find((e) => path.includes('.' + e));
    kind = 'audio';
  } else if (host === TWITTER_VIDEO_HOST) {
    // twimg 有时会带 tag/token，扩展名不在末尾；只要来自视频 CDN 且不是图片就收。
    container = path.includes('.m3u8') ? 'm3u8' : 'mp4';
    kind = 'video';
  } else {
    return null;
  }

  // 解析分辨率：twitter 直链形如 .../vid/avc1/1280x720/... 或 .../vid/1280x720/...
  let width = 0;
  let height = 0;
  const res = path.match(/\/(\d{2,4})x(\d{2,4})\//);
  if (res) {
    width = parseInt(res[1], 10);
    height = parseInt(res[2], 10);
  }

  return { container, kind, width, height };
}

/**
 * 给候选打分：越像“可直接播放/下载的完整媒体文件”分越高。
 * 关键排序意图（X 场景）：
 *   最高码率的 video.twimg.com .mp4  >  m3u8 主播放列表  >  .ts 分段/缩略图。
 */
function scoreCandidate(c) {
  const host = hostOf(c.url);
  const path = pathOf(c.url);
  let s = 0;

  // 1) 容器基础分：完整 mp4/webm 直链最优；HLS/DASH 播放列表次之；裸分段最差。
  switch (c.container) {
    case 'mp4':
    case 'm4v':
    case 'mov':
    case 'webm':
      s += 100;
      break;
    case 'm3u8': // HLS 播放列表（可能是 master，也可能是 media）
      s += 80;
      break;
    case 'mpd': // DASH manifest
      s += 72;
      break;
    case 'm4a':
    case 'mp3':
    case 'aac':
    case 'opus':
    case 'ogg':
    case 'flac':
    case 'wav':
      s += 60;
      break;
    case 'ts':
    case 'm4s': // 裸媒体分段：单独下没意义，最低
      s += 8;
      break;
    default:
      s += 40;
  }

  // 2) X/Twitter 视频 CDN 加成（这是本扩展存在的主要理由）。
  if (host === TWITTER_VIDEO_HOST) s += 50;

  // 3) 分辨率：面积越大越好，封顶 +60，避免超大数值压过容器权重。
  if (c.width && c.height) {
    s += Math.min(60, (c.width * c.height) / 40000);
  }

  // 4) DOM 直链（<video src>）通常是当前正在播放的真实媒体，可靠，小幅加成。
  if (c.source === 'dom') s += 20;

  // 5) 明显是分段/缩略图/预览的降权。
  if (/\/seg(ment)?[-_/]?\d+/i.test(path) || /[-_]seg[-_]?\d+/i.test(path)) s -= 30;
  if (/thumb|poster|preview|sprite|storyboard/i.test(path)) s -= 60;

  return s;
}

// ---------------------------------------------------------------------------
// 每标签候选管理
// ---------------------------------------------------------------------------

function getList(tabId) {
  let list = capturedByTab.get(tabId);
  if (!list) {
    list = [];
    capturedByTab.set(tabId, list);
  }
  return list;
}

/** 加入一个候选（去重 + 打分 + 排序 + 截断），返回是否新增。 */
function addCandidate(tabId, partial) {
  if (tabId == null || tabId < 0) return false;
  if (!partial || !partial.url) return false;

  // 与桌面端共用同一红线：只收有主机、无内嵌凭据、长度受限的 http(s)。
  // blob:/data:/file:/javascript: 无法安全交给外部下载器，全部跳过。
  if (typeof partial.url !== 'string' || partial.url.length > 32768) return false;
  try {
    const parsed = new URL(partial.url);
    if (!['http:', 'https:'].includes(parsed.protocol) || !parsed.hostname ||
        parsed.username || parsed.password) return false;
  } catch (_) {
    return false;
  }

  const list = getList(tabId);
  if (list.some((c) => c.url === partial.url)) return false; // 去重

  const c = {
    url: partial.url,
    container: partial.container || 'unknown',
    kind: partial.kind || 'video',
    width: partial.width || 0,
    height: partial.height || 0,
    source: partial.source || 'network',
    ts: Date.now(),
  };
  c.score = scoreCandidate(c);

  list.push(c);
  list.sort((a, b) => b.score - a.score || b.ts - a.ts);
  if (list.length > MAX_PER_TAB) list.length = MAX_PER_TAB;

  persist(tabId, list);
  updateBadge(tabId, list.length);
  return true;
}

/** 清空某标签（导航到新页面时）。 */
function clearTab(tabId) {
  capturedByTab.delete(tabId);
  if (sessionStore) sessionStore.remove('tab_' + tabId).catch(() => {});
  updateBadge(tabId, 0);
}

/** 镜像进 session storage，供 worker 冷启动时的 popup 兜底读取。 */
function persist(tabId, list) {
  if (!sessionStore) return;
  sessionStore.set({ ['tab_' + tabId]: list }).catch(() => {});
}

/** 从 session storage 恢复（worker 刚被唤醒、内存为空时）。 */
async function restore(tabId) {
  if (capturedByTab.has(tabId)) return capturedByTab.get(tabId);
  if (!sessionStore) return [];
  try {
    const data = await sessionStore.get('tab_' + tabId);
    const list = data['tab_' + tabId] || [];
    if (list.length) capturedByTab.set(tabId, list);
    return list;
  } catch (_) {
    return [];
  }
}

/** 在扩展图标上显示当前标签捕获数量。 */
function updateBadge(tabId, count) {
  try {
    chrome.action.setBadgeText({ tabId, text: count ? String(count) : '' });
    chrome.action.setBadgeBackgroundColor({ tabId, color: '#6D4AFF' });
  } catch (_) {
    /* 某些时机（tab 已关闭）会抛错，忽略 */
  }
}

// ---------------------------------------------------------------------------
// webRequest：观察媒体请求
// ---------------------------------------------------------------------------

chrome.webRequest.onBeforeRequest.addListener(
  (details) => {
    const { tabId, url, type } = details;

    // 主框架导航 = 页面切换：清空该标签旧的捕获，避免跨页面串味。
    // （用 main_frame 判断导航，这样就不必额外申请 webNavigation 权限。）
    if (type === 'main_frame') {
      clearTab(tabId);
      return;
    }

    if (tabId < 0) return; // 非标签页发起的请求（扩展/后台）不处理

    const info = classify(url);
    if (!info) return;

    addCandidate(tabId, {
      url,
      container: info.container,
      kind: info.kind,
      width: info.width,
      height: info.height,
      source: 'network',
    });
  },
  { urls: ['<all_urls>'] }
  // 注意：不加 'requestBody' 等 extraInfoSpec，onBeforeRequest 只做观察。
);

// ---------------------------------------------------------------------------
// 标签生命周期清理
// ---------------------------------------------------------------------------

chrome.tabs.onRemoved.addListener((tabId) => clearTab(tabId));

// 地址栏导航（含 SPA history 变化里会重新触发 main_frame 的情况已由上面覆盖，
// 这里再兜底：当 URL 发生整页变化时清空）。
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === 'loading' && changeInfo.url) {
    // 仅当确实换了地址时清空（changeInfo.url 只有整页导航才有）
    clearTab(tabId);
  }
});

// ---------------------------------------------------------------------------
// 打开 xico:// 深链（干扰最小方案）
// ---------------------------------------------------------------------------

/*
 * 用一个“后台瞬时标签”触发系统协议处理器（macOS 打开 Xico），随后立刻关掉它。
 * 为什么不用其它方式：
 *   - chrome.tabs.update(当前标签, {url: deepLink}) 会把用户正在看的页面导航走 ❌
 *   - 在 popup 里 window.location=deepLink 常被拦、且 popup 会立刻关闭 ⚠️
 *   - 后台新标签触发协议、随即关闭：用户当前标签不受影响，几乎无感 ✅
 * 放在 SW 里执行，保证 popup 关闭后瞬时标签仍能被可靠删除。
 */
function openTransientDeepLink(deepLink) {
  return new Promise((resolve, reject) => {
    try {
      chrome.tabs.create({ url: deepLink, active: false }, (t) => {
        if (chrome.runtime.lastError || !t) {
          return reject(chrome.runtime.lastError || new Error('create failed'));
        }
        // 给外部协议处理器一点时间被触发，然后收掉这个标签。
        setTimeout(() => {
          chrome.tabs.remove(t.id).catch(() => {});
        }, 900);
        resolve();
      });
    } catch (e) {
      reject(e);
    }
  });
}

/** 只允许 popup 生成的 xico://download 深链，拒绝任意协议/激活等越权消息。 */
function isSafeDownloadDeepLink(raw) {
  try {
    if (typeof raw !== 'string' || raw.length > 65536) return false;
    const u = new URL(raw);
    if (u.protocol !== 'xico:' || u.hostname !== 'download') return false;
    const target = new URL(u.searchParams.get('url') || '');
    if (target.protocol !== 'https:' && target.protocol !== 'http:') return false;
    const kind = u.searchParams.get('kind') || 'video';
    return ['video', 'audio', 'image'].includes(kind);
  } catch (_) {
    return false;
  }
}

/** 特权动作只接受扩展自己的 popup；普通网页/内容脚本不能借消息通道打开协议或读其它标签。 */
function isPopupSender(sender) {
  return !sender.tab && sender.url === chrome.runtime.getURL('popup.html');
}

// ---------------------------------------------------------------------------
// 与 popup / content 的消息通道
// ---------------------------------------------------------------------------

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || !msg.type) return;

  switch (msg.type) {
    // content.js 上报 DOM 里发现的 <video>/<source> 直链
    case 'domMedia': {
      const tabId = sender.tab && sender.tab.id;
      if (tabId != null && Array.isArray(msg.items)) {
        for (const it of msg.items.slice(0, 60)) {
          const info = classify(it.url) || {};
          addCandidate(tabId, {
            url: it.url,
            container: info.container || extOf(it.url) || 'unknown',
            kind: info.kind || 'video',
            width: info.width || it.width || 0,
            height: info.height || it.height || 0,
            source: 'dom',
          });
        }
      }
      sendResponse({ ok: true });
      return true;
    }

    // popup 请求某标签的候选列表
    case 'getCaptures': {
      if (!isPopupSender(sender) || !Number.isInteger(msg.tabId) || msg.tabId < 0) {
        sendResponse({ ok: false, error: 'unauthorized' });
        return true;
      }
      const tabId = msg.tabId;
      restore(tabId).then((list) => {
        sendResponse({
          ok: true,
          items: (list || []).map((c) => ({
            url: c.url,
            container: c.container,
            kind: c.kind,
            width: c.width,
            height: c.height,
            source: c.source,
            score: c.score,
          })),
        });
      });
      return true; // 异步 sendResponse
    }

    // popup 手动清空某标签
    case 'clearCaptures': {
      if (!isPopupSender(sender) || !Number.isInteger(msg.tabId) || msg.tabId < 0) {
        sendResponse({ ok: false, error: 'unauthorized' });
        return true;
      }
      clearTab(msg.tabId);
      sendResponse({ ok: true });
      return true;
    }

    // popup 请求打开 xico:// 深链。
    // 关键：一定要在 background（service worker）里建/删这个瞬时标签，
    // 而不是在 popup 里——因为 popup 点完就关，它内部的 setTimeout 会被销毁，
    // 导致那个瞬时标签删不掉、残留在浏览器里。SW 独立于 popup 存活，稳妥。
    case 'openDeepLink': {
      if (!isPopupSender(sender) || !isSafeDownloadDeepLink(msg.url)) {
        sendResponse({ ok: false, error: 'invalid deep link' });
        return true;
      }
      openTransientDeepLink(msg.url)
        .then(() => sendResponse({ ok: true }))
        .catch((e) => sendResponse({ ok: false, error: String(e) }));
      return true; // 异步
    }

    default:
      return;
  }
});
