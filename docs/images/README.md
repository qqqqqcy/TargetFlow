# Target Flow 品牌素材

- `target-flow-icon.svg`：可缩放应用图标。
- `target-flow-icon.png`：1024 × 1024 应用图标预览。
- `target-flow-header.png`：Target Flow 品牌横幅。

## README 产品演示

- `target-flow-timeline.png`：当前目标与自动事件时间线，1440 × 1010。
- `target-flow-current-goals.gif`：打开「事件与目标」、开启第二个目标并返回时间线，4 个步骤帧、循环播放，1440 × 1010。
- `target-flow-assessment.png`：事件详情中的分心评估、判断理由和回归建议，1440 × 1010。
- `target-flow-distraction-reminder.png`：真实展开的刘海提醒窗口，1440 × 830。通过独立预览应用的「预览刘海通知」按钮触发，正文保留测试提醒文案；只裁切窗口、添加圆角展示框和说明，不改写提醒内容。

英文 README 使用以上英文版素材，应用界面、目标、事件、评估示例与画面标题均为英文。中文版 README 使用对应的 `-zh-CN` 素材：`target-flow-timeline-zh-CN.png`、`target-flow-current-goals-zh-CN.gif`、`target-flow-assessment-zh-CN.png` 和 `target-flow-distraction-reminder-zh-CN.png`，界面及示例文案为中文。两套素材由应用的真实窗口截图排版制作。使用独立标识 `local.targetflow.preview.readme` 和隔离数据库中的虚构演示内容；不含真实用户的活动记录、录屏、密钥或接口日志。评估文字为预置示例，并非现场调用模型的结果。GIF 是实际操作截图序列，不是连续录屏。

截图加上标题、蓝白背景和示例数据说明；应用界面本身没有重绘。截图在界面动画结束后采集。演示数据库与构建中间文件保存在被 Git 忽略的 `build/readme-media/`，不作为产品数据发布。

应用图标、菜单栏图标、启动图、引导示意图及引导视频均由本项目原创生成。

重新生成应用素材：

```bash
swift scripts/generate-brand-assets.swift
```

应用品牌名为 **Target Flow**，当前版本为 **0.0.1**。上游来源和许可证见项目根目录 README 与 LICENSE。
