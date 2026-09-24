#!/usr/bin/env python3
"""每天拉 Quick BI 周度数据（最近两周）写回飞书「周度详细数据」。

ApiId 默认 QUICKBI_API_ID_WEEKLY（6148260aafa3）。
周口径：周三～周二；取最近两个「周起始日=周三」≤ as_of 的周（含进行中的本周）。

重要：数据服务把 pt 编译为 `周起始日 > pt`（不是分区日等号），且返回行不带周起始日。
因此用相邻 pt 差分还原单周：
  week_start = D  →  (pt=D-1) 减去 (pt=D) 的多重集差。
"""

from __future__ import annotations

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
SHEET_ID = os.environ.get("FEISHU_SHEET_ID_WEEKLY", "66mgnV")
API_ID = os.environ.get("QUICKBI_API_ID_WEEKLY", "6148260aafa3")


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
    # Mon=0 … Sun=6; Wednesday=2
    return d - timedelta(days=(d.weekday() - 2) % 7)


def _week_starts(as_of: date, n: int = 2) -> list[date]:
    """最近 n 个周的周三起始日（含 as_of 所在周，不要求周已结束）。"""
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


def _multiset_by_index2(rows: list[dict]) -> dict[str, list[dict]]:
    m: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        k = str(r.get("index2") or "").strip()
        if not k:
            continue
        m[k].append(r)
    return m


def _diff_week(lo_rows: list[dict], hi_rows: list[dict]) -> list[dict]:
    """lo = 周起始日 > D-1；hi = 周起始日 > D；差集 ≈ 周起始日 = D。"""
    hi_m = _multiset_by_index2(hi_rows)
    out: list[dict] = []
    for k, rows in _multiset_by_index2(lo_rows).items():
        remaining = list(rows)
        for hr in hi_m.get(k, []):
            hn = _num(hr.get("num"))
            for i, rr in enumerate(remaining):
                if _num(rr.get("num")) == hn:
                    remaining.pop(i)
                    break
        out.extend(remaining)
    return out


def _fetch_week(exp, week_start: date, as_of: date) -> tuple[date, list[dict]] | None:
    """差分还原单周；无数据返回 None。"""
    if as_of < week_start:
        print(f"  week_start={week_start} skip (as_of 早于本周)")
        return None
    lo = (week_start - timedelta(days=1)).strftime("%Y%m%d")
    hi = week_start.strftime("%Y%m%d")
    try:
        lo_rows = _fetch_raw(exp, lo)
        hi_rows = _fetch_raw(exp, hi)
    except Exception as exc:  # noqa: BLE001
        print(f"  week_start={week_start} fetch error: {exc}", file=sys.stderr)
        return None
    rows = _diff_week(lo_rows, hi_rows)
    # 同一 index2 若仍重复，保留首次
    seen: set[str] = set()
    deduped: list[dict] = []
    for r in rows:
        k = str(r.get("index2") or "").strip()
        if not k or k in seen:
            continue
        seen.add(k)
        deduped.append(r)
    print(
        f"  week_start={week_start} isolated rows={len(deduped)}"
        f" (lo={len(lo_rows)} hi={len(hi_rows)})"
    )
    if not deduped:
        return None
    # pt 列记差分下界（D-1），便于追溯
    return week_start - timedelta(days=1), deduped

def _month_week_label(week_start: date) -> str:
    """M9W2 风格：自然月内第几个周三周。"""
    first = week_start.replace(day=1)
    # 该月第一个周三
    first_wed = first + timedelta(days=(2 - first.weekday()) % 7)
    if week_start < first_wed:
        # 跨月周归到起始日所在月的 W0/上月 — 仍按起始日月份计
        first_wed = first_wed
    idx = ((week_start - first_wed).days // 7) + 1
    if week_start < first_wed:
        idx = 0
    return f"M{week_start.month}W{idx}"


def build_table(weeks: list[tuple[date, date, list[dict]]]) -> list[list[dict]]:
    """返回含表头的 cells 二维数组。"""
    header = ["周起始日", "周标签", "统计层级", "维度", "层级维度", "运单量(万）", "pt"]
    grid: list[list[dict]] = [[{"value": h} for h in header]]
    # title row above? keep simple — row1 header

    def cell(v):
        return {"value": v}

    for week_start, pt_day, rows in weeks:
        label = _month_week_label(week_start)
        pt_s = pt_day.strftime("%Y%m%d")
        ws = f"{week_start.year}/{week_start.month}/{week_start.day}"
        # stable order by index2
        rows_sorted = sorted(rows, key=lambda r: str(r.get("index2", "")))
        for r in rows_sorted:
            num = r.get("num")
            try:
                num_v = round(float(num), 6)
            except (TypeError, ValueError):
                num_v = num
            grid.append(
                [
                    cell(ws),
                    cell(label),
                    cell(str(r.get("data_index", "")).strip()),
                    cell(str(r.get("index1", "")).strip()),
                    cell(str(r.get("index2", "")).strip()),
                    cell(num_v),
                    cell(pt_s),
                ]
            )
    return grid


def write_sheet(grid: list[list[dict]], title: str) -> None:
    n = len(grid)
    # clear + write + meta
    ops = [
        {
            "shortcut": "+cells-clear",
            "input": {"sheet_id": SHEET_ID, "range": "A1:G500", "scope": "all"},
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
    payload = ROOT / "logs" / "sheet_weekly_ops.json"
    payload.parent.mkdir(parents=True, exist_ok=True)
    payload.write_text(json.dumps(ops, ensure_ascii=False), encoding="utf-8")
    rel = payload.relative_to(ROOT).as_posix()
    _lark("+batch-update", "--yes", "--operations", f"@./{rel}")


def main() -> int:
    sys.path.insert(0, str(ROOT))
    import export_dataset as exp

    as_of = datetime.now().date() - timedelta(days=1)
    print(f"[{datetime.now():%F %T}] weekly refresh as_of={as_of} api={API_ID}")

    week_starts = _week_starts(as_of, n=2)
    print(f"target weeks={[ws.isoformat() for ws in week_starts]}")

    weeks: list[tuple[date, date, list[dict]]] = []
    missing: list[date] = []
    for ws in week_starts:
        got = _fetch_week(exp, ws, as_of)
        if got is None:
            missing.append(ws)
            continue
        pt_day, rows = got
        weeks.append((ws, pt_day, rows))

    if not weeks:
        raise SystemExit(f"最近两周均无数据: {week_starts}")

    # also dump csv
    out_dir = ROOT / "out"
    out_dir.mkdir(exist_ok=True)
    import csv

    csv_path = out_dir / f"quickbi_weekly_{datetime.now():%Y%m%d_%H%M%S}.csv"
    latest = out_dir / "quickbi_weekly_latest.csv"
    fieldnames = ["week_start", "week_label", "data_index", "index1", "index2", "num", "pt"]
    flat = []
    for ws, pt_day, rows in weeks:
        label = _month_week_label(ws)
        for r in rows:
            flat.append(
                {
                    "week_start": ws.isoformat(),
                    "week_label": label,
                    "data_index": r.get("data_index"),
                    "index1": r.get("index1"),
                    "index2": r.get("index2"),
                    "num": r.get("num"),
                    "pt": pt_day.strftime("%Y%m%d"),
                }
            )
    for path in (csv_path, latest):
        with path.open("w", newline="", encoding="utf-8-sig") as f:
            w = csv.DictWriter(f, fieldnames=fieldnames)
            w.writeheader()
            w.writerows(flat)
    print(f"csv rows={len(flat)} wrote {csv_path.name}")

    got_lbl = "、".join(ws.strftime("%m/%d") for ws, _, _ in weeks)
    miss_lbl = "、".join(ws.strftime("%m/%d") for ws in missing)
    title = f"周度详细数据｜最近两周目标 {week_starts[0].strftime('%m/%d')}&{week_starts[1].strftime('%m/%d')}｜已写入 {got_lbl}｜刷新日 {as_of.isoformat()}"
    if missing:
        title += f"｜暂无 {miss_lbl}"

    grid = build_table(weeks)
    os.chdir(ROOT)
    write_sheet(grid, title)
    print(f"sheet {SHEET_ID} updated weeks={[w[0].isoformat() for w in weeks]} missing={[m.isoformat() for m in missing]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
