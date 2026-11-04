import Foundation
import WebKit
import Combine

@MainActor
private final class ScriptEvaluation {
    var continuation: CheckedContinuation<Any?, Error>?
    var timeout: Task<Void, Never>?
    func finish(_ result: Result<Any?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        continuation.resume(with: result)
    }
}

private enum BrowserScriptFailure: LocalizedError {
    case timeout
    var errorDescription: String? { "网页脚本限时无响应，任务暂停，已保存的断点保留。" }
}

struct CollectionCompletion: Identifiable {
    let id = UUID()
    let added: Int
    let checked: Int
    let sources: Int
    let outcomes: [String]
    let commentIDs: [String]
}

/// Reads the visible page's own JSON responses first; DOM handles search/open/scroll and explicit fallback.
/// No cookie export, signed request replay, external server, or JavaScript message handler.
@MainActor
final class BrowserCollector: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published private(set) var status = "无需软件账号；平台登录和验证码需本人完成。"
    @Published private(set) var running = false
    @Published private(set) var stage = "等待开始"
    @Published private(set) var progress: Double = 0
    @Published private(set) var runSummary = "来源7/30/90天 · 最多5条视频 / 每条检查200条后选50条"
    @Published private(set) var canResume = false
    @Published var completion: CollectionCompletion?
    @Published private(set) var navigationDiagnostics: [String] = []
    var navigationDiagnosticText: String { navigationDiagnostics.joined(separator: "\n") }
    var diagnosticReport: String {
        "后门 0.2.0 (10)\n阶段：\(stage)\n\(runSummary)\n" +
        "结构检查：" + structureSummary + "\n读取路径：" + protocolSummary + "\n来源检查：" + sourceDiagnosticSummary + "\n" + navigationDiagnosticText +
        "\n仅含任务计数与导航类别；未包含评论、昵称、Cookie或完整URL。"
    }

    private let store: CommentStore
    private let script: String
    private let protocolScript: String
    private var protocolDocumentID: String
    private var protocolTaskID: String
    private var protocolSourceIdentity: String?
    private var protocolPreparedURL: String?
    private var protocolSummary = "未读取"
    private let checkpoint = CollectionJobStore()
    private var job: CollectionJob?
    private var task: Task<Void, Never>?
    @Published private(set) var pageLoadFailed = false
    private var activeNavigation: WKNavigation?
    private var navigationLoad: NavigationLoadState?
    private var navigationOperation = UUID()
    private var awaitingNavigation: UUID?
    private var navigationMonitor: Task<Void, Never>?
    private var navigationTokens: [ObjectIdentifier: UUID] = [:]
    private var retainedNavigations: [WKNavigation] = []
    private var trackingNavigation = false
    private var lastMainRequestURL: URL?
    private var pendingMainNavigationURL: URL?
    private var policyFailureMessage: String?
    private var secureUpgradeBudget = HTTPSUpgradeBudget()
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var activeEvaluation: ScriptEvaluation?
    private var keyword = ""
    private var sourceWindowDays = 7
    private var preparingSnapshots = false
    private var snapshotNavigationFailure: String?
    private var selectedRecency: CommentRecency = .all
    private var selectedIndustry: IndustryProfile = .general
    private var selectedPlatform: CollectionPlatform = .douyin
    private var structureSummary = "未读取"
    private var generation = UUID()
    private var bufferedCount = 0
    private var sourceSkipCounts: [String: Int] = [:]
    private var sourceDiagnosticSummary: String {
        sourceSkipCounts.keys.sorted().map { "\($0)=\(sourceSkipCounts[$0] ?? 0)" }.joined(separator: " ")
    }
    private struct SourceCandidate {
        let url: String
        let title: String
        let raw: String
        let iso: String?
        let observedAt: Date
    }
    private struct BufferedComment {
        let key: String
        let row: [String: Any]
        let time: PublicationTime?
    }
    private struct CommentScan {
        let comments: [BufferedComment]
        let outcome: String
        let sourceUnavailable: Bool
    }


    init(store: CommentStore) {
        self.store = store
        let configuration = WKWebViewConfiguration()
        let initialDocumentID = UUID().uuidString, initialTaskID = UUID().uuidString
        protocolDocumentID = initialDocumentID; protocolTaskID = initialTaskID
        let capture = Bundle.main.url(forResource: "protocol-capture", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        protocolScript = capture
        // Install in the page world BEFORE WKWebView is created: isolated-world hooks
        // cannot observe the page's fetch/XHR, and didFinish injection misses detail JSON.
        configuration.userContentController.addUserScript(Self.protocolUserScript(capture,
            documentID: initialDocumentID, taskID: initialTaskID, platform: .douyin, source: nil))
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        script = ["collector-ios", "collector-xhs"].compactMap { resource in
            Bundle.main.url(forResource: resource, withExtension: "js")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }.joined(separator: "\n")
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        do {
            job = try checkpoint.load()
            canResume = job.map { !$0.finished } ?? false
            refreshSummary()
        } catch { status = error.localizedDescription }
    }

    private func allowed(_ url: URL?) -> Bool {
        guard NavigationPolicy.isSupportedMainURL(url), let host = url?.host?.lowercased() else { return false }
        switch selectedPlatform {
        case .douyin: return host == "douyin.com" || host.hasSuffix(".douyin.com")
        case .xiaohongshu: return ["xiaohongshu.com", "www.xiaohongshu.com"].contains(host)
        case .channels: return false
        }
    }

    func prepare(keyword: String, platform: CollectionPlatform = .douyin) {
        stop()
        guard platform.canCollect else { status = "\(platform.title)尚未接通可验证的采集路径，未启动任务。"; return }
        self.keyword = keyword; selectedPlatform = platform
        reopenPlatform()
    }

    /// Opens a fresh HTTPS entry without deleting cookies, comments, or the saved task.
    func reopenPlatform() {
        stop()
        guard selectedPlatform.canCollect else { return }
        stage = "打开平台网页"; status = "正在安全加载；平台登录需本人完成。"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.navigate(self.selectedPlatform.homeURL)
                self.stage = "平台网页已打开"
                self.status = "如需登录请在网页完成，然后继续原断点任务。"
            } catch is CancellationError { }
              catch {
                self.pageLoadFailed = true; self.stage = "网页未打开"
                self.status = error.localizedDescription
            }
        }
    }

    func stop(_ message: String? = nil) {
        let discardedBuffer = bufferedCount > 0
        bufferedCount = 0
        task?.cancel()
        suspendProtocolCapture()
        navigationMonitor?.cancel(); navigationMonitor = nil
        trackingNavigation = false; activeNavigation = nil; navigationLoad = nil
        pendingMainNavigationURL = nil
        navigationOperation = UUID(); awaitingNavigation = nil
        webView.stopLoading()
        activeEvaluation?.finish(.failure(CancellationError())); activeEvaluation = nil
        task = nil
        generation = UUID()
        running = false
        canResume = job.map { !$0.finished } ?? false
        if let message { status = message + (discardedBuffer ? " 当前视频尚未入库缓存已丢弃，继续将重扫。" : ""); stage = "已暂停" }
    }

    private func persist(_ next: CollectionJob) throws {
        try checkpoint.save(next)
        job = next
        canResume = !next.finished
        refreshSummary()
    }
    private func refreshSummary() {
        guard let job else { return }
        let count = job.videos.count
        progress = job.finished ? 1 : (count == 0 ? 0 : min(1, (Double(job.nextIndex) + Double(job.acceptedThisVideo) / 50) / Double(count)))
        runSummary = "\(job.platform.title) · 来源7/30/90天 · 评论\(job.range.title) · 检查 \(job.seen.count) 条 · 新增 \(job.added) 条 · 过期跳过 \(job.skippedOld ?? 0) · 时间未知跳过 \(job.skippedUnknown ?? 0)"
    }

    private func appendNavigationDiagnostic(_ line: String) {
        navigationDiagnostics.append(line)
        if navigationDiagnostics.count > 40 { navigationDiagnostics.removeFirst(navigationDiagnostics.count - 40) }
    }

    private func registerNavigation(_ navigation: WKNavigation?) {
        guard let navigation else {
            navigationLoad?.rejectPolicy(reason: "load_not_created", at: uptime)
            return
        }
        let key = ObjectIdentifier(navigation)
        let token = navigationTokens[key] ?? UUID()
        if navigationTokens[key] == nil {
            navigationTokens[key] = token
            retainedNavigations.append(navigation)
        }
        if navigationLoad?.begin(token: token, at: uptime) == true { activeNavigation = navigation }
    }

    @discardableResult
    private func beginNavigation(_ url: URL, timeout: TimeInterval) -> UUID {
        navigationMonitor?.cancel()
        navigationOperation = UUID(); trackingNavigation = true
        navigationLoad = NavigationLoadState(requestedURL: url, startedAt: uptime, timeout: timeout)
        secureUpgradeBudget.reset(); policyFailureMessage = nil; snapshotNavigationFailure = nil
        pageLoadFailed = false; lastMainRequestURL = url
        pendingMainNavigationURL = nil
        prepareProtocolDocument(for: url)
        registerNavigation(webView.load(URLRequest(url: url)))
        monitorNavigation()
        return navigationOperation
    }

    private func monitorNavigation() {
        navigationMonitor?.cancel()
        let operation = navigationOperation
        navigationMonitor = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.navigationOperation == operation {
                self.navigationLoad?.expire(at: self.uptime)
                if let retry = self.navigationLoad?.takeRetry(at: self.uptime) {
                    self.appendNavigationDiagnostic("load=retry reason=correlated_policy_cancel attempt=1")
                    self.status = "页面跳转中断，正在恢复一次 HTTPS 页面…"
                    self.registerNavigation(self.webView.load(URLRequest(url: retry)))
                }
                switch self.navigationLoad?.outcome {
                case .succeeded?: self.pageLoadFailed = false; return
                case .failed(let failure)?:
                    self.appendNavigationDiagnostic(failure.diagnosticLine)
                    self.pageLoadFailed = true
                    let message = self.policyFailureMessage ?? failure.userMessage
                    if self.awaitingNavigation != operation {
                        if self.preparingSnapshots { self.snapshotNavigationFailure = message }
                        else { self.stop(message) }
                    }
                    return
                case nil: return
                case .pending?: break
                }
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            }
        }
    }

    /// A completed document can start another real navigation. Never try to register a
    /// replacement into an irreversible success/failure state.
    private func prepareSuccessorIfCompleted(_ target: URL) {
        guard let previous = navigationLoad, previous.outcome == .succeeded else { return }
        navigationMonitor?.cancel()
        if awaitingNavigation == navigationOperation {
            // didFinish and a successor can arrive between two awaiter polls. Keep the
            // original target and deadline rather than abandoning a still-running job.
            navigationLoad = NavigationLoadState(requestedURL: previous.requestedURL,
                startedAt: uptime, timeout: max(0, previous.deadline - uptime))
        } else {
            navigationOperation = UUID()
            navigationLoad = NavigationLoadState(requestedURL: target, startedAt: uptime, timeout: 45)
            secureUpgradeBudget.reset()
        }
        policyFailureMessage = nil; pageLoadFailed = false
        monitorNavigation()
    }


    private static func jsonLiteral(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func protocolUserScript(_ capture: String, documentID: String, taskID: String,
                                          platform: CollectionPlatform, source: String?) -> WKUserScript {
        let initialTask: [String: String]? = source.map { ["platform": platform.rawValue, "sourceUrl": $0, "taskId": taskID] }
        let taskJSON = initialTask.map { jsonLiteral($0) } ?? "null"
        let sourceCode = "window.__houmenNativeDocumentID=" + jsonLiteral(documentID) + ";" +
            "window.__houmenNativeTaskID=" + jsonLiteral(taskID) + ";" +
            "window.__houmenProtocolInitialTask=" + taskJSON + ";\n" + capture +
            (source == nil ? "\nwindow.__houmenProtocol && window.__houmenProtocol.stop();" : "")
        return WKUserScript(source: sourceCode, injectionTime: .atDocumentStart,
                            forMainFrameOnly: true, in: .page)
    }

    private func replaceProtocolUserScript() {
        // This WebView has its own content controller and exactly this owned user script.
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(Self.protocolUserScript(protocolScript, documentID: protocolDocumentID,
            taskID: protocolTaskID, platform: selectedPlatform, source: protocolSourceIdentity))
    }

    private func suspendProtocolCapture() {
        let document = Self.jsonLiteral(protocolDocumentID), oldTask = Self.jsonLiteral(protocolTaskID)
        // A queued cancellation from an old document/task must never stop its successor.
        webView.evaluateJavaScript("if(window.__houmenNativeDocumentID===\(document)&&window.__houmenNativeTaskID===\(oldTask)){window.__houmenProtocol&&window.__houmenProtocol.stop();}", completionHandler: nil)
        protocolTaskID = UUID().uuidString; protocolSourceIdentity = nil
        replaceProtocolUserScript()
    }

    private func prepareProtocolDocument(for url: URL) {
        suspendProtocolCapture()
        protocolPreparedURL = url.absoluteString
        protocolDocumentID = UUID().uuidString; protocolTaskID = UUID().uuidString
        if running && !preparingSnapshots && CollectionPlatform.sourcePlatform(url.absoluteString) == selectedPlatform {
            protocolSourceIdentity = CollectionPlatform.sourceIdentity(url.absoluteString)
        }
        // beginTask configuration executes at documentStart, before the first detail request.
        // evaluate() repeats the SAME task id idempotently; it does not clear first-load data.
        replaceProtocolUserScript()
    }

    private func visibleSourceIdentity() -> String? {
        guard let url = webView.url else { return nil }
        if let identity = CollectionPlatform.sourceIdentity(url.absoluteString) { return identity }
        guard selectedPlatform == .douyin, allowed(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let ids = components.queryItems?.filter { $0.name == "modal_id" } ?? []
        guard ids.count == 1, let id = ids[0].value else { return nil }
        return CollectionPlatform.sourceIdentity("https://www.douyin.com/video/" + id)
    }

    /// Same-document manual collection can bind a fresh epoch. Automatic collection is
    /// already bound at documentStart; repeating that binding preserves captured details.
    private func protocolConfiguration(for source: String, command: String) -> [String: Any]? {
        guard ["source", "open", "read"].contains(command), !protocolScript.isEmpty,
              CollectionPlatform.sourcePlatform(source) == selectedPlatform,
              let identity = CollectionPlatform.sourceIdentity(source),
              visibleSourceIdentity() == identity else { return nil }
        if protocolSourceIdentity != identity {
            suspendProtocolCapture()
            protocolSourceIdentity = identity
            replaceProtocolUserScript()
        }
        return ["platform": selectedPlatform.rawValue, "sourceUrl": identity,
                "taskId": protocolTaskID, "documentId": protocolDocumentID]
    }

    // Executed as ordinary page-world JavaScript, with only normalized projected data
    // returned to Swift. DOM fallback is explicit, never reported as protocol capture.
    private static let protocolDispatch = #"""
    (function(config, dom) {
      const task = config.protocolTask;
      const fallback = () => {
        const result = dom();
        return {...result, acquisitionPath: task ? 'dom_fallback' : 'dom_navigation'};
      };
      if (!task) return fallback();
      const blocked = code => ({state:'blocked',code,acquisitionPath:'protocol',
        message:'协议任务或来源已改变，已暂停；未保存错误来源。'});
      if (window.__houmenNativeDocumentID !== task.documentId) return blocked('protocol_document_changed');
      const hook = window.__houmenProtocol;
      if (!hook || typeof hook.beginTask !== 'function' || typeof hook.read !== 'function') return fallback();
      try {
        window.__houmenNativeTaskID = task.taskId;
        const bound = hook.beginTask(task);
        if (bound && bound.state === 'blocked') return blocked('protocol_bind_rejected');
        const result = hook.read({...task, keyword:config.keyword});
        if (!result || typeof result !== 'object') return fallback();
        if (result.state === 'blocked') return blocked('protocol_source_rejected');
        if (result.state === 'skipped') return {...result, acquisitionPath:'protocol',
          message:'平台未提供可核验的当前来源，已跳过；不视为零评论。'};
        const identity = {taskId:result.taskId,sourceId:result.sourceId,sourceUrl:result.sourceUrl,
          acquisitionPath:'protocol',diagnostics:result.diagnostics};
        if (config.command === 'source' && result.sourceReady === true) return {
          ...identity,state:'ready',sourcePublishedAt:result.sourcePublishedAt || '',
          sourcePublishedAtISO:result.sourcePublishedAtISO,
          message:'已读取平台详情响应，仍由本机核验原发布时间。'};
        if (['open','read'].includes(config.command) && result.commentsReady === true && Array.isArray(result.comments)) return {
          ...identity,state:'ready',comments:result.comments,explicitZero:result.explicitEmpty === true,
          endOfComments:result.endOfComments === true,
          message:'已读取页面已加载的公开评论响应；非全量。'};
      } catch (_) { /* A hook fault is not permission to issue or replay requests. */ }
      return fallback();
    })
    """#

    private func checkedProtocolResult(_ result: [String: Any], source: String, taskID: String) throws -> [String: Any] {
        guard result["acquisitionPath"] as? String == "protocol", result["state"] as? String != "blocked" else { return result }
        guard result["taskId"] as? String == taskID,
              let identity = CollectionPlatform.sourceIdentity(source),
              CollectionPlatform.sourceIdentity(result["sourceUrl"] as? String ?? "") == identity,
              visibleSourceIdentity() == identity else {
            throw LocalFailure.message("协议响应不属于当前页面任务，未保存数据")
        }
        var checked = result
        if let rows = result["comments"] as? [[String: Any]] {
            var safe: [[String: Any]] = [], dropped = 0
            let fields = ["commentId", "authorName", "authorId", "publicHandle", "profileUrl", "text",
                          "publishedAt", "publishedAtISO", "publishedTimeQuality", "parentCommentId", "isReply", "ipLabel", "likeCount", "replyCount"]
            for row in rows.prefix(200) {
                guard CollectionPlatform.sourceIdentity(row["sourceUrl"] as? String ?? "") == identity else {
                    throw LocalFailure.message("评论响应包含其他来源，未保存当前批次")
                }
                guard CollectionPlatform.profilePlatform(row["profileUrl"] as? String ?? "") == selectedPlatform,
                      let author = row["authorName"] as? String, !author.isEmpty,
                      let text = row["text"] as? String, !text.isEmpty else { dropped += 1; continue }
                var item = row.filter { fields.contains($0.key) }
                item["sourceUrl"] = source; item["platform"] = selectedPlatform.rawValue
                item["sourceTitle"] = ""; item["industry"] = selectedIndustry.rawValue; item["product"] = keyword
                item["acquisition"] = "local_protocol_response"
                safe.append(item)
            }
            checked["comments"] = safe
            // Filtering unsupported rows never manufactures a zero-comment result.
            if !rows.isEmpty { checked["explicitZero"] = false }
            protocolSummary = "协议响应 rows=\(safe.count) skipped=\(dropped)"
        } else { protocolSummary = "协议响应：来源日期待本机核验" }
        return checked
    }

    private func navigate(_ url: URL, timeout: TimeInterval = 45) async throws {
        try Task.checkCancellation()
        guard allowed(url) else { throw LocalFailure.message("仅支持当前平台HTTPS页面") }
        let operation = beginNavigation(url, timeout: timeout)
        awaitingNavigation = operation
        defer { if awaitingNavigation == operation { awaitingNavigation = nil } }
        while navigationOperation == operation {
            try Task.checkCancellation()
            navigationLoad?.expire(at: uptime)
            switch navigationLoad?.outcome {
            case .succeeded?: return
            case .failed(let failure)?:
                pageLoadFailed = true
                throw LocalFailure.message(policyFailureMessage ?? failure.userMessage)
            case nil: throw CancellationError()
            case .pending?: break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try Task.checkCancellation()
        throw LocalFailure.message("目标页面被新的导航替换，已暂停并保留断点。")
    }

    private func waitForVisibleNavigation(timeout: TimeInterval) async throws {
        let deadline = uptime + max(0, min(12, timeout))
        var observedOperation: UUID?
        defer { if awaitingNavigation == observedOperation { awaitingNavigation = nil } }
        while let load = navigationLoad {
            try Task.checkCancellation()
            switch load.outcome {
            case .succeeded: return
            case .failed(let failure): throw LocalFailure.message(policyFailureMessage ?? failure.userMessage)
            case .pending:
                observedOperation = navigationOperation; awaitingNavigation = navigationOperation
                navigationLoad?.expire(at: uptime)
                guard uptime < deadline else {
                    throw LocalFailure.message("网页仍在跳转，已暂停并保留断点；未读取旧页面。")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func evaluate(_ command: String, source: String = "", title: String = "", scriptTimeout: TimeInterval = 12) async throws -> [String: Any] {
        try Task.checkCancellation()
        let startedAt = uptime
        try await waitForVisibleNavigation(timeout: scriptTimeout)
        let remainingScriptTimeout = max(0.001, scriptTimeout - (uptime - startedAt))
        guard !script.isEmpty else { throw LocalFailure.message("缺少采集脚本，请重新构建App") }
        guard allowed(webView.url) else { throw LocalFailure.message("当前不在所选平台HTTPS页面") }
        let currentGeneration = generation, currentNavigation = navigationOperation
        var config: [String: Any] = ["command": command, "keyword": keyword, "sourceUrl": source,
                                    "sourceTitle": title, "sourceWindowDays": sourceWindowDays, "platform": selectedPlatform.rawValue, "industry": selectedIndustry.rawValue, "maxVideos": 40, "maxComments": 200]
        if let protocolTask = protocolConfiguration(for: source, command: command) { config["protocolTask"] = protocolTask }
        let documentID = protocolDocumentID, taskID = protocolTaskID
        let data = try JSONSerialization.data(withJSONObject: config)
        let function = selectedPlatform == .xiaohongshu ? "collectXiaohongshuPage" : "collectAudioPage"
        let literal = String(decoding: data, as: UTF8.self)
        let expression = script + "\nJSON.stringify(" + Self.protocolDispatch + "(" + literal +
            ",function(){return " + function + "(" + literal + ");}));"
        let evaluation = ScriptEvaluation()
        activeEvaluation = evaluation
        defer { if activeEvaluation === evaluation { activeEvaluation = nil } }
        let value: Any? = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                evaluation.continuation = continuation
                if Task.isCancelled { evaluation.finish(.failure(CancellationError())); return }
                evaluation.timeout = Task {
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.001, min(12, remainingScriptTimeout)) * 1_000_000_000)) }
                    catch { return }
                    evaluation.finish(.failure(BrowserScriptFailure.timeout))
                }
                webView.evaluateJavaScript(expression) { result, error in
                    if let error { evaluation.finish(.failure(error)) }
                    else { evaluation.finish(.success(result)) }
                }
            }
        } onCancel: {
            Task { @MainActor in evaluation.finish(.failure(CancellationError())) }
        }
        try Task.checkCancellation()
        guard generation == currentGeneration else { throw CancellationError() }
        guard navigationOperation == currentNavigation, protocolDocumentID == documentID, protocolTaskID == taskID else {
            throw LocalFailure.message("页面或读取任务已切换，已暂停；当前视频未保存缓存丢弃。")
        }
        guard let string = value as? String, let bytes = string.data(using: .utf8),
              let decoded = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw LocalFailure.message("页面返回结构不正确，未保存数据")
        }
        let result = try checkedProtocolResult(decoded, source: source, taskID: taskID)
        if result["acquisitionPath"] as? String == "dom_fallback" { protocolSummary = "DOM 回退：本次未读取协议数据" }
        if let d = result["diagnostics"] as? [String: Any] {
            structureSummary = ["loaded", "parsed", "skipped", "folded"].map { key in
                "\(key)=\((d[key] as? Int) ?? 0)"
            }.joined(separator: " ")
        }
        if result["state"] as? String == "blocked" {
            throw LocalFailure.message(result["message"] as? String ?? "平台限制访问，已暂停")
        }
        return result
    }

    private func waitFor(_ command: String, source: String = "", title: String = "", timeout: TimeInterval = 60) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let result: [String: Any]
            do {
                result = try await evaluate(command, source: source, title: title,
                                            scriptTimeout: max(0.05, min(12, deadline.timeIntervalSinceNow)))
            } catch BrowserScriptFailure.timeout {
                if command == "source" { break }
                throw BrowserScriptFailure.timeout
            }
            if ["ready", "skipped"].contains(result["state"] as? String ?? "") { return result }
            status = result["message"] as? String ?? "等待网页内容…"
            try await Task.sleep(nanoseconds: UInt64(max(0, min(1.5, deadline.timeIntervalSinceNow)) * 1_000_000_000))
        }
        if command == "source" {
            return ["state": "skipped", "code": "source_time_unknown", "message": "12秒内未确认原发布时间，跳过此来源"]
        }
        throw LocalFailure.message("限时内未读到可识别内容；可能需要平台登录或网页已改版。未完成任务，可分享诊断。")
    }

    private func waitForComments(_ command: String, target: VideoTarget, until deadline: TimeInterval) async throws -> [String: Any]? {
        try await CommentPolling.wait(until: deadline, evaluate: { remaining in
            // Do not start a new 60-second timer between opening and the first read.
            do {
                return try await self.evaluate(command, source: target.url, title: target.title,
                                               scriptTimeout: max(0.01, remaining))
            } catch BrowserScriptFailure.timeout {
                // Only the exhausted comment budget is a skip; an earlier script fault still pauses.
                if ProcessInfo.processInfo.systemUptime >= deadline { return ["state": "waiting"] }
                throw BrowserScriptFailure.timeout
            }
        }, waiting: { message, remaining in
            self.status = message + " · 最多再等\(Int(ceil(remaining)))秒"
        })
    }

    private func sourceSkipped(_ code: String) {
        let allowed = ["source_old", "source_time_unknown", "source_unavailable", "source_limit", "source_changed"]
        let category = allowed.contains(code) ? code : "source_time_unknown"
        sourceSkipCounts[category, default: 0] += 1
    }
    private static func evidence(from result: [String: Any], observedAt: Date = Date()) -> SourcePublicationEvidence? {
        SourcePublicationGate.evidence(raw: result["sourcePublishedAt"] as? String ?? "",
                                       iso: result["sourcePublishedAtISO"] as? String, observedAt: observedAt)
    }
    private func sourceProof(for target: VideoTarget) async throws -> SourcePublicationEvidence? {
        let result = try await waitFor("source", source: target.url, title: target.title, timeout: 12)
        if result["state"] as? String == "skipped" {
            sourceSkipped(result["code"] as? String ?? "source_time_unknown"); return nil
        }
        guard let proof = Self.evidence(from: result) else { sourceSkipped("source_time_unknown"); return nil }
        guard SourcePublicationGate.eligible(proof, now: Date()) else { sourceSkipped("source_old"); return nil }
        return proof
    }
    private static func olderProof(_ first: SourcePublicationEvidence, _ second: SourcePublicationEvidence) -> SourcePublicationEvidence {
        // Both are factory-validated canonical UTC stamps; retain an earlier original date on a re-read.
        first.publishedAtISO <= second.publishedAtISO ? first : second
    }
    private static func rankedSources(_ targets: [VideoTarget], now: Date) -> [VideoTarget] {
        Array(CollectionJob.prioritizedTargets(targets, now: now).prefix(5))
    }
    private func discoverSources() async throws -> [VideoTarget] {
        guard let search = selectedPlatform.searchURL(keyword: keyword) else { throw LocalFailure.message("此平台未接通关键词采集") }
        var verified: [VideoTarget] = [], inspected = Set<String>()
        // Expand only when the bounded newer-source sample contains fewer than five valid sources.
        for window in [7, 30, 90] {
            try Task.checkCancellation()
            if verified.count >= 5 { break }
            sourceWindowDays = window
            stage = "1/3 来源核验 · 近\(window)天"
            status = "最新发布优先；不足5个合格来源才扩大日期范围。"
            try await navigate(search)
            let prepared = try await waitFor("prepare_search")
            guard prepared["state"] as? String == "ready" else { throw LocalFailure.message("未确认最新发布筛选，未读取热门结果") }
            var result = try await waitFor("search")
            var candidates: [SourceCandidate] = [], identities = Set<String>(), stagnant = 0
            for round in 0..<5 {
                try Task.checkCancellation()
                guard result["latestOrderConfirmed"] as? Bool == true else {
                    throw LocalFailure.message("搜索页最新发布条件未确认，已暂停，不退回热门结果")
                }
                let before = candidates.count, observedAt = Date()
                let videos = try CollectionJob.searchVideos(from: result, sourceWindowDays: window)
                for item in videos {
                    guard candidates.count < 40, let url = item["url"] as? String,
                          CollectionPlatform.sourcePlatform(url) == selectedPlatform,
                          let identity = CollectionPlatform.sourceIdentity(url), !inspected.contains(identity),
                          identities.insert(identity).inserted else { continue }
                    candidates.append(SourceCandidate(url: url, title: String((item["title"] as? String ?? "").prefix(300)),
                        raw: item["sourcePublishedAt"] as? String ?? "", iso: item["sourcePublishedAtISO"] as? String, observedAt: observedAt))
                }
                stagnant = candidates.count == before ? stagnant + 1 : 0
                if result["explicitEmpty"] as? Bool == true || candidates.count >= 40 || round == 4 || stagnant >= 2 { break }
                let advanced = try await waitFor("search_advance", timeout: 12)
                if advanced["state"] as? String == "skipped" { break }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                result = try await waitFor("search", timeout: 12)
            }
            var unknownProbes = 0
            for (index, candidate) in candidates.enumerated() {
                try Task.checkCancellation()
                let card = SourcePublicationGate.evidence(raw: candidate.raw, iso: candidate.iso, observedAt: candidate.observedAt)
                if let card, !SourcePublicationGate.eligible(card, now: Date(), windowDays: window) { continue }
                if card == nil {
                    if unknownProbes >= 10 { sourceSkipped("source_limit"); continue }
                    unknownProbes += 1
                }
                guard let url = URL(string: candidate.url), let identity = CollectionPlatform.sourceIdentity(candidate.url) else { continue }
                status = "近\(window)天 · 核验来源 \(index + 1)/\(candidates.count)"
                try await navigate(url)
                let target = VideoTarget(url: candidate.url, title: candidate.title)
                if let detail = try await sourceProof(for: target) {
                    if SourcePublicationGate.eligible(detail, now: Date(), windowDays: window) {
                        inspected.insert(identity)
                        verified.append(VideoTarget(url: target.url, title: target.title, publication: detail))
                    }
                } else { inspected.insert(identity) }
                if index + 1 < candidates.count { try await Task.sleep(nanoseconds: 1_000_000_000) }
            }
            verified = Self.rankedSources(verified, now: Date())
        }
        return Self.rankedSources(verified, now: Date())
    }

    func start(keyword: String, recency: CommentRecency = .all, industry: IndustryProfile = .general, platform: CollectionPlatform = .douyin) {
        guard !running else { return }
        stop()
        self.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.keyword.count <= 60 else { status = "关键词最多60字，请缩短后再试"; return }
        guard platform.canCollect else { status = "\(platform.title)尚未接通可验证采集，未建立假任务。"; return }
        selectedRecency = recency; selectedIndustry = industry; selectedPlatform = platform
        guard !self.keyword.isEmpty else { status = "请输入产品、服务、品牌或需求词"; return }
        sourceSkipCounts = [:]; completion = nil
        do {
            var next = CollectionJob(keyword: self.keyword)
            next.schema = 4; next.sourcePolicy = SourcePublicationGate.policy; next.searchExhausted = false
            next.recencyRaw = recency.rawValue; next.industryRaw = industry.rawValue; next.platformRaw = platform.rawValue
            next.currentAccepted = 0; next.skippedOld = 0; next.skippedUnknown = 0
            try persist(next); launch()
        } catch { status = "无法建立本机任务：" + error.localizedDescription }
    }

    func resume() {
        guard !running else { return }
        stop()
        do {
            guard let saved = try checkpoint.load(), !saved.finished else {
                status = "没有未完成任务；没有近期来源时请更换关键词重新查找"; canResume = false; return
            }
            if saved.requiresFreshSourceSearch || !saved.currentVideoKeys.isEmpty || saved.acceptedThisVideo > 0 {
                start(keyword: saved.keyword, recency: saved.range, industry: saved.industry, platform: saved.platform)
                status = "旧任务使用旧日期策略，已按7/30/90天优先级重搜；已存评论保留。"
                return
            }
            job = saved; keyword = saved.keyword; selectedRecency = saved.range; selectedIndustry = saved.industry; selectedPlatform = saved.platform
            refreshSummary(); launch()
        } catch { status = "无法恢复：" + error.localizedDescription }
    }

    private static func commentTime(_ row: [String: Any], observedAt: Date) -> PublicationTime? {
        let raw = row["publishedAt"] as? String ?? ""
        guard !raw.contains("编辑"), !raw.contains("更新") else { return nil }
        let iso = row["publishedAtISO"] as? String
        if let iso, !iso.isEmpty {
            guard let value = CommentRecency.isoDate(iso), value <= observedAt else { return nil }
            if row["acquisition"] as? String == "local_protocol_response",
               row["publishedTimeQuality"] as? String == "exact" {
                return PublicationTime(date: value, quality: "exact")
            }
        }
        return CommentRecency.resolved(raw: raw, iso: iso, observedAt: observedAt)
    }
    private func scanComments(for target: VideoTarget) async throws -> CommentScan {
        let initialDeadline = CommentPolling.deadline()
        guard let opened = try await waitForComments("open", target: target, until: initialDeadline) else {
            return CommentScan(comments: [], outcome: "评论区12秒内未就绪，跳过；不代表零评论", sourceUnavailable: false)
        }
        if opened["state"] as? String == "skipped" {
            sourceSkipped(opened["code"] as? String ?? "source_unavailable")
            return CommentScan(comments: [], outcome: "来源不可用，未读取评论", sourceUnavailable: true)
        }
        guard var result = try await waitForComments("read", target: target, until: initialDeadline) else {
            return CommentScan(comments: [], outcome: "评论12秒内未加载，跳过；不代表零评论", sourceUnavailable: false)
        }
        var buffer: [BufferedComment] = [], seen = Set(job?.seen ?? []), stagnant = 0
        var outcome = "达到24轮检查上限；非全量"
        for round in 0..<24 {
            try Task.checkCancellation()
            if result["state"] as? String == "skipped" {
                sourceSkipped(result["code"] as? String ?? "source_unavailable")
                return CommentScan(comments: [], outcome: "来源不可用，本视频未保存缓存已丢弃", sourceUnavailable: true)
            }
            guard let rows = result["comments"] as? [[String: Any]] else { throw LocalFailure.message("评论结构无效，当前视频尚未保存") }
            let before = buffer.count, observedAt = Date()
            for row in rows {
                guard CollectionPlatform.sourceIdentity(row["sourceUrl"] as? String ?? "") == CollectionPlatform.sourceIdentity(target.url) else {
                    throw LocalFailure.message("评论来源与当前核验视频不一致，未保存当前视频")
                }
                guard buffer.count < 200 else { break }
                let key = CollectionJob.rowKey(row)
                if seen.insert(key).inserted { buffer.append(BufferedComment(key: key, row: row, time: Self.commentTime(row, observedAt: observedAt))) }
            }
            stagnant = buffer.count == before ? stagnant + 1 : 0
            bufferedCount = buffer.count
            status = "暂存检查 \(buffer.count)/200 条；完成本视频后按评论时间选较新50条"
            if result["explicitZero"] as? Bool == true {
                outcome = buffer.isEmpty ? "平台稳定显示零评论" : "后续列表变空，保留此前已读样本；非全量"
                break
            }
            if result["endOfComments"] as? Bool == true {
                outcome = buffer.isEmpty ? "本次响应已到末页，无可保存评论；不等于平台零评论" : "已到本次已加载响应末页；非全量"
                break
            }
            if buffer.count >= 200 { outcome = "已检查200条公开评论；非全量"; break }
            if stagnant >= 3 { outcome = "连续3轮无新增公开评论；非全量"; break }
            if round == 23 { break }
            let advanced = try await evaluate("advance", source: target.url)
            if advanced["state"] as? String == "skipped" {
                sourceSkipped(advanced["code"] as? String ?? "source_unavailable")
                return CommentScan(comments: [], outcome: "来源不可用，本视频未保存缓存已丢弃", sourceUnavailable: true)
            }
            try await Task.sleep(nanoseconds: 2_500_000_000)
            guard let nextRead = try await waitForComments("read", target: target, until: CommentPolling.deadline()) else {
                outcome = buffer.isEmpty ? "评论12秒内未加载，跳过；不代表零评论" : "后续评论等待12秒超时，保留此前样本；非全量"
                break
            }
            result = nextRead
        }
        return CommentScan(comments: buffer, outcome: outcome, sourceUnavailable: false)
    }
    private static func selectedComments(_ comments: [BufferedComment], range: CommentRecency, now: Date) -> [BufferedComment] {
        comments.filter { item in
            guard let time = item.time, time.date <= now else { return false }
            return CommentRecency.accepts(time, range: range, now: now)
        }.sorted { lhs, rhs in
            let left = lhs.time!.date, right = rhs.time!.date
            return left == right ? lhs.key < rhs.key : left > right
        }.prefix(50).map { $0 }
    }
    private func finishTarget(_ target: VideoTarget, scan: CommentScan, proof: SourcePublicationEvidence?) throws {
        try Task.checkCancellation()
        guard var next = job, next.nextIndex < next.videos.count,
              CollectionPlatform.sourceIdentity(next.videos[next.nextIndex].url) == CollectionPlatform.sourceIdentity(target.url) else {
            throw LocalFailure.message("任务来源已改变，未保存缓存")
        }
        let now = Date()
        let selected = scan.sourceUnavailable ? [] : Self.selectedComments(scan.comments, range: next.range, now: now)
        var batch: [[String: Any]] = []
        if !scan.sourceUnavailable {
            guard let proof, SourcePublicationGate.eligible(proof, now: now) else { throw LocalFailure.message("来源已不符合90天，未保存当前视频") }
            batch = selected.map { item in
                var row = item.row
                // Native verification always replaces page-supplied source evidence fields.
                row["sourceUrl"] = target.url; row["sourceTitle"] = target.title
                row["platform"] = selectedPlatform.rawValue; row["industry"] = selectedIndustry.rawValue; row["product"] = keyword
                row.merge(proof.rowFields) { _, verified in verified }
                row["publishedAtISO"] = ISO8601DateFormatter().string(from: item.time!.date)
                row["publishedTimeQuality"] = item.time!.quality
                return row
            }
        }
        let keys = scan.sourceUnavailable ? [] : scan.comments.map(\.key)
        next.seen.append(contentsOf: keys)
        next.skippedUnknown = (next.skippedUnknown ?? 0) + scan.comments.filter { $0.time == nil }.count
        next.skippedOld = (next.skippedOld ?? 0) + scan.comments.filter {
            guard let time = $0.time else { return false }
            return !CommentRecency.accepts(time, range: next.range, now: now)
        }.count
        let previousAdded = next.added
        next.added += batch.count
        next.outcomes.append(String((scan.outcome + "；选取有日期评论\(batch.count)条").prefix(300)))
        next.nextIndex += 1; next.currentVideoKeys = []; next.currentAccepted = 0
        try next.validate() // No invalid checkpoint can cause a batch to be saved first.
        let added: Int
        if batch.isEmpty { added = 0 } else { added = try store.save(batch, requireRecentSource: true, now: now) }
        next.added = previousAdded + added
        do { try persist(next); bufferedCount = 0 }
        catch { throw LocalFailure.message("评论批次已保存，但任务断点写入失败；继续会去重重扫当前视频。" + error.localizedDescription) }
    }

    private func collectedCommentsForJob() -> [AudioComment] {
        guard let job else { return [] }
        let keys = Set(job.seen)
        let ordered = store.comments.filter { comment in
            let row: [String: Any] = ["sourceUrl": comment.sourceUrl, "profileUrl": comment.profileUrl,
                                     "commentId": comment.commentId, "text": comment.text]
            guard let date = CommentRecency.publicationDate(comment), date <= Date(),
                  CommentRecency.accepts(PublicationTime(date: date, quality: "stored"), range: job.range, now: Date()) else { return false }
            return keys.contains(CollectionJob.rowKey(row)) && SourcePublicationGate.eligible(SourcePublicationGate.publication(comment), now: Date())
        }.sorted {
            (CommentRecency.publicationDate($0) ?? .distantPast) > (CommentRecency.publicationDate($1) ?? .distantPast)
        }
        var perSource: [String: Int] = [:]
        return ordered.filter { comment in
            guard let source = CollectionPlatform.sourceIdentity(comment.sourceUrl) else { return false }
            let count = perSource[source, default: 0]
            guard count < 50 else { return false }
            perSource[source] = count + 1
            return true
        }
    }
    private func presentCompletion() {
        guard let job, job.finished else { return }
        completion = CollectionCompletion(added: job.added, checked: job.seen.count, sources: job.nextIndex,
                                          outcomes: job.outcomes, commentIDs: collectedCommentsForJob().map(\.id))
    }
    private func prepareProfileSnapshots() async {
        preparingSnapshots = true
        defer { preparingSnapshots = false; snapshotNavigationFailure = nil }
        let cache = ProfileSnapshotStore.shared
        var identities = Set<String>()
        let profiles = collectedCommentsForJob().filter { comment in
            comment.assessment.hasClue && CollectionPlatform.profilePlatform(comment.profileUrl) == selectedPlatform &&
                CollectionPlatform.profileIdentity(comment.profileUrl).map { identities.insert($0).inserted } == true
        }
        for (index, comment) in profiles.prefix(10).enumerated() {
            if Task.isCancelled { return }
            guard let url = URL(string: comment.profileUrl) else { continue }
            stage = "3/3 准备主页截图 · \(index + 1)/\(min(10, profiles.count))"
            status = "仅保存对应公开主页的资料区域，不读取私信或其他 App。"
            do {
                try await navigate(url, timeout: 8)
                try await cache.capture(in: webView, profileURL: comment.profileUrl)
            } catch is CancellationError { return }
              catch {
                try? cache.recordFailure(profileURL: comment.profileUrl, reason: error.localizedDescription)
            }
        }
        for comment in profiles.dropFirst(10) {
            try? cache.recordFailure(profileURL: comment.profileUrl, reason: "本轮最多准备10个公开主页截图，尚未截图")
        }
    }

    private func launch() {
        completion = nil
        running = true
        let currentGeneration = UUID(); generation = currentGeneration
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == currentGeneration { self.suspendProtocolCapture() } }
            do {
                try Task.checkCancellation()
                guard self.generation == currentGeneration else { return }
                if self.job?.videos.isEmpty == true {
                    let targets = try await self.discoverSources()
                    guard var next = self.job else { throw LocalFailure.message("任务状态丢失") }
                    next.videos = targets; next.sourceOrderConfirmedAt = ISO8601DateFormatter().string(from: Date())
                    next.searchExhausted = targets.isEmpty
                    try self.persist(next)
                    if targets.isEmpty {
                        self.running = false; self.canResume = false; self.progress = 1
                        self.stage = "本轮没有符合条件的近期来源"
                        self.status = "本轮有限候选中未核验到原发布时间90天内的视频。不是零评论结果；可更换关键词重新查找。"
                        self.presentCompletion()
                        return
                    }
                }
                while let current = self.job, current.nextIndex < current.videos.count {
                    try Task.checkCancellation()
                    let target = current.videos[current.nextIndex]
                    self.stage = "2/3 评论检查 · 来源 \(current.nextIndex + 1)/\(current.videos.count)"
                    guard let url = URL(string: target.url) else { throw LocalFailure.message("来源地址无效") }
                    try await self.navigate(url)
                    guard let fresh = try await self.sourceProof(for: target), let original = target.publication else {
                        try self.finishTarget(target, scan: CommentScan(comments: [], outcome: "来源原发布时间未知或过期，跳过", sourceUnavailable: true), proof: nil)
                        continue
                    }
                    let proof = Self.olderProof(original, fresh)
                    guard SourcePublicationGate.eligible(proof, now: Date()) else {
                        self.sourceSkipped("source_old")
                        try self.finishTarget(target, scan: CommentScan(comments: [], outcome: "来源已超出90天，跳过", sourceUnavailable: true), proof: nil)
                        continue
                    }
                    let scan = try await self.scanComments(for: target)
                    if scan.sourceUnavailable {
                        try self.finishTarget(target, scan: scan, proof: nil)
                    } else if let finalRead = try await self.sourceProof(for: target) {
                        let finalProof = Self.olderProof(proof, finalRead)
                        if SourcePublicationGate.eligible(finalProof, now: Date()) {
                            try self.finishTarget(target, scan: scan, proof: finalProof)
                        } else {
                            self.sourceSkipped("source_old")
                            try self.finishTarget(target, scan: CommentScan(comments: [], outcome: "保存前来源已过期，缓存丢弃", sourceUnavailable: true), proof: nil)
                        }
                    } else {
                        try self.finishTarget(target, scan: CommentScan(comments: [], outcome: "保存前来源无法核验，缓存丢弃", sourceUnavailable: true), proof: nil)
                    }
                    if self.job?.finished == false { try await Task.sleep(nanoseconds: 5_000_000_000) }
                }
                try Task.checkCancellation()
                guard self.generation == currentGeneration else { return }
                guard self.job?.finished == true else { throw LocalFailure.message("任务状态未完成") }
                await self.prepareProfileSnapshots()
                try Task.checkCancellation()
                guard self.generation == currentGeneration else { return }
                self.running = false; self.canResume = false; self.progress = 1
                self.stage = "3/3 本轮检查结束"
                self.status = (self.job?.added ?? 0) == 0 ?
                    "本轮没有新增符合条件的有日期评论；来源均须原发布90天内，未宣称全量采集。" :
                    "已保存90天内来源中有日期的较新评论及公开主页；范围为本轮已加载样本。"
                self.refreshSummary()
                self.presentCompletion()
            } catch is CancellationError { /* No buffered keys were checkpointed; resume rescans this source. */ }
              catch {
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                self.bufferedCount = 0; self.running = false; self.canResume = self.job.map { !$0.finished } ?? false
                self.stage = "已暂停 · 未完成"
                let message = error.localizedDescription
                self.status = message + (message.hasPrefix("评论批次已保存") ? "" : " 当前视频未入库缓存不会记作完成，继续将重扫。")
                self.refreshSummary()
            }
        }
    }

    func saveVisiblePage() {
        guard !running else { return }
        stop()
        guard let current = webView.url, let components = URLComponents(url: current, resolvingAgainstBaseURL: false) else {
            status = "请打开一个视频评论区"; return
        }
        let ids = components.queryItems?.filter { $0.name == "modal_id" } ?? []
        let source = CollectionPlatform.sourcePlatform(current.absoluteString) == selectedPlatform ? current.absoluteString :
            (selectedPlatform == .douyin && ids.count == 1 ? ids[0].value.map { "https://www.douyin.com/video/" + $0 } : nil) ?? ""
        guard CollectionPlatform.sourcePlatform(source) == selectedPlatform else { status = "请打开单个视频并展开评论"; return }
        running = true; stage = "手动保存本页"
        let currentGeneration = UUID(); generation = currentGeneration
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == currentGeneration { self.suspendProtocolCapture() } }
            do {
                let target = VideoTarget(url: source, title: "")
                guard let proof = try await self.sourceProof(for: target) else {
                    self.running = false; self.status = "未保存：此来源原发布时间未确认在90天内。"; return
                }
                guard let result = try await self.waitForComments("read", target: target, until: CommentPolling.deadline()) else {
                    throw LocalFailure.message("本页评论12秒内未就绪；未把未知状态当作零评论")
                }
                guard result["state"] as? String == "ready", let rows = result["comments"] as? [[String: Any]] else {
                    throw LocalFailure.message(result["message"] as? String ?? "评论不可用")
                }
                let now = Date(); var keys = Set<String>(), buffer: [BufferedComment] = []
                for row in rows.prefix(200) {
                    guard CollectionPlatform.sourceIdentity(row["sourceUrl"] as? String ?? "") == CollectionPlatform.sourceIdentity(source) else {
                        throw LocalFailure.message("本页评论来源不匹配")
                    }
                    let key = CollectionJob.rowKey(row)
                    if keys.insert(key).inserted { buffer.append(BufferedComment(key: key, row: row, time: Self.commentTime(row, observedAt: now))) }
                }
                guard let finalRead = try await self.sourceProof(for: target) else { throw LocalFailure.message("保存前来源无法重新核验") }
                let finalProof = Self.olderProof(proof, finalRead)
                guard SourcePublicationGate.eligible(finalProof, now: Date()) else { throw LocalFailure.message("来源已不在90天范围") }
                let manual = Self.selectedComments(buffer, range: self.selectedRecency, now: Date()).map { item -> [String: Any] in
                    var row = item.row; row["sourceUrl"] = source
                    row["platform"] = self.selectedPlatform.rawValue; row["industry"] = self.selectedIndustry.rawValue; row["product"] = self.keyword
                    row.merge(finalProof.rowFields) { _, verified in verified }
                    row["publishedAtISO"] = ISO8601DateFormatter().string(from: item.time!.date)
                row["publishedTimeQuality"] = item.time!.quality
                    return row
                }
                try Task.checkCancellation()
                let added: Int
                if manual.isEmpty { added = 0 } else { added = try self.store.save(manual, requireRecentSource: true) }
                self.status = "已核验来源7/30/90天；本页有日期评论选取\(manual.count)条，新增\(added)条。仅当前加载样本。"
                self.running = false; self.stage = "手动保存结束"; self.refreshSummary()
            } catch is CancellationError { }
              catch {
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                self.running = false; self.status = "未保存：" + error.localizedDescription
            }
        }
    }

    private func recordNavigation(_ decision: NavigationPolicy.Decision) {
        if decision.effect == .allow && decision.frame != .main { return }
        appendNavigationDiagnostic(decision.diagnosticLine)
    }

    private func rejectNavigation(_ reason: String, message: String) {
        guard trackingNavigation else { return }
        // Preserve the policy reason. Its subsequent 102/-999 must not overwrite it.
        navigationLoad?.rejectPolicy(reason: reason, at: uptime)
        if policyFailureMessage == nil { policyFailureMessage = message }
        pageLoadFailed = true
        if awaitingNavigation != navigationOperation || navigationLoad?.outcome == .succeeded {
            if preparingSnapshots { snapshotNavigationFailure = policyFailureMessage }
            else { stop(policyFailureMessage) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Never load the cleartext URL. Only an exact supported same-site main GET may
        // be replaced by HTTPS, with a strict per-operation loop bound.
        if trackingNavigation, let upgraded = NavigationPolicy.upgradedMainRequestURL(
            url: action.request.url, method: action.request.httpMethod,
            targetIsMainFrame: action.targetFrame?.isMainFrame,
            currentMainURL: navigationLoad?.requestedURL ?? webView.url), allowed(upgraded) {
            prepareSuccessorIfCompleted(upgraded)
            guard navigationLoad?.outcome == .pending else { decisionHandler(.cancel); return }
            guard secureUpgradeBudget.consume() else {
                appendNavigationDiagnostic("frame=main effect=cancelAndPause reason=https_upgrade_loop")
                rejectNavigation("https_upgrade_loop", message: "平台反复跳转到 HTTP，已停止重试并保留断点；请查看诊断。")
                decisionHandler(.cancel); return
            }
            appendNavigationDiagnostic("frame=main effect=upgrade scheme=https reason=same_site_get_upgrade count=\(secureUpgradeBudget.count)")
            if let token = navigationLoad?.activeToken {
                navigationLoad?.recordBenignMainCancellation(token: token, at: uptime)
            }
            lastMainRequestURL = upgraded
            prepareProtocolDocument(for: upgraded)
            decisionHandler(.cancel)
            registerNavigation(webView.load(URLRequest(url: upgraded)))
            return
        }
        let decision = NavigationPolicy.decideAction(url: action.request.url,
            targetIsMainFrame: action.targetFrame?.isMainFrame, currentMainURL: webView.url)
        recordNavigation(decision)
        if decision.effect == .allow, decision.frame == .main, trackingNavigation {
            lastMainRequestURL = action.request.url
            pendingMainNavigationURL = action.request.url
            // beginNavigation already registered the initial documentStart task before
            // load(). Do not rotate it again for the matching policy callback.
            if let url = action.request.url,
               protocolPreparedURL != url.absoluteString || navigationLoad?.outcome == .succeeded {
                prepareProtocolDocument(for: url)
            }
        }
        if decision.effect == .cancel, decision.frame == .main,
           decision.reason == "non_web_handoff_blocked", let token = navigationLoad?.activeToken {
            navigationLoad?.recordBenignMainCancellation(token: token, at: uptime)
        }
        if decision.effect == .cancelAndPause {
            rejectNavigation(decision.reason, message: decision.pauseMessage ?? "主网页导航被拒绝，已保留断点。")
        }
        decisionHandler(decision.effect == .allow ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let decision = NavigationPolicy.decideResponse(url: response.response.url,
            isMainFrame: response.isForMainFrame, httpStatus: (response.response as? HTTPURLResponse)?.statusCode)
        recordNavigation(decision)
        if decision.effect == .cancelAndPause {
            rejectNavigation(decision.reason, message: decision.pauseMessage ?? "主网页响应被拒绝，已保留断点。")
        }
        decisionHandler(decision.effect == .allow ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard trackingNavigation, let navigation else { return }
        let key = ObjectIdentifier(navigation)
        if let token = navigationTokens[key] {
            // Includes old callbacks after cancellation: never register them as a successor.
            if token != navigationLoad?.activeToken { return }
            pendingMainNavigationURL = nil
        } else {
            guard let target = pendingMainNavigationURL, allowed(target) else { return }
            pendingMainNavigationURL = nil
            if navigationLoad?.outcome == .succeeded {
                prepareSuccessorIfCompleted(target)
            }
            guard navigationLoad?.outcome == .pending else { return }
            registerNavigation(navigation)
            monitorNavigation()
        }
        appendNavigationDiagnostic("load=started phase=provisional")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let navigation, let token = navigationTokens[ObjectIdentifier(navigation)] else { return }
        navigationLoad?.commit(token: token, at: uptime)
        if token == navigationLoad?.activeToken { appendNavigationDiagnostic("load=committed") }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, let token = navigationTokens[ObjectIdentifier(navigation)],
              let target = navigationLoad?.requestedURL else { return }
        let matches = allowed(webView.url) && NavigationPolicy.matchesDestination(requested: target, actual: webView.url)
        navigationLoad?.finish(token: token, validDocument: matches, at: uptime)
        if token == navigationLoad?.activeToken {
            appendNavigationDiagnostic("load=finished destination_match=\(matches)")
        }
    }

    private func failedNavigation(_ navigation: WKNavigation?, error: Error, phase: String) {
        let ns = error as NSError
        let safe = NavigationLoadState.Failure.network(ns)
        let token = navigation.flatMap { navigationTokens[ObjectIdentifier($0)] }
        let current = token != nil && token == navigationLoad?.activeToken
        appendNavigationDiagnostic("load=callback phase=\(phase) current=\(current) domain=\(safe.domain) code=\(safe.code)")
        guard current, let token else { return }
        navigationLoad?.fail(token: token, error: ns, at: uptime)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failedNavigation(navigation, error: error, phase: "provisional")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failedNavigation(navigation, error: error, phase: "committed")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        appendNavigationDiagnostic("load=failed reason=web_process_terminated")
        rejectNavigation("web_process_terminated", message: "网页进程被系统回收，已保留断点；请重新打开平台。")
    }
}
