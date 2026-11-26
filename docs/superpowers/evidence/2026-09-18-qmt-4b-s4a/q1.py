import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
print("=== Q1：「重拷」这一格到底可不可达、可不可行 ===")

def prep():
    root, src, stg, d1, dd = build()
    m = seed_manifest()
    src_fd, stg_fd, lock_fd, ledger = session(src, stg, m)
    _, m2 = copy_stock(src_fd, stg_fd, SLOT, (R1M, RDAY), m,
                       ledger=ledger, budget=Budget(None, m["committed_bytes"]))
    close(src_fd, stg_fd, lock_fd)
    return root, src, stg, m2, d1, dd

# A) 本地文件被改坏、源没变 → 重拷应得到与账本逐字相同的记录
root, src, stg, m2, d1, dd = prep()
open(os.path.join(stg, R1M), "wb").write(b"CORRUPTED" + b"\x00" * (len(d1) - 9))
src_fd, stg_fd, lock_fd, ledger = session(src, stg, m2)
try:
    rec = [r for r in m2["files"] if r["relative_path"] == R1M][0]
    print("  A) 判据 =", classify(stg_fd, R1M, rec), "（本地坏了、源没变）")
    try:
        st, out = copy_stock(src_fd, stg_fd, SLOT, (R1M, RDAY), m2,
                             ledger=ledger, budget=Budget(None, m2["committed_bytes"]))
        print("     重拷结果 =", st, "| 落地字节复原 =",
              open(os.path.join(stg, R1M), "rb").read() == d1)
        print("     pool_order 有没有重复 =", out["pool_order"]["SH"])
    except Exception as e:
        print("     重拷 →", type(e).__name__, str(e)[:110])
finally:
    close(src_fd, stg_fd, lock_fd)

# B) 本地文件被改坏 + 源也变了 → 应在标记之前终止
root, src, stg, m2, d1, dd = prep()
open(os.path.join(stg, R1M), "wb").write(b"CORRUPTED" + b"\x00" * (len(d1) - 9))
open(os.path.join(src, R1M), "wb").write(b"NEWGEN" + b"\x00" * (len(d1) - 6))   # 等长换代
src_fd, stg_fd, lock_fd, ledger = session(src, stg, m2)
try:
    try:
        copy_stock(src_fd, stg_fd, SLOT, (R1M, RDAY), m2,
                   ledger=ledger, budget=Budget(None, m2["committed_bytes"]))
        print("  B) 没有终止 ← 不该发生")
    except SourceChangedMidRun as e:
        print("  B) 终止 =", type(e).__name__, "|", str(e)[:70])
        print("     在途标记写了吗 =", os.path.exists(os.path.join(stg, INFLIGHT)))
        print("     .part 残留     =", [r for r in (R1M,RDAY) if os.path.exists(os.path.join(stg,r+PART))])
        d = read_manifest(stg_fd)
        print("     cursor 推进了吗 =", d["cursor"]["SH"], "(提交前是", m2["cursor"]["SH"], ")")
finally:
    close(src_fd, stg_fd, lock_fd)

# C) 不跳过已在池里的股，会不会撞「层内 universe_idx 唯一」（S2-F8 的担心）
root, src, stg, m2, d1, dd = prep()
src_fd, stg_fd, lock_fd, ledger = session(src, stg, m2)
try:
    st, out = copy_stock(src_fd, stg_fd, SLOT, (R1M, RDAY), m2,
                         ledger=ledger, budget=Budget(None, m2["committed_bytes"]))
    print("  C) 对已在池里的股再跑一次 =", st, "| pool_order =", out["pool_order"]["SH"])
except Exception as e:
    print("  C) →", type(e).__name__, str(e)[:110])
finally:
    close(src_fd, stg_fd, lock_fd)
