# 导航栏流动等高线

视觉参考：[React Drops · Topographic Flow](https://reactdrops.dev/components/background/topographic-flow)。选择其舒缓变化的等高线概念，呼应 Target Flow 的流动主题，在蓝白界面中增加层次。

应用使用独立编写的 SwiftUI `Canvas` 实现，没有嵌入 React Drops 的组件源码、依赖或网页运行时。效果仅位于左侧 166 点宽的导航栏背景，不覆盖时间线内容；22 条封闭曲线缓慢起伏，每四条强调一条，透明度为 10%／20%，顶部和底部渐隐。线条不接收点击，也不进入辅助功能树。

动画最多每秒更新 20 次。视图不可见或场景不活跃时暂停累计时间，恢复时从原位置继续；系统开启“减少动态效果”时显示固定构图。深色主题略微降低装饰透明度。组件内提供浅色与深色 Xcode Preview。

代码入口：`Dayflow/Dayflow/Views/Components/TopographicFlowBackground.swift`。主界面在 `Layout+Panels.swift` 的 `leftColumn` 背景接入。
