# 录屏分析详情出现删除线的原因

## 结论

事件摘要和详细记录中的普通文字被界面作为 Markdown 解析。正文中的 ASCII 波浪号 `~` 在满足解析条件时会触发删除线；两个不同记录行中的波浪号可以配对，把其间多行文字一起划掉。

这不是事件被删除、失效或需要忽略的标记。录屏分析输出包含正文中的波浪号，显示层将这些字符解释成了排版语法。

## 代码链路

修复前，`Dayflow/Dayflow/Views/UI/MainView/ActivityCard.swift` 中：

1. 事件摘要传给 `renderMarkdownText(summaryText(for: activity))`。
2. 详细记录先经过 `formattedDetailedSummary`，再传给相同的 `renderMarkdownText`。
3. `renderMarkdownText` 调用 `AttributedString(markdown:options:)`，选用 `.inlineOnlyPreservingWhitespace`。
4. 该选项保留空白，但仍解释行内 Markdown，包括删除线；保留换行并不阻止语法跨行配对。
5. 解析成功后，`Text(parsed)` 显示带有 `.strikethrough` 意图的文字。只有解析抛出错误才会退回普通 `Text(content)`；误解释合法语法不会触发回退。

`formattedDetailedSummary` 只处理没有换行的旧详情，按时间范围插入换行，没有添加删除线的逻辑。

Git 历史表明，Markdown 渲染函数在该视图最初引入时就已存在。近期分析结果中的正文字符可以触发这条既有路径，无需近期新增删除线功能。

## 合成复现

在 macOS 的 Swift/Foundation 环境运行以下代码；所有文字与时间均为合成示例：

```swift
import Foundation

let content = """
9:00 AM - 9:01 AM: 查看示例标题~后续文字
9:01 AM - 9:02 AM: 编辑示例文档
9:02 AM - 9:03 AM: 查看另一标题~后续文字
"""
let options = AttributedString.MarkdownParsingOptions(
  interpretedSyntax: .inlineOnlyPreservingWhitespace
)
let parsed = try AttributedString(markdown: content, options: options)
let strikes = parsed.runs.filter {
  $0.inlinePresentationIntent?.contains(.strikethrough) == true
}
assert(!strikes.isEmpty)
assert(strikes.contains {
  String(parsed[$0.range].characters).contains("编辑示例文档")
})

let escaped = content.replacingOccurrences(of: "~", with: "\\~")
let safe = try AttributedString(markdown: escaped, options: options)
assert(!safe.runs.contains {
  $0.inlinePresentationIntent?.contains(.strikethrough) == true
})
```

验证时需要区分位置条件：`甲~乙~丙` 可以触发删除线，`甲 ~ 乙 ~ 丙` 没有触发。不能仅用两边都有空格的时间分隔符样例排除单个波浪号的影响。

## 实机验证边界

只读核对了与问题截图匹配的已存记录和对应模型响应中的格式字符，并在原设备使用相同的 Foundation 解析方式验证。原始正文含单个波浪号，没有双波浪号；原文能产生跨行删除线，转义波浪号后删除线消失。

本报告不保存原始活动、时间、模型请求或响应、数据库、截图及设备路径。

## 修复建议

优先将事件摘要与详细记录按纯文本显示，例如 `Text(verbatim: content)`。这些字段承载观察到的活动和引用文本，纯文本显示能保留波浪号、星号、下划线、反引号等原始字符，也可让已有记录直接恢复正常，无需重跑分析或修改数据库。

如果产品明确需要保留 Markdown 排版，则应另行定义哪些字段或语法允许解释。只转义 `~` 可以解决本次删除线，但仍会让其他正文字符被当成 Markdown 解释；仅修改模型提示词也无法修正已保存记录。

现已将事件摘要和详细记录改为纯文本显示，并移除 Markdown 渲染函数。已有记录读取时同样使用纯文本显示。
