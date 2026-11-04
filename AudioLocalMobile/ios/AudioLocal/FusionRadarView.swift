import SwiftUI
import SafariServices

/// Only Bilibili has a new collection adapter. Other buttons open manual search;
/// they do not inject scripts, transfer login sessions, or promise collection.
struct FusionRadarView: View {
    @EnvironmentObject private var fusion: FusionLeadStore
    @StateObject private var client = FusionBiliClient()
    @State private var keyword = ""
    @State private var limit = 50
    @State private var searchTask: Task<Void, Never>?
    @State private var browser: FusionSearchPage?

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
