import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
import qmt_manifest as QM
print("=== Q2b：进度一步不推进、只写诊断键，提交收不收 ===")
root, src, stg, d1, dd = build(); m = seed_manifest()
a,b,c,l = session(src, stg, m)
try:
    _, m2 = copy_stock(a,b,SLOT,(R1M,RDAY),m,ledger=l,budget=Budget(None,m["committed_bytes"]))
    diag = dict(m2)          # 进度逐字不动
    diag["fetch_source_drift"] = {"code": CODE, "relative_path": R1M,
                                  "expected_sha256": "a"*64, "found_sha256": "b"*64}
    try:
        out = QM.commit_stock(b, diag, ledger=l)
        disk = read_manifest(b)
        print("  只写诊断键、进度不动 → 接受")
        print("    诊断键读回 =", disk.get("fetch_source_drift", {}).get("code"))
        print("    cursor 没变 =", disk["cursor"]["SH"] == m2["cursor"]["SH"],
              "| files 没变 =", len(disk["files"]) == len(m2["files"]))
    except Exception as e:
        print("  ⛔", type(e).__name__, str(e)[:140])
finally: close(a,b,c)

print()
print("=== Q3b：非普通文件一律判 untracked（拒绝覆盖）执行得了吗 ===")
def prep():
    root, src, stg, d1, dd = build(); m = seed_manifest()
    a,b,c,l = session(src, stg, m)
    _, m2 = copy_stock(a,b,SLOT,(R1M,RDAY),m,ledger=l,budget=Budget(None,m["committed_bytes"]))
    close(a,b,c); return root, src, stg, m2
import engine
for kind in ("目录","FIFO"):
    root, src, stg, m2 = prep()
    t = os.path.join(stg, R1M); os.unlink(t)
    os.mkdir(t) if kind=="目录" else os.mkfifo(t)
    a,b,c,l = session(src, stg, m2)
    try:
        # 改判据：非普通文件一律 untracked，不管有没有记录
        orig = engine.classify
        def patched(stg_fd, rel, record):
            v = orig(stg_fd, rel, record)
            return engine.TARGET_UNTRACKED if v == engine.TARGET_RECOPY and _nonreg(stg, rel) else v
        def _nonreg(stg, rel):
            import stat as S
            try: return not S.S_ISREG(os.lstat(os.path.join(stg, rel)).st_mode)
            except OSError: return False
        engine.classify = patched
        try:
            copy_stock(a,b,SLOT,(R1M,RDAY),m2,ledger=l,budget=Budget(None,m2["committed_bytes"]))
            print(f"  目标={kind} → 没拒绝（不该）")
        except engine.StockCopyFailed as e:
            print(f"  目标={kind} → 拒绝 reason={e.reason}",
                  "| 标记残留 =", os.path.exists(os.path.join(stg, INFLIGHT)),
                  "| 那个对象还在 =", os.path.exists(os.path.join(stg, R1M)))
        finally:
            engine.classify = orig
    finally: close(a,b,c)
