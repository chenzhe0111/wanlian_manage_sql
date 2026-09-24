#!/usr/bin/env python3
"""每天拉 Quick BI 月度/周度漏斗（ApiId 9cd9d778e4fd）写回飞书 QbfdXI。

数据服务只暴露 key/type/new_old/index_type/num，且 pt 被编译为
  WHERE 周期起始日 > '{pt}'
因此用相邻 pt 差分还原单周期：
  period_start = D  →  (pt=D-1) 减去 (pt=D) 的多重集差。

写入：本月（月初 1 日）+ 近两周（周起始=周三，含进行中周）。
同时落本地 CSV（带时间戳 + latest）。
"""

from __future__ import annotations

import csv
import json
import os
import subprocess
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent
load_dotenv(ROOT / ".env")

SHEET_URL = os.environ.get(
    "FEISHU_SHEET_URL",
    "https://wanlianyida.feishu.cn/sheets/L91EsEtAohwjhStD4y6cYLCGnVe",
)
SHEET_ID = os.environ.get("FEISHU_SHEET_ID_FUNNEL", "QbfdXI")
API_ID = os.environ.get("QUICKBI_API_ID_FUNNEL", "9cd9d778e4fd")

INIT_ORDER = {
    "货主招募": 1,
    "投流": 2,
    "电销": 3,
    "调度": 4,
    "线下": 5,
    "无线下销售归属": 6,
}
SHIPPER_ORDER = {"整体": 0, "新货主": 1, "老货主": 2}
METRIC_ORDER = {
    "注册企业数": 1,
    "注册账号": 2,
    "认证企业数": 3,
    "发货货主数": 4,
    "成交货主数": 5,
    "成交运单量": 6,
}


def _lark(*args: str) -> dict:
    cmd = ["lark-cli", "sheets", *args, "--url", SHEET_URL, "--as", "user", "--format", "json"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(proc.stderr or proc.stdout or f"lark-cli failed: {args}")
    data = json.loads(proc.stdout)
    if not data.get("ok", True):
        raise SystemExit(json.dumps(data.get("error") or data, ensure_ascii=False)[:2000])
    return data


def _last_wednesday_on_or_before(d: date) -> date:
    return d - timedelta(days=(d.weekday() - 2) % 7)


def _week_starts(as_of: date, n: int = 2) -> list[date]:
    start = _last_wednesday_on_or_before(as_of)
    return [start - timedelta(days=7 * i) for i in range(n)]


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return v


def _fetch_raw(exp, pt: str) -> list[dict]:
    payload = exp.query_data(API_ID, conditions=json.dumps({"pt": pt}, ensure_ascii=False))
    result = payload.get("Result") or payload.get("result") or {}
    rows = exp._normalize_rows(result.get("Values") or result.get("values") or [])
    print(f"  pt={pt} rows={len(rows)} req={payload.get('RequestId')}")
    return rows


def _multiset_by_key(rows: list[dict]) -> dict[str, list[dict]]:
    m: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        k = str(r.get("key") or "").strip()
        if not k:
            continue
        m[k].append(r)
    return m


def _diff_period(lo_rows: list[dict], hi_rows: list[dict]) -> list[dict]:
    """lo = period_start > D-1；hi = period_start > D；差集 ≈ period_start = D。"""
    hi_m = _multiset_by_key(hi_rows)
    out: list[dict] = []
    for k, rows in _multiset_by_key(lo_rows).items():
        remaining = list(rows)
        for hr in hi_m.get(k, []):
            hn = _num(hr.get("num"))
            for i, rr in enumerate(remaining):
                if _num(rr.get("num")) == hn:
                    remaining.pop(i)
                    break
        out.extend(remaining)
    return out


def _fetch_period(exp, period_start: date) -> list[dict] | None:
    lo = (period_start - timedelta(days=1)).strftime("%Y%m%d")
    hi = period_start.strftime("%Y%m%d")
    try:
        lo_rows = _fetch_raw(exp, lo)
        hi_rows = _fetch_raw(exp, hi)
    except Exception as exc:  # noqa: BLE001
        print(f"  period={period_start} fetch error: {exc}", file=sys.stderr)
        return None
    rows = _diff_period(lo_rows, hi_rows)
    print(f"  period={period_start} isolated rows={len(rows)} (lo={len(lo_rows)} hi={len(hi_rows)})")
    return rows if rows else None


def _sort_key(r: dict) -> tuple:
    return (
        INIT_ORDER.get(str(r.get("type") or "").strip(), 99),
        SHIPPER_ORDER.get(str(r.get("new_old") or "").strip(), 99),
        METRIC_ORDER.get(str(r.get("index_type") or "").strip(), 99),
        str(r.get("key") or ""),
    )


def build_grid(blocks: list[tuple[str, date, list[dict]]]) -> list[list[dict]]:
    header = ["月周标识", "主键", "周期起始日", "举措", "新老货主", "指标类型", "指标值"]
    grid: list[list[dict]] = [[{"value": h} for h in header]]

    def cell(v):
        return {"value": v}

    for grain, period_start, rows in blocks:
        ps = period_start.isoformat()
        for r in sorted(rows, key=_sort_key):
            num = _num(r.get("num"))
            if isinstance(num, float) and num == int(num):
                num_v: float | int = int(num)
            elif isinstance(num, float):
                num_v = round(num, 6)
            else:
                num_v = num
            grid.append(
                [
                    cell(grain),
                    cell(str(r.get("key") or "").strip()),
                    cell(ps),
                    cell(str(r.get("type") or "").strip()),
                    cell(str(r.get("new_old") or "").strip()),
                    cell(str(r.get("index_type") or "").strip()),
                    cell(num_v),
                ]
            )
    return grid


def write_sheet(grid: list[list[dict]], title: str) -> None:
    n = len(grid)
    ops = [
        {
            "shortcut": "+cells-clear",
            "input": {"sheet_id": SHEET_ID, "range": "A1:G2000", "scope": "all"},
        },
        {
            "shortcut": "+cells-set",
            "input": {
                "sheet_id": SHEET_ID,
                "range": "A1",
                "cells": [
                    [
                        {
                            "value": title,
                            "cell_styles": {
                                "font_weight": "bold",
                                "font_size": 13,
                                "background_color": "#FFF2CC",
                            },
                        }
                    ]
                ],
            },
        },
        {
            "shortcut": "+cells-merge",
            "input": {"sheet_id": SHEET_ID, "range": "A1:G1", "merge_type": "all"},
        },
        {
            "shortcut": "+cells-set",
            "input": {
                "sheet_id": SHEET_ID,
                "range": f"A2:G{n + 1}",
                "cells": [
                    [
                        {
                            **c,
                            "cell_styles": {
                                **(
                                    {
                                        "background_color": "#BDD7EE",
                                        "font_weight": "bold",
                                        "horizontal_alignment": "center",
                                    }
                                    if i == 0
                                    else {}
                                ),
                                "vertical_alignment": "middle",
                                "font_size": 11,
                            },
                        }
                        for c in row
                    ]
                    for i, row in enumerate(grid)
                ],
            },
        },
    ]
    payload = ROOT / "logs" / "sheet_funnel_ops.json"
    payload.parent.mkdir(parents=True, exist_ok=True)
    payload.write_text(json.dumps(ops, ensure_ascii=False), encoding="utf-8")
    rel = payload.relative_to(ROOT).as_posix()
    _lark("+batch-update", "--yes", "--operations", f"@./{rel}")


def _write_csv(blocks: list[tuple[str, date, list[dict]]], stamp: str) -> Path:
    out_dir = ROOT / "out"
    out_dir.mkdir(exist_ok=True)
    fieldnames = ["月周标识", "主键", "周期起始日", "举措", "新老货主", "指标类型", "指标值"]
    flat = []
    for grain, period_start, rows in blocks:
        for r in sorted(rows, key=_sort_key):
            flat.append(
                {
                    "月周标识": grain,
                    "主键": str(r.get("key") or "").strip(),
                    "周期起始日": period_start.isoformat(),
                    "举措": str(r.get("type") or "").strip(),
                    "新老货主": str(r.get("new_old") or "").strip(),
                    "指标类型": str(r.get("index_type") or "").strip(),
                    "指标值": r.get("num"),
                }
            )
    csv_path = out_dir / f"quickbi_funnel_{stamp}.csv"
    latest = out_dir / "quickbi_funnel_latest.csv"
    for path in (csv_path, latest):
        with path.open("w", newline="", encoding="utf-8-sig") as f:
            w = csv.DictWriter(f, fieldnames=fieldnames)
            w.writeheader()
            w.writerows(flat)
    print(f"csv rows={len(flat)} wrote {csv_path.name}")
    return csv_path


def main() -> int:
    sys.path.insert(0, str(ROOT))
    import export_dataset as exp

    as_of = datetime.now().date() - timedelta(days=1)
    print(f"[{datetime.now():%F %T}] funnel refresh as_of={as_of} api={API_ID}")

    month_start = as_of.replace(day=1)
    week_starts = _week_starts(as_of, n=2)
    print(f"target month={month_start.isoformat()} weeks={[w.isoformat() for w in week_starts]}")

    blocks: list[tuple[str, date, list[dict]]] = []
    missing: list[str] = []

    print("fetch month …")
    month_rows = _fetch_period(exp, month_start)
    if month_rows:
        blocks.append(("月度", month_start, month_rows))
    else:
        missing.append(f"月度{month_start.isoformat()}")

    for ws in week_starts:
        print(f"fetch week {ws} …")
        rows = _fetch_period(exp, ws)
        if rows:
            blocks.append(("周度", ws, rows))
        else:
            missing.append(f"周度{ws.isoformat()}")

    if not blocks:
        raise SystemExit(f"本月与近两周均无数据: month={month_start} weeks={week_starts}")

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    _write_csv(blocks, stamp)

    got = "、".join(
        ("月" if g == "月度" else "周") + p.strftime("%m/%d") for g, p, _ in blocks
    )
    title = (
        f"月度周度漏斗｜本月 {month_start.strftime('%Y-%m')}｜近两周 "
        f"{week_starts[0].strftime('%m/%d')}&{week_starts[1].strftime('%m/%d')}"
        f"｜已写入 {got}｜刷新日 {as_of.isoformat()}"
    )
    if missing:
        title += "｜暂无 " + "、".join(missing)

    grid = build_grid(blocks)
    os.chdir(ROOT)
    write_sheet(grid, title)
    print(
        f"sheet {SHEET_ID} updated blocks="
        f"{[(g, p.isoformat(), len(r)) for g, p, r in blocks]} missing={missing}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
