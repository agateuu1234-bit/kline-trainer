#!/usr/bin/env python3
"""冻结清单 28 条 + 一条**函数形式**（末尾 "()"）的 UIKit-gated 期望测试。

为什么要有这份：当前全树没有任何函数形式的 UIKit-gated 测试，所以
「函数形式的名字在结构化结果里长什么样」在交付时没有现成档位覆盖。
那个名字与节点都是从 2026-10-11 本机真构建的结果包里**原样取**的
（源码 `@Test func g3_replayBaseline_captures_all_include_defaultStyle()`，
文本日志印作 `✔ Test g3_…() passed after`，结构化 name 就是 `g3_…()`）。
⛔ 别改成手造名字：本仓 feedback_fixtures_must_match_production_format。
"""
NAMES = [
    '§5.3 #14 drawDrawings with empty list calls no render',
    '§5.3 #15 registered tool render called once with passed-through drawing',
    '§5.3 #16 missing tool in dictionary skips silently (Wave 1 default path)',
    'D35：两条不同样式的 drawing 各自带自己的样式 + scheme 按顺序抵达渲染层',
    '标注 render 路径：.left/.right 画出文字像素；.hidden/.segment 无标注泄漏（codex plan-R5）',
    'render 路径回归（codex branch-R3 medium）：价格超出 viewport 区间的线，线与标注均不画；区间内对照组画出',
    'render 路径（codex branch-R5 medium）：损坏 fontSize（负数/极大）不崩溃、像素不越界',
    'ChartContainerView 可构造 + 符合 UIViewRepresentable',
    'Coordinator 可构造 + attach 装 5 个识别器（C7 接线编译反射）',
    'Coordinator crosshairPoint 默认 nil（视图层瞬态）',
    '布局到有效尺寸后 renderState 重算非空（静态 engine 不依赖 observation 再触发）',
    'layoutSubviews 同 bounds 只回调一次（lastLaidOutBounds 去重，挡重复 make）',
    '布局重算同步 engine bounds → 静态界面后续 pinch 生效（codex R1-F1：不被 stale .zero bounds no-op）',
    '瞬态零尺寸 layout 不 clamp panel offset（codex R2-F1：滚动位置不被吞）',
    '零尺寸 rebuild（updateUIView 路径）不 clamp offset（codex R3-F1：observation 路径同护）',
    'KLineView 可实例化（spec L1179 final class）',
    'renderState 可读写（compile-check：let 字段 + init 重建模式）',
    'forScheme(.dark) 13 字段桥 = AppPalette.dark',
    'forScheme(.light) 13 字段桥 = AppPalette.light',
    'light/dark UIColor 真不同（防退化为单集）',
    'KLineView 非 opaque（codex R4-F1：透明画布须 isOpaque=false，防 scheme 切换残留伪影）',
    'trait dark → 选 dark 集 / trait light → 选 light 集（currentPalette 选取链）',
    '默认 displayMode == .system',
    'resolve(trait:) .system + dark trait → .dark',
    'resolve(trait:) .light forced 忽略 dark trait',
    'resolve(trait:) .dark forced 忽略 light trait',
    'resolve(trait:) .system + .unspecified → .light（D-7：UIKit 未传播状态默认）',
    'UIColor(rgba:) 桥接保持通道值 + 13 const 全 = token 桥接（D-11）',
    'g3_replayBaseline_captures_all_include_defaultStyle()',
]

for n in NAMES:
    print(n)
