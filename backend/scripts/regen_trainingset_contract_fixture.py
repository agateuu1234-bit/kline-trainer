#!/usr/bin/env python3
"""重新生成跨端契约 fixture（spec §4.1）。

⚠️ **重新生成 = 改契约。** 这份 zip 是「当前生成器输出 / 已提交 fixture / App 侧读取链路」
   三方共同钉住的**同一件**产物；它一变，切片二的 App 侧链路必须重跑。
⛔ **不得**为了让 `test_committed_fixture_matches_current_generator` 变绿而顺手跑本脚本 ——
   那道闸红了说明**生成器行为变了**，先判断那是不是有意的改动。

用法（在仓库任意目录）：
    python3 backend/scripts/regen_trainingset_contract_fixture.py
"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

# backend/ 本身要在 sys.path 上，才能 `from tests._trainingset_contract_fixture import ...`
# （与 backend/tests/ 下测试文件的隐式 import 方式一致；同 backend/scripts/verify_qmt_pg_chain.py）。
_BACKEND_DIR = Path(__file__).resolve().parent.parent
if str(_BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(_BACKEND_DIR))

from tests._trainingset_contract_fixture import FIXTURE_ZIP, build_fixture  # noqa: E402


def main() -> int:
    old = FIXTURE_ZIP.read_bytes() if FIXTURE_ZIP.exists() else None
    FIXTURE_ZIP.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        gen = build_fixture(Path(td))
        # ⭐ **原子替换**：先落到同目录的临时名，再 `os.replace` 顶上去。
        # `shutil.copyfile` 是「先截断再写」——中途崩/断电/写满盘会让**已提交的契约产物**
        # 变成半截文件，而它正是三方共同钉住的那一件东西。同目录 ⇒ 同文件系统 ⇒ replace 原子。
        staged = FIXTURE_ZIP.parent / (FIXTURE_ZIP.name + ".tmp")
        try:
            shutil.copyfile(gen.path, staged)
            os.replace(staged, FIXTURE_ZIP)
        finally:
            staged.unlink(missing_ok=True)   # 复制失败时不留残渣
    new = FIXTURE_ZIP.read_bytes()

    with zipfile.ZipFile(FIXTURE_ZIP) as zf:
        members = zf.namelist()

    print(f"写入 {FIXTURE_ZIP}")
    print(f"  成员清单     : {members}")
    print(f"  字节数       : {len(new)}")
    print(f"  content_hash : {gen.content_hash}"
          f"   ⚠️ 随写库机器的 sqlite 版本变，⛔ 不得写进任何断言")
    if old is None:
        print("  （原先不存在，本次新建）")
    elif old == new:
        print("  内容与原先**逐字节相同**")
    else:
        print(f"  ⚠️ 内容变了（原 {len(old)} 字节）—— 这是**契约变更**，"
              f"切片二的 App 侧读取链路必须重跑")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
