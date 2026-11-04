import Foundation
import CryptoKit
import Combine
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
#endif

struct ProfileSnapshotEntry: Codable, Equatable {
    let profileIdentity: String
    let status: String
    let capturedAt: String?
    let checkedAt: String
    let filename: String?
    let failureReason: String?
}

private struct ProfileSnapshotIndex: Codable {
    let schema: Int
    let entries: [String: ProfileSnapshotEntry]
}

enum ProfileSnapshotFailure: LocalizedError {
    case message(String)
    case timeout
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .timeout: return "主页截图等待超时（8秒），未保存不确定画面。"
        }
    }
}

/// A local, bounded cache of verified public-profile HEADER images, never whole account pages.
/// No nicknames, cookies, credentials, OCR enrichment, or remote upload are used as identity.
@MainActor
final class ProfileSnapshotStore: ObservableObject {
    static let shared = ProfileSnapshotStore()
    @Published private(set) var revision: UInt64 = 0
    private(set) var loadError: String?
    private var entries: [String: ProfileSnapshotEntry] = [:]
    private let directory: URL
    private let indexURL: URL
    private static let maxImageBytes = 3 * 1024 * 1024
    private static let maxCacheBytes = 60 * 1024 * 1024
    private static let maxImageCount = 200
    private static let maxEntryCount = 2000

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShengxunLocal/ProfileSnapshots", isDirectory: true)
        self.directory = root
        indexURL = root.appendingPathComponent("index.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var folder = root, values = URLResourceValues()
            values.isExcludedFromBackup = true; try folder.setResourceValues(values)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
            #endif
            if FileManager.default.fileExists(atPath: indexURL.path) {
                guard (try indexURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4 * 1024 * 1024 else {
                    throw ProfileSnapshotFailure.message("截图索引过大，未覆盖原文件。")
                }
                let index = try JSONDecoder().decode(ProfileSnapshotIndex.self, from: Data(contentsOf: indexURL))
                guard index.schema == 1, index.entries.count <= Self.maxEntryCount,
                      index.entries.allSatisfy({ Self.valid($0.value, key: $0.key) }) else {
                    throw ProfileSnapshotFailure.message("截图索引无效，未覆盖原文件。")
                }
                entries = index.entries
            }
        } catch { loadError = "本机截图读取失败，旧文件保留。" }
    }

    func entry(for profileURL: String) -> ProfileSnapshotEntry? {
        guard let identity = CollectionPlatform.profileIdentity(profileURL) else { return nil }
        return entries[identity]
    }

    func imageURL(for profileURL: String) -> URL? {
        guard let entry = entry(for: profileURL), let filename = entry.filename,
              Self.valid(entry, key: entry.profileIdentity) else { return nil }
        let file = directory.appendingPathComponent(filename)
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= Self.maxImageBytes else { return nil }
        return file
    }

    /// Failure metadata never removes a previously successful screenshot.
    func recordFailure(profileURL: String, reason: String) throws {
        guard let identity = CollectionPlatform.profileIdentity(profileURL) else {
            throw ProfileSnapshotFailure.message("公开主页地址无效，未写入截图记录。")
        }
        let previous = entries[identity]
        let sanitized = reason.components(separatedBy: .controlCharacters).joined(separator: " ")
            .replacingOccurrences(of: "https?://[^\\s]+", with: "[地址已省略]", options: .regularExpression)
            .replacingOccurrences(of: "(?i)(cookie|token|authorization)\\s*[:=]\\s*[^\\s]+", with: "[敏感字段已省略]", options: .regularExpression)
        let cleanReason = String(sanitized.prefix(300))
        let entry = ProfileSnapshotEntry(profileIdentity: identity, status: "failed", capturedAt: previous?.capturedAt,
            checkedAt: Self.timestamp(Date()), filename: previous?.filename,
            failureReason: cleanReason.isEmpty ? "主页截图暂不可用。" : cleanReason)
        var next = entries; next[identity] = entry
        try commit(next)
    }

    /// Only call after public-page validation. Foundation-only to allow isolated persistence tests.
    func persistValidatedCapture(_ png: Data, profileURL: String, capturedAt: Date = Date()) throws {
        guard loadError == nil else { throw ProfileSnapshotFailure.message(loadError!) }
        guard let identity = CollectionPlatform.profileIdentity(profileURL),
              png.count > 8, png.count <= Self.maxImageBytes,
              png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw ProfileSnapshotFailure.message("截图格式、大小或公开主页地址无效。")
        }
        let previous = entries[identity]
        let otherImages = entries.values.filter { $0.profileIdentity != identity && $0.filename != nil }
        let currentBytes = otherImages.reduce(0) { count, item in
            count + (imageURL(for: item.profileIdentity).flatMap {
                try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
            } ?? 0)
        }
        guard otherImages.count < Self.maxImageCount, currentBytes + png.count <= Self.maxCacheBytes else {
            throw ProfileSnapshotFailure.message("本机截图缓存已达上限；请清理不需要的客户记录后重试。")
        }
        let filename = Self.prefix(for: identity) + "-" + UUID().uuidString.lowercased() + ".png"
        let file = directory.appendingPathComponent(filename)
        try Self.write(png, to: file)
        let stamp = Self.timestamp(capturedAt)
        var next = entries
        next[identity] = ProfileSnapshotEntry(profileIdentity: identity, status: "ready", capturedAt: stamp,
                                              checkedAt: stamp, filename: filename, failureReason: nil)
        do { try commit(next) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
        // Only a successfully committed replacement can retire its previous image.
        if let oldFilename = previous?.filename, oldFilename != filename {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(oldFilename))
        }
    }

    /// Explicit cleanup after comment deletion only; normal capture/load never evicts old images.
    func prune(keeping profileURLs: Set<String>) throws {
        let keep = Set(profileURLs.compactMap(CollectionPlatform.profileIdentity))
        let removed = entries.values.filter { !keep.contains($0.profileIdentity) }
        guard !removed.isEmpty else { return }
        try commit(entries.filter { keep.contains($0.key) })
        for entry in removed {
            if let filename = entry.filename {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
            }
        }
    }

    private func commit(_ next: [String: ProfileSnapshotEntry]) throws {
        guard loadError == nil else { throw ProfileSnapshotFailure.message(loadError!) }
        guard next.count <= Self.maxEntryCount, next.allSatisfy({ Self.valid($0.value, key: $0.key) }) else {
            throw ProfileSnapshotFailure.message("截图索引无效或已达上限，原记录保留。")
        }
        let data = try JSONEncoder().encode(ProfileSnapshotIndex(schema: 1, entries: next))
        try Self.write(data, to: indexURL)
        entries = next; revision &+= 1
    }
    private static func write(_ data: Data, to file: URL) throws {
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }
    private static func prefix(for identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func valid(_ entry: ProfileSnapshotEntry, key: String) -> Bool {
        guard entry.profileIdentity == key, CollectionPlatform.profileIdentity(key) == key,
              ["ready", "failed"].contains(entry.status), ISO8601DateFormatter().date(from: entry.checkedAt) != nil,
              entry.failureReason == nil || entry.failureReason!.count <= 300 else { return false }
        if let filename = entry.filename {
            guard filename.range(of: "^" + prefix(for: key) + "-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.png$", options: .regularExpression) != nil,
                  entry.capturedAt.flatMap({ ISO8601DateFormatter().date(from: $0) }) != nil else { return false }
        } else if entry.capturedAt != nil { return false }
        return entry.status == "ready" ? entry.filename != nil && entry.failureReason == nil : entry.failureReason?.isEmpty == false
    }
}

#if canImport(UIKit) && canImport(WebKit)
@MainActor
private final class SnapshotOperation<Value> {
    var continuation: CheckedContinuation<Value, Error>?
    var timer: Task<Void, Never>?
    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timer?.cancel(); timer = nil
        continuation.resume(with: result)
    }
}

extension ProfileSnapshotStore {
    /// One shared eight-second deadline covers DOM readiness, the image and post-capture checks.
    func capture(in webView: WKWebView, profileURL: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        guard let identity = CollectionPlatform.profileIdentity(profileURL) else {
            throw ProfileSnapshotFailure.message("不是可核验的公开主页，未截图。")
        }
        var lastReason = "没有找到可确认的公开主页信息区。"
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            try checkPage(webView, identity: identity)
            let proof = try await inspect(webView, deadline: deadline)
            guard proof["state"] as? String == "ready" else {
                lastReason = proof["reason"] as? String ?? lastReason
                if proof["state"] as? String == "blocked" { throw ProfileSnapshotFailure.message(lastReason) }
                try await Task.sleep(nanoseconds: UInt64(min(0.25, max(0, deadline - ProcessInfo.processInfo.systemUptime)) * 1_000_000_000)); continue
            }
            let rect = try snapshotRect(proof, in: webView, identity: identity)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = rect // Never nil/default/full-page bounds.
            configuration.snapshotWidth = NSNumber(value: Double(min(rect.width, 480)))
            configuration.afterScreenUpdates = true
            let image: UIImage = try await timed(deadline: deadline) { finish in
                webView.takeSnapshot(with: configuration) { image, error in
                    if let error { finish(.failure(error)) }
                    else if let image { finish(.success(image)) }
                    else { finish(.failure(ProfileSnapshotFailure.message("系统未返回主页截图。"))) }
                }
            }
            try Task.checkCancellation()
            try checkPage(webView, identity: identity)
            let after = try await inspect(webView, deadline: deadline)
            guard after["state"] as? String == "ready" else {
                throw ProfileSnapshotFailure.message(after["reason"] as? String ?? "截图后主页状态改变，未保存。")
            }
            let afterRect = try snapshotRect(after, in: webView, identity: identity)
            guard proof["fingerprint"] as? String == after["fingerprint"] as? String,
                  proof["selector"] as? String == after["selector"] as? String,
                  abs(afterRect.minX - rect.minX) < 2, abs(afterRect.minY - rect.minY) < 2,
                  abs(afterRect.width - rect.width) < 2, abs(afterRect.height - rect.height) < 2 else {
                throw ProfileSnapshotFailure.message("主页画面在截图期间变化，未保存不确定截图。")
            }
            let width = min(image.size.width * image.scale, 1000)
            guard width > 0, image.size.width > 0, image.size.height > 0 else {
                throw ProfileSnapshotFailure.message("截图尺寸无效。")
            }
            let size = CGSize(width: width, height: width * image.size.height / image.size.width)
            guard size.height <= 2400 else { throw ProfileSnapshotFailure.message("主页信息区过大，未截图整个页面。") }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let bounded = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let png = bounded.pngData() else { throw ProfileSnapshotFailure.message("截图编码失败。") }
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProfileSnapshotFailure.timeout }
            try checkPage(webView, identity: identity)
            try persistValidatedCapture(png, profileURL: identity)
            return
        }
        throw ProfileSnapshotFailure.message(lastReason + "（等待已达8秒，未截图）")
    }

    private func checkPage(_ webView: WKWebView, identity: String) throws {
        var ancestor: UIView? = webView
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01 else {
                throw ProfileSnapshotFailure.message("公开主页不在可见界面中，未截图。")
            }
            ancestor = view.superview
        }
        guard UIApplication.shared.applicationState == .active, webView.window != nil,
              !webView.isHidden, webView.alpha > 0.01, webView.bounds.width >= 150, webView.bounds.height >= 100,
              CollectionPlatform.profileIdentity(webView.url?.absoluteString ?? "") == identity else {
            throw ProfileSnapshotFailure.message("当前可见网页不是该公开主页，或 App 已离开前台，未截图。")
        }
    }
    private func inspect(_ webView: WKWebView, deadline: TimeInterval) async throws -> [String: Any] {
        let result: Any? = try await timed(deadline: deadline) { finish in
            webView.evaluateJavaScript(Self.headerProbe) { result, error in
                if let error { finish(.failure(error)) } else { finish(.success(result)) }
            }
        }
        guard let result = result as? [String: Any] else { throw ProfileSnapshotFailure.message("主页结构检查未返回有效结果。") }
        return result
    }
    private func snapshotRect(_ proof: [String: Any], in webView: WKWebView, identity: String) throws -> CGRect {
        func number(_ key: String) -> CGFloat? {
            guard let value = proof[key] as? Double, value.isFinite else { return nil }
            return CGFloat(value)
        }
        guard proof["state"] as? String == "ready", proof["fingerprint"] is String,
              CollectionPlatform.profileIdentity(proof["href"] as? String ?? "") == identity,
              let x = number("x"), let y = number("y"), let w = number("width"), let h = number("height"),
              let vw = number("viewportWidth"), let vh = number("viewportHeight"), vw > 0, vh > 0,
              x >= 0, y >= 0, w >= 120, h >= 60, x + w <= vw + 1, y + h <= vh + 1 else {
            throw ProfileSnapshotFailure.message("公开主页区域未通过可见性或身份检查，未截图。")
        }
        let sx = webView.bounds.width / vw, sy = webView.bounds.height / vh
        guard abs(sx - sy) <= max(sx, sy) * 0.1 else {
            throw ProfileSnapshotFailure.message("网页缩放区域无法安全对应，未截图。")
        }
        let rect = CGRect(x: x * sx, y: y * sy, width: w * sx, height: h * sy).intersection(webView.bounds)
        guard !rect.isEmpty, !rect.isNull, rect.width >= 50, rect.height >= 30 else {
            throw ProfileSnapshotFailure.message("主页截图区域不可见。")
        }
        return rect
    }
    private func timed<Value>(deadline: TimeInterval,
        start: (@escaping @MainActor (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        let waiter = SnapshotOperation<Value>()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiter.continuation = continuation
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { waiter.finish(.failure(ProfileSnapshotFailure.timeout)); return }
                waiter.timer = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                    catch { return }
                    waiter.finish(.failure(ProfileSnapshotFailure.timeout))
                }
                start { waiter.finish($0) }
            }
        }, onCancel: { Task { @MainActor in waiter.finish(.failure(CancellationError())) } })
    }

    // XHS header/name structure was observed on a public merchant profile; iPhone capture still needs acceptance.
    // DY candidates remain fail-closed until live verification; no full-page fallback is used.
    // This script reads visible public header layout only; it never logs in, clicks or scrolls.
    static let headerProbe = #"""
(() => {
  const waiting = reason => ({state:'waiting', reason});
  const blocked = reason => ({state:'blocked', reason});
  const visible = el => {
    if (!el || !el.isConnected) return false;
    const r = el.getBoundingClientRect();
    for (let p = el; p && p.nodeType === 1; p = p.parentElement) {
      const s = getComputedStyle(p);
      if (p.hidden || s.display === 'none' || s.visibility === 'hidden' || Number(s.opacity || 1) <= 0.01) return false;
    }
    return r.width > 0 && r.height > 0;
  };
  if (document.readyState === 'loading') return waiting('公开主页仍在加载。');
  const url = new URL(location.href);
  const dy = /^(www\.)?douyin\.com$/.test(url.hostname) && /^\/user\/[A-Za-z0-9_.-]{4,200}\/?$/.test(url.pathname);
  const xhs = /^(www\.)?xiaohongshu\.com$/.test(url.hostname) && /^\/user\/profile\/[0-9a-fA-F]{24}\/?$/.test(url.pathname);
  if (url.protocol !== 'https:' || url.username || url.password || (url.port && url.port !== '443') || (!dy && !xhs)) return blocked('不是公开用户主页，未截图。');
  const gates = '[role="dialog"],[aria-modal="true"],[class*="login-modal"],[class*="login-panel"],[class*="captcha"],[id*="captcha"],input[type="password"],input[autocomplete="one-time-code"]';
  if ([...document.querySelectorAll(gates)].some(visible)) return blocked('存在登录、验证或弹窗遮挡，未截图。');
  // Read account/page status markers, never infer account privacy from collection-tab text.
  // A public XHS header can coexist with "该用户已设置收藏内容不可见" below it.
  const accountPrivate = /私密[账帐]号|隐私[账帐]号|(?:该用户|该[账帐]号|此[账帐]号).{0,12}(?:设置.{0,5}隐私|设为私密)|(?:用户|个人|[账帐]号)主页.{0,12}(?:不可见|仅(?:自己|好友|关注者|粉丝)可见)/;
  const pageBlocked = /无权访问|[账帐]号已注销|用户已注销|用户不存在|页面不存在|暂时无法访问|[账帐]号已封禁|登录后(?:即可)?查看|扫码登录|安全验证/;
  const statuses = '[role="alert"],[role="status"],[data-e2e="error-page"],[data-e2e="user-error"],.error-page,.page-error,.error-message,.empty-text,.private-account,.account-private,.user-private';
  for (const status of document.querySelectorAll(statuses)) {
    if (!visible(status)) continue;
    const text = (status.innerText || status.textContent || '').trim().slice(0, 1200);
    if (accountPrivate.test(text) || pageBlocked.test(text)) return blocked('账号主页为私密、错误或访问受限状态，未截图。');
  }
  const specs = dy ? [
    ['[data-e2e="user-info"]','[data-e2e="user-info-name"],[data-e2e="user-info-nickname"]']
  ] : [
    // Verified public merchant header chain; prefer the info rectangle, not the outer page.
    ['.user-profile .user-info .info-part > .info','.user-nickname > .user-name'],
    ['.user-profile .user','.user-nickname > .user-name']
  ];
  let matches = [];
  for (const [selector, nameSelector] of specs) {
    const group = [];
    for (const header of document.querySelectorAll(selector)) {
      const name = header.querySelector(nameSelector);
      if (!visible(header) || !visible(name) || !(name.innerText || name.textContent || '').trim()) continue;
      // Even the fallback must contain only profile information, never posts/private tabs.
      if (header.querySelector('[data-e2e="comment-list"],.feeds-container,.note-list,.empty-text,[role="tabpanel"],a[href*="/video/"]')) continue;
      if (!group.some(item => item.header === header)) group.push({header, selector});
    }
    // More-specific and fallback nested headers are alternatives, never simultaneous candidates.
    if (group.length) { matches = group; break; }
  }
  if (matches.length !== 1) return waiting('未能唯一确认公开主页信息区；不会改截整个网页。');
  const {header, selector} = matches[0], r = header.getBoundingClientRect();
  const accountScope = xhs ? (header.closest('.user-info') || header) : header;
  const headerText = (accountScope.innerText || accountScope.textContent || '').trim().slice(0, 16000);
  if (accountPrivate.test(headerText) || pageBlocked.test(headerText)) return blocked('账号主页信息区显示私密或访问限制，未截图。');
  const privacyFlags = '[aria-label*="私密"],[title*="私密"],[data-e2e="user-private"],[data-e2e="private-account"],.private-account,.account-private,.user-private';
  if ([...accountScope.querySelectorAll(privacyFlags)].some(visible)) return blocked('账号主页信息区标记为私密状态，未截图。');
  const vv = window.visualViewport;
  const vw = vv?.width || window.innerWidth, vh = vv?.height || window.innerHeight;
  const ox = vv?.offsetLeft || 0, oy = vv?.offsetTop || 0;
  if (r.width < 120 || r.height < 60 || r.height > 900 || r.left < ox - 1 || r.top < oy - 1 || r.right > ox + vw + 1 || r.bottom > oy + vh + 1) return waiting('公开主页信息区未完整显示，未截图。');
  for (const px of [0.15, 0.5, 0.85]) for (const py of [0.15, 0.5, 0.85]) {
    const top = document.elementFromPoint(r.left + r.width * px, r.top + r.height * py);
    if (!top || !header.contains(top)) return blocked('主页信息区被其他内容遮挡，未截图。');
  }
  const text = (header.innerText || header.textContent || '').trim().slice(0, 20000);
  let hash = 2166136261;
  for (let i = 0; i < text.length; i++) { hash ^= text.charCodeAt(i); hash = Math.imul(hash, 16777619); }
  return {state:'ready', href:location.href, selector, fingerprint:(hash >>> 0).toString(16),
          x:r.left-ox, y:r.top-oy, width:r.width, height:r.height, viewportWidth:vw, viewportHeight:vh};
})()
"""#
}
#endif
