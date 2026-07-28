// Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift
// 设置面板灰态判据（host 可测，非 View）。本期只实现水平线（母 spec §3.1 水平线行）；
// 其余工具的矩阵属 P1c，届时再泛化——本期不写不存在工具的分支（YAGNI）。
public enum DrawingStyleAvailability {
    /// 线型子类：水平线 直线✅/射线✅/线段灰。
    public static func horizontalLineSubTypeEnabled(_ sub: LineSubType) -> Bool {
        switch sub {
        case .straight, .ray: return true
        case .segment:        return false
        }
    }

    /// D59/D67 共享单点：该 `toolType` 下 `lineSubType` 是否**恒可渲染**（与 viewport 无关）。
    /// append 家族的引擎门、`DrawingObject.withStyle` 的可用性闸、设置面板的线型灰态**三处共用**它，
    /// 禁止各写一份（D59「与设置面板灰态同一真相」）。
    /// ⚠️ 横规则**只对水平工具成立**（`horizontalLineSubTypeEnabled` 的头注：本期只实现水平线）——
    /// 对非水平工具无条件套它，会把合法的 `.trend` 线段在共享写入边界静默拒掉（codex WB re-attest R1 实证）。
    public static func isRenderableSubType(_ sub: LineSubType, toolType: DrawingToolType) -> Bool {
        guard toolType == .horizontal else { return true }   // 非水平：横规则不适用（矩阵属 P1c）
        return horizontalLineSubTypeEnabled(sub)
    }

    /// 本构建**写得出样式矩阵**的工具集。与 `DrawingToolType.implemented`（= 画得出 / 提交得了）
    /// **是两件不同的事**（codex plan-R13-F2）：那个集合回答"能不能画"，本集合回答"本构建懂不懂它的
    /// 样式语义"。今天只有水平线有矩阵（`horizontalLineSubTypeEnabled` / `horizontalLabelModeEnabled`）。
    /// ⚠️ P1c 给新工具接线时：加进 `DrawingToolType.implemented` 之后它就能画了，但**样式仍改不动**，
    ///   直到你为它写出子类型/标注矩阵并加进本集合 —— 这个方向的漂移是 **fail-closed**（现象是
    ///   "新工具的样式控件不生效"，一眼可见、且不污染数据），比反过来 fail-open
    ///   （尚无矩阵就允许编辑 → 把不受支持的样式组合持久化）安全。
    static let toolsWithStyleMatrix: Set<DrawingToolType> = [.horizontal]

    /// 该工具的样式语义是否被本构建理解 → **能否编辑**（codex plan-R11-F1）。
    /// ⚠️ **复用既有单一真相 `DrawingToolType.implemented`**（`Models.swift:50`），**绝不另立第二份登记表**
    ///   （codex plan-R12-F2：我上一稿真的另写了一个 `implementedToolTypes`，那会在 P1c 打开新工具时漂移成
    ///   「画得出、样式控件却永远不生效」）。该集合已被激活门（`TrainingEngine:1259`）与落锚阈值
    ///   （`DefaultDrawingInputController:43`，其注释原文「单一真相派生」）消费 —— 编辑面跟着它走，
    ///   P1c 只要照常把新工具加进 `DrawingToolType.implemented`，可编辑性**自动**跟上，无需记住第二处。
    /// ⚠️ **与 `isRenderableSubType`（append 侧）刻意不对称，别"统一"掉**：
    ///   - **append = 数据进来**：拒绝 = 静默丢掉用户/高版本已有的线 → 必须宽松（PR-1 over-reject 的教训）；
    ///   - **编辑 = 改写已有数据**：`DrawingToolType` 把 `.trend`/`.text` 等目标工具**已声明为已知 case**，
    ///     故一条高版本 `.trend` 线解码后是 known 值、**D61 的 raw-aware 门看不见它** → 若放行编辑，
    ///     本构建就会拿**水平线的样式假设**改写一条自己根本渲染不出的线，且不可逆（本期无 undo）。
    ///   与 D61「高版本线：选得中、改不动样式、可整条删」逐字同构 —— 同一条纪律，只是判据从
    ///   「未知枚举值」扩到「已知但本构建未实现的工具」。
    public static func isEditableToolType(_ t: DrawingToolType) -> Bool {
        DrawingToolType.implemented.contains(t) && toolsWithStyleMatrix.contains(t)
    }

    /// D59 共享单点（tool-aware 版）：写入边界用的 `labelMode` 归一化。
    /// ⚠️ **与 `isRenderableSubType` 必须对称**（codex plan-R2-F1... 见 R2-F2）：`normalizedLabelMode(current:lineSubType:)`
    /// 里那条「射线不能配『左』」是**水平线的**规则（`horizontalLabelModeEnabled` 头注：母 spec §3.1 水平线行）。
    /// 若 `withStyle` 这种**工具无关**的写入边界无条件套它，一条 `.trend` 线的 `.show` / `.left` 会被按横线规则
    /// 静默改写成 `.hidden` —— 与 PR-1 那个 `.segment` over-reject **同族**（把只对某类型成立的规则套到所有类型）。
    /// 非水平工具：原样返回（它们的 labelMode 矩阵属 P1c，本期不替它们做决定）。
    public static func normalizedLabelMode(current: LabelMode, lineSubType: LineSubType,
                                           toolType: DrawingToolType) -> LabelMode {
        guard toolType == .horizontal else { return current }
        return normalizedLabelMode(current: current, lineSubType: lineSubType)
    }

    /// 标注：水平线 隐藏/左/右可选、显示恒灰；选射线时『左』再灰（母 spec §3.1）。
    public static func horizontalLabelModeEnabled(_ mode: LabelMode, lineSubType: LineSubType) -> Bool {
        switch mode {
        case .show:   return false
        case .hidden, .right: return true
        case .left:   return lineSubType != .ray
        }
    }

    /// 依赖字段规整：切线型子类后，若旧 labelMode 在新子类下不可用（如直线选『左』后切射线），
    /// 回落 .hidden；否则原样。**复用 horizontalLabelModeEnabled，规则单一真相不重复。**
    /// 设置卡片切线型时调它 → 矛盾组合（灰项却被当默认提交）从结构上进不来（codex plan-R1-medium）。
    public static func normalizedLabelMode(current: LabelMode, lineSubType: LineSubType) -> LabelMode {
        horizontalLabelModeEnabled(current, lineSubType: lineSubType) ? current : .hidden
    }
}
