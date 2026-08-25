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

    /// 「本局默认」那一半（D102）。**只有画线态改样式那条路会带** ——
    /// 那一次动作是**两处写入**（那条线 + 本局默认，见 `DrawingEditRouter.applyPanelStyleMutation`
    /// 的 `.draw` 分支）。撤销必须把这一对当**一个**动作一并回滚，否则被撤销掉的样式会在
    /// 下一笔新画的线上、以及断点续训之后复活（自动选中 spec §10.1，**override 不覆盖**）。
    var defaultDelta: DrawingDefaultStyleDelta?

    /// ⚠️ **显式构造器，不用自动生成的那个**（codex plan-R1，**已核实为真**）。
    ///    自动构造器要求实参**按存储属性声明顺序**给标签；Task 5 要往本结构里加第三个字段
    ///    `defaultDelta`，一旦它插在中间、或调用处顺序写反，就是一个**编译期**错误 ——
    ///    而卡住的正好是风险最高的成对回滚那一步。写死一个显式签名，把顺序收在这一处：
    ///    将来再加字段只需在**这里**追加一个带默认值的尾参，既有调用点一处都不用动。
    ///
    /// ⚠️ 新参数**必须排在最后且带默认值**（codex plan-R1）：这样 Task 1 / Task 3 里那些
    ///    两参构造点（`DrawingUndoEntry(drawingsDelta:isUndone:)`）**一处都不用改**。
    ///    把它插在中间 = 那些调用点全部编译不过。
    init(drawingsDelta: DrawingsDelta, isUndone: Bool,
         defaultDelta: DrawingDefaultStyleDelta? = nil) {
        self.drawingsDelta = drawingsDelta
        self.isUndone = isUndone
        self.defaultDelta = defaultDelta
    }
}

/// 「本局默认」那一半的前后快照（D102）。
/// ⚠️ **用一个成对的结构而不是两个可选字段** —— `before` 有值而 `after` 没有（或反过来）
///    是个说不通的状态，用两个 `Optional` 就把它变成可表达的了。
struct DrawingDefaultStyleDelta: Equatable {
    let before: DrawingDefaultStyle
    let after: DrawingDefaultStyle
}

/// undo / redo 共用同一个执行单点，方向由本枚举表达 —— 两份镜像实现必然漂移（D76 的表格是对称的）。
enum DrawingUndoDirection { case undo, redo }
