# 划线工具扩充 · P1c 第 1 片 spec：样式矩阵结构泛化（为四个新工具让路）

- **上游母 spec**：`docs/superpowers/specs/2026-07-04-drawing-tools-expansion-design.md`（D1–D22）
- **上游 P1b 拆分补充**：`docs/superpowers/specs/2026-07-10-drawing-tools-P1b-split-addendum.md`（D23–D43）
- **上游 P1c 拆分补充**：`docs/superpowers/specs/2026-08-25-drawing-tools-P1c-split-addendum.md`（D104–D111，PR #176 已合入 main）
- **本 spec 新增决策编号：D112 起。**

**基线**：`origin/main` @ `1437529`（2026-08-30）。本文件所有「实测」陈述均在该 commit 上核实，逐条给出 `文件:行`。

> ⚠️ 上游 P1c 拆分补充的基线是 `a018a7f`。main 此后走过 `ad84865` / `25424fd` / `1437529` 三次合并，**行号已漂移**。本 spec 引用的一律是 `1437529` 上重新核过的行号，**不得回头照抄上游行号**。

---

## 0. 本片是什么

**一句话**：把「本构建懂每个划线工具的哪些**样式语义**」从**散落在四处的写死判据**收成**一张表**，表的内容一行不变（今天仍只有水平线）⇒ **对用户零可见变化**，但第 4/5/6 片每加一个工具从「改四处代码」变成「加一行」。

> ⚠️ 上游 §2A.1 第 5 项列的是「五处」，本片只做**样式那四处**；第五处（落锚的 `minAnchors`）**不属于样式**，且与既有的 `DrawingTool.requiredAnchors` 契约冲突 ⇒ 移交第 4 片，见 **D119**。

**本片不产生任何用户可见变化。**

---

## 1. 本 spec 对上游 P1c 拆分补充的取代（D112–D116）

> ⛔ **上游拆分补充 §2A / §2B / D105 不变量 4 / D109c 关于第 1 片的内容，在下列范围内被本 spec 取代。**
> 上游文件已合入 main（PR #176），**不修改它**；后续任何实现者读到那几节时，一律以本节为准。
> 取代的授权来源：上游 §12 逐字「⛔ 任何实现者都不得把 P1c 的任意两片合并成一个 PR，**除非重走一次本文件这样的拆分论证并拿到 user 同意**」—— 本节就是那次论证，user 已于 2026-08-30 逐条拍板。

### D112　范围重定：第 1 片从「跨版本兼容地基」缩为「样式矩阵结构泛化」

**上游 §2A.1 列了六项**。本 spec 保留**第 5 项**，删除其余五项（逐条理由见 D113–D115）。

**片名同步改**：「1A 兼容地基（零 UI）」→ **「第 1 片：样式矩阵结构泛化」**。第 1B 片取消（D113）⇒ **七片变六片**：

| # | 片名 | 状态 |
|---|---|---|
| **1** | **样式矩阵结构泛化** | **本片** |
| 2 | 节点显示 + 选中态终局 | 不变 |
| 3 | 拖节点 + §14 手势分支 | 不变 |
| 4 | 多锚落点泛化 + 趋势线 | 不变（**新增三项交接**：样式面板三处 D116、`minAnchors` 单一真相 D119、标签布局 Q10；见 §8） |
| 5 | 通道线 + 箱体 | 不变 |
| 6 | 折线 + 临时 4 键 + 删单节点 | 不变 |

**依赖链**：1 → 2 → 3 → 4 → 5 → 6。上游 D109/D109b 关于第 2–6 片的全部结论**原样有效**，本 spec 一字不改。

---

### D113　取消第 1B 片；归档死锁记为**知情接受的残留**（user 2026-08-30 拍板）

> **⛔ 复核状态（给后续评审轮次与实现者看，请先读这一段再决定是否重提）**：
> 本条经过**两次** user 拍板。第一次基于本 spec 上一稿的威胁模型；codex R1-high 指出其中「数据跟着手机走」措辞错误（**该指正成立，已按下文订正**）后，**user 于 2026-08-30 在拿到订正后的事实（`app.sqlite` 随整机备份迁移；但常规恢复装的是该设备可用的最新版，故仅路径 c / e 会产生版本错位）之上复核并明确维持原决定**。
> ⇒ 这是**知情决策**，不是遗漏，也不是基于错误事实的决策。重提本条前，请先给出**上表五条路径之外的新触发路径**，或指出订正后的事实仍有错 —— 仅重述「备份会迁移数据」不构成新信息。

**上游的设计**：那道「未支持数据挡住归档」的门（`TrainingSessionCoordinator.swift:741-745`）会把用户卡死且无出口 ⇒ 1A 造一个「持久删除 API」，1B 给它接上界面（提示 + 删除入口 + 结算失败弹窗第三动作）。

**推翻的依据**：user 要求先量清楚「这个死锁到底什么时候会真发生」。逐条实测的结论是**触发面比上游隐含的窄得多**：

| 实测事实 | 出处 |
|---|---|
| **全仓零账号、零登录** —— `signIn` / `login` / `logout` / `userId` / `accountId` / `authToken` / `AppleID` / `ASAuthorization` 全仓（排除 `.build`、排除测试）**零命中** | 全仓 grep |
| **训练记录与画线全在手机本地**，存 `app.sqlite`，位于 **Application Support** 目录 | `ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift:14-16` |
| **无任何跨设备同步机制**：`iCloud` / `CloudKit` / `NSUbiquitous` 全仓**零命中** | 全仓 grep |
| ⚠️ **但 `app.sqlite` 会随整机备份走**：它在 Application Support（iOS 备份**默认包含**该目录；默认被排除的是 Caches），且全仓**没有任何** `isExcludedFromBackup` 标记 | `KlineTrainerApp.swift:14-16` + 全仓 grep 零命中 |
| **后端只下载、不上传**：API 一共三个 —— 训练组清单 `training-sets/meta`、下载 `training-set/{id}/download`、下载完成回执 `training-set/{id}/confirm`。**没有任何接口上传训练记录或画线** | `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAPIClient.swift:33 / :49 / :69` |

⇒ **数据不跟账号走**（无账号、无云同步、后端不上传）。

**⚠️ 但「数据只留在这一台手机上」是错的**（codex R1-high，**已核实为真**；本 spec 上一稿写作「数据跟着手机走」，措辞错误，据此修正）：整机备份**会**把 `app.sqlite` 一起带走，恢复到另一台设备上。

**⇒ 因此判据不是「数据会不会离开这台手机」（会），而是「数据落地的那台设备上，App 版本是不是比写它的那个版本旧」。**

**⚠️ 常规换机 / 恢复备份并不产生版本错位**：iOS 恢复时 App 是**由 App Store 重新下载该设备可用的最新版**，不是把备份里那台设备当时的旧二进制搬过去。所以「数据比 App 新」只在下表这几种情况下出现：

| # | 路径 | 判断 | user 的应对（2026-08-30 逐条给出） |
|---|---|---|---|
| a | **开发 / 真机验收阶段**：第 4 片之后回头验收前面几片的构建、或切分支跑测试 | 几乎必然 | 「删掉 App 重新装就好了」 |
| b | **TestFlight 版 → 装回 App Store 正式旧版** | 可能 | 「基本上也就是我自己用」 |
| c | **备份 / 迁移落到一台只装得到更旧版本的设备**：App Store 对系统版本过老的设备只提供「最后一个兼容的旧版」 | 窄，但真实存在 | 「让用户升级就好了」 |
| d | 第三方降级工具 | 罕见 | 「不考虑」 |
| **e** | **开发者主动把 App Store 上可下载的版本回退到更早的二进制**（撤下新版、重新发布旧构建）后，用户恢复备份时拿到那个更旧的二进制 | 极窄，且**完全在开发者自己控制之下** | **本 spec 新增**（上一稿漏列）。应对 = 真要回退版本时，先确认没有跨版本数据 |

**⛔ 上游 D105 不变量 4「不得存在用户无法解除的归档死锁」在本 spec 中被降为「知情接受的残留」**，理由三条：

1. **那道门今天就在跑着，本片一行不改** —— 取消 1B 不是「拆掉安全网」，而是「不给已存在的门配钥匙」。合并后 main 上的行为与今天**逐字节相同**。
   **⚠️ 但必须把这个残留的真实代价写准**（codex R2-high 的事实半边，**已核实为真**；本 spec 上一稿只写「一局白打」，**说轻了**）：撞上时，`结算入账失败` 弹窗只有两个按钮（`UI/TrainingView.swift:169-176`）——「重试」撞同一道门**永远失败**，「放弃」走 `discardSession()` → **`pendingRepo.clearPending()`**（`TrainingSessionCoordinator.swift:1000-1018`）**永久删除整局 pending**，含那些未来数据的原始字节。
   ⇒ 残留的准确表述是：**「用户被界面推向一个破坏性动作，而被删掉的这一局，在他按下去之前本来是可以靠装回较新版本的 App 完整救回来的。」** 界面上唯一的非破坏性出路是**强行退出 App、不去碰它**。
   ⇒ 因此那道门的实际作用是**把「静默的永久丢失」换成「用户亲手选择的永久丢失」**，它**并不阻止**丢失。⛔ 后续任何人不得把它描述成「已经保住了数据」。

   **⚠️ 但那个弹窗本身的可达性同样必须量清楚**（否则会把一个几乎到不了的路径当成常见故障来加固）。逐条实测：

   - **弹窗只有一个来源** —— `runFinalize()` 的 `catch`（`UI/TrainingView.swift:644-655`）；
   - **到达 `runFinalize` 只有两条路**：① 步进到最后一根 K 线自动结束（`maybeAutoEnd`，`:323` / `:371`）；② 手动「结束本局」→ 确认框点「是」（`:224-225` → `endManually`）。第三条是弹窗自己的「重试」；
   - **只有正常训练局会走** —— `routeEndOfSession`（`:659-663`）把 replay 分流到 `runReplaySettlement`；review 不可达（`shouldAutoFinalize` 抑制 + `forceCloseManually` 对 review 返 false）；
   - **在那一刻能抛错的全部位置**（`coordinator.finalize`，`:685-780`）：

     | # | 原因 | 现实可达性 |
     |---|---|---|
     | 1 | **未支持数据那道门**（`:741-743`） | **今天不可达**（需比本构建更新的版本写出的数据）；将来仅限 D113 上表五条路径 |
     | 2 | `reconciled` 抛（重复 / 空 id，`:737-740`） | 极罕见，属数据损坏 |
     | 3 | 缺活跃会话上下文（`:754`） | 属内部 bug |
     | 4 | `reader.loadMeta()` 抛（`:756`） | 训练组文件损坏 / 丢失 |
     | 5 | **`finalizeSession` 单事务写库失败**（`:778`） | ⚠️ **唯一现实可达的一条**：磁盘满 / DB 损坏 / IO 错误 |

   ⇒ **对 P1c 而言，原因 1 今天触发不了，这正是 D113 取舍成立的量化依据。**
   ⇒ **但原因 5 是真会发生的**，而它撞上的是同一个弹窗与同一个破坏性「放弃」—— 那条问题**不属于 P1c**，另立 §8-Q13。
2. **⛔ 绝不得反过来把那道门拆掉** —— 它的存在理由是「未来数据随 pending 永久丢失」（`TrainingSessionCoordinator.swift:696-703` 的大注释）。拆门 = 一次不可逆的数据丢失（上游记录的 codex R1-high 方向），本 spec **不授权任何人这么做**。
3. **将来想补不会变贵**：那道门还在、`.unknownRaw` 与已知条的未来字段都是**原文照抄**（`LossyDrawingArray.swift:348 / :355`）不会丢失 ⇒ 任何时候补「可分辨信号 + 恢复通道」都是纯增量，不存在「现在不做以后就补不上」的缝。

**⛔ 一处必须澄清的因果**（针对 codex R1-high 的措辞「会把正常兼容状态变成不可归档或数据丢失」）：**不成立。** 本片对那道门与它的全部行为**一行不改**，合并后与今天 `main` 上的表现**逐字节相同** —— D113 只是**不去新增**一个恢复出口，而不是新造一个失败。真正会造成数据丢失的动作是**拆掉那道门**，本 spec §2 硬约束 1 明令禁止，且本片不碰它。

**⚠️ 这一条与已记录的项目原则「App 可能公开上架 → 持久化按公开发布标准做、版本错位真会发生、勿按单用户简化」存在张力。** 本条**不推翻**那条原则（持久化保真、契约、迁移纪律一律照旧），只对**这一个具体出口**做了成本/触发面权衡：user 在拿到上表四条路径的实测结论后作出判断。**记录在此，便于日后复核。**

**受此影响一并取消的**：上游 §2A.1b 全节（持久删除 API 七条硬要求）、§2A.3 的 N10 / N11 / N11b / N12 / N13 / N14 / N15 / N16、§2B 全节、§8 表格中「③ → 1A 建立事实 + 1B 兑现机制」那一行的 1B 半边。

---

### D114　不引入可分辨的失败信号；因此**不 bump** `CONTRACT_VERSION`

上游 §2A.1 第 3 项要求：那道门不得继续复用 `.dbCorrupted`，须引入一个可分辨的新信号，好让 UI 判断该不该给「第三个按钮」。

**取消理由**：那个信号的**唯一消费方**就是 1B 的第三个按钮。1B 取消后，**没有任何代码会读它** —— 落地即死代码，且它是 1A 唯一改变既有语义的一项，反而要付「逐个核对五处 `.dbCorrupted` 消费方」的举证成本。

**⚠️ 顺带订正上游一处不准确**：上游 §2A.1 第 3 项与 §2A.3-N5 点名的「靠丢弃来恢复」的 `.dbCorrupted` 消费方是**三处**（`SettingsStore.swift:126`、`TrainingSessionCoordinator.swift:873`、`:1385`）。**实测是五处** —— 上游漏了两处经 `AppError.isDBCorrupted`（`AppError.swift:130`）间接匹配的：

| # | 消费方 | 丢弃动作 |
|---|---|---|
| 1 | `Settings/SettingsStore.swift:125`（`isDBCorrupted`，用于 `:169` / `:185`） | 写回默认设置 |
| 2 | `TrainingSessionCoordinator.swift:389` | `clearWorking`（清复盘草稿列） |
| 3 | `TrainingSessionCoordinator.swift:448` | `clearSaved`（清复盘定稿列） |
| 4 | `TrainingSessionCoordinator.swift:873` | 清损坏的 pending 槽 |
| 5 | `TrainingSessionCoordinator.swift:1385`（`isCorruptTrainingSet`） | 删训练组缓存文件 + `clearReplay` |

**⛔ 将来若有人重启这个信号，必须按五处核，不是三处。** 本条记录在此就是为了那一天。

**因此不 bump**：上游 §11.1 把 bump 的**唯一**触发理由写成「1A 改变了 `finalize` 未支持数据的处置语义（m01 §Bump 策略 A 类）」。该语义改动取消 ⇒ 触发条件不成立。本片对照 m01 §Bump 策略逐条核：

| Bump 触发条件 | 本片是否命中 |
|---|---|
| 影响 DDL / 新表 / DML 清理 migration | ❌ 无任何迁移，`user_version` 维持 **8** |
| 跨系统字段 / OpenAPI 变更 | ❌ 不碰后端 |
| Codable 字段变更 | ❌ 不增删任何 `DrawingObject` / `PendingTraining` / `PendingReplay` 字段 |
| 扩展 / 收缩枚举值域 | ❌ `DrawingToolType` **十三个** case 一字不改（`Models.swift:39` 的十一个目标工具 + `:41` 的两个 legacy `ray` / `time`）；`implemented` 仍是 `[.horizontal]`（`Models.swift:50`） |
| 改既有语义 | ❌ **本片全部改动行为等价**（§5-T1 穷举举证） |

⇒ **`CONTRACT_VERSION` 维持 `"1.13"`，m01 矩阵不动、不写 bump 记录。**

**⛔ 不得援引本条把上游「①记账义务」当成被永久豁免**：它只是**没有触发**，不是被取消。第 4 片首次写出 `.trend` 时是否触发，由那一片按 m01 §Bump 策略自行论证（上游 §11.1 已给出「不该单独触发」的逐条理由，本 spec 不改那个结论）。

---

### D115　不变量 1–3 与结构损坏边界：**实测已被现有测试覆盖，本片不补**

上游 §2A.1 第 1、2 项要求补测锁死三条不变量与「`.unknownRaw` 恒等于正面识别的未来工具记录」。逐条去现有测试里找对应后，**绝大部分已经存在**：

| 上游要求的档 | 现有测试 | 出处 |
|---|---|---|
| N6 —— `[not-json]` → 抛 `.dbCorrupted` | ✅ 已有 | `Tests/.../Drawing/DrawingModelP1aTests.swift:139` |
| N6 —— 标量 `[123]` | ✅ 已有 | `:147` |
| N6 —— 空对象 `[{}]`（无 toolType） | ✅ 已有 | `:155` |
| N6 —— 已知工具缺必填字段 | ✅ 已有 | `:174` |
| N6 —— 已知工具字段类型错 | ✅ 已有 | `:182` |
| N6 **正向档**（真·未来工具 → 确归 `.unknownRaw`） | ✅ 已有 | `:163` |
| N6 **反向对照**（已知工具真损坏 → 仍 `.dbCorrupted`，不被放宽） | ✅ 已有 | `:217` |
| 不变量 2「未注册工具不可命中」**含反向对照** | ✅ 已有（`unregisteredToolNeverHits`，`:58` 是防「一律不命中」骗过的反向档） | `Tests/.../Drawing/DrawingHitTesterTests.swift:51-58` |
| 不变量 3 保序 | ✅ 已有 | `DrawingModelP1aTests.swift:236` |
| 不变量 3 未来字段逐字节保留 | ✅ 已有 | `:274` |
| 不变量 3 删别的已知条后未来条仍在原位 | ✅ 已有 | `:456` |
| 不变量 3（持久层两条路） | ✅ 已有 | `Tests/KlineTrainerPersistenceTests/PendingLossyTests.swift`、`CoordinatorLossyPreserveTests.swift`、`ReviewArchiveRepositoryTests.swift` |
| **不变量 1「未注册工具不渲染」**（空注册表 → 渲染器零调用） | ✅ **已有，且是 UIKit 真跑档** | `Tests/.../Drawing/DrawDrawingsDispatchTests.swift:49`（`§5.3 #16 missing tool in dictionary skips silently`） |
| 不变量 1 **正向对照**（注册了的工具 → 渲染器恰好一次、且拿到的就是那条 drawing） | ✅ 已有 | 同文件 `:30`（`§5.3 #15`） |
| 不变量 1 **空列表对照** | ✅ 已有 | 同文件 `:17`（`§5.3 #14`） |
| **「生产渲染注册表里确实没有 `.trend`」**（把「模拟旧构建」这个前提本身钉死） | ✅ 已有 | `Tests/.../Render/KLineViewCompileTests.swift:39`（`L8c 契约`） |

⇒ **四条不变量与结构损坏边界全部已有测试覆盖，本片一条都不补。**

**⚠️ 上面最后四行是 codex R1-medium 逼出来的订正 —— 本 spec 上一稿把不变量 1 写成「无直接行为测试」，那是错的。** 记下经过，因为它是一个会重犯的检索错误：我当时的搜索词是 `unregistered` / `未注册` / `无渲染器` / `notRegistered`，而那条测试叫 **`drawDrawingsMissingToolSkipsSilently`**（用的是 `Missing`）。**按「概念」搜而不按「该概念在本仓的全部书写形态」搜，会把已存在的覆盖判成缺口，进而写出重复测试或错误的取舍论证。**

**这四条不但存在，还被 CI 必需门逐条点名**（比「存在」强一个量级）：

- `.github/scripts/catalyst-uikit-baseline.txt` 逐行列着 `§5.3 #14 / #15 / #16` 与 `L8c 契约: 生产渲染注册表里确实没有 .trend`；
- 闸门 `catalyst-gate.sh` 的 G8 逐测试判据读这份**签入仓库、与当前源码解耦**的基线（`catalyst-uikit-baseline-reader.py` 头注逐字说明为何不能对当前 checkout 活推导：那是循环论证），日志里找不到对应 `passed` 行就 FAIL 并点名；
- 而 CI 的 Catalyst job **早已是真跑 `xcodebuild test`**，不是只编译 —— `catalyst-build.yml:23-24` 逐字：「名字里的 "build-for-testing" 是历史遗留：本 job 现在**真跑 test**」。

⇒ 每个 PR 都在真执行这四条并要求它们 passed。**本片不需要为不变量 1 做任何事，但 §7.2 的三绿门必须跟着改**（见那一节）。

---

### D116　「五处」实测是「五处 + 样式面板三处」；面板三处**交接给第 4 片**

上游 §2A.1 第 5 项列了**五处**要泛化。实测：这五处之外，**常驻样式面板里还有三处直接套了水平线专用规则**：

| # | 位置 | 调的是哪个（水平线专用）版本 |
|---|---|---|
| 面板① | `UI/DrawingStyleParams.swift:39` | `horizontalLineSubTypeEnabled($0)` —— 线型组的灰态判据 |
| 面板② | `UI/DrawingStyleParams.swift:46` | `normalizedLabelMode(current:lineSubType:)`（**两参**横线版） |
| 面板③ | `UI/DrawingStyleParams.swift:142` | `horizontalLabelModeEnabled(mode, lineSubType:)` —— 标注组的灰态判据 |

**本片不动它们**，三条理由：

1. **它是界面**：`DrawingStyleParams.swift:9` 是 `#if canImport(UIKit)` 的 SwiftUI `View`。本片零 UI。
2. **泛化不动**：该 View **根本不知道自己在编辑哪种工具** —— 它只收 `style: DrawingDefaultStyle` 与 `enabled: Bool`（`:16` / `:20`），没有 `toolType`。要泛化必须改它的参数签名 = 真界面手术 + Catalyst 基线同步。
3. **第 4 片本来就必须改它**：第 4 片要让面板显示趋势线的三种线型子类，非改不可。现在改一半、那时再改一次，反而是两次手术。

⇒ **作为硬约束交接给第 4 片**（§8-Q8）。**今天不构成缺陷**：表里只有水平线，面板拿横线规则算横线，结果正确。

**本片范围之外、但第 4 片起必须处理的「水平线专属耦合」完整清单**：

> **⚠️ 本表经两种写法穷尽扫描**（codex R5-high 逼出来的订正 —— 本 spec 上一稿只列了前两行，因为我**只按 `== .horizontal` 这一种写法搜**，漏掉了「直接调用 `HorizontalLineTool.某函数`」那一整类）。
> **⛔ 这是本 spec 第二次栽在同一个形状上**（第一次见 D115：搜 `unregistered` 漏掉 `MissingTool`）。**扫描必须按「该概念在本仓的全部书写形态」穷尽，不能按概念名搜一遍就收工。** 本表用的两个搜索式：`== \.horizontal` 与 `HorizontalLineTool`。

| # | 位置 | 是什么 | 归属 |
|---|---|---|---|
| 1 | `Drawing/DrawingLabelLayout.swift:64 / :66` | `guard drawing.toolType == .horizontal else { return nil }`（价格标签内容） | 第 4 片（Q10） |
| 2 | `Render/KLineView+Drawing.swift:33-34` | `if drawing.toolType == .horizontal` + `HorizontalLineTool.visibleGeometry`（渲染层画价格标签的分支） | 第 4 片（Q10） |
| **3** | **`Drawing/DrawingEditRouter.swift:50`** | `selectionGeometryVisible` —— **「屏幕上真看得见吗」这条通用判据，用的却是水平线专属几何**。它是**改样式 / 删除 / 锁定**三个动作的共同前提 | **第 4 片（Q16，新增）** |
| **4** | **`Drawing/DrawingEditRouter.swift:203`** | 改线型子类时，候选对象必须有可见几何，否则**拒绝改样式** | **第 4 片（Q16）** |
| **5** | **`Drawing/DrawingEditRouter.swift:321`** | 落线提交路径上的「不可见画线不落库」门 —— 不通过就**清掉选中、不落库** | **第 4 片（Q16）** |
| 6 | `Render/KLineView.swift:47` | 渲染注册表 `[.horizontal: HorizontalLineTool()]` | 第 4 片起逐个注册新工具（已在上游 D109 各片范围内） |
| — | `Drawing/DrawingStyleIconSpec.swift:19 / :25` | 引用 `HorizontalLineTool.dashPattern` / `.lineWidth` 生成样式图标 | **判定：不需要泛化。** 虚线间隔与粗细档位→线宽是**工具无关**的视觉规格（所有工具用同一套），该文件头注也写明「刻意派生自渲染层、不另写一张表」。⛔ 若日后某工具真需要不同线宽，那一片自己论证后再动，**本片与第 4 片都不得顺手改它** |

---

## 2. 跨版本兼容现状核实表（交接材料，零代码）

> **本节不要求本片写任何代码。** 它是把上游第 1 片本来打算「用测试钉死」的那些事实，改成**一份核实过的清单**交给第 2–6 片。上游 §2A.1 第 1、2 项被 D115 取消后，这份表就是它们的替代物。

**「本版本不支持的画线」有两类**（沿用上游 D105 的分类，**分类本身没有变**）：

| 类别 | 成因 | 本构建的表现 |
|---|---|---|
| **(a) 可解码、本构建无渲染器** | `toolType` 是**已声明**的枚举 case（`Models.swift:39` 十一个目标工具 + `:41` 两个 legacy，共 **13** 个），但 `KLineView.drawingTools` 注册表里没有它 | 渲染 dispatch 静默跳过（`Render/KLineView+Drawing.swift:25`）；`DrawingHitTester.firstHit` 恒返 false（`Drawing/DrawingHitTester.swift:26`） |
| **(b) 本构建不认识这个工具名** | `toolType` 不在本构建枚举里 → 进 `LossyDrawingArray` 的 `.unknownRaw` 分支 | 连 `engine.drawings`（已知投影）都进不去 |

**四条事实（逐条在 `1437529` 上核实）**：

| # | 事实 | 判据在哪 | 被哪些测试锁住 |
|---|---|---|---|
| F1 | **不渲染** | `Render/KLineView+Drawing.swift:25` | `DrawDrawingsDispatchTests.swift:49`（空注册表 → 渲染器零调用）+ `:30` 正向对照 + `:17` 空列表对照；另有 `KLineViewCompileTests.swift:39` 钉死「生产注册表里确实没有 `.trend`」。**四条均在 `catalyst-uikit-baseline.txt` 被逐条点名，CI 每个 PR 真跑并要求 passed** |
| F2 | **不可命中**，与渲染 dispatch **逐字同判据** | `Drawing/DrawingHitTester.swift:26`（`:23` 注释逐字写明同判据） | `DrawingHitTesterTests.swift:51-58`（含反向对照）+ `:61-80`（源码守卫：命中入口唯一 + 必来自 `visibleDrawings`） |
| F3 | **不被普通保存覆盖**：`.known` 未编辑 → 原样 `raw`；`.unknownRaw` → 原位保留 | `Persistence/LossyDrawingArray.swift:348` / `:355` | `DrawingModelP1aTests.swift:236 / :274 / :456` + `PendingLossyTests` / `CoordinatorLossyPreserveTests` / `ReviewArchiveRepositoryTests` |
| F4 | **`.unknownRaw` 恒等于「正面识别的未来工具记录」**：须同时满足①合法 JSON 对象 ②非空 `toolType` 字符串 ③该名不在本构建枚举里；任一不满足 → 抛 `.dbCorrupted` | `Persistence/LossyDrawingArray.swift:143-147` | `DrawingModelP1aTests.swift:139 / :147 / :155 / :163 / :174 / :182 / :217`（正反两档齐） |

**归档阻塞的真实判据**（`TrainingSessionCoordinator.swift:741-743`，本片**一行不改也不新增**）：

```swift
if !effectiveLossy.unknownRaw.isEmpty
    || effectiveLossy.hasKnownFutureFields(liveIds: liveIds)
    || effectiveLossy.hasKnownFutureEnumValues(liveIds: liveIds) {
    throw AppError.persistence(.dbCorrupted)
}
```

**⛔ 三条硬约束（沿用上游，第 2–6 片一律适用）**：

1. **不得拆掉这道门** —— 拆门 = 未来数据随 pending 永久丢失（D113 理由 2）。
2. **不得新增以「有没有渲染器」为判据的阻塞** —— 那会造出一个今天并不存在的死锁（上游 codex R2-high 点名的失败形态）。
3. **不得把这类数据的用户文案说成「读不懂 / 损坏」** —— 准确说法是：**读得出这是一条画线，只是不认识它用的工具**（上游 D105）。

**为什么这道门只在正常训练局生效（实测，上游未写）**：

| 对局 | 画线最终存到哪 | 该处能否承载 `.unknownRaw` | 会不会撞到这道门 |
|---|---|---|---|
| **正常训练** | 永久记录表 `drawings`，**逐字段列**：`id / record_id / tool_type / panel_position / is_extended / anchors / reveal_tick / style_json / draw_uuid`（`AppDBMigrations.swift:219-229`） | ❌ 它存的是**解码后的已知投影**；`.unknownRaw` 从不进入 `engine.drawings`，未来字段在解码时即被忽略 | ✅ **会**（门就在 `finalize` 里） |
| **回放** | `pending_replay` 槽，画线是**一整段 JSON 原文** | ✅ 原样进出 | ❌ `finalize` 首行对 `shouldSaveRecord()==false` 提前返回（`TrainingSessionCoordinator.swift:686`；`ReplayFlow.shouldSaveRecord()==false`，`TrainingFlowController.swift:106`）⇒ **永远撞不到** |
| **复盘** | 记录上的 `saved` / `working` 两列，**一整段原文**（`Persistence/ReviewArchiveRepository.swift:100` 逐字：「接收完整 lossy（含 unknownRaw 有序），原样保真回写」） | ✅ 原样进出 | ❌ 全仓 `unknownRaw` 判据**只有** `TrainingSessionCoordinator.swift:741` 一处 |

⇒ **分界线不是「存不存档」，而是「存进去的那个地方是否原文照抄」。**

---

## 3. 本片做什么

### D117　泛化的目标形状：**一张按工具查的样式表**，**四处**从它取值

> **⚠️ 本条较上一稿窄化：锚数（`minAnchors`）已移出本片**，理由见紧随其后的 **D119**（codex R2-medium，**已核实为真**）。上游 §2A.1 第 5 项列的是「五处」，本片只做其中**四处**（全部是样式语义），第 5 处（锚数）归第 4 片。

**今天的形状（两处写死 `.horizontal` + 两处派生）**：

| # | 位置 | 今天怎么写的 |
|---|---|---|
| ① | `Drawing/DrawingStyleAvailability.swift:19` | `guard toolType == .horizontal else { return true }` 之后套横线子类规则 |
| ② | `Drawing/DrawingStyleAvailability.swift:60` | `guard toolType == .horizontal else { return current }` 之后套横线 labelMode 规则 |
| ③ | `Drawing/DrawingStyleAvailability.swift:30` | `static let toolsWithStyleMatrix: Set<DrawingToolType> = [.horizontal]`（**第二份**写死的工具清单） |
| ④ | `Drawing/DrawingStyleAvailability.swift:48-49` | `isEditableToolType` = `implemented.contains ∧ toolsWithStyleMatrix.contains` |

**目标形状（示意，具体由 plan 定）**：

```
一行 = 一个工具，本构建懂它的哪些【样式语义】：
    renderableLineSubType : (LineSubType) -> Bool             // 【有效性】这个值会不会让线画不出来 ⇒ 该不该拒收
    labelModeEnabled      : (LabelMode, LineSubType) -> Bool   // 【归一化】不可用的标注回落 .hidden

今天表里只有一行：.horizontal → (横线子类规则, 横线标注规则)
```

**⛔ 第一列的命名是 load-bearing 的，见紧随其后的 D120 —— 它是「有效性」，不是「UI 灰态」。**

改法：

- ① → 查表；**表里没有这个工具 → 返回 `true`**（与今天 `guard ... else { return true }` 逐字等价）
- ② → 查表；**表里没有 → 原样返回 `current`**（与今天逐字等价）
- ③ → **从表的键派生**（`Set(表.keys)`），不再是第二份写死清单
- ④ → 表达式**一字不改**（它读的 `toolsWithStyleMatrix` 现在是派生值）

**⚠️ 表放在哪**：锚数移出后，这张表**纯粹是样式语义** ⇒ **就放在 `DrawingStyleAvailability` 里**，**不新建文件**（上一稿建议新建中性命名文件，唯一理由是「表里含锚数、放在『样式可用性』里会误导」；该理由随 D119 一并消失）。这样也免掉「新文件出现在源码守卫的 grep 命中里」这一层需要额外实跑确认的风险。**⛔ 横线的两条规则函数体仍必须留在 `DrawingStyleAvailability.swift` 原地**（§3.2 硬约束 1）。

---

### D119　`minAnchors` **移出本片**，锚数的单一真相是 `DrawingTool.requiredAnchors`（第 4 片落实）

**codex R2-medium 指出的冲突，逐条核实为真**：

| 实测事实 | 出处 |
|---|---|
| `DrawingTool` 协议**早就有** `requiredAnchors: ClosedRange<Int>` | `Drawing/DrawingTool.swift:17` |
| `HorizontalLineTool` **已实现**它，值为 `1...1` | `Drawing/HorizontalLineTool.swift:13` |
| 已有测试断言它 | `Tests/.../Drawing/HorizontalLineToolTests.swift:23`、`DrawingProtocolTests.swift:20 / :30-33` |
| `DefaultDrawingInputController` 里那份 enum→锚数映射**自己的注释就承认是重复的**：「MVP 显式映射 enum→最小锚数（`requiredAnchors` 是 tool 实例属性、非 enum 可达）」 | `DefaultDrawingInputController.swift:4` / `:38` |
| 上游 P1c 拆分补充把「**`requiredAnchors` 单一真相**」明确划给**第 4 片** | 上游 D109 第 4 片行 / §5.1 |

⇒ 若本片把锚数放进新表，仓里会同时存在**三份**同一个数字（协议实现 `1...1` / controller 映射 / 新表），而且本片的 T2 结构守卫会把「新表是权威」**钉死** —— 第 4 片必须先拆掉这条守卫才能兑现它的单一真相。**两片的要求直接互斥。**

**决定**：本片**完全不碰** `DefaultDrawingInputController` 与 `minAnchors`。锚数留在原地，由第 4 片按上游既定方案改成读 `DrawingTool.requiredAnchors`（经工具注册表），一次性消灭重复。

**⛔ 不得援引本条把锚数重复当成「可接受」** —— 它是**已登记的待消除重复**（§8-Q12），只是不归本片。

### D120　线型子类那一列**只表达「有效性」，绝不是 UI 灰态判据**（codex R3-high）

**codex R3-high 指出的缺陷，逐条核实为真**：一个布尔装不下两种含义。

| 实测事实 | 出处 |
|---|---|
| 母 spec §3.1 的**箱体**行 = `灰 / 灰 / 灰`（三个线型全灰）；**折线**行同样 `灰 / 灰 / 灰` | `2026-07-04-drawing-tools-expansion-design.md:100 / :106` |
| `DrawingObject.lineSubType` **非可选**，每条线都必带一个值（默认 `.straight`） | `Models/Models.swift:249 / :269` |
| `isRenderableSubType(_:toolType:)` 今天的消费方**全是写入闸、零个 UI**：落线 ×2（`guard … else { return false }`）、`withStyle`（`else { return nil }`）、`sanitized`（不可渲染则回落 `.straight`） | `TrainingEngine.swift:1157 / :1265 / :1299-1300`、`DrawingObjectStyleEdit.swift:17`、`DrawingEnums.swift:58` |
| 面板的灰态判据**是另一条路** —— 直接调横线专用函数，不经这个共享单点 | `UI/DrawingStyleParams.swift:39` |

⇒ 若把这一列同时当作 UI 灰态判据，箱体落地时只能二选一地坏掉：

- 箱体那行写成**三个全 false** → 它自带的 `.straight` 过不了 `TrainingEngine.swift:1157` 那道 `guard` → **箱体根本画不出来**（静默落线失败）；
- 写成 `.straight` 为 true 好让写入通过 → 面板会把「直线」显示成**可点** → 违反母 spec §3.1 的「整块灰」。

**⚠️ 今天看不出这个矛盾**，因为水平线的两件事**恰好重合**（`.segment` 既确实画不出、也确实该灰）。**只有「整块灰、但数据仍须能存」的工具才会暴露它** —— 箱体（第 5 片）与折线（第 6 片）正是。

**决定**：本表的线型子类列**语义严格限定为「有效性」** —— 回答的是「**这个值会不会让线画不出来、该不该拒收这条数据**」，命名与文档都必须体现（如 `renderableLineSubType`）。
**⛔ 任何人不得把这一列接到样式面板的灰态上。** UI 灰态是**另一个维度**，今天独立存在于面板内（`DrawingStyleParams.swift:39`），由第 4 片正式建立（§8-Q14）。

**可表达性演算（证明这个形状真装得下未来四个工具，不是嘴上说说）**：

| 工具 | 有效性列（会不会拒收） | UI 灰态（另一维，第 4 片起） | 母 spec §3.1 |
|---|---|---|---|
| 水平线（今天唯一一行） | 直✅ 射✅ 段❌ | 直✅ 射✅ **段灰** | **两者重合** ⇒ 今天看不出问题 |
| 趋势线（第 4 片） | 直✅ 射✅ 段✅ | 直✅ 射✅ 段✅ | 重合 |
| 通道线（第 5 片） | 直✅ 射✅ 段✅ | 同上 | 重合 |
| **箱体**（第 5 片） | **全 ✅** —— 该工具**忽略**这个字段，**不得据此拒收数据** | **全灰** | **必须分离** |
| **折线**（第 6 片） | **全 ✅**（同上） | **全灰** | **必须分离** |

**⚠️ 标注那一列没有这个毛病，⛔ 不要「顺手一起改」**：它喂的是 `normalizedLabelMode` —— 一个**归一化**函数（不可用就回落 `.hidden`），**不是拒收**。箱体/折线的标注整块灰 ⇒ 归一到 `.hidden` 即可，数据一条都不会被拒。**两列的机制不同，故只有线型那一列需要区分「有效性 / 灰态」。**

---

### D118　给 `DrawingToolType` 加 `CaseIterable`（纯加法，为了让 T1 的穷举是**真**断言）

**实测**：`DrawingToolType`（`Models.swift:37`）今天**不是** `CaseIterable` —— 它的遵从列表只有 `String, Codable, Equatable, Sendable`。而同一族的 `LineSubType`（`DrawingEnums.swift:6`）与 `LabelMode`（`:18`）**都是** `CaseIterable`。

**为什么这一个协议是 load-bearing 的**：T1 的全部价值在于「对**每一个**工具都断言了期望值」。若遍历源是测试文件里手写的十三元素数组：

1. 「数量 == 13」就退化成「测试断言自己写的那个字面量」= **恒真空转**（已知的七种撞法之一：自检本身空转）；
2. 第 4–6 片加工具时 T1 **不会**自动覆盖新工具 —— 它会安静地继续只测那 13 个，而漏掉的恰恰是新加的那一个。

加 `CaseIterable` 后 `allCases` 由编译器合成 ⇒ 数量断言是对**生产枚举**的真断言，且后续加工具自动进入覆盖面。

**为什么安全**：无关联值的 `String` raw-value 枚举，`allCases` 合成是机械的；纯加法的协议遵从，**不改任何既有行为**、不影响 `Codable` 编解码、不影响任何既有 `switch` 的穷尽性。

**不触发 bump**（补 D114 那张表）：`CaseIterable` **不扩展枚举的值域**（一个 case 都没加），也不属于 DDL / 跨系统字段 / Codable 字段变更 / 既有语义变更中的任何一类。

**⛔ 边界**：**只加协议遵从**。不得顺手改 case 名、次序、raw value，也不得动 `implemented` 的内容 —— 次序改变会改变 `allCases` 的顺序；legacy 的 `ray` / `time` 必须留在原位（`Models.swift:40-41` 的注释逐字说明它们是历史 blob 的容忍解码通道）。

### 3.1 等价性论证（为什么这四处改完行为一字不变）

三条改法的等价性**都依赖同一个前提**：**表的键恰好等于 `{.horizontal}`**。

- 前提今天成立：`toolsWithStyleMatrix` 今天就是 `[.horizontal]`（`:30`），`implemented` 也是 `[.horizontal]`（`Models.swift:50`）。
- 前提由**既有的漂移告警**继续守着：`DrawingObjectStyleEditTests.swift:82` 断言 `DrawingToolType.implemented == toolsWithStyleMatrix`。第 4 片若只把新工具加进 `implemented` 而没在表里加行，该断言当场红。
- 本片另加一条**穷举真值表测试**（§5-T1）把等价性直接钉死，不靠推理。

### 3.2 必须守住的既有闸门（改动不得让它们变红）

**⛔ 这四条不是建议，是本片的编译期/测试期边界。** 它们全部实测于 `DrawingObjectStyleEditTests.swift:172-241` 那条源码守卫与 `:82` 的漂移告警：

| # | 约束 | 出处 |
|---|---|---|
| 1 | `func horizontalLineSubTypeEnabled(` 与 `func horizontalLabelModeEnabled(` 在 `Sources/` 中**各恰好 1 处**，且都必须在 `DrawingStyleAvailability.swift` ⇒ **不得改名、不得删除、不得移文件** | `:198-201` |
| 2 | `func normalizedLabelMode(` **恰好 2 处**（两参横线版 + 三参 tool-aware 版），都在 `DrawingStyleAvailability.swift` ⇒ **两参版必须保留**（面板② 还在用它，D116） | `:203-204` / `UI/DrawingStyleParams.swift:46` |
| 3 | `horizontalLineSubTypeEnabled(` **不得**出现在 `TrainingEngine.swift` / `DrawingObjectStyleEdit.swift`；`horizontalLabelModeEnabled(` **不得**出现在 `DrawingObjectStyleEdit.swift`；两个写入边界必须经共享单点 `isRenderableSubType(` | `:227-241` |
| 4 | `withStyle` 里必须出现整段调用形状 `lineSubType: s.lineSubType, toolType: toolType`（锚点必须取整段，只锚 `toolType: toolType` 是恒真的） | `:220-224` |

**⚠️ 表就建在 `DrawingStyleAvailability.swift` 内部**（D117）⇒ 对 `horizontalLineSubTypeEnabled(` / `horizontalLabelModeEnabled(` 的引用**仍落在它们自己的定义文件里**，既有守卫的「各恰好 1 处 `func …(` 定义」与「不得出现在 `TrainingEngine.swift` / `DrawingObjectStyleEdit.swift`」两类判据都不受影响。**即便如此，plan 阶段仍必须把 §5-T3 那组守卫实跑一次，不得只靠推理。**

### 3.3 四处之外的**已知消费方**（改完必须逐个复核语义没变）

**⚠️ 守则：「有 N 个调用点」≠「这 N 处语义都一样」，必须逐个打开看。**

| 被改的函数 | 生产消费方 |
|---|---|
| `isRenderableSubType(_:toolType:)` | `TrainingEngine.swift:1157`（append 门）、`:1265`（append 门）、`:1299-1300`（私有 helper）、`Drawing/DrawingObjectStyleEdit.swift:17`（`withStyle` 可用性闸）、`Models/DrawingEnums.swift:58`（`sanitized(for:)`） |
| `normalizedLabelMode(current:lineSubType:toolType:)` | `Drawing/DrawingObjectStyleEdit.swift:37`、`Models/DrawingEnums.swift:65` |
| `normalizedLabelMode(current:lineSubType:)`（两参横线版） | `UI/DrawingStyleParams.swift:46`（**本片不动**，D116） |
| `isEditableToolType(_:)` | `TrainingEngine.swift:1193`（编辑门）、`Drawing/DrawingEditRouter.swift:81` |
| `horizontalLineSubTypeEnabled` / `horizontalLabelModeEnabled` | `UI/DrawingStyleParams.swift:39` / `:142`（**本片不动**，D116） |
| ~~`minAnchors(for:)`~~ | **本片不碰**（D119）—— `DefaultDrawingInputController.swift` 一个字都不改 |

---

## 4. 本片不做

- **任何界面改动**（样式面板三处写死横线规则 → 第 4 片，D116）；
- **不变量 1–3 与结构损坏边界的补测**（已有覆盖，D115）；
- **可分辨的失败信号 / 持久删除 API / 恢复通道 UI**（D113、D114 取消）；
- **`CONTRACT_VERSION` bump / m01 矩阵改动 / `user_version` 变更 / 任何迁移**（D114）；
- **归档阻塞判据一行不改、一条不加**（§2 硬约束 1、2）；
- 四个新工具的几何 / 注册 / 图标；节点；手势；多锚；折线；
- **`minAnchors` / `DefaultDrawingInputController.swift` 一个字都不改**（D119：锚数的单一真相是 `DrawingTool.requiredAnchors`，由第 4 片落实）；
- `DrawingLabelLayout.swift:66` 与 `KLineView+Drawing.swift:33` 两处 `.horizontal` 写死（属第 4 片起，D116）；
- 复盘侧的等价能力（属 P5）。

**⛔ 本片明确不解除归档死锁**（D113）。**spec / plan / PR 描述一律不得声称满足了上游 D105 的不变量 4。**

---

## 5. 必须存在的测试

> **纪律**：写每条断言先自问「**如果被测的那件事根本没发生，这条断言还会通过吗？**」已知的七种撞法：撞 no-op 守卫 / 撞出厂默认值 / 撞空栈 / 撞三元写法 / 撞终态相同 / 撞大小写 / 自检本身空转。

### T1　行为等价穷举真值表（**本片的核心举证，不可省**）

**不得**写成「泛化前后结果相同」（同一个构建里跑不出「前」）。**必须逐格断言具体期望值**，构成一张冻结的真值表：

| 分组 | 断言 | 格数 |
|---|---|---|
| T1a | `isRenderableSubType(sub, toolType: .horizontal)`：`.straight`✅ `.ray`✅ `.segment`❌ | 3 |
| T1b | `isRenderableSubType(sub, toolType: t)` 对**其余十二个** `DrawingToolType` × 三个 `LineSubType` **恒 true** | 36 |
| T1c | `normalizedLabelMode(current:lineSubType:toolType: .horizontal)` 的 **`LabelMode` × `LineSubType` 全笛卡尔积**，逐格给出期望值（`.show` 恒落 `.hidden`；`.left` 在 `.ray` 下落 `.hidden`，其余原样；`.hidden` / `.right` 恒原样） | 4×3 = 12 |
| T1d | 同上对**其余十二个**工具：**恒原样返回 `current`** | 12×12 = 144 |
| T1e | `isEditableToolType`：`.horizontal` ✅，其余十二个 ❌ | 13 |
| T1f | **本片不做**（D119：锚数移交第 4 片）。改为一条**自足的源码守卫**（⛔ **不得**写成「断言 branch-diff 里零改动」—— codex R4-medium **已核实为真**：CI 的 `actions/checkout` 未设深度（默认浅克隆，拿不到基准提交），且仓内**零先例**在 Swift 测试里跑 git ⇒ 那种断言要么在 CI 脆断、要么退化成证明不了该命题的替代物）。**改为三条自足断言**：① `Sources/` 中 `func minAnchors(` **恰好 1 处**且在 `DefaultDrawingInputController.swift` 内；② 该文件**不含**对新样式表的任何引用（结构断言，剥注释剥字面量）；③ **反向自检** —— 断言该文件确实被扫到（命中一个已知锚点，如 `func shouldCommit(`），防「路径写错 → 零命中 → 恒过」。⚠️「本片没改那个文件」这一事实由 **PR diff 与评审**承担，不由单元测试承担 | 3 |

**⚠️ 防空转三条（缺一不可）**：

1. **真值表必须同时含 ✅ 与 ❌**（T1a 的 `.segment`、T1c 的 `.show`）—— 全 ✅ 的套件会与「实现恒返 true」这种坏实现同时为绿；
2. **必须显式断言表的键恰好是 `{.horizontal}`** —— 否则表被误扩时 T1b/T1d/T1e 会**静默改变含义**却仍然绿；
3. **必须断言 `DrawingToolType.allCases.count == 13`** —— 防「遍历拿到空集 / 少数几个 → 循环次数不足 → 恒绿」。⚠️ 该断言只有在遍历源是**生产枚举**（`allCases`）时才有意义；若改用测试文件里手写的数组，这条就退化成「测试断言自己写的字面量」= 恒真空转（见 D118）。

### T2　单一真相守卫（**结构计数，⛔ 不得写成禁词黑名单**）

断言这四处**确实都从同一张表取值**。判据用**结构计数**（如「查表调用形状在 `Sources/` 中恰好出现 N 处，且分布在预期的那几个文件」），**不得**写成「某某文件里不许出现 `.horizontal` 这个词」——后者可被删注释/改写法绕过，也会被自己的承重注释误伤。

**⚠️ 两条配套要求**：

- 扫描必须**剥注释、剥字符串字面量**（复用既有的 `squeezedText` / `squeeze` 共享扫描器，`DrawingObjectStyleEditTests.swift:187-196`）；
- 必须配**反向自检**：锚点失效（比如文件被改名、调用形状被改写）时守卫要**报错**，不能静默变成「零命中 ⇒ 通过」。

### T2b　钉死「有效性列没有被接到 UI 上」（D120 的落地闸门，**不可省**）

**结构断言**：`isRenderableSubType(` 在 `Sources/` 中的消费方**恰好是那四处写入闸**，且**一处都不在 UI 层**（`Sources/KlineTrainerContracts/UI/` 目录下命中数 == 0）。

⚠️ **两条配套要求**：

1. **必须配反向自检** —— 断言那四处确实**各自命中**（`TrainingEngine.swift` / `DrawingObjectStyleEdit.swift` / `DrawingEnums.swift`）。只写「UI 目录零命中」会与「这个函数被整个删掉」这种坏实现**同时为绿**；
2. 扫描同样**剥注释、剥字符串字面量**（复用 `squeezedText`）。

**它挡的是什么**：D120 那个矛盾（箱体要么画不出、要么面板错误可点）**只有在第 5 片才会暴露**。本条把「别把有效性当灰态用」在**四片之前**就变成一条会当场变红的机械判据。

### T3　既有闸门不回归（**逐条实跑，不得只靠推理**）

改完之后 §3.2 那四条约束对应的既有测试必须仍绿，且**必须在 plan 阶段就实跑一次**确认新增的表没有把源码守卫的计数打乱。⚠️ 本组**必须额外包含** `Tests/.../Drawing/DrawingProtocolTests.swift` 与 `HorizontalLineToolTests.swift`（`requiredAnchors` 契约档）—— 本片虽不碰锚数，但它们是 D119 边界没被破掉的现成证据：

- `DrawingObjectStyleEditTests.swift:172`（N5 源码守卫，含 §3.2 全部四条）
- `DrawingObjectStyleEditTests.swift:82`（`implemented == toolsWithStyleMatrix` 漂移告警）
- `DrawingObjectStyleEditTests.swift:56`（工具门：未实现的已知工具不可编辑）
- `DrawingObjectStyleEditTests.swift:108` / `:121`（tool-aware 归一化的行为档）
- `DrawingStyleAvailabilityTests.swift`（三条横线规则档）
- `DrawingDefaultStyleSanitizeTests.swift`
- `DrawingEditRouterTests.swift`
- `Render/DrawingStylePanelSourceGuardTests.swift`（面板守卫 —— 本片不动面板，但它扫的是面板对灰态判据的消费，必须确认没被牵动）

### T4　变异验证（**逐条关门看红，实施者自报「验过了」不算数**）

至少三组，每组必须回答「**红的是哪一条测试名**」：

| 变异 | 预期变红的档 |
|---|---|
| 把 `isEditableToolType` 的 `∧` 改成 `∨` | T1e（⚠️ **已知它今天区分不了**：两个集合恰好相等 ⇒ 这条变异**预期不红**。故必须由「表的键恰好是 `{.horizontal}`」+ 既有漂移告警 `DrawingObjectStyleEditTests.swift:82` 共同承担，**plan 必须把这条等价变异显式登记为「已识别的等价变异」**，不得当成测试失效） |
| 把「表里没有的工具 → 返回 true」改成「→ 返回 false」 | T1b（**不是** T1a —— 若 T1a 也红说明判据串了） |
| 把「表里没有的工具 → 原样返回 current」改成「→ 落 `.hidden`」 | T1d |
| 把表多加一行（如 `.trend`） | T1 防空转第 2 条 + `:82` 漂移告警 |

**纪律**：先提交实现、再跑变异；复原一律 `cp` 往返，⛔ 禁止 `git checkout <file>`。

---

## 6. 非程序员验收清单（本片 plan 补齐细节）

**本片对用户零可见变化**，所以每一条的预期都是「跟以前一模一样」。

| # | 动作 | 预期 | 通过/不通过 |
|---|---|---|---|
| 1 | 进入训练，画三条水平线 | 与本片之前**完全一样**，能正常画出来 | ☐ 通过 ☐ 不通过 |
| 2 | 选中其中一条，把颜色、粗细、线样式各改一遍 | 与本片之前**完全一样**，改哪个变哪个 | ☐ 通过 ☐ 不通过 |
| 3 | 在样式面板里点「线型」那一组 | 「直线」「射线」可选，**「线段」是灰的** —— 与本片之前一模一样 | ☐ 通过 ☐ 不通过 |
| 4 | 选「射线」之后再看「标注」那一组 | **「左」变灰**，且原来如果选的就是「左」，会自动回到「隐藏」—— 与本片之前一模一样 | ☐ 通过 ☐ 不通过 |
| 5 | 锁定一条线、解锁、删除、撤销 | 与本片之前**完全一样** | ☐ 通过 ☐ 不通过 |
| 6 | 打完一整局并结算入账 | 与本片之前**完全一样**，能正常写进历史记录 | ☐ 通过 ☐ 不通过 |
| 7 | 打开历史记录做一次复盘，在复盘里画线、改样式 | 与本片之前**完全一样** | ☐ 通过 ☐ 不通过 |
| 8 | 退出 App 再进来，看上面画的线还在不在、样式对不对 | 与本片之前**完全一样**，一条不少、一字不差 | ☐ 通过 ☐ 不通过 |

> ⚠️ **只要有任何一条「跟以前不一样」，就是不通过** —— 本片的全部承诺就是「什么都没变，只是内部结构换了」。

---

## 7. 契约 / 闸门 / 交付

### 7.1 契约

| 项 | 本片 |
|---|---|
| `CONTRACT_VERSION` | **不变（`"1.13"`）**，逐条论证见 D114 |
| `user_version` | **不变（8）** |
| 迁移 | **无** |
| m01 矩阵 / bump 记录 | **不动** |

### 7.2 三绿门（作者亲核，clean build）

- **⛔ Catalyst 必须 `xcodebuild test` 真执行，不得只 `build-for-testing`**（codex R1-medium 订正）。两条理由：
  ① 本片新增的产物**不是**唯一被验的东西 —— D115 认定「不变量 1 已被覆盖」所依赖的那四条档（`DrawDrawingsDispatchTests` 三条 + `KLineViewCompileTests` L8c）**全是 UIKit-gated**，只编译不跑等于把本片赖以成立的证据放着不验；
  ② CI 的 Catalyst job **本来就是真跑**（`catalyst-build.yml:23-24 / :58 / :65`），作者的三绿门若比 CI 松，就会出现「本地判绿、CI 才红」。
- **本片零新增 UIKit-gated 测试** ⇒ **`catalyst-uikit-baseline.txt` 不需要改**（它只列 UIKit-gated 测试名）。
- ⚠️ **但 `catalyst-total-baseline.txt`（当前 `1864`）必须实测核对**：它是**全部** swift-testing 用例的总数，host 测试在 Catalyst 上同样执行 ⇒ 本片新增的 T1/T2 会把它推高。闸门容差是 **±30**（`catalyst-gate.sh:227` `DELTA=30`，且注释逐字要求「有意的大幅增减请同步更新基线文件并在 PR 说明，而不是放宽 delta」）。**plan 阶段必须实测本片的用例增量**：落在 ±30 内 → 基线不动；超出 → **同步更新 `catalyst-total-baseline.txt` 并在 PR 描述里说明**。
- **§5-T3 点名的八个测试文件已逐个实测：`canImport(UIKit)` 出现次数全为 0** ⇒ T3 那一整组回归验证在 host `swift test` 里就能真执行（Catalyst 上同样会跑，不冲突）。
- Catalyst 必须用 `-scheme KlineTrainerContracts-Package`（library scheme **不编译 testTarget**），且 `set -o pipefail`（`tee` 会吞退出码）。
- 判绿读**输出内容 / 执行量**，⛔ 不读「SUCCEEDED」字样、⛔ 不用 `tail` 截断。
- 每条闸门命令必须**同时打印 branch 与 HEAD**。
- `@Observable` 类若增删存储属性 → 先 `rm -rf ios/Contracts/.build` 再下结论（本片预计不涉及）。

### 7.3 交付方式

- **worktree**：`.dev/worktree/drawing-p1c-1a`，分支 `feat/drawing-p1c-1a`，base = `origin/main` @ `1437529`。
- **评审命令固定**：`.claude/scripts/codex-attest.sh --scope branch-diff --head feat/drawing-p1c-1a --base origin/main`。⛔ 不得传任何未知参数（含 `--help` —— 兜底分支会把它当 focus 目标，产出假 approve + 脏账本）。
- 评审只读**本地 git** ⇒ 每轮只需 commit，**不需 push**。
- push / 开 PR 由 user 在自己终端执行；给 user 的命令**一行以上一律落成 `/tmp/*.sh`**。
- 本片另带 `docs/superpowers/acceptance/2026-08-30-drawing-p1c-1-tool-matrix.md`（§6 那张表的正式版）。
- 逐片合入 `main`，不叠罗汉。**本片合进 main 之前，第 2 片不开工。**

---

## 8. 遗留问题（交接给后续片，⛔ 不得默默跳过）

| # | 问题 | 归属 | 为什么不能拖 |
|---|---|---|---|
| **Q8** | **样式面板三处写死横线规则**（`UI/DrawingStyleParams.swift:39 / :46 / :142`）必须改成 tool-aware。该 View 目前**收不到 `toolType`**，泛化要改它的参数签名。**⛔ 第 4 片不得只加趋势线的图标而不改这三处** —— 否则趋势线的线型/标注会按**水平线规则**置灰（如趋势线的「线段」会被灰掉，而线段正是趋势线的三种子类之一） | **第 4 片** | 第 4 片一落地就会露出错误的灰态 |
| ~~**Q9**~~ | ~~不变量 1 无直接行为测试~~ —— **本条撤销**（codex R1-medium）：该覆盖一直存在且被 CI 必需门逐条点名，见 D115 订正段。⚠️ 第 2 片新增节点渲染时仍须按既有规矩办：**新增 UIKit-gated 测试 → 同步 `catalyst-uikit-baseline.txt`（用 `uikit-expected-tests.py` 重新生成，不得手打测试名）+ 核对总数基线** | ~~第 2 片~~ 已撤销 | — |
| **Q10** | `Drawing/DrawingLabelLayout.swift:66` 与 `Render/KLineView+Drawing.swift:33` 两处写死 `.horizontal`（价格标签的内容与绘制分支）。新工具要不要标签、标签怎么摆，是每工具的几何问题 | **第 4 片** | 第 4 片写第一条非水平线时必须回答 |
| **Q11** | **归档死锁的恢复通道**（上游 D105 不变量 4 / §2B 整片）已按 D113 记为**知情接受的残留**。若日后 App 上架后真有用户反馈，补它的最小形态是「可分辨的失败信号 + 一句诚实文案」，**⛔ 届时必须按五处核对 `.dbCorrupted` 消费方**（D114 的表），不是上游写的三处 | **未排期** | 记录在此，防止日后照上游三处清单漏核两处 |
| **Q14** | **UI 灰态必须另立一维**（D120）。母 spec §3.1 要求箱体/折线「三个线型全灰」，而它们的数据仍须能存 ⇒ 灰态**不能**复用有效性列。第 4 片接线样式面板时（与 Q8 同一动作）必须：

**① 建立 `lineSubType` 的「UI 可选性」维度**（与有效性列并列，D120）。

**② 面板三处各接各的维度 —— ⛔ 三处不是同一件事**（codex R4-high，**已核实为真**；本 spec 上一稿把三处笼统写成「都接到线型可选性上」，**是错的**）：

| 面板处 | 它实际是什么 | 第 4 片应接到哪一维 |
|---|---|---|
| `DrawingStyleParams.swift:39` | `horizontalLineSubTypeEnabled($0)` —— **线型**组灰态 | **线型 UI 可选性**（本条 ① 新建的那一维） |
| `:46` | `normalizedLabelMode(current:lineSubType:)`（**两参横线版**）—— 切线型后的**标注归一化** | **tool-aware 标注归一化**（改调三参重载，传 `toolType`） |
| `:142` | `horizontalLabelModeEnabled(mode, lineSubType:)` —— **标注**组灰态 | **矩阵的标注列**（tool-aware，传 `toolType`） |

**⚠️ 两维真的会分叉，不是理论风险**：母 spec §3.1 的**趋势线**行 = 三个线型**全 ✅** + 标注**整块灰**（`2026-07-04-…-design.md:98`）。照上一稿「三处都接线型维度」实现，趋势线的标注会被**错误放开**。

**③ 必须配的测试**：
- **趋势线档**（两维分叉的证据）：三个线型按钮**全可点** + 标注按钮**全灰** + 标注经归一化落 `.hidden`。**三项都要**；
- **箱体 / 折线档**（D120 的证据）：**数据落线成功** + 三个线型按钮**全灰**。**两半都要** —— 只测一半会被两种坏实现分别蒙混（只测落线成功 → 漏掉「面板错误可点」；只测全灰 → 漏掉「箱体画不出来」）。

⛔ 不得把灰态塞回有效性列 | **第 4 片**（与 Q8 同一动作） | 第 5 片（箱体）一落地矛盾就爆发；第 4 片是最后一个能从容建立这一维的时机 |
| **Q15** | **有效性列的默认取值纪律**：⛔ 默认应是**全 ✅**，只有该工具**真的画不出**某个值才写 ❌（今天唯一已知的真·画不出是水平线的 `.segment`）。⚠️ 连带风险：`sanitized(for:)` 在「不可渲染」时回落 `.straight`（`DrawingEnums.swift:58`），这**隐含假设 `.straight` 恒有效**；若日后有工具把 `.straight` 标成 ❌（母 spec §3.1 里黄金率/波浪尺的「直线」是灰的），`sanitized` 会产出一个**仍然无效**的值 → 落线照样被拒。届时必须同时改 `sanitized` 的回退目标，或坚持「有效性列全 ✅、灰态交给另一维」 | **第 4 片起每片自查**（P2 工具尤甚） | 表的形状定在本片，故纪律必须写在本片 |
| **Q16** | **`DrawingEditRouter` 的三处水平线专属几何**（上表 3/4/5，codex R5-high）：`:50` / `:203` / `:321` 全部直接调 `HorizontalLineTool.visibleGeometry`，却守着**工具无关**的动作（改样式 / 删除 / 锁定 / 落库）。对一条合法的 `.trend` + `.segment`：水平线几何对 `.segment` **恒返 nil**（`KLineView+Drawing.swift:34` 注释逐字：「nil = segment / 超界射线 / 价格超出可见区间」）⇒ ① 落线时 `:321` 判它不可见 → **锚点被消耗掉、线却没落库**（静默丢线）；② `:203` 拒绝把趋势线改成线段；③ `:50` 认为它不可见 → **改不了样式、删不掉、解不开锁**。⇒ 第 4 片必须把这三处换成**tool-aware 的可见性契约**（经工具注册表拿该工具自己的几何），并配**端到端测试**：一条趋势线 `.segment` 能**落库 / 选中 / 改样式 / 锁定与解锁 / 删除**（五项都要 —— 只测其中几项会被不同的坏实现分别蒙混）。⛔ 不得只把 `HorizontalLineTool` 换成另一个写死的工具 | **第 4 片** | 不做的话第 4 片会 ship 一个「画得出但一碰就废」的趋势线：锚点消耗掉、线不见了，用户完全无从理解 |
| **Q13** | **⚠️ 与 P1c 无关的既有缺陷（本片只登记、不修）**：`结算入账失败` 弹窗的正文写着「进度保留至最近存档」（`UI/TrainingView.swift:180`），而「放弃」按钮实际执行 `discardSession()` → `pendingRepo.clearPending()`（`TrainingSessionCoordinator.swift:1000-1018`）**永久删除整局 pending**。⇒ **用户看到的话与按钮做的事相反**，会让他放心点下破坏性动作。触发面**不限于**未支持数据 —— 上表原因 5（磁盘满 / DB 损坏 / IO 错误）是现实可达的。⛔ **不得并进 P1c 任何一片**（它属结算流程，与划线无关）；最小修法可能只是**把那句文案改对**（如「放弃将丢弃本局进度」），未必需要改行为 | **未排期 · 独立 bug** | 登记在此防止随本轮讨论一起被遗忘；user 2026-08-30 明确要求与 P1c 分开 |
| **Q12** | **锚数的单一真相**（D119）：仓里现有**两份**同一个数字 —— `HorizontalLineTool.requiredAnchors`（`1...1`，`HorizontalLineTool.swift:13`）与 `DefaultDrawingInputController` 的 enum→锚数映射（`:42-48`，其注释自认是 MVP 权宜）。第 4 片按上游既定方案改成经工具注册表读 `DrawingTool.requiredAnchors`，一次性消灭重复。**⛔ 第 4 片不得反过来把锚数塞回样式表** —— 那正是本片 D119 拒绝的形状 | **第 4 片** | 第 4 片是第一个真正需要「每工具不同锚数」的片；再拖就会有第三份 |
| Q1 / Q2 / Q3 / Q4 / Q5 / Q6 / Q7 | 上游 §10 的七个遗留问题**原样有效**，归属不变（Q2 原属第 1B 片 ⇒ **随 1B 一并取消**） | 见上游 §10 | — |

---

## 9. 本 spec 不做

四个工具各自的几何设计（各片自己的 spec）；任何实施细节（属 plan）；第 2–6 片的范围调整（上游 D109/D109b 原样有效）；P2 的五个工具；P3 标注；P4 放大镜与吸附；P5 复盘集成；P6 主页全局默认设置。

**⛔ 与上游 §12 同一条纪律：任何实现者都不得把 P1c 的任意两片合并成一个 PR**，除非重走一次拆分论证并拿到 user 同意。
