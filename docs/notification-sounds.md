# 提醒音效

目标提醒使用本机已安装的 Cindy 游戏音效。原文件来自 `/Applications/Cindy.app/Contents/Resources/tools/agent-island/sounds/`；转换后的资源保存在 `Dayflow/Dayflow/Sounds/`，随 Target Flow 打包，运行时不依赖 Cindy。

| 设置中的名称 | 原文件 |
| --- | --- |
| 宝石收集（默认） | `gem-collect.mp3` |
| 发现物品 | `item-found.mp3` |
| 秘密发现 | `secret-chime.mp3` |
| 清脆铃声 | `ring-chime.mp3` |
| 获得道具 | `item-fanfare.mp3` |
| 胜利号角 | `victory-fanfare.mp3` |
| 启程提示 | `startup-chime.mp3` |
| 错误警示 | `error-buzz.mp3` |

macOS 系统通知的自定义声音需使用支持的音频格式，且短于 30 秒。文件使用 `afconvert -f caff -d LEI16` 从原 MP3 转换为 CAF，保留原采样率和声道，命名为 `target-<原文件名>.caf`。测试验证全部音效均已打包、可解码且短于 30 秒。

刘海通知通过 `NSSound` 播放，系统 Notice 通过 `UNNotificationSound` 播放相同文件；静音时两条路径均不播放声音。单独试听不会发送通知。系统 Notice 的实际横幅和声音还受系统通知权限、声音设置及专注模式控制。
