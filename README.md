# Mac Clean

Mac Clean 是一个面向 macOS 14 及以上系统的原生菜单栏清理工具。当前仓库提供的是可通过 Swift Package Manager 构建和运行的 Foundation MVP：它可以扫描当前用户的应用缓存、展示来源与风险依据、只清理绿色候选项、在 Finder 中定位仍存在的候选项，并把扫描和清理审计保存在本机。

这不是已经签名、可直接分发的 `.app`。当前目标是验证产品核心和清理安全边界；最终产品仍以可用 Developer ID 签名、公证并分享的 macOS 应用为目标。

## 开发环境

- macOS 14 或更高版本
- Xcode 26.4
- Swift 6.3

在仓库根目录运行：

```sh
swift test
swift build --product MacCleanApp
swift run MacCleanApp
```

`swift run MacCleanApp` 会启动菜单栏界面。它是 SwiftPM executable，不是带签名和 entitlements 的应用包；因此本 slice 不用于验证系统通知授权、完全磁盘访问、Developer ID 或公证流程。SwiftPM 进程不是 `.app` 时，通知适配器会安全地视为不可用，扫描与清理不受影响。

## 当前 MVP

- 从 `/Applications`、`/System/Applications` 和 `~/Applications` 建立已安装应用清单，并读取当前运行应用的 Bundle ID。
- 只扫描 `~/Library/Caches` 的直接子目录，不扫描用户文档、下载、照片、音乐或项目目录。
- 只有与已安装且未运行应用 Bundle ID 精确匹配的可再生缓存才成为绿色候选项；未知来源或正在运行应用的缓存只报告。
- 用户可以手动扫描和清理绿色候选项。菜单根视图出现时会根据本地最新扫描时间补做错过的每周扫描；自动流程也只执行绿色项。
- 黄色和红色项不会由补扫流程执行。通知只包含“预计清理字节数”和黄色待确认数量，不包含路径。
- 每个候选项展示原始/规范化路径、扫描器、规则、所有者、风险原因和计划动作，并根据当前文件状态启用 Finder 定位。
- 扫描时间戳和逐项清理结果通过 SwiftData 保存在本机；代码没有网络依赖，也不上传扫描数据。

清理的具体路径约束、descriptor-relative 删除流程和已知竞态限制见 [安全模型](docs/security-model.md)。所有空间数字都是逻辑大小的估算，字段名使用 `estimatedDeletedBytes`；它们不是文件系统实际回收空间的承诺。部分删除按失败/部分完成记录，不会被描述为完整成功。

## 三阶段路线图

1. **Foundation MVP（当前）**：应用清单、应用缓存扫描、风险分类、安全清理、Finder 定位、本地审计、运行期间的每周补扫，以及紧凑菜单栏/详情界面。
2. **扩展扫描器**：为 Homebrew、npm、pip、Cargo、Xcode DerivedData 和不可用模拟器增加独立、可审查的扫描器。依赖候选必须来自包管理器的权威结果；不会按最后访问时间猜测“未使用”依赖。
3. **可分发产品**：建立正式 Xcode `.app` 工程和应用包，加入明确授权的 Full Disk Access 引导、登录项与受限 XPC Helper，再完成通用归档、Hardened Runtime、Developer ID 签名、公证、staple 和 `.dmg` 制作。

第 3 阶段完成前，本仓库不声称已有 privileged helper、Full Disk Access 覆盖、后台常驻启动、签名、公证或可安装磁盘映像。
