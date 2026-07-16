/*
 * Xico 下载助手 — popup 逻辑
 * --------------------------
 * 打开时：拿到当前标签 → 向 background 要“网络捕获”的候选，
 * 同时让 content.js 立刻重扫 DOM，两边合并去重后渲染。
 * 点击：拼出 xico://download?url=...&kind=... 深链，交给 Xico 桌面版。
 */

'use strict';

const state = {
  tabId: null,
  tabUrl: '',
  tabTitle: '',
  kind: 'video', // 用户在类型选择器里选的 kind（主按钮/兜底用）
  items: [], // 合并后的候选
};

// ---------------------------------------------------------------------------
// 深链构造与打开
// ---------------------------------------------------------------------------

/** 构造 Xico 深链。url 必须整体编码，避免其自带的 & ? = 破坏我们的参数。 */
function buildDeepLink(mediaUrl, kind) {
  return (
    'xico://download?url=' +
    encodeURIComponent(mediaUrl) +
    '&kind=' +
    encodeURIComponent(kind || 'video')
  );
}

/*
 * 打开深链的机制（重要设计决策）：
 *
 * 备选方案对比：
 *   A) chrome.tabs.update(activeTabId, {url: deepLink})
 *      —— 会把用户当前正在看的页面（比如那条带视频的 X 推文）导航走，
 *         体验很差，且可能丢失页面状态。❌
 *   B) 在 popup 里 window.location.href = deepLink
 *      —— popup 是独立文档，设它的 location 只会导航 popup 自身；
 *         自定义协议在 popup 里常被拦或表现怪异，且 popup 会立刻关闭。
 *         只作为最后兜底。⚠️
 *   C) chrome.tabs.create({url: deepLink, active:false}) 然后很快 remove
 *      —— 新建一个“后台”标签来触发外部协议处理器（macOS 打开 Xico），
 *         用户当前标签完全不受影响；随后把这个瞬时标签关掉，用户几乎无感。
 *         这是干扰最小的方案。✅（首选）
 *
 * 谁来建/删这个瞬时标签，是个坑：如果在 popup 里做，popup 点完就 window.close()，
 * 它内部负责“删掉瞬时标签”的 setTimeout 会随 popup 文档一起销毁 → 标签残留。
 * 所以首选路径是 **把打开动作委托给 background service worker**（它独立于 popup 存活），
 * 由 SW 负责建标签 + 定时删标签。popup 只管发消息，然后可以放心关闭。
 *
 * 首次使用时浏览器可能弹“要打开 Xico 吗？”确认框——这是系统级行为，无法绕过，属正常预期。
 */
async function openDeepLink(mediaUrl, kind) {
  const deepLink = buildDeepLink(mediaUrl, kind);

  // 首选：交给 background（SW）建/删瞬时标签，避免 popup 关闭导致标签残留。
  const viaBg = await new Promise((resolve) => {
    try {
      chrome.runtime.sendMessage({ type: 'openDeepLink', url: deepLink }, (resp) => {
        resolve(!chrome.runtime.lastError && resp && resp.ok);
      });
    } catch (_) {
      resolve(false);
    }
  });
  if (viaBg) return { ok: true, viaBackground: true };

  // 兜底 C'：background 不可用时，popup 自己建标签。
  // 注意此路径下不要立刻 window.close()，否则删标签的 setTimeout 会被销毁。
  try {
    const t = await chrome.tabs.create({ url: deepLink, active: false });
    setTimeout(() => chrome.tabs.remove(t.id).catch(() => {}), 900);
    return { ok: true, viaBackground: false };
  } catch (_) {
    // 最后兜底 B：从 popup 自身导航到深链
    try {
      window.location.href = deepLink;
      return { ok: true, viaBackground: false };
    } catch (_2) {
      return { ok: false, viaBackground: false };
    }
  }
}

// ---------------------------------------------------------------------------
// 取数据：网络捕获 + DOM 重扫，合并
// ---------------------------------------------------------------------------

function askBackground(tabId) {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage({ type: 'getCaptures', tabId }, (resp) => {
      if (chrome.runtime.lastError || !resp || !resp.ok) return resolve([]);
      resolve(resp.items || []);
    });
  });
}

function askContentRescan(tabId) {
  return new Promise((resolve) => {
    chrome.tabs.sendMessage(tabId, { type: 'rescan' }, (resp) => {
      // content 未注入（如 chrome:// 页面）时 lastError 会有值，静默降级。
      if (chrome.runtime.lastError || !resp || !resp.ok) {
        return resolve({ items: [], pageUrl: '', pageTitle: '' });
      }
      resolve(resp);
    });
  });
}

/** 简单容器推断（供 DOM 直链补标签用）。 */
function guessContainer(url) {
  const path = url.split('?')[0].split('#')[0].toLowerCase();
  const seg = path.substring(path.lastIndexOf('/') + 1);
  const dot = seg.lastIndexOf('.');
  const ext = dot >= 0 ? seg.substring(dot + 1) : '';
  return ext || 'media';
}

async function loadData() {
  const [netItems, dom] = await Promise.all([
    askBackground(state.tabId),
    askContentRescan(state.tabId),
  ]);

  if (dom.pageTitle) {
    state.tabTitle = dom.pageTitle;
    state.tabUrl = dom.pageUrl || state.tabUrl;
  }

  // 合并去重：以 background 的候选为主（已打分排序），DOM 补充其未包含的。
  const map = new Map();
  for (const it of netItems) map.set(it.url, it);
  for (const it of dom.items || []) {
    if (!map.has(it.url)) {
      map.set(it.url, {
        url: it.url,
        container: guessContainer(it.url),
        kind: 'video',
        width: it.width || 0,
        height: it.height || 0,
        source: 'dom',
        score: 0,
      });
    }
  }

  // 背景返回的已按分排序；DOM 追加项排在后面即可，这里保持插入顺序但把
  // 有 score 的排前。为稳妥，统一按 score 再排一次（score 为 0 的 DOM 补充殿后）。
  state.items = Array.from(map.values()).sort(
    (a, b) => (b.score || 0) - (a.score || 0)
  );
}

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------

const $ = (id) => document.getElementById(id);

function tagClassFor(item) {
  const host = (() => {
    try {
      return new URL(item.url).host.toLowerCase();
    } catch (_) {
      return '';
    }
  })();
  if (host === 'video.twimg.com') return 'twitter';
  return (item.container || '').toLowerCase();
}

function tagLabelFor(item) {
  const host = (() => {
    try {
      return new URL(item.url).host.toLowerCase();
    } catch (_) {
      return '';
    }
  })();
  if (host === 'video.twimg.com') return 'X 视频';
  return (item.container || 'media').toUpperCase();
}

function render() {
  $('pageTitle').textContent = state.tabTitle || state.tabUrl || '当前标签';
  $('count').textContent = String(state.items.length);

  // 主按钮副标题：说明将下载什么
  const best = state.items[0];
  if (best) {
    $('primarySub').textContent = '最佳来源：' + tagLabelFor(best);
  } else {
    $('primarySub').textContent = '下载此页面（由 Xico 解析）';
  }

  const list = $('list');
  const empty = $('empty');

  // 清掉除 empty 之外的旧节点
  list.querySelectorAll('.item').forEach((n) => n.remove());

  if (!state.items.length) {
    empty.style.display = '';
    return;
  }
  empty.style.display = 'none';

  state.items.forEach((item, idx) => {
    const row = document.createElement('div');
    row.className = 'item' + (idx === 0 ? ' best' : '');

    const body = document.createElement('div');
    body.className = 'item-body';

    const r1 = document.createElement('div');
    r1.className = 'item-row1';

    const tag = document.createElement('span');
    tag.className = 'tag ' + tagClassFor(item);
    tag.textContent = tagLabelFor(item);
    r1.appendChild(tag);

    if (idx === 0) {
      const b = document.createElement('span');
      b.className = 'badge-best';
      b.textContent = '最佳';
      r1.appendChild(b);
    }

    if (item.width && item.height) {
      const res = document.createElement('span');
      res.className = 'res';
      res.textContent = item.width + '×' + item.height;
      r1.appendChild(res);
    }

    const urlEl = document.createElement('div');
    urlEl.className = 'item-url';
    urlEl.textContent = item.url;
    urlEl.title = item.url;

    body.appendChild(r1);
    body.appendChild(urlEl);

    const btn = document.createElement('button');
    btn.className = 'dl';
    btn.title = '用 Xico 下载这个';
    btn.innerHTML =
      '<svg viewBox="0 0 24 24" width="16" height="16">' +
      '<path d="M12 4v9m0 0 3.2-3.2M12 13l-3.2-3.2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>' +
      '<path d="M6 19h12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>' +
      '</svg>';
    btn.addEventListener('click', () => {
      // 每个条目用其自身推断的 kind（video/audio），否则退回选择器的 kind。
      const itemKind = item.kind || state.kind;
      handoff(item.url, itemKind);
    });

    row.appendChild(body);
    row.appendChild(btn);
    list.appendChild(row);
  });
}

// ---------------------------------------------------------------------------
// 交互
// ---------------------------------------------------------------------------

function toast(text) {
  const t = $('toast');
  t.textContent = text;
  t.classList.add('show');
  setTimeout(() => t.classList.remove('show'), 1600);
}

async function handoff(url, kind) {
  const res = await openDeepLink(url, kind);
  if (res.ok) {
    toast('已发送到 Xico ✓');
    if (res.viaBackground) {
      // background 拥有瞬时标签，popup 可以放心自动关闭。
      setTimeout(() => window.close(), 700);
    }
    // 若是 popup 自建标签的兜底路径，则不自动关闭，交由用户手动关，
    // 以免销毁负责删除瞬时标签的 setTimeout。
  } else {
    toast('无法打开 Xico，请确认已安装');
  }
}

function wireKindSelector() {
  document.querySelectorAll('.kind').forEach((btn) => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.kind').forEach((b) => {
        b.classList.remove('active');
        b.setAttribute('aria-selected', 'false');
      });
      btn.classList.add('active');
      btn.setAttribute('aria-selected', 'true');
      state.kind = btn.dataset.kind;
    });
  });
}

function wirePrimary() {
  $('primary').addEventListener('click', () => {
    const best = state.items[0];
    if (best) {
      // 有捕获到的真实媒体：交出最佳直链。
      // 主按钮尊重用户选择器的 kind（例如想把视频当音频抓也行），
      // 但若最佳项本身是音频而用户仍选 video，也以用户选择为准。
      handoff(best.url, state.kind);
    } else {
      // 没捕获到：把当前页面地址交给 Xico，其内置 yt-dlp 解析器去尝试。
      const pageUrl = state.tabUrl;
      if (!pageUrl) {
        toast('无法读取当前页面地址');
        return;
      }
      handoff(pageUrl, state.kind);
    }
  });
}

// ---------------------------------------------------------------------------
// 启动
// ---------------------------------------------------------------------------

async function init() {
  wireKindSelector();
  wirePrimary();

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) {
    $('pageTitle').textContent = '无法读取当前标签';
    return;
  }
  state.tabId = tab.id;
  state.tabUrl = tab.url || '';
  state.tabTitle = tab.title || '';
  render(); // 先渲染标题占位

  await loadData();
  render();
}

document.addEventListener('DOMContentLoaded', init);
