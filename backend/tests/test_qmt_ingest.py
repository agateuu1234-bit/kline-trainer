import pytest
from qmt_ingest import ExportLogEntry, parse_export_log, QmtIngestRejected
from qmt_normalize import QmtSchemaError

def _write_log(tmp_path, rows):
    import csv
    p = tmp_path / "export_log.csv"
    with open(p, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f); w.writerow(["stock", "period", "status", "rows", "first_time", "last_time"])
        for r in rows: w.writerow(r)
    return p

def test_parse_export_log_basic(tmp_path):
    p = _write_log(tmp_path, [["000001.SZ", "1m", "ok", "241", "20200102093000", "20200102150000"]])
    d = parse_export_log(p)
    e = d[("000001.SZ", "1m")]
    assert e.code == "000001.SZ" and e.period == "1m" and e.status == "ok" and e.rows == 241

def test_parse_export_log_missing_column_raises(tmp_path):
    import csv
    p = tmp_path / "export_log.csv"
    with open(p, "w", newline="", encoding="utf-8-sig") as f:
        csv.writer(f).writerow(["stock", "period", "status"])   # 缺 rows/first/last
    with pytest.raises(QmtSchemaError):
        parse_export_log(p)

def test_parse_export_log_duplicate_key_raises(tmp_path):
    p = _write_log(tmp_path, [
        ["000001.SZ", "1m", "error", "1", "20200102093000", "20200102093000"],
        ["000001.SZ", "1m", "ok", "241", "20200102093000", "20200102150000"]])
    with pytest.raises(QmtSchemaError) as ei:
        parse_export_log(p)
    assert "export_log_duplicate" in str(ei.value)
