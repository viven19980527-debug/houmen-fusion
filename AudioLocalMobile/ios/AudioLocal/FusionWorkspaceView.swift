import SwiftUI
import UniformTypeIdentifiers

/// A shared view over historical Houmen records and explicitly imported/radar records.
/// This view is intentionally NOT labelled as the original verified-90-day collection scope.
struct FusionWorkspaceView: View {
    @EnvironmentObject private var comments: CommentStore
    @EnvironmentObject private var fusion: FusionLeadStore
    @State private var query = ""
    @State private var region = ""
    @State private var platform = ""
    @State private var status = ""
    @State private var questionsOnly = false
    @State private var cluesOnly = false
    @State private var importing = false
    @State private var exportingCSV = false
    @State private var exportingJSON = false
    @State private var csvDocument = CSVDocument(text: "")
    @State private var jsonDocument = FusionJSONDocument(data: Data())
    @State private var notice: String?
    @State private var visibleLimit = 100

    private var all: [FusionLead] { fusion.allLeads(comments: comments.comments) }
    private var platforms: [String] { Array(Set(all.map(\.platform))).sorted() }
    private var rows: [FusionLead] {
        all.filter { lead in
            (platform.isEmpty || lead.platform == platform) &&
            (status.isEmpty || fusion.followup(for: lead).status.rawValue == status) &&
            (!questionsOnly || lead.isQuestion) && (!cluesOnly || lead.assessment.hasClue) &&
            (region.isEmpty || (lead.region ?? "").localizedCaseInsensitiveContains(region)) &&
            (query.isEmpty || [lead.authorName, lead.text, lead.keyword, lead.sourceTitle,
                              fusion.followup(for: lead).note].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("统一看板 · \(rows.count) / \(all.count) 条", systemImage: "tray.full.fill")
                        .font(.headline)
                    Text("包含本机历史与雷达记录，不等于已核验的90天潜客。发布时间未知的记录会明确标出；意向与提问标签需人工复核。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = fusion.loadError ?? comments.loadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                filterSection
                Section("记录") {
                    if rows.isEmpty {
                        Text("暂无匹配记录。原采集页的数据会自动显示，也可从雷达入口采集或导入已有 JSON。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(rows.prefix(visibleLimit))) { lead in
                        NavigationLink {
                            FusionLeadDetailView(lead: lead)
                        } label: {
                            FusionLeadRow(lead: lead, followup: fusion.followup(for: lead))
                        }
                    }
                    if rows.count > visibleLimit {
                        Button("继续显示（还剩 \(rows.count - visibleLimit) 条）") { visibleLimit += 100 }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(BackdoorTheme.background)
            .navigationTitle("线索工作台")
            .searchable(text: $query, prompt: "评论、昵称、关键词、备注")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { actions } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false, onCompletion: importFile)
            .fileExporter(isPresented: $exportingCSV, document: csvDocument, contentType: .commaSeparatedText,
                          defaultFilename: "后门-融合工作台-待核实") { exportFinished($0) }
            .fileExporter(isPresented: $exportingJSON, document: jsonDocument, contentType: .json,
                          defaultFilename: "后门-融合工作台-备份") { exportFinished($0) }
            .alert("工作台", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("知道了", role: .cancel) { notice = nil }
            } message: { Text(notice ?? "") }
        }
    }

    private var filterSection: some View {
        Section("本地筛选") {
            Picker("平台", selection: $platform) {
                Text("全部平台").tag("")
                ForEach(platforms, id: \.self) { key in
                    Text(all.first(where: { $0.platform == key })?.platformTitle ?? key).tag(key)
                }
            }
            Picker("跟进", selection: $status) {
                Text("全部状态").tag("")
                ForEach(FusionStatus.allCases) { value in Text(value.title).tag(value.rawValue) }
            }
            Toggle("仅看提问句", isOn: $questionsOnly)
            Toggle("仅看规则命中的意向线索", isOn: $cluesOnly)
            TextField("公开地区标签（未知不猜测）", text: $region)
            Button("重置筛选") {
                query = ""; region = ""; platform = ""; status = ""
                questionsOnly = false; cluesOnly = false; visibleLimit = 100
            }
        }
    }

    private var actions: some View {
        Menu {
            Button { importing = true } label: { Label("导入已有 JSON", systemImage: "square.and.arrow.down") }
            Button { prepareCSV() } label: { Label("导出筛选结果 CSV", systemImage: "tablecells") }.disabled(rows.isEmpty)
            Button { prepareJSON() } label: { Label("备份筛选结果 JSON", systemImage: "square.and.arrow.up") }.disabled(rows.isEmpty)
        } label: { Image(systemName: "ellipsis.circle") }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= FusionLeadStore.maximumImportBytes else { throw LocalFailure.message("文件超过5 MiB，请先分批导出。") }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: FusionLeadStore.maximumImportBytes + 1) ?? Data()
            let added = try fusion.importJSON(data: data, comments: comments.comments)
            notice = "导入完成：新增 \(added) 条。旧记录和手工跟进信息保留。\n" + fusion.lastImportWarnings.joined(separator: "\n")
        } catch { notice = "没有导入：\(error.localizedDescription)" }
    }

    private func prepareCSV() {
        csvDocument = CSVDocument(text: fusion.exportCSV(rows: rows)); exportingCSV = true
    }

    private func prepareJSON() {
        do { jsonDocument = FusionJSONDocument(data: try fusion.exportJSON(rows: rows)); exportingJSON = true }
        catch { notice = error.localizedDescription }
    }

    private func exportFinished(_ result: Result<URL, Error>) {
        switch result {
        case .success: notice = "文件已导出。文件可能包含你保存的评论及备注，请只分享给获准接收的人。"
        case .failure(let error): notice = "未导出：\(error.localizedDescription)"
        }
    }
}

private struct FusionLeadRow: View {
    let lead: FusionLead
    let followup: FusionFollowup
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(lead.authorName).font(.headline).lineLimit(1)
                Spacer()
                Text(lead.platformTitle).font(.caption).foregroundStyle(.secondary)
            }
            Text(lead.text).font(.subheadline).lineLimit(3)
            HStack {
                Text(followup.status.title)
                if lead.isQuestion { Text("提问句") }
                if lead.assessment.hasClue { Text("意向待核实") }
            }.font(.caption2).foregroundStyle(BackdoorTheme.accent)
            Text(lead.publishedAt.map { "评论发布：" + $0 } ?? "评论发布时间未知")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

struct FusionJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
