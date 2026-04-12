# Kline Trainer iOS App — 全量项目实施方案

**版本：v1.5**
**更新日期：2026-04-11**
**变更说明：(1) MACD 线颜色从 DIF白+DEA黑 改为 DIF白+DEA黄，与需求"黄白线"一致；(2) 第三按钮改为动态命名——有仓位时显示"持有"，空仓时显示"观察"；(3) 修正 2 处残留笔误（代码注释和验证方案中"最小周期/分钟"→"月"）。**
**v1.4 变更说明：修正 4 处需求偏差——(1) 买入仓位基准从可用资金改为总资金；(2) BOLL 曲线样式从灰色细线改为灰色虚线；(3) ticket_index 确认以 1 分钟为基准，去掉 3 分钟降级备选；(4) 修正手势矛盾说明，需求 4.2.1 和 8.3 均为双指，无矛盾。**
**v1.3 变更说明：修正 8.3 节训练集"之后"数据范围定义错误——从"8 根最小周期 K 线时间窗口"（约 24 分钟）改回需求 7.2 原文的"8 根月 K 线时间窗口"（约 8 个月），涉及注释、查询代码及关键改动说明共 3 处。**
**v1.2 变更说明：在 v1.1 基础上整合 3 轮对抗性评审的全部 49 项必改，涵盖架构层（渲染、手势、状态模型）、需求对齐（收益率、持仓成本、盈亏颜色、免5、index 基准）、业务规则（100 股取整、卖出语义、成本模型）、持久化完整性（交易记录、进度保存、训练组关联）、后端协议（租约模型、验收状态机）等。**

---

## 一、技术选型

| 层面 | 选型 | 理由 |
|------|------|------|
| **iOS UI 框架** | SwiftUI | 现代化，开发效率高；复杂图表部分用 UIKit 自绘 + UIViewRepresentable 桥接 |
| **架构模式** | MVVM + @Observable | SwiftUI 最主流架构，@Observable 比旧 @ObservableObject 更简洁高效 |
| **K 线渲染** | Core Graphics 自绘引擎（Phase 1 纯 `draw(_:)`，单帧 >4ms 时引入 Bitmap Cache） | 所有图表元素在同一坐标系渲染，零帧漂移。Bitmap Cache 非默认，按性能实测按需引入 |
| **滚动/手势** | UIPanGestureRecognizer + DecelerationAnimator | 自定义手势 + 极简减速器，避免 Phantom ScrollView 的手势仲裁复杂度 |
| **本地存储** | GRDB.swift + SQLite | 训练组：独立 SQLite 文件直连查询。训练记录/设置：统一 app.sqlite |
| **网络层** | async/await + URLSession | 后端接口仅 2 个，无需第三方网络库 |
| **后端框架** | FastAPI (Python) | 轻量，部署 NAS Docker 方便。服务器地址集中于环境变量，便于日后迁移到云服务器 |
| **数据库** | PostgreSQL (Docker on NAS) | 需求指定 |
| **数据处理** | pandas + pandas-ta | 计算 MA66/BOLL/MACD 技术指标 |
| **部署目标** | iOS/iPadOS 17+ | 自用设备为 iOS 18，17+ 兼容日后上架（覆盖约 85-90% 用户） |

### K 线渲染策略：Core Graphics 自绘引擎

**核心思路：所有图表元素在同一个 `draw(in ctx: CGContext)` 中渲染，共享同一个 ChartViewport 与 CoordinateMapper，零帧漂移，完全可控。**

**Phase 1 策略：纯 `draw(_:)` 无 Bitmap 缓存，每帧完整重绘。** 可见蜡烛约 93 根，总计约 600-700 次 Core Graphics 调用/帧，A17 Pro 在 120Hz 下无压力（瓶颈线 > 5000 次）。**性能门槛：当 Instruments 测量单帧绘制超过 4ms 时，引入 Bitmap Cache 优化。**

**排除方案：**

* KSChart/开源库：引入黑盒坐标系，Overlay 帧级漂移无法根治
* TradingView Lightweight Charts：JS + WKWebView，延迟大、内存高
* SwiftUI Charts：不支持缩放/平移/绘线

### 手势方案：UIPanGestureRecognizer + DecelerationAnimator

**替代 Phantom ScrollView，避免透明 UIScrollView 与 Pinch/LongPress/DrawingPan/两指切周期的手势仲裁问题。**

**DecelerationAnimator 实现：**

```swift
class DecelerationAnimator {
    private var displayLink: CADisplayLink?
    private var velocity: CGFloat = 0
    private let friction: CGFloat = 0.94
    private let refInterval: CGFloat = 1.0 / 120.0
    private let stopThreshold: CGFloat = 0.5  // pt/s
    
    var onUpdate: ((CGFloat) -> Void)?  // 传出 delta offset
    
    func start(initialVelocity: CGFloat) {
        velocity = initialVelocity
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    @objc private func tick(_ link: CADisplayLink) {
        let dt = CGFloat(link.targetTimestamp - link.timestamp)
        guard dt > 0 && dt < 1.0 else {
            // 后台恢复时 dt 可能爆炸，直接停止
            stop()
            return
        }
        velocity *= pow(friction, dt / refInterval)
        if abs(velocity) < stopThreshold {
            stop()
            return
        }
        onUpdate?(velocity * dt)
    }
    
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        velocity = 0
    }
}
```

**关键设计点：**
- CADisplayLink 驱动，基于 `deltaTime` 的指数衰减（`velocity *= pow(friction, dt / refInterval)`）
- 停止阈值 0.5 pt/s
- `sceneDidBecomeActive` 时 reset animator 状态，防止后台恢复 deltaTime 爆炸导致一帧跳出屏幕
- 边缘 bounce 在 Phase 5 磨光阶段再加

**手势仲裁规则：**

| 手势 | 识别器 | 优先级 | 冲突处理 |
|------|--------|--------|---------|
| 单指左右滑动 | UIPanGestureRecognizer | 默认 | 检测主方向为水平时激活 |
| 两指上下滑动 | UIPanGestureRecognizer (numberOfTouchesRequired=2) | 高于单指 | 检测主方向为垂直时激活，与 Pinch 通过主方向判定互斥 |
| 两指捏合/张开 | UIPinchGestureRecognizer | 高于单指 | 与两指垂直滑动通过主方向判定互斥 |
| 长按 | UILongPressGestureRecognizer | 与 Pan 共存 | `shouldRecognizeSimultaneouslyWith` 返回 true |
| 绘线锚点 | UITapGestureRecognizer | 仅 Drawing 模式 | Drawing 模式下 Pan 被绘线截获 |

**说明：** 需求 4.2.1 和 8.3 均为两指上下滑动切换周期，方案采用**两指上下滑动**，通过 numberOfTouches 与单指左右平移清晰区分。

### 图表架构核心

```
TickEngine（唯一时间状态）
    → globalTickIndex
BinarySearch（纯函数）
    → 可见数据分片
PanelViewState × 2（每面板独立）
    → period / interactionMode / visibleCount / offset
ChartViewport（计算属性）
    → startIndex / visibleCount / priceRange
CoordinateMapper（纯数学）
    → index→X, price→Y

UIPanGestureRecognizer → DecelerationAnimator → offset → 
KLineView.draw(_ rect:)
    ├── 行情图 + MA66 + BOLL
    ├── 交易量柱状图
    ├── MACD 子图（柱子 + DIF/DEA 线）
    ├── 买卖标记（红点B / 绿点S）
    ├── 绘线工具
    └── 十字光标（长按时绘制）
```

```swift
struct ChartViewport {
    let startIndex: Int
    let visibleCount: Int
    let pixelShift: CGFloat
    let geometry: ChartGeometry
    let priceRange: PriceRange
    let mainChartFrame: CGRect
}

struct ChartGeometry {
    let candleStep: CGFloat
    let candleWidth: CGFloat
    let gap: CGFloat
}

struct PriceRange: Equatable {
    var min: Double
    var max: Double
    
    /// 计算可见范围的价格区间，包含蜡烛 + BOLL + MA66
    static func calculate(from candles: ArraySlice<KLineCandle>) -> PriceRange {
        guard !candles.isEmpty else { return PriceRange(min: 0, max: 1) }
        var lo = candles.map(\.low).min()!
        var hi = candles.map(\.high).max()!
        // 包含 BOLL 上下轨和 MA66，避免指标线被截断
        for c in candles {
            if let bu = c.bollUpper { hi = Swift.max(hi, bu) }
            if let bl = c.bollLower { lo = Swift.min(lo, bl) }
            if let ma = c.ma66 { hi = Swift.max(hi, ma); lo = Swift.min(lo, ma) }
        }
        lo *= 0.95
        hi *= 1.05
        return PriceRange(min: lo, max: hi)
    }
}
```

### 坐标映射：纯数学

**原则：X 轴永远用 Index 驱动，不用 datetime**（A 股有停牌/节假日，时间不连续）

```swift
struct CoordinateMapper {
    let viewport: ChartViewport
    
    func indexToX(_ index: Int) -> CGFloat {
        let raw = CGFloat(index - viewport.startIndex) * viewport.geometry.candleStep
        let scale = displayScale  // 从 UIView.traitCollection.displayScale 获取
        return round(raw * scale) / scale
    }
    
    func priceToY(_ price: Double) -> CGFloat {
        let frame = viewport.mainChartFrame
        let ratio = (price - viewport.priceRange.min)
                  / (viewport.priceRange.max - viewport.priceRange.min)
        let raw = frame.maxY - ratio * frame.height
        let scale = displayScale
        return round(raw * scale) / scale
    }
    
    func xToIndex(_ x: CGFloat) -> Int {
        viewport.startIndex + Int(floor(x / viewport.geometry.candleStep))
    }
    
    func yToPrice(_ y: CGFloat) -> Double {
        let frame = viewport.mainChartFrame
        let ratio = (frame.maxY - y) / frame.height
        return viewport.priceRange.min + ratio * (viewport.priceRange.max - viewport.priceRange.min)
    }
}
```

**关键设计点：**
* **亚像素对齐** `round(x * scale) / scale`，`displayScale` 从 `UIView.traitCollection.displayScale` 获取（非 `UIScreen.main.scale`）
* **绝对坐标计算**：永远用 `index * step`，不用累加
* **mainChartFrame 隔离**：Y 轴价格只在主图区域内

### 交互模式：三态状态机（每面板独立）

```swift
struct PanelViewState {
    var period: Period
    var interactionMode: ChartInteractionMode
    var visibleCount: Int
    var decelerationAnimator: DecelerationAnimator?
}

enum ChartInteractionMode {
    case autoTracking
    case freeScrolling(exactOffset: CGFloat)
    case drawing(snapshot: DrawingSnapshot)
}
```

| 状态 | 谁控制时间 | 谁控制视图 | 手势行为 |
|------|-----------|-----------|---------|
| **Auto-Tracking** | TickEngine | 系统（锁定最新 K 线） | Pan = 切到 Free，Pinch = 缩放 |
| **Free-Scrolling** | 已定格 | DecelerationAnimator + offset | 自由平移浏览历史 |
| **Drawing(snapshot)** | 已定格 | 已定格 | Pan = 绘线坐标捕捉 |

**状态转换规则：**

| 从 \ 到 | Auto-Tracking | Free-Scrolling | Drawing |
|---------|---------------|----------------|---------|
| Auto-Tracking | — | 用户单指左右滑动 | 用户点击激活绘线工具 |
| Free-Scrolling | 买入/卖出/持有/观察触发（强制） | — | 用户点击激活绘线工具 |
| Drawing | 绘线完成/取消 | ❌ 不允许 | — |

**买入/卖出/持有/观察触发时：两面板立即中断 free-scrolling，硬切 auto-tracking，无平滑过渡。** 交易是强意图信号，延迟会造成认知混乱。

---

## 二、项目结构

```
KlineTrainer/
├── KlineTrainer/
│   ├── App/
│   │   └── KlineTrainerApp.swift
│   ├── Models/
│   │   ├── KLineData.swift              # K线数据模型，datetime 为 Int64 Unix timestamp
│   │   ├── TrainingSet.swift
│   │   ├── TrainingRecord.swift          # GRDB Record，含 FeeSnapshot + 训练组关联
│   │   ├── TradeOperation.swift          # 逐笔交易记录（见 3.3 节详细定义）
│   │   ├── DrawingObject.swift           # DrawingAnchor + DrawingObject（见 3.3 节）
│   │   ├── FeeSnapshot.swift             # 费率快照
│   │   ├── PositionManager.swift         # 持仓管理（加权平均成本）
│   │   └── PendingTraining.swift         # 继续训练进度存储模型
│   ├── ViewModels/
│   │   ├── TrainingEngine.swift          # 训练核心引擎（@Observable）
│   │   ├── TickEngine.swift              # 时间引擎（advance/reset），唯一时间状态
│   │   ├── PanelViewState.swift          # 每面板独立状态（period/mode/zoom）
│   │   ├── TrainingFlowController.swift  # 协议 + Normal/Review/Replay 三实现
│   │   └── SettingsStore.swift           # 设置管理（@Observable）
│   ├── Views/
│   │   ├── HomeView.swift                # 首页
│   │   ├── TrainingView.swift            # 训练页面
│   │   ├── SettingsPanel.swift           # 设置小面板（弹出式）
│   │   ├── SettlementView.swift          # 结算弹窗
│   │   ├── PositionPickerView.swift      # 仓位选择 HUD（5档）
│   │   └── HistoryActionSheet.swift      # 历史记录点击→复盘/再来一次
│   ├── ChartEngine/
│   │   ├── Core/
│   │   │   ├── ChartViewport.swift
│   │   │   ├── CoordinateMapper.swift
│   │   │   ├── ChartInteractionMode.swift
│   │   │   └── DecelerationAnimator.swift
│   │   ├── KLineView.swift
│   │   ├── KLineView+Candles.swift
│   │   ├── KLineView+MACD.swift
│   │   ├── KLineView+Volume.swift
│   │   ├── KLineView+Crosshair.swift
│   │   ├── KLineView+Markers.swift       # 跨周期买卖标记
│   │   ├── ChartContainerView.swift       # UIViewRepresentable 桥接
│   │   └── DrawingTools/
│   │       ├── DrawingToolManager.swift
│   │       ├── KLineView+Drawings.swift
│   │       ├── RayTool.swift
│   │       ├── TrendLineTool.swift
│   │       ├── HorizontalLineTool.swift
│   │       ├── GoldenRatioTool.swift
│   │       ├── WaveRulerTool.swift
│   │       ├── CycleLineTool.swift
│   │       └── TimeRulerTool.swift
│   ├── Services/
│   │   ├── APIClient.swift
│   │   ├── TrainingSetDB.swift
│   │   └── CacheManager.swift
│   └── Assets.xcassets/

Backend/
├── docker-compose.yml
├── .env                                   # NAS_HOST, DB_URL 等集中配置
├── scripts/
│   ├── import_csv.py
│   └── generate_training_sets.py
├── training_sets/
└── app/
    ├── main.py
    ├── config.py                          # 从 .env 读取配置
    ├── models.py
    ├── routes.py
    ├── scheduler.py                       # APScheduler 每日 5:00 检查
    └── requirements.txt
```

---

## 三、数据存储设计

### 3.1 NAS 端（PostgreSQL）数据仓库

```sql
CREATE TABLE stocks (
    code VARCHAR(10) PRIMARY KEY,
    name VARCHAR(50) NOT NULL
);

CREATE TABLE klines (
    id BIGSERIAL PRIMARY KEY,
    stock_code VARCHAR(10) NOT NULL REFERENCES stocks(code),
    period VARCHAR(10) NOT NULL,       -- '1m','3m','15m','60m','daily','weekly','monthly'
    datetime BIGINT NOT NULL,          -- Unix timestamp（秒），Int64
    open DECIMAL(10,2) NOT NULL,
    high DECIMAL(10,2) NOT NULL,
    low DECIMAL(10,2) NOT NULL,
    close DECIMAL(10,2) NOT NULL,
    volume BIGINT NOT NULL,
    amount DECIMAL(16,2),              -- 成交额（需求 CSV 包含此字段）
    ticket_index INTEGER,              -- 1m 周期唯一，全局递增 0,1,2...
    ma66 DECIMAL(10,4),
    boll_upper DECIMAL(10,4),
    boll_mid DECIMAL(10,4),
    boll_lower DECIMAL(10,4),
    macd_diff DECIMAL(10,6),
    macd_dea DECIMAL(10,6),
    macd_bar DECIMAL(10,6),
    UNIQUE(stock_code, period, datetime)
);

CREATE INDEX idx_klines_lookup ON klines(stock_code, period, datetime);

CREATE TABLE training_sets (
    id SERIAL PRIMARY KEY,
    stock_code VARCHAR(10) NOT NULL,
    stock_name VARCHAR(50) NOT NULL,
    start_datetime BIGINT NOT NULL,
    end_datetime BIGINT NOT NULL,
    schema_version INTEGER NOT NULL DEFAULT 1,
    file_path VARCHAR(255) NOT NULL,
    content_hash VARCHAR(64),
    created_at TIMESTAMP DEFAULT NOW(),
    status VARCHAR(10) NOT NULL DEFAULT 'unsent'  -- unsent / reserved / sent
);
```

**关于 ticket_index 基准的说明：** 以 1 分钟 K 线为基准建立 ticket_index（3m 对应能被 3 整除的点，60m 对应能被 60 整除的点）。

### 3.2 训练组（独立 SQLite 文件）

每个训练组生成为一个独立 SQLite 文件（PRAGMA user_version 存储 schema_version），包含该次训练所需的所有周期数据。

```sql
-- schema_version 通过 PRAGMA user_version = N 设置

CREATE TABLE meta (
    stock_code TEXT NOT NULL,
    stock_name TEXT NOT NULL,
    start_datetime INTEGER NOT NULL,      -- Unix timestamp（秒）
    end_datetime INTEGER NOT NULL
);

CREATE TABLE klines (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    period TEXT NOT NULL,
    datetime INTEGER NOT NULL,            -- Unix timestamp（秒）
    open REAL NOT NULL,
    high REAL NOT NULL,
    low REAL NOT NULL,
    close REAL NOT NULL,
    volume INTEGER NOT NULL,
    amount REAL,                           -- 成交额
    ma66 REAL,
    boll_upper REAL,
    boll_mid REAL,
    boll_lower REAL,
    macd_diff REAL,
    macd_dea REAL,
    macd_bar REAL,
    global_index INTEGER,                  -- 最小周期唯一，全局递增 0,1,2...
    end_global_index INTEGER NOT NULL      -- 所有周期：该 K 线对应最后一根最小周期的 global_index
);

CREATE INDEX idx_period_endidx ON klines(period, end_global_index);
CREATE INDEX idx_period_datetime ON klines(period, datetime);
```

### 3.3 app.sqlite（训练记录、交易操作、设置、进度）

```sql
-- ============ 训练记录 ============
CREATE TABLE training_records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    training_set_filename TEXT NOT NULL,   -- 关联训练组 SQLite 文件名，复盘/再来一次用
    created_at INTEGER NOT NULL,           -- 训练结束时间 Unix timestamp
    stock_code TEXT NOT NULL,
    stock_name TEXT NOT NULL,
    start_year INTEGER NOT NULL,
    start_month INTEGER NOT NULL,
    total_capital REAL NOT NULL,           -- 本局结束时的总资金
    profit REAL NOT NULL,                  -- 本局盈亏额度
    return_rate REAL NOT NULL,             -- 本局收益率（如 0.05 = 5%）
    max_drawdown REAL NOT NULL,            -- 最大回撤（如 -0.12 = -12%）
    buy_count INTEGER NOT NULL,
    sell_count INTEGER NOT NULL,
    fee_snapshot TEXT NOT NULL             -- JSON: FeeSnapshot
);

-- ============ 逐笔交易记录 ============
CREATE TABLE trade_operations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    record_id INTEGER NOT NULL REFERENCES training_records(id),
    global_tick INTEGER NOT NULL,          -- 交易时的 globalTickIndex
    period TEXT NOT NULL,                  -- 操作所在周期
    direction TEXT NOT NULL,               -- 'buy' / 'sell'
    price REAL NOT NULL,                   -- 成交价（收盘价）
    shares INTEGER NOT NULL,               -- 成交股数
    position_tier TEXT NOT NULL,           -- '1/5','2/5',...'5/5'
    commission REAL NOT NULL,              -- 本笔佣金
    stamp_duty REAL NOT NULL,              -- 本笔印花税
    total_cost REAL NOT NULL,              -- 本笔总成本/到手金额
    created_at INTEGER NOT NULL
);

-- ============ 绘线数据 ============
CREATE TABLE drawings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    record_id INTEGER NOT NULL REFERENCES training_records(id),
    tool_type TEXT NOT NULL,               -- 'ray','trend','horizontal','golden','wave','cycle','time'
    panel_position INTEGER NOT NULL,       -- 0=上面板, 1=下面板
    is_extended INTEGER NOT NULL DEFAULT 0,
    anchors TEXT NOT NULL                  -- JSON: [DrawingAnchor]
);

-- ============ 继续训练进度 ============
CREATE TABLE pending_training (
    id INTEGER PRIMARY KEY CHECK (id = 1), -- 单行表，只有 0 或 1 行
    training_set_filename TEXT NOT NULL,
    global_tick_index INTEGER NOT NULL,
    upper_period TEXT NOT NULL,
    lower_period TEXT NOT NULL,
    position_data TEXT NOT NULL,            -- JSON: PositionManager 序列化
    fee_snapshot TEXT NOT NULL,             -- JSON: FeeSnapshot
    trade_operations TEXT NOT NULL,         -- JSON: [TradeOperation]
    drawings TEXT NOT NULL,                 -- JSON: [DrawingObject]
    started_at INTEGER NOT NULL,
    accumulated_capital REAL NOT NULL       -- 本局起始资金
);

-- ============ 设置 ============
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
-- key 包括：commission_rate, min_commission_enabled, stamp_duty_enabled,
--           total_capital, display_mode
```

### 3.4 Swift 数据模型

```swift
// === 费率快照 ===
struct FeeSnapshot: Codable {
    let commissionRate: Double      // 佣金费率（万分之X）
    let stampDutyEnabled: Bool      // 是否收印花税（0.05% 卖出）
    let minCommissionEnabled: Bool  // 是否最低 5 元佣金（免5=关闭此项）
}

// === 逐笔交易记录 ===
struct TradeOperation: Codable {
    let globalTick: Int
    let period: Period
    let direction: TradeDirection   // .buy / .sell
    let price: Double
    let shares: Int                 // 必须是 100 的整数倍（5/5 清仓除外）
    let positionTier: String        // "1/5" ~ "5/5"
    let commission: Double
    let stampDuty: Double
    let totalCost: Double
    let createdAt: Int64
}

// === 绘线锚点 ===
struct DrawingAnchor: Codable {
    let period: Period
    let candleIndex: Int            // 该周期内的 K 线索引
    let price: Double
}

// === 绘线对象 ===
struct DrawingObject: Codable {
    let toolType: DrawingToolType
    let anchors: [DrawingAnchor]
    let isExtended: Bool
    let panelPosition: Int          // 0=上面板, 1=下面板
}
```

### 3.5 数据流转

```
[CSV 原始数据]
    ↓ import_csv.py（pandas 清洗 + pandas-ta 计算指标 + 建立 ticket_index）
[PostgreSQL 全量 K 线数据]
    ↓ generate_training_sets.py（每周期独立按目标 bars 数查询 + 计算 end_global_index）
[独立 SQLite 文件] → PRAGMA user_version = schema_version → 压缩为 .zip
    ↓ FastAPI 文件下载（租约模型）
[iPad 下载 .zip] → 验收状态机 → 解压存入 App 沙盒
    ↓ GRDB 一次性全量加载 → 内存数组 allCandles[period]
[TickEngine → BinarySearch → PanelViewState → Viewport → Mapper → Rendering]
```

---

## 四、核心逻辑设计

### 4.0 架构核心原则（时间轴驱动系统）

```
Backend（Python）
    → 预处理 global_index / end_global_index
Memory（iOS 启动训练时一次性加载）
    → allCandles[period]
TickEngine（唯一时间状态，全局共享）
    → globalTickIndex
BinarySearch（纯函数，tick → endIndex）
    ↓
PanelViewState × 2（每面板独立 period/mode/zoom）
    ↓
Viewport（计算属性 + Fractional Offset）
    → startIndex / visibleCount / pixelShift
CoordinateMapper（纯数学，业务数据 → 像素网格）
    → index→X, price→Y
KLineView（Phase 1 纯 draw，按需引入 Bitmap Cache）
    ← DecelerationAnimator offset
```

```swift
struct TickEngine {
    private(set) var globalTickIndex: Int = 0
    let maxTick: Int

    mutating func advance(steps: Int = 1) -> Bool {
        guard globalTickIndex < maxTick else { return false }
        globalTickIndex = min(globalTickIndex + steps, maxTick)
        return true
    }

    mutating func reset(to tick: Int) {
        globalTickIndex = max(0, min(tick, maxTick))
    }
}
```

### 4.1 多周期联动步进

6 个周期从小到大：3m → 15m → 60m → 日 → 周 → 月

**步进规则（需求 3.7）：** 点击某周期的买入/卖出/持有/观察按钮 → globalTickIndex 推进 N 步 → 所有周期自动联动。

**步进量计算（统一二分查找，零线性扫描）：**

```swift
func stepsForPeriod(_ period: Period) -> Int {
    let candles = allCandles[period]!
    let currentTick = tickEngine.globalTickIndex
    // 二分查找：找到 end_global_index > currentTick 的第一根 K 线
    let nextIdx = candles.binarySearch { $0.end_global_index > currentTick }
    guard nextIdx < candles.count else { return 0 }
    return candles[nextIdx].end_global_index - currentTick
}
```

**联动效果（由 end_global_index 驱动，iOS 端零硬编码）：**
- 低级别周期：每步都自然追加 K 线
- 高级别周期：只在 end_global_index <= globalTickIndex 时新增 1 根
- 例如：60m 按钮步进 → globalTickIndex 推进到下一根 60m 的 end_global_index → 15m 自动 +4 根、3m 自动 +20 根、日线视情况 +0 或 +1

### 4.2 交易计算

**免5 与印花税是两个独立设置：**
- **免5开关（min_commission_enabled）：** 关闭=免5（佣金按实际金额，无最低限制）；开启=不免5（佣金不足 5 元按 5 元收）
- **印花税：** A 股卖出时固定收取 0.05%，始终计算，不可配置

```
=== 买入 ===
目标金额 = 总资金 × 仓位比例（1/5, 2/5, 3/5, 4/5, 5/5）
原始股数 = floor(目标金额 / 买入价)
买入股数 = floor(原始股数 / 100) × 100      ← A股100股整数倍取整
  若买入股数 = 0，提示"资金不足"，交易取消
买入金额 = 买入股数 × 买入价
买入佣金 = 买入金额 × 佣金费率
  若「min_commission_enabled」= true 且佣金 < 5：佣金 = 5
买入总成本 = 买入金额 + 买入佣金
现金余额 -= 买入总成本

=== 卖出 ===
卖出仓位语义：1/5~5/5 相对**当前持仓股数**计算
目标股数 = 持仓股数 × 仓位比例
卖出股数 = floor(目标股数 / 100) × 100      ← 100股整数倍取整
  若 5/5（清仓）：卖出股数 = 全部持仓（不取整，允许零股清仓）
  若卖出股数 = 0 且非清仓，提示"持仓不足"，交易取消
卖出金额 = 卖出股数 × 卖出价
卖出佣金 = 卖出金额 × 佣金费率
  若「min_commission_enabled」= true 且佣金 < 5：佣金 = 5
印花税 = 卖出金额 × 0.0005（0.05%，仅卖出时收取，始终计算）
卖出实际到手 = 卖出金额 - 卖出佣金 - 印花税
现金余额 += 卖出实际到手
```

**持仓管理（加权平均成本法）：**

```swift
struct PositionManager {
    private(set) var shares: Int = 0           // 当前持仓股数
    private(set) var averageCost: Double = 0   // 加权平均成本（含佣金，每股）
    private(set) var totalInvested: Double = 0 // 累计买入总成本
    
    mutating func buy(shares: Int, totalCost: Double) {
        let newTotal = totalInvested + totalCost
        let newShares = self.shares + shares
        averageCost = newTotal / Double(newShares)
        self.shares = newShares
        totalInvested = newTotal
    }
    
    mutating func sell(shares: Int) {
        self.shares -= shares
        totalInvested = averageCost * Double(self.shares)
        if self.shares == 0 {
            averageCost = 0
            totalInvested = 0
        }
    }
    
    /// 持仓成本 = 当前持仓股数 × 加权平均成本
    var holdingCost: Double { averageCost * Double(shares) }
    
    /// 当前仓位档位（0~5）
    var positionTier: Int {
        // 根据实际持仓比例映射到最接近的档位
        // 具体实现取决于初始资金和当前持仓
        0
    }
}
```

**无效操作处理：**
- **空仓点卖出：** 卖出按钮灰置（disabled），不可点击
- **满仓（5/5）点买入：** 买入按钮灰置（disabled），不可点击
- **资金不足（买入股数取整后为 0）：** 弹出 Toast 提示"资金不足，无法买入"
- **持仓不足（卖出股数取整后为 0 且非清仓）：** 弹出 Toast 提示"持仓不足"

**最大回撤计算：**

```swift
var peakCapital: Double = initialCapital
var maxDrawdown: Double = 0.0  // 负值，如 -0.12 = -12%

func updateDrawdown(currentCapital: Double) {
    if currentCapital > peakCapital { peakCapital = currentCapital }
    let drawdown = (currentCapital - peakCapital) / peakCapital
    if drawdown < maxDrawdown { maxDrawdown = drawdown }
}
```

**自动结束时持仓处理：** 当 `globalTickIndex >= maxTick` 时，若用户仍有持仓，**按最后一根最小周期 K 线的收盘价强制全部平仓**（计算佣金和印花税），然后进行结算。

### 4.3 跨周期买卖标记同步

需求 3.7："同时在**所有周期**此价格对应的K线处进行标记。"

**实现方案：** TrainingEngine 维护一个全局 `markers: [TradeMarker]` 数组：

```swift
struct TradeMarker {
    let globalTick: Int        // 交易时的 globalTickIndex
    let price: Double          // 成交价
    let direction: TradeDirection  // .buy / .sell
}
```

每个周期的 KLineView 渲染时，遍历 markers，通过 `end_global_index` 找到对应该 globalTick 的 K 线（二分查找），在该 K 线的收盘价 Y 轴位置绘制标记：
- 买入：红点 + 大写字母「B」
- 卖出：绿点 + 大写字母「S」

标记在所有 6 个周期的图表上同步显示，不仅限于操作所在的周期。

### 4.4 多周期展示布局

屏幕分上下两区域，各显示一个周期的 K 线图。

**初始周期组合：上区 60m，下区 日线**

**两指上下滑动切换，完整序列：**

```
3m / 15m  ←→  15m / 60m  ←→  60m / 日  ←→  日 / 周  ←→  周 / 月
```

两指上滑：向右（周期变大），两指下滑：向左（周期变小）

**每个 K 线图区域内容（从上到下，高度比例 60:15:25）：**

```
┌─────────────────────────────────────────────────┬─────┐
│  主图（60%）                                      │ 买入 │
│  K线行情图（红涨绿跌）                             │ 卖出 │
│  + MA66（亮橙色）                                 │持有/观察│
│  + BOLL（灰色虚线，上/中/下轨）                    │     │
│  + 买卖标记（红点B / 绿点S）                       │     │
│  ────────────────────────────────────────────    │     │
│  交易量柱状图（15%）                               │     │
│  ────────────────────────────────────────────    │     │
│  MACD子图（25%）（柱子 + DIF白线 + DEA黄线）        │     │
└─────────────────────────────────────────────────┴─────┘
```

**双面板 Y 轴各自独立计算**，Phase 5 可选"锁定 Y 轴"功能。

---

## 五、训练流程控制

### 5.0 TrainingFlowController

```swift
protocol TrainingFlowController {
    var mode: TrainingMode { get }
    func canBuySell() -> Bool
    func canAdvance() -> Bool
    func shouldSaveRecord() -> Bool
    func shouldAccumulateCapital() -> Bool
    func shouldShowSettlement() -> Bool
}

enum TrainingMode {
    case normal      // 正常训练
    case review      // 复盘（只读）
    case replay      // 再来一次（可操作，不保存）
}
```

**Capability Matrix：**

| 能力 | Normal | Review | Replay |
|------|--------|--------|--------|
| K线图渲染 | ✅ | ✅ | ✅ |
| 买入/卖出/持有/观察按钮 | ✅ | ❌（隐藏） | ✅ |
| 绘线工具 | ✅ | ✅（只读，不可新增） | ✅ |
| 仓位选择弹窗 | ✅ | ❌ | ✅ |
| TickEngine 可步进 | ✅ | ❌（固定最终态） | ✅（从头开始） |
| 结束按钮 | ✅ | ❌（用返回退出） | ✅ |
| 训练记录写入 | ✅ | ❌ | ❌ |
| 总资金累加 | ✅ | ❌ | ❌ |
| 总出次+1 | ✅ | ❌ | ❌ |
| 触觉反馈 | ✅ | ❌ | ✅ |
| 结算弹窗 | ✅ | ❌ | ✅（显示但不保存） |
| 费率来源 | 当前设置 | 原局 FeeSnapshot | 原局 FeeSnapshot |

---

## 六、页面 UI 详细设计

### 6.1 首页（HomeView）

#### 6.1.1 顶部统计栏

```
┌──────────────────────────────────────────────┐
│  总局次：N 局    胜率：X%    总资金：¥ XXX,XXX  │
└──────────────────────────────────────────────┘
```

- **总局次**：所有正式训练记录条数
- **胜率**：盈利局数 / 总局次（profit > 0 的记录数 / 总记录数）
- **总资金**：初始 10 万，每局正式结束后累加盈亏

#### 6.1.2 「开始训练」/「继续训练」按钮

- **默认状态**：显示「开始训练」
- **有未完成训练时**（pending_training 表有数据）：显示「继续训练」
- 点击「开始训练」：从离线缓存中随机选 1 个训练组，加载后跳转训练页
- 点击「继续训练」：从 pending_training 恢复进度，跳转训练页
- **离线缓存为空时**：点击「开始训练」弹出提示"暂无可用训练数据，请先在设置中下载离线缓存"

#### 6.1.3 训练历史列表

位于按钮下方，可上下滚动。每条记录独占一行，按时间**从新到旧**排列。
无记录时显示占位文字"暂无训练记录"。

**每行记录展示内容：**

```
[日期时间]  [股票名称（代码）]  [起始年月]  [总资金]  [盈亏]  [收益率]
例：2024-03-15 14:32  贵州茅台（600519）  2021年08月  ¥102,345  +¥2,345（+2.3%）
```

- 日期时间：训练结束时的时间戳
- 起始年月：训练组起始时间对应的 K 线年份和月份
- 总资金：本局结束时的总资金
- 盈亏：本局净盈亏额 + 收益率
  - **颜色：正数红色，负数绿色**（A 股标准：红=赚钱，绿=亏钱）

**点击一条历史记录 → 弹出提示框：**

| 选项 | 行为 |
|------|------|
| **复盘** | 进入训练页（Review 模式），显示该局结束时完整状态，只读浏览 |
| **再来一次** | 进入训练页（Replay 模式），重玩同一训练组，结束后不保存/不计入统计。使用原局 FeeSnapshot |

#### 6.1.4 齿轮按钮

- 位置：屏幕**右上角**，齿轮图标
- 点击弹出小型设置面板，点击面板外消失

---

### 6.2 训练页面（TrainingView）

#### 6.2.1 顶部信息栏

```
┌──────────────────────────────────────────────────────────────────┐
│ [返回]  ¥总资金  持仓成本¥X  仓位 X/5  收益率 +X.XX%        [画线] │
└──────────────────────────────────────────────────────────────────┘
```

- **返回按钮**：位于顶部最左侧
- **总资金**：本局实时总资金（现金 + 持仓市值）
- **持仓成本**：当前持仓的加权平均成本总额（含佣金）。无持仓时显示 ¥0
- **仓位**：当前持仓档位，以"X/5"表示
- **收益率**：本局至今的净收益率（含佣金和印花税）
- **绘线工具按钮**：位于顶部最右侧

**点击返回按钮：** 保存进度到 pending_training 表，返回首页，按钮变为「继续训练」。

#### 6.2.2 底部结束按钮

- 位置：屏幕**底部左侧**
- 点击弹出确认「结束本局训练」→「是」/「否」
  - 「是」：若有持仓，先按最后收盘价强制平仓；弹出结算窗口
  - 「否」：对话框消失

#### 6.2.3 双K线图区域

屏幕除顶栏外的剩余区域**平均分为上下两块**，各显示一个周期 K 线图。

每块包含（高度比 60:15:25）：
1. **主图**：K 线（红涨绿跌）+ MA66（亮橙色）+ BOLL（灰色虚线）+ 买卖标记
2. **成交量柱**
3. **MACD**（柱状图 + DIF 白线 + DEA 黄线）

#### 6.2.4 每个K线区域的右侧按钮组

纵向排列 3 个图标按钮：买入、卖出、持有/观察。

- **买入按钮**：空仓或未满仓时可用（否则灰置）。点击弹出仓位选择 HUD
- **卖出按钮**：有持仓时可用（否则灰置）。点击弹出仓位选择 HUD
- **持有/观察按钮**：始终可用。直接推进 1 根当前周期 K 线。**有仓位时显示为"持有"图标，空仓时显示为"观察"图标**

**仓位选择 HUD：**

```
[ 1/5 ]  [ 2/5 ]  [ 3/5 ]  [ 4/5 ]  [ 5/5 ]
```

点击某档位后确认交易，面板消失。

**买入/卖出确认后：**
1. 调用 `UIImpactFeedbackGenerator`（.heavy）震动反馈
2. `TickEngine.advance(steps: N)`
3. 两面板立即硬切 `autoTracking`
4. 在**所有周期**的对应 K 线上同步标记红点B / 绿点S

#### 6.2.5 自动结束训练

当 `globalTickIndex >= maxTick` 时自动结束：
1. 若有持仓，按最后收盘价强制平仓
2. 弹出结算窗口
3. 确认后保存记录、清除 pending_training、返回首页

#### 6.2.6 绘线工具面板

点击顶部「画线」按钮，弹出面板，7 种绘线类型独立开关：

```
射线         [开/关]    — 2个锚点，从第一点过第二点延伸
趋势线       [开/关]    — 2个锚点，连线
水平线       [开/关]    — 1个锚点，水平延伸
黄金分割线   [开/关]    — 2个锚点，自动绘制 0/23.6/38.2/50/61.8/100% 水平线
波浪尺       [开/关]    — 多个锚点（3~N），连线+标注
周期线       [开/关]    — 2个锚点，等间距垂直线
时间尺       [开/关]    — 2个锚点，测量时间跨度
```

- 打开开关 → 该工具快捷按钮显示在**顶栏画线按钮旁边（水平排列）**
- 同一时间只能激活一种绘线工具
- 进入 Drawing 模式，Pan 手势被绘线截获
- **长按已有绘线可选中并删除**（弹出小菜单"删除"）

---

### 6.3 结算小窗口（SettlementView）

```
┌─────────────────────────────┐
│         本局结算             │
│                             │
│  股票：贵州茅台（600519）     │
│  起始：2021年08月            │
│                             │
│  总资金：¥ 102,345.67        │
│  总收益率：+2.34%            │  ← 需求明确要求
│  最大回撤：-8.32%            │
│  买入次数：4 次               │
│  卖出次数：3 次               │
│                             │
│         [ 确认 ]             │
└─────────────────────────────┘
```

点击「确认」：
1. Normal 模式：保存记录到 app.sqlite，返回首页
2. Replay 模式：不保存，直接返回首页

---

### 6.4 设置面板（SettingsPanel）

弹出小面板，点击面板外消失。从上到下：

| 控件 | 说明 |
|------|------|
| **佣金费率** 按钮 | 弹出输入框，修改佣金费率（初始值 1，单位万分之一），精确到小数点后 3 位，不能为空 |
| **免5** 开关 | 关闭=免5（佣金无最低 5 元限制）；开启=不免5（佣金最低 5 元） |
| **重置资金** 按钮 | 弹出二次确认，确认后将总资金重置为 10 万元（不清空训练记录） |
| **离线缓存** 按钮 | 弹出输入框，输入下载数量（整数 1~20），确认后向 NAS 请求，显示进度条 |
| **显示模式** 按钮 | 白天模式 / 夜间模式 / 跟随系统 |

**说明：** 印花税（0.05% 卖出）始终生效，无需开关。

---

## 七、触控交互

| 手势 | 行为 | 实现 |
|------|------|------|
| 两指捏合/张开 | K 线缩放（以捏合焦点为中心） | UIPinchGestureRecognizer |
| 单指左右滑动 | K 线平移（切到 Free-Scrolling） | UIPanGestureRecognizer + DecelerationAnimator |
| 两指上下滑动 | 切换周期组合 | UIPanGestureRecognizer (touches=2)，主方向判定 |
| 长按 | 十字光标，松手退出 | UILongPressGestureRecognizer |
| 单指点击 | 绘线模式下确定锚点 | UITapGestureRecognizer |
| 长按绘线 | 选中绘线→弹出删除菜单 | UILongPressGestureRecognizer (Drawing 模式) |

**斜向滑动消歧：** 两指滑动时取主方向（|dx| > |dy| → 忽略，|dy| > |dx| → 切周期），避免意外触发。

---

## 八、后端

### 8.1 FastAPI 接口

**所有配置（NAS_HOST、DB_URL、TRAINING_SETS_DIR 等）集中于 `.env` 文件，便于日后迁移服务器。**

```
GET /training-sets/meta?count=N
    请求：{ count: N }
    响应：{
        "lease_id": "uuid-string",
        "expires_at": "2026-04-11T05:10:00Z",  // TTL 10 分钟
        "sets": [
            {
                "id": 42,
                "stock_code": "600519",
                "stock_name": "贵州茅台",
                "filename": "ts_42_600519.zip",
                "schema_version": 1,
                "content_hash": "sha256hex..."
            },
            ...
        ]
    }
    效果：标记这 N 个训练组为 "reserved"

GET /training-set/{id}/download
    响应：训练组 SQLite .zip 文件流

POST /training-set/{id}/confirm?lease_id=X
    效果：标记为 "sent"，幂等（重复 confirm 返回 200）

定时任务（APScheduler，每天北京时间 5:00）：
    1. reserved 超 TTL 未 confirm → reset 为 "unsent"
    2. 检查 unsent 数量，若 <= 40，生成新训练组补充至 100 个
```

### 8.2 下载验收状态机（客户端）

```
[idle] → GET meta → [reserved(lease_id, expires_at)]
       → download zip → [downloaded]
       → verify zip CRC → [crc_ok] / [crc_fail → delete → 跳过继续下一个]
       → GRDB open → [db_ok] / [db_fail → delete → 跳过]
       → check PRAGMA user_version (schema_version) → [verified] / [schema_mismatch → delete → 跳过]
       → check 3m 数据量 > 0 → [data_ok] / [empty → delete → 跳过]
       → POST /confirm(lease_id) → [confirmed]
```

- 下载并发度：默认 1，可配 2
- 失败包单独跳过继续下一个，不阻塞队列
- 本地训练组超 20 个时，被动 LRU 淘汰最久未访问的（lastAccessedAt）

### 8.3 generate_training_sets.py 逻辑

```python
def generate_one_training_set(stock_code):
    # Step 1: 基于月线确定可用范围，随机选起始点
    monthly = query("... period='monthly' ORDER BY datetime")
    # 要求起始月K线之前至少 30 根月K线，之后至少 8 根月K线
    start_idx = random.randint(30, len(monthly) - 9)
    start_datetime = monthly[start_idx].datetime

    # Step 2: 每个周期独立按目标 bars 数查询
    period_configs = {
        'monthly': {'before': 'ALL', 'after_minutes': 8},  # 所有月线（不限数量）
        'weekly':  {'before': 120,    'after_minutes': 8},
        'daily':   {'before': 150,    'after_minutes': 8},
        '60m':     {'before': 150,    'after_minutes': 8},
        '15m':     {'before': 150,    'after_minutes': 8},
        '3m':      {'before': 150,    'after_minutes': 8},
    }
    # "after" 的含义：起始时间之后 8 根月 K 线的时间窗口内，
    # 该周期包含的所有 K 线。（不是每个周期固定 8 根）

    for period, cfg in period_configs.items():
        all_bars = query(f"... period='{period}' AND stock_code='{stock_code}' ORDER BY datetime")
        pivot = binary_search(all_bars, start_datetime)
        before_count = pivot if cfg['before'] == 'ALL' else min(pivot, cfg['before'])
        
        # "after" 根据 8 根月 K 线的时间窗口计算
        monthly_after = query("... period='monthly' AND stock_code=... AND datetime >= start_datetime ORDER BY datetime LIMIT 8")
        after_end_time = monthly_after[-1].datetime
        after_bars = [b for b in all_bars[pivot:] if b.datetime <= after_end_time]
        
        # 硬校验
        assert before_count >= 30, f"Not enough {period} bars before start"
        assert len(after_bars) >= 1, f"Not enough {period} bars after start"

    # Step 3: 基于最小周期建立 global_index（0, 1, 2, ...）
    # Step 4: 高级别周期通过 datetime 二分匹配计算 end_global_index
    # Step 5: 写入 SQLite（PRAGMA user_version = SCHEMA_VERSION）+ 压缩 .zip
```

**关键改动 vs v1.1：**
1. 月线取**起始前所有**（不限 120 根）
2. "之后"数据由 8 根月 K 线的时间窗口决定（不是每个周期固定 8 根）
3. 起始条件：**30 根月K线**（不是 30 根分钟 K 线）
4. 每周期独立按目标 bars 数查询（不由最小周期窗口派生）
5. end_global_index 通过 datetime 二分匹配（不依赖周期间固定倍数）
6. 硬校验不满足 → 跳过该股票重新选

---

## 九、分阶段实施计划

### Phase 0：后端基础

1. NAS 上 docker-compose 部署 PostgreSQL
2. 编写 `.env` 配置文件（集中 NAS_HOST、DB_URL 等）
3. 编写 `import_csv.py`：CSV → pandas 清洗 → pandas-ta 计算指标 → 建立 ticket_index → 入库（含 amount 成交额字段）
4. 编写 `generate_training_sets.py`：月线选起始点 → 每周期独立查询 → 计算 global_index / end_global_index → 写入 SQLite（PRAGMA user_version）→ 压缩 → 生成 100 个训练组
5. 编写 FastAPI 服务（预占-确认三态 API + 下载接口 + APScheduler 定时任务）
6. Docker 部署 FastAPI
7. 手动检查 3-5 个训练组数据正确性（SQLite 客户端打开验证）

### Phase 1：iOS 项目骨架 + K 线自绘引擎

1. Xcode 新建项目，配置 iOS/iPadOS 17+ 部署目标
2. 搭建 MVVM 目录结构，SPM 引入 GRDB
3. 定义数据模型（KLineData datetime=Int64, TrainingSet, FeeSnapshot 等）
4. 实现 APIClient（对接 FastAPI 预占-确认三态 + 下载验收状态机）
5. 实现数据加载（GRDB 读取训练组 SQLite → allCandles[period] + DEBUG 单调性校验）
6. 实现 ChartEngine/Core（ChartViewport、CoordinateMapper、PanelViewState）
7. 定义颜色常量（红涨绿跌、MA66 橙色、BOLL 灰色等），Phase 5 切主题时只改常量
8. 实现 Core Graphics 自绘引擎 KLineView（Phase 1 纯 draw，无 Bitmap）：
   - KLineView+Candles：行情图（红涨绿跌）+ MA66 + BOLL
   - KLineView+Volume：交易量柱
   - KLineView+MACD：MACD 子图（柱子 + DIF 白线 + DEA 黄线）
   - PriceRange 包含 BOLL/MA66 范围
9. 实现手势系统：
   - UIPanGestureRecognizer + DecelerationAnimator（含 sceneDidBecomeActive reset）
   - UIPinchGestureRecognizer → 缩放（以焦点为中心）
   - UILongPressGestureRecognizer → 十字光标
   - 手势仲裁规则（见一、手势方案节）
10. UIViewRepresentable 封装（ChartContainerView），注意 @Observable 桥接刷新
11. 实现双周期上下分栏 + 两指上下滑动切换周期组合

### Phase 2：训练核心逻辑

1. 实现 TickEngine（advance/reset）
2. 实现纯函数数据管道（Binary Search → getVisibleSlice → Viewport）
3. 实现多周期联动步进（统一二分查找）
4. 实现 PositionManager（加权平均成本、100 股取整、买入/卖出语义）
5. 实现交易计算（佣金 + 免5 + 印花税 + 最大回撤实时追踪）
6. 实现 FeeSnapshot 序列化/反序列化
7. 实现 TradeMarker + 跨周期买卖标记同步（KLineView+Markers）
8. 实现买卖按钮状态管理（空仓灰置卖出、满仓灰置买入）
9. 实现三态交互模式 + 模式切换规则
10. 自动结束训练检测（含强制平仓）
11. 结算弹窗（股票名称/代码、起始年月、总资金、总收益率、最大回撤、买入/卖出次数）
12. 触觉反馈（UIImpactFeedbackGenerator，.heavy）

### Phase 2.5：最简绘线工具验证

1. 实现 ChartInteractionMode.drawing 状态机
2. 实现水平线绘制工具（1 个锚点）
3. 验证 Drawing 模式下 Pan 手势截获正确
4. 验证绘线坐标存储（DrawingAnchor { period, candleIndex, price }）和跨缩放/平移还原

### Phase 3：页面与交互完整实现

1. HomeView：统计栏、开始/继续训练、历史列表（含收益率、红盈绿亏颜色）、复盘/再来一次
2. TrainingView：顶栏（持仓成本）、双 K 线区域、仓位选择 HUD、底部结束按钮
3. SettingsPanel：佣金费率、免5、重置资金、离线缓存（进度条）、显示模式
4. TrainingFlowController + Normal/Review/Replay 三实现
5. GRDB 模型定义 + 训练记录/交易操作/绘线数据 CRUD
6. 训练进度保存/恢复（pending_training 表）
7. 离线缓存下载（验收状态机 + 并发度可配 + 失败跳过 + LRU 淘汰）
8. 历史记录复盘（Review 模式，还原全部标记和绘线）
9. 「再来一次」（Replay 模式，复用原局 FeeSnapshot）

### Phase 4：绘线工具（完整）

1. DrawingToolManager（工具选择、互斥、快捷按钮显示在顶栏画线按钮旁）
2. 6 种剩余绘线工具实现（射线、趋势线、黄金分割、波浪尺、周期线、时间尺）
3. 绘线数据保存到 drawings 表
4. 长按绘线选中 → 删除功能
5. 复盘时绘线还原（通过 CoordinateMapper 将 (period, candleIndex, price) 映射回屏幕坐标）

### Phase 5：磨光

1. 白天/夜间/跟随系统显示模式（切换颜色常量）
2. UI 细节（图标、间距、字体）
3. 性能优化（Instruments Profiler，单帧 >4ms 时引入 Bitmap Cache）
4. 边缘 bounce 动画（DecelerationAnimator 扩展）
5. 边界情况处理（训练组损坏、下载中断、磁盘不足）
6. 统一错误处理策略（网络错误 Toast、数据解析失败提示、SQLite 损坏自动清理重下）
7. iPad 横竖屏策略（v1 锁定竖屏，上架前评估横屏需求）

---

## 十、验证方案

| 验证项 | 方法 |
|--------|------|
| CSV 导入 | PostgreSQL 数据条数、时间连续性、技术指标、ticket_index 递增、amount 字段完整 |
| 训练组生成 | 验证月线取全量（不截断）、起始前 ≥30 根月K线、"之后"数据符合月K线时间窗口 |
| API | curl 测试租约模型完整流程：meta → download → confirm，验证幂等和超时回退 |
| K 线渲染 | 对比东方财富/同花顺截图，验证行情图/指标/交易量/MACD 显示正确 |
| PriceRange | 验证 BOLL 上轨和 MA66 不被截断在可视区域外 |
| 手势 | iPad mini 7 测试：DecelerationAnimator 惯性滚动、Pinch 缩放、十字光标、两指切周期、斜向消歧 |
| 多周期联动 | 60m 步进 → 验证 15m/3m 自动新增正确数量、日线视情况 +0/+1 |
| 交易计算 | 手动计算若干组买卖：100股取整、佣金/免5/印花税、加权平均成本、盈亏 |
| 最大回撤 | 构造已知峰谷资金序列，验证数值 |
| 跨周期标记 | 在 60m 买入 → 验证 3m/15m/日/周/月 对应 K 线均出现红点B |
| 无效操作 | 空仓点卖出（灰置）、满仓点买入（灰置）、资金不足弹 Toast |
| 自动结束 | 步进到 maxTick，有持仓时验证强制平仓 + 结算数据正确 |
| 复盘 | 完成训练 → 点复盘 → 验证标记/绘线完整还原 + 按钮隐藏 + 不可步进 |
| 再来一次 | Replay → 验证记录数/总资金/总局次均不变 + 使用原局费率 |
| 继续训练 | 中途返回 → 继续 → 验证 globalTickIndex/持仓/绘线恢复正确 |
| 结算弹窗 | 验证股票/起始年月/总资金/**总收益率**/最大回撤/买卖次数均正确 |
| 下载验收 | 模拟 zip 损坏、schema 不匹配、空数据 → 验证自动跳过不阻塞 |
| 盈亏颜色 | 验证历史列表：正数红色、负数绿色 |
| FeeSnapshot | 修改当前费率 → 复盘/再来一次 → 验证使用原局费率而非当前 |
| 渲染性能 | Instruments 验证 120Hz 无卡顿，Phase 1 纯 draw 单帧 <4ms |

---

## 十一、风险提示

1. **DecelerationAnimator 后台恢复**（已解决）：`sceneDidBecomeActive` 时 reset，dt > 1s 时直接 stop
2. **PriceRange 与 BOLL/MA66 协调**（已解决）：calculate 包含指标极值，5% padding
3. **后端 Index 预计算**：global_index / end_global_index 必须严格递增；后端 assert + 前端 DEBUG 校验
4. **A 股异常数据**：停牌/分红/数据缺失 → 依赖后端 pandas 清洗处理
5. **CSV 数据量**：全市场 × 多周期，import_csv.py 需异步批处理
6. **训练组 SQLite 完整性**（已解决）：完整验收状态机（CRC → GRDB → schema_version → 数据量）
7. **训练组版本兼容**：schema_version 不匹配时客户端拒收删除，向后兼容
8. **NAS 不可达**：App 支持纯离线运行（仅使用已缓存训练组），网络错误统一 Toast 提示
9. **1 分钟 index 基准**：数据源需包含 1 分钟 K 线 CSV
