#!/usr/bin/env python3
"""用本地《1021目标数据.xlsx》回写飞书目标表（跳过 QuickBI）。

sheet 映射：
  整合表                     → 1074dd 月实际（46b）
  整合表第七部分（举措×新老） → 1074dd 第七部分（49）
  司机                       → 41UJIa
  周度                       → 66mgnV（近两周）
  月度周度新老漏斗_周按周首次 → QbfdXI（03d）

as_of = 整合表 10 月「统计天数」对应日（20 → 2026-10-20）。
"""

from __future__ import annotations

import importlib.util
from datetime import date, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
XLSX = Path("/Users/chenzhe/Desktop/1021目标数据.xlsx")

# 复用 1014 的加载/写入实现，只改路径与 sheet 名
_spec = importlib.util.spec_from_file_location(
    "refresh_from_excel_1014", ROOT / "refresh_from_excel_1014.py"
)
_m = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(_m)

_m.XLSX = XLSX


def main() -> int:
    if not XLSX.exists():
        raise SystemExit(f"找不到 {XLSX}")

    import openpyxl

    wb = openpyxl.load_workbook(XLSX, data_only=True)
    target_month = date(2026, 10, 1)
    as_of, overall = _m.load_actuals(wb["整合表"], target_month)
    as_of_s = as_of.isoformat()
    month_key = "202610"
    month_dash = "2026-10"
    print(f"[{datetime.now():%F %T}] excel={XLSX.name} as_of={as_of_s}")

    import os

    os.chdir(ROOT)

    actuals = _m.build_actuals_writes(overall, month_key)
    print(
        f"actuals cells={len(actuals)} N5={actuals.get('N5')} "
        f"N65={actuals.get('N65')} N73={actuals.get('N73')}"
    )
    _m.write_actuals(actuals, as_of_s)
    print("✓ 1074dd 月实际已写")

    newold_rows = _m.load_newold_rows(wb["整合表第七部分（举措×新老）"], target_month)
    newold = _m.build_newold_writes(newold_rows, month_dash)
    print(
        f"newold cells={len(newold)} N103={newold.get('N103')} N120={newold.get('N120')} "
        f"N157={newold.get('N157')} N158={newold.get('N158')}"
    )
    _m.write_newold(newold, as_of_s)
    print("✓ 1074dd 第七部分新老已写")

    drv_asof, drv_row = _m.load_driver_row(wb["司机"], target_month)
    driver = _m.build_driver_writes(drv_row, month_dash)
    print("driver writes", __import__("json").dumps(driver, ensure_ascii=False))
    _m.write_driver(driver, as_of=drv_asof)
    print("✓ 41UJIa 司机已写")

    weeks, miss_w, week_targets = _m.load_weekly_blocks(wb["周度"], as_of)
    if weeks:
        got_w = "、".join(w.strftime("%m/%d") for w, _, _ in weeks)
        wtitle = (
            f"周度详细数据｜最近两周目标 {week_targets[0].strftime('%m/%d')}&"
            f"{week_targets[1].strftime('%m/%d')}｜已写入 {got_w}｜刷新日 {as_of_s}｜本地Excel1021"
        )
        if miss_w:
            wtitle += "｜暂无 " + "、".join(m.strftime("%m/%d") for m in miss_w)
        _m.write_weekly(_m.build_weekly_table(weeks), wtitle)
        print(f"✓ 66mgnV 周度已写 weeks={[w[0].isoformat() for w in weeks]} miss={miss_w}")
    else:
        print(f"⚠ 周度跳过 miss={miss_w}")

    blocks, miss_f, week_targets = _m.load_funnel_blocks_03d(
        wb["月度周度新老漏斗_周按周首次"], as_of
    )
    if not blocks:
        raise SystemExit(f"漏斗无可用块: missing={miss_f}")
    got = "、".join(("月" if g == "月度" else "周") + p.strftime("%m/%d") for g, p, _ in blocks)
    title = (
        f"月度周度漏斗(03d)｜本月 {as_of.strftime('%Y-%m')}｜近两周 "
        f"{week_targets[0].strftime('%m/%d')}&{week_targets[1].strftime('%m/%d')}"
        f"｜已写入 {got}｜刷新日 {as_of_s}｜本地Excel1021"
    )
    if miss_f:
        title += "｜暂无 " + "、".join(miss_f)
    _m.write_funnel_03d(_m.build_funnel_grid_03d(blocks), title)
    print(
        f"✓ QbfdXI 漏斗(03d)已写 blocks="
        f"{[(g, p.isoformat(), len(r)) for g, p, r in blocks]} miss={miss_f}"
    )

    print("\n--- verify ---")
    v1 = _m._lark("+cells-get", "--sheet-id", "1074dd", "--range", "O1,N5,N65,N73,N103,N120,N157")
    print("1074dd:", __import__("json").dumps(v1.get("data") or v1, ensure_ascii=False)[:900])
    v2 = _m._lark("+cells-get", "--sheet-id", "41UJIa", "--range", "L1,K7,K8,K10")
    print("41UJIa:", __import__("json").dumps(v2.get("data") or v2, ensure_ascii=False)[:500])
    v3 = _m._lark("+cells-get", "--sheet-id", "QbfdXI", "--range", "A1:I3")
    print("QbfdXI:", __import__("json").dumps(v3.get("data") or v3, ensure_ascii=False)[:700])
    v4 = _m._lark("+cells-get", "--sheet-id", "66mgnV", "--range", "A1:E3")
    print("66mgnV:", __import__("json").dumps(v4.get("data") or v4, ensure_ascii=False)[:500])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
