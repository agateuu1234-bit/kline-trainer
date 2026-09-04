# 切片一 P2（跨端接缝生产者半边）· 变异验证逐条记录

**分支** `feat/trainingset-p2-crossboundary-fixture`
**跑的人** 控制者本人（⛔ 不是子代理转述；每一组的原始输出都在下面）
**日期** 2026-09-05
**基线** 全套 `1130 passed / 0 failed / 0 skipped`；聚焦 `tests/test_trainingset_contract_fixture.py` **9 passed**

## 怎么跑的（可复跑）

驱动器 `/tmp/mutate.py`（本记录附录给出全文）每次只跑**一组**，`backup / restore` 包在 `try/finally` 里、复原是每组的最后一步：

```bash
cd "<repo>" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" /tmp/mutate.py P1
```

⛔ 三条纪律逐条落实：

1. **一组一条命令**，不把多组串在一条里（长链被超时掐死在「已施加变异、尚未复原」之间，会留下一棵带注入缺陷的树 —— 本仓栽过）；
2. 复原用**事先 `cp` 的副本**，⛔ 不用 `git checkout <file>`（会连未提交改动一起抹掉）；
3. 每组跑前**清 `backend/**/__pycache__`**，跑完**单独再看一次 `git status --short`**（下表每行末列即当次实测，全部为空）。

另：锚点命中数 ≠ 1 时驱动器**当场中止且不写盘**，避免「变异其实没施加，却记成『没红』」这种假阴性。实测触发过一次（P2 加固那轮锚点写错一个字），中止有效。

---

## 逐组结果

| # | 变异 | 期望 | 实测红的**具体用例** | 复原后 `git status` |
|---|---|---|---|---|
| **P1** | `assign_global_indices` 还原成旧公式（`upper = 下一根 open − 1`，末根退化为轴末） | 索引断言 + 漂移闸红 | 🔴 `…hand_written_expectations[fresh]`（`15m`）<br>🔴 `test_committed_fixture_matches_current_generator`（`klines`）<br>🟢 `[committed]`（它读的是已提交文件，本就不该红） | 空 |
| **P2** | 把 `daily`/`weekly`/`monthly` 也当成收盘标注（分流反过来的那一半） | `daily` 或 `monthly` 红 ⇒ 正向对照兑现 | 🔴 `…[fresh]`（`daily`）<br>🔴 漂移闸（`klines`） | 空 |
| **P3** | `period_end` 的 `weekly` 分支改成当天（不再取该周周日） | `weekly` 红 | 🔴 `…[fresh]`（`weekly`）<br>🔴 漂移闸（`klines`） | 空 |
| **P4** | `assemble_from_windows` 成员名后缀 `.db` → `.sqlite`（spec 变异 **B64**） | ⭐ **必须分两条记** | 🔴 **只有** 漂移闸（`members`）<br>🟢 「后缀 ∈ {`.sqlite`,`.db`}」那条断言**没红**<br>合计 **1 failed, 8 passed** | 空 |
| **P5** | `SCHEMA_VERSION` 2→3 且 DDL 字面量 `user_version` 2→3，**不重生 fixture**（spec 变异 **B53**） | 两条都红 | 🔴 `…[fresh]`（`user_version != 2`）<br>🔴 漂移闸（`user_version`） | 空 |
| **P6** | `build_windows` 绕过 `select_period_window`，weekly 三根全塞进去 | 特征前提 + spy 守卫 + 索引断言全红 | 🔴 `test_windows_carry_the_three_required_features`<br>🔴 `test_build_windows_goes_through_production_select_period_window`<br>🔴 `…[fresh]`（`weekly` `[0,5,23]`）<br>🔴 漂移闸 | 空 |
| **P6b** | ⭐ 同上但**手工丢掉最后一根** ⇒ 输出与今天**逐根相同** | 只有 spy 守卫能抓 | 🔴 **只有** `test_build_windows_goes_through_production_select_period_window`<br>合计 **1 failed, 8 passed** | 空 |
| **P7** | 把漂移闸比较面里的 `user_version` 拿掉，并叠加 P1 | 自测红 | 🔴 自测（`['klines','members','meta','schema']`）<br>🔴 `…[fresh]` · 🔴 漂移闸 | 空 |
| **P7b** | ⭐⭐ 把比较面里的 **`klines` 整个拿掉**（这才是能让闸门瞎掉的那一刀），并叠加 P1 | 漂移闸应当**变瞎** | 🔴 自测（`['members','meta','schema','user_version']`）<br>🟢 **漂移闸 PASSED —— 闸门真的瞎了**<br>🔴 `…[fresh]` | 空 |
| **P8** | 期望值改成运行时现算的**共享 oracle**，并叠加 P1（spec 变异 **B18** 的反面示范） | 证明这种写法必须被禁止 | 🟢 **`…[fresh]` PASSED —— 生产者与校验者一起错、一起绿**<br>🔴 `…[committed]`（`weekly [0,5] != [0,23]`）<br>🔴 漂移闸 | 空 |

---

## 三条从实测里读出来的结论（不是推演）

### 1. P4 证明了「后缀断言」与「漂移闸」的分工是真的

spec 变异 B64 明写这两条对 `assemble_from_windows` 那行 `f"{fname}.db"` 的敏感度**不同**，必须分开记。实测正是如此：改后缀 ⇒ **只有** 漂移闸红（`members` 字段），后缀断言一动不动（它对 `.sqlite` 同样放行，这是 spec 定的）。

⇒ 若哪天有人以为「后缀断言就够了」而删掉漂移闸，`.db` → `.sqlite` 这类改动会**静默通过**。

### 2. P6b 证明了那条 spy 守卫**不可替代**

「绕过生产切窗函数、手工丢掉那根跨界周」产出的窗口与今天**逐根相同** ⇒ 所有比内容的用例全绿，**只有** spy 守卫红。

⇒ 这条守卫是任务级评审挖出来的（原计划没有）。没有它，「产物必须由生产代码产出」这条契约在判据层面是**空的** —— 只剩一行 ⛔ 注释在管。

### 3. P7b + P8 一起说明了「三方钉同一件产物」为什么是三方，而不是两方

- **P7b**：把 `klines` 从比较面拿掉 + 公式改错 ⇒ **漂移闸 PASSED**。闸门瞎了，唯一红的是那条自测。
  ⇒ 那条自测**是承重的**，不是装饰。这也正是任务级评审 I2 要求把它从「只查键名」加固成「查取值形状」的理由 —— 承重件自己不能是重言式。
- **P8**：期望值改成运行时现算 ⇒ **`[fresh]` 全绿**（生产者与校验者一起用错公式、一起绿，spec §1.4 描述的缝当场重现），而 **`[committed]` 与漂移闸红**。
  ⇒ ⭐ **已提交的那份 fixture 是打破「一起绿」的那个第三方**。这条实测把 spec §4.1「必须提交进仓库」从一条规定变成了一条**有证据的**规定。

---

## 一处我自己的失误，如实记下

**P7 第一版没对准要证明的那条判据。** 计划里 P7 写的是「把比较面写窄成只剩 `members`」，我实际只拿掉了 `user_version` 一个键 —— 于是 `klines` 仍在比，漂移闸照样红。这一组**只证明了「删掉一个键会被自测抓到」，没有证明「窄化会让漂移闸瞎掉」**，而后者才是那条自测存在的理由。

发现后补跑 **P7b**（拿掉 `klines`），才拿到真正的观测量：**漂移闸 PASSED**。

⇒ 印证仓内旧账：「**变异必须对准你要证明的那条判据** —— 『有测试变红』是假信号，必须问『红的是哪一条』，以及**该绿的那条真的绿了吗**」。

---

## 附录：驱动器全文

见 `/tmp/mutate.py`（会话级临时文件，不进仓库）。其结构为：

```python
MUT = {"P1": (说明, [(文件, 旧文本, 新文本), ...]), ...}

def main():
    key = sys.argv[1]; desc, edits = MUT[key]
    bak = {}
    try:
        for path, old, new in edits:
            bak.setdefault(path, cp 到临时目录)
            assert path.read_text().count(old) == 1   # 锚点不唯一 ⇒ 当场中止、不写盘
            path.write_text(替换后)
        清 __pycache__
        跑 pytest tests/test_trainingset_contract_fixture.py -v
    finally:
        for path in bak: cp 回来
        清 __pycache__
        打印 git status --short        # 必须为空
```
