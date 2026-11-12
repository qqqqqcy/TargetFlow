# 测试清单与执行时机

本文按当前仓库中的测试源文件、共享 Xcode Scheme、脚本、Git hooks 和 GitHub Actions 配置梳理。数量为静态定义的测试方法数，不是最近一次运行的通过数；参数化循环不额外计数。原有 UI 测试目标及其 3 个模板测试已经删除。

## 总览

| 测试层 | 文件数 | 方法数 | 执行入口 | 当前自动执行情况 |
| --- | ---: | ---: | --- | --- |
| Swift XCTest：DayflowTests | 57 | 506 | scripts/test.sh、Xcode Test 或 xcodebuild test | 已准备 GitHub Actions 工作流，发布后生效；脚本负责本次测试数据清理 |
| Python unittest：回放脚本安全测试 | 2 | 21 | 直接运行测试文件或 unittest discovery | 测试工作流会执行；不属于 Xcode Scheme |
| 真实录屏回放 | 不计入上述数量 | 无固定 XCTest 用例数 | scripts/replay-recording.sh | 手动启动；不是固定断言的自动测试套件 |
| 发布产物校验 | 不计入上述数量 | 不适用 | scripts/package-test.sh、release.yml | main 推送或手动运行发布 workflow 时执行 |

当前合计 59 个测试源文件、527 个测试方法（Swift 506，Python 21）。

## 测试来源：上游 Dayflow 与 Target Flow 新增

本仓库从 Dayflow 分叉，分叉点之前的最后一个上游提交为 730d6f84（2026-10-22）。按 `git log --diff-filter=A` 统计首个引入提交：

| 来源 | 文件数 | 方法数 | 说明 |
| --- | ---: | ---: | --- |
| 上游 Dayflow 引入、仍保留 | 15 单元 | 165 | 上游原有 157；fork 后增至 165 |
| 上游引入、随功能删除 | 11（均为单元） | 已删除 | 见下表 |
| Target Flow 新增 | 44（42 单元 + 2 Python） | 362（341 Swift + 21 Python） | fork 后的目标、事件、连续覆盖、并行、回放等 |

上游保留的 15 个文件：

| 文件 | 当前方法数 | fork 后是否改动 |
| --- | ---: | --- |
| ClaudeActivityCardBoundaryTests.swift | 35 | 改写 6 处断言与提示词规则 |
| ClaudeCLIExecutionProfileTests.swift | 14 | 增加 1 项显式 effort 覆盖 |
| ClaudeTranscriptionInputBuilderTests.swift | 6 | 未改动 |
| CodexClaudeProviderTests.swift | 18 | 删除 8 项遥测测试，收紧 3 项断言，新增 2 项 |
| CodexExecutableResolverTests.swift | 6 | 未改动 |
| DaySummaryLoadTokenTests.swift | 3 | 未改动 |
| GeminiAPIHelperTests.swift | 4 | 未改动 |
| LLMProviderRoutingTests.swift | 32 | 删除 3 项主备测试，新增 5 项连接/托管归一化 |
| LocalizationTests.swift | 12 | 新增语言选项与中英文资源测试 |
| OpenAICompatibleConfigurationTests.swift | 5 | 未改动 |
| OpenAICompatibleProviderTests.swift | 8 | 新增 5 项单步时间线与黑帧测试 |
| ProviderPromptPreferencesTests.swift | 11 | 新增 5 项共享偏好与迁移测试 |
| ProvidersSettingsViewModelTests.swift | 6 | 按新的连接编辑器重写 4 项 |
| TimeParsingTests.swift | 2 | 未改动 |
| TimelineActivityLoaderTests.swift | 3 | 未改动 |

随功能一起删除的上游测试文件：

| 删除的文件 | 对应已移除功能 |
| --- | --- |
| AgentClientRegistrationTests.swift | Agent/MCP 注册 |
| AgentPlaybackUsageTests.swift | Agent 用量回放 |
| AgentUsageTelemetryQueueTests.swift | 遥测队列 |
| AgentWriteHandlersTests.swift | Agent 写入接口 |
| ChatReplyStateTests.swift | 对话界面 |
| ChatStreamingRegressionTests.swift | 流式对话 |
| DailyRecapAttemptBudgetTests.swift | 每日回顾 |
| FlowWaitlistRegistrationTests.swift | 候补名单 |
| GeminiDashboardModelFallbackTests.swift | 仪表盘模型回退 |
| SupportChatContextTests.swift | 支持对话 |
| WeeklyDashboardBuilderTests.swift | 周报面板 |

## 冗余评估

**结论：当前没有发现“功能已删除、测试仍残留”的陈旧测试。** 证据：

1. 删除功能时同步删除了 11 个对应测试文件，`Dayflow/DayflowTests` 中不再出现 chat、dashboard、weekly、waitlist、recap 等测试类型。
2. 全仓唯一提及这些名称的测试是 RetiredFeatureConfigurationTests，它专门断言已退役路由被忽略，属于退役保护而非残留。
3. 保留的 15 个上游单元测试文件均指向仍在使用的能力：AI 连接与路由、CLI 调用、OCR 输入、时间线加载、时间解析、本地化。未发现针对不可达代码的测试。

需要区分看待的两类情况：

- **有意保留的兼容性测试。** LLMProviderRoutingTests 中 4 项 hosted 归一化测试对应一条旧配置迁移路径：设置界面的“添加供应商”只剩订阅 CLI、API/代理和本地服务，hosted 已不能新建，但旧配置仍会被读取。这类测试保护迁移，不属于冗余；若确认永久不再读旧托管配置，可合并为 1 项迁移测试。
- **同一不变量的分层覆盖。** 例如短切换吸收同时由 TimelineStabilizationTests（纯策略函数）和 ContinuousEventCoverageTests（数据库与发布链路）验证；凌晨 4 点边界出现在 11 个文件中，但分属时间线策略、批处理、pending、来源轮转、视图缩放等不同场景。抽查确认它们不是复制粘贴的重复断言，而是同一规则的多个入口。维护成本体现在修改规则时要同步多处 fixture，而不是测试跑两遍同一代码。

可选的精简候选（收益有限，需先确认产品仍不需要旧托管配置）：

| 候选 | 位置 | 判断 |
| --- | --- | --- |
| hosted 归一化 4 项 | LLMProviderRoutingTests | 合并为 1 项迁移测试 |
| visible-black-visible 两组 | ActivityBoundaryTests 与 ActivityPipelineRegressionTests | 前者测重写跨度与前置上下文，后者测落库与类别归一化；可保留但宜注明分工 |
| 遥测相关残留 | 已删除 | 无需处理 |

## 实测耗时与两层划分建议

一次本地运行 `-only-testing:DayflowTests`：505 项全部通过，无失败、无跳过。以下耗时仅供参考，测试数量已随后增加。

| 指标 | 实测 |
| --- | --- |
| 冷缓存首次（含测试 target 编译） | 约 3–4 分钟 |
| 热缓存全量 505 项墙钟 | 22 秒 |
| Python 21 项墙钟 | 0.48 秒（用例 0.39 秒） |
| 用例耗时合计（并行） | 34.5 秒 |
| 最慢单个用例 | 13.0 秒（NotchNotificationTests 的真实等待） |
| 调用真实模型或真实网络的用例 | 0 项 |

最慢的测试类：

| 类 | 用例数 | 耗时 | 原因 |
| --- | ---: | ---: | --- |
| NotchNotificationTests | 10 | 14.6s | 一项真实等待 13 秒的上屏时长断言 |
| DayTimelineZoomTests | 19 | 8.3s | 真实 AppKit/SwiftUI 窗口与手势事件 |
| UnchangedInactivityEvidenceTests | 11 | 5.7s | 图像像素相似度计算 |
| AnalysisSchedulingTests | 12 | 1.5s | 异步调度与退避 |
| OpenAICompatibleProviderTests | 8 | 1.1s | 合成图片与时间线校验 |

其余 50 个测试类合计不足 3 秒。

### 关于“快测 / 合并前”两分法

方向合理，但按当前数据，“耗时”不是这个仓库的主要矛盾：

1. 全量 Swift 测试 22 秒即可跑完，拆分两套清单的收益有限。
2. 没有任何 XCTest 调用真实模型，“消耗 token”的测试在现有套件中不存在。唯一使用真实模型的是 scripts/replay-recording.sh 手动回放，它不是固定断言。
3. 冷缓存编译约需 3–4 分钟，是测试之外的主要固定成本；发布流程另有签名步骤。
4. 真正有风险的是依赖图形会话的 3 个类（NotchNotificationTests、DayTimelineZoomTests、LocalizationTests 的 Bundle 读取），它们在无桌面的 CI runner 上不稳定，而不是“慢”。

建议改成按依赖划分，而不是按时长划分：

| 层 | 内容 | 耗时 | 何时运行 |
| --- | --- | --- | --- |
| 1 快速门禁 | DayflowTests 全量 | 22s（热） | 每次改动、每个 PR 推送 |
| 1b 可选更快的子集 | 排除 NotchNotificationTests、DayTimelineZoomTests、UnchangedInactivityEvidenceTests | 约 8s | 本地保存即跑 |
| 2 合并前 | DayflowTests 全量 + 21 项 Python | Swift 22s + Python 0.5s | 合并到 main 前 |
| 3 本地人工（不入 CI 门槛） | replay-recording.sh 真实模型回放 | 分钟级，消耗 token | 改动分析链路后的自查 |

第 3 层不进仓库 CI 还有隐私原因：AGENTS.md 规定真实录屏、截图、模型请求和响应不得公开，因此回放使用的实机数据不能作为 CI fixture；用合成数据又无法反映真实模型表现。

### UI 测试的历史尝试与删除决定

历史尝试：2026-11-11 两次运行 UI 测试均未完成：禁用签名时 Runner 被系统终止（Test crashed with signal kill before establishing connection）；使用 ad-hoc 签名时启用自动化模式超时（Timed out while enabling automation mode）。两条失败信息已记录，未测得耗时。

原 UI target 及其 3 个模板测试已删除。它们没有核心业务交互断言。

## 什么时候会执行

完整 Scheme Test 只纳入 DayflowTests。

| 操作 | Swift 506 项 | Python 21 项 | 其他验证 |
| --- | --- | --- | --- |
| Xcode 对 Dayflow Scheme 执行完整 Test（⌘U） | 默认纳入 | 不执行 | 测试选择/过滤可以缩小范围 |
| xcodebuild -scheme Dayflow … test，无测试过滤 | 默认纳入 | 不执行 | 先构建测试目标，再运行 |
| bash scripts/test.sh | 执行 | 不执行 | 清理本次注册的隔离数据和偏好；可进一步筛选测试类或方法 |
| 普通 Xcode Build/Run、xcodebuild build | 不执行 | 不执行 | 只构建/启动，不等于运行测试 |
| scripts/run-local.sh，包括 --build-only | 不执行 | 不执行 | Debug 构建、签名验证；默认还会安装并启动应用 |
| scripts/package-test.sh | 不执行 | 不执行 | Release 构建、签名及身份检查、DMG 校验、SHA-256 生成 |
| scripts/release_dmg.sh | 不执行 | 不执行 | 构建、签名、公证及打包流程 |
| scripts/replay-recording.sh | 不执行 | 不执行 | 默认构建独立回放应用并启动回放；--skip-build 跳过构建，--view-only 只查看 |
| 手动运行 Python 测试文件/discovery | 不执行 | 执行选定文件或全部 | 临时目录和合成数据 |
| 创建或更新目标为 main 的 PR | 执行 | 执行 | 测试工作流运行；分支保护需单独配置 |
| 推送 main | 执行 | 执行 | 测试与发布 workflow 各自触发，发布不等待测试 |
| 创建提交或推送非 main 分支（不涉及 PR） | 不自动执行 | 不自动执行 | 未发现有效测试 hooks |
| workflow_dispatch 手动启动发布 workflow | 不执行 | 不执行 | 仅触发发布流程 |

证据入口：

- [共享 Dayflow Scheme](../Dayflow/Dayflow.xcodeproj/xcshareddata/xcschemes/Dayflow.xcscheme)：DayflowTests 的 skipped=NO、parallelizable=YES；TestAction 为 Debug，设置 TARGETFLOW_TEST_MODE=1。
- [发布 workflow](../.github/workflows/release.yml)：只有 main push 和 workflow_dispatch 触发，无 pull_request 触发；运行 package-test.sh，未调用测试命令。
- [README 中的单元测试命令](../README.zh-CN.md)：通过 scripts/test.sh 运行 DayflowTests 并清理本次隔离数据。
- 项目使用文件系统同步测试目录，未配置额外的测试 build phase 或独立 .xctestplan。当前本地 hooks 目录仅有 .sample 文件，没有有效的 pre-commit/pre-push 测试入口。

## Swift 测试完整清单

下表文件均位于 Dayflow/DayflowTests。它们共用同一 target，不会根据修改的功能自动选择执行；完整运行 DayflowTests 时会纳入全部测试，除非显式过滤或命中条件跳过。

### 录屏、采样和分析调度：7 文件，52 方法

| 文件 | 方法数 | 主要覆盖 |
| --- | ---: | --- |
| AnalysisIntervalTests.swift | 5 | 分析间隔偏好、范围与时长规则 |
| AnalysisSchedulingTests.swift | 12 | 分析任务调度、暂停及恢复、并发与积压处理 |
| RecordingEvidenceTests.swift | 5 | 录屏证据、隐私占位与证据元数据 |
| TimelineCaptureRunTests.swift | 8 | 录制会话边界、连续来源与会话恢复 |
| TimelineSegmentRotationTests.swift | 5 | 录屏分段、帧索引及跨段连续性 |
| InactivityPreferencesTests.swift | 6 | 无活动阈值及相关偏好 |
| UnchangedInactivityEvidenceTests.swift | 11 | 画面未变、无活动证据及事件输出约束 |

### 事件生成、连续覆盖和写入恢复：15 文件，159 方法

| 文件 | 方法数 | 主要覆盖 |
| --- | ---: | --- |
| ActivityBoundaryTests.swift | 13 | 活动时间边界、间隙与重叠 |
| ActivityPipelineRegressionTests.swift | 11 | 活动处理链路回归、边界及保真 |
| ClaudeActivityCardBoundaryTests.swift | 35 | 卡片输出边界、时间修复、细节和中断保留 |
| ContinuousEventCoverageTests.swift | 3 | 连续录屏的事件覆盖及短切换保留 |
| MinimumEventDurationTests.swift | 15 | 稳定窗口、短片段暂存、跨批次处理与测试状态清理 |
| ParallelTimelineGenerationTests.swift | 4 | 并行时间线生成与任务互不阻塞 |
| PendingRetryStateTests.swift | 4 | 待重试状态、可重试判定及状态转换 |
| PolicyCorrectionRegressionTests.swift | 5 | 闲置阈值、事件成员关系、历史评估持久化及提醒时效回归 |
| SameLabelSingleEventTests.swift | 19 | 同事件标签合并、细节保留与硬边界 |
| TimelineCategoryWriteTests.swift | 9 | 事件标签归一化、未知标签与写入一致性 |
| TimelineFailure1937Tests.swift | 6 | 历史失败场景的时间线处理回归 |
| TimelineRetryRecoveryTests.swift | 8 | 分析失败、手动重试及恢复 |
| TimelineRewriteSnapshotTests.swift | 16 | 重写快照、并发改动冲突及事务保护 |
| TimelineStabilizationTests.swift | 9 | 事件稳定、短切换吸收及覆盖连续性 |
| TimeParsingTests.swift | 2 | 时间字符串解析 |

### AI 配置、发现与路由：11 文件，114 方法

| 文件 | 方法数 | 主要覆盖 |
| --- | ---: | --- |
| AIConfigurationTests.swift | 17 | 连接、模型、功能分配、迁移与配置验证 |
| AIConfigurationValidatorTests.swift | 8 | 能力验证、失败结果与错误信息脱敏 |
| AIConfiguredRuntimeTests.swift | 8 | 根据配置选择运行时、失败和回退 |
| AIProviderDiscoveryTests.swift | 11 | 模型列表发现、服务地址、响应和错误处理 |
| AIRequestContextTests.swift | 3 | 请求上下文与功能/模型关联 |
| CLIModelConfigurationTests.swift | 2 | CLI 模型配置 |
| LLMProviderRoutingTests.swift | 32 | 供应商路由、旧偏好迁移、端点和密钥规则 |
| ModelPreferencesTests.swift | 11 | 模型选择与推理参数偏好 |
| OpenAICompatibleConfigurationTests.swift | 5 | OpenAI 兼容端点、请求和运行时配置 |
| ProviderPromptPreferencesTests.swift | 11 | 共享提示词、自定义覆盖及旧偏好迁移 |
| ProvidersSettingsViewModelTests.swift | 6 | 供应商设置状态和偏好读取 |

### 供应商适配、CLI、输入和用量：9 文件，76 方法

| 文件 | 方法数 | 主要覆盖 |
| --- | ---: | --- |
| ChatCLIProcessRunnerTests.swift | 6 | CLI 配置错误识别、隔离回退环境及合成凭证文件复制 |
| ClaudeCLIExecutionProfileTests.swift | 14 | Claude 执行配置、工具权限、输入限制和参数 |
| ClaudeTranscriptionInputBuilderTests.swift | 6 | 帧采样、OCR 请求配置、输入构造与识别失败 |
| CodexClaudeProviderTests.swift | 18 | 两种 CLI 的提示词、命令参数和响应解析 |
| CodexExecutableResolverTests.swift | 6 | CLI 路径、能力探测及替身解析行为 |
| GeminiAPIHelperTests.swift | 4 | Gemini 请求/响应辅助处理 |
| OpenAICompatibleProviderTests.swift | 8 | 单步图像时间线、输出封装、校验和错误路径 |
| LLMUsageReceiptTests.swift | 9 | 用量、成本与供应商元数据解析 |
| ModelExecutionHistoryTests.swift | 5 | 模型/推理元数据、并发有界历史、脱敏及 shell 参数转义 |

### 事件目标与提醒：6 文件，50 方法

| 文件 | 方法数 | 主要覆盖 |
| --- | ---: | --- |
| EventEnabledTests.swift | 4 | 事件启停与评估联动 |
| EventGoalTests.swift | 10 | 当前目标、事件分组和专注判定 |
| TargetEvaluationTests.swift | 10 | 目标评估、历史快照、保存与失败处理 |
| TargetNotificationPreferencesTests.swift | 4 | 提醒偏好及持久化 |
| PauseRecordingReminderTests.swift | 12 | 暂停录屏提醒、周期、取消与恢复 |
| NotchNotificationTests.swift | 10 | 刘海提醒内容、尺寸与展示行为 |

### 界面状态、本地化和加载：6 文件，45 方法

| 文件 | 方法数 | 主要覆盖 |
| --- | ---: | --- |
| DaySummaryLoadTokenTests.swift | 3 | 日期加载令牌与过期结果保护 |
| DayTimelineZoomTests.swift | 19 | 时间线缩放、滚动、坐标及可视范围 |
| LocalizationTests.swift | 12 | 语言偏好、资源、权限文案和输出语言 |
| SpinnerLifecycleTests.swift | 5 | 评估队列清空、缓存复用、目标关闭及提醒重试的加载状态 |
| TimelineActivityLoaderTests.swift | 3 | 时间线活动读取及失败处理 |
| TimelineGenerationStatusTests.swift | 3 | 生成状态及界面状态转换 |

### 隔离、产品范围和退役配置：3 文件，10 方法

| 文件 | 方法数 | 主要覆盖 |
| --- | ---: | --- |
| TestIsolationTests.swift | 6 | 独立数据/偏好/凭证、路径及符号链接保护、外部媒体保护 |
| TargetFlowScopeTests.swift | 2 | 导航范围及独立存储路径 |
| RetiredFeatureConfigurationTests.swift | 2 | 已退役功能的配置范围 |

## Python 测试的实际内容

### scripts/test_recording_replay_snapshot.py：7 方法

- 复制媒体、筛选帧、保留隐私标记，清空旧分析输出，源数据库和偏好不被改动。
- 拒绝正式数据重叠路径、符号链接别名与已有输出目录。
- 缺失媒体时拒绝创建有效快照。
- 生成 ID 命名空间覆盖原本为空的表。
- 使用已保存快照的媒体、当前偏好以及全新分析输出重跑。
- 搬迁副本时保留输出、重写安全媒体路径并核对媒体一致性。
- 时间窗口必须带时区且按有效顺序给出。

### scripts/test_recording_replay_import.py：14 方法

- 导入后保留输出、引用、原始模型文本和日志；保留源目录；重复导入幂等并能修复审计附件。
- 经审计的失败批次导入后仍保留失败状态。
- ID 冲突时整笔事务回滚。
- 帧时间、索引、隐私标记及活动状态必须匹配。
- 媒体内容不同则拒绝导入。
- 报告必须完成且 manifest 摘要匹配。
- 拒绝窗口外输出和不安全的生成媒体路径。
- 目标缺失对应帧则拒绝。
- 目标已有重叠分析批次则拒绝。
- 目标窗口必须覆盖源窗口。
- 拒绝可能篡改输出的数据库 trigger。
- 源目标表结构必须一致。
- 拒绝正式数据目录及重叠源目标目录。
- 在线备份能读取已提交 WAL 数据，且不改动源文件。

这些测试使用临时 SQLite、合成媒体字节和合成偏好；不会启动原生应用或调用模型。

## 运行条件与隔离

- 原生测试需要完整 Xcode。项目的测试部署要求为 macOS 15.1；应用本身为 macOS 14。
- 部分 DayflowTests 同样依赖图形会话：NotchNotificationTests 直接读取 NSScreen.main，无屏幕时会断言失败而非跳过；时间线缩放用例会创建 AppKit/SwiftUI 窗口并路由事件。不能将整个 DayflowTests 当作无桌面依赖的测试。
- DayflowTests 没有独立的 XCTest measure 性能基准；其中一项刘海提醒生命周期用例会明确等待 13 秒。
- DayflowTests 包含纯函数测试，也包含数据库、AppKit、图像/视频文件、异步调度和持久化等组件测试，不都是无文件系统依赖的纯逻辑测试。
- AI 请求相关测试使用注入闭包、测试响应或 URLProtocol 等替身，不等于实际服务、登录状态或真实模型质量验证。
- ModelExecutionHistoryTests 中有一项实际运行 /bin/sh 来核对参数转义；它不调用真实模型。CLI 配置与能力测试也不代表真实 CLI 已登录且可用。
- Scheme 设置 TARGETFLOW_TEST_MODE=1。AppStoragePaths 还识别 XCTest 宿主，使用独立临时数据目录、独立偏好和隔离凭证路径。AppDelegate 在隔离模式不会走正常自动录屏及后台启动流程。
- MinimumEventDurationTests.testPendingDoesNotContinueAcrossKnownCurrentSessionStart 的动态时间样例如跨越凌晨 4 点，会 XCTSkip。静态方法数不意味着每轮都执行并通过 506 项。
- 本轮删除线修复执行过 Debug 构建和 Swift 合成编译验证，尚无新增 XCTest 自动 UI 回归用例。

## 手动执行命令

以下命令从仓库根目录运行。

运行 Swift 单元/组件测试，入口会隔离并清理本次测试数据：

```bash
bash scripts/test.sh
```

运行单个测试类（示例）：

```bash
bash scripts/test.sh -only-testing:DayflowTests/TimelineRewriteSnapshotTests
```

直接在 Xcode 或使用 `xcodebuild test` 运行仍使用独立测试数据，但不会经过脚本的退出清理。

运行全部 Python 用例：

```bash
python3 -m unittest discover -s scripts -p 'test_*.py' -v
```

单独运行一个 Python 测试文件：

```bash
python3 scripts/test_recording_replay_snapshot.py
python3 scripts/test_recording_replay_import.py
```

真实录屏回放通过 scripts/replay-recording.sh 手动指定时间窗口或已准备的隔离快照。它可以使用当前模型配置生成 report.json、卡片和评估结果，适合排查模型输出与录屏链路；不是以上 527 项中的自动断言。--view-only 仅查看，--retry-batch 针对已有失败批次重试，--from-snapshot 用已保存媒体启动新的分析运行。

## 当前缺口

1. 合并前必需检查需要在 GitHub 分支保护中配置；工作流文件本身不提供强制限制。
2. main 发布流水线没有以 Swift 或 Python 测试通过为前提。
3. package-test.sh 的名称容易误解；实际动作是构建并验证安装包，不运行 XCTest。
4. 核心业务交互及正文显示缺少自动 UI 回归覆盖。
5. 手动回放能检验真实模型表现，但未形成固定样例、明确断言和持续运行入口。
