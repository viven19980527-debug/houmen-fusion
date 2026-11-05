import SwiftUI
import SafariServices
import WebKit

/// Only Bilibili has a new collection adapter. Other buttons open manual search;
/// they do not inject scripts, transfer login sessions, or promise collection.
struct FusionRadarView: View {
    @EnvironmentObject private var fusion: FusionLeadStore
    @StateObject private var client = FusionBiliClient()
    @State private var keyword = ""
    @State private var limit = 50
    @State private var searchTask: Task<Void, Never>?
    @State private var browser: FusionSearchPage?
    @State private var showBiliLogin = false
    @State private var loggedIn = BiliAuth.isLoggedIn

    private var term: String { keyword.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("公开内容 · 人工确认 · 本机保存", systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline)
                    Text("融合的是公开评论与跟进工作流，不是私人联系方式获取。请只处理你有权保存的内容；提问不等于购买意向。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("输入产品或服务关键词", text: $keyword)
                        .autocorrectionDisabled().disabled(client.running)
                    Text("关键词 1–100 字；不会把关键词自动发给其他平台。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("B站公开评论 · 实验性接口") {
                    HStack {
                        Image(systemName: loggedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(loggedIn ? .green : .orange)
                        Text(loggedIn ? "B站已登录" : "B站未登录（会返回 -101）")
                        Spacer()
                        Button(loggedIn ? "重新登录" : "登录") { showBiliLogin = true }
                            .font(.callout)
                    }
                    if loggedIn {
                        Button("清除登录态", role: .destructive) {
                            BiliAuth.signOut(); loggedIn = false
                        }.font(.caption)
                    }
                    Text("未登录时 B站 会拒绝公开接口（code=-101）。登录只保存在本机，仅用于通过访客校验，不上传。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Picker("本轮最多读取", selection: $limit) {
                        Text("20 条").tag(20)
                        Text("50 条").tag(50)
                        Text("100 条").tag(100)
                    }.disabled(client.running)
                    Text("最多检查10个搜索视频，各取有限首批评论；不代表全量评论或已认证的90天范围。接口尚未完成在线兼容性验收，认证、拒绝访问或限流时立即停止。")
                        .font(.caption).foregroundStyle(.secondary)
                    if client.running {
                        HStack { ProgressView(); Text("正在读取公开内容…") }
                        Button("停止本轮", role: .destructive, action: stop)
                    } else {
                        Button(action: search) {
                            Label("读取 B站公开评论", systemImage: "magnifyingglass")
                        }.disabled(term.isEmpty || term.count > 100 || fusion.loadError != nil)
                    }
                    if !client.progress.isEmpty { Text(client.progress).font(.caption) }
                    if !client.errorText.isEmpty {
                        Label(client.errorText, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let error = fusion.loadError { Text(error).font(.caption).foregroundStyle(.orange) }
                    Text("成功保存的结果会出现在「线索工作台」。重复记录不会重复计数。离开此页会停止请求，已保存记录保留。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("多平台入口 · 手动浏览") {
                    Text("抖音、小红书请使用「精细采集」页，保留原有登录与来源核验流程。下方仅打开搜索页，不自动采集或导入。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(FusionSearchPlatform.allCases) { platform in
                        Button {
                            if let url = platform.searchURL(keyword: term) { browser = FusionSearchPage(url: url) }
                        } label: {
                            Label("打开\(platform.title)搜索", systemImage: "safari")
                        }.disabled(term.isEmpty || term.count > 100 || client.running)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(BackdoorTheme.background)
            .navigationTitle("获客雷达")
            .sheet(item: $browser) { page in FusionSafariView(url: page.url) }
            .sheet(isPresented: $showBiliLogin) {
                BiliLoginView()
            }
            .onChange(of: showBiliLogin) { presenting in
                if !presenting { loggedIn = BiliAuth.isLoggedIn }
            }
            .onDisappear(perform: stop)
        }
    }

    private func search() {
        guard !client.running else { return }
        let query = term
        let maximum = limit
        searchTask = Task { @MainActor in
            await client.search(keyword: query, limit: maximum) { rows in
                try fusion.add(rows)
            }
            searchTask = nil
        }
    }

    private func stop() { searchTask?.cancel(); client.cancel() }
}

enum FusionSearchPlatform: String, CaseIterable, Identifiable {
    case bilibili, weibo, kuaishou
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bilibili: return "B站"
        case .weibo: return "微博"
        case .kuaishou: return "快手"
        }
    }
    func searchURL(keyword: String) -> URL? {
        guard !keyword.isEmpty, keyword.count <= 100 else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        switch self {
        case .bilibili:
            c.host = "search.bilibili.com"; c.path = "/all"
            c.queryItems = [URLQueryItem(name: "keyword", value: keyword)]
        case .weibo:
            c.host = "s.weibo.com"; c.path = "/weibo"
            c.queryItems = [URLQueryItem(name: "q", value: keyword)]
        case .kuaishou:
            c.host = "www.kuaishou.com"; c.path = "/search/video"
            c.queryItems = [URLQueryItem(name: "searchKey", value: keyword)]
        }
        return c.url
    }
}

private struct FusionSearchPage: Identifiable {
    let id = UUID()
    let url: URL
}

private struct FusionSafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}


// MARK: - 统一采集页（B站 + 抖音 + 小红书 同页，同一套登录）

struct UnifiedCaptureView: View {
    @EnvironmentObject private var store: CommentStore
    @EnvironmentObject private var fusion: FusionLeadStore

    @StateObject private var bili = FusionBiliClient()
    @State private var collectors: [AuthPlatform: BrowserCollector] = [:]

    @State private var keyword = ""
    @State private var limit = 50
    @State private var picked: Set<AuthPlatform> = [.bilibili]
    @State private var loginTarget: AuthPlatform?
    @State private var runningPlatform: AuthPlatform?
    @State private var logLines: [String] = []
    @State private var busy = false
    @State private var showAdvanced = false
    @AppStorage("cap.maxAgeHours") private var maxAgeHours = 0        // 0=不限
    @AppStorage("cap.monitorMids") private var monitorRaw = ""        // 逗号分隔 UID
    @State private var newMid = ""

    private var term: String { keyword.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("关键词") {
                    TextField("输入关键词，例如：空调安装多少钱", text: $keyword)
                        .autocorrectionDisabled()
                    Picker("每个平台最多", selection: $limit) {
                        Text("20 条").tag(20)
                        Text("50 条").tag(50)
                        Text("100 条").tag(100)
                    }
                }

                Section("新帖狙击 · 发布时效") {
                    Picker("只看", selection: $maxAgeHours) {
                        Text("不限").tag(0)
                        Text("2 小时内").tag(2)
                        Text("6 小时内").tag(6)
                        Text("24 小时内").tag(24)
                        Text("3 天内").tag(72)
                    }
                    Text("只采最近发布的视频：同行还没反应过来，评论区竞争最少。B站按视频发布时间过滤；抖音/小红书在采集器里按来源日期核验。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section("竞品账号订阅（B站 UID）") {
                    HStack {
                        TextField("输入 UID，如 4384200", text: $newMid)
                            .keyboardType(.numberPad)
                        Button("添加") { addMid() }
                            .disabled(newMid.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    let mids = monitorList
                    if mids.isEmpty {
                        Text("还没有监控账号。把你关注的同行 UID 加进来，每次采集会先扫他们最新的视频。")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ForEach(mids, id: \.self) { mid in
                            HStack {
                                Text(mid).font(.body.monospaced())
                                Spacer()
                                Button("删除") { removeMid(mid) }
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                        Text("共 \(mids.count) 个账号 · 每个最多取 5 个最新视频")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Section("平台（可多选，一次跑完）") {
                    ForEach(AuthPlatform.allCases) { p in
                        Button {
                            if picked.contains(p) { picked.remove(p) } else { picked.insert(p) }
                        } label: {
                            HStack {
                                Image(systemName: picked.contains(p) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(p) ? Color.accentColor : .secondary)
                                Text(p.title)
                                Spacer()
                                if p.isLoggedIn {
                                    Text("已登录").font(.caption2).foregroundStyle(.green)
                                } else {
                                    Text("未登录").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("登录（三个平台同一套流程）") {
                    ForEach(AuthPlatform.allCases) { p in
                        HStack {
                            Image(systemName: p.isLoggedIn
                                  ? "checkmark.seal.fill" : "person.crop.circle.badge.exclamationmark")
                                .foregroundStyle(p.isLoggedIn ? .green : .orange)
                            Text(p.title)
                            Spacer()
                            Button(p.isLoggedIn ? "重新登录" : "登录") {
                                loginTarget = p
                            }
                            if p.isLoggedIn {
                                Button("清除") { PlatformAuth.signOut(p); refreshAll() }
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    Text("登录只为通过平台访客校验；cookie 保存在本机，不上传。抖音/小红书登录后，内置浏览器会直接复用同一登录态。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section("采集") {
                    Button {
                        runAll()
                    } label: {
                        HStack {
                            Image(systemName: "bolt.horizontal.circle.fill")
                            Text(busy ? "采集中…" : "一键采集（\(picked.count) 个平台）")
                                .font(.headline)
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy || term.isEmpty || picked.isEmpty)
                    if !bili.progress.isEmpty {
                        Text(bili.progress).font(.caption2)
                    }
                    if !bili.errorText.isEmpty {
                        Label(bili.errorText, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                if !logLines.isEmpty {
                    Section("运行日志") {
                        ForEach(Array(logLines.suffix(12).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(BackdoorTheme.background)
            .navigationTitle("采集")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("精细采集（高级流程）") { showAdvanced = true }
                        Button("打开 B站搜索页") { openSearch(.bilibili) }
                        Button("打开抖音搜索页") { openSearch(.douyin) }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showAdvanced) {
                NavigationStack { HomeView() }
                    .environmentObject(store)
                    .environmentObject(fusion)
            }
            .sheet(item: $loginTarget, onDismiss: { refreshAll() }) { p in
                PlatformLoginView(platform: p)
            }
            .sheet(item: $runningPlatform) { p in
                collectorSheet(p)
            }
            .onAppear { refreshAll() }
        }
    }

    // MARK: 采集器 sheet（抖音 / 小红书）

    // 内置浏览器（复用采集器的 WKWebView）
    private struct CollectorWebView: UIViewRepresentable {
        let webView: WKWebView
        func makeUIView(context: Context) -> WKWebView { webView }
        func updateUIView(_ uiView: WKWebView, context: Context) {}
    }

    @ViewBuilder
    private func collectorSheet(_ p: AuthPlatform) -> some View {
        let c: BrowserCollector = {
            if let existing = collectors[p] { return existing }
            let made = BrowserCollector(store: store)
            collectors[p] = made
            return made
        }()
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.stage).font(.caption).bold()
                    Text(c.runSummary).font(.caption2).foregroundStyle(.secondary)
                    if c.progress > 0 {
                        ProgressView(value: c.progress).progressViewStyle(.linear)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.blue.opacity(0.12))

                CollectorWebView(webView: c.webView)

                HStack(spacing: 8) {
                    if c.running {
                        Button(role: .destructive) {
                            c.stop()
                            log("\(p.title)：已暂停（可续采）")
                        } label: { Label("暂停", systemImage: "pause.fill") }
                        .buttonStyle(.bordered)
                    } else if c.canResume {
                        Button {
                            c.resume()
                            log("\(p.title)：继续采集")
                        } label: { Label("继续", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            startCollector(c, p)
                        } label: { Label("开始", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                    }
                    Button {
                        c.saveVisiblePage()
                        log("\(p.title)：已保存当前页")
                    } label: { Label("存当前页", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("完成") {
                        c.stop()
                        runningPlatform = nil
                        log("\(p.title)：结束，结果已进「线索工作台」")
                    }.bold()
                }
                .padding(8)
            }
            .navigationTitle("\(p.title) 采集")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if !c.running && !c.canResume { startCollector(c, p) } }
        }
    }

    private func startCollector(_ c: BrowserCollector, _ p: AuthPlatform) {
        log("\(p.title)：开始采集…")
        if p == .douyin {
            c.start(keyword: term, recency: .all, industry: .general, platform: .douyin)
        } else {
            c.start(keyword: term, recency: .all, industry: .general, platform: .xiaohongshu)
        }
    }

    // MARK: 运行

    private func runAll() {
        guard !busy else { return }
        busy = true
        log("开始：\(picked.map { $0.title }.joined(separator: "、")) · 关键词「\(term)」")
        Task {
            // 1) B站：原生
            if picked.contains(AuthPlatform.bilibili) {
                if !AuthPlatform.bilibili.isLoggedIn {
                    log("B站：未登录，可能返回 -101")
                }
                await bili.search(keyword: term, limit: limit,
                                  maxAgeHours: maxAgeHours > 0 ? maxAgeHours : nil,
                                  monitorMids: monitorList) { rows in
                    try fusion.add(rows)
                }
                log("B站：完成，\(bili.progress)")
            }
            // 2) 抖音 / 小红书：内置浏览器
            for p: AuthPlatform in [.douyin, .xhs] where picked.contains(p) {
                await MainActor.run { runningPlatform = p }
                log("\(p.title)：已打开内置浏览器，完成后点「完成」")
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                await MainActor.run { runningPlatform = nil }
            }
            await MainActor.run {
                busy = false
                log("全部完成。结果在「线索工作台」")
                refreshAll()
            }
        }
    }

    private func openSearch(_ p: AuthPlatform) {
        if let url = URL(string: p.loginURL.replacingOccurrences(of: "/login", with: "")) {
            UIApplication.shared.open(url)
        }
    }

    private var monitorList: [String] {
        monitorRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func addMid() {
        let v = newMid.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !monitorList.contains(v) else { newMid = ""; return }
        monitorRaw = (monitorList + [v]).joined(separator: ",")
        newMid = ""
        log("已添加监控账号 \(v)")
    }

    private func removeMid(_ mid: String) {
        monitorRaw = monitorList.filter { $0 != mid }.joined(separator: ",")
        log("已移除监控账号 \(mid)")
    }

    private func log(_ s: String) {
        logLines.append(s)
    }

    private func refreshAll() {
        for p in AuthPlatform.allCases where p != .bilibili {
            PlatformAuth.checkWebKit(p) { _ in }
        }
    }
}
