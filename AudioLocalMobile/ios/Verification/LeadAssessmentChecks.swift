import Foundation

/// Called by LocalStoreChecks; no network, WebView, real accounts or application data are used.
enum LeadAssessmentChecks {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw LocalFailure.message("FAILED: " + label) }
            count += 1
            print("PASS: " + label)
        }
        let price = LeadAssessment.assess("请问这套线阵多少钱？")
        try check(price.signals.contains { $0.kind == .price && $0.matchedTerms.contains("多少钱") }, "price clue has literal evidence")
        try check(price.signals.contains { $0.kind == .consultation }, "multiple explainable clues")
        try check(LeadAssessment.assess("想买一套音响，哪里买").signals.contains { $0.kind == .purchase }, "purchase phrases")
        try check(LeadAssessment.assess("求租一套，能租几天").signals.contains { $0.kind == .rental }, "rental phrases")
        try check(LeadAssessment.assess("不想买，只是看看").signals.allSatisfy { $0.kind != .purchase }, "negated purchase not marked purchase")
        try check(LeadAssessment.assess("已经租了，不需要租赁").signals.allSatisfy { $0.kind != .rental }, "negated rental not marked rental")
        try check(!LeadAssessment.assess("音质不错，路过看看").hasClue, "generic praise not called a lead")
        try check(!LeadAssessment.assess("").hasClue, "empty content is not a lead")
        try check(!LeadAssessment.assess("13800000000").hasClue, "number alone does not infer intent")
        try check(LeadAssessment.assess("报价").explanation.contains("报价"), "explanation retains matched text")
        try check(LeadAssessment.disclaimer.contains("待人工确认"), "assessment is not a verified buyer claim")

        let colloquialPrices: [(String, String)] = [
            ("这套多少米", "多少米"),
            ("这一套需要多少8+4", "需要多少"),
            ("多少一套", "多少一套"),
            ("一套多钱", "一套多钱"),
            ("功放啥价", "啥价"),
            ("求价格", "求价格"),
            ("价格多少", "价格多少"),
            ("这套音响预算5000怎么配", "预算"),
            ("发一下价格表", "价格表")
        ]
        for (text, evidence) in colloquialPrices {
            try check(LeadAssessment.assess(text).signals.contains { $0.kind == .price && $0.matchedTerms.contains(evidence) },
                      "colloquial price has literal contextual evidence: " + evidence)
        }
        try check(LeadAssessment.assess("想一套音响").signals.contains { $0.kind == .purchase && $0.matchedTerms.contains("想一套") },
                  "colloquial want-a-set purchase clue")
        try check(LeadAssessment.assess("不想一套音响").signals.allSatisfy { $0.kind != .purchase }, "negated want-a-set excluded")
        for measurement in ["面积多少米", "这一套场地面积多少米", "音响覆盖多少米", "线阵吊高多少米",
                            "这套设备需要多少米线", "多少米", "需要多少", "预算"] {
            try check(LeadAssessment.assess(measurement).signals.allSatisfy { $0.kind != .price },
                      "measurement or missing context is not a price clue")
        }
        let budget = LeadAssessment.assess("这套音响预算5000")
        try check(!budget.explanation.contains("5000") && !budget.labels.contains("购买力"), "budget marker does not infer purchasing power")
        try check(LeadAssessment.assess("没有预算买这套设备").signals.allSatisfy { $0.kind != .price }, "negative budget is not a price clue")
        try check(LeadAssessment.assess("面积多少米，这套音响报价多少").signals.contains { $0.kind == .price && $0.matchedTerms.contains("报价") },
                  "explicit price remains visible alongside measurement")

        // Keywords and source metadata are explicit context, not words that the commenter
        // must repeat. Every match remains a literal fragment of this comment, not the title.
        let contextualRequests: [(String, String, IndustryProfile, LeadKind, String)] = [
            ("多少钱？", "示例音响品牌", .audio, .price, "多少钱"),
            ("怎么搭配功放？", "示例音响品牌", .audio, .consultation, "怎么搭配"),
            ("应该用什么型号？", "示例音响品牌", .audio, .consultation, "应该用什么"),
            ("多少寸合适？", "示例音响品牌", .audio, .consultation, "多少寸"),
            ("12寸还是15寸？", "示例音响品牌", .audio, .consultation, "12寸还是15寸"),
            ("求个方案", "示例音响品牌", .audio, .consultation, "求个方案"),
            ("有没有适合饭店的方案？", "示例音响品牌", .audio, .consultation, "有没有适合饭店的方案"),
            ("给我设计一套方案", "示例定制品牌", .home, .consultation, "给我设计一套方案"),
            ("窗帘用多宽？", "示例家居品牌", .home, .consultation, "用多宽"),
            ("尺码怎么选？", "示例服装品牌", .beauty, .consultation, "尺码怎么选"),
            ("选什么色号？", "示例美妆品牌", .beauty, .consultation, "选什么色号"),
            ("用哪种规格？", "示例汽车品牌", .auto, .consultation, "用哪种"),
            ("一次要多少克？", "示例食品品牌", .food, .consultation, "多少克"),
            ("需要多大功率？", "示例设备品牌", .industrial, .consultation, "多大功率"),
            ("能帮我出一份部署方案吗？", "示例软件品牌", .informationTech, .consultation, "帮我出一份部署方案"),
            ("怎么收费？", "示例保洁品牌", .residentServices, .price, "怎么收费"),
            ("怎么预约？", "示例服务品牌", .localServices, .service, "怎么预约")
        ]
        for (text, product, industry, kind, literal) in contextualRequests {
            let assessment = LeadAssessment.assess(text, product: product, sourceTitle: "合成来源标题", industry: industry)
            try check(assessment.hasClue && assessment.signals.contains { $0.kind == kind && $0.matchedTerms.contains(literal) },
                      "contextual purchase consultation without repeating keyword: " + literal)
            try check(!text.contains(product) && assessment.signals.flatMap(\.matchedTerms).allSatisfy { text.contains($0) },
                      "evidence comes only from literal comment text: " + literal)
        }
        try check(!LeadAssessment.assess("怎么搭配？").hasClue &&
                  LeadAssessment.assess("怎么搭配？", product: "任意自定义关键词").hasClue,
                  "custom keyword resolves an abbreviated question without an industry catalog restriction")
        try check(LeadAssessment.assess("多少寸？", sourceTitle: "合成设备详情").hasClue,
                  "source title alone supplies explicit item context")
        try check(LeadAssessment.assess("尺码怎么选？", industry: .beauty).hasClue,
                  "explicit selected industry supplies context without a brand inference")
        try check(!LeadAssessment.assess("普通评论", product: "多少钱", sourceTitle: "求方案", industry: .audio).hasClue,
                  "context cannot invent demand evidence missing from the comment")
        for text in ["方案", "这套方案很好", "产品参数说明", "请问，可以吗", "示例品牌", "音质不错", "专业搭配"] {
            try check(!LeadAssessment.assess(text, product: "示例品牌", sourceTitle: "怎么搭配，求方案", industry: .audio).hasClue,
                      "topic or weak question alone is not a demand clue: " + text)
        }
        for text in ["这套需要多少寸", "这套设备需要多少台", "这套需要多少瓦", "这款需要多少克"] {
            try check(LeadAssessment.assess(text, product: "示例品牌").signals.allSatisfy { $0.kind != .price },
                      "selection or quantity question does not become colloquial pricing: " + text)
        }
        for request in ["支持批发吗？拿货价多少", "方便私信我报价吗", "本店想采购一套，多少钱", "本公司想采购，怎么下单"] {
            try check(LeadAssessment.assess(request, product: "示例品牌").hasClue,
                      "buyer wholesale, quote reply and business context do not imply seller promotion: " + request)
        }
        let nonDemand = [
            "多少钱？厂家直销，欢迎咨询", "不知道怎么搭配？私信我，免费出方案", "源头厂家，报价优惠，支持批发",
            "提供上门服务，怎么预约看主页", "这套报价1000", "价格表在主页", "不需要报价", "别问多少钱",
            "不关心多少钱", "不需要方案", "不想要方案", "不想买，只是问多少寸", "随便问问怎么搭配",
            "怎么搭配，已经解决了", "多少钱？已经解决了", "求个方案，已经选好了", "想买一套，现在不用了",
            "想买，但是不买了", "多少钱，已解决，不过音质不错", "不知道怎么搭配？私信我", "支持批发，批发价私聊",
            "有人问多少钱", "客户问怎么搭配", "他说想买一套", "转述：该用什么型号", "报价教程",
            "教你怎么搭配", "今天分享多少寸的选择", "“多少钱”是常见问句", "引用「求个方案」", "\"怎么搭配\"", "‘想买一套’"
        ]
        for text in nonDemand {
            try check(!LeadAssessment.assess(text, product: "示例品牌", sourceTitle: "合成视频", industry: .audio).hasClue,
                      "advertisement, withdrawn, resolved or reported clue is suppressed: " + text)
        }
        try check(LeadAssessment.assess("已经解决了，不过我还需要一份搭配方案", product: "示例品牌").hasClue,
                  "explicit renewed request can coexist with a resolved earlier need")
        let mixedReport = LeadAssessment.assess("朋友问多少钱，我想买一套", product: "示例品牌")
        try check(mixedReport.signals.contains { $0.kind == .purchase } && mixedReport.signals.allSatisfy { $0.kind != .price },
                  "reported clause does not suppress a distinct first-person request or leak quoted pricing")
        let noAmounts = LeadAssessment.assess("预算5000，这套设备怎么搭配", product: "示例品牌")
        try check(noAmounts.hasClue && !noAmounts.explanation.contains("5000") && !noAmounts.labels.contains("购买力"),
                  "contextual request keeps only literal demand fragments, not a wealth estimate")
        let contextualComment = AudioComment(id: "context", commentId: "context", platform: "douyin", product: "示例品牌",
            text: "怎么搭配？", authorName: "合成公开昵称", authorId: "", profileUrl: "https://www.douyin.com/user/fixture_context",
            publishedAt: "", sourceUrl: "https://www.douyin.com/video/1234567890123456789", sourceTitle: "合成详情",
            collectedAt: "2026-10-25T00:00:00Z", saved: false, note: "", industry: "audio")
        try check(contextualComment.assessment.hasClue && contextualComment.assessment.signals.contains { $0.matchedTerms.contains("怎么搭配") },
                  "AudioComment computed assessment passes stored keyword, source and industry context")
        try check(LeadFiltering.filter([contextualComment], query: "", savedOnly: false, cluesOnly: true).count == 1,
                  "clue-only filter retains contextual request even when comment omits brand keyword")

        func fixture(_ id: String, _ profile: String, platform: String = "douyin", name: String = "同名账号") -> AudioComment {
            AudioComment(id: id, commentId: id, platform: platform, product: "线阵音响", text: "想买一套，多少钱",
                         authorName: name, authorId: "", profileUrl: profile, publishedAt: "",
                         sourceUrl: "https://www.douyin.com/video/1234567890123456789", sourceTitle: "",
                         collectedAt: "2026-10-25T00:00:00Z", saved: false, note: "")
        }
        let a = fixture("1", "https://www.douyin.com/user/SameUser?from=video")
        let b = fixture("2", "https://douyin.com/user/SameUser/")
        let c = fixture("3", "https://www.douyin.com/user/OtherUser")
        let grouped = LeadGrouping.groups([a, b, c])
        try check(grouped.count == 2 && grouped[0].comments.count == 2, "canonical public profile merges query and trailing slash")
        try check(grouped[0].comments.map(\.id) == ["1", "2"], "group keeps every source comment in order")
        try check(grouped[1].comments[0].id == "3", "same nickname on different profiles never merges")
        let otherPlatform = fixture("4", a.profileUrl, platform: "different")
        try check(LeadGrouping.groups([a, otherPlatform]).count == 2, "platform identity boundary")
        try check(LeadGrouping.groups([fixture("5", ""), fixture("6", "")]).count == 2, "missing profiles remain separate")
        try check(LeadGrouping.groups([a, fixture("7", "https://www.douyin.com/user/sameuser")]).count == 2, "profile path case is not guessed")
        try check(LeadGrouping.groups([fixture("8", "https://www.douyin.com.evil.invalid/user/SameUser"), a]).count == 2, "lookalike host never merges")
        try check(a.assessment.hasClue && grouped[0].clueCount == 2, "computed assessment preserves Codable schema")
        var favorite = a
        favorite.saved = true
        favorite.note = "Follow up in showroom"
        let neutral = AudioComment(id: "neutral", commentId: "neutral", platform: "douyin", product: "线阵音响",
                                   text: "路过看看", authorName: "普通公开账号", authorId: "", profileUrl: c.profileUrl,
                                   publishedAt: "", sourceUrl: c.sourceUrl, sourceTitle: "", collectedAt: c.collectedAt,
                                   saved: false, note: "")
        let records = [favorite, b, neutral]
        try check(LeadFiltering.filter(records, query: "", savedOnly: false, cluesOnly: false).count == 3, "default filter keeps all comments")
        try check(LeadFiltering.filter(records, query: "", savedOnly: false, cluesOnly: true).count == 2, "clue filter does not include generic text")
        try check(LeadFiltering.filter(records, query: "", savedOnly: true, cluesOnly: false).map(\.id) == [a.id], "saved filter")
        try check(LeadFiltering.filter(records, query: "SHOWROOM", savedOnly: true, cluesOnly: true).map(\.id) == [a.id], "filters combine with case insensitive notes")
        try check(LeadFiltering.filter(records, query: "no matching term", savedOnly: false, cluesOnly: false).isEmpty, "unmatched local query does not launch collection")
        try check(LeadAssessment.assess("窗帘怎么收费").signals.contains { $0.kind == .price }, "non-audio product pricing")
        try check(LeadAssessment.assess("这款茶叶想下单").signals.contains { $0.kind == .purchase }, "non-audio purchase")
        try check(LeadAssessment.assess("需要上门清洗，怎么预约").signals.contains { $0.kind == .service }, "generic service appointment")
        try check(LeadAssessment.assess("不需要上门服务").signals.allSatisfy { $0.kind != .service }, "negated service excluded")
        try check(LeadAssessment.assess("这个产品多少米").signals.contains { $0.kind == .price }, "context rules do not require audio category")
        try check(LeadAssessment.assess("这个窗帘长度多少米").signals.allSatisfy { $0.kind != .price }, "generic product measurement excluded")
        try check(!LeadAssessment.assess("请问，可以吗").hasClue, "generic questions alone are not potential customers")
        try check(LeadAssessment.assess("求推荐一款适合家用的").hasClue, "explicit selection request is a reviewable clue")
        try check(IndustryProfile.allCases.count == 28 && IndustryProfile.general.suggestedKeywords.isEmpty,
                  "industry is selectable and custom keywords remain unrestricted")
        try check(IndustryProfile.audio.suggestedKeywords.contains("线阵音响") &&
                  IndustryProfile.localServices.suggestedKeywords.contains("上门保洁"),
                  "industry-specific suggestions cover products and services")
        return count
    }
}
