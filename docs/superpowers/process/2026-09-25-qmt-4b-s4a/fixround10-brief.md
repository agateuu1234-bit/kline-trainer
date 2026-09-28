# 修复轮 10 任务书 —— codex R7 的 [high]：在途标记的耐久屏障

分支 `qmt-4b-s4a`，BASE `3499287a`。工作目录
`/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend`，
解释器 `../.venv/bin/python`（路径带空格，必须引号）。
⛔ 每条闸门命令同时打印 `git rev-parse --abbrev-ref HEAD` 与 `git rev-parse --short HEAD`。

## 一、评审原文（逐字）

> - [high] Persist the recovery marker before publishing either final file (backend/qmt_fetch.py:1048-1055)
>   The marker is written with ordinary fsync, then copy_stock starts replacing final files.
>   qmt_fsroot explicitly documents that macOS fsync does not guarantee persistence or write
>   ordering across power loss. Consequently, a power failure before commit_stock's full-sync
>   barrier can leave a final CSV durable while .inflight.json is absent or invalid and the
>   manifest remains unchanged. Recovery then lacks its deletion authority; an unrecorded final
>   is classified as untracked_target_file instead of being rolled back and retried. This is a
>   durability inference from the repository's documented platform guarantees, not a reproduced
>   power-loss test.
>   Recommendation: Write the marker with full_sync=True so its contents and published directory
>   entry are durable before either final replacement. Update the durability contract and add an
>   ordering test requiring that barrier before the first .part-to-final rename.

## 二、我已经核过的事实（你不必重核，但不许与之矛盾）

1. **次序属实**：`copy_stock` 里 `_write_inflight_marker(...)` 在第一次
   `_replace_part_to_final(...)` **之前**。
2. **耐久等级属实**：`_write_inflight_marker` 调 `atomic_write_json`，`full_sync` 取默认 `False`。
3. **平台保证属实**：`qmt_fsroot.py` 自己写着「`fcntl(fd, F_FULLFSYNC)` —— 本平台唯一把字节
   真正推到盘上的调用」，并引 macOS `man 2 fsync` 原文说 `fsync` 不保证断电耐久。
4. **`full_sync=True` 覆盖面属实**：`qmt_fsroot` 写明「`full_sync=True` 时，`os.replace`
   之后的**目录项也走 `full_fsync`**」⇒ 评审要求的「内容与目录项都耐久」一个调用即可满足。
5. **这是本仓认过一次的家族**：大 spec 自己记了 O2-F1（[high]）——
   「崩溃回滚对两条 final 的 `unlink` 不在耐久闭合清单 → 目录项丢失后该股被**永久判
   `untracked_target_file` 除名**」。同一套推理，大 spec 用在了回滚删除上，**没用在标记创建上**。

⚠️ 评审自陈这是**推理**、不是断电实测。你也做不了真断电实测，**不要假装做了**。
可做的是**次序测试**（见第四节）。

## 三、要做的事

1. **`_write_inflight_marker` 改走 `full_sync=True`。**
2. **改 docstring**：那里现在写着「`full_sync` 取默认的 `False`——大 spec 闭合清单只给
   `.inflight.json` 的创建/删除记了普通 `fsync`」。这句话是**本次被推翻的依据本身**，
   必须改写成新结论 + 为什么推翻（标记是 D6 的唯一授权凭据；凭据本身的耐久等级
   低于它要授权去删的那些东西，授权在最需要的时刻可能不存在）。
3. **契约 §5 覆盖表加两行**（现有 11 行），逐字列名被本片覆盖的大 spec 语句：
   - `§4.6` 第 2 条：「原子写在途标记 `<staging>/.inflight.json`（tmp → `fsync` → `os.replace`）」
   - 耐久闭合清单：「`.inflight.json` 的**创建**与**删除** → 各自之后 `fsync(staging)`」
   ⚠️ 覆盖表的规矩是**按字面量穷举**，不是按概念搜词。请把上面两句**原样**贴进表里，
   并写清「本片把**创建**那一侧升级为 `full_sync`；**删除**那一侧本片不涉及（归 S4b）」。
   若你在大 spec 里还找到**别的**语句把标记的耐久等级钉成普通 `fsync`，一并列名。
4. **契约 §3b 或 D6 记一条代价**：每只股多一次 `F_FULLFSYNC`（它会 drain 整个磁盘缓存）。
   给出数量级：本片一只股原本 `commit_stock` 已有一次，现在变两次。
5. **§4 交接**：若删标记那一侧（S4b）也该升级，写成一条交接（**只写事实 + 为什么不能不管
   + 必须存在的测试**，不许替 S4b 开药方）。

## 四、测试要求

至少两条：

- **次序测试**：打桩记录调用序列，断言**在第一次 `.part → final` 的 `os.replace` 发生之前**，
  标记的那次 `full_fsync`（内容与目录项两处）**都已经发生**。
  ⛔ 不要只断言「调过 full_sync」——要断言**相对次序**。
- **参数测试**：断言 `_write_inflight_marker` 这条路径上 `full_sync=True` 真的传下去了
  （在没有 `F_FULLFSYNC` 的平台上 `full_fsync` 会退回 `os.fsync`，所以**不能**靠
  「有没有调 fcntl」判断——要在 `qmt_fsroot` 的接口层面判）。

CI 是 **Linux**（没有 `F_FULLFSYNC` 常量），**零容忍 skip**：测试在两个平台上都必须真跑、
不许 `skipif`。

## 五、变异自证（缺这节报告不收）

每条新判据一次定向变异，每次：锚点 `assert count == 1`；前后各清 `__pycache__`；
跑测试带 `PYTHONDONTWRITEBYTECODE=1`；**邻居 deselect 只跑目标那条**；
还原后 sha256 与原文件逐字相同；报告里贴红掉的 `E   ...` 原文。
**最关键的一条变异**：把 `full_sync=True` 改回 `False`，次序测试必须红。

## 六、闸门与约束

- `../.venv/bin/python -m pytest tests/ -q -rs`：BASE 是 **1594 passed / 0 skipped**，
  交付时 0 failed / 0 skipped。
- 禁改模块：`qmt_fsroot.py` / `qmt_manifest.py` / `qmt_pool.py` / `qmt_ingest.py` /
  `qmt_normalize.py`，交付前 `git diff --stat 3499287a -- <这五个>` 自证为空。
  ⚠️ **`full_sync=True` 是既有参数，不需要改 `qmt_fsroot`**；若你发现非改不可，**停下来报告**。
- 异常三族、`reason` 闭集 4 个、`argparse`=0 不变。

## 七、交付

中文提交信息，正文说清**为什么**；结尾
`Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`。
报告写进 `.superpowers/sdd/2026-09-19-qmt-4b-s4a-impl/fixround10-report.md`，
返回值只给：状态、提交 SHA、一行测试结论、疑虑逐条列出。
⛔ 不许派子代理、不许 push、不许开 PR、不许动 `.claude/state/`。
