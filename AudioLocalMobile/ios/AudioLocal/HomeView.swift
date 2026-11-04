import SwiftUI
import UniformTypeIdentifiers
import WebKit
import UIKit

// Keep all native surfaces in one restrained dark palette. Web-page content is not restyled.
enum BackdoorTheme {
    static let background = Color(red: 0.025, green: 0.030, blue: 0.040)
    static let surface = Color(red: 0.075, green: 0.085, blue: 0.105)
    static let prominent = Color(red: 0.19, green: 0.22, blue: 0.27)
    static let accent = Color(red: 0.78, green: 0.84, blue: 0.93)
    static let secondary = Color(red: 0.68, green: 0.72, blue: 0.78)
    static let warning = Color(red: 1.0, green: 0.63, blue: 0.62)
}

private struct NightBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack(alignment: .topLeading) {
            BackdoorTheme.background
            if !reduceTransparency {
                RadialGradient(colors: [Color(red: 0.15, green: 0.18, blue: 0.23).opacity(0.45), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 520)
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Native glass is limited to grouped control surfaces; older iOS keeps the same hierarchy.
private struct NightGlassGroup<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: 8) { content }
        } else { content }
    }
}

private struct NightSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat = 18
    var prominent = false
    var interactive = false
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content.background(prominent ? BackdoorTheme.prominent : BackdoorTheme.surface, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(prominent ? 0.28 : 0.12), lineWidth: 0.75).allowsHitTesting(false))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.white.opacity(prominent ? 0.16 : 0.035)).interactive(interactive),
                                in: .rect(cornerRadius: radius))
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .background(prominent ? BackdoorTheme.prominent.opacity(0.85) : BackdoorTheme.surface.opacity(0.45), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(prominent ? 0.28 : 0.10), lineWidth: 0.75).allowsHitTesting(false))
        }
    }
}

/// Content cards use one quiet material layer, not nested interactive glass.
private struct NightCard: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if reduceTransparency {
            content.background(BackdoorTheme.surface, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.75).allowsHitTesting(false))
        }
    }
}

private struct NightFormRow: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var body: some View {
        if reduceTransparency { BackdoorTheme.surface }
        else { Rectangle().fill(.ultraThinMaterial) }
    }
}

private struct NightPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 28).padding(.horizontal, 18).padding(.vertical, 14)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .modifier(NightSurface(prominent: true, interactive: true))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.42)
    }
}

private extension View {
    func nightSurface(radius: CGFloat = 18, interactive: Bool = false) -> some View {
        modifier(NightSurface(radius: radius, interactive: interactive))
    }
    func nightCard() -> some View { modifier(NightCard()) }
    func nightScreen() -> some View {
        foregroundStyle(.white).tint(BackdoorTheme.accent)
            .background { NightBackdrop() }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .preferredColorScheme(.dark)
    }
}
private let channelsUnavailable = "视频号采集尚未接通，未启动任务。能打开视频号助手不等于已实现关键词查找和评论采集。"

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = value
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private enum BrowserAction { case newTask, resume, browse }
private struct BrowserSession: Identifiable {
    let id = UUID()
    let keyword: String
    let recency: CommentRecency
    let industry: IndustryProfile
    let platform: CollectionPlatform
    let action: BrowserAction
}
private struct ProfileSnapshotPresentation: Identifiable {
    let profileURL: String
    let name: String
    var id: String { CollectionPlatform.profileIdentity(profileURL) ?? profileURL }
}
private struct Followup: Identifiable { let id: String; let note: String }
private struct ProfileReview: Identifiable { let id: String; let comment: AudioComment }
private struct UserNotice: Identifiable { let id = UUID(); let text: String }
private struct SettingsPresentation: Identifiable { let id = UUID() }
private struct DiagnosticPresentation: Identifiable { let id = UUID(); let report: String }
private struct CleanupRequest { let ids: Set<String>; let description: String; let favorites: Int }

private struct LocalFilters {
    var query = ""
    var savedOnly = false
    var cluesOnly = true
    var grouped = true
    var region = ""
    var minimumAge: Int?
    var maximumAge: Int?
    var includeUnknownAge = true
    var chips: [String] {
        var values: [String] = []
        if !query.isEmpty { values.append("搜索：" + query) }
        if savedOnly { values.append("已收藏") }
        if cluesOnly { values.append("意向待核实") }
        if !region.isEmpty { values.append("地区：" + region) }
        if minimumAge != nil || maximumAge != nil {
            let lower = minimumAge.map(String.init) ?? "不限"
            let upper = maximumAge.map(String.init) ?? "不限"
            values.append("年龄 \(lower)–\(upper)" + (includeUnknownAge ? " · 含未知" : ""))
        } else if !includeUnknownAge { values.append("排除年龄未知") }
        if grouped { values.append("按主页合并") }
        return values
    }
}

private func sourcePriorityLabel(_ comment: AudioComment, now: Date = Date()) -> String {
    switch SourcePublicationGate.sourceTier(comment, now: now) {
    case 7: return "近7天"
    case 30: return "8–30天"
    case 90: return "31–90天"
    default: return "日期待核实"
    }
}

private func checkedAge(_ raw: String) throws -> Int? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return nil }
    guard let age = Int(value), (1...120).contains(age), value.allSatisfy({ $0.isNumber }) else {
        throw LocalFailure.message("年龄请填写 1–120 的整数，或留空不限。")
    }
    return age
}

@MainActor
struct HomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: CommentStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var sourceEligibilityNow = Date()
    @State private var selectedPlatform: CollectionPlatform = .douyin
    @State private var selectedIndustry: IndustryProfile?
    @State private var keyword = ""
    @State private var taskKeyword = ""
    @State private var taskIndustry: IndustryProfile = .general
    @State private var taskPlatform: CollectionPlatform = .douyin
    @State private var recency: CommentRecency = .all
    @State private var showHistory = false
    @State private var showSuggestions = false
    @State private var filters = LocalFilters()
    @State private var displayLimit = 50
    @State private var browser: BrowserSession?
    @State private var pendingCompletion: CollectionCompletion?
    @State private var completedResults: CollectionCompletion?
    @State private var followup: Followup?
    @State private var profileReview: ProfileReview?
    @State private var settings: SettingsPresentation?
    @State private var notice: UserNotice?
    @State private var cleanup: CleanupRequest?
    @State private var exporting = false
    @State private var exportDescription = ""
    @State private var exportFilename = "后门-来源分档-评论"
    @State private var document = CSVDocument(text: "")
    private var recentKeywords: [String] {
        guard let selectedIndustry else { return [] }
        var seen = Set<String>()
        var values: [String] = []
        // Collection time is used only for recent search suggestions, never to sort comment results.
        for comment in store.comments.sorted(by: { $0.collectedAt > $1.collectedAt }) {
            guard comment.platform == selectedPlatform.rawValue,
                  (IndustryProfile(rawValue: comment.industry ?? "") ?? .general) == selectedIndustry else { continue }
            let value = comment.product.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 60 else { continue }
            if seen.insert(normalizedKeyword(value)).inserted { values.append(value) }
            if values.count == 6 { break }
        }
        return values
    }

    private func normalizedKeyword(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private var scopeTitle: String {
        showHistory || taskKeyword.isEmpty ? "全部任务 · 90天来源" : taskPlatform.title + " · " + taskIndustry.title + " · " + taskKeyword
    }
    private var sourceEligibleComments: [AudioComment] {
        // Every display/filter scope starts from verified recent source publication.
        // Saved-only, all-comment-time and all-task views must not bypass this gate.
        store.comments.filter { SourcePublicationGate.sourceEligible($0, now: sourceEligibilityNow) }
    }
    private var scopedComments: [AudioComment] {
        guard !showHistory, !taskKeyword.isEmpty else { return sourceEligibleComments }
        let submitted = normalizedKeyword(taskKeyword)
        // Associate the collection term, not literal words inside short replies such as "多少钱".
        return sourceEligibleComments.filter {
            $0.platform == taskPlatform.rawValue && normalizedKeyword($0.product) == submitted &&
            (IndustryProfile(rawValue: $0.industry ?? "") ?? .general) == taskIndustry
        }
    }
    private var filteredBeforeTime: [AudioComment] {
        let textMatches = LeadFiltering.filter(scopedComments, query: filters.query,
                                               savedOnly: filters.savedOnly, cluesOnly: filters.cluesOnly)
        return CommentRecency.filterDemographics(textMatches, region: filters.region,
                                                minimumAge: filters.minimumAge, maximumAge: filters.maximumAge,
                                                includeUnknownAge: filters.includeUnknownAge)
    }
    private var rows: [AudioComment] {
        // Publication-date ordering is applied last; never use collection time as publication time.
        CommentRecency.filteredAndSorted(filteredBeforeTime, range: recency)
    }
    private var cleanupPresented: Binding<Bool> {
        Binding(get: { cleanup != nil }, set: { if !$0 { cleanup = nil } })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    collectionControls
                    if let error = store.loadError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(BackdoorTheme.warning).textSelection(.enabled)
                    }
                    results
                }.padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .nightScreen()
            .navigationTitle("后门").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { actionsMenu }
            }
            .sheet(item: $browser, onDismiss: {
                // Wait for the browser dismissal before presenting the real result sheet.
                if let result = pendingCompletion {
                    pendingCompletion = nil; completedResults = result
                }
            }) { session in
                CollectorScreen(store: store, keyword: session.keyword, recency: session.recency,
                                industry: session.industry, platform: session.platform, action: session.action) { result in
                    pendingCompletion = result
                    browser = nil
                }
            }
            .sheet(item: $completedResults) { result in
                CollectionResultsSheet(completion: result, store: store)
            }
            .sheet(item: $followup) { value in
                FollowupSheet(value: value) { note in try store.preference(id: value.id, note: note) }
            }
            .sheet(item: $profileReview) { value in
                PublicProfileSheet(comment: value.comment) { region, age in
                    try store.publicProfile(id: value.id, region: region, age: age)
                }
            }
            .sheet(item: $settings) { _ in
                LocalSettingsSheet(filters: filters, showHistory: showHistory,
                                   taskKeyword: taskKeyword, taskIndustry: taskIndustry, taskPlatform: taskPlatform,
                                   totalCount: sourceEligibleComments.count) { next, history in
                    filters = next; showHistory = history; displayLimit = 50
                }
            }
            .alert(item: $notice) { value in
                Alert(title: Text("后门"), message: Text(value.text), dismissButton: .default(Text("知道了")))
            }
            .confirmationDialog("确认清理本机记录？", isPresented: cleanupPresented, titleVisibility: .visible) {
                if let request = cleanup {
                    Button("删除 \(request.ids.count) 条", role: .destructive) { performCleanup(request) }
                    Button("取消", role: .cancel) { cleanup = nil }
                }
            } message: {
                if let request = cleanup {
                    Text("\(request.description)，共 \(request.ids.count) 条，其中收藏 \(request.favorites) 条。评论和备注一并删除，不能撤销，请先导出。不影响平台原评论。")
                }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText,
                          defaultFilename: exportFilename) { result in
                switch result {
                case .success: notice = UserNotice(text: "已导出" + exportDescription)
                case .failure(let error): notice = UserNotice(text: "导出失败：" + error.localizedDescription)
                }
            }
            .onChange(of: selectedIndustry) { _ in keyword = ""; showSuggestions = false }
            .onChange(of: selectedPlatform) { _ in showSuggestions = false }
            .onChange(of: recency) { _ in displayLimit = 50 }
            .onChange(of: showHistory) { _ in displayLimit = 50 }
            .onChange(of: scenePhase) { phase in
                if phase == .active { sourceEligibilityNow = Date() }
            }
            .task {
                // Refresh day-boundary eligibility even when the screen stays open.
                while !Task.isCancelled {
                    sourceEligibilityNow = Date()
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                    catch { return }
                }
            }
        }
    }

    private var platformPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("平台", systemImage: "square.stack.3d.up").font(.caption).foregroundStyle(BackdoorTheme.secondary)
            Picker("采集平台", selection: $selectedPlatform) {
                ForEach(CollectionPlatform.allCases) { value in
                    Text(value == .xiaohongshu ? "小红书·未验收" : value.entryLabel).tag(value)
                }
            }.pickerStyle(.menu).labelsHidden().font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityLabel("选择采集平台")
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).nightSurface(interactive: true)
    }

    private var industryPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("行业", systemImage: "square.grid.2x2").font(.caption).foregroundStyle(BackdoorTheme.secondary)
            Picker("选择行业", selection: $selectedIndustry) {
                Text("选择行业").tag(IndustryProfile?.none)
                ForEach(IndustryProfile.allCases) { value in
                    Text(value.title).tag(Optional(value))
                }
            }.pickerStyle(.menu).labelsHidden().font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityLabel("选择行业")
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).nightSurface(interactive: true)
    }

    private var keywordInput: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(BackdoorTheme.secondary).accessibilityHidden(true)
            TextField("产品、服务、品牌或需求", text: $keyword)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).onSubmit { startCollection() }
                .accessibilityLabel("采集关键词")
            if !keyword.isEmpty {
                Button { keyword = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(BackdoorTheme.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("清空待采集关键词")
            }
        }.padding(.leading, 16).padding(.trailing, keyword.isEmpty ? 16 : 4)
            .frame(minHeight: 58).nightSurface(interactive: true)
    }

    private func keywordChips(_ values: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(values, id: \.self) { value in
                    Button(value) { keyword = value }.buttonStyle(.bordered)
                        .font(.caption).frame(minHeight: 44)
                }
            }
        }
    }

    private var collectionControls: some View {
        NightGlassGroup {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 7) {
                    Image(systemName: "clock.badge.checkmark").accessibilityHidden(true)
                    Text("近7天优先 · 最长90天")
                }.font(.caption.weight(.medium)).foregroundStyle(BackdoorTheme.accent)
                    .padding(.bottom, 2).accessibilityElement(children: .combine)
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) { industryPicker; platformPicker }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) { industryPicker; platformPicker }
                        VStack(spacing: 12) { industryPicker; platformPicker }
                    }
                }
                if selectedPlatform == .xiaohongshu {
                    Text("小红书尚未接通验收 · 仅供测试")
                        .font(.caption).foregroundStyle(BackdoorTheme.secondary)
                } else if !selectedPlatform.canCollect {
                    Text("视频号未接通评论采集")
                        .font(.caption).foregroundStyle(BackdoorTheme.secondary)
                }
                if let industry = selectedIndustry {
                    keywordInput
                    if !industry.suggestedKeywords.isEmpty || !recentKeywords.isEmpty {
                        DisclosureGroup("关键词建议与最近搜索", isExpanded: $showSuggestions) {
                            VStack(alignment: .leading, spacing: 4) {
                                keywordChips(Array(industry.suggestedKeywords.prefix(6)))
                                if !recentKeywords.isEmpty { keywordChips(recentKeywords) }
                            }.padding(.top, 6)
                        }.font(.caption).tint(BackdoorTheme.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("评论时间 · 来源最长90天").font(.caption).foregroundStyle(BackdoorTheme.secondary)
                    Picker("评论发布时间范围", selection: $recency) {
                        ForEach(CommentRecency.allCases) { value in Text(value.title).tag(value) }
                    }.pickerStyle(.segmented)
                }
                Button(action: startCollection) {
                    Label(selectedIndustry == nil ? "先选择行业" : "查找潜在客户", systemImage: "magnifyingglass")
                        .multilineTextAlignment(.center)
                }.buttonStyle(NightPrimaryButtonStyle())
                    .disabled(store.loadError != nil || selectedIndustry == nil)
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            Section("结果") {
                Button("所有任务的90天来源") { revealAllHistory() }
                if !taskKeyword.isEmpty {
                    Button("当前任务：\(taskPlatform.title) · \(taskIndustry.title) · \(taskKeyword)") { showHistory = false; filters = LocalFilters() }
                }
                Button("使用说明") { settings = SettingsPresentation() }
            }
            Section("导出") {
                Button("导出当前结果（\(rows.count) 条）") { export(rows, description: "当前结果") }
                Button("导出全部合格来源（\(sourceEligibleComments.count) 条）") {
                    export(CommentRecency.filteredAndSorted(sourceEligibleComments, range: .all), description: "90天来源")
                }
                Button("历史备份（含旧记录，\(store.comments.count) 条）") {
                    export(CommentRecency.filteredAndSorted(store.comments, range: .all), description: "历史备份（非当前潜客结果）", historyBackup: true)
                }
            }
            Section("采集") {
                Button("继续上次断点任务") {
                    revealAllHistory()
                    browser = BrowserSession(keyword: taskKeyword, recency: recency, industry: taskIndustry, platform: taskPlatform, action: .resume)
                }
                Button("平台登录 / 查看网页") {
                    if selectedPlatform.canCollect {
                        browser = BrowserSession(keyword: "", recency: recency, industry: .general,
                                                 platform: selectedPlatform, action: .browse)
                    } else { notice = UserNotice(text: channelsUnavailable) }
                }
            }
            Menu("清理本机记录…") {
                Button("删除当前结果", role: .destructive) { requestCleanup(rows, description: "当前结果") }
                Button("删除所有未收藏记录", role: .destructive) {
                    requestCleanup(store.comments.filter { !$0.saved }, description: "所有未收藏记录")
                }
                Button("删除全部记录", role: .destructive) { requestCleanup(store.comments, description: "本机全部记录") }
            }.disabled(store.comments.isEmpty || store.loadError != nil)
            Button("退出本 App 内全部平台登录") {
                WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                    notice = UserNotice(text: "此 App 内全部平台登录状态已清除，本机评论保留。")
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44).accessibilityLabel("历史、导出和设置")
        }
    }

    private var results: some View {
        let filtered = rows
        let groups = LeadGrouping.groups(filtered)
        let unknownCount = filteredBeforeTime.filter { CommentRecency.publicationDate($0) == nil }.count
        return LazyVStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("客户线索").font(.title3.weight(.semibold))
                    Text(scopeTitle).font(.caption).foregroundStyle(BackdoorTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { settings = SettingsPresentation() } label: {
                    Image(systemName: filters.chips.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        .font(.title3).frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("筛选地区、年龄及本机记录")
            }
            HStack {
                Text("\(groups.count) 个用户 · \(filtered.count) 条\(filters.cluesOnly ? "意向" : "")评论")
                Spacer()
                Text("最新优先").fixedSize()
            }.font(.caption).foregroundStyle(BackdoorTheme.secondary)
            if !filters.chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(filters.chips, id: \.self) { value in
                            Text(value).font(.caption2).padding(.horizontal, 8).padding(.vertical, 5)
                                .background(BackdoorTheme.accent.opacity(0.10), in: Capsule())
                        }
                        Button("重置") { filters = LocalFilters(); displayLimit = 50 }.font(.caption)
                    }
                }
            }
            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.title2).foregroundStyle(BackdoorTheme.secondary)
                    Text(store.comments.isEmpty ? "选择行业，再输入关键词。" : "暂无符合90天来源条件的评论。")
                        .font(.subheadline).foregroundStyle(BackdoorTheme.secondary)
                    if !sourceEligibleComments.isEmpty {
                        Button("查看所有合格来源（\(sourceEligibleComments.count) 条）") { revealAllHistory() }.font(.caption)
                    } else if !store.comments.isEmpty {
                        Text("旧记录仍保留，可在菜单导出历史备份。")
                            .font(.caption2).foregroundStyle(BackdoorTheme.secondary)
                    }
                }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .padding(.horizontal, 20).padding(.vertical, 34).nightCard()
            } else if filters.grouped {
                ForEach(Array(groups.prefix(displayLimit))) { group in
                    GroupedCommentsCard(group: group, onFavorite: toggleFavorite, onNote: openNote, onProfile: openProfile)
                }
                if groups.count > displayLimit {
                    Button("显示更多主页（\(groups.count - displayLimit)）") { displayLimit += 50 }.font(.footnote)
                }
            } else {
                ForEach(Array(filtered.prefix(displayLimit))) { comment in
                    CommentCard(comment: comment, onFavorite: toggleFavorite, onNote: openNote, onProfile: openProfile)
                        .padding(18).nightCard()
                }
                if filtered.count > displayLimit {
                    Button("显示更多评论（\(filtered.count - displayLimit)）") { displayLimit += 50 }.font(.footnote)
                }
            }
            if recency != .all && unknownCount > 0 {
                HStack {
                    Text("\(unknownCount) 条评论发布时间待核实").foregroundStyle(BackdoorTheme.secondary)
                    Button("放宽评论时间") { recency = .all }
                }.font(.caption2)
            }
        }
    }

    private func startCollection() {
        guard let industry = selectedIndustry else { notice = UserNotice(text: "请先选择行业。"); return }
        guard selectedPlatform.canCollect else { notice = UserNotice(text: channelsUnavailable); return }
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { notice = UserNotice(text: "先输入一个产品、服务、品牌或需求。"); return }
        guard term.count <= 60 else { notice = UserNotice(text: "关键词请控制在 60 字以内。"); return }
        keyword = term; taskKeyword = term; taskIndustry = industry; taskPlatform = selectedPlatform
        showHistory = false; displayLimit = 50
        browser = BrowserSession(keyword: term, recency: recency, industry: industry, platform: selectedPlatform, action: .newTask)
    }
    private func revealAllHistory() {
        showHistory = true; recency = .all; filters = LocalFilters(); filters.cluesOnly = false; displayLimit = 50
    }
    private func export(_ records: [AudioComment], description: String, historyBackup: Bool = false) {
        // Recheck at the export action; a screen may have crossed the source cutoff.
        let now = Date()
        let exported = historyBackup ? records : records.filter { SourcePublicationGate.sourceEligible($0, now: now) }
        guard !exported.isEmpty else { notice = UserNotice(text: "没有可导出的合格评论。"); return }
        exportFilename = historyBackup ? "后门-历史备份-非当前潜客结果" : "后门-来源分档-评论"
        document = CSVDocument(text: store.csv(records: exported))
        exportDescription = "\(description) \(exported.count) 条；意向标签待人工核实。"
        exporting = true
    }
    private func toggleFavorite(_ comment: AudioComment) {
        do { try store.preference(id: comment.id, saved: !comment.saved) }
        catch { notice = UserNotice(text: error.localizedDescription) }
    }
    private func openNote(_ comment: AudioComment) { followup = Followup(id: comment.id, note: comment.note) }
    private func openProfile(_ comment: AudioComment) { profileReview = ProfileReview(id: comment.id, comment: comment) }
    private func requestCleanup(_ records: [AudioComment], description: String) {
        guard !records.isEmpty else { notice = UserNotice(text: "没有可清理的记录。"); return }
        cleanup = CleanupRequest(ids: Set(records.map(\.id)), description: description, favorites: records.filter(\.saved).count)
    }
    private func performCleanup(_ request: CleanupRequest) {
        do {
            let count = try store.remove(ids: request.ids)
            do { try ProfileSnapshotStore.shared.prune(keeping: Set(store.comments.map(\.profileUrl))) }
            catch {
                notice = UserNotice(text: "已删除 \(count) 条评论；旧截图清理失败，截图文件仍保留。")
                cleanup = nil; return
            }
            notice = UserNotice(text: "已删除 \(count) 条本机记录。")
        } catch { notice = UserNotice(text: "清理失败，旧记录保留：" + error.localizedDescription) }
        cleanup = nil
    }
}

@MainActor
private struct CompactLeadSummary: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var snapshots = ProfileSnapshotStore.shared
    @State private var snapshot: ProfileSnapshotPresentation?
    let comment: AudioComment
    @Binding var expanded: Bool
    let onFavorite: (AudioComment) -> Void

    private var publicSummary: String {
        var values: [String] = []
        if let region = comment.region, !region.isEmpty {
            if comment.regionSource == "comment_ip" { values.append("IP 属地：" + region) }
            else if comment.regionSource == "manual_public_profile" { values.append("公开地区：" + region) }
        }
        if let age = comment.age, comment.demographicSource == "manual_public_profile" {
            values.append("公开年龄：\(age)")
        }
        return values.isEmpty ? "公开资料待核实" : values.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(comment.authorName).font(.headline).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CollectionPlatform(rawValue: comment.platform)?.title ?? "未知平台")
                Spacer(minLength: 4)
                Text(CommentRecency.displayTime(comment))
            }.font(.caption).foregroundStyle(BackdoorTheme.secondary)
            Text("来源 · " + sourcePriorityLabel(comment)).font(.caption2).foregroundStyle(BackdoorTheme.accent)
            Text(publicSummary).font(.caption).foregroundStyle(BackdoorTheme.secondary)
            Text(snapshotStatus).font(.caption2).foregroundStyle(BackdoorTheme.secondary)
            Text(comment.text).font(.subheadline).lineLimit(expanded ? nil : 3).textSelection(.enabled)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { profileLink; favoriteButton; detailButton }
                    .font(.caption)
            } else {
                HStack(spacing: 14) { profileLink; Spacer(minLength: 0); favoriteButton; detailButton }
                    .font(.caption)
            }
        }
        .sheet(item: $snapshot) { value in ProfileSnapshotSheet(value: value) }
    }
    private var snapshotStatus: String {
        if snapshots.imageURL(for: comment.profileUrl) != nil {
            return snapshots.entry(for: comment.profileUrl)?.status == "failed" ? "主页旧截图 · 最近刷新失败" : "主页截图已备好"
        }
        return snapshots.entry(for: comment.profileUrl)?.failureReason != nil ? "主页截图暂不可用 · 点击查看原因" : "主页截图待采集"
    }
    private var profileLink: some View {
        Button {
            snapshot = ProfileSnapshotPresentation(profileURL: comment.profileUrl, name: comment.authorName)
        } label: {
            Label("主页截图", systemImage: "person.crop.rectangle").frame(minHeight: 44)
        }.accessibilityLabel("查看" + comment.authorName + "的本机公开主页截图")
    }
    private var favoriteButton: some View {
        Button { onFavorite(comment) } label: {
            Label(comment.saved ? "已收藏" : "收藏", systemImage: comment.saved ? "star.fill" : "star")
                .frame(minHeight: 44)
        }.accessibilityLabel(comment.saved ? "取消收藏此线索" : "收藏此线索")
    }
    private var detailButton: some View {
        Button(expanded ? "收起" : "详情") {
            if reduceMotion { expanded.toggle() }
            else { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } }
        }.frame(minWidth: 44, minHeight: 44)
    }

}

@MainActor
private struct CommentDetails: View {
    let comment: AudioComment
    let onNote: (AudioComment) -> Void
    let onProfile: (AudioComment) -> Void
    var body: some View {
        let assessment = comment.assessment
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            if !comment.note.isEmpty { Text("备注：" + comment.note).font(.footnote) }
            Button("填写跟进备注") { onNote(comment) }.font(.caption).frame(minHeight: 44)
            if let region = comment.region, !region.isEmpty {
                if comment.regionSource == "comment_ip" {
                    Text("评论 IP 属地：" + region + "（不是居住地）").font(.caption)
                } else if comment.regionSource == "manual_public_profile" {
                    Text("主页公开地区：" + region + "（人工核实）").font(.caption)
                } else { Text("地区来源待核实").font(.caption).foregroundStyle(BackdoorTheme.secondary) }
            } else { Text("公开地区待核实").font(.caption).foregroundStyle(BackdoorTheme.secondary) }
            if let age = comment.age, comment.demographicSource == "manual_public_profile" {
                Text("主页公开年龄：\(age)（人工核实）").font(.caption)
            } else { Text("公开年龄待核实").font(.caption).foregroundStyle(BackdoorTheme.secondary) }
            Button("核实公开资料") { onProfile(comment) }.font(.caption).frame(minHeight: 44)
            if CommentStore.validLink(comment.profileUrl, profile: true), let profileURL = URL(string: comment.profileUrl) {
                Link("公开主页（外部打开）", destination: profileURL).font(.caption).frame(minHeight: 44)
            }
            if CommentStore.validLink(comment.sourceUrl, profile: false), let url = URL(string: comment.sourceUrl) {
                Link("查看原视频", destination: url).font(.caption).frame(minHeight: 44)
            }
            Text(assessment.hasClue ? assessment.labels + " · 待人工核实" : "未命中意向规则")
                .font(.caption.weight(.medium)).foregroundStyle(BackdoorTheme.accent)
            Text(assessment.explanation).font(.caption2).foregroundStyle(BackdoorTheme.secondary)
            Text("仅为文字线索，不代表真实采购意向或保证成交。").font(.caption2).foregroundStyle(BackdoorTheme.secondary)
            Group {
                Text("采集行业：" + (IndustryProfile(rawValue: comment.industry ?? "") ?? .general).title)
                Text("采集词：" + comment.product)
                Text("评论时间：" + (comment.publishedAt.isEmpty ? CommentRecency.displayTime(comment) : comment.publishedAt))
                Text("来源发布时间：" + SourcePublicationGate.displayTime(comment))
                Text("来源核实时间：" + (comment.sourceCheckedAt ?? "未知"))
                if !comment.authorId.isEmpty { Text("公开账号：" + comment.authorId) }
                if let handle = comment.publicHandle, !handle.isEmpty { Text("公开号：" + handle) }
                if comment.isReply == true { Text("评论类型：回复") }
                if let likes = comment.likeCount { Text("评论点赞：\(likes)") }
                if let replies = comment.replyCount { Text("评论回复数：\(replies)") }
                if comment.acquisition == "local_protocol_response" { Text("数据来源：本机网页已收到的公开响应") }
                Text("主页：" + comment.profileUrl)
                if !comment.sourceTitle.isEmpty { Text("视频：" + comment.sourceTitle) }
                Text("来源：" + comment.sourceUrl)
                Text("采集时间：" + comment.collectedAt)
            }.font(.caption2).foregroundStyle(BackdoorTheme.secondary).textSelection(.enabled)
        }
    }
}

@MainActor
private struct CommentCard: View {
    let comment: AudioComment
    let onFavorite: (AudioComment) -> Void
    let onNote: (AudioComment) -> Void
    let onProfile: (AudioComment) -> Void
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CompactLeadSummary(comment: comment, expanded: $expanded, onFavorite: onFavorite)
            if expanded { CommentDetails(comment: comment, onNote: onNote, onProfile: onProfile) }
        }
    }
}

@MainActor
private struct GroupedCommentsCard: View {
    let group: LeadGroup
    let onFavorite: (AudioComment) -> Void
    let onNote: (AudioComment) -> Void
    let onProfile: (AudioComment) -> Void
    @State private var expanded = false
    @State private var limit = 3
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let newest = group.comments.first {
                CompactLeadSummary(comment: newest, expanded: $expanded, onFavorite: onFavorite)
                if expanded {
                    CommentDetails(comment: newest, onNote: onNote, onProfile: onProfile)
                    Text("同一公开主页，共 \(group.comments.count) 条当前条件下的评论；按发布时间最新优先。")
                        .font(.caption2).foregroundStyle(BackdoorTheme.secondary)
                    ForEach(Array(group.comments.dropFirst().prefix(limit))) { comment in
                        Divider()
                        CommentCard(comment: comment, onFavorite: onFavorite, onNote: onNote, onProfile: onProfile)
                    }
                    if group.comments.count - 1 > limit {
                        Button("更多原评论（\(group.comments.count - 1 - limit)）") { limit += 10 }.font(.caption)
                    }
                }
            }
        }.padding(18).nightCard()
    }
}

@MainActor
private struct LocalSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LocalFilters
    @State private var history: Bool
    @State private var minimumText: String
    @State private var maximumText: String
    @State private var error: String?
    let taskKeyword: String
    let taskIndustry: IndustryProfile
    let taskPlatform: CollectionPlatform
    let totalCount: Int
    let apply: (LocalFilters, Bool) -> Void

    init(filters: LocalFilters, showHistory: Bool, taskKeyword: String, taskIndustry: IndustryProfile,
         taskPlatform: CollectionPlatform, totalCount: Int,
         apply: @escaping (LocalFilters, Bool) -> Void) {
        _draft = State(initialValue: filters); _history = State(initialValue: showHistory)
        _minimumText = State(initialValue: filters.minimumAge.map(String.init) ?? "")
        _maximumText = State(initialValue: filters.maximumAge.map(String.init) ?? "")
        self.taskKeyword = taskKeyword; self.taskIndustry = taskIndustry; self.taskPlatform = taskPlatform
        self.totalCount = totalCount; self.apply = apply
    }
    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { Text(error).foregroundStyle(BackdoorTheme.warning) }.listRowBackground(NightFormRow()) }
                Section("地区与年龄") {
                    TextField("地区，不限请留空", text: $draft.region)
                    Text("可匹配已保存的主页公开地区或评论 IP 属地；IP 属地不是居住地，结果详情会标明来源。")
                        .font(.caption).foregroundStyle(BackdoorTheme.secondary)
                    HStack {
                        TextField("最小年龄", text: $minimumText).keyboardType(.numberPad)
                        Text("—").foregroundStyle(BackdoorTheme.secondary)
                        TextField("最大年龄", text: $maximumText).keyboardType(.numberPad)
                    }
                    Toggle("包含年龄未知", isOn: $draft.includeUnknownAge)
                    Text("年龄仅来自人工核实的主页公开资料。空值表示不限，范围为 1–120；不会根据头像、昵称或评论猜测。")
                        .font(.caption).foregroundStyle(BackdoorTheme.secondary)
                }.listRowBackground(NightFormRow())
                Section("本机筛选") {
                    TextField("额外搜索昵称、评论、备注", text: $draft.query)
                    Toggle("只看收藏", isOn: $draft.savedOnly)
                    Toggle("只看意向线索（待核实）", isOn: $draft.cluesOnly)
                    Toggle("按公开主页合并", isOn: $draft.grouped)
                    Toggle("全部任务，仍限90天来源", isOn: $history)
                    Button("恢复默认筛选") {
                        draft = LocalFilters(); minimumText = ""; maximumText = ""; error = nil
                    }
                }.listRowBackground(NightFormRow())
                Section("当前范围") {
                    Text(taskKeyword.isEmpty ? "尚未提交采集任务" : "已提交：" + taskPlatform.title + " · " + taskIndustry.title + " · " + taskKeyword)
                    Text("90天合格来源共 \(totalCount) 条评论。行业只作引导，关键词可自由输入；提交前修改草稿不改变结果，评论不必包含采集词。")
                    Text("来源先找近7天，合格来源不足5个时用8–30天补充，再用31–90天兜底；各档最新优先，任务最多5个来源，非全量。再筛选评论时间、意向、地区和年龄；时间未知、未来、仅有编辑时间或超90天的来源不计入。评论时间默认全部，也可手动缩小。")
                }.font(.footnote).listRowBackground(NightFormRow())
                Section("使用说明") {
                    DisclosureGroup("平台与采集范围") {
                        Text("抖音试用适配；小红书尚未接通验收，仅供测试。来源须确认最新排序与90天内原发布时间；不能确认则暂停或跳过，不使用未知日期或超90天来源补足。每任务最多 5 个来源页，每页最多检查 200 条、保存 50 条评论，非全量；请保持前台。")
                        Text("抖音、小红书需要时请在 App 内网页本人登录、处理验证码。微信、小红书等原 App 的登录状态不会共享到本页。不会绕过登录或访问限制。")
                        Text("视频号未接通关键词查找与评论采集，能打开视频号助手不等于接通；淘宝、京东也未适配。")
                        Text("新任务重新搜索来源。旧版断点没有最新排序和来源日期证明，不会沿用旧队列；已存记录不删除。所有任务视图仍先限制90天来源，旧数据仅可从“历史备份”导出。")
                    }
                    DisclosureGroup("公开资料与隐私") {
                        Text("这些高级筛选只作用于本机资料，不会自动补全未知年龄或地区。意向标签待人工核实，不保证成交；关闭“只看意向线索”可查看普通评论。不推断身份、财富或手机号，不自动发送消息。")
                        Text("本机保存，无管理服务器，不读取其他 App 登录态、SIM、短信、通讯录。没有设备/电话卡锁，不保证防转发。")
                    }
                    DisclosureGroup("本机数据与版本") {
                        Text("记录上限 2000 条。导出、清理、平台登录在右上菜单；清理需确认，卸载可能丢失数据。评论与断点是独立原子文件，断点计数写失败可能低报新增，但已提交评论保留。")
                        Text("0.1.7 (9) · 本机协议响应优先，仍需 iPhone 真机采集验收。")
                    }
                }.font(.footnote).listRowBackground(NightFormRow())
            }
            .scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).nightScreen()
            .navigationTitle("筛选").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("应用") { applyFilters() } }
            }.tint(BackdoorTheme.accent)
        }
    }
    private func applyFilters() {
        do {
            let minimum = try checkedAge(minimumText), maximum = try checkedAge(maximumText)
            if let minimum, let maximum, minimum > maximum { throw LocalFailure.message("最小年龄不能大于最大年龄。") }
            let region = draft.region.trimmingCharacters(in: .whitespacesAndNewlines)
            guard region.count <= 40 else { throw LocalFailure.message("地区请控制在 40 字以内。") }
            draft.region = region; draft.query = draft.query.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.minimumAge = minimum; draft.maximumAge = maximum
            apply(draft, history); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private struct PublicProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var region: String
    @State private var ageText: String
    @State private var confirmed = false
    @State private var error: String?
    let comment: AudioComment
    let save: (String, Int?) throws -> Void
    init(comment: AudioComment, save: @escaping (String, Int?) throws -> Void) {
        self.comment = comment; self.save = save
        _region = State(initialValue: comment.regionSource == "manual_public_profile" ? (comment.region ?? "") : "")
        _ageText = State(initialValue: comment.demographicSource == "manual_public_profile" ? (comment.age.map(String.init) ?? "") : "")
    }
    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { Text(error).foregroundStyle(BackdoorTheme.warning) }.listRowBackground(NightFormRow()) }
                Section {
                    Text(comment.authorName)
                    if CommentStore.validLink(comment.profileUrl, profile: true), let url = URL(string: comment.profileUrl) {
                        Link("打开公开主页核实", destination: url)
                    }
                    Text("只填主页主动公开且你已核实的内容。不要根据头像、昵称、评论推断，也不要填写私下取得的信息。")
                        .font(.footnote).foregroundStyle(BackdoorTheme.secondary)
                }.listRowBackground(NightFormRow())
                Section("已核实的公开资料") {
                    TextField("主页公开地区，未公开留空", text: $region)
                    TextField("主页公开年龄，未公开留空", text: $ageText).keyboardType(.numberPad)
                    Toggle("我已核对主页公开资料", isOn: $confirmed)
                    Text("年龄只能填 1–120 或留空。同一公开主页的本机记录会一起更新；空地区清除人工资料，若原评论有 IP 属地则回落显示 IP 属地，不当作居住地。")
                        .font(.caption).foregroundStyle(BackdoorTheme.secondary)
                }.listRowBackground(NightFormRow())
            }
            .scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).nightScreen()
            .navigationTitle("核实公开资料").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { saveProfile() }.disabled(!confirmed) }
            }.tint(BackdoorTheme.accent)
        }
    }
    private func saveProfile() {
        do {
            guard confirmed else { throw LocalFailure.message("请先核对主页主动公开的资料。") }
            let value = region.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count <= 40 else { throw LocalFailure.message("地区请控制在 40 字以内。") }
            let age = try checkedAge(ageText)
            try save(value, age); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private struct FollowupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var error: String?
    let value: Followup
    let save: (String) throws -> Void
    init(value: Followup, save: @escaping (String) throws -> Void) {
        self.value = value; self.save = save; _note = State(initialValue: value.note)
    }
    var body: some View {
        NavigationStack {
            VStack {
                if let error { Text(error).foregroundStyle(BackdoorTheme.warning).font(.footnote).padding(.horizontal) }
                TextEditor(text: $note).font(.body).scrollContentBackground(.hidden)
                    .padding(12).nightCard().padding(.horizontal, 16)
                    .accessibilityLabel("跟进备注，最多1000字")
                Text("\(note.count)/1000 · 超出部分不保存")
                    .font(.caption).foregroundStyle(BackdoorTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 20)
            }.padding(.vertical, 16).nightScreen()
                .navigationTitle("跟进备注").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do { try save(String(note.prefix(1000))); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
        }
    }
}

private struct PlatformWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

@MainActor
private struct CollectorScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var collector: BrowserCollector
    @State private var opened = false
    @State private var diagnostics: DiagnosticPresentation?
    private let keyword: String
    private let recency: CommentRecency
    private let industry: IndustryProfile
    private let platform: CollectionPlatform
    private let action: BrowserAction
    private let onCompletion: (CollectionCompletion) -> Void
    private var canRestart: Bool {
        guard case .newTask = action else { return false }
        return !keyword.isEmpty && platform.canCollect
    }
    init(store: CommentStore, keyword: String, recency: CommentRecency, industry: IndustryProfile,
         platform: CollectionPlatform, action: BrowserAction,
         onCompletion: @escaping (CollectionCompletion) -> Void) {
        _collector = StateObject(wrappedValue: BrowserCollector(store: store))
        self.keyword = keyword; self.recency = recency; self.industry = industry
        self.platform = platform; self.action = action; self.onCompletion = onCompletion
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(collector.stage).font(.subheadline.weight(.semibold))
                        Spacer()
                        if collector.running {
                            Button("暂停") { collector.stop("已暂停，可继续原任务。") }.font(.caption)
                                .frame(minWidth: 44, minHeight: 44)
                        } else if collector.canResume {
                            Button("继续断点") { collector.resume() }.font(.caption)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    ProgressView(value: min(1, max(0, collector.progress))).tint(BackdoorTheme.accent)
                    // Errors and platform restrictions remain visible, never hidden in a disclosure.
                    Text(collector.status).font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("保持前台 · 仅采集已核验90天来源")
                        .font(.caption2).foregroundStyle(BackdoorTheme.secondary)
                    if !collector.running && !collector.runSummary.isEmpty {
                        Text(collector.runSummary).font(.caption2).foregroundStyle(BackdoorTheme.secondary)
                    }
                }.padding(16).nightSurface().padding(.horizontal, 12).padding(.top, 4)
                if collector.pageLoadFailed {
                    HStack {
                        Button("重新打开平台") { collector.reopenPlatform() }
                        Spacer()
                        Button("查看诊断") { diagnostics = DiagnosticPresentation(report: collector.diagnosticReport) }
                    }.font(.subheadline).padding(.horizontal, 22).padding(.vertical, 8)
                }
                PlatformWebView(webView: collector.webView)
            }.nightScreen()
            .navigationTitle("后门 · 本机采集").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回") { collector.stop(); dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("继续原断点任务") { collector.resume() }.disabled(collector.running || !collector.canResume)
                        Button(canRestart ? "重新开始当前任务" : "新任务请先在首页选择行业") {
                            collector.start(keyword: keyword, recency: recency, industry: industry, platform: platform)
                        }.disabled(collector.running || !canRestart)
                        Button("保存本页（仍需90天来源）") { collector.saveVisiblePage() }.disabled(collector.running)
                        Button("查看访问诊断") { diagnostics = DiagnosticPresentation(report: collector.diagnosticReport) }
                        ShareLink(item: collector.diagnosticReport) { Label("分享去敏诊断", systemImage: "square.and.arrow.up") }
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("采集操作与诊断") }
                }
            }
            .sheet(item: $diagnostics) { value in DiagnosticSheet(report: value.report) }
            .tint(BackdoorTheme.accent)
            .task {
                guard !opened else { return }; opened = true
                switch action {
                case .newTask: collector.start(keyword: keyword, recency: recency, industry: industry, platform: platform)
                case .resume: collector.resume()
                case .browse: collector.prepare(keyword: keyword, platform: platform)
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase != .active { collector.stop("离开前台，自动采集已暂停。返回后可继续断点。") }
            }
            .onChange(of: collector.completion?.id) { _ in
                guard let result = collector.completion else { return }
                collector.completion = nil
                onCompletion(result)
            }
            .onDisappear { collector.stop() }
        }
    }
}

@MainActor
private struct DiagnosticSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: String
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    .nightCard().padding(16)
            }.nightScreen().navigationTitle("去敏诊断").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        ShareLink(item: report) { Image(systemName: "square.and.arrow.up") }
                    }
                }
        }
    }
}


@MainActor
private struct ProfileSnapshotSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var snapshots = ProfileSnapshotStore.shared
    @State private var enlarged = false
    let value: ProfileSnapshotPresentation
    private func dateLabel(_ stamp: String?) -> String {
        guard let stamp, let date = ISO8601DateFormatter().date(from: stamp) else { return "未知" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    var body: some View {
        let entry = snapshots.entry(for: value.profileURL)
        let image = snapshots.imageURL(for: value.profileURL).flatMap { UIImage(contentsOfFile: $0.path) }
        return NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(value.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let image {
                    Text("截图于 " + dateLabel(entry?.capturedAt))
                        .font(.caption).foregroundStyle(BackdoorTheme.secondary)
                    if entry?.status == "failed" {
                        Text("正在查看旧截图。最近刷新失败：" + (entry?.failureReason ?? "未知原因"))
                            .font(.caption).foregroundStyle(BackdoorTheme.warning)
                    }
                    Button(enlarged ? "适合屏幕" : "放大查看") { enlarged.toggle() }
                        .font(.caption).frame(minHeight: 44)
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(width: enlarged ? max(geometry.size.width, image.size.width) : geometry.size.width)
                                .accessibilityLabel(value.name + "的公开主页信息区截图；截图可能已过期")
                        }
                    }.nightCard()
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                        Text("暂无可查看的主页截图").font(.headline)
                        Text(snapshots.loadError ?? entry?.failureReason ??
                             (entry?.filename != nil ? "截图文件缺失或损坏；评论仍保留。" : "该用户尚未完成主页截图。下次采集时会自动尝试。"))
                            .font(.subheadline).foregroundStyle(BackdoorTheme.secondary)
                    }.multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity).nightCard()
                    Spacer(minLength: 0)
                }
                if let checkedAt = entry?.checkedAt {
                    Text("最近检查 " + dateLabel(checkedAt)).font(.caption2).foregroundStyle(BackdoorTheme.secondary)
                }
                Text("仅本机缓存的公开主页信息区，不是实时资料；不会截图登录、私密页或账号后台。")
                    .font(.caption2).foregroundStyle(BackdoorTheme.secondary)
            }.padding(16).nightScreen()
                .navigationTitle("主页截图").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if CommentStore.validLink(value.profileURL, profile: true), let url = URL(string: value.profileURL) {
                            Menu { Link("公开主页（外部打开）", destination: url) } label: {
                                Image(systemName: "ellipsis").accessibilityLabel("其他主页操作")
                            }
                        }
                    }
                }
        }
    }
}

@MainActor
private struct CollectionResultsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CommentStore
    let completion: CollectionCompletion
    @State private var notice: UserNotice?
    @State private var followup: Followup?
    @State private var profileReview: ProfileReview?
    @State private var now = Date()
    @State private var limit = 50
    @State private var detailsExpanded = false
    init(completion: CollectionCompletion, store: CommentStore) {
        self.completion = completion; self.store = store
    }
    private var comments: [AudioComment] {
        let ids = Set(completion.commentIDs)
        let actual = store.comments.filter { ids.contains($0.id) && SourcePublicationGate.sourceEligible($0, now: now) }
        return CommentRecency.filteredAndSorted(actual, range: .all)
    }
    var body: some View {
        let actual = comments
        return NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("本次采集已结束").font(.title3.weight(.semibold))
                        Text("新增 \(completion.added) 条 · 检查 \(completion.checked) 条 · \(completion.sources) 个来源")
                            .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        Text("本次可查看 \(actual.count) 条本机实际记录 · 最新优先")
                            .font(.caption).foregroundStyle(BackdoorTheme.secondary)
                        Text("来源分档：近7天 \(actual.filter { SourcePublicationGate.sourceTier($0, now: now) == 7 }.count) 条 · 8–30天 \(actual.filter { SourcePublicationGate.sourceTier($0, now: now) == 30 }.count) 条 · 31–90天 \(actual.filter { SourcePublicationGate.sourceTier($0, now: now) == 90 }.count) 条")
                            .font(.caption2).foregroundStyle(BackdoorTheme.secondary)
                    }.padding(18).nightCard()
                    if actual.isEmpty {
                        Text("本次没有可展示的合格记录").font(.headline)
                        Text("没有结果不等于零评论；超时、访问限制和来源跳过情况见下方任务详情。已保存记录不会被虚构或替换。")
                            .font(.caption).foregroundStyle(BackdoorTheme.secondary)
                    }
                    if !completion.outcomes.isEmpty {
                        DisclosureGroup("任务详情", isExpanded: $detailsExpanded) {
                            ForEach(Array(completion.outcomes.enumerated()), id: \.offset) { _, text in
                                Text(text).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }.padding(16).nightCard()
                    }
                    ForEach(Array(actual.prefix(limit))) { comment in
                        CommentCard(comment: comment, onFavorite: toggleFavorite,
                            onNote: { followup = Followup(id: $0.id, note: $0.note) },
                            onProfile: { profileReview = ProfileReview(id: $0.id, comment: $0) })
                            .padding(18).nightCard()
                    }
                    if actual.count > limit {
                        Button("查看更多（\(actual.count - limit)）") { limit += 50 }.frame(minHeight: 44)
                    }
                    if actual.count < Set(completion.commentIDs).count {
                        Text("部分记录可能已清理或来源已超出90天；本页只显示仍合格的实际记录。")
                            .font(.caption2).foregroundStyle(BackdoorTheme.secondary)
                    }
                }.padding(16)
            }.nightScreen().navigationTitle("本次结果").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(item: $followup) { value in
                    FollowupSheet(value: value) { note in try store.preference(id: value.id, note: note) }
                }
                .sheet(item: $profileReview) { value in
                    PublicProfileSheet(comment: value.comment) { region, age in
                        try store.publicProfile(id: value.id, region: region, age: age)
                    }
                }
                .alert(item: $notice) { value in Alert(title: Text("后门"), message: Text(value.text), dismissButton: .default(Text("知道了"))) }
                .onAppear { detailsExpanded = comments.isEmpty }
                .task {
                    while !Task.isCancelled {
                        now = Date()
                        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    }
                }
        }
    }
    private func toggleFavorite(_ comment: AudioComment) {
        do { try store.preference(id: comment.id, saved: !comment.saved) }
        catch { notice = UserNotice(text: error.localizedDescription) }
    }
}
