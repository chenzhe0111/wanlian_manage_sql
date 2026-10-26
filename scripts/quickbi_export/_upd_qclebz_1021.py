#!/usr/bin/env python3
"""用《1021目标数据.xlsx》重刷 QCleBZ 第一表「七、线上举措转化」。

口径：
  月实际 ← 整合表第七部分（49）10 月
  周度   ← 03d 漏斗 M10W1(10/07) / M10W2(10/14)
  as_of  = 2026-10-20；时间进度 = 20/31
"""

from __future__ import annotations

import json
import os
import subprocess
from datetime import date
from pathlib import Path

import openpyxl

ROOT = Path(__file__).resolve().parent
XLSX = Path("/Users/chenzhe/Desktop/1021目标数据.xlsx")
SHEET_URL = "https://wanlianyida.feishu.cn/sheets/L91EsEtAohwjhStD4y6cYLCGnVe"
SHEET_ID = "QCleBZ"
AS_OF = "2026-10-20"
TP = 20 / 31
W1, W2 = date(2026, 10, 7), date(2026, 10, 14)


def _lark(*args: str) -> dict:
    cmd = ["lark-cli", "sheets", *args, "--url", SHEET_URL, "--as", "user", "--format", "json"]
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    raw = proc.stdout or proc.stderr
    i = raw.find("{")
    if proc.returncode != 0 or i < 0:
        raise SystemExit(raw[-2000:] or f"lark-cli failed {proc.returncode}")
    data = json.loads(raw[i:])
    if not data.get("ok", True):
        raise SystemExit(json.dumps(data.get("error") or data, ensure_ascii=False)[:2000])
    return data


def _f(v):
    try:
        return float(str(v).replace(",", "").replace("%", ""))
    except (TypeError, ValueError):
        return None


def wan(orders):
    if orders is None:
        return None
    return round(float(orders) / 10000.0, 6)


def wow(cur, prev):
    if cur is None or prev is None:
        return None
    if prev == 0:
        return None if cur == 0 else None
    return cur / prev - 1


def pct_str(x):
    if x is None:
        return ""
    return f"{x * 100:.1f}%"


def rate(a, b):
    if a is None or b in (None, 0):
        return None
    return a / b


def load_act(wb):
    ws = wb["整合表第七部分（举措×新老）"]
    out = {}
    for r in range(2, ws.max_row + 1):
        mon = ws.cell(r, 1).value
        if not mon or mon.month != 10:
            continue
        dim = str(ws.cell(r, 3).value or "").strip()
        out[dim] = {
            "fahuo": _f(ws.cell(r, 5).value),
            "cj": _f(ws.cell(r, 6).value),
            "wan": _f(ws.cell(r, 8).value),
            "rate": _f(ws.cell(r, 9).value),
            "avg": _f(ws.cell(r, 10).value),
            "zhuce": _f(ws.cell(r, 11).value),
            "renzheng": _f(ws.cell(r, 12).value),
        }
    return out


def load_funnel(wb):
    ws = wb["月度周度新老漏斗_周按周首次"]
    out = {}
    for r in range(2, ws.max_row + 1):
        if str(ws.cell(r, 2).value or "") != "周度":
            continue
        ps = ws.cell(r, 3).value
        ps = ps.date() if hasattr(ps, "date") else ps
        if ps not in (W1, W2):
            continue
        key = (
            ps,
            str(ws.cell(r, 4).value or "").strip(),
            str(ws.cell(r, 5).value or "").strip(),
            str(ws.cell(r, 6).value or "").strip(),
        )
        out[key] = _f(ws.cell(r, 7).value)
    return out


ops: list[dict] = []


def set_cell(addr: str, value):
    ops.append(
        {
            "shortcut": "+cells-set",
            "input": {
                "sheet_id": SHEET_ID,
                "range": addr,
                "cells": [[{"value": value}]],
            },
        }
    )


def set_row_vals(row: int, col_start: str, values: list):
    start_idx = ord(col_start) - ord("A")
    end_col = chr(ord("A") + start_idx + len(values) - 1)
    rng = f"{col_start}{row}:{end_col}{row}"
    ops.append(
        {
            "shortcut": "+cells-set",
            "input": {
                "sheet_id": SHEET_ID,
                "range": rng,
                "cells": [[{"value": v} for v in values]],
            },
        }
    )


def fill_metric_row(row, tgt, act, w1, w2, *, as_rate=False):
    tv, av = _f(tgt), _f(act)
    if as_rate:
        if tv and tv > 1.5:
            tv = tv / 100
        if av and av > 1.5:
            av = av / 100
        comp = (av / tv) if tv else None
        w1n, w2n = _f(w1), _f(w2)
        if w1n is not None and w1n > 1.5:
            w1n /= 100
        if w2n is not None and w2n > 1.5:
            w2n /= 100
        wow_out = f"{(w2n - w1n) * 100:+.1f}pp" if w1n is not None and w2n is not None else ""
    else:
        comp = (av / tv) if tv not in (None, 0) and av is not None else None
        wv = wow(_f(w2), _f(w1))
        wow_out = f"{wv * 100:+.1f}%" if wv is not None else ""
    set_row_vals(
        row,
        "C",
        [
            "" if tgt is None else tgt,
            "" if act is None else act,
            pct_str(comp) if comp is not None else "",
            "" if w1 is None else w1,
            "" if w2 is None else w2,
            wow_out,
        ],
    )


def main() -> int:
    if not XLSX.exists():
        raise SystemExit(f"找不到 {XLSX}")
    wb = openpyxl.load_workbook(XLSX, data_only=True)
    ACT = load_act(wb)
    FUN = load_funnel(wb)

    def g(start, init, shipper, metric):
        return FUN.get((start, init, shipper, metric))

    def week_block(init: str, shipper: str):
        def one(start):
            o = g(start, init, shipper, "成交运单量")
            f = g(start, init, shipper, "发货货主数")
            c = g(start, init, shipper, "成交货主数")
            return wan(o), f, c, rate(c, f), (None if not c or not o else o / c)

        return one(W1), one(W2)

    def a(dim, key, default=None):
        row = ACT.get(dim) or {}
        v = row.get(key)
        return default if v is None else v

    set_cell(
        "A2",
        f"目标←整合表D列(202610)；实际←整合表N列(10月实际)；周度列=M10W1(10/07)+M10W2(10/14)；"
        f"环比=M10W2 vs M10W1；统计截止日={AS_OF}；时间进度={TP:.0%}｜源=本地Excel1021",
    )
    set_row_vals(
        3,
        "A",
        ["模块", "指标", "10月目标", "10月实际", "目标完成度", "M10W1", "M10W2", "环比(M10W2 vs M10W1)", "分析结论"],
    )

    # ===== 裂变 =====
    lb_old_w1, lb_old_w2 = week_block("货主招募", "老货主")
    lb_new_w1, lb_new_w2 = week_block("货主招募", "新货主")
    lb_new_orders = a("货主招募-新货主", "wan", 0) or 0
    lb_old_orders = a("货主招募-老货主", "wan", 0) or 0
    lb_act = round(lb_new_orders + lb_old_orders, 4)
    lb_sum_w1 = (lb_old_w1[0] or 0) + (lb_new_w1[0] or 0)
    lb_sum_w2 = (lb_old_w2[0] or 0) + (lb_new_w2[0] or 0)

    fill_metric_row(4, 8.07, lb_act, round(lb_sum_w1, 6), round(lb_sum_w2, 6))
    fill_metric_row(6, 17653.13, a("货主招募-新货主", "zhuce", 0) or 0, None, None)
    fill_metric_row(8, 7061.25, a("货主招募-新货主", "renzheng", 0) or 0, None, None)
    fill_metric_row(10, 564.90, a("货主招募-新货主", "fahuo", 0) or 0, lb_new_w1[1], lb_new_w2[1])
    fill_metric_row(11, 5.65, lb_new_orders, lb_new_w1[0] or 0, lb_new_w2[0] or 0)
    fill_metric_row(12, 100, a("货主招募-新货主", "avg"), lb_new_w1[4], lb_new_w2[4])
    fill_metric_row(14, 2.42, lb_old_orders, lb_old_w1[0], lb_old_w2[0])
    fill_metric_row(15, 161.40, a("货主招募-老货主", "cj"), lb_old_w1[2], lb_old_w2[2])
    fill_metric_row(16, 150, a("货主招募-老货主", "avg"), lb_old_w1[4], lb_old_w2[4])
    set_cell(
        "I4",
        f"1. 货主招募：本周 {lb_sum_w2 * 10000:.0f} 单（周环比 {pct_str(wow(lb_sum_w2, lb_sum_w1))}），量级仍接近归零。<br/>"
        f"2. 留存运单 {lb_old_orders} 万；Excel 无「货主招募-新货主」行，新增月实际按 0。完成 {pct_str(lb_act / 8.07)}（时间进度 {TP:.0%}）。",
    )

    # ===== 电销 =====
    dx_old_w1, dx_old_w2 = week_block("电销", "老货主")
    dx_new_w1, dx_new_w2 = week_block("电销", "新货主")
    dx_old = a("电销-老货主", "wan") or 0
    dx_new = a("电销-新货主", "wan") or 0
    dx_act = round(dx_old + dx_new, 4)
    dx_sum_w1 = (dx_old_w1[0] or 0) + (dx_new_w1[0] or 0)
    dx_sum_w2 = (dx_old_w2[0] or 0) + (dx_new_w2[0] or 0)

    fill_metric_row(17, 9.63, dx_act, round(dx_sum_w1, 6), round(dx_sum_w2, 6))
    fill_metric_row(19, 7.44, dx_old, dx_old_w1[0], dx_old_w2[0])
    fill_metric_row(20, 337.41, a("电销-老货主", "fahuo"), dx_old_w1[1], dx_old_w2[1])
    fill_metric_row(21, 330.67, a("电销-老货主", "cj"), dx_old_w1[2], dx_old_w2[2])
    fill_metric_row(22, "98%", a("电销-老货主", "rate"), dx_old_w1[3], dx_old_w2[3], as_rate=True)
    fill_metric_row(23, 225.00, a("电销-老货主", "avg"), dx_old_w1[4], dx_old_w2[4])
    fill_metric_row(25, 2.19, dx_new, dx_new_w1[0], dx_new_w2[0])
    fill_metric_row(26, 266.23, a("电销-新货主", "fahuo"), dx_new_w1[1], dx_new_w2[1])
    fill_metric_row(27, 121.67, a("电销-新货主", "cj"), dx_new_w1[2], dx_new_w2[2])
    fill_metric_row(28, "46%", a("电销-新货主", "rate"), dx_new_w1[3], dx_new_w2[3], as_rate=True)
    fill_metric_row(29, 180.00, a("电销-新货主", "avg"), dx_new_w1[4], dx_new_w2[4])
    fill_metric_row(
        32,
        1242.63,
        a("电销-新货主", "renzheng"),
        g(W1, "电销", "新货主", "认证企业数"),
        g(W2, "电销", "新货主", "认证企业数"),
    )
    set_cell(
        "I17",
        f"1. 电销：本周 {dx_sum_w2:.3f} 万单（周环比 {pct_str(wow(dx_sum_w2, dx_sum_w1))}）。"
        f"完成 {pct_str(dx_act / 9.63)}（时间进度 {TP:.0%}）。<br/>"
        f"2. 留存 {dx_old:.3f} 万托底；新增 {dx_new:.4f} 万（03d当周首活）。",
    )

    # ===== 投流 =====
    tl_old_w1, tl_old_w2 = week_block("投流", "老货主")
    tl_new_w1, tl_new_w2 = week_block("投流", "新货主")
    tl_old = a("投流-老货主", "wan") or 0
    tl_new = a("投流-新货主", "wan") or 0
    tl_act = round(tl_old + tl_new, 4)
    tl_sum_w1 = (tl_old_w1[0] or 0) + (tl_new_w1[0] or 0)
    tl_sum_w2 = (tl_old_w2[0] or 0) + (tl_new_w2[0] or 0)

    fill_metric_row(43, 24.42, tl_act, round(tl_sum_w1, 6), round(tl_sum_w2, 6))
    fill_metric_row(45, 18.76, tl_old, tl_old_w1[0], tl_old_w2[0])
    fill_metric_row(46, 1114.59, a("投流-老货主", "fahuo"), tl_old_w1[1], tl_old_w2[1])
    fill_metric_row(47, 1092.30, a("投流-老货主", "cj"), tl_old_w1[2], tl_old_w2[2])
    fill_metric_row(48, "98%", a("投流-老货主", "rate"), tl_old_w1[3], tl_old_w2[3], as_rate=True)
    fill_metric_row(49, 171.79, a("投流-老货主", "avg"), tl_old_w1[4], tl_old_w2[4])
    fill_metric_row(51, 5.66, tl_new, tl_new_w1[0], tl_new_w2[0])
    fill_metric_row(52, 813.75, a("投流-新货主", "fahuo"), tl_new_w1[1], tl_new_w2[1])
    fill_metric_row(53, 488.25, a("投流-新货主", "cj"), tl_new_w1[2], tl_new_w2[2])
    fill_metric_row(54, "60%", a("投流-新货主", "rate"), tl_new_w1[3], tl_new_w2[3], as_rate=True)
    fill_metric_row(55, 115.82, a("投流-新货主", "avg"), tl_new_w1[4], tl_new_w2[4])
    fill_metric_row(
        57,
        904.18,
        a("投流-整体", "renzheng"),
        g(W1, "投流", "整体", "认证企业数"),
        g(W2, "投流", "整体", "认证企业数"),
    )
    fill_metric_row(
        58,
        1808.36,
        a("投流-整体", "zhuce"),
        g(W1, "投流", "整体", "注册企业数"),
        g(W2, "投流", "整体", "注册企业数"),
    )
    fill_metric_row(
        59,
        150697,
        a("投流-注册账号", "zhuce"),
        g(W1, "投流", "整体", "注册账号"),
        g(W2, "投流", "整体", "注册账号"),
    )
    set_cell(
        "I43",
        f"1. 投流：本周 {tl_sum_w2:.3f} 万单（周环比 {pct_str(wow(tl_sum_w2, tl_sum_w1))}）。"
        f"完成 {pct_str(tl_act / 24.42)}（时间进度 {TP:.0%}）。<br/>"
        f"2. 留存 {tl_old:.3f} 万；新增 {tl_new:.4f} 万（03d当周首活）。",
    )

    # ===== 调度 =====
    dd_old_w1, dd_old_w2 = week_block("调度", "老货主")
    dd_new_w1, dd_new_w2 = week_block("调度", "新货主")
    dd_new = a("调度-新货主", "wan") or 0
    dd_old = a("调度-老货主", "wan") or 0
    dd_total = round(dd_new + dd_old, 4)
    dd_sum_w1 = (dd_old_w1[0] or 0) + (dd_new_w1[0] or 0)
    dd_sum_w2 = (dd_old_w2[0] or 0) + (dd_new_w2[0] or 0)

    fill_metric_row(66, 14.43, dd_total, round(dd_sum_w1, 6), round(dd_sum_w2, 6))
    fill_metric_row(68, 14.43, dd_total, round(dd_sum_w1, 6), round(dd_sum_w2, 6))
    fill_metric_row(69, 3.81, dd_new, dd_new_w1[0], dd_new_w2[0])
    fill_metric_row(70, 10.62, dd_old, dd_old_w1[0], dd_old_w2[0])
    fill_metric_row(75, 190, a("调度-新货主", "fahuo"), dd_new_w1[1], dd_new_w2[1])
    fill_metric_row(81, 152, a("调度-老货主", "fahuo"), dd_old_w1[1], dd_old_w2[1])
    set_cell(
        "I66",
        f"1. 调度：本周 {dd_sum_w2:.3f} 万单（周环比 {pct_str(wow(dd_sum_w2, dd_sum_w1))}），仍为量级第一。"
        f"完成 {pct_str(dd_total / 14.43)}（时间进度 {TP:.0%}）。<br/>"
        f"2. 留存 {dd_old:.3f} 万托底；新增 {dd_new:.4f} 万。",
    )

    os.chdir(ROOT)
    print(
        f"as_of={AS_OF} lb={lb_act} dx={dx_act} tl={tl_act} dd={dd_total} "
        f"weeks dx={dx_sum_w1:.4f}->{dx_sum_w2:.4f} tl={tl_sum_w1:.4f}->{tl_sum_w2:.4f} "
        f"dd={dd_sum_w1:.4f}->{dd_sum_w2:.4f}"
    )
    CHUNK = 80
    for i in range(0, len(ops), CHUNK):
        chunk = ops[i : i + CHUNK]
        p = ROOT / "logs" / f"qclebz_1021_chunk_{i // CHUNK}.json"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(chunk, ensure_ascii=False), encoding="utf-8")
        rel = p.relative_to(ROOT).as_posix()
        print(f"write chunk {i // CHUNK} n={len(chunk)}")
        _lark("+batch-update", "--yes", "--operations", f"@./{rel}")
    print("done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
