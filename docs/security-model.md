# Mac Clean Foundation MVP 安全模型

本文描述当前 SwiftPM MVP 的实际边界，不描述后续签名 `.app`、privileged helper 或扩展扫描器尚未实现的能力。

## 扫描范围与信任规则

当前可清理根目录是当前用户的 `~/Library/Caches`、`~/Library/Logs`、`~/Library/Application Support` 和 `~/Library/Developer`。缓存扫描器只枚举 Caches 根目录的直接子项；系统数据扫描器只枚举 Logs 根目录的直接子项，把目录名与已安装应用的显示名称对应为可轮转日志，并把 `DiagnosticReports` 崩溃报告作为系统数据候选；开发数据扫描器枚举 DerivedData（标记为 Xcode `com.apple.dt.Xcode` 所有）和 Developer 顶层目录；应用支持扫描器枚举 Application Support 的直接子项，跳过匹配已安装应用的目录和 `com.apple.*` 系统容器。应用清单用于把缓存/日志/支持目录名与已安装应用对应，并排除正在运行的应用。项目目录、用户文档、下载、照片、音乐和包管理器依赖目录均不进入当前扫描范围。

允许根在验证器初始化时规范化并固定为不可变的 canonical URL；配置路径的最后一个组件必须是真实目录，不能是符号链接或 Finder alias。系统路径祖先的合法 canonicalization（例如 macOS 的 `/var` 到 `/private/var`）不会因为最终根目录本身不是链接而被误拒。每次扫描前，应用缓存扫描器都会确认配置的 `~/Library/Caches` 仍解析到初始化时固定的根，并只枚举该固定 canonical 根；初始化后将配置路径替换为其他目录的链接会在枚举前 fail closed。

候选路径先标准化并解析符号链接，再以 `pathComponents` 做组件级包含判断，不能用字符串前缀伪造位于允许根目录内。目标缺失、解析后越出固定允许根、等于任一允许根目录，或命中明确禁止路径时都会被拒绝。生产配置明确禁止 `/`、用户主目录、`~/Library/Caches`、`~/Library/Logs` 和 `~/Library/Developer/Xcode/DerivedData` 本身；执行动作只允许清空已验证候选目录的内容并保留候选根目录。

解析后越界的符号链接会在候选验证阶段被拒绝。即使 direct child alias 仍解析在允许根目录内，只有原始 child 的标准化路径与验证后的 canonical 路径完全相同，扫描器才可能声明已安装应用所有权；类型也从 canonical 对象读取。扫描器在异步统计大小前后对 canonical 对象各做一次不跟随链接的完整 fingerprint，并要求完全相同后才允许产生绿色候选。稳定但未知的目录仍以红色证据报告。单个缓存子项无法验证、统计或读取指纹时（例如 macOS 对 CloudKit 等系统缓存施加的读取保护，或扫描期间子项消失），该子项被跳过且绝不会进入清理计划，其余子项继续扫描；只有根目录固定失败和 canonical 对象在统计期间被替换仍然 fail closed。执行器打开候选根目录时使用 `O_NOFOLLOW`，遍历子目录时也使用 descriptor-relative `openat(..., O_NOFOLLOW)`。

绿色缓存必须有已安装应用的明确 Bundle ID 所有者，并且该 Bundle ID 不在 `NSWorkspace` 的运行应用集合中。唯一的无所有者绿色例外是系统数据扫描器报告的崩溃报告（`~/Library/Logs/DiagnosticReports`）：它是纯诊断产物、不包含用户数据且系统可随时再生成，因此不依赖应用所有者即可作为绿色候选。无主残留（Caches 中匹配不到已安装应用的缓存目录、Application Support 中匹配不到已安装应用的数据目录、Developer 顶层目录）标记为黄色"待确认"（置信度 inferred），只在用户在详情页显式勾选确认后才进入计划并移入废纸篓；`com.apple.*` 系统容器和匹配到已安装应用的目录永不进入计划。正在运行应用的缓存仍是红色 report-only。清理流程在 planner 前重新读取一次应用清单；若绿色或已确认黄色候选项的所有者此时已经运行，该候选项不会进入计划。若最新清单读取失败，整次清理 fail closed。

## 计划、身份复查与删除

扫描阶段记录候选根目录的 device ID、inode、owner ID、逻辑大小和纳秒修改时间。UI 不直接删除文件；候选项先由 `CleanupPlanner` 生成不可变计划，再交给单一 `CleanupExecutor`。补扫和"清理安全缓存"只把绿色且动作不是 report-only 的候选项放入计划；"清理所选"额外把用户在详情页勾选确认的黄色项（`confirmedIDs`）放入计划，此时计划项携带扫描时的 `estimatedBytes`。

执行器先重新运行路径验证，然后只按计划中的规范化路径打开候选根目录。它对已打开根目录调用 `fstat`，要求根对象的 device/inode 身份与扫描时一致，并把该根目录的 descriptor 作为整个树遍历的锚点。目录自身的大小和修改时间在扫描与清理之间会因应用继续写入而变化，因此不要求完整 fingerprint 相等——对象身份相同即可继续；对象被删除并重建（inode 变化）则拒绝。完整计划执行由 FIFO slot 串行化，避免两个清理计划在 executor 内重叠。

根目录以下的操作是 descriptor-relative 的：

1. 目录内容通过已打开 descriptor 枚举，而不是重新拼接绝对路径遍历。
2. 每个 child name 先用 `fstatat(..., AT_SYMLINK_NOFOLLOW)` 读取，不跟随符号链接，并要求仍位于根目录所在 device。
3. 子目录用 `openat(..., O_NOFOLLOW)` 打开；`fstat` 必须与打开前的 device、inode 和文件类型一致。
4. 每次删除前再次用 `fstatat(..., AT_SYMLINK_NOFOLLOW)` 比较 device、inode 和类型，然后用同一 parent descriptor 上的 `unlinkat` 删除普通项或空目录。

因此遍历绑定在已经打开的根目录对象上；扫描后把根路径替换为别处的目录或符号链接，不能把遍历重定向到允许根之外。跨 device 项、身份变化、符号链接跟随尝试和不支持的动作都会停止对应项。

黄色已确认项使用 move-to-trash 动作：执行器先以与清空相同的流程验证并打开根目录（`O_NOFOLLOW`、`fstat`、fingerprint 一致），再用 `fstatat(..., AT_SYMLINK_NOFOLLOW)` 校验父目录条目仍指向同一 device/inode/类型对象，最后用 `renameat` 把整个根目录原子地移入 `~/.Trash`（同名冲突时追加时间戳后缀），删除对象可随时从废纸篓恢复；字节估算使用计划中携带的扫描时 `estimatedBytes`，与清空动作按条目累计的方式不同。move-to-trash 也支持**单个普通文件**（如偏好设置 plist、HTTPStorages 的 binarycookies）：打开根对象时先尝试 `O_DIRECTORY`，失败（ENOTDIR）再以 `O_RDONLY | O_NOFOLLOW` 打开文件并校验类型为常规文件，随后走与目录相同的父条目复核与 `trashItem`/`renameat` 流程；符号链接、别名、socket 与设备节点一律拒绝。

## 应用卸载（AppCleaner 风格）

卸载功能是独立于扫描清理的用户显式操作，使用**单独的验证器与执行器**，覆盖范围固定为用户 `~/Library` 下的数据根（Application Support、Caches、Logs、Preferences、HTTPStorages、WebKit、Saved Application State、Containers、Group Containers、Application Scripts、LaunchAgents）与应用所在目录（`/Applications`、`~/Applications`），不扩大扫描验证器的边界。

- **门禁**：只有 `/System` 下的 SIP 保护系统应用不可卸载。`com.apple.*` Bundle ID 并不等于系统应用——Xcode（`com.apple.dt.Xcode`）、Final Cut、Pages 等 Apple 用户安装应用位于 `/Applications`，与 `/Library/Input Methods` 第三方输入法一样可卸载；`/Applications` 中极少数 SIP 保护的存留应用（如 App Store）在移入废纸篓时优雅失败。验证器根目录包含 `/Applications`、`~/Applications`、`/Library/Input Methods` 与 `~/Library/Developer`。
- **运行中的应用**：计划阶段不拒绝运行中的应用；执行前 UI 通过 `NSRunningApplication.terminate` 优雅退出并**有界等待**进程退出（最多约 15 秒，绝不 force-quit，避免丢失未保存数据）；退出失败则中止本次卸载并提示用户手动退出后重试；执行器仍以 `NSWorkspace` 运行清单重新核对，进程未退出则拒绝执行，应用本体不可能从运行中的进程下被移走。
- **匹配规则**：只枚举各数据根的直接子项。先做**精确匹配**——名称与 Bundle ID 或显示名规范化后完全相等（规范化 = 小写 + 去除标点，与 `ApplicationNameMatcher` 一致）；再做**单向包含匹配**（要求完整 Bundle ID ≥ 8 字符）：Application Support / Caches / Logs 接受数据目录名是应用显示名的核心词（≥3 字符，如 `Google` 之于 Google Chrome、`Code` 之于 Visual Studio Code）或嵌入完整规范化 Bundle ID（如 `com.google.Chrome.ShipIt`）；Containers 与 Application Scripts 接受嵌入完整 Bundle ID 的**扩展容器**（FileProvider / Share / NotificationService 扩展的 bundle ID 内嵌宿主 bundle ID，如 `com.tencent.xinWeChat.WeChatFileProviderExtension`）；组容器（Group Containers）兼容 `group.` 与团队 ID 两种前缀（如 `5A4RE8SF68.com.tencent.xinWeChat`），按完整 Bundle ID 包含匹配；反向包含（应用名是数据目录名的一部分，如 `Pro` 匹配 `Profiles`）一律不允许。符号链接与 Finder alias 子项直接跳过。逐项勾选 + 确认对话框覆盖包含匹配的少量边界误报。
- **健壮性与身份**：单个数据目录无法指纹或统计大小（消失、无权限、超大）时只跳过/记 0，**不会中止整个卸载计划**；大小统计有 30 秒超时，删除动作本身不依赖大小；规划阶段对数据目录做两次指纹校验，但只比较 **device + inode 对象身份**而非完整指纹——运行中应用持续写入的目录（聊天数据库、缓存等）mtime 会变化，完整指纹比对会误跳过真实数据目录。执行阶段的 move-to-trash 同样只按对象身份复核（见上节）。
- **计划与执行**：规划阶段记录每个对象的 fingerprint 与逻辑大小（统计前后双 fingerprint，不一致则跳过）；执行阶段复用 `CleanupExecutor` 的 move-to-trash 路径，重新验证路径、按 descriptor 复核对象身份，只把项目移入废纸篓，绝不做永久删除。
- **已知限制**：vendor 式数据目录（如 Chrome 的 `Application Support/Google`）不参与自动匹配，用户需手动在 Finder 定位；组容器包含匹配理论上可能把 Bundle ID 是其子串的无关容器一并列出，逐项勾选与确认对话框可避免误删。

上述流程不是“原子安全删除”的声明。最后一次 `fstatat` 与紧接着的 `unlinkat` 之间仍存在一个 same-parent child-name race：同一父目录中的攻击者可能在两次系统调用之间替换同名子项。当前 API 流程无法把“验证该 inode”与“只删除该 inode”合并为一个条件原子操作。

这个 MVP 限制已被明确接受：每次 `unlinkat` 前仍必须校验 device、inode 和类型；不跟随符号链接；遍历始终不能逃离已打开的根 descriptor。限制意味着同一已打开父目录内的替换项在极窄窗口中仍可能受影响，所以安全模型不能声称不存在任何 TOCTOU 风险。后续若需要更强对抗模型，必须重新设计删除原语，而不是把当前流程描述为原子操作。

## 结果、审计与通知

删除是逐项执行的，已完成的删除不会因后续项失败而回滚。只要已经删除过任何目录项后发生错误，结果就是 partial；审计 outcome 记为 failed 并保存 partial 消息，不算完整成功。

成功和 partial 返回的字节字段统一叫 `estimatedDeletedBytes`。它累计已删除普通文件的逻辑大小，可能与 APFS 实际释放空间不同；失败和跳过项贡献 0，溢出时汇总饱和为 `UInt64.max`。产品文案使用“预计”，不承诺实际回收字节。

补扫只有在所有扫描器都完成、扫描结果有效且扫描时间戳成功写入本地审计存储后才会继续。任何 scanner failure 都会保留在 UI 中，但不会记录新的完成时间、不会清理或通知，因此同一计划时间仍可重试；手动扫描仍允许保存其他扫描器产生的部分结果。补扫只执行绿色计划；黄色和红色候选不执行。cleanup executor 返回的 plan ID 或候选集合若与请求不一一对应，所有计划项按协议失败审计，并且不发送虚假的成功摘要。通知只携带聚合的 `estimatedDeletedBytes` 和黄色待确认数量，不包含任何路径。通知权限被拒绝不会阻止扫描，也不会触发重复授权请求。

扫描时间、原始/规范化路径和逐项结果只保存在本地 SwiftData。当前代码没有第三方运行时依赖、遥测、云账户或网络请求。

## 当前不具备的权限与分发能力

本 slice 没有 privileged XPC Helper，也没有 Full Disk Access onboarding。权限不足会表现为扫描或清理失败，不会自动扩大权限、以管理员身份运行包管理器，或降级为 shell 命令。当前产物是 SwiftPM executable，不是已经 Developer ID 签名、公证或装入 `.dmg` 的应用包；这些属于后续可分发产品阶段。
