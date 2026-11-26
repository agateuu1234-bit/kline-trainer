# -*- coding: utf-8 -*-
"""实验台：造源树/staging，跑场景，打印真实答案。"""
import os, sys, hashlib, tempfile, shutil, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine import *
from qmt_fsroot import open_root, acquire_lock, atomic_write_json
from qmt_manifest import begin_run, read_manifest

R1M   = "1分钟K线_前复权/600000.SH_浦发银行_1分钟K线_前复权.csv"
RDAY  = "日K线_前复权/600000.SH_浦发银行_日K线_前复权.csv"
CODE  = "600000.SH"
SLOT  = {"code": CODE, "market": "SH", "universe_idx": 0}
ELOG_BYTES = b"stock,period\n600000.SH,1m\n"

def sha(b): return hashlib.sha256(b).hexdigest()

def seed_manifest(universe=(CODE,)):
    return {"manifest_version": 1, "seed": "spike",
        "source_snapshot": {"export_log_sha256": sha(ELOG_BYTES),
                            "universe": {"SH": list(universe), "SZ": [], "BJ": []}},
        "source_mount": {"fstype":"smbfs","device":"//u@h/s","source_root_relative":"r"},
        "pool_order": {"SH": [], "SZ": [], "BJ": []},
        "cursor": {"SH": 0, "SZ": 0, "BJ": 0}, "files": [],
        "staged_export_log": {"relative_path":"export_log.csv",
                              "bytes": len(ELOG_BYTES), "sha256": sha(ELOG_BYTES)},
        "source_verification": "partial",
        "source_verification_evidence": {"level":"partial","passes":[]},
        "committed_bytes": len(ELOG_BYTES)}

def build(d1=b"1m-data"*20, dd=b"daily-data"*20):
    root = os.path.realpath(tempfile.mkdtemp(prefix="spike_"))
    src, stg = os.path.join(root,"src"), os.path.join(root,"stg")
    for p in (src, stg): os.makedirs(p)
    for rel, data in ((R1M, d1), (RDAY, dd)):
        fp = os.path.join(src, rel)
        os.makedirs(os.path.dirname(fp), exist_ok=True)
        open(fp,"wb").write(data)
    return root, src, stg, d1, dd

def session(src, stg, manifest):
    """返回 (src_fd, stg_fd, lock_fd, ledger)；调用方负责 close。"""
    src_fd, stg_fd = open_root(src), open_root(stg)
    atomic_write_json(stg_fd, "fetch_manifest.json", manifest, full_sync=False)
    open(os.path.join(stg,"export_log.csv"),"wb").write(ELOG_BYTES)
    lock_fd = acquire_lock(stg_fd, ".staging.lock", tool="qmt_fetch")
    return src_fd, stg_fd, lock_fd, begin_run(stg_fd)

def close(*fds):
    for f in fds:
        try: os.close(f)
        except Exception: pass
