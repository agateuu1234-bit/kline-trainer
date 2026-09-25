import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
import qmt_manifest as QM

print("=== H1：恢复第③档之后再提交一次，committed_bytes 写多少才收 ===")
root, src, stg, d1, dd = build(); m = seed_manifest()
a,b,c,l = session(src, stg, m)
try:
    _, m2 = copy_stock(a,b,SLOT,(R1M,RDAY),m,ledger=l,budget=Budget(None,m["committed_bytes"]))
    print("  ① 提交股 A 后 committed_bytes =", m2["committed_bytes"],
          f"(两文件 {len(d1)+len(dd)} + export_log {len(ELOG_BYTES)})")

    # ② 模拟恢复第③档：删该股 files/pool_order、cursor 回退、累计量只能保持
    rec = dict(m2)
    rec["files"] = []
    rec["pool_order"] = {"SH": [], "SZ": [], "BJ": []}
    rec["cursor"] = {"SH": 0, "SZ": 0, "BJ": 0}
    rec["committed_bytes"] = m2["committed_bytes"]          # 不许降（E10）
    QM.commit_stock(b, rec, ledger=l,
                    recovery=QM.RecoveryScope(stock_code=CODE, market="SH", universe_idx=0))
    print("  ② 恢复第③档提交 → 接受，盘上 committed_bytes =", read_manifest(b)["committed_bytes"])

    # ③ 重拉 A：扫描 committed_bytes 取哪些值收得下
    base = read_manifest(b)
    recs = [{"stock_code":CODE,"period":p,"relative_path":r,
             "bytes":len(x),"sha256":__import__("hashlib").sha256(x).hexdigest()}
            for p,r,x in (("1m",R1M,d1),("daily",RDAY,dd))]
    print("  ③ 重拉 A，扫描 committed_bytes 的可接受值：")
    for v in (366, 400, 705, 706, 707):
        t = dict(base); t["files"] = recs
        t["pool_order"] = {"SH":[{"code":CODE,"universe_idx":0}],"SZ":[],"BJ":[]}
        t["cursor"] = {"SH":1,"SZ":0,"BJ":0}; t["committed_bytes"] = v
        try:
            QM.commit_stock(b, t, ledger=l); print(f"     {v:5d} → 接受"); break
        except Exception as e:
            print(f"     {v:5d} → 拒 ({str(e)[:58]}…)")
finally: close(a,b,c)

print()
print("=== 盘上实占 vs 账本记的 ===")
print(f"  盘上实占 = {len(d1)+len(dd)+len(ELOG_BYTES)} 字节（A 只有一份）")
print("  若 706 才收，则 A 的 340 字节对 --max-bytes 被记了两遍")
