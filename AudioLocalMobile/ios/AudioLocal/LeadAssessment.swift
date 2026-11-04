import Foundation

/// User-chosen search context, not an inferred industry or a restriction on custom keywords.
enum IndustryProfile: String, CaseIterable, Codable, Identifiable {
    case audio, home, beauty, auto, food, localServices, industrial, agriculture, mining, manufacturing, utilities, construction, wholesaleRetail, transport, hospitality, informationTech, finance, realEstate, businessServices, scienceTech, environment, residentServices, education, healthcare, cultureSports, publicServices, internationalOrganizations, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audio: return "影音设备"
        case .home: return "家居家装"
        case .beauty: return "服饰美妆"
        case .auto: return "汽车用品"
        case .food: return "食品饮品"
        case .localServices: return "本地服务"
        case .industrial: return "工业设备"
        case .agriculture: return "农林牧渔"
        case .mining: return "采矿与矿业服务"
        case .manufacturing: return "制造业"
        case .utilities: return "能源与公用事业"
        case .construction: return "建筑工程"
        case .wholesaleRetail: return "批发零售"
        case .transport: return "交通运输与仓储物流"
        case .hospitality: return "住宿餐饮"
        case .informationTech: return "信息技术与互联网"
        case .finance: return "金融与保险"
        case .realEstate: return "房地产与物业"
        case .businessServices: return "租赁与商务服务"
        case .scienceTech: return "科研与技术服务"
        case .environment: return "水利环境与公共设施"
        case .residentServices: return "居民服务与维修"
        case .education: return "教育培训"
        case .healthcare: return "卫生健康与社会工作"
        case .cultureSports: return "文化体育与娱乐"
        case .publicServices: return "公共管理与社会组织"
        case .internationalOrganizations: return "国际组织与涉外服务"
        case .general: return "其他/自定义"
        }
    }
    var suggestedKeywords: [String] {
        switch self {
        case .audio: return ["专业音响", "线阵音响", "无线话筒"]
        case .home: return ["窗帘定制", "全屋定制", "装修"]
        case .beauty: return ["护肤", "服装定制", "美妆"]
        case .auto: return ["汽车用品", "汽车贴膜", "汽车改装"]
        case .food: return ["咖啡豆", "茶叶", "食品批发"]
        case .localServices: return ["上门保洁", "家电维修", "摄影服务"]
        case .industrial: return ["机械设备", "五金工具", "自动化设备"]
        case .agriculture: return ["农业设备", "农产品", "园林养护"]
        case .mining: return ["矿山设备", "矿业服务", "采矿机械"]
        case .manufacturing: return ["产品加工", "代工生产", "包装定制"]
        case .utilities: return ["新能源设备", "供水设备", "节能改造"]
        case .construction: return ["建筑材料", "工程施工", "钢结构"]
        case .wholesaleRetail: return ["批发拿货", "实体零售", "货源"]
        case .transport: return ["货运物流", "仓储服务", "冷链运输"]
        case .hospitality: return ["民宿", "餐饮设备", "餐饮加盟"]
        case .informationTech: return ["软件开发", "网站建设", "信息系统"]
        case .finance: return ["企业财务服务", "保险咨询", "金融科技"]
        case .realEstate: return ["物业管理", "商铺租赁", "房屋装修"]
        case .businessServices: return ["设备租赁", "企业服务", "会展服务"]
        case .scienceTech: return ["检测服务", "工业设计", "技术咨询"]
        case .environment: return ["环保设备", "污水处理", "景观工程"]
        case .residentServices: return ["家政服务", "家电维修", "便民服务"]
        case .education: return ["职业培训", "技能学习", "教学设备"]
        case .healthcare: return ["养老服务", "健康管理", "医疗设备"]
        case .cultureSports: return ["体育用品", "演出设备", "文化活动"]
        case .publicServices: return ["公共设施", "社区服务", "公益活动"]
        case .internationalOrganizations: return ["涉外服务", "国际会展", "跨境服务"]
        case .general: return []
        }
    }
}

enum LeadKind: String, CaseIterable, Identifiable {
    case price = "询价"
    case purchase = "采购"
    case rental = "租赁"
    case consultation = "咨询"
    case service = "预约服务"
    var id: String { rawValue }
}

struct LeadSignal: Identifiable, Equatable {
    let kind: LeadKind
    let matchedTerms: [String]
    var id: String { kind.rawValue }
    var explanation: String { "命中：" + matchedTerms.map { "“\($0)”" }.joined(separator: "、") }
}

/// Explicit source context may resolve an abbreviated question. It never supplies a demand
/// phrase, identifies a person, estimates purchasing power or confirms that someone is a buyer.
struct LeadAssessment: Equatable {
    let signals: [LeadSignal]
    private static let weakConsultationTerms: Set<String> = ["请问", "咨询", "怎么接", "如何接", "求教", "有没有", "能不能", "可以吗"]
    var hasClue: Bool {
        signals.contains { signal in
            signal.kind != .consultation ||
                signal.matchedTerms.contains { !Self.weakConsultationTerms.contains($0) }
        }
    }
    var labels: String { signals.map { $0.kind.rawValue }.joined(separator: " / ") }
    var explanation: String {
        signals.isEmpty ? "未命中本机规则；不代表没有需求" :
            signals.map { "\($0.kind.rawValue)：\($0.matchedTerms.joined(separator: "、"))" }.joined(separator: "；")
    }
    static let disclaimer = "结合来源上下文，按评论原文规则标记，待人工确认；不等于真实采购意向。"

    private static func contains(_ text: String, any terms: [String]) -> Bool {
        terms.contains { text.range(of: $0, options: [.caseInsensitive, .widthInsensitive]) != nil }
    }

    /// Mask quoted examples while keeping every remaining evidence fragment literal.
    /// An unclosed quotation is deliberately not interpreted as the commenter's own request.
    private static func withoutQuotations(_ text: String) -> String {
        let pairs: [Character: Character] = ["“": "”", "‘": "’", "「": "」", "『": "』", "\"": "\"", "`": "`"]
        var closing: Character?, output = ""
        for character in text {
            if let end = closing {
                output.append(character == "\n" ? "\n" : " ")
                if character == end { closing = nil }
            } else if let end = pairs[character] {
                closing = end; output.append(" ")
            } else { output.append(character) }
        }
        return output
    }

    /// Old assess(text) calls remain valid. Context is the user's keyword, this source's title
    /// and the explicitly selected industry; no brand lookup or inferred user attributes occur.
    static func assess(_ text: String, product: String = "", sourceTitle: String = "",
                       industry: IndustryProfile = .general) -> LeadAssessment {
        let body = withoutQuotations(String(text.prefix(6000)))
        let hasSourceContext = industry != .general ||
            !product.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let itemTerms = ["这个", "这款", "这套", "那套", "一套", "整套", "套装", "产品", "商品", "设备", "服务", "项目", "价格", "价钱"]
        let hasCommentContext = contains(body, any: itemTerms)
        let hasContext = hasSourceContext || hasCommentContext
        // A seller advertisement may contain a buyer-style question as its headline.
        // Suppress the entire ad rather than interpreting its question as a customer request.
        let promotion = ["厂家直销", "工厂直销", "源头厂家", "厂家供货", "现货供应", "大量现货",
                         "欢迎咨询", "欢迎询价", "欢迎问价", "欢迎下单", "私信报价", "私聊报价", "加我报价",
                         "联系我报价", "报价请私信", "报价私信", "找我拿货", "找我购买", "下单找我", "需要的联系", "需要的私信",
                         "需要的找我", "有需要联系我", "有需要找我", "有需要私信", "加微咨询",
                         "免费提供方案", "免费出方案", "本店供应", "本店主营", "本公司主营", "本厂直供", "我这有货", "我有货",
                         "我这里卖", "提供上门服务", "专业提供", "承接各类", "专业承接", "报价教程"]
        let standaloneSalesCTA = body.range(of: #"(?:^|[，,。;；！？?!\n])\s*(?:私信我|联系我|加我|找我)(?:[，,。;；！？?!\s]|$)"#, options: .regularExpression) != nil
        let wholesaleStatement = body.components(separatedBy: CharacterSet(charactersIn: "，,。;；！？?!\n"))
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "支持批发" }
        if contains(body, any: promotion) || standaloneSalesCTA || wholesaleStatement { return LeadAssessment(signals: []) }
        let reported = ["有人问", "别人问", "大家都问", "客户问", "买家问", "粉丝问", "朋友问", "老板问",
                        "他说", "她说", "有人说", "视频说", "原文说", "评论里说", "转述", "转发", "引用",
                        "教你", "教大家", "告诉大家", "今天分享", "分享一下", "本期介绍", "给大家讲", "演示一下"]
        let resolved = ["已经解决", "已解决", "解决了", "已经选好", "已选好", "已经配好", "已经搭配好",
                        "已经买好", "买好了", "已下单", "已经下单", "不用了", "不需要了", "不要了",
                        "不买了", "也不买", "都不买", "不想买", "不打算买", "无需采购", "不采购",
                        "只是看看", "随便问问", "纯属好奇", "只是好奇", "不用推荐", "不必推荐", "无需推荐", "不用方案"]
        let renewedRequest = ["但是", "不过", "还想", "还要", "还需要", "另外", "仍然", "现在想", "现在需要"]
        // Keep only an explicitly renewed request AFTER the last resolution/withdrawal.
        // An earlier "但是" cannot revive "想买，但是不买了" or an already resolved price question.
        var activeBody = body
        var lastResolutionEnd: String.Index?
        for term in resolved {
            if let range = body.range(of: term, options: [.backwards, .caseInsensitive, .widthInsensitive]),
               lastResolutionEnd == nil || range.upperBound > lastResolutionEnd! {
                lastResolutionEnd = range.upperBound
            }
        }
        if let end = lastResolutionEnd {
            let suffix = String(body[end...])
            guard contains(suffix, any: renewedRequest) else { return LeadAssessment(signals: []) }
            activeBody = suffix
        }
        let measurements = ["面积", "平方", "平米", "距离", "间距", "线长", "长度", "宽度", "高度", "多少米线",
                            "多少米长", "多少米远", "米外", "米内", "米高", "米宽", "米深", "长多少", "高多少",
                            "宽多少", "多长", "多高", "多宽", "覆盖", "传输", "吊高", "尺寸", "英寸", "寸",
                            "功率", "瓦", "匹", "流量", "尺码", "色号"]
        let buyingQuestions = ["怎么搭配", "如何搭配", "怎样搭配", "怎么配", "如何配", "怎样配", "咋配", "配什么",
                               "搭配什么", "该用什么", "应该用什么", "用什么型号", "选什么型号", "哪个型号合适",
                               "什么型号合适", "选哪款", "买哪款", "选哪种", "用哪种", "选哪个好", "怎么选型", "如何选型",
                               "求配置", "推荐个配置", "什么配置", "需要什么配置", "需要多大", "多大合适", "多大够用",
                               "多少寸", "几寸", "选多大", "用多大", "选多宽", "用多宽", "需要多宽", "要多宽",
                               "要多长", "需要多长", "多少匹", "多少升", "多少克", "多少斤", "多少公斤", "多大功率", "功率多大",
                               "尺寸多少", "多大尺寸", "尺寸怎么选", "要多少瓦", "多少瓦合适", "规格怎么选", "什么规格",
                               "用什么规格", "哪个尺码", "什么尺码", "尺码怎么选", "尺码怎么挑", "选什么色号", "用什么色号",
                               "选哪个色号", "要多大流量", "要多少吨", "多少吨合适", "怎么定制", "如何定制",
                               "怎么做方案", "如何做方案", "方案怎么做", "方案怎么选", "求方案", "求个方案", "求一份方案",
                               "求搭配方案", "需要方案", "需要个方案", "需要一份方案", "想要方案", "想要个方案",
                               "给个方案", "给一份方案", "适合什么方案", "有没有方案", "有没有合适的方案", "能出方案吗"]
        let contextualPatterns = [
            #"(?:请|麻烦|能否|能不能|帮我|帮忙|给我).{0,6}(?:推荐|搭配|配置|出|设计).{0,8}方案"#,
            #"(?:有没有|有什么|需要|求|想要).{0,10}方案"#,
            #"(?:什么|哪种|哪套|哪个).{0,6}方案(?:合适|适合|好|可用)"#,
            #"\d+(?:\.\d+)?\s*(?:英寸|寸|匹|升|千瓦|瓦|kw|w|吨|号|码|厘米|毫米|cm|mm)\s*(?:还是|或)\s*\d+(?:\.\d+)?\s*(?:英寸|寸|匹|升|千瓦|瓦|kw|w|吨|号|码|厘米|毫米|cm|mm)"#
        ]
        var matches: [LeadKind: [String]] = [:]
        func append(_ evidence: String, kind: LeadKind) {
            if !(matches[kind] ?? []).contains(evidence) { matches[kind, default: []].append(evidence) }
        }
        let sentences = activeBody.components(separatedBy: CharacterSet(charactersIn: "。！？!?;；\n\r"))
        for sentence in sentences {
            for clause in sentence.components(separatedBy: CharacterSet(charactersIn: "，,")) {
                guard !contains(clause, any: reported) else { continue }
                var priceTerms = ["多少钱", "什么价", "价格多少", "报价", "怎么卖", "最低价", "价格呢", "问价",
                                  "多少一套", "一套多钱", "啥价", "求价格", "价格表", "收费多少", "怎么收费", "费用多少",
                                  "多少钱一", "拿货价", "批发价", "能便宜点吗", "能优惠吗"]
                // Colloquial money/measurement ambiguity still needs context in the comment,
                // not merely a brand keyword. Never extract a budget amount or estimate wealth.
                let quantityQuestion = body.range(of: #"需要多少\s*(?:升|吨|件|个|台|只|套|箱|公斤|斤|克|人|天)"#, options: .regularExpression) != nil
                if hasCommentContext && !contains(body, any: measurements) && !quantityQuestion { priceTerms += ["多少米", "需要多少"] }
                if hasCommentContext && !contains(clause, any: ["没有预算", "没预算", "无预算"]) { priceTerms.append("预算") }
                let consultationTerms = ["请问", "咨询", "求推荐", "怎么选", "如何选", "怎么接", "如何接", "求教", "有没有", "能不能", "可以吗"] + (hasContext ? buyingQuestions : [])
                let rules: [(LeadKind, [String], [String])] = [
                    (.price, priceTerms, ["不问价", "不问价格", "不需要报价", "不要报价", "不用报价", "无需报价", "不是问价",
                        "别问多少钱", "别再问多少钱", "不要问多少钱", "不问多少钱", "不用问多少钱", "别问价格", "不需要价格表",
                        "价格表在主页", "价格表见主页", "报价已发", "已经报价", "不关心", "不想知道", "不需要知道", "没兴趣", "没问"]),
                    (.purchase, ["想买", "要买", "求购", "采购", "订购", "怎么买", "哪里买", "哪里有卖", "需要一套", "想要一套", "想一套", "买一套", "想下单", "怎么下单", "想拿货", "我要订货", "起订量"],
                        ["不买", "不想买", "不要买", "不需要", "已经买", "买过了", "无需采购", "不采购", "不打算买", "不订购", "不想一套", "没想买"]),
                    (.rental, ["求租", "想租", "租一套", "租用", "租赁", "出租吗", "能租", "可以租", "租一天", "租几天"],
                        ["不租", "不想租", "不用租", "无需租", "不需要租", "不提供租", "已经租"]),
                    (.service, ["想预约", "怎么预约", "可以预约", "需要上门", "上门服务", "预约咨询", "想定制"],
                        ["不预约", "不想预约", "不用上门", "不需要上门", "不想定制"]),
                    (.consultation, consultationTerms, ["不咨询", "不用推荐", "不要推荐", "无需推荐", "不需要方案", "不要方案",
                        "不用方案", "无需方案", "不想要", "不想", "不用做方案", "不需要做方案",
                        "不问", "没问", "不关心", "不考虑", "别问", "不用搭配", "不需要搭配"])
                ]
                for (kind, terms, exclusions) in rules {
                    guard !contains(clause, any: exclusions) else { continue }
                    // A numerical quote from a seller is not itself an inquiry. A separate
                    // explicit question still matches its own phrase below/in another clause.
                    let priceStatement = kind == .price && clause.range(of: #"报价\s*(?:是|为|:|：)?\s*\d"#, options: .regularExpression) != nil &&
                        !contains(clause, any: ["多少", "什么价", "问价", "求价格", "能便宜", "能优惠", "吗", "怎么"])
                    if priceStatement { continue }
                    for term in terms {
                        if let range = clause.range(of: term, options: [.caseInsensitive, .widthInsensitive]) {
                            append(String(clause[range]), kind: kind)
                        }
                    }
                    if kind == .consultation && hasContext {
                        for pattern in contextualPatterns {
                            if let range = clause.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                                append(String(clause[range]), kind: kind)
                            }
                        }
                    }
                }
            }
        }
        let signals = LeadKind.allCases.compactMap { kind -> LeadSignal? in
            guard let terms = matches[kind], !terms.isEmpty else { return nil }
            return LeadSignal(kind: kind, matchedTerms: terms)
        }
        return LeadAssessment(signals: signals)
    }
}

extension AudioComment {
    var assessment: LeadAssessment {
        LeadAssessment.assess(text, product: product, sourceTitle: sourceTitle,
                              industry: industry.flatMap(IndustryProfile.init(rawValue:)) ?? .general)
    }
}

struct LeadGroup: Identifiable {
    let id: String
    let comments: [AudioComment]
    var authorName: String { comments.first?.authorName ?? "未命名公开账号" }
    var clueCount: Int { comments.filter { $0.assessment.hasClue }.count }
}

/// Only the same public profile path within a platform is merged. A nickname is never an identity key.
enum LeadGrouping {
    static func profileKey(platform: String, profileURL: String, fallbackID: String) -> String {
        if platform == CollectionPlatform.xiaohongshu.rawValue,
           CollectionPlatform.profilePlatform(profileURL) == .xiaohongshu,
           let identity = CollectionPlatform.profileIdentity(profileURL) {
            return platform + "|" + identity
        }
        guard let c = URLComponents(string: profileURL), c.scheme == "https",
              c.user == nil, c.password == nil, c.port == nil || c.port == 443,
              ["www.douyin.com", "douyin.com"].contains(c.host ?? ""),
              c.path.range(of: "^/user/[A-Za-z0-9_.-]{4,200}/?$", options: .regularExpression) != nil else {
            return platform + "|unmerged|" + fallbackID
        }
        let path = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        return platform + "|" + path
    }

    static func key(for comment: AudioComment) -> String {
        profileKey(platform: comment.platform, profileURL: comment.profileUrl, fallbackID: comment.id)
    }

    static func groups(_ comments: [AudioComment]) -> [LeadGroup] {
        var order: [String] = []
        var grouped: [String: [AudioComment]] = [:]
        for comment in comments {
            let key = key(for: comment)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(comment)
        }
        return order.map { LeadGroup(id: $0, comments: grouped[$0] ?? []) }
    }
}


enum LeadFiltering {
    static func filter(_ comments: [AudioComment], query: String, savedOnly: Bool, cluesOnly: Bool) -> [AudioComment] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return comments.filter { c in
            (!savedOnly || c.saved) && (!cluesOnly || c.assessment.hasClue) &&
                (term.isEmpty || [c.authorName, c.authorId, c.text, c.product, c.note, c.sourceTitle]
                    .joined(separator: "\n").localizedCaseInsensitiveContains(term))
        }.sorted {
            $0.collectedAt == $1.collectedAt ? $0.id < $1.id : $0.collectedAt > $1.collectedAt
        }
    }
}
