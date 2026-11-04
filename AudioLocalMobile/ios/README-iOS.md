# 后门融合源码 0.2.0 (10)

请以源码包根目录 `README-融合说明.md` 与本轮 `verification/` 为准。

本版新增三页入口、独立融合数据层与实验性B站适配器；原抖音/小红书采集逻辑保持。当前没有新IPA，原仓库账号暂停导致未上传/未触发云构建。

唯一当前完整验证入口：`bash AudioLocalMobile/ios/verify-fusion.sh`（从源码包根目录运行）。旧 verify-and-build/export-ipa-only 是历史脚本，不是融合版完整验收流程。

最低部署iOS16；构建使用Xcode26 SDK。Node合成/结构测试不代表Swift编译、联网采集或真机验收通过。详细实现范围、数据保护、导入限制和回滚见根说明。
