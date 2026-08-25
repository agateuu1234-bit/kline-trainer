"""`fetch_manifest.json` —— `qmt_fetch` 写、`qmt_pilot` 读的唯一真相源。

Spec: `docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md` §4.4 + §4.5
（含文末「S2 实施轮」四条更正）。

本模块只做三件事，**不碰网络、不碰拷贝、不碰数据库**：
1. 定义 manifest 的结构与版本；
2. 读侧**闭合**校验（fail-closed，绝不「尽力而为地解析」）——纯函数，零文件系统；
3. 两个提交入口 + `stopped_reason` / `fetch_fatal_error` 的生命周期决策表。

⚠️ **为什么读侧校验必须闭合**：一个被截断的 manifest 解析出来往往仍是合法 JSON
的**前缀片段**，静默消费它 = 把 manifest 损坏伪装成「候选就这么多」，最终产出一份
**会撒谎的 pilot 报告**（R1-F4）。
"""
from __future__ import annotations

# ── 版本 ─────────────────────────────────────────────────────
# 新增任何**必需**字段都必须 bump 本值（spec O2-F8）。可选字段经
# 「未知顶层键原样保留」通道流转，不需要 bump。
MANIFEST_VERSION = 1

MANIFEST_NAME = "fetch_manifest.json"

MARKETS = ("SH", "SZ", "BJ")
PERIODS = ("1m", "daily")

# 必需顶层键的**外延**（写死，不做「凡是我认识的都必需」这种开放定义）。
# ⚠️ 顶层**没有** `universe`（S2-F3）：名单的唯一位置是 `source_snapshot.universe`。
# 原 spec 把它列成顶层必需键，而写侧从不产出它 → 本工具诚实产出的每一份 manifest
# 都会被本工具自己的读侧判 FAIL_MANIFEST_INVALID，一次都跑不通。
REQUIRED_KEYS = (
    "manifest_version", "seed", "source_snapshot", "source_mount",
    "pool_order", "cursor", "files", "staged_export_log",
    "source_verification", "source_verification_evidence",
)

# `stopped_reason` 的闭合枚举（R87-F1 + R89 自查补 + O4-F3 补第四值）。
STOPPED_REASONS = frozenset({
    "max_bytes",
    "source_path_escape",
    "staging_path_escape",
    "staging_recheck_failed",
})

# `fetch_fatal_error.kind` 记录的是**首次逃逸的类型**，与 `stopped_reason` **解耦**
# （O4-F3）：复校失败那一档正是「保留 fatal + 换 stopped_reason」，
# 写成「kind 恒等于 stopped_reason」会让它**结构上不可表达**。
FATAL_KINDS = frozenset({"source_path_escape", "staging_path_escape"})

# 这三个 `stopped_reason` 必须同时带形状合规的顶层 `fetch_fatal_error`。
REASONS_REQUIRING_FATAL = frozenset({
    "source_path_escape", "staging_path_escape", "staging_recheck_failed",
})

VERIFICATION_LEVELS = ("snapshot", "full", "partial")

# 生命周期三字段：**只有收尾提交能动它们**，per-stock 提交在写入路径上够不到
# （R95-F2 + spec §9-3s「使规则可机械检验」）。
LIFECYCLE_KEYS = frozenset({
    "stopped_reason", "stopped_reason_secondary", "fetch_fatal_error",
})


class ManifestInvalidError(Exception):
    """manifest 形状/自洽性不过 → `FAIL_MANIFEST_INVALID`。

    **与 `ManifestVersionError` 是两族**：本族说「这份账本坏了」，那族说
    「这份账本是别的版本写的」。混成一句话会让操作者面对一棵已拉几百只股的
    staging 无路可走（O2-F8）。
    """


class ManifestVersionError(Exception):
    """manifest 版本与本工具不等——**不是**形状非法。

    三档（O2-F8 + O4-F10）：低于 / 高于 / 缺失（视为 0，走「低于」）。
    每档给出**不同的、操作者照做得了的**指引。
    """

    def __init__(self, *, kind: str, found: int, expected: int):
        if kind not in ("older", "newer"):
            raise ValueError(f"kind 只能是 older/newer，收到 {kind!r}")
        self.kind = kind
        self.found = found
        self.expected = expected
        self.guidance = (
            f"该 staging 由旧版本（manifest_version={found}）产出，"
            f"本工具是 {expected} 版。请换新 staging + 新 seed 重拉。"
            if kind == "older" else
            f"该 staging 由更新版本（manifest_version={found}）产出，"
            f"本工具只到 {expected} 版。请用对应版本的工具，或换新 staging。"
        )
        super().__init__(self.guidance)
