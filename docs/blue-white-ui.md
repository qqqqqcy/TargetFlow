# 蓝白界面重构与验证

基线提交：`ee1884aa`。界面开发与独立预览在 `target-flow-blue-ui` 工作目录完成；本阶段改动整理为 checkpoint 后合回 `target-flow`。未推送或安装覆盖 `/Applications/TargetFlow.app`。

## 视觉与功能范围

共享主题采用 `#2869EF` 蓝色导航与主操作、`#F6F8FB` 浅灰画布、白色内容面板和细浅色分隔线，并提供对应深色配色。设置、事件与目标、详情及提供商配置使用相同的控件与系统字体。现有系统／浅色／深色偏好在设置页可切换。

保持时间线日／周、事件筛选与详情、录屏回放、多个当前目标及其评估、提醒样式与声音、提供商、用量费用、隐私与存储功能。没有恢复日报、聊天或 Agents 入口，也没有将设计稿示例写入应用数据。

主时间线的事件与目标管理入口已合并，仅保留当前目标横条右侧的「事件与目标」按钮。摘要中的铅笔按钮用于独立的专注／分心统计分类，辅助标签明确其用途。

原始设计参考已复制到 `build/design-reference/target-flow-modern-preview.png` 和 `build/design-reference/target-flow-modern-preview.html`。`build/` 受仓库忽略规则保护，参考文件、构建产物、数据副本及运行截图均不进入源码提交。

## 独立 UI 预览

Debug 构建支持 `TARGETFLOW_UI_PREVIEW_DATA_DIR`，用于读取真实数据库的独立副本。这个模式要求：

- 应用标识以 `local.targetflow.preview.` 开头，例如 `local.targetflow.preview.blue`；正式标识 `local.targetflow.app` 搭配此环境变量会被拒绝。
- 预览 bundle 必须带此环境变量启动；缺少变量时会由 precondition 拒绝启动，避免意外访问正式数据目录。
- 环境变量指向绝对路径，且不能是正式数据目录、它的子目录或父目录。
- 使用 SQLite backup 取得一致的 `chunks.sqlite` 副本，不复制正在使用中的数据库单文件来冒充一致快照。
- 将偏好导入独立预览应用的 defaults 域。独立 bundle id 隔离读写；不能把 `setVolatileDomain` 当作正式偏好的写保护。

当前副本位于 `build/verification/runtime/`，其中 `preferences.plist` 来自真实偏好。预览初始化仅在独立域设置 `didOnboard=true`、`isRecording=false` 和显示 Dock 图标；语言使用 `-AppleLanguages` 和 `-AppleLocale` 命令行参数。日常预览不传 `-dayflowAppearance`，使设置页的外观切换正常生效；固定外观参数仅适用于无需交互切换的单次截图。

预览构建继续使用与正常构建相同的固定证书和完整签名，只通过构建参数覆盖 `PRODUCT_BUNDLE_IDENTIFIER`。最终正常产物保存在 `build/verified/TargetFlow.app`，独立预览产物保存在 `build/preview/TargetFlow.app`；`build/local/` 是复用的中间构建目录，可能包含预览标识的产物，不能据路径假定其为正式应用标识。启动独立预览产物时传入环境变量，例如：

```bash
open -n \
  --env "TARGETFLOW_UI_PREVIEW_DATA_DIR=$PWD/build/verification/runtime" \
  "$PWD/build/preview/TargetFlow.app" \
  --args -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
```

预览不创建录屏器，不启动自动时间线分析、通知服务或离开监测；目标评估队列也被阻止。数据库打开后仍进行副本自身的 schema 迁移，以保持读取兼容，但跳过媒体路径迁移、初次清理、定时清理、备份和维护。媒体清理入口另有守卫，避免副本中的绝对媒体路径删除正式录屏。回放可以只读访问原媒体；没有生成示例记录。

未设置变量的常规 Debug 构建和所有 Release 构建保留正常行为。预览设置只用于本地界面验证，不改变正式版的录制、分析或保留策略。

## 已完成检查

- 阶段提交前重新运行正常构建及完整签名验证，通过；上述 7 个测试组重新运行共 45 项通过，包含最新系统通知默认声音行为。日志为 `build/verification/checkpoint-build.log` 和 `build/verification/checkpoint-tests.log`。

- 最终 `scripts/run-local.sh --build-only` 使用固定证书构建成功，完整签名验证成功；日志为 `build/verification/build-final.log`。首轮成功日志保留在 `build/verification/build-first-passed.log`。
- 独立预览 bundle 最终构建成功；日志为 `build/verification/preview-build-final.log`。
- 7 个选定测试组共 45 项通过：`EventGoalTests`、`TargetEvaluationTests`、`TargetNotificationPreferencesTests`、`ProvidersSettingsViewModelTests`、`LLMUsageReceiptTests`、`TargetFlowScopeTests`、`TimelineActivityLoaderTests`。日志为 `build/verification/tests.log`。
- 设置及提供商界面变更、预览守卫均通过 Swift 语法检查；`git diff --check` 通过。
- 已实际运行独立 SwiftUI 应用，检查日／周时间线、日历与事件筛选、所选事件详情、真实录屏的 20× 回放、多当前目标开关（操作后恢复）、记录与提醒／隐私／提供商设置，以及浅色／深色切换。
- 已实测最小窗口约束：内容最小尺寸约 900 × 558，macOS 测得窗口边框为 901 × 591（包含隐藏标题栏区域）；通过系统「窗口 → 移动与调整大小 → 左上」触及该约束。日视图隐藏左侧日历面板，保留日历弹出窗和横向事件筛选；周网格可横向滚动。目标管理弹窗底部的「添加事件」「调整颜色」「完成」均可见，卡片回顾及记录设置页可滚动访问内容。
- 构建仍有项目既存警告：`Copy Bundle Resources` 包含目标自己的 `Info.plist`。本次构建成功，未借界面重构改变该构建配置。

## 真实应用截图

以下文件均为独立构建产物的实际界面截图；显示的活动来自真实数据库副本，不是静态设计稿或新增示例。

| 页面 | 路径 |
| --- | --- |
| 浅色日时间线 | `build/verification/timeline-day-light.png` |
| 浅色事件详情与回放 | `build/verification/timeline-detail-light.png` |
| 浅色周时间线 | `build/verification/timeline-week-light.png` |
| 事件与目标管理 | `build/verification/goals-light.png` |
| 记录与提醒设置 | `build/verification/settings-recording-light.png` |
| 隐私设置 | `build/verification/settings-privacy-light.png` |
| 浅色提供商设置 | `build/verification/settings-providers-light.png` |
| 深色提供商设置 | `build/verification/settings-providers-dark.png` |
| 深色事件详情 | `build/verification/timeline-detail-dark.png` |
| 最小窗口日时间线 | `build/verification/timeline-minimum-dark.png` |
| 最小窗口周时间线 | `build/verification/timeline-week-minimum-dark.png` |
| 最小窗口目标管理 | `build/verification/goals-minimum-dark.png` |
| 最小窗口卡片回顾 | `build/verification/review-minimum-dark.png` |
| 最小窗口记录设置 | `build/verification/settings-minimum-dark.png` |

## 验证边界

此模式隔离数据目录和偏好、关闭自动后台工作，并非完整的网络或钥匙串沙箱。显式操作“重新分析失败记录”和“测试提供商连接”仍可能发送请求；提供商密钥服务前缀也仍与正式应用相同。因此本次界面验证只浏览提供商配置，不执行连接测试、保存或删除密钥，不触发失败记录重新分析。上述 45 项测试覆盖选定的目标、通知偏好、提供商配置、费用解析和时间线逻辑；它们不证明外部连接、实际请求计费、系统通知送达或密钥写入已完成端到端验证。

实际录屏授权（TCC）、正式连续录制、系统通知实际送达以及云端提供商可用性不在这个独立预览模式中验证。真实录屏回放通过不等于本次已重新执行屏幕采集。没有重置 macOS 录屏授权，也没有替换已安装的应用。
