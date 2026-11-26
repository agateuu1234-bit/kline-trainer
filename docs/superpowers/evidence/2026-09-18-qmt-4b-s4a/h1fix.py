import os, sys, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
import qmt_manifest as QM

print("=== 出路验证：committed_bytes 改成「累计写入量」（只增，= 旧值 + 本次新写字节）===")
root, src, stg, d1, dd = build(); m = seed_manifest()
a,b,c,l = session(src, stg, m)
def recs():
    return [{"stock_code":CODE,"period":p,"relative_path":r,"bytes":len(x),
             "sha256":hashlib.sha256(x).hexdigest()} for p,r,x in (("1m",R1M,d1),("daily",RDAY,dd))]
try:
    # ① 首次提交：累计 = 26(export_log) + 340
    t = dict(m); t["files"] = recs()
    t["pool_order"] = {"SH":[{"code":CODE,"universe_idx":0}],"SZ":[],"BJ":[]}
    t["cursor"] = {"SH":1,"SZ":0,"BJ":0}
    t["committed_bytes"] = m["committed_bytes"] + (len(d1)+len(dd))
    QM.commit_stock(b, t, ledger=l)
    v1 = read_manifest(b)["committed_bytes"]; print(f"  ① 首次提交 → 接受，累计 = {v1}")

    # ② 恢复第③档：删记录、退游标，累计**不动**
    r = dict(read_manifest(b)); r["files"] = []
    r["pool_order"] = {"SH":[],"SZ":[],"BJ":[]}; r["cursor"] = {"SH":0,"SZ":0,"BJ":0}
    QM.commit_stock(b, r, ledger=l,
                    recovery=QM.RecoveryScope(stock_code=CODE, market="SH", universe_idx=0))
    v2 = read_manifest(b)["committed_bytes"]; print(f"  ② 恢复第③档 → 接受，累计 = {v2}（不动）")

    # ③ 重拉：累计 = 旧值 + 本次真正写下去的字节
    t = dict(read_manifest(b)); t["files"] = recs()
    t["pool_order"] = {"SH":[{"code":CODE,"universe_idx":0}],"SZ":[],"BJ":[]}
    t["cursor"] = {"SH":1,"SZ":0,"BJ":0}
    t["committed_bytes"] = v2 + (len(d1)+len(dd))
    QM.commit_stock(b, t, ledger=l)
    v3 = read_manifest(b)["committed_bytes"]; print(f"  ③ 重拉同一只 → 接受，累计 = {v3}")

    # ④ 再来一轮崩溃+重拉，证明不是一次性侥幸
    r = dict(read_manifest(b)); r["files"] = []
    r["pool_order"] = {"SH":[],"SZ":[],"BJ":[]}; r["cursor"] = {"SH":0,"SZ":0,"BJ":0}
    QM.commit_stock(b, r, ledger=l,
                    recovery=QM.RecoveryScope(stock_code=CODE, market="SH", universe_idx=0))
    t = dict(read_manifest(b)); t["files"] = recs()
    t["pool_order"] = {"SH":[{"code":CODE,"universe_idx":0}],"SZ":[],"BJ":[]}
    t["cursor"] = {"SH":1,"SZ":0,"BJ":0}
    t["committed_bytes"] = read_manifest(b)["committed_bytes"] + (len(d1)+len(dd))
    QM.commit_stock(b, t, ledger=l)
    v4 = read_manifest(b)["committed_bytes"]
    print(f"  ④ 再崩一次再重拉 → 接受，累计 = {v4}")
    print()
    print(f"  ⇒ 盘上始终只占 {len(d1)+len(dd)+len(ELOG_BYTES)} 字节，账本累计已涨到 {v4}")
    print(f"     每崩一次重拉，--max-bytes 预算多消耗 {len(d1)+len(dd)} 字节（真实写盘量，不是占用量）")
except Exception as e:
    print("  ⛔", type(e).__name__, str(e)[:160])
finally: close(a,b,c)
