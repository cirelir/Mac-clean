# Mac Clean Foundation MVP 安全模型

本文描述当前 SwiftPM MVP 的实际边界，不描述后续签名 `.app`、privileged helper 或扩展扫描器尚未实现的能力。

## 扫描范围与信任规则

当前唯一可清理根目录是当前用户的 `~/Library/Caches`。扫描器只枚举这个根目录的直接子项；应用清单只用于把缓存目录名与已安装应用 Bundle ID 对应，并排除正在运行的应用。项目目录、用户文档、下载、照片、音乐、包管理器依赖目录和开发工具目录均不进入当前扫描范围。

路径先标准化并解析符号链接，再以 `pathComponents` 做组件级包含判断，不能用字符串前缀伪造位于允许根目录内。目标缺失、解析后越出允许根目录、等于任一允许根目录，或命中明确禁止路径时都会被拒绝。生产配置明确禁止 `/`、用户主目录和 `~/Library/Caches` 本身；执行动作只允许清空已验证候选目录的内容并保留候选根目录。

解析后越界的符号链接会在候选验证阶段被拒绝。即使符号链接仍解析在允许根目录内，应用缓存扫描器也不会把符号链接本身分类为可自动清理的绿色缓存。执行器打开候选根目录时使用 `O_NOFOLLOW`，遍历子目录时也使用 descriptor-relative `openat(..., O_NOFOLLOW)`。

绿色缓存必须有已安装应用的明确 Bundle ID 所有者，并且该 Bundle ID 不在 `NSWorkspace` 的运行应用集合中。未知所有者、未知发现类型和正在运行应用的缓存都是红色 report-only。当前实现不扫描项目目录，不根据 access time 推断未使用依赖，也没有 Homebrew、npm、pip、Cargo 或 Xcode 专用扫描器。

## 计划、身份复查与删除

扫描阶段记录候选根目录的 device ID、inode、owner ID、逻辑大小和纳秒修改时间。UI 不直接删除文件；候选项先由 `CleanupPlanner` 生成不可变计划，再交给单一 `CleanupExecutor`。自动和手动无确认清理都只把绿色且动作不是 report-only 的候选项放入计划。

执行器先重新运行路径验证，然后只按计划中的规范化路径打开候选根目录。它对已打开根目录调用 `fstat`，要求完整根 fingerprint 与扫描时一致，并把该根目录的 descriptor 作为整个树遍历的锚点。完整计划执行由 FIFO slot 串行化，避免两个清理计划在 executor 内重叠。

根目录以下的操作是 descriptor-relative 的：

1. 目录内容通过已打开 descriptor 枚举，而不是重新拼接绝对路径遍历。
2. 每个 child name 先用 `fstatat(..., AT_SYMLINK_NOFOLLOW)` 读取，不跟随符号链接，并要求仍位于根目录所在 device。
3. 子目录用 `openat(..., O_NOFOLLOW)` 打开；`fstat` 必须与打开前的 device、inode 和文件类型一致。
4. 每次删除前再次用 `fstatat(..., AT_SYMLINK_NOFOLLOW)` 比较 device、inode 和类型，然后用同一 parent descriptor 上的 `unlinkat` 删除普通项或空目录。

因此遍历绑定在已经打开的根目录对象上；扫描后把根路径替换为别处的目录或符号链接，不能把遍历重定向到允许根之外。跨 device 项、身份变化、符号链接跟随尝试和不支持的动作都会停止对应项。

## 已接受的竞态限制

上述流程不是“原子安全删除”的声明。最后一次 `fstatat` 与紧接着的 `unlinkat` 之间仍存在一个 same-parent child-name race：同一父目录中的攻击者可能在两次系统调用之间替换同名子项。当前 API 流程无法把“验证该 inode”与“只删除该 inode”合并为一个条件原子操作。

这个 MVP 限制已被明确接受：每次 `unlinkat` 前仍必须校验 device、inode 和类型；不跟随符号链接；遍历始终不能逃离已打开的根 descriptor。限制意味着同一已打开父目录内的替换项在极窄窗口中仍可能受影响，所以安全模型不能声称不存在任何 TOCTOU 风险。后续若需要更强对抗模型，必须重新设计删除原语，而不是把当前流程描述为原子操作。

## 结果、审计与通知

删除是逐项执行的，已完成的删除不会因后续项失败而回滚。只要已经删除过任何目录项后发生错误，结果就是 partial；审计 outcome 记为 failed 并保存 partial 消息，不算完整成功。

成功和 partial 返回的字节字段统一叫 `estimatedDeletedBytes`。它累计已删除普通文件的逻辑大小，可能与 APFS 实际释放空间不同；失败和跳过项贡献 0，溢出时汇总饱和为 `UInt64.max`。产品文案使用“预计”，不承诺实际回收字节。

补扫只有在扫描结果和扫描时间戳成功写入本地审计存储后才会继续。它只执行绿色计划；黄色和红色候选不执行。cleanup executor 返回的 plan ID 或候选集合若与请求不一一对应，所有计划项按协议失败审计，并且不发送虚假的成功摘要。通知只携带聚合的 `estimatedDeletedBytes` 和黄色待确认数量，不包含任何路径。通知权限被拒绝不会阻止扫描，也不会触发重复授权请求。

扫描时间、原始/规范化路径和逐项结果只保存在本地 SwiftData。当前代码没有第三方运行时依赖、遥测、云账户或网络请求。

## 当前不具备的权限与分发能力

本 slice 没有 privileged XPC Helper，也没有 Full Disk Access onboarding。权限不足会表现为扫描或清理失败，不会自动扩大权限、以管理员身份运行包管理器，或降级为 shell 命令。当前产物是 SwiftPM executable，不是已经 Developer ID 签名、公证或装入 `.dmg` 的应用包；这些属于后续可分发产品阶段。
