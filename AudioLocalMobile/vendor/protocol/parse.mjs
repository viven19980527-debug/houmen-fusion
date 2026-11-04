// 评论响应解析（0.1.2）。
// 0.1.2 相对 0.1.1：
//   - 按端点固定根数组，不再靠分数猜主评论/回复
//   - 分页字段逐项合并（父层只有 total 时不会吞掉根层 cursor）
//   - 任务代次之外的来源绑定：评论、详情、导出三层都带 platform + sourceId
//   - 导出 iOS 原生需要的六个来源证据字段（只在来源核验通过时给）
//   - 大整数 ID 用词法扫描加引号，能处理转义键名与指数写法
//   - 字符串业务状态、内层空数组、平铺 user_id 等边界

const ID_KEYS = ['cid', 'comment_id', 'commentId', 'id'];
const TEXT_KEYS = ['text', 'content', 'comment'];
const USER_KEYS = ['user', 'user_info', 'userInfo', 'author'];
const NAME_KEYS = ['nickname', 'nick_name', 'name', 'screen_name'];
const USER_ID_KEYS = ['sec_uid', 'secUid', 'user_id', 'userId', 'uid'];
const HANDLE_KEYS = ['unique_id', 'uniqueId', 'short_id', 'red_id'];
const TIME_KEYS = ['create_time', 'createTime', 'created_at', 'createdAt', 'timestamp', 'time'];
const IP_KEYS = ['ip_label', 'ipLabel', 'ip_location', 'ipLocation'];
const LIKE_KEYS = ['digg_count', 'diggCount', 'like_count', 'likeCount'];
const REPLY_COUNT_KEYS = ['reply_comment_total', 'sub_comment_count', 'subCommentCount', 'reply_count'];
const REPLIES_KEYS = ['sub_comments', 'subComments', 'replies', 'reply_comments'];
const BIG_ID_KEYS = new Set(['cid', 'comment_id', 'commentId', 'id', 'user_id', 'userId', 'uid',
  'aweme_id', 'note_id', 'item_id', 'parent_comment_id']);

export const NATIVE_SOURCE_POLICY = 'published_tiered_7_30_90_latest';

const ROOT_PATHS = {
  douyin: {
    comment_list: ['comments'],
    comment_reply: ['comments'],
  },
  xiaohongshu: {
    comment_page: ['data', 'comments'],
    comment_sub: ['data', 'comments'],
  },
};

function pick(object, keys) {
  if (!object || typeof object !== 'object') return undefined;
  for (const key of keys) {
    const value = object[key];
    if (value !== undefined && value !== null && value !== '') return value;
  }
  return undefined;
}

function textOf(value) {
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number') return String(value);
  return '';
}

/**
 * 词法扫描：只在「ID 键」对应的值位置给 16 位以上整数加引号。
 * 能处理 `\u0063id` 这类转义键名，也不会碰字符串里的数字或指数写法。
 */
export function quoteUnsafeIntegerIds(text) {
  const source = String(text);
  let out = '';
  let index = 0;
  let lastKey = null;

  while (index < source.length) {
    const ch = source[index];

    if (ch === '"') {
      let end = index + 1;
      while (end < source.length) {
        if (source[end] === '\\') { end += 2; continue; }
        if (source[end] === '"') break;
        end += 1;
      }
      const token = source.slice(index, end + 1);
      out += token;
      let lookahead = end + 1;
      while (lookahead < source.length && /\s/.test(source[lookahead])) lookahead += 1;
      if (source[lookahead] === ':') {
        try { lastKey = JSON.parse(token); } catch { lastKey = null; }
      } else {
        lastKey = null;
      }
      index = end + 1;
      continue;
    }

    if (ch === '-' || (ch >= '0' && ch <= '9')) {
      let end = index + 1;
      while (end < source.length && /[0-9eE+\-.]/.test(source[end])) end += 1;
      const token = source.slice(index, end);
      if (lastKey && BIG_ID_KEYS.has(lastKey) && /^\d{16,}$/.test(token)) {
        out += `"${token}"`;
      } else {
        out += token;
      }
      lastKey = null;
      index = end;
      continue;
    }

    if (ch === ':') { out += ch; index += 1; continue; }            // 保留 lastKey 给紧随其后的值
    if (ch === '{' || ch === '[' || ch === '}' || ch === ']' || ch === ',') {
      lastKey = null;
      out += ch;
      index += 1;
      continue;
    }

    if (!/\s/.test(ch)) lastKey = null;
    out += ch;
    index += 1;
  }
  return out;
}

export function parsePayload(body) {
  if (body && typeof body === 'object') return body;
  if (typeof body !== 'string') throw new Error('响应不是 JSON 文本');
  return JSON.parse(quoteUnsafeIntegerIds(body));
}

/** 业务状态：数字或数字字符串都认；未知状态单独报，不当成功。 */
export function businessError(payload) {
  if (!payload || typeof payload !== 'object') return null;
  const raw = payload.status_code ?? payload.statusCode;
  if (raw !== undefined && raw !== null) {
    const numeric = typeof raw === 'number' ? raw : Number(raw);
    if (!Number.isFinite(numeric)) return `status_code=${String(raw)}`;
    if (numeric !== 0) return `status_code=${numeric}`;
  }
  const code = payload.code;
  if (code !== undefined && code !== null) {
    const numeric = typeof code === 'number' ? code : Number(code);
    if (Number.isFinite(numeric) && numeric !== 0) return `code=${numeric}`;
  }
  if (payload.success === false || payload.success === 'false') return 'success=false';
  return null;
}

function hasPaging(object) {
  if (!object || typeof object !== 'object') return false;
  return ['cursor', 'next_cursor', 'nextCursor', 'has_more', 'hasMore', 'total'].some((key) => key in object);
}

function looksLikeComment(item) {
  if (!item || typeof item !== 'object') return false;
  const hasText = TEXT_KEYS.some((key) => textOf(item[key]).length > 0);
  const hasUser = USER_KEYS.some((key) => item[key] && typeof item[key] === 'object')
    || NAME_KEYS.some((key) => textOf(item[key]).length > 0)
    || USER_ID_KEYS.some((key) => textOf(item[key]).length > 0);
  return hasText && hasUser;
}

function walk(root, visit, { maxDepth = 8 } = {}) {
  const queue = [{ value: root, path: '$', depth: 0, parent: null, key: null }];
  while (queue.length) {
    const node = queue.shift();
    if (!node.value || typeof node.value !== 'object' || node.depth > maxDepth) continue;
    if (visit(node) === false) continue;
    const entries = Array.isArray(node.value)
      ? node.value.slice(0, 3).map((item, idx) => [`[${idx}]`, item])
      : Object.entries(node.value);
    for (const [key, child] of entries) {
      if (child && typeof child === 'object') {
        queue.push({
          value: child,
          path: Array.isArray(node.value) ? `${node.path}${key}` : `${node.path}.${key}`,
          depth: node.depth + 1,
          parent: node.value,
          key,
        });
      }
    }
  }
}

/** 仅在端点未知时使用的兜底：按路径提示 + 分页 + 层级打分。 */
export function findCommentArray(root) {
  let best = null;
  walk(root, (node) => {
    if (!Array.isArray(node.value)) return true;
    const sample = node.value.slice(0, 5);
    const matched = sample.filter(looksLikeComment).length;
    if (!matched) return true;
    const depth = node.path.split('.').length + (node.path.includes('[') ? 1 : 0);
    const score = (hasPaging(node.parent) ? 500 : 0)
      + (/comment/i.test(node.path) ? 200 : 0)
      + matched * 10
      + Math.min(node.value.length, 50)
      - depth * 5;
    if (!best || score > best.score) best = { array: node.value, path: node.path, parent: node.parent, score };
    return true;
  });
  return best ? { array: best.array, path: best.path, parent: best.parent, pathKind: 'heuristic' } : null;
}

function readPath(root, path) {
  let current = root;
  for (const key of path) {
    if (!current || typeof current !== 'object') return { found: false };
    current = current[key];
  }
  return { found: true, value: current };
}

/** 端点已知时按固定根取数组；返回 null 表示该路径不存在（可能改版）。 */
export function explicitCommentArray(payload, platform, endpoint) {
  const path = ROOT_PATHS[platform]?.[endpoint];
  if (!path) return null;
  const result = readPath(payload, path);
  if (!result.found || !Array.isArray(result.value)) return null;
  const parentPath = path.slice(0, -1);
  const parent = parentPath.length ? readPath(payload, parentPath).value : payload;
  return {
    array: result.value,
    path: `$.${path.join('.')}`,
    parent: parent || payload,
    pathKind: 'explicit',
  };
}

function findEmptyCommentArray(root) {
  let found = null;
  walk(root, (node) => {
    if (found) return false;
    if (!Array.isArray(node.value) || node.value.length !== 0) return true;
    if (typeof node.key === 'string' && /comment/i.test(node.key) && node.depth <= 3) {
      found = { path: node.path, parent: node.parent };
      return false;
    }
    return true;
  });
  return found;
}

function isoFromEpoch(value) {
  const number = typeof value === 'string' && /^\d+$/.test(value) ? Number(value) : value;
  if (typeof number !== 'number' || !Number.isFinite(number) || number <= 0) return '';
  const ms = number < 100_000_000_000 ? number * 1000 : number;
  const date = new Date(ms);
  return Number.isNaN(date.getTime()) ? '' : date.toISOString().replace('.000Z', 'Z');
}

export function profileUrlFor(platform, userId) {
  if (!userId) return '';
  if (platform === 'douyin') return `https://www.douyin.com/user/${userId}`;
  if (platform === 'xiaohongshu') return `https://www.xiaohongshu.com/user/profile/${userId}`;
  return '';
}

export function sourceUrlFor(platform, sourceId) {
  if (!sourceId) return '';
  if (platform === 'douyin') return `https://www.douyin.com/video/${sourceId}`;
  if (platform === 'xiaohongshu') return `https://www.xiaohongshu.com/explore/${sourceId}`;
  return '';
}

export function mapComment(item, platform, { parentCommentId = '' } = {}) {
  const user = pick(item, USER_KEYS) || {};
  const rawId = pick(item, ID_KEYS);
  const id = textOf(rawId);
  const unsafeId = typeof rawId === 'number' && rawId > Number.MAX_SAFE_INTEGER;
  const text = textOf(pick(item, TEXT_KEYS));
  if (!text) return null;

  const name = textOf(pick(user, NAME_KEYS)) || textOf(pick(item, NAME_KEYS));
  const userId = textOf(pick(user, USER_ID_KEYS)) || textOf(pick(item, USER_ID_KEYS));
  if (!name && !userId) return null;

  const handle = textOf(pick(user, HANDLE_KEYS)) || textOf(pick(item, HANDLE_KEYS));
  const likeCount = pick(item, LIKE_KEYS);
  const replyCount = pick(item, REPLY_COUNT_KEYS);

  return {
    platform,
    commentId: id,
    unsafeNumericId: unsafeId,
    parentCommentId,
    isReply: Boolean(parentCommentId),
    text,
    authorName: name || '未提供昵称',
    authorId: userId,
    profileUrl: profileUrlFor(platform, userId),
    publicHandle: handle,
    publishedAtISO: isoFromEpoch(pick(item, TIME_KEYS)),
    publishedAtRaw: '',
    ipLabel: textOf(pick(item, IP_KEYS)),
    likeCount: likeCount === undefined ? '' : String(likeCount),
    replyCount: replyCount === undefined ? '' : String(replyCount),
  };
}

/** 逐字段合并分页状态：父层只有 total 时，仍会去根层找 cursor / has_more。 */
function pagingFields(sources) {
  const cursor = sources.map((s) => [s, pick(s, ['cursor', 'next_cursor', 'nextCursor'])]).find(([, v]) => v !== undefined);
  const hasMoreRaw = sources.map((s) => [s, pick(s, ['has_more', 'hasMore'])]).find(([, v]) => v !== undefined);
  const total = sources.map((s) => [s, pick(s, ['total', 'comment_count'])]).find(([, v]) => v !== undefined);
  // 未知值保持 null，不能当成「已结束」
  const flag = hasMoreRaw === undefined ? undefined : hasMoreRaw[1];
  const hasMore = flag === undefined ? null
    : flag === true || flag === 1 || flag === '1' || flag === 'true' ? true
      : flag === false || flag === 0 || flag === '0' || flag === 'false' ? false
        : null;
  return {
    cursor: cursor && cursor[1] !== undefined ? String(cursor[1]) : '',
    hasMore,
    total: total && total[1] !== undefined ? Number(total[1]) : null,
    from: {
      cursor: cursor ? (cursor[0] === sources[0] ? 'list' : 'root') : 'unavailable',
      hasMore: hasMoreRaw ? (hasMoreRaw[0] === sources[0] ? 'list' : 'root') : 'unavailable',
    },
  };
}

function parseError(kind, message) {
  const error = new Error(message);
  error.kind = kind;
  return error;
}

function identifier(value) {
  if (typeof value === 'number' && !Number.isSafeInteger(value)) {
    throw parseError('unsafe_source_id', '来源标识已经丢失数值精度');
  }
  return textOf(value);
}

function captureContext(captureUrl, platform) {
  if (!captureUrl) return { sourceId: '', parentId: '' };
  let url;
  try { url = new URL(captureUrl); } catch { throw parseError('invalid_capture_url', '捕获地址无效'); }
  const hosts = platform === 'douyin' ? ['www.douyin.com', 'douyin.com']
    : platform === 'xiaohongshu' ? ['www.xiaohongshu.com', 'edith.xiaohongshu.com'] : [];
  if (url.protocol !== 'https:' || !hosts.includes(url.hostname) || url.username || url.password || url.port) {
    throw parseError('invalid_capture_url', '捕获地址与平台不匹配');
  }
  const keys = platform === 'xiaohongshu' ? ['note_id', 'item_id'] : ['aweme_id', 'item_id'];
  const uniqueParam = (names) => {
    const values = [...new Set(names.flatMap(key => url.searchParams.getAll(key)).filter(Boolean))];
    if (values.length > 1) throw parseError('source_conflict', '捕获地址中的标识冲突');
    return values[0] || '';
  };
  return { sourceId: uniqueParam(keys), parentId: uniqueParam(['comment_id', 'root_comment_id']) };
}

function sourceIdOf(payload, capture, platform) {
  const keys = platform === 'xiaohongshu' ? ['note_id', 'item_id'] : ['aweme_id', 'item_id'];
  const declared = [payload, payload?.data].flatMap(object => keys.map(key => identifier(object?.[key]))).filter(Boolean);
  const values = [...new Set([...declared, capture.sourceId].filter(Boolean))];
  if (values.length > 1) throw parseError('source_conflict', '评论响应与捕获地址的来源标识不一致');
  return values[0] || '';
}

export function parseComments(body, {
  platform = 'douyin',
  endpoint = '',
  includeReplies = false,
  captureUrl = '',
  parentCommentId = '',
} = {}) {
  const payload = parsePayload(body);
  const failed = businessError(payload);
  if (failed) {
    const error = new Error(`接口返回业务错误：${failed}`);
    error.kind = 'business_error';
    throw error;
  }

  const capture = captureContext(captureUrl, platform);
  const sourceId = sourceIdOf(payload, capture, platform);
  let found;
  if (endpoint) {
    if (!ROOT_PATHS[platform]?.[endpoint]) throw parseError('unsupported_endpoint', '端点不属于此平台的评论接口');
    found = explicitCommentArray(payload, platform, endpoint);
    if (!found) throw parseError('structure_changed', '已知评论端点的根数组缺失或类型变化');
  } else {
    found = findCommentArray(payload);
  }

  if (!found) {
    const empty = findEmptyCommentArray(payload);
    if (empty || payload?.total === 0) {
      return {
        platform,
        path: empty ? empty.path : '$',
        comments: [],
        empty: true,
        paging: pagingFields([empty ? empty.parent : payload, payload]),
        sourceId,
        rawCount: 0,
        pathKind: 'empty',
      };
    }
    const error = new Error('响应里没有找到评论数组');
    error.kind = 'structure_changed';
    throw error;
  }

  // 独立回复端点：父 ID 来自请求参数，不靠猜
  const isReplyEndpoint = ['comment_reply', 'comment_sub'].includes(endpoint);
  const explicitParent = identifier(parentCommentId);
  if (isReplyEndpoint && explicitParent && capture.parentId && explicitParent !== capture.parentId) {
    throw parseError('parent_conflict', '回复父标识与捕获地址不一致');
  }
  const rootParent = isReplyEndpoint ? (capture.parentId || explicitParent) : '';
  if (isReplyEndpoint && !rootParent) throw parseError('unbound_reply', '独立回复缺少父评论标识');

  const comments = [];
  const seen = new Set();
  let mergedWithoutId = 0;
  let unsafeIds = 0;

  const add = (item, parentId = '') => {
    const mapped = mapComment(item, platform, { parentCommentId: parentId });
    if (!mapped) return;
    const rowSource = sourceIdOf(item, { sourceId, parentId: '' }, platform);
    if (sourceId && rowSource && rowSource !== sourceId) throw parseError('source_conflict', '评论条目的来源标识冲突');
    mapped.sourceId = rowSource;
    if (mapped.unsafeNumericId) unsafeIds += 1;
    const key = mapped.commentId && !mapped.unsafeNumericId
      ? `id:${mapped.commentId}`
      : `fallback:${mapped.authorId}|${mapped.text}|${mapped.publishedAtISO}`;
    if (!mapped.commentId || mapped.unsafeNumericId) mergedWithoutId += 1;
    if (seen.has(key)) return;
    seen.add(key);
    comments.push(mapped);
  };

  for (const item of found.array) {
    add(item, rootParent);
    if (includeReplies) {
      const replies = pick(item, REPLIES_KEYS);
      if (Array.isArray(replies)) {
        const parentId = textOf(pick(item, ID_KEYS));
        replies.forEach((reply) => add(reply, parentId));
      }
    }
  }

  return {
    platform,
    path: found.path,
    pathKind: found.pathKind,
    comments,
    empty: found.array.length === 0,
    paging: pagingFields([found.parent, payload]),
    sourceId,
    rawCount: found.array.length,
    mergedWithoutId,
    unsafeIds,
  };
}

// Strict, canonical UTC evidence timestamps. Native SourcePublicationGate rebuilds at seconds.
function evidenceDate(value) {
  if (typeof value !== 'string') return null;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match) return null;
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number);
  const probe = new Date(0); probe.setUTCFullYear(year, month - 1, day); probe.setUTCHours(hour, minute, second, 0);
  if (year < 1 || probe.getUTCFullYear() !== year || probe.getUTCMonth() !== month - 1 || probe.getUTCDate() !== day
    || probe.getUTCHours() !== hour || probe.getUTCMinutes() !== minute || probe.getUTCSeconds() !== second) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? { ms, iso: new Date(Math.floor(ms / 1000) * 1000).toISOString().replace('.000Z', 'Z') } : null;
}

function sourceDates(publishedAtISO, checkedAt, now) {
  const publication = evidenceDate(publishedAtISO), checked = evidenceDate(checkedAt);
  const nowMs = now instanceof Date ? now.getTime() : typeof now === 'number' ? now : Date.parse(now);
  if (!publication || !checked || !Number.isFinite(nowMs) || publication.ms > checked.ms || checked.ms > nowMs) return null;
  return { publishedAtISO: publication.iso, checkedAt: checked.iso };
}

/** Only endpoint-owned detail objects are evidence; never recursively inspect comment descendants. */
export function parseSource(body, { platform = 'douyin', capturedAt = '', captureUrl = '', now = Date.now() } = {}) {
  const payload = parsePayload(body);
  if (businessError(payload)) return null;
  const capture = captureContext(captureUrl, platform);
  const checkedAt = capturedAt || new Date(now).toISOString();
  const candidates = [];
  if (platform === 'douyin') {
    for (const object of [payload?.aweme_detail, payload?.data?.aweme_detail]) {
      if (object && typeof object === 'object' && !Array.isArray(object)) candidates.push({ object, wrapperId: '' });
    }
  } else if (platform === 'xiaohongshu' && Array.isArray(payload?.data?.items)) {
    for (const item of payload.data.items) {
      const object = item?.note_card;
      if (object && typeof object === 'object' && !Array.isArray(object)) candidates.push({ object, wrapperId: identifier(item.id || item.note_id) });
    }
  }
  const results = [];
  const keys = platform === 'xiaohongshu' ? ['note_id', 'item_id', 'id'] : ['aweme_id', 'item_id'];
  for (const { object, wrapperId } of candidates) {
    const ids = [...new Set([...keys.map(key => identifier(object[key])), wrapperId].filter(Boolean))];
    if (ids.length > 1) throw parseError('source_conflict', '详情对象中的来源标识冲突');
    const sourceId = ids[0];
    if (!sourceId) continue;
    if (capture.sourceId && sourceId !== capture.sourceId) throw parseError('source_conflict', '详情响应与捕获地址的来源标识不一致');
    const dates = sourceDates(isoFromEpoch(pick(object, TIME_KEYS)), checkedAt, now);
    if (!dates) continue;
    results.push({ platform, sourceId, publishedAtISO: dates.publishedAtISO,
      title: textOf(pick(object, ['desc', 'title', 'display_title'])), quality: 'exact', checkedAt: dates.checkedAt });
  }
  // Multiple distinct publications or sources need explicit selection, not whichever appeared first.
  const identities = new Set(results.map(item => `${item.sourceId}|${item.publishedAtISO}`));
  if (identities.size !== 1) return null;
  return results[0];
}

/**
 * 转成采集器 / lead-api 的原始行。
 * 只有来源（platform + sourceId）核验通过，才附带 iOS 原生要求的六个日期证据字段；
 * 不一致或未知时明确标状态，不把别的来源日期挂到这条评论上。
 */
export function toRows(comments, { source = null, sourceUrl = '', sourceTitle = '', product = '', now = Date.now() } = {}) {
  return comments.map((comment) => {
    const derived = sourceUrlFor(comment.platform, comment.sourceId);
    let status = 'unknown';
    if (source && source.platform !== comment.platform) status = 'platform_mismatch';
    else if (source && source.sourceId && comment.sourceId && source.sourceId !== comment.sourceId) status = 'mismatch';
    else if (!comment.sourceId) status = 'unbound';
    else if (source && source.sourceId && comment.sourceId === source.sourceId && source.publishedAtISO) status = 'candidate';
    else if (comment.sourceId) status = 'bound';

    const dates = status === 'candidate' ? sourceDates(source.publishedAtISO, source.checkedAt, now) : null;
    if (status === 'candidate') status = dates && (!source.quality || source.quality === 'exact') ? 'verified' : 'invalid_date';
    const verified = status === 'verified';
    const finalUrl = derived || (status === 'unbound' ? sourceUrl : '');

    const evidence = verified
      ? {
        sourcePublishedAt: '',
        sourcePublishedAtISO: dates.publishedAtISO,
        sourcePublishedTimeQuality: 'exact',
        sourceCheckedAt: dates.checkedAt,
        sourceEarliestAtISO: dates.publishedAtISO,
        sourcePolicy: NATIVE_SOURCE_POLICY,
      }
      : {};

    return {
      platform: comment.platform,
      product,
      text: comment.text,
      authorName: comment.authorName,
      authorId: comment.authorId,
      profileUrl: comment.profileUrl || '',
      publicHandle: comment.publicHandle || '',
      commentId: comment.commentId,
      parentCommentId: comment.parentCommentId || '',
      isReply: Boolean(comment.isReply),
      publishedAtRaw: '',
      publishedAtISO: comment.publishedAtISO || '',
      ipLabel: comment.ipLabel || '',
      likeCount: comment.likeCount || '',
      replyCount: comment.replyCount || '',
      replyToAuthor: '',
      sourceId: comment.sourceId || '',
      sourceUrl: finalUrl,
      sourceTitle,
      sourceStatus: status,
      sourceConflict: status === 'mismatch' || status === 'platform_mismatch'
        || Boolean(derived && sourceUrl && derived !== sourceUrl),
      ...evidence,
      acquisition: 'protocol_capture',
    };
  });
}
