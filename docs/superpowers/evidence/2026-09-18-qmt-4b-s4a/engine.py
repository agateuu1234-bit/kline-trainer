# -*- coding: utf-8 -*-
"""一次性探针：最小拷贝引擎。

⛔⛔ **这不是参考实现，是实验当时的原样记录。不得照抄。**
本文件的 `classify` 对「非普通文件」按**有无记录分叉**
（`TARGET_UNTRACKED if record is None else TARGET_RECOPY`，见下方约 105/113 行）——
那正是 **E6 证伪掉的写法**：目标是目录时「重拷」执行不了（`os.replace` 抛 `IsADirectoryError`），
而那时在途标记已残留在盘上。
**契约 D2 据此改判为「一律 `untracked_target_file`，不按有无记录分叉」**，由 E7（q2b.py）实测坐实。
⇒ **以 `docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md` 的 D2 为准，不以本文件为准。**
本文件刻意保留原样：改它就是伪造实验记录，而 E6 的结论恰恰建立在「原样跑出来会失败」上。
**不进仓库**，只为把悬着的问题跑出答案。"""
import hashlib, os, stat, sys
sys.path.insert(0, "/Users/maziming/Coding/Prj_Kline trainer/backend")

from qmt_fsroot import (open_root, open_under, parent_fd_under, fsync_dir,
                        open_regular_probe, atomic_write_json, PathEscapeError,
                        NotARegularFileError, acquire_lock)
from qmt_manifest import (begin_run, read_manifest, commit_stock, MARKETS,
                          ManifestInvalidError)
from qmt_normalize import parse_qmt_filename, QmtSchemaError

PART = ".part"
INFLIGHT = ".inflight.json"
CHUNK = 1 << 20

class StockCopyFailed(Exception):
    def __init__(self, reason, detail=""):
        self.reason = reason
        super().__init__(f"{reason}: {detail}")

class MaxBytesExhausted(Exception): pass
class SourceChangedMidRun(Exception): pass

class Budget:
    def __init__(self, limit=None, used0=0):
        self.limit, self.used = limit, used0
    def precheck(self, n):
        if self.limit is not None and self.used + n > self.limit:
            raise MaxBytesExhausted(f"precheck {n}, remaining {self.limit - self.used}")
    def charge(self, n):
        if self.limit is not None and self.used + n > self.limit:
            raise MaxBytesExhausted(f"charge {n}, remaining {self.limit - self.used}")
        self.used += n
    def refund(self, n):
        assert n <= self.used, "退还超过已扣"
        self.used -= n

def _write_all(fd, data):
    v = memoryview(data)
    while v:
        w = os.write(fd, v)
        assert w > 0
        v = v[w:]

def _probe(dir_fd, relpath, *, flags=os.O_RDONLY):
    """逐段无跟随 + 类型安全地打开一个叶子。返回 (fd, st)。"""
    pfd, leaf = parent_fd_under(dir_fd, relpath)   # ENOENT 原样上抛
    try:
        return open_regular_probe(pfd, leaf, flags=flags)
    finally:
        os.close(pfd)

def copy_one(src_fd, stg_fd, rel, budget):
    part = rel + PART
    try:
        sfd, st = _probe(src_fd, rel)
    except FileNotFoundError as e:
        raise StockCopyFailed("fetch_missing_file", f"{rel}: {e}") from e
    except NotARegularFileError as e:
        raise StockCopyFailed("fetch_missing_file", f"{rel}: {e}") from e
    try:
        if not stat.S_ISREG(st.st_mode):        # ← S4-F2：调用方自己查
            raise StockCopyFailed("fetch_missing_file", f"{rel}: 不是普通文件")
        budget.precheck(st.st_size)
        h, n = hashlib.sha256(), 0
        dfd = open_under(stg_fd, part, flags=os.O_WRONLY|os.O_CREAT|os.O_TRUNC,
                         create_dirs=True)
        try:
            while True:
                b = os.read(sfd, CHUNK)
                if not b: break
                budget.charge(len(b)); _write_all(dfd, b); h.update(b); n += len(b)
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        os.close(sfd)
    # 对落地的 .part 重算
    rfd = open_under(stg_fd, part, flags=os.O_RDONLY)
    try:
        h2 = hashlib.sha256()
        while True:
            b = os.read(rfd, CHUNK)
            if not b: break
            h2.update(b)
    finally:
        os.close(rfd)
    if h2.hexdigest() != h.hexdigest():
        raise StockCopyFailed("fetch_copy_hash_mismatch", rel)
    return n, h.hexdigest()

TARGET_COPY, TARGET_SKIP, TARGET_RECOPY, TARGET_UNTRACKED = "copy","skip","recopy","untracked"

def classify(stg_fd, rel, record):
    try:
        pfd, leaf = parent_fd_under(stg_fd, rel)
    except FileNotFoundError:
        return TARGET_COPY                    # ← 父目录不存在 = 全新 staging
    try:
        try:
            fd, st = open_regular_probe(pfd, leaf, flags=os.O_RDONLY)
        except FileNotFoundError:
            return TARGET_COPY
        except NotARegularFileError:
            return TARGET_UNTRACKED if record is None else TARGET_RECOPY
    finally:
        os.close(pfd)
    try:
        if record is None:
            return TARGET_UNTRACKED
        if not stat.S_ISREG(st.st_mode):      # ← S4-F2 读侧
            return TARGET_UNTRACKED if record is None else TARGET_RECOPY
        if st.st_size != record["bytes"]:
            return TARGET_RECOPY
        h = hashlib.sha256()
        while True:
            b = os.read(fd, CHUNK)
            if not b: break
            h.update(b)
        return TARGET_SKIP if h.hexdigest() == record["sha256"] else TARGET_RECOPY
    finally:
        os.close(fd)

def _unlink_tol(stg_fd, rel):
    """删一条，容忍 ENOENT；其余 errno 原样上抛（含目录的 EPERM/EISDIR）。"""
    try:
        pfd, leaf = parent_fd_under(stg_fd, rel)
    except FileNotFoundError:
        return
    try:
        os.unlink(leaf, dir_fd=pfd)
    except FileNotFoundError:
        return
    else:
        fsync_dir(pfd)
    finally:
        os.close(pfd)

def _apply(manifest, slot, records):
    mk = slot["market"]
    out = dict(manifest)
    out["files"] = [r for r in manifest.get("files", [])
                    if r.get("stock_code") != slot["code"]] + records
    pool = {m: list(manifest["pool_order"][m]) for m in MARKETS}
    if not any(i["code"] == slot["code"] for i in pool[mk]):
        pool[mk] = pool[mk] + [{"code": slot["code"], "universe_idx": slot["universe_idx"]}]
    out["pool_order"] = pool
    cur = dict(manifest["cursor"])
    cur[mk] = max(cur[mk], slot["universe_idx"] + 1)
    out["cursor"] = cur
    sel = manifest.get("staged_export_log") or {}
    out["committed_bytes"] = sum(r["bytes"] for r in out["files"]) + int(sel.get("bytes", 0))
    return out

def copy_stock(src_fd, stg_fd, slot, rels, manifest, *, ledger, budget, now="T"):
    by_rel = {r["relative_path"]: r for r in manifest.get("files", [])
              if r.get("stock_code") == slot["code"]}
    recs_in = [by_rel.get(r) for r in rels]
    verdicts = [classify(stg_fd, r, rec) for r, rec in zip(rels, recs_in)]
    if TARGET_UNTRACKED in verdicts:
        raise StockCopyFailed("untracked_target_file", slot["code"])
    if all(v == TARGET_SKIP for v in verdicts):
        return "skipped", manifest

    written, records = {}, []
    try:
        for rel, per, rec, v in zip(rels, ("1m","daily"), recs_in, verdicts):
            if v == TARGET_SKIP:
                records.append(dict(rec)); continue
            n, d = copy_one(src_fd, stg_fd, rel, budget)
            written[rel] = n
            # ← 收口点前移：重拷结果与账本记录不符 ⇒ 源中途变了
            if rec is not None and (rec["bytes"] != n or rec["sha256"] != d):
                raise SourceChangedMidRun(f"{rel}: 账本 {rec['sha256'][:8]} vs 现在 {d[:8]}")
            records.append({"stock_code": slot["code"], "period": per,
                            "relative_path": rel, "bytes": n, "sha256": d})
    except BaseException:
        for rel in rels:
            _unlink_tol(stg_fd, rel + PART)
            n = written.pop(rel, 0)
            if n: budget.refund(n)
        raise

    atomic_write_json(stg_fd, INFLIGHT, {
        "code": slot["code"], "universe_idx": slot["universe_idx"],
        "targets": list(rels), "parts": [r + PART for r in rels],
        "started_at": now}, full_sync=True)

    for rel, v in zip(rels, verdicts):
        if v == TARGET_SKIP: continue
        spfd, sl = parent_fd_under(stg_fd, rel + PART)
        try:
            dpfd, dl = parent_fd_under(stg_fd, rel)
            try:
                os.replace(sl, dl, src_dir_fd=spfd, dst_dir_fd=dpfd)
                fsync_dir(dpfd)
            finally:
                os.close(dpfd)
        finally:
            os.close(spfd)

    committed = commit_stock(stg_fd, _apply(manifest, slot, records), ledger=ledger)
    _unlink_tol(stg_fd, INFLIGHT)
    return "committed", committed
