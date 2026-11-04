import SwiftUI

struct FusionLeadDetailView: View {
    @EnvironmentObject private var fusion: FusionLeadStore
    let lead: FusionLead
    @State private var status: FusionStatus = .pending
    @State private var note = ""
    @State private var notice: String?

    var body: some View {
        Form {
            Section("原始内容") {
                LabeledContent("平台", value: lead.platformTitle)
                Text(lead.authorName).font(.headline)
                Text(lead.text).textSelection(.enabled)
                if !lead.sourceTitle.isEmpty { Text(lead.sourceTitle).font(.caption).foregroundStyle(.secondary) }
                if !lead.keyword.isEmpty { LabeledContent("采集关键词", value: lead.keyword) }
                Text(lead.assessment.explanation).font(.caption)
                Text(LeadAssessment.disclaimer).font(.caption2).foregroundStyle(.secondary)
            }
            Section("来源与时间") {
                if let url = lead.sourceLink { Link("查看原内容", destination: url) }
                if let url = lead.profileLink { Link("查看公开主页", destination: url) }
                LabeledContent("评论发布", value: lead.publishedAt ?? "未知")
                LabeledContent("原内容发布", value: lead.sourcePublishedAt ?? "未知；未获90天来源认证")
                LabeledContent("采集/导入", value: lead.collectedAt)
                LabeledContent("公开地区", value: lead.region ?? "未知")
                Text("来自：\(lead.origin)。不会通过头像、昵称推断年龄、所在地或私人联系方式。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("手工跟进") {
                Picker("状态", selection: $status) {
                    ForEach(FusionStatus.allCases) { value in Text(value.title).tag(value) }
                }
                TextEditor(text: $note).frame(minHeight: 110)
                    .accessibilityLabel("跟进备注")
                Text("\(note.count)/1000 字。请勿保存密码、验证码或未经许可的私人信息。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("保存跟进", action: save).disabled(note.count > 1000)
            }
            Section {
                Text("状态由你手动标记；本应用不会自动拨号、群发私信或添加联系人。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden).background(BackdoorTheme.background)
        .navigationTitle("线索详情").navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .alert("跟进记录", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("知道了", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func load() {
        let existing = fusion.followup(for: lead); status = existing.status; note = existing.note
    }
    private func save() {
        do { try fusion.update(id: lead.id, status: status, note: note); notice = "已保存，仅保存在本机。" }
        catch { notice = "未保存：\(error.localizedDescription)" }
    }
}
