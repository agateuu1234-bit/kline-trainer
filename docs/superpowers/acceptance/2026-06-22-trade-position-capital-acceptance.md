# RFC-A 交易/仓位/资金对齐 验收清单（非程序员可执行）

> 权威 spec：`docs/superpowers/specs/2026-06-22-trade-position-capital-design.md` §10。
> 计划：`docs/superpowers/plans/2026-06-22-trade-position-capital.md`（真 Codex R1–R26 收敛 approve）。
> 分支：`feat/trade-position-capital`。CONTRACT_VERSION 1.6→1.7。

## 执行环境
- 设备：模拟器 **iPhone 17 Pro**（udid `DE0BA39D-C749-459D-A407-4418599B61CA`）。
- 数据：DEBUG fixture（启动前置环境变量 `SIMCTL_CHILD_KLINE_SEED_FIXTURE=1`）。
- 改 fixture 后须 `simctl uninstall` 再重装，否则旧库残留。
- 证据：每条附截图。判定为二值（pass/fail），无中间态。

## 自动化验证（已由 controller 实测）
| 项 | 结果 |
|---|---|
| host `swift test`（Contracts，Swift Testing + XCTest 两框架） | ✅ 全绿：Swift Testing 1201 tests/168 suites passed + XCTest `All tests` passed，两侧 0 失败 |
| CONTRACT_VERSION bump | ✅ `"1.6"`→`"1.7"`（Models.swift），ModelsTests 同步，m01 记录 A 类改既有语义 |
| iOS Simulator build（iPhone 17 Pro，整个 app 含 UIKit TrainingView/TradeBoxView） | ✅ `** BUILD SUCCEEDED **` |
| Mac Catalyst build-for-testing | 本机无 Mac Catalyst destination（签名/环境限制，沿用历史多 PR 同档）→ **CI `Mac Catalyst build-for-testing on macos-15` job 兜底** |

## 人工验收清单（模拟器，14 条）

| # | 操作（action） | 预期（expected） | 通过判定（pass/fail） |
|---|---|---|---|
| 1 | 进入训练，点底部「买入」 | 从 active 图底部弹出**数量框**（非旧 5 档条）：含数量框 + −/＋ + 1/5..4/5 + 全仓 + 可买 N 股 + 预估金额 + 右上 ✕ + 全宽「买入」键 | 框内 7 类元素齐全且从 active 图底弹 = pass；仍是旧 5 档条或缺元素 = fail |
| 2 | 框内点「＋」一次、再点「−」一次 | 数量各 ±100 股 | 步进恰为 ±100 = pass；否则 fail |
| 3 | 手动输入一个非 100 倍数（如 250） | 确认时取整到手（250→200），或输入即向下取整到 100 | 最终下单股数为 100 倍数 = pass；成交奇数股 = fail |
| 4 | 点「全仓」再「买入」 | 用尽可用现金买入最大手数且**不报现金不足**；持仓股数增加、现金≥0 | 成交且现金不为负、无「现金不足」报错 = pass；报错或现金为负 = fail |
| 5 | 持仓>0 时点「卖出」→「清仓」→「卖出」 | 持仓清零（精确全部，含零股）、现金增加 | 持仓变 0 = pass；残留股数 = fail |
| 6 | 0 持仓时看「卖出」入口 | 卖出禁用（或卖框「可卖 0 股」且确认禁用） | 不能卖空 = pass；能卖出 = fail |
| 7 | 切 T2「60分」点买入 / 切「日线」点买入 | 框分别从**上图(60分)底部** / **下图(日线)底部**弹出，红框随之在上/下图 | 两次弹出位置 + 红框各自正确 = pass；位置/红框错 = fail |
| 8 | 顶栏第 5 格（持仓>0 与 =0） | 持仓>0 显**当前持仓浮动盈亏**「±¥金额 (±%)」=（现价−成本）×股数；持仓=0 显 `+¥0.00 (+0.00%)` | 两态取值符合 = pass；显示账户总收益率或错值 = fail |
| 9 | 完成一局（结算）后开新局 | 新局起始总资金 = 上局结束总资金（含上局盈亏，跨局复利接续） | 新局起始资金接续上局 = pass；回到 10 万 = fail |
| 10 | 设置里「重置资金」 | 总资金回 10 万，但**历史记录仍在**（历史列表条目数不变） | 资金=10 万 且 历史条目保留 = pass；记录被清空 = fail |
| 11 | 打开买框后，先做一次「持有」（推进 tick），再回到框点「买入」 | 框因状态漂移作废/刷新，不会按过期价/tick 成交 | 不发生过期成交（框失效或数值已刷新）= pass；按旧价/旧 tick 成交 = fail |
| 12 | 全程不动 RFC-B 布局 | 顶栏框架 / 上下两图 / 坐标轴 / MA66·BOLL·MACD / 画线浮动 ✎ / T2 条顺序(周期左·价中·买卖持有右) 与 RFC-B 一致 | 布局零变化 = pass；任一被改 = fail |
| 13 | 点「买入」在框里填一个数量（如 500），**不关框**直接点 T2「卖出」 | 卖出框重新弹出且数量框**归 0**（非残留 500）；确认键文案随新数量 | 新框为 0 = pass；残留旧数量 = fail |
| 14 | 买框里手输一个非整手/超限数量（如 250 或超「可买」），直接点确认 | 确认键文案 = 将提交的合法股数（如 250→200、超限→可买上限）；成交记录的股数 = 该值；数量框失焦/确认后亦显该值 | 文案=记录股数、显示==提交 = pass；显示一个量却成交另一个量 = fail |

## 签收
- [ ] 14 条全 pass（每条附截图）。
- [ ] CI `Mac Catalyst build-for-testing on macos-15` job 绿。
- [ ] 任一 fail → 记录现象 + 截图，回 systematic-debugging。
