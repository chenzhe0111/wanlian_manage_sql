#!/usr/bin/env python3
"""每天把 Quick BI「新老货主」T-1 实际写回飞书整合表第七部分。

ApiId 默认 QUICKBI_API_ID_NEWOLD（f181db8dd61c）。
注意：此接口 pt 入参格式为 YYYYMMDD（与整体实际接口的 YYYY-MM-DD 不同）。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent
load_dotenv(ROOT / ".env")

SHEET_URL = os.environ.get(
    "FEISHU_SHEET_URL",
    "https://wanlianyida.feishu.cn/sheets/L91EsEtAohwjhStD4y6cYLCGnVe",
)
SHEET_ID = "1074dd"
API_ID = os.environ.get("QUICKBI_API_ID_NEWOLD", "f181db8dd61c")

MONTH_COL = {
    "2026-08": "H",  # 若以后要刷历史月，可扩
    "2026-09": "H",
    "2026-10": "I",
    "2026-11": "J",
    "2026-12": "K",
}


def _num(row: dict, key: str, ndigits: int | None = None):
    if key not in row or row[key] is None or str(row[key]).strip() == "":
        return None
    v = float(row[key])
    if ndigits is None:
        return v
    return round(v, ndigits)


def _int(row: dict, key: str):
    v = _num(row, key)
    return None if v is None else int(round(v))


def _rate(row: dict) -> float | None:
    ship = _num(row, "fahuo_num")
    deal = _num(row, "chengjiao_num")
    if ship is None or deal is None or ship == 0:
        return None
    return round(deal / ship, 4)


def build_writes(rows: list[dict], month: str) -> dict[str, float | int]:
    ix = {(str(r.get("index2", "")).strip()): r for r in rows if str(r.get("month")) == month}
    need = [
        "货主招募-新货主",
        "货主招募-老货主",
        "电销-新货主",
        "电销-老货主",
        "投流-新货主",
        "投流-老货主",
        "调度-新货主",
        "调度-老货主",
    ]
    missing = [k for k in need if k not in ix]
    if missing:
        raise SystemExit(f"新老数据集缺行: {missing}")

    zm_n, zm_o = ix["货主招募-新货主"], ix["货主招募-老货主"]
    dx_n, dx_o = ix["电销-新货主"], ix["电销-老货主"]
    tl_n, tl_o = ix["投流-新货主"], ix["投流-老货主"]
    dd_n, dd_o = ix["调度-新货主"], ix["调度-老货主"]
    tl_all = ix.get("投流-整体") or {}
    tl_acct = ix.get("投流-注册账号") or {}

    raw: dict[str, float | int | None] = {
        # 裂变
        "99": _int(zm_n, "renzheng_num"),
        "101": _int(zm_n, "fahuo_num"),
        "102": _num(zm_n, "chengjiao_yundan", 4),
        "103": _num(zm_n, "avg_num", 2),
        "106": _num(zm_o, "chengjiao_yundan", 4),
        "107": _int(zm_o, "chengjiao_num"),
        "108": _num(zm_o, "avg_num", 2),
        # 电销留存 / 新增
        "112": _num(dx_o, "chengjiao_yundan", 4),
        "113": _int(dx_o, "fahuo_num"),
        "114": _int(dx_o, "chengjiao_num"),
        "115": _rate(dx_o),
        "116": _num(dx_o, "avg_num", 2),
        "119": _num(dx_n, "chengjiao_yundan", 4),
        "120": _int(dx_n, "fahuo_num"),
        "121": _int(dx_n, "chengjiao_num"),
        "122": _rate(dx_n),
        "123": _num(dx_n, "avg_num", 2),
        "127": _int(dx_n, "renzheng_num"),
        # 投流留存 / 新增
        "141": _num(tl_o, "chengjiao_yundan", 4),
        "142": _int(tl_o, "fahuo_num"),
        "143": _int(tl_o, "chengjiao_num"),
        "144": _rate(tl_o),
        "145": _num(tl_o, "avg_num", 2),
        "148": _num(tl_n, "chengjiao_yundan", 4),
        "149": _int(tl_n, "fahuo_num"),
        "150": _int(tl_n, "chengjiao_num"),
        "151": _rate(tl_n),
        "152": _num(tl_n, "avg_num", 2),
        "155": _int(tl_all, "renzheng_num") if tl_all else None,
        "156": _int(tl_all, "zhuce_num") if tl_all else None,
        "157": _int(tl_acct, "zhuce_num") if tl_acct else None,
        # 调度
        "168": _num(dd_n, "chengjiao_yundan", 4),
        "169": _num(dd_o, "chengjiao_yundan", 4),
        "167": round(
            (_num(dd_n, "chengjiao_yundan", 4) or 0) + (_num(dd_o, "chengjiao_yundan", 4) or 0),
            4,
        ),
        "175": _int(dd_n, "fahuo_num"),
        "181": _int(dd_o, "fahuo_num"),
    }
    col = MONTH_COL.get(month)
    if not col:
        raise SystemExit(f"没有 {month} 的实际列映射")
    return {f"{col}{r}": v for r, v in raw.items() if v is not None}


def _lark(*args: str) -> dict:
    cmd = ["lark-cli", "sheets", *args, "--as", "user", "--url", SHEET_URL, "--format", "json"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    raw = proc.stdout or proc.stderr
    i = raw.find("{")
    if proc.returncode != 0 or i < 0:
        raise SystemExit(raw[-2000:] or f"lark-cli failed {proc.returncode}")
    data = json.loads(raw[i:])
    if not data.get("ok", True):
        raise SystemExit(json.dumps(data.get("error") or data, ensure_ascii=False)[:2000])
    return data


def write_sheet(cell_values: dict[str, float | int], as_of: str) -> None:
    ops = [
        {
            "shortcut": "+cells-set",
            "input": {
                "sheet_id": SHEET_ID,
                "range": "J1",
                "cells": [[{"value": as_of}]],
            },
        }
    ]
    for addr, val in cell_values.items():
        ops.append(
            {
                "shortcut": "+cells-set",
                "input": {
                    "sheet_id": SHEET_ID,
                    "range": addr,
                    "cells": [[{"value": val}]],
                },
            }
        )
    payload = ROOT / "logs" / "sheet_newold_ops.json"
    payload.parent.mkdir(parents=True, exist_ok=True)
    payload.write_text(json.dumps(ops, ensure_ascii=False), encoding="utf-8")
    rel = payload.relative_to(ROOT).as_posix()
    _lark("+batch-update", "--yes", "--operations", f"@./{rel}")


def main() -> int:
    sys.path.insert(0, str(ROOT))
    import export_dataset as exp

    as_of = (datetime.now().date() - timedelta(days=1)).strftime("%Y-%m-%d")
    pt = as_of.replace("-", "")  # YYYYMMDD
    month = as_of[:7]  # 2026-09
    print(f"[{datetime.now():%F %T}] newold refresh as_of={as_of} pt={pt} api={API_ID}")

    payload = exp.query_data(API_ID, conditions=json.dumps({"pt": pt}, ensure_ascii=False))
    result = payload.get("Result") or payload.get("result") or {}
    rows = exp._normalize_rows(result.get("Values") or result.get("values") or [])
    rows = [r for r in rows if str(r.get("month", "")).startswith(month)]
    print(f"rows={len(rows)} request_id={payload.get('RequestId') or payload.get('request_id')}")
    if not rows:
        raise SystemExit(f"没有 month={month} 的新老数据，未改表")

    writes = build_writes(rows, month)
    print(f"cells={len(writes)} sample H119={writes.get('H119')} H112={writes.get('H112')}")
    os.chdir(ROOT)
    write_sheet(writes, as_of)
    print("sheet section7 updated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
