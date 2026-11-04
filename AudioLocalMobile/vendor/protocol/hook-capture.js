/*
 * 协议层采集 hook（抖音 / 小红书）· 0.1.2
 *
 * 只做一件事：包住页面自己的 fetch / XHR，把「评论接口」的响应抄一份。
 * 不伪造签名、不改请求、不发新请求、不读 Cookie 与请求头。
 *
 * 0.1.2 相对 0.1.1：
 *   - XHR 也核验最终地址（responseURL）；send 抛错/中止时清理监听且不改异常行为
 *   - 引入任务代次（epoch）：stop/clear/resume 之后，旧任务的迟到响应不再入缓冲
 *   - 并发读取上限与总缓冲字节预算
 *   - 记录最终地址（重定向后仍能定位真实来源），并保留请求地址
 *
 * 注入：
 *   Playwright : context.addInitScript({ path: 'hook-capture.js' })
 *   WKWebView  : WKUserScript(source:, injectionTime: .atDocumentStart,
 *                             forMainFrameOnly: true, contentWorld: .page)
 */
(function (window) {
  'use strict';
  if (!window || window.__shengxunCaptureHook) return;
  window.__shengxunCaptureHook = true;

  var VERSION = 'capture/0.1.2-houmen.1';
  var MAX_BODY_BYTES = 512 * 1024;
  var MAX_TOTAL_BYTES = 4 * 1024 * 1024;
  var MAX_RECORDS = 200;
  var MAX_ACTIVE_READS = 4;
  var MAX_PARAM_VALUE = 64;

  var HOSTS = {
    douyin: ['www.douyin.com', 'douyin.com'],
    xiaohongshu: ['www.xiaohongshu.com', 'edith.xiaohongshu.com']
  };
  var ENDPOINTS = [
    // reply 必须排在 list 前面
    { platform: 'douyin', name: 'comment_reply', path: /^\/aweme\/v1\/web\/comment\/list\/reply\/?$/ },
    { platform: 'douyin', name: 'comment_list', path: /^\/aweme\/v1\/web\/comment\/list\/?$/ },
    { platform: 'douyin', name: 'aweme_detail', path: /^\/aweme\/v1\/web\/aweme\/detail\/?$/ },
    { platform: 'xiaohongshu', name: 'comment_page', path: /^\/api\/sns\/web\/v1\/comment\/page\/?$/ },
    { platform: 'xiaohongshu', name: 'comment_sub', path: /^\/api\/sns\/web\/v1\/comment\/sub\/page\/?$/ },
    { platform: 'xiaohongshu', name: 'note_feed', path: /^\/api\/sns\/web\/v1\/feed\/?$/ }
  ];
  var KEEP_PARAMS = ['aweme_id', 'note_id', 'item_id', 'comment_id', 'root_comment_id', 'cursor', 'count'];

  var items = [];
  var totalBytes = 0;
  var stopped = false;
  var epoch = 0;
  var activeReaders = [];
  var stats = {
    seen: 0, matched: 0, stored: 0, tooLarge: 0, failed: 0,
    rejected: 0, staleEpoch: 0, budgetSkipped: 0
  };

  function toUrl(value) {
    try {
      var base = window.location && window.location.href;
      if (typeof value === 'string') return new URL(value, base);
      if (value && typeof value.url === 'string') return new URL(value.url, base);   // Request
      if (value && typeof value.href === 'string') return new URL(value.href, base); // URL
    } catch (e) { /* 落空 */ }
    return null;
  }

  function match(value) {
    var url = toUrl(value);
    if (!url || url.protocol !== 'https:') return null;
    var host = url.hostname.toLowerCase();
    for (var i = 0; i < ENDPOINTS.length; i += 1) {
      var endpoint = ENDPOINTS[i];
      if (HOSTS[endpoint.platform].indexOf(host) >= 0 && endpoint.path.test(url.pathname)) {
        return { endpoint: endpoint, url: url };
      }
    }
    return null;
  }

  function samePlatform(meta, value) {
    if (!value) return true; // 没给最终地址就沿用请求的元数据
    var other = match(value);
    return Boolean(other && other.endpoint.platform === meta.endpoint.platform);
  }

  function sanitizeUrl(input) {
    try {
      var url = input instanceof URL ? input : new URL(String(input), window.location && window.location.href);
      var kept = new URLSearchParams();
      for (var i = 0; i < KEEP_PARAMS.length; i += 1) {
        var values = url.searchParams.getAll(KEEP_PARAMS[i]);
        for (var j = 0; j < values.length; j += 1) {
          if (values[j].length <= MAX_PARAM_VALUE) kept.append(KEEP_PARAMS[i], values[j]);
        }
      }
      var query = kept.toString();
      return url.origin + url.pathname + (query ? '?' + query : '');
    } catch (e) {
      return '';
    }
  }

  function byteLength(text) {
    try {
      if (typeof TextEncoder !== 'undefined') return new TextEncoder().encode(text).length;
    } catch (e) { /* 退化为字符数 */ }
    return text.length;
  }

  function trimBuffer() {
    while (items.length > MAX_RECORDS || totalBytes > MAX_TOTAL_BYTES) {
      var removed = items.shift();
      if (!removed) break;
      totalBytes -= removed.bytes;
    }
  }

  function record(meta, requestUrl, finalUrl, status, body, boundEpoch) {
    if (boundEpoch !== epoch) { stats.staleEpoch += 1; return; }
    stats.matched += 1;
    if (stopped) { stats.rejected += 1; return; }
    if (typeof body !== 'string') { stats.failed += 1; return; }
    var bytes = byteLength(body);
    if (bytes > MAX_BODY_BYTES) { stats.tooLarge += 1; return; }

    var request = sanitizeUrl(requestUrl);
    var final = finalUrl ? sanitizeUrl(finalUrl) : request;
    if (!final) { stats.failed += 1; return; }

    items.push({
      platform: meta.endpoint.platform,
      name: meta.endpoint.name,
      url: final,
      requestUrl: request,
      redirected: Boolean(request && final && request !== final),
      status: status,
      bytes: bytes,
      at: new Date().toISOString(),
      body: body
    });
    totalBytes += bytes;
    trimBuffer();
    stats.stored += 1;
  }

  // A reader belongs to one task. Remove it synchronously before cancelling; its
  // later release callback cannot decrement a separate counter below zero.
  function cancelActiveReaders() {
    var readers = activeReaders.splice(0);
    for (var i = 0; i < readers.length; i += 1) {
      try { Promise.resolve(readers[i].cancel()).catch(function () {}); } catch (e) { /* ignore */ }
    }
  }

  function readBounded(response, meta, requestUrl, boundEpoch) {
    if (boundEpoch !== epoch) { stats.staleEpoch += 1; return; }
    if (stopped) { stats.rejected += 1; return; }
    if (!samePlatform(meta, response && response.url ? toUrl(response.url) : null)) {
      stats.rejected += 1;
      return;
    }
    var finalUrl = response && response.url ? toUrl(response.url) : null;

    // Check before clone(): do not create an unread tee branch when at capacity.
    if (activeReaders.length >= MAX_ACTIVE_READS) { stats.budgetSkipped += 1; return; }
    var clone;
    try { clone = response.clone(); } catch (e) { stats.failed += 1; return; }

    if (!clone.body || typeof clone.body.getReader !== 'function') {
      clone.text().then(function (text) {
        record(meta, requestUrl, finalUrl, response.status, text, boundEpoch);
      }).catch(function () { stats.failed += 1; });
      return;
    }

    var reader = clone.body.getReader();
    activeReaders.push(reader);
    var finished = false;
    var chunks = [];
    var total = 0;
    var decoder = typeof TextDecoder !== 'undefined' ? new TextDecoder('utf-8') : null;

    function release() {
      if (finished) return;
      finished = true;
      var index = activeReaders.indexOf(reader);
      if (index >= 0) activeReaders.splice(index, 1);
    }

    function pump() {
      reader.read().then(function (step) {
        if (step.done) {
          var text = '';
          for (var i = 0; i < chunks.length; i += 1) {
            text += decoder ? decoder.decode(chunks[i], { stream: true }) : '';
          }
          if (decoder) text += decoder.decode();
          release();
          record(meta, requestUrl, finalUrl, response.status, text, boundEpoch);
          return;
        }
        total += step.value.byteLength;
        if (total > MAX_BODY_BYTES) {
          stats.tooLarge += 1;
          release();
          reader.cancel().catch(function () {});
          return;
        }
        chunks.push(step.value);
        pump();
      }).catch(function () { release(); stats.failed += 1; });
    }
    pump();
  }

  // ---- fetch ----
  var realFetch = window.fetch;
  if (typeof realFetch === 'function') {
    window.fetch = function (input) {
      var meta = match(input);
      var bound = epoch;
      var promise = realFetch.apply(this, arguments);
      if (!meta) return promise;
      return promise.then(function (response) {
        stats.seen += 1;
        readBounded(response, meta, meta.url.href, bound);
        return response;
      });
    };
  }

  // ---- XMLHttpRequest ----
  var RealXHR = window.XMLHttpRequest;
  if (typeof RealXHR === 'function') {
    var open = RealXHR.prototype.open;
    var send = RealXHR.prototype.send;

    RealXHR.prototype.open = function (method, url) {
      this.__shengxunMeta = match(url);
      return open.apply(this, arguments);
    };

    RealXHR.prototype.send = function () {
      var meta = this.__shengxunMeta;
      var xhr = this;
      if (!meta) return send.apply(this, arguments);

      var bound = epoch;
      var done = false;
      function handler() {
        if (done) return;
        done = true;
        detach();
        try {
          var finalUrl = xhr.responseURL ? toUrl(xhr.responseURL) : null;
          if (!samePlatform(meta, finalUrl)) { stats.rejected += 1; return; }
          var type = xhr.responseType;
          var text = '';
          if (type === '' || type === 'text') text = xhr.responseText;
          else if (type === 'json') text = JSON.stringify(xhr.response);
          stats.seen += 1;
          record(meta, meta.url.href, finalUrl || meta.url, xhr.status, text, bound);
        } catch (e) { stats.failed += 1; }
      }
      function detach() {
        if (typeof xhr.removeEventListener === 'function') xhr.removeEventListener('loadend', handler);
      }
      xhr.addEventListener('loadend', handler);

      try {
        return send.apply(this, arguments);
      } catch (error) {
        done = true;
        detach();
        throw error;  // 不吞原生异常
      }
    };
  }

  window.__shengxunCapture = {
    version: VERSION,
    get stats() { return stats; },
    get epoch() { return epoch; },
    patterns: ENDPOINTS.map(function (e) { return e.platform + ':' + e.name; }),
    take: function () { var out = items.slice(); items.length = 0; totalBytes = 0; return out; },
    peek: function () { return items.slice(); },
    /** 换任务（换关键词/换品牌）：旧代次的迟到响应会被丢弃 */
    beginTask: function () { epoch += 1; stopped = false; cancelActiveReaders(); return epoch; },
    /** 停用：代次失效 + 取消进行中的读取 */
    stop: function () {
      stopped = true;
      epoch += 1;
      cancelActiveReaders();
    },
    /** 恢复：新代次，旧响应不再入缓冲 */
    resume: function () { stopped = false; epoch += 1; cancelActiveReaders(); return epoch; },
    clear: function () { items.length = 0; totalBytes = 0; }
  };
})(typeof window !== 'undefined' ? window : undefined);
