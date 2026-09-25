import os, sys, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
import qmt_manifest as QM

print("=== Q3：目标是非普通文件时，规定的处置执行得了吗 ===")
def prep():
    root, src, stg, d1, dd = build()
    m = seed_manifest()
    a,b,c,l = session(src, stg, m)
    _, m2 = copy_stock(a,b,SLOT,(R1M,RDAY),m,ledger=l,budget=Budget(None,m["committed_bytes"]))
    close(a,b,c); return root, src, stg, m2, d1

for kind in ("目录", "FIFO"):
    root, src, stg, m2, d1 = prep()
    t = os.path.join(stg, R1M); os.unlink(t)
    os.mkdir(t) if kind == "目录" else os.mkfifo(t)
    a,b,c,l = session(src, stg, m2)
    try:
        rec = [r for r in m2["files"] if r["relative_path"] == R1M][0]
        print(f"  目标={kind}, 有记录 → 判据 =", classify(b, R1M, rec))
        try:
            st,_ = copy_stock(a,b,SLOT,(R1M,RDAY),m2,ledger=l,budget=Budget(None,m2["committed_bytes"]))
            print(f"    执行 → {st}")
        except Exception as e:
            print(f"    执行 → ⛔ {type(e).__name__} errno={getattr(e,'errno',None)}")
            print("       在途标记残留 =", os.path.exists(os.path.join(stg, INFLIGHT)))
    finally: close(a,b,c)
    # 无记录那一格
    root, src, stg, m2, d1 = prep()
    t = os.path.join(stg, RDAY); os.unlink(t)
    os.mkdir(t) if kind == "目录" else os.mkfifo(t)
    a,b,c,l = session(src, stg, m2)
    try:
        print(f"  目标={kind}, 无记录 → 判据 =", classify(b, RDAY, None))
    finally: close(a,b,c)

print()
print("=== Q2：终止时账本记得下什么 ===")
print("  FinalOutcome 合法 kind =", sorted(QM._FINAL_KINDS))
for k in ("source_changed_midrun",):
    try:
        QM.FinalOutcome(kind=k); print(f"    kind={k} → 接受")
    except Exception as e:
        print(f"    kind={k} → ⛔ {type(e).__name__}: {str(e)[:70]}")
try:
    QM.escape_stop(kind="source_changed_midrun", relative_path="x", component="y", errno="ELOOP")
    print("    escape_stop 新 kind → 接受")
except Exception as e:
    print("    escape_stop 新 kind → ⛔", type(e).__name__, str(e)[:70])
# 未知顶层诊断键能不能随 per-stock 提交落盘并读回
root, src, stg, d1, dd = build(); m = seed_manifest()
a,b,c,l = session(src, stg, m)
try:
    m_diag = dict(m); m_diag["fetch_source_drift"] = {"code": CODE, "relative_path": R1M}
    st, out = copy_stock(a,b,SLOT,(R1M,RDAY),m_diag,ledger=l,budget=Budget(None,m["committed_bytes"]))
    disk = read_manifest(b)
    print("  未知顶层诊断键随 per-stock 提交落盘 =", "fetch_source_drift" in disk,
          "| 读回 =", disk.get("fetch_source_drift"))
finally: close(a,b,c)

print()
print("=== Q4：恢复第③档让 files 变少时，committed_bytes 能不能跟着降 ===")
root, src, stg, d1, dd = build(); m = seed_manifest()
a,b,c,l = session(src, stg, m)
try:
    _, m2 = copy_stock(a,b,SLOT,(R1M,RDAY),m,ledger=l,budget=Budget(None,m["committed_bytes"]))
    shrunk = dict(m2); shrunk["files"] = []
    shrunk["pool_order"] = {"SH": [], "SZ": [], "BJ": []}
    shrunk["cursor"] = {"SH": 0, "SZ": 0, "BJ": 0}
    for label, cb in (("跟着降到 export_log", len(ELOG_BYTES)), ("保持原值不降", m2["committed_bytes"])):
        t = dict(shrunk); t["committed_bytes"] = cb
        try:
            QM.commit_stock(b, t, ledger=l,
                            recovery=QM.RecoveryScope(stock_code=CODE, market="SH", universe_idx=0))
            print(f"  {label} → 接受")
        except Exception as e:
            print(f"  {label} → ⛔ {type(e).__name__}: {str(e)[:100]}")
finally: close(a,b,c)
