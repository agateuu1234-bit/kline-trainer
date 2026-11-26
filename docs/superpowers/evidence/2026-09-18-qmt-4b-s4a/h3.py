import os, sys, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
import qmt_manifest as QM
print("=== H3：重拷成功那一格，转移守卫算出的 added 是多少 ===")
root, src, stg, d1, dd = build(); m = seed_manifest()
a,b,c,l = session(src, stg, m)
def recs():
    return [{"stock_code":CODE,"period":p,"relative_path":r,"bytes":len(x),
             "sha256":hashlib.sha256(x).hexdigest()} for p,r,x in (("1m",R1M,d1),("daily",RDAY,dd))]
try:
    t = dict(m); t["files"] = recs()
    t["pool_order"]={"SH":[{"code":CODE,"universe_idx":0}],"SZ":[],"BJ":[]}
    t["cursor"]={"SH":1,"SZ":0,"BJ":0}
    t["committed_bytes"] = m["committed_bytes"] + len(d1)+len(dd)
    QM.commit_stock(b, t, ledger=l)
    ob = read_manifest(b)["committed_bytes"]
    print(f"  首次提交后 ob = {ob}")
    # 重拷成功：记录逐字相同（本地坏了、源没变），本次真写了 1m 那份 = len(d1)
    print(f"  重拷成功时：记录逐字相同 ⇒ prev 里已有该 key ⇒ added = 0")
    print(f"  但本次真写盘 {len(d1)} 字节（1m 那份）")
    for label, nb in (("严格相等 nb == ob + added = ob", ob),
                      ("累计语义 nb = ob + 本次写盘", ob + len(d1))):
        t2 = dict(read_manifest(b)); t2["files"] = recs(); t2["committed_bytes"] = nb
        try:
            QM.commit_stock(b, t2, ledger=l); print(f"    {label} → {nb} 接受")
        except Exception as e:
            print(f"    {label} → {nb} ⛔ {str(e)[:80]}")
finally: close(a,b,c)
