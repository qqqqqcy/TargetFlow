# 自动测试

目标为 `main` 的拉取请求和推送到 `main` 会触发 [Tests workflow](../.github/workflows/tests.yml)。它在 `macos-15` 上运行 `bash scripts/test.sh` 和 Python unittest discovery；Swift 测试失败时仍会运行 Python 测试，任一测试失败都会使任务失败。

配置 `main` 分支保护规则或规则集时，可将任务检查 **Swift and Python tests** 设为必需检查。该设置需要在 GitHub 仓库设置中单独完成；工作流文件本身不会启用分支保护。

测试工作流与现有发布工作流独立运行，推送到 `main` 后发布流程不会等待测试结果。部分 Swift 测试依赖图形会话，是否能在 GitHub 托管的 runner 上稳定运行需要通过实际 CI 运行确认。
