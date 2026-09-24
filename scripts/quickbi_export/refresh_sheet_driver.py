#!/usr/bin/env python3
"""每天把 Quick BI「注册司机分类型」T-1 实际写回飞书「注册司机车辆数据」。

ApiId 默认 QUICKBI_API_ID_DRIVER（a136c69111d1）。
pt 入参为 YYYYMMDD。

接口没有月份列，固定从 1 月起每月一行。用第 8 行 TMS 运单量（约 72.7 万）
确认仍是 1–N 月顺序，再取当月那一行。只回写该月实际列：
  J=9月 K=10月 L=11月 M=12月
行：7 业务合计（三类相加）、8–10 TMS、11–13 撮合、14–16 网货。
不改 J1 标题，也不写累计/当月新增（接口未返回）。
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
SHEET_ID = "41UJIa"
API_ID = os.environ.get("QUICKBI_API_ID_DRIVER", "a136c69111d1")

MONTH_COL = {
    "2026-09": "J",
    "2026-10": "K",
    "2026-11": "L",
    "2026-12": "M",
}

# (row, api field or "biz", decimals)
ROW_SPEC = [
    (8, "tms_driver", 4),
    (9, "tms_avg", 2),
    (10, "tms_num", 4),
    (11, "cuohe_driver", 4),
    (12, "cuohe_avg", 2),
    (13, "cuohe_num", 4),
    (14, "wanghuo_driver", 4),
    (15, "wanghuo_avg", 2),
    (16, "wanghuo_num", 4),
]


def _num(row: dict, key: str, ndigits: int) -> float | None:
    if key not in row or row[key] is None or str(row[key]).strip() == "":
        return None
    return round(float(row[key]), ndigits)


def pick_month_row(rows: list[dict], month: str) -> dict:
    """接口从 1 月起按顺序返回，无月份字段。"""
    year, mon = month.split("-")
    if year != "2026":
        raise SystemExit(f"只支持 2026 年，当前 {month}")
    idx = int(mon) - 1
    if len(rows) <= idx:
        raise SystemExit(f"期望至少 {int(mon)} 行（1月起），实际 {len(rows)} 行，未改表")
    if len(rows) <= 7:
        raise SystemExit("不足 8 行，无法用 8 月 TMS 运单量校验顺序，未改表")
    aug_tms = _num(rows[7], "tms_num", 4)
    if aug_tms is None or not (70 <= aug_tms <= 75):
        raise SystemExit(f"第8行 TMS 运单量={aug_tms}，不像 8 月（约 72.7），未改表")
    return rows[idx]


def build_writes(row: dict, month: str) -> dict[str, float]:
    col = MONTH_COL.get(month)
    if not col:
        raise SystemExit(f"没有 {month} 的实际列映射")
    out: dict[str, float] = {}
    parts = []
    for r, key, nd in ROW_SPEC:
        v = _num(row, key, nd)
        if v is None:
            continue
        out[f"{col}{r}"] = v
        if key.endswith("_driver"):
            parts.append(v)
    if len(parts) == 3:
        out[f"{col}7"] = round(sum(parts), 4)
    if not out:
        raise SystemExit("当月行没有可写指标，未改表")
    return out


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


def write_sheet(cell_values: dict[str, float]) -> None:
    ops = []
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
    payload = ROOT / "logs" / "sheet_driver_ops.json"
    payload.parent.mkdir(parents=True, exist_ok=True)
    payload.write_text(json.dumps(ops, ensure_ascii=False), encoding="utf-8")
    rel = payload.relative_to(ROOT).as_posix()
    _lark("+batch-update", "--yes", "--operations", f"@./{rel}")


def main() -> int:
    sys.path.insert(0, str(ROOT))
    import export_dataset as exp

    as_of = (datetime.now().date() - timedelta(days=1)).strftime("%Y-%m-%d")
    pt = as_of.replace("-", "")
    month = as_of[:7]
    print(f"[{datetime.now():%F %T}] driver refresh as_of={as_of} pt={pt} api={API_ID}")

    payload = exp.query_data(API_ID, conditions=json.dumps({"pt": pt}, ensure_ascii=False))
    result = payload.get("Result") or payload.get("result") or {}
    rows = exp._normalize_rows(result.get("Values") or result.get("values") or [])
    print(f"rows={len(rows)} request_id={payload.get('RequestId') or payload.get('request_id')}")
    if not rows:
        raise SystemExit(f"没有 pt={pt} 的司机数据，未改表")

    row = pick_month_row(rows, month)
    writes = build_writes(row, month)
    print("writes", json.dumps(writes, ensure_ascii=False))
    os.chdir(ROOT)
    write_sheet(writes)
    print("driver sheet updated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
