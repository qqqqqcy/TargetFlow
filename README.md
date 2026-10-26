# Target Flow

Target Flow 是 [Dayflow](https://github.com/JerryZLiu/dayflow) 的本地 fork，功能聚焦于自动时间线、当前目标和相关设置。保留上游 Git 历史和 MIT 许可证；基于上游提交 `730d6f84`（v2.7.5）。

## 功能范围

- **时间线**：屏幕录制与自动分析、日／周时间线、活动卡片与回放、分类、时间线复核、复制和删除。
- **Target**：设置、更新或结束当前目标；新卡片保存后由当前主提供商异步评估为「专心／中性／严重偏离」，显示判断理由和 AI 回归建议，卡片详情保留评估时的目标。跨越目标启用时间的卡片，仅使用启用后的活动记录评估，不追溯之前的活动。
- **设置 → Target**：严重偏离提醒开关，5／15／30 分钟冷却间隔（默认 15），系统通知权限／横幅／声音检测、请求权限、打开系统设置及测试通知。仅最近 30 分钟内结束的严重偏离卡片触发提醒，点击通知打开 Target。
- **设置 → 存储空间**：录制与回放空间用量、存储上限和清理；截屏频率和卡片生成间隔（1、5、15 分钟，默认 5 分钟）。
- **设置 → 隐私**：选择不参与屏幕录制的应用。
- **设置 → 提供商**：配置自己的 API、本地模型或 CLI 提供商，以及主／备用提供商。
- 首次启动仅配置提供商和屏幕录制权限；菜单栏保留录制、暂停、打开窗口和退出等必要操作。

日报、独立周报、聊天、Flow、Agents、账户／订阅、推荐计划、MCP／CLI 接入设置、导出设置及其他设置不再作为应用功能提供。原版的更新检查、功能推广和遥测不启动，构建时不再捆绑 Dayflow CLI。

上游的一些未使用视图、模型、资源及数据库表仍保留在源码中，便于维护共享依赖和后续合并；它们没有应用入口或启动任务。项目和 Swift 模块仍名为 `Dayflow`，构建产物为 `TargetFlow.app`。

## 与 Dayflow 并存

- 应用标识：`local.targetflow.app`
- URL scheme：`targetflow://`（录制开始／停止）
- 数据目录：`~/Library/Application Support/TargetFlow/`
- API 密钥服务前缀：`local.targetflow.apikeys`

不自动导入或迁移已安装 Dayflow 的录屏、数据库、偏好或密钥。首次启动需要单独授权屏幕录制并配置提供商。选择云端提供商时，分析所需的活动数据会发送到该提供商。

## 构建

需要完整 Xcode（支持该上游项目的 Swift 工具链和 macOS SDK），仅安装 Command Line Tools 无法构建这个 macOS 应用。应用部署目标为 macOS 14；测试目标为 macOS 15.1。

```bash
open Dayflow/Dayflow.xcodeproj
```

选择 `Dayflow` scheme，在 Signing & Capabilities 中设置自己的签名团队，然后运行。需要录屏授权的应用必须使用完整的 bundle 签名，不要用 `CODE_SIGNING_ALLOWED=NO` 生成日常运行的版本。

本地构建、验证签名并安装到固定路径 `/Applications/TargetFlow.app`：

```bash
bash scripts/run-local.sh
```

安装前需要从菜单栏选择“完全退出”；脚本不会覆盖正在运行的应用。只构建并验证、不安装时使用 `bash scripts/run-local.sh --build-only`。

日常构建必须固定使用同一张代码签名证书，避免重编译后录屏授权失效。脚本优先读取 `TARGETFLOW_SIGNING_IDENTITY`，其次读取被 Git 忽略的 `scripts/local-signing-identity`（单行证书 SHA-1）。使用 `security find-identity -v -p codesigning` 查看可用证书，将选定的 SHA-1 保存到该文件，之后直接运行脚本即可。也可以临时指定，例如：

```bash
TARGETFLOW_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
  bash scripts/run-local.sh
```

没有配置证书时脚本会停止，不会自动改用临时签名。仅临时验证时可显式指定 `TARGETFLOW_SIGNING_IDENTITY=-`；这种 ad-hoc 签名的身份绑定程序内容哈希，不适合作为需要保留录屏授权的日常安装版本。

脚本不会创建证书、修改钥匙串信任或自动重置权限。首次从临时签名切换到固定证书后可能需要重新授权一次；之后保持证书、应用标识和安装路径不变。证书过期或被替换时需要重新检查权限。Xcode 直接运行也应选择同一证书，避免与脚本安装的签名身份混用。

### 屏幕录制权限

首次启动时点击“打开系统设置”，在“隐私与安全性 → 录屏与系统录音”（部分 macOS 版本称“屏幕与系统音频录制”）中开启 TargetFlow。列表没有应用时，点击 `+` 添加 `/Applications/TargetFlow.app`。这里不需要辅助功能权限。

返回应用后会自动重新检查权限。如果开关已开启但权限仍未生效，点击“退出并重新打开”；按钮会真正重启应用。只有系统权限检查成功，“下一步”才可用。

如果曾运行不签名的版本，或者更换了签名身份，系统可能仍保留旧身份的授权。先完全退出 Target Flow，再只重置本应用的录屏授权，然后重新打开并授权：

```bash
tccutil reset ScreenCapture local.targetflow.app
open /Applications/TargetFlow.app
```

这属于旧签名记录的迁移恢复，不是每次启动的必要步骤；应用不会自动执行权限重置。

运行单元测试：

```bash
xcodebuild -project Dayflow/Dayflow.xcodeproj \
  -scheme Dayflow -destination 'platform=macOS' \
  -only-testing:DayflowTests CODE_SIGNING_ALLOWED=NO test
```

本地 `upstream` remote 指向同级 `dayflow/` 仓库，开发分支为 `target-flow`。尚未创建或推送 GitHub 远程 fork。原版发布脚本保留作上游参考；本 fork 没有配置发布渠道。

## 许可证

继承上游 [MIT License](LICENSE)，保留原作者版权声明。
