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

# 与整合表「9–12月实际」列一致（表头 M–P）
MONTH_COL = {
    "2026-08": "M",  # 若以后要刷历史月，可扩
    "2026-09": "M",
    "2026-10": "N",
    "2026-11": "O",
    "2026-12": "P",
}
AS_OF_CELL = "O1"


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
    # 10 月起接口常缺「货主招募-新货主」：跳过缺行，有数的照写
    if missing:
        print(f"warn: 新老数据集缺行（跳过）: {missing}")
    if not any(k in ix for k in need):
        raise SystemExit("新老数据集当月无任何举措行，未改表")

    empty: dict = {}
    zm_n, zm_o = ix.get("货主招募-新货主") or empty, ix.get("货主招募-老货主") or empty
    dx_n, dx_o = ix.get("电销-新货主") or empty, ix.get("电销-老货主") or empty
    tl_n, tl_o = ix.get("投流-新货主") or empty, ix.get("投流-老货主") or empty
    dd_n, dd_o = ix.get("调度-新货主") or empty, ix.get("调度-老货主") or empty
    tl_all = ix.get("投流-整体") or {}
    tl_acct = ix.get("投流-注册账号") or {}

    # 行号对齐整合表第七部分当前结构（分组标题行不写；指标行 = 标题行+1）
    raw: dict[str, float | int | None] = {
        # 裂变：100认证 / 102发货 / 103新增运单 / 104人均；107留存运单 / 108留存用户 / 109人均
        "100": _int(zm_n, "renzheng_num"),
        "102": _int(zm_n, "fahuo_num"),
        "103": _num(zm_n, "chengjiao_yundan", 4),
        "104": _num(zm_n, "avg_num", 2),
        "107": _num(zm_o, "chengjiao_yundan", 4),
        "108": _int(zm_o, "chengjiao_num"),
        "109": _num(zm_o, "avg_num", 2),
        # 电销：113–117 留存；120–124 新增；128 认证
        "113": _num(dx_o, "chengjiao_yundan", 4),
        "114": _int(dx_o, "fahuo_num"),
        "115": _int(dx_o, "chengjiao_num"),
        "116": _rate(dx_o),
        "117": _num(dx_o, "avg_num", 2),
        "120": _num(dx_n, "chengjiao_yundan", 4),
        "121": _int(dx_n, "fahuo_num"),
        "122": _int(dx_n, "chengjiao_num"),
        "123": _rate(dx_n),
        "124": _num(dx_n, "avg_num", 2),
        "128": _int(dx_n, "renzheng_num"),
        # 投流：142–146 留存；149–153 新增；156–158 漏斗
        "142": _num(tl_o, "chengjiao_yundan", 4),
        "143": _int(tl_o, "fahuo_num"),
        "144": _int(tl_o, "chengjiao_num"),
        "145": _rate(tl_o),
        "146": _num(tl_o, "avg_num", 2),
        "149": _num(tl_n, "chengjiao_yundan", 4),
        "150": _int(tl_n, "fahuo_num"),
        "151": _int(tl_n, "chengjiao_num"),
        "152": _rate(tl_n),
        "153": _num(tl_n, "avg_num", 2),
        "156": _int(tl_all, "renzheng_num") if tl_all else None,
        "157": _int(tl_all, "zhuce_num") if tl_all else None,
        "158": _int(tl_acct, "zhuce_num") if tl_acct else None,
        # 调度：168合计 / 169新增 / 170留存；176新增发货 / 182留存发货
        "169": _num(dd_n, "chengjiao_yundan", 4),
        "170": _num(dd_o, "chengjiao_yundan", 4),
        "168": round(
            (_num(dd_n, "chengjiao_yundan", 4) or 0) + (_num(dd_o, "chengjiao_yundan", 4) or 0),
            4,
        )
        if (dd_n or dd_o)
        else None,
        "176": _int(dd_n, "fahuo_num"),
        "182": _int(dd_o, "fahuo_num"),
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
                "range": AS_OF_CELL,
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
    col = MONTH_COL.get(month, "O")
    print(f"cells={len(writes)} sample {col}119={writes.get(f'{col}119')} {col}112={writes.get(f'{col}112')}")
    os.chdir(ROOT)
    write_sheet(writes, as_of)
    print("sheet section7 updated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
