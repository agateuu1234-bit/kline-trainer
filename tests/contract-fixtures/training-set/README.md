# 训练组跨端契约 fixture

`999002.SZ_1774972800.zip` 是**唯一**一份跨端共用的训练组样本，由后端**生产**装配函数
`assemble_from_windows` 产出（spec `docs/superpowers/specs/2026-09-01-trainingset-timestamp-semantics-design.md` §4.1）。

它同时被三方钉住：

1. **手写期望值** —— `backend/tests/test_trainingset_contract_fixture.py` 里的字面量，
   由人工按 spec §2.2 的公式独立推算，⛔ 不是「跑一遍生成器抄回来」的；
2. **已提交的这份产物** —— 就是本目录里的这个 zip；
3. **当前生成器的现场输出** —— 每次后端 CI 都重跑一次 `assemble_from_windows`，
   与本文件按**逻辑内容**比对（`test_committed_fixture_matches_current_generator`）。

⇒ 三方任何一方漂移都会红。切片二会把 App 侧的「解压 → 打开 → 读取」链路接到**这一份**上
（⛔ 不是另造一份），spec §1.4 那道「两侧静态 fixture 各自漂移」的缝才算闭合。

## 逻辑形态速查

| 项 | 值 |
|---|---|
| 压缩包成员 | 恰好 1 个：`999002.SZ_1774972800.db`（⛔ 无 sidecar） |
| `PRAGMA user_version` | `2` |
| `meta` | 1 行：`999002.SZ` / `跨端契约样例` / `1774972800` / `1775059199` |
| `klines` 行数 | 47 = monthly 4 + weekly 2 + daily 5 + 60m 4 + 15m 8 + 3m 24 |
| 3m 轴 | 4 个交易日（2026-03-27 / 03-30 / 03-31 / 04-01）× 每日 6 根（09:33 / 09:36 / 11:27 / 11:30 / 14:57 / 15:00） |
| `end_global_index` | `3m` `[0..23]` · `15m` `[3,5,9,11,15,17,21,23]` · `60m` `[5,11,17,23]` · `daily` `[0,5,11,17,23]` · `weekly` `[0,5]` · `monthly` `[0,0,17,23]` |

三类刻意做进去的特征（spec §4.1 note 2）：

- ① `monthly` 前两根落在 `end_global_index = 0`（月末早于 3m 轴首）；
- ② `15m` / `60m` 跨**午休**（11:30 → 14:57）与跨**日**（15:00 → 次日 09:33）两条边界；
- ③ 起点 2026-04-01 是**周三**，`select_period_window` 把 2026-03-30 那根周线删掉 ⇒ 周线序列**有洞**。

## ⛔ 没有记录 content_hash / 字节数，这是有意的

SQLite 文件头 offset 96 存的是「最后写这个库的 sqlite 库的版本号」（本机实测 `3053003` = 3.53.3）
⇒ 换一台机器、升一次 sqlite，zip 的字节与 CRC32 都会变。所以：

- ⛔ 任何测试都**不得**断言 `content_hash` 字面量，也**不得**比 zip 原始字节；
- ✅ 比对一律走**逻辑内容**：压缩包成员清单 + `PRAGMA user_version` + `sqlite_master` + `meta` 与 `klines` 的全部行。

## 怎么重新生成

```bash
python3 backend/scripts/regen_trainingset_contract_fixture.py
```

⚠️ **重新生成 = 改契约。**
⛔ 如果你是因为 `test_committed_fixture_matches_current_generator` 红了才来跑这条命令，**先停下**：
那道闸红了说明**生成器的行为变了**。先判断那是不是有意的 ——

- **有意**（比如又 bump 了一代产物）⇒ 重生 fixture，并把切片二的 App 侧读取链路一并重跑；
- **无意** ⇒ 这就是回归，该改的是生成器，不是 fixture。
