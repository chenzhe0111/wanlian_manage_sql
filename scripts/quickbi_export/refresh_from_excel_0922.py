#!/usr/bin/env python3
"""用本地《周报数据0922.xlsx》回写飞书（跳过 QuickBI）。

写回范围（同昨日定时任务）：
  1) 1074dd 整合表：月实际（整体）+ 第七部分新老
  2) QbfdXI 月度周度漏斗：本月 + 近两周（Excel 有则写）
  3) 66mgnV 周度详细：最近两周

as_of 取 Excel 9 月统计天数对应日（22 → 2026-09-22）。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

import openpyxl

ROOT = Path(__file__).resolve().parent
SHEET_URL = "https://wanlianyida.feishu.cn/sheets/L91EsEtAohwjhStD4y6cYLCGnVe"
XLSX = Path("/Users/chenzhe/Desktop/周报数据0922.xlsx")

# --- 复用 refresh_sheet_* 里的排序/写表逻辑 ---
from refresh_sheet_actuals import MONTH_COL as ACTUALS_MONTH_COL  # noqa: E402
from refresh_sheet_actuals import build_writes as build_actuals_writes  # noqa: E402
from refresh_sheet_actuals import write_sheet as write_actuals  # noqa: E402
from refresh_sheet_funnel import (  # noqa: E402
    INIT_ORDER,
    METRIC_ORDER,
    SHIPPER_ORDER,
    build_grid as build_funnel_grid,
    write_sheet as write_funnel,
)
from refresh_sheet_newold import MONTH_COL as NEWOLD_MONTH_COL  # noqa: E402
from refresh_sheet_newold import write_sheet as write_newold  # noqa: E402
from refresh_sheet_weekly import (  # noqa: E402
    _month_week_label,
    build_table as build_weekly_table,
    write_sheet as write_weekly,
)


def _lark_verify(*args: str) -> dict:
    cmd = ["lark-cli", "sheets", *args, "--url", SHEET_URL, "--as", "user", "--format", "json"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    raw = proc.stdout or proc.stderr
    i = raw.find("{")
    if proc.returncode != 0 or i < 0:
        raise SystemExit(raw[-2000:] or f"lark-cli failed {proc.returncode}")
    data = json.loads(raw[i:])
    if not data.get("ok", True):
        raise SystemExit(json.dumps(data.get("error") or data, ensure_ascii=False)[:2000])
    return data


def _to_date(v) -> date | None:
    if v is None:
        return None
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    s = str(v)[:10]
    return date.fromisoformat(s)


def load_overall(ws) -> tuple[date, list[dict]]:
    """整体数据 → QuickBI 风格行（key1/key2 + 英文字段）。"""
    rows = []
    day_n = None
    for r in range(2, ws.max_row + 1):
        mon = _to_date(ws.cell(r, 1).value)
        if mon is None:
            continue
        if mon.year != 2026 or mon.month != 9:
            continue
        day_n = int(ws.cell(r, 4).value)
        rows.append(
            {
                "month": "202609",
                "key1": str(ws.cell(r, 2).value or "").strip(),
                "key2": str(ws.cell(r, 3).value or "").strip(),
                "avg_num": ws.cell(r, 6).value,
                "max_num": ws.cell(r, 7).value,
                "month_num": ws.cell(r, 5).value,
                "gtv_1": ws.cell(r, 9).value,
                "avg_cost": ws.cell(r, 11).value,
            }
        )
    if not rows or not day_n:
        raise SystemExit("整体数据缺少 2026-09 行")
    as_of = date(2026, 9, day_n)
    return as_of, rows


def load_funnel_month(ws, month_start: date) -> dict[str, dict]:
    """主键 → {指标类型: 值}，仅月度。"""
    out: dict[str, dict] = defaultdict(dict)
    for r in range(2, ws.max_row + 1):
        if str(ws.cell(r, 2).value or "").strip() != "月度":
            continue
        ps = _to_date(ws.cell(r, 3).value)
        if ps != month_start:
            continue
        init = str(ws.cell(r, 4).value or "").strip()
        ship = str(ws.cell(r, 5).value or "").strip()
        metric = str(ws.cell(r, 6).value or "").strip()
        val = ws.cell(r, 7).value
        key = f"{init}-{ship}"
        out[key][metric] = val
        # 也按完整主键存
        full = str(ws.cell(r, 1).value or "").strip()
        out[full][metric] = val
    return out


def build_newold_from_excel(overall_rows: list[dict], funnel_ix: dict[str, dict], month: str) -> dict[str, float | int]:
    """运单万单/客单走整体数据；人头与单货主均单走漏斗。"""
    ox = {(r["key1"], r["key2"]): r for r in overall_rows}

    def o(dim: str, field: str, nd=4):
        r = ox.get(("举措新老", dim))
        if not r or r.get(field) is None:
            return None
        return round(float(r[field]), nd)

    def fget(init_ship: str, metric: str):
        return funnel_ix.get(init_ship, {}).get(metric)

    def _int(v):
        if v is None or str(v).strip() == "":
            return None
        return int(round(float(v)))

    def _avg(ship_key: str):
        yundan = fget(ship_key, "成交运单量")
        owners = fget(ship_key, "成交货主数")
        if yundan is None or owners is None or float(owners) == 0:
            return None
        return round(float(yundan) / float(owners), 2)

    def _rate(ship_key: str):
        fahuo = fget(ship_key, "发货货主数")
        deal = fget(ship_key, "成交货主数")
        if fahuo is None or deal is None or float(fahuo) == 0:
            return None
        return round(float(deal) / float(fahuo), 4)

    zm_n, zm_o = "货主招募-新货主", "货主招募-老货主"
    dx_n, dx_o = "电销-新货主", "电销-老货主"
    tl_n, tl_o = "投流-新货主", "投流-老货主"
    dd_n, dd_o = "调度-新货主", "调度-老货主"

    raw: dict[str, float | int | None] = {
        "99": _int(fget(zm_n, "认证企业数")),
        "101": _int(fget(zm_n, "发货货主数")),
        "102": o(zm_n, "month_num"),
        "103": _avg(zm_n),
        "106": o(zm_o, "month_num"),
        "107": _int(fget(zm_o, "成交货主数")),
        "108": _avg(zm_o),
        "112": o(dx_o, "month_num"),
        "113": _int(fget(dx_o, "发货货主数")),
        "114": _int(fget(dx_o, "成交货主数")),
        "115": _rate(dx_o),
        "116": _avg(dx_o),
        "119": o(dx_n, "month_num"),
        "120": _int(fget(dx_n, "发货货主数")),
        "121": _int(fget(dx_n, "成交货主数")),
        "122": _rate(dx_n),
        "123": _avg(dx_n),
        "127": _int(fget(dx_n, "认证企业数")),
        "141": o(tl_o, "month_num"),
        "142": _int(fget(tl_o, "发货货主数")),
        "143": _int(fget(tl_o, "成交货主数")),
        "144": _rate(tl_o),
        "145": _avg(tl_o),
        "148": o(tl_n, "month_num"),
        "149": _int(fget(tl_n, "发货货主数")),
        "150": _int(fget(tl_n, "成交货主数")),
        "151": _rate(tl_n),
        "152": _avg(tl_n),
        "155": _int(fget("投流-整体", "认证企业数")),
        "156": _int(fget("投流-整体", "注册企业数")),
        "157": _int(fget("投流-整体", "注册账号")),
        "168": o(dd_n, "month_num"),
        "169": o(dd_o, "month_num"),
        "167": round((o(dd_n, "month_num") or 0) + (o(dd_o, "month_num") or 0), 4),
        "175": _int(fget(dd_n, "发货货主数")),
        "181": _int(fget(dd_o, "发货货主数")),
    }
    col = NEWOLD_MONTH_COL.get(month)
    if not col:
        raise SystemExit(f"没有 {month} 的新老列映射")
    return {f"{col}{r}": v for r, v in raw.items() if v is not None}


def load_funnel_blocks(ws, as_of: date) -> tuple[list[tuple[str, date, list[dict]]], list[str]]:
    month_start = as_of.replace(day=1)
    # 近两周目标
    last_wed = as_of - timedelta(days=(as_of.weekday() - 2) % 7)
    week_targets = [last_wed, last_wed - timedelta(days=7)]

    by_period: dict[tuple[str, date], list[dict]] = defaultdict(list)
    for r in range(2, ws.max_row + 1):
        grain = str(ws.cell(r, 2).value or "").strip()
        ps = _to_date(ws.cell(r, 3).value)
        if not grain or ps is None:
            continue
        by_period[(grain, ps)].append(
            {
                "key": str(ws.cell(r, 1).value or "").strip(),
                "type": str(ws.cell(r, 4).value or "").strip(),
                "new_old": str(ws.cell(r, 5).value or "").strip(),
                "index_type": str(ws.cell(r, 6).value or "").strip(),
                "num": ws.cell(r, 7).value,
            }
        )

    blocks: list[tuple[str, date, list[dict]]] = []
    missing: list[str] = []
    if ("月度", month_start) in by_period:
        blocks.append(("月度", month_start, by_period[("月度", month_start)]))
    else:
        missing.append(f"月度{month_start.isoformat()}")

    for ws_d in week_targets:
        if ("周度", ws_d) in by_period:
            blocks.append(("周度", ws_d, by_period[("周度", ws_d)]))
        else:
            missing.append(f"周度{ws_d.isoformat()}")
            # 回退：若目标周缺失，尝试用 Excel 里最新的周补上（仅提示）
    return blocks, missing


def load_weekly_blocks(ws, as_of: date) -> tuple[list[tuple[date, date, list[dict]]], list[date]]:
    last_wed = as_of - timedelta(days=(as_of.weekday() - 2) % 7)
    week_targets = [last_wed, last_wed - timedelta(days=7)]

    by_week: dict[date, list[dict]] = defaultdict(list)
    for r in range(2, ws.max_row + 1):
        ws_d = _to_date(ws.cell(r, 1).value)
        if ws_d is None:
            continue
        by_week[ws_d].append(
            {
                "data_index": str(ws.cell(r, 2).value or "").strip(),
                "index1": str(ws.cell(r, 3).value or "").strip(),
                "index2": str(ws.cell(r, 4).value or "").strip(),
                "num": ws.cell(r, 5).value,
            }
        )

    weeks: list[tuple[date, date, list[dict]]] = []
    missing: list[date] = []
    for ws_d in week_targets:
        if ws_d in by_week:
            weeks.append((ws_d, ws_d - timedelta(days=1), by_week[ws_d]))
        else:
            missing.append(ws_d)
    return weeks, missing


def main() -> int:
    if not XLSX.exists():
        raise SystemExit(f"找不到 {XLSX}")

    wb = openpyxl.load_workbook(XLSX, data_only=True)
    as_of, overall = load_overall(wb["整体数据"])
    as_of_s = as_of.isoformat()
    month_key = "202609"
    month_dash = "2026-09"
    print(f"[{datetime.now():%F %T}] excel={XLSX.name} as_of={as_of_s}")

    os.chdir(ROOT)

    # 1) 整合表月实际
    actuals = build_actuals_writes(overall, month_key)
    print(f"actuals cells={len(actuals)} H5={actuals.get('H5')} H64={actuals.get('H64')}")
    write_actuals(actuals, as_of_s)
    print("✓ 1074dd 月实际已写")

    # 2) 整合表第七部分新老
    funnel_ix = load_funnel_month(wb["月度周度漏斗数据"], as_of.replace(day=1))
    newold = build_newold_from_excel(overall, funnel_ix, month_dash)
    print(
        f"newold cells={len(newold)} H102={newold.get('H102')} H119={newold.get('H119')} "
        f"H157={newold.get('H157')}"
    )
    write_newold(newold, as_of_s)
    print("✓ 1074dd 第七部分新老已写")

    # 3) 月度周度漏斗
    blocks, miss_f = load_funnel_blocks(wb["月度周度漏斗数据"], as_of)
    if not blocks:
        raise SystemExit(f"漏斗无可用块: missing={miss_f}")
    week_targets = [
        as_of - timedelta(days=(as_of.weekday() - 2) % 7),
        as_of - timedelta(days=(as_of.weekday() - 2) % 7) - timedelta(days=7),
    ]
    got = "、".join(("月" if g == "月度" else "周") + p.strftime("%m/%d") for g, p, _ in blocks)
    title = (
        f"月度周度漏斗｜本月 {as_of.strftime('%Y-%m')}｜近两周 "
        f"{week_targets[0].strftime('%m/%d')}&{week_targets[1].strftime('%m/%d')}"
        f"｜已写入 {got}｜刷新日 {as_of_s}｜本地Excel"
    )
    if miss_f:
        title += "｜暂无 " + "、".join(miss_f)
    grid = build_funnel_grid(blocks)
    write_funnel(grid, title)
    print(f"✓ QbfdXI 漏斗已写 blocks={[(g, p.isoformat(), len(r)) for g, p, r in blocks]} miss={miss_f}")

    # 4) 周度详细
    weeks, miss_w = load_weekly_blocks(wb["周度详细数据数据"], as_of)
    if weeks:
        got_w = "、".join(w.strftime("%m/%d") for w, _, _ in weeks)
        miss_lbl = "、".join(m.strftime("%m/%d") for m in miss_w)
        wtitle = (
            f"周度详细数据｜最近两周目标 {week_targets[0].strftime('%m/%d')}&"
            f"{week_targets[1].strftime('%m/%d')}｜已写入 {got_w}｜刷新日 {as_of_s}｜本地Excel"
        )
        if miss_w:
            wtitle += f"｜暂无 {miss_lbl}"
        wgrid = build_weekly_table(weeks)
        write_weekly(wgrid, wtitle)
        print(f"✓ 66mgnV 周度已写 weeks={[w[0].isoformat() for w in weeks]} miss={[m.isoformat() for m in miss_w]}")
    else:
        print(f"⚠ 周度详细跳过：最近两周均无数据 miss={miss_w}")

    # 回读核对
    print("\n--- verify ---")
    v = _lark_verify("+cells-get", "--sheet-id", "1074dd", "--range", "J1,H5,H64,H74,H102,H119,H157")
    cells = (((v.get("data") or {}).get("valueRanges") or [{}])[0].get("values")) or v.get("data") or v
    print("1074dd sample:", json.dumps(cells, ensure_ascii=False)[:800])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
