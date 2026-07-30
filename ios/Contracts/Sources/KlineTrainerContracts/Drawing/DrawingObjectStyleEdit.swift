// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingObjectStyleEdit.swift
// D59（1b-i 切片2）：`DrawingObject` 的**样式语义闸单点**。四条语义在源码中各只出现这一次：
//   派生① isExtended == (lineSubType == .ray)
//   派生② textColorToken **条件**派生（本来跟线同色的才继续跟随；已是独立字色则保留）
//   归一化 labelMode 必须过 DrawingStyleAvailability.normalizedLabelMode（挡 (ray,.left)）
//   可用性 lineSubType 必须是该 toolType 恒可渲染的值（水平线的 .segment 恒不可渲染 → nil）
// 两个写入点共用（DrawingSession.commitPending / TrainingEngine.updateDrawingStyle），各自传播失败——
// 不许任何调用方"自己派生一遍"或"信任面板会归一化"（D59：public/internal 写入面必须自己把关）。
extension DrawingObject {
    /// nil = 该样式对本对象语义上不成立（① 该 `toolType` 下 `lineSubType` 恒不可渲染，如水平线的 `.segment`；
    /// ② `thickness` 越出本构建的 1…5 值域**且**与本对象当前值不同，见下）。
    /// 非 nil 时：只换 5 个样式字段 + 两个派生字段，其余字段逐字段原样拷贝。
    func withStyle(_ s: DrawingDefaultStyle) -> DrawingObject? {
        // ⚠️ **工具门不在这里**（codex plan-R15-F2）：`withStyle` 同时服务**新建**（`commitPending`）与
        //   **编辑**（`updateDrawingStyle`）。把「只有已写出样式矩阵的工具才准动」塞进这里，会让 P1c
        //   新工具「能激活却提交失败、静默丢锚不出线」。编辑门属于编辑面 → 放在 `updateDrawingStyle`。
        guard DrawingStyleAvailability.isRenderableSubType(s.lineSubType, toolType: toolType) else { return nil }
        // 值域闸（codex plan-R4-F1）：`DrawingDefaultStyle.thickness` 是裸 `Int`、文档域 1…5
        // （`DrawingEnums.swift:31`），面板控件只产 1…5，但**直接调用者**能塞 0 / 负数 / 极大值，
        // 经 updateDrawingStyle 落库并 autosave；渲染器那层 clamp 只会**掩盖**坏数据不会阻止它
        // （同 P1a「持久化 fontSize 可为负」那族，[[feedback_internal_review_misses_bad_data]]）。
        // ⚠️ **条件式，不是一律拒**（否则过度拒绝，重犯 PR-1 的 over-reject）：`thickness` 是 Int 不是枚举，
        //    D61 的 raw-aware 判据**看不见**高版本写的 thickness=8 这类值。若无条件要求 1…5，
        //    PR-4 按 D49 派生回显把 8 原样传回来时，这条线连改颜色都会被拒死。
        //    故：**写入一个新的越域值 → 拒**；**原样带回本对象已有的越域值 → 放行**（不代高版本决定它的粗细，
        //    与 D52「装载不加闸」、D61「不认识的就别改」同一条纪律）。
        guard (1...5).contains(s.thickness) || s.thickness == thickness else { return nil }
        return DrawingObject(
            id: id, toolType: toolType, anchors: anchors,
            isExtended: s.lineSubType == .ray,                     // 派生①
            panelPosition: panelPosition, revealTick: revealTick,
            period: period,
            lineSubType: s.lineSubType, lineStyle: s.lineStyle,
            thickness: s.thickness, colorToken: s.colorToken,
            // 归一化必须 **tool-aware**（codex plan-R2-F2）：横线规则只对 .horizontal 成立，
            // 无条件套会把 .trend 等工具的 .show/.left 静默改写成 .hidden（与 .segment over-reject 同族）。
            labelMode: DrawingStyleAvailability.normalizedLabelMode(current: s.labelMode,
                                                                    lineSubType: s.lineSubType,
                                                                    toolType: toolType),
            locked: locked,                                        // 本函数不碰 locked（能不能改由引擎门 D60 判）
            text: text, fontSize: fontSize,
            // 派生②（条件，codex R11-F1）：known 独立字色（如 orange 线 + blue 标签）必须保住；
            // 无条件 `= s.colorToken` 会把它抹成线色。unknown 枚举那一类由 D61 整条拒编辑兜住
            // （保守版：带未来数据的线根本进不到这里）。
            textColorToken: textColorToken == colorToken ? s.colorToken : textColorToken,
            textForm: textForm, tailAnchor: tailAnchor)
    }
}
