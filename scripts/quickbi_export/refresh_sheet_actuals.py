#!/usr/bin/env python3
"""每天把 Quick BI T-1 实际写回飞书整合表。

口径：pt = 昨天；只回写该月「实际」列（9月=H … 12月=K），并更新 J1 统计截止日。
不改公式列（占比、达成率、时间进度）。
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

# 实际列：与表头「9月实际 / 10月实际 / 11月实际 / 12月实际」一致
MONTH_COL = {
    "202609": "H",
    "202610": "I",
    "202611": "J",
    "202612": "K",
}


def _f(row: dict, key: str, ndigits: int = 4) -> float:
    return round(float(row[key]), ndigits)


def _index(rows: list[dict]) -> dict[tuple[str, str], dict]:
    out = {}
    for r in rows:
        out[(str(r.get("key1", "")).strip(), str(r.get("key2", "")).strip())] = r
    return out


def build_writes(rows: list[dict], month: str) -> dict[str, float]:
    """返回 {单元格: 数值}，不含表头与公式格。"""
    ix = _index(rows)
    need = {
        ("整体", "整体"),
        ("运单类型", "整体-网货"),
        ("运单类型", "整体-撮合"),
        ("运单类型", "整体-TMS"),
        ("线下线上", "线上"),
        ("线下线上", "线下"),
        ("线上举措", "货主招募"),
        ("线上举措", "电销"),
        ("线上举措", "投流"),
        ("线上举措", "调度"),
        ("运单类型", "线上-TMS"),
        ("运单类型", "线上-撮合"),
        ("运单类型", "线上-网货"),
        # 第七部分「举措×新老」明细改由 refresh_sheet_newold.py 回写
    }
    missing = [k for k in need if k not in ix]
    if missing:
        raise SystemExit(f"数据集缺行: {missing}")

    g = ix[("整体", "整体")]
    wh = ix[("运单类型", "整体-网货")]
    ch = ix[("运单类型", "整体-撮合")]
    tms = ix[("运单类型", "整体-TMS")]
    online = ix[("线下线上", "线上")]
    offline = ix[("线下线上", "线下")]
    zm = ix[("线上举措", "货主招募")]
    dx = ix[("线上举措", "电销")]
    tl = ix[("线上举措", "投流")]
    dd = ix[("线上举措", "调度")]
    writes = {
        "3": _f(g, "avg_num"),
        "4": _f(g, "max_num"),
        "5": _f(g, "month_num"),
        "6": _f(g, "gtv_1"),
        "13": _f(wh, "gtv_1"),
        "14": _f(wh, "avg_cost", 2),
        "15": _f(wh, "avg_num"),
        "16": _f(wh, "max_num"),
        "17": _f(wh, "month_num"),
        "20": _f(ch, "gtv_1"),
        "21": _f(ch, "avg_cost", 2),
        "22": _f(ch, "avg_num"),
        "23": _f(ch, "max_num"),
        "24": _f(ch, "month_num"),
        "27": _f(tms, "gtv_1"),
        "28": _f(tms, "avg_cost", 2),
        "29": _f(tms, "avg_num"),
        "30": _f(tms, "max_num"),
        "31": _f(tms, "month_num"),
        "57": _f(offline, "max_num"),
        "64": _f(online, "month_num"),
        "65": _f(online, "avg_num"),
        "66": _f(online, "max_num"),
        "72": _f(zm, "month_num"),
        "73": _f(dx, "month_num"),
        "74": _f(tl, "month_num"),
        "75": _f(dd, "month_num"),
        "76": round(_f(zm, "month_num") + _f(dx, "month_num") + _f(tl, "month_num") + _f(dd, "month_num"), 4),
        "85": _f(ix[("运单类型", "线上-TMS")], "month_num"),
        "86": _f(ix[("运单类型", "线上-撮合")], "month_num"),
        "87": _f(ix[("运单类型", "线上-网货")], "month_num"),
        "88": _f(online, "month_num"),
    }
    col = MONTH_COL.get(month)
    if not col:
        raise SystemExit(f"没有 {month} 的实际列映射（仅支持 202609–202612）")
    return {f"{col}{row}": val for row, val in writes.items()}


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


def write_sheet(cell_values: dict[str, float], as_of: str) -> None:
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
    payload = ROOT / "logs" / "sheet_write_ops.json"
    payload.parent.mkdir(parents=True, exist_ok=True)
    payload.write_text(json.dumps(ops, ensure_ascii=False), encoding="utf-8")
    rel = payload.relative_to(ROOT).as_posix()
    _lark("+batch-update", "--yes", "--operations", f"@./{rel}")


def main() -> int:
    sys.path.insert(0, str(ROOT))
    import export_dataset as exp

    as_of = (datetime.now().date() - timedelta(days=1)).strftime("%Y-%m-%d")
    month = as_of[:7].replace("-", "")
    print(f"[{datetime.now():%F %T}] refresh as_of={as_of} month={month}")

    payload = exp.query_data(
        os.environ["QUICKBI_API_ID"],
        conditions=json.dumps({"pt": as_of}, ensure_ascii=False),
    )
    result = payload.get("Result") or payload.get("result") or {}
    rows = exp._normalize_rows(result.get("Values") or result.get("values") or [])
    rows = [r for r in rows if str(r.get("pt", ""))[:10] == as_of and str(r.get("month")) == month]
    print(f"rows={len(rows)} request_id={payload.get('RequestId') or payload.get('request_id')}")
    if not rows:
        raise SystemExit(f"没有 pt={as_of} month={month} 的数据，未改表")

    writes = build_writes(rows, month)
    print(f"cells={len(writes)} J1={as_of} sample H3={writes.get('H3')}")
    # run from ROOT so @relative path works
    os.chdir(ROOT)
    write_sheet(writes, as_of)
    print("sheet updated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
