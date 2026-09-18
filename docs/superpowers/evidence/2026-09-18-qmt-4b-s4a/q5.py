import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
print("=== Q5：按股事务五步端到端 ===")
root, src, stg, d1, dd = build()
m = seed_manifest()
src_fd, stg_fd, lock_fd, ledger = session(src, stg, m)
try:
    status, out = copy_stock(src_fd, stg_fd, SLOT, (R1M, RDAY), m,
                             ledger=ledger, budget=Budget(None, m["committed_bytes"]))
    print("  status          =", status)
    print("  两个 final 都在  =", all(os.path.exists(os.path.join(stg,r)) for r in (R1M,RDAY)))
    print("  .part 残留      =", [r for r in (R1M,RDAY) if os.path.exists(os.path.join(stg,r+PART))])
    print("  在途标记残留     =", os.path.exists(os.path.join(stg,INFLIGHT)))
    disk = read_manifest(stg_fd)
    print("  files 条数      =", len(disk["files"]))
    print("  pool_order[SH]  =", disk["pool_order"]["SH"])
    print("  cursor[SH]      =", disk["cursor"]["SH"])
    print("  committed_bytes =", disk["committed_bytes"],
          " (= 两文件 %d + export_log %d)" % (len(d1)+len(dd), len(ELOG_BYTES)))
finally:
    close(src_fd, stg_fd, lock_fd)
