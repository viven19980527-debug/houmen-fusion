# 后门 × 获客雷达：融合源码 0.2.0 (10)

## 交付状态（2026-11-05）

这是源码合并包，不是已完成编译/签名的安装包。原 GitHub 账号在只读检查时返回 HTTP 403 / “Sorry. Your account was suspended”；未上传本次源码，未触发新云构建，未消耗本次构建额度。Codemagic 元数据可访问不等于编译成功。

本轮 Node 测试结果见 `verification/final-node-tests.json`，其中包含合成 DOM 与静态源码断言。新增 Swift fixtures 已写入，但 Windows 上未执行原生 Swift 测试、Xcode 编译、模拟器或 iPhone 验收。B站接口与新增手动搜索入口未完成在线兼容性验收。

## 已接入源码

| 入口/能力 | 合并方式 | 边界 |
|---|---|---|
| 精细采集 | 保留后门原抖音/小红书流程、来源发布时间核验、暂停/续采、公开主页功能 | 原有90天来源规则不放宽，不承诺全量或真机接通 |
| 获客雷达 | 新增B站公开评论适配器、关键词与20/50/100条预算 | 实验性；最多10视频、每视频有限首批评论；请求间隔至少700ms；拒绝/限流即停 |
| 手动多平台搜索 | B站、微博、快手通过系统浏览器视图打开搜索 | 仅浏览，不伪称已自动采集；不共享旧采集器Cookie |
| 线索工作台 | 原后门历史只读投影 + 新雷达/导入记录 | “历史”不等于90天合格潜客；未知发布时间显式保留未知 |
| 筛选与跟进 | 平台、文字、公开地区标签、提问句、既有保守意向规则、人工状态与备注 | 提问/规则命中不等于已确认意向；地区标签不代表居住地 |
| 数据交换 | LeadRadar旧JSON数组或融合JSON导入；筛选结果CSV/JSON导出 | 单批5000条/5 MiB，来源/字段校验整批拒绝，CSV防公式注入 |

未合并：自动私人联系方式抽取、头像OCR取联系方式、自动联系/群发、按昵称跨平台拼人，以及把时间未知写成“刚发布”的逻辑。原 LeadRadar 的整套网页采集状态机没有覆盖后门采集器。

## 数据与升级

- App 名仍为“后门”，Bundle ID `cn.shengxun.local`；原图标保持。
- 原文件 `Application Support/ShengxunLocal/comments.json` 不由融合模块改写。
- 新数据独立存于 `Application Support/ShengxunLocal/fusion-leads-v1.json`，原子写入、iOS文件保护、排除系统备份。损坏时显示错误并禁止覆盖，不静默清空。
- 原备注/收藏作为默认值保留；新的人工跟进独立保存，收藏不转换为购买意向。重复导入不覆盖已有手工状态。
- 使用“平台 + 原来源 + 评论ID”去重；缺少评论ID时依据公开主页和评论原文，不按昵称合并。无可靠身份或来源的旧记录不会被伪造补齐。
- JSON备份保存的是当前筛选结果，不是自动全库备份。极旧的无有效来源/身份/时间记录可以显示，但严格导出可能拒绝；先用原页面的导出保留原始数据。
- 导出文件含用户保存的评论及备注，不再受App文件保护，请妥善保管。卸载或更改签名身份可能丢数据，先分别导出原采集数据和融合数据。

## 构建

Windows可执行（源码包根目录）：

```powershell
npm --prefix AudioLocalMobile ci --ignore-scripts --no-audit --no-fund
npm --prefix AudioLocalMobile test
node AudioLocalMobile/tools/build-ios-protocol.mjs --check
```

Mac需完整Xcode及Node/npm，已有界面包含受系统版本保护的iOS26 API，因此使用Xcode26 SDK；最低部署iOS16。实际新编译结果仍待验证：

```bash
bash AudioLocalMobile/ios/verify-fusion.sh
```

脚本依次校验身份/资源、安装锁定依赖、运行Node测试、执行旧与新Foundation fixtures，再编译iPhoneOS arm64。任一步失败即终止并记录真实退出码；只有构建成功才生成 `AudioLocalMobile/ios/build/HoumenFusion-unsigned.ipa`。可选 `FUSION_BUILD_SIMULATOR=1` 增加模拟器编译，仍不等于UI或真实平台测试。

`codemagic.yaml` 保留原工作流ID `audio-local-ios`，改为上述完整检查入口。不使用旧的 export-only 流程；旧构建脚本仅为历史兼容保留，旧测试结果没有放入本交付包。恢复原GitHub账号后，或用户另行授权正常可用的源仓库后，再上传本源码并运行。包内没有云密钥、Git凭据、签名证书或设备数据。

## 来源与回滚

- 基线：后门 `houmen-ios-v0.1.7-source.zip`；没有修改原ZIP或原IPA。
- 雷达参考：本机LeadRadar源码提交 `ad74465` 的公开评论接口流程；用户提供的 `LeadRadar-v2.6-signed.ipa` 只做静态检查，没有执行、注入、改包或复用签名。文件名v2.6与包内1.0/build1不一致，不能把当前源码提交声称为该IPA的可重现来源。
- 具体输入哈希、每文件哈希、保留基线文件比对见 `source-manifest.json`；测试及云阻断见 `verification/`。
- 若尚未安装融合版，原App不受影响；停止使用此源码即可回滚。若后续安装测试，先导出融合数据，再用原签名身份安装已保留的原后门版本，不先卸载、不覆盖原数据文件。不同签名身份的数据继承不能保证。

## 待验收

1. 在可用Mac构建环境执行全部Swift fixtures与Xcode编译，解决实际编译错误后才能称为可安装产物。
2. 用户自行签名，在测试iPhone上验证原数据仍在、三页入口、导入/重复导入、跟进保存/重启、筛选导出、取消任务。
3. 用户主动小批验证平台接口；认证、拒绝或限流时停止，不绕过。验证完成前不把实验性B站能力描述为稳定可用。
