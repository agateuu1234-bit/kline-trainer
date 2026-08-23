// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingUndoEntry.swift
// Spec: 2026-08-11-drawing-tools-P1b-1b-ii-lock-undo-design.md §2.2（D75）/ §2.3（D76）
// 计划决策 D101 / D102。
//
// ⚠️ **纯值类型**：本文件不引用 TrainingEngine、不写 `drawings`。
//    引擎侧的全部撤销代码必须留在 TrainingEngine.swift —— `drawings` 是 `public private(set)`，
//    setter 是**文件作用域**，别的文件里的 extension 根本写不了它（编译器直接拦）；
//    而 D79 第一层那条穷尽守卫也只扫 TrainingEngine.swift，挪出去就等于从守卫底下溜走。

/// 一条**可撤销动作**的快照。栈深度 1 —— 引擎里最多存一条（D25）。
struct DrawingUndoEntry {

    /// `drawings` 那一半。**必存** —— 没有 `drawings` 改动就根本不入栈（D101）。
    ///
    /// ⚠️ 三个 case 的 `at` 都是**动作发生时**的下标，D25 逐字：数组序 = z-order。
    ///    撤销必须回到**同一个下标**，不是"放回末尾"—— 否则同价位重合的三条线撤销之后，
    ///    在那个价位单击选中的就不是原来那条了（D25 / D33 / D40 点名的正是这个错误）。
    enum DrawingsDelta {
        /// 画线：undo = `remove(at:)`，redo = `insert(after, at:)`
        case inserted(after: DrawingObject, at: Int)
        /// 删线：undo = `insert(before, at:)`，redo = `remove(at:)`
        case removed(before: DrawingObject, at: Int)
        /// 改样式 / 锁定：undo = `drawings[at] = before`，redo = `drawings[at] = after`
        case replaced(before: DrawingObject, after: DrawingObject, at: Int)
    }

    var drawingsDelta: DrawingsDelta

    /// 栈顶是否**已被撤销**。`false` ⇒ ↩ 可用；`true` ⇒ ↪ 可用（D78）。
    /// ⚠️ 深度 1 的栈用**一个布尔**表达 undo/redo 两个位，而不是两个数组 ——
    ///    「↩ 和 ↪ 同时可用」「已撤销却还能再撤」这类坏状态因此不可表达。
    var isUndone: Bool

    /// ⚠️ **显式构造器，不用自动生成的那个**（codex plan-R1，**已核实为真**）。
    ///    自动构造器要求实参**按存储属性声明顺序**给标签；Task 5 要往本结构里加第三个字段
    ///    `defaultDelta`，一旦它插在中间、或调用处顺序写反，就是一个**编译期**错误 ——
    ///    而卡住的正好是风险最高的成对回滚那一步。写死一个显式签名，把顺序收在这一处：
    ///    将来再加字段只需在**这里**追加一个带默认值的尾参，既有调用点一处都不用动。
    init(drawingsDelta: DrawingsDelta, isUndone: Bool) {
        self.drawingsDelta = drawingsDelta
        self.isUndone = isUndone
    }
}
