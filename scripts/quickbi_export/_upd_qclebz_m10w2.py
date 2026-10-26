#!/usr/bin/env python3
"""把 QCleBZ 线上表刷成 M9W2 同款列结构：月目标/月实际/完成度 + 上周 + 本周 + 周环比。

本周=M10W2(10/14)，上周=M10W1(10/07)；月实际对齐整合表 as_of=2026-10-19。
漏斗明细用 out/quickbi_funnel_latest.csv；KPI/矩阵运单用 out/quickbi_weekly_latest.csv。
"""

from __future__ import annotations

import csv
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SHEET_URL = "https://wanlianyida.feishu.cn/sheets/L91EsEtAohwjhStD4y6cYLCGnVe"
SHEET_ID = "QCleBZ"
AS_OF = "2026-10-19"
TP = 19 / 31  # 时间进度


def _lark(*args: str) -> dict:
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


def _f(v):
    try:
        return float(str(v).replace(",", "").replace("%", ""))
    except (TypeError, ValueError):
        return None


def load_funnel() -> dict[tuple[str, str, str, str], float]:
    out = {}
    for r in csv.DictReader(open(ROOT / "out" / "quickbi_funnel_latest.csv", encoding="utf-8-sig")):
        out[(r["周期起始日"], r["举措"], r["新老货主"], r["指标类型"])] = _f(r["指标值"])
    return out


def load_weekly() -> dict[tuple[str, str, str], float]:
    out = {}
    for r in csv.DictReader(open(ROOT / "out" / "quickbi_weekly_latest.csv", encoding="utf-8-sig")):
        out[(r["week_label"], r["data_index"], r["index1"])] = _f(r["num"])
    return out


def wan(orders: float | None) -> float | None:
    if orders is None:
        return None
    return round(orders / 10000.0, 6)


def wow(cur, prev):
    if cur is None or prev is None:
        return None
    if prev == 0:
        return None if cur == 0 else "—"
    return round(cur / prev - 1, 4)


def wow_pp(cur, prev):
    if cur is None or prev is None:
        return None
    return round((cur - prev) * 100, 1)  # percentage points if inputs are rates 0-1


def pct_str(x):
    if x is None:
        return ""
    if isinstance(x, str):
        return x
    return f"{x * 100:.1f}%"


def rate(a, b):
    if a is None or b is None or b == 0:
        return None
    return a / b


FUN = load_funnel()
W = load_weekly()
W1, W2 = "2026-10-07", "2026-10-14"


def g(start, init, shipper, metric):
    return FUN.get((start, init, shipper, metric))


def week_block(init: str, shipper: str):
    """return (orders_wan, fahuo, chengjiao, deal_rate, avg) for W1/W2"""

    def one(start):
        o = g(start, init, shipper, "成交运单量")
        f = g(start, init, shipper, "发货货主数")
        c = g(start, init, shipper, "成交货主数")
        return wan(o), f, c, rate(c, f), (None if not c or not o else o / c)

    return one(W1), one(W2)


# 整合表 10月实际（万单/人数）— 与 refresh_sheet_newold / 整合表 N 列对齐
ACT = {
    # 裂变
    "liebian_new_orders": 0.0,  # 整合表 N103 空/0
    "liebian_old_orders": 0.0009,
    "liebian_old_users": 2,
    "liebian_old_avg": 4.25,
    "liebian_new_auth": 0,
    "liebian_new_ship": 0,
    # 电销
    "dx_old_orders": 2.4552,
    "dx_old_fahuo": 274,
    "dx_old_cj": 253,
    "dx_old_rate": 0.9234,
    "dx_old_avg": 97.04,
    "dx_new_orders": 0.0414,
    "dx_new_fahuo": 140,
    "dx_new_cj": 47,
    "dx_new_rate": 0.3357,
    "dx_new_avg": 8.81,
    "dx_auth": 256,
    # 投流
    "tl_old_orders": 2.7566,
    "tl_old_fahuo": 450,
    "tl_old_cj": 422,
    "tl_old_rate": 0.9378,
    "tl_old_avg": 65.32,
    "tl_new_orders": 0.1592,
    "tl_new_fahuo": 219,
    "tl_new_cj": 91,
    "tl_new_rate": 0.4155,
    "tl_new_avg": 17.49,
    "tl_auth": 249,
    "tl_reg": 249,
    "tl_acct": 20672,
    # 调度
    "dd_total": 8.0225,
    "dd_new": 0.1423,
    "dd_old": 7.8802,
    "dd_new_fahuo": 20,
    "dd_old_fahuo": 203,
}

ops: list[dict] = []


def set_cell(addr: str, value, *, number: bool = False):
    cell = {"value": value}
    ops.append(
        {
            "shortcut": "+cells-set",
            "input": {"sheet_id": SHEET_ID, "range": addr, "cells": [[cell]]},
        }
    )


def set_row_vals(row: int, col_start: str, values: list):
    """Write contiguous values starting at col_start row."""
    # build A1 range
    start_idx = ord(col_start) - ord("A")
    end_col = chr(ord("A") + start_idx + len(values) - 1)
    rng = f"{col_start}{row}:{end_col}{row}"
    cells = [[{"value": v} for v in values]]
    ops.append(
        {
            "shortcut": "+cells-set",
            "input": {"sheet_id": SHEET_ID, "range": rng, "cells": cells},
        }
    )


# ---------- headers / note ----------
set_cell(
    "A2",
    f"目标←整合表D列(202610)；实际←整合表N列(10月实际)；周度列=M10W1(10/07)+M10W2(10/14)｜周环比=本周/上周-1；"
    f"格式同M9W2（上周+本周+环比）；统计截止日={AS_OF}；时间进度={TP:.0%}",
)
set_row_vals(3, "A", ["模块", "指标", "10月目标", "10月实际", "目标完成度", "M10W1", "M10W2", "周环比", "分析结论"])


def fill_metric_row(row, tgt, act, w1, w2, *, as_rate=False, as_pp=False):
    """C..H: tgt, act, rate, w1, w2, wow"""
    comp = None
    if tgt not in (None, "") and act not in (None, "") and _f(tgt):
        comp = _f(act) / _f(tgt) if not as_rate else None
    if as_rate:
        # act/w already rates; completion vs target rate
        if tgt not in (None, "") and act not in (None, "") and _f(tgt):
            # if tgt is like 0.98 or "98%"
            tv = _f(tgt)
            if tv and tv > 1.5:
                tv = tv / 100
            av = _f(act)
            if av and av > 1.5:
                av = av / 100
            comp = (av / tv) if tv else None
        wow_v = wow_pp(_f(w2) if _f(w2) and _f(w2) <= 1.5 else ((_f(w2) or 0) / 100),
                       _f(w1) if _f(w1) and _f(w1) <= 1.5 else ((_f(w1) or 0) / 100) if w1 not in (None, "") else None)
        if wow_v is not None:
            wow_out = f"{wow_v:+.1f}pp"
        else:
            wow_out = ""
    else:
        wow_v = wow(_f(w2), _f(w1))
        wow_out = pct_str(wow_v) if wow_v is not None and not isinstance(wow_v, str) else (wow_v or "")
        if isinstance(wow_v, float):
            wow_out = f"{wow_v*100:+.1f}%"
    comp_out = pct_str(comp) if comp is not None else ""
    # normalize blank
    vals = [
        "" if tgt is None else tgt,
        "" if act is None else act,
        comp_out,
        "" if w1 is None else w1,
        "" if w2 is None else w2,
        wow_out,
    ]
    set_row_vals(row, "C", vals)


# ===== 裂变 =====
lb_old_w1, lb_old_w2 = week_block("货主招募", "老货主")
lb_new_w1, lb_new_w2 = week_block("货主招募", "新货主")
lb_sum_w1 = (lb_old_w1[0] or 0) + (lb_new_w1[0] or 0)
lb_sum_w2 = (lb_old_w2[0] or 0) + (lb_new_w2[0] or 0)
lb_act = (ACT["liebian_new_orders"] or 0) + (ACT["liebian_old_orders"] or 0)

fill_metric_row(4, 8.07, round(lb_act, 4), round(lb_sum_w1, 6), round(lb_sum_w2, 6))
fill_metric_row(11, 5.65, ACT["liebian_new_orders"], lb_new_w1[0] or 0, lb_new_w2[0] or 0)
fill_metric_row(10, 564.90, ACT["liebian_new_ship"], lb_new_w1[1], lb_new_w2[1])
fill_metric_row(14, 2.42, ACT["liebian_old_orders"], lb_old_w1[0], lb_old_w2[0])
fill_metric_row(15, 161.40, ACT["liebian_old_users"], lb_old_w1[2], lb_old_w2[2])
fill_metric_row(16, 150, ACT["liebian_old_avg"], lb_old_w1[4], lb_old_w2[4])

concl_lb = (
    f"1. 货主招募：本周 {lb_sum_w2*10000:.0f} 单（周环比 {pct_str(wow(lb_sum_w2, lb_sum_w1))}），量级仍接近归零。<br/>"
    f"2. 留存运单 {lb_old_w2[0]} 万；新增几乎无贡献。完成 {pct_str(lb_act/8.07)}（时间进度 {TP:.0%}）。"
)
set_cell("I4", concl_lb)

# ===== 电销 =====
dx_old_w1, dx_old_w2 = week_block("电销", "老货主")
dx_new_w1, dx_new_w2 = week_block("电销", "新货主")
dx_sum_w1 = (dx_old_w1[0] or 0) + (dx_new_w1[0] or 0)
dx_sum_w2 = (dx_old_w2[0] or 0) + (dx_new_w2[0] or 0)
dx_act = ACT["dx_old_orders"] + ACT["dx_new_orders"]

fill_metric_row(17, 9.63, round(dx_act, 4), round(dx_sum_w1, 6), round(dx_sum_w2, 6))
fill_metric_row(19, 7.44, ACT["dx_old_orders"], dx_old_w1[0], dx_old_w2[0])
fill_metric_row(20, 337.41, ACT["dx_old_fahuo"], dx_old_w1[1], dx_old_w2[1])
fill_metric_row(21, 330.67, ACT["dx_old_cj"], dx_old_w1[2], dx_old_w2[2])
fill_metric_row(22, "98%", ACT["dx_old_rate"], dx_old_w1[3], dx_old_w2[3], as_rate=True)
fill_metric_row(23, 225.00, ACT["dx_old_avg"], dx_old_w1[4], dx_old_w2[4])
fill_metric_row(25, 2.19, ACT["dx_new_orders"], dx_new_w1[0], dx_new_w2[0])
fill_metric_row(26, 266.23, ACT["dx_new_fahuo"], dx_new_w1[1], dx_new_w2[1])
fill_metric_row(27, 121.67, ACT["dx_new_cj"], dx_new_w1[2], dx_new_w2[2])
fill_metric_row(28, "46%", ACT["dx_new_rate"], dx_new_w1[3], dx_new_w2[3], as_rate=True)
fill_metric_row(29, 180.00, ACT["dx_new_avg"], dx_new_w1[4], dx_new_w2[4])
fill_metric_row(32, 1242.63, ACT["dx_auth"], g(W1, "电销", "新货主", "认证企业数"), g(W2, "电销", "新货主", "认证企业数"))

concl_dx = (
    f"1. 电销：本周 {dx_sum_w2:.3f} 万单（周环比 {pct_str(wow(dx_sum_w2, dx_sum_w1))}）。"
    f"完成 {pct_str(dx_act/9.63)}（时间进度 {TP:.0%}）。<br/>"
    f"2. 留存 {dx_old_w2[0]:.3f} 万托底；新增 {dx_new_w2[0]:.4f} 万仍弱（03d当周首活）。"
)
set_cell("I17", concl_dx)

# ===== 投流 =====
tl_old_w1, tl_old_w2 = week_block("投流", "老货主")
tl_new_w1, tl_new_w2 = week_block("投流", "新货主")
tl_sum_w1 = (tl_old_w1[0] or 0) + (tl_new_w1[0] or 0)
tl_sum_w2 = (tl_old_w2[0] or 0) + (tl_new_w2[0] or 0)
tl_act = ACT["tl_old_orders"] + ACT["tl_new_orders"]

fill_metric_row(43, 24.42, round(tl_act, 4), round(tl_sum_w1, 6), round(tl_sum_w2, 6))
fill_metric_row(45, 18.76, ACT["tl_old_orders"], tl_old_w1[0], tl_old_w2[0])
fill_metric_row(46, 1114.59, ACT["tl_old_fahuo"], tl_old_w1[1], tl_old_w2[1])
fill_metric_row(47, 1092.30, ACT["tl_old_cj"], tl_old_w1[2], tl_old_w2[2])
fill_metric_row(48, "98%", ACT["tl_old_rate"], tl_old_w1[3], tl_old_w2[3], as_rate=True)
fill_metric_row(49, 171.79, ACT["tl_old_avg"], tl_old_w1[4], tl_old_w2[4])
fill_metric_row(51, 5.66, ACT["tl_new_orders"], tl_new_w1[0], tl_new_w2[0])
fill_metric_row(52, 813.75, ACT["tl_new_fahuo"], tl_new_w1[1], tl_new_w2[1])
fill_metric_row(53, 488.25, ACT["tl_new_cj"], tl_new_w1[2], tl_new_w2[2])
fill_metric_row(54, "60%", ACT["tl_new_rate"], tl_new_w1[3], tl_new_w2[3], as_rate=True)
fill_metric_row(55, 115.82, ACT["tl_new_avg"], tl_new_w1[4], tl_new_w2[4])
fill_metric_row(57, 904.18, ACT["tl_auth"], g(W1, "投流", "整体", "认证企业数"), g(W2, "投流", "整体", "认证企业数"))
fill_metric_row(58, 1808.36, ACT["tl_reg"], g(W1, "投流", "整体", "注册企业数"), g(W2, "投流", "整体", "注册企业数"))
fill_metric_row(59, 150697, ACT["tl_acct"], g(W1, "投流", "整体", "注册账号"), g(W2, "投流", "整体", "注册账号"))

concl_tl = (
    f"1. 投流：本周 {tl_sum_w2:.3f} 万单（周环比 {pct_str(wow(tl_sum_w2, tl_sum_w1))}）。"
    f"完成 {pct_str(tl_act/24.42)}（时间进度 {TP:.0%}）。<br/>"
    f"2. 留存 {tl_old_w2[0]:.3f} 万；新增 {tl_new_w2[0]:.4f} 万（03d当周首活）。"
)
set_cell("I43", concl_tl)

# ===== 调度 =====
dd_old_w1, dd_old_w2 = week_block("调度", "老货主")
dd_new_w1, dd_new_w2 = week_block("调度", "新货主")
dd_sum_w1 = (dd_old_w1[0] or 0) + (dd_new_w1[0] or 0)
dd_sum_w2 = (dd_old_w2[0] or 0) + (dd_new_w2[0] or 0)

fill_metric_row(66, 14.43, ACT["dd_total"], round(dd_sum_w1, 6), round(dd_sum_w2, 6))
fill_metric_row(68, 14.43, ACT["dd_total"], round(dd_sum_w1, 6), round(dd_sum_w2, 6))
fill_metric_row(69, 3.81, ACT["dd_new"], dd_new_w1[0], dd_new_w2[0])
fill_metric_row(70, 10.62, ACT["dd_old"], dd_old_w1[0], dd_old_w2[0])
fill_metric_row(75, 190, ACT["dd_new_fahuo"], dd_new_w1[1], dd_new_w2[1])
fill_metric_row(81, 152, ACT["dd_old_fahuo"], dd_old_w1[1], dd_old_w2[1])

concl_dd = (
    f"1. 调度：本周 {dd_sum_w2:.3f} 万单（周环比 {pct_str(wow(dd_sum_w2, dd_sum_w1))}），仍为量级第一。"
    f"完成 {pct_str(ACT['dd_total']/14.43)}（时间进度 {TP:.0%}）。<br/>"
    f"2. 留存 {dd_old_w2[0]:.3f} 万托底；新增 {dd_new_w2[0]:.4f} 万。"
)
set_cell("I66", concl_dd)

# ===== KPI概览：近三周 M9W5 无源则清空/保留结构 → M10W1/M10W2 + 环比 =====
# 列：C9月实际 D10月目标 E10月实际 F完成率 G同比 H9月同期 I M9W5 J M10W1 K M10W2 L 环比
# 改为：I=M10W1 J=M10W2 K=周环比（压缩为两周，贴近M9W2）；若保留三周则 I=M9W5空 J=M10W1 K=M10W2
# 按M9W2格式：两周+环比。这里把表头改成 M10W1 / M10W2 / 周环比（I/J/K）

set_cell("B88", f"KPI概览（时间进度:{TP:.0%}）")
set_cell("C88", f"10月(时间进度{TP:.0%}）")
set_row_vals(89, "C", ["9月实际值", "10月目标", "10月实际达成", "完成率", "同比", "9月同期", "M10W1", "M10W2", "周环比"])

# 线上运单（单）
online_w1 = W.get(("M10W1", "整体", "线上"))
online_w2 = W.get(("M10W2", "整体", "线上"))
tms_w1 = W.get(("M10W1", "线上", "TMS"))
tms_w2 = W.get(("M10W2", "线上", "TMS"))
ch_w1 = W.get(("M10W1", "线上", "撮合"))
ch_w2 = W.get(("M10W2", "线上", "撮合"))
wh_w1 = W.get(("M10W1", "线上", "网货"))
wh_w2 = W.get(("M10W2", "线上", "网货"))
all_w1 = W.get(("M10W1", "整体", "整体"))
all_w2 = W.get(("M10W2", "整体", "整体"))


def orders_int(wan_v):
    return None if wan_v is None else int(round(wan_v * 10000))


# E90 线上发货货主 — 缺周度货主数，只更新运单相关；发货货主保留月实际
def set_week_pair(row, a, b, *, as_int=True):
    va = orders_int(a) if as_int else a
    vb = orders_int(b) if as_int else b
    wv = wow(b, a)
    wow_s = f"{wv*100:+.2f}%" if isinstance(wv, float) else (wv or "")
    set_row_vals(row, "I", [va if va is not None else "", vb if vb is not None else "", wow_s])


set_week_pair(91, online_w1, online_w2)
set_week_pair(92, wh_w1, wh_w2)
set_week_pair(93, ch_w1, ch_w2)
set_week_pair(94, tms_w1, tms_w2)


def share(part, total):
    if part is None or total in (None, 0):
        return None
    return part / total


# 占比行
for row, p1, p2 in (
    (95, wh_w1, wh_w2),
    (96, ch_w1, ch_w2),
    (97, tms_w1, tms_w2),
):
    s1, s2 = share(p1, online_w1), share(p2, online_w2)
    set_row_vals(row, "I", [pct_str(s1), pct_str(s2), ""])
    if s1 is not None and s2 is not None:
        set_cell(f"K{row}", f"{(s2-s1)*100:+.1f}pp")

s1, s2 = share(online_w1, all_w1), share(online_w2, all_w2)
set_row_vals(98, "I", [pct_str(s1), pct_str(s2), ""])
if s1 is not None and s2 is not None:
    set_cell("K98", f"{(s2-s1)*100:+.1f}pp")

# 10月实际达成 from 整合表（单）
set_cell("E91", 135847)  # 13.5847万
set_cell("E92", 40708)
set_cell("E93", 9620)
set_cell("E94", 85519)
set_cell("E95", "29.97%")
set_cell("E96", "7.08%")
set_cell("E97", "62.95%")
set_cell("E98", "25.52%")
set_cell("F91", "24.02%")
set_cell("F98", f"{(0.2552/0.2806)*100:.2f}%")

# ===== KPI举措：近两周 M10W1/M10W2（M9W2格式）=====
set_cell("B101", f"KPI举措（时间进度:{TP:.0%}）")
set_cell("C101", f"10月（时间进度:{TP:.0%}）｜周度=M10W1&M10W2")
set_row_vals(102, "C", ["目标", "实际达成", "完成率", "9月同期", "同比", "M10W1", "M10W2", "周环比"])

init_map = [
    (103, "货主招募", 8.07, lb_act),
    (104, "货主招募-TMS", None, None),
    (105, "货主招募-撮合", None, None),
    (106, "货主招募-网货", None, None),
    (107, "电销", 9.63, dx_act),
    (108, "电销-TMS", None, None),
    (109, "电销-撮合", None, None),
    (110, "电销-网货", None, None),
    (111, "投流", 24.42, tl_act),
    (112, "投流-TMS", None, None),
    (113, "投流-撮合", None, None),
    (114, "投流-网货", None, None),
    (115, "调度", 14.43, ACT["dd_total"]),
    (116, "调度-TMS", None, None),
    (117, "调度-撮合", None, None),
    (118, "调度-网货", None, None),
]

for row, key, tgt, act in init_map:
    w1 = W.get(("M10W1", "线上举措", key))
    w2 = W.get(("M10W2", "线上举措", key))
    wv = wow(w2, w1)
    wow_s = f"{wv*100:+.1f}%" if isinstance(wv, float) else (wv or "")
    if tgt is not None and act is not None:
        set_row_vals(row, "C", [tgt, round(act, 4), pct_str(act / tgt) if tgt else ""])
    set_row_vals(row, "H", [w1 if w1 is not None else "", w2 if w2 is not None else "", wow_s])

# ===== 平台矩阵：周列改为 M10W1 / M10W2 / 周环比（保留月列）=====
# 当前: B122 平台运营-矩阵,,6月,7月,8月,9月,10月,月同比,M9W2,M9W3,M9W4,M9W5,M10W1,周环比,9月MTD
# 目标: ...10月,月同比,M10W1,M10W2,周环比
set_row_vals(122, "C", ["", "6月", "7月", "8月", "9月", "10月", "月同比", "M10W1", "M10W2", "周环比"])

# 更新 10月 + 周度（单）
# 区域地推 ≈ 整体线下；用 整体-线下
offline_w1 = W.get(("M10W1", "整体", "线下"))
offline_w2 = W.get(("M10W2", "整体", "线下"))
# 10月线上/举措 from weekly sum isn't month; use 整合表万单*10000
oct_online = 135847
oct_lb = int(round(lb_act * 10000))
oct_tl = int(round(tl_act * 10000))
oct_dx = int(round(dx_act * 10000))
oct_dd = int(round(ACT["dd_total"] * 10000))
oct_offline = int(round(3.1106 * 10000 * 10))  # placeholder — better from 整合表线下月量
# 整合表 N58 线下转化日均? 用整体月 - 线上
oct_all = int(round(53.2358 * 10000))  # 整体月运单
oct_offline = oct_all - oct_online

set_cell("H123", oct_offline)
set_cell("H124", oct_online)
set_cell("H125", oct_lb)
set_cell("H126", oct_tl)
set_cell("H127", oct_dx)
set_cell("H128", oct_dd)

# week cols I/J/K
pairs = [
    (123, offline_w1, offline_w2),
    (124, online_w1, online_w2),
    (125, W.get(("M10W1", "线上举措", "货主招募")), W.get(("M10W2", "线上举措", "货主招募"))),
    (126, W.get(("M10W1", "线上举措", "投流")), W.get(("M10W2", "线上举措", "投流"))),
    (127, W.get(("M10W1", "线上举措", "电销")), W.get(("M10W2", "线上举措", "电销"))),
    (128, W.get(("M10W1", "线上举措", "调度")), W.get(("M10W2", "线上举措", "调度"))),
]
for row, a, b in pairs:
    set_row_vals(row, "I", [orders_int(a), orders_int(b), ""])
    wv = wow(b, a)
    set_cell(f"K{row}", f"{wv*100:+.1f}%" if isinstance(wv, float) else "")

# 占比
for row, num_row in ((129, 123), (130, 124), (131, 125), (132, 126), (133, 127), (134, 128)):
    # month share vs all
    # week shares vs (offline+online) approx all
    pass

tot_w1 = (offline_w1 or 0) + (online_w1 or 0)
tot_w2 = (offline_w2 or 0) + (online_w2 or 0)
share_rows = [
    (129, offline_w1, offline_w2, oct_offline),
    (130, online_w1, online_w2, oct_online),
    (131, W.get(("M10W1", "线上举措", "货主招募")), W.get(("M10W2", "线上举措", "货主招募")), oct_lb),
    (132, W.get(("M10W1", "线上举措", "投流")), W.get(("M10W2", "线上举措", "投流")), oct_tl),
    (133, W.get(("M10W1", "线上举措", "电销")), W.get(("M10W2", "线上举措", "电销")), oct_dx),
    (134, W.get(("M10W1", "线上举措", "调度")), W.get(("M10W2", "线上举措", "调度")), oct_dd),
]
for row, a, b, oct_v in share_rows:
    set_cell(f"H{row}", pct_str(oct_v / oct_all if oct_all else None))
    s1 = share(a, tot_w1)
    s2 = share(b, tot_w2)
    set_row_vals(row, "I", [pct_str(s1), pct_str(s2), ""])
    if s1 is not None and s2 is not None:
        set_cell(f"K{row}", f"{(s2-s1)*100:+.1f}pp")

# clear old L/M/N week leftovers on matrix header row if any
set_cell("L122", "")
set_cell("M122", "")
set_cell("N122", "")
set_cell("O122", "")

import os

os.chdir(ROOT)
payload = ROOT / "logs" / "qclebz_m10w2_ops.json"
payload.parent.mkdir(parents=True, exist_ok=True)
payload.write_text(json.dumps(ops, ensure_ascii=False), encoding="utf-8")
print(f"ops={len(ops)} -> {payload}")

# batch in chunks of 80
CHUNK = 80
for i in range(0, len(ops), CHUNK):
    chunk = ops[i : i + CHUNK]
    p = ROOT / "logs" / f"qclebz_ops_chunk_{i//CHUNK}.json"
    p.write_text(json.dumps(chunk, ensure_ascii=False), encoding="utf-8")
    rel = p.relative_to(ROOT).as_posix()
    print(f"write chunk {i//CHUNK} n={len(chunk)}")
    _lark("+batch-update", "--yes", "--operations", f"@./{rel}")

print("done")
print("samples", {
    "dx_w1": dx_sum_w1,
    "dx_w2": dx_sum_w2,
    "tl_w1": tl_sum_w1,
    "tl_w2": tl_sum_w2,
    "dd_w1": dd_sum_w1,
    "dd_w2": dd_sum_w2,
    "online_w1": online_w1,
    "online_w2": online_w2,
})
