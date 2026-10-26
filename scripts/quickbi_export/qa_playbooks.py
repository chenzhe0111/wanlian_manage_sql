#!/usr/bin/env python3
"""固化分析思路的答案实现（PLAYBOOK A–N）。由 qa_analyze 调用。"""

from __future__ import annotations

import calendar
import csv
from datetime import datetime
from pathlib import Path

import daily_target_digest as dig
import qa_analyze as base

ROOT = Path(__file__).resolve().parent
RISK = dig.RISK_BUFFER_PP


def _snap():
    grid = dig._read_sheet_grid()
    return grid, dig.build_snapshot(grid)


def _as_of_days(as_of: str) -> tuple[int, int, str, str]:
    d = datetime.strptime(as_of, "%Y-%m-%d").date()
    cur_month = d.strftime("%Y%m")
    if d.month == 1:
        prev_month, prev_days = f"{d.year - 1}12", 31
    else:
        prev_month = f"{d.year}{d.month - 1:02d}"
        prev_days = calendar.monthrange(d.year, d.month - 1)[1]
    return prev_days, d.day, prev_month, cur_month


def answer_online_why() -> str:
    grid, snap = _snap()
    tp = snap["time_progress"]
    online = snap["online"]
    month = dig._month_from_as_of(snap["as_of"])
    acol, tcol = dig.ACTUAL_COL[month], dig.TARGET_COL[month]
    types = []
    for name, row in (("TMS", 86), ("撮合", 87), ("网货", 88)):
        a = dig._cell(grid, row, acol) or 0.0
        t = dig._cell(grid, row, tcol) or 0.0
        rate = a / t if t else 0.0
        types.append((name, a, t, rate, rate * 100 - tp * 100))
    types.sort(key=lambda x: x[4])
    worst_t = types[0]
    body = base.answer_why_low()
    head = [
        f"**线上进度慢（截止 {snap['as_of']}）**",
        f"线上月运单 {_fmt(online.actual)}/{_fmt(online.target)} 万，达成 {_pct(online.rate,1)}，"
        f"落后时间进度 **{online.gap_pp(tp):+.0f}pp**（进度 {_pct(tp)}）。",
        f"线上类型窟窿首位：**{worst_t[0]}**（达成 {_pct(worst_t[3],1)}，{worst_t[4]:+.0f}pp）。",
        "",
        "—— 下接四举措归因 ——",
        "",
        body,
    ]
    return "\n".join(head)


def answer_overall() -> str:
    grid, snap = _snap()
    tp = snap["time_progress"]
    o, avg, peak = snap["overall"], snap["overall_avg"], snap["overall_peak"]
    gtv_a = dig._cell(grid, 6, dig.ACTUAL_COL[dig._month_from_as_of(snap["as_of"])])
    gtv_t = dig._cell(grid, 6, dig.TARGET_COL[dig._month_from_as_of(snap["as_of"])])
    lines = [
        f"**大盘进度（截止 {snap['as_of']}，时间进度 {_pct(tp)}）**",
        f"- 月运单 {_fmt(o.actual)}/{_fmt(o.target)}，达成 {_pct(o.rate)}（{o.gap_pp(tp):+.0f}pp）",
        f"- 日均 {_fmt(avg.actual)}/{_fmt(avg.target)}，达成 {_pct(avg.rate)}（{avg.gap_pp(tp):+.0f}pp）",
        f"- 峰值 {_fmt(peak.actual)}/{_fmt(peak.target)}，达成 {_pct(peak.rate)}（{peak.gap_pp(tp):+.0f}pp）",
    ]
    if gtv_a is not None and gtv_t:
        gr = gtv_a / gtv_t
        lines.append(f"- GTV {_fmt(gtv_a)}/{_fmt(gtv_t)} 亿，达成 {_pct(gr)}（{gr*100-tp*100:+.0f}pp）")
    # 结构还是纯量：四举措是否都差
    inits = snap["initiatives"]
    bad = sum(1 for m in inits if m.gap_pp(tp) < -15)
    kind = "多举措同时落后，偏**结构+放量**问题" if bad >= 3 else "局部举措拖累为主"
    lines.append(f"**总判**：大盘落后时间进度 {o.gap_pp(tp):+.0f}pp；{kind}。")
    lines.append(answer_catchup_from_snap(snap))
    return "\n".join(lines)


def answer_catchup_from_snap(snap: dict) -> str:
    as_of = snap["as_of"]
    d = datetime.strptime(as_of, "%Y-%m-%d").date()
    days_in_month = calendar.monthrange(d.year, d.month)[1]
    remain = max(days_in_month - d.day, 0)
    o, avg = snap["overall"], snap["overall_avg"]
    gap = max(o.target - o.actual, 0.0)
    need = gap / remain if remain else float("inf")
    cur = avg.actual
    if remain == 0:
        return f"**追赶**：本月已无剩余天数；累计 {_fmt(o.actual)}/{_fmt(o.target)}。"
    mult = need / cur if cur > 1e-9 else float("inf")
    return (
        f"**追赶**：月目标还差 {_fmt(gap)} 万，剩 {remain} 天 → 所需日均 **{_fmt(need)}** 万"
        f"（当前日均 {_fmt(cur)}，约 **{mult:.1f}x**）。"
    )


def answer_catchup() -> str:
    _, snap = _snap()
    return f"**追赶测算（截止 {snap['as_of']}）**\n" + answer_catchup_from_snap(snap)


def answer_online_share() -> str:
    grid, snap = _snap()
    month = dig._month_from_as_of(snap["as_of"])
    acol, tcol = dig.ACTUAL_COL[month], dig.TARGET_COL[month]
    # 行68 线上峰值占比
    share_a = dig._cell(grid, 68, acol)
    share_t = dig._cell(grid, 68, tcol)
    if share_a is not None and share_a > 1:
        share_a /= 100.0
    if share_t is not None and share_t > 1:
        share_t /= 100.0
    online, overall = snap["online"], snap["overall"]
    # 用运单占比近似
    vol_share = online.actual / overall.actual if overall.actual else 0.0
    lines = [
        f"**线上占比（截止 {snap['as_of']}）**",
        f"- 线上/整体运单占比约 **{_pct(vol_share,1)}**（线上 {_fmt(online.actual)} / 整体 {_fmt(overall.actual)}）",
    ]
    if share_a is not None and share_t is not None:
        lines.append(
            f"- 表内线上峰值占比实际 {_pct(share_a,1)} / 目标 {_pct(share_t,1)}"
            f"（{share_a*100-share_t*100:+.1f}pp）"
        )
    # 相对目标：线上达成 vs 整体达成
    lines.append(
        f"- 线上月运单达成 {_pct(online.rate,1)}，整体达成 {_pct(overall.rate,1)} → "
        + (
            "线上更慢，占比承压来自**线上自身放量不足**"
            if online.rate < overall.rate
            else "线上相对不慢于大盘"
        )
    )
    return "\n".join(lines)


def answer_biz_line() -> str:
    _, snap = _snap()
    tp = snap["time_progress"]
    wh, ch, tms = snap["wh_avg"], snap["ch_avg"], snap["tms_avg"]
    ranked = sorted(
        [("网货", wh), ("撮合", ch), ("TMS", tms)], key=lambda x: x[1].gap_pp(tp)
    )
    lines = [
        f"**业务线谁在扛（截止 {snap['as_of']}，进度 {_pct(tp)}）**",
    ]
    for name, m in ranked:
        lines.append(
            f"- {name}日均 {_fmt(m.actual)}/{_fmt(m.target)}，达成 {_pct(m.rate)}（{m.gap_pp(tp):+.0f}pp）"
        )
    lines.append(
        f"**总判**：拖累 **{ranked[0][0]}**，相对托底 **{ranked[-1][0]}**。"
    )
    return "\n".join(lines)


# 电销/投流：第七部分留存·新增漏斗行（整合表）
_FUNNEL_ROWS = {
    "电销": {
        "留存": {
            "运单量（万单）": 113,
            "发货货主数（家）": 114,
            "成交货主数（家）": 115,
            "货主成交率": 116,
            "单货主成交运单数": 117,
        },
        "新增": {
            "运单量（万单）": 120,
            "发货货主数（家）": 121,
            "成交货主数（家）": 122,
            "货主成交率": 123,
            "单货主成交运单数": 124,
        },
    },
    "投流": {
        "留存": {
            "运单量（万单）": 142,
            "发货货主数（家）": 143,
            "成交货主数（家）": 144,
            "货主成交率": 145,
            "单货主成交运单数": 146,
        },
        "新增": {
            "运单量（万单）": 149,
            "发货货主数（家）": 150,
            "成交货主数（家）": 151,
            "货主成交率": 152,
            "单货主成交运单数": 153,
        },
    },
}


def _fmt_metric_cell(label: str, v: float | None) -> str:
    if v is None:
        return "—"
    if "成交率" in label:
        # 表内可能是 0.92 或误写成 33.57
        if v > 1.5:
            return f"{v:.1f}%"
        return f"{v * 100:.1f}%"
    if "运单量" in label:
        return _fmt(v, 4) if abs(v) < 0.1 else _fmt(v, 2)
    if "单货主" in label:
        return _fmt(v, 2)
    # 货主数取整观感
    return f"{v:.0f}"


def _funnel_block(
    grid, name: str, pc: str, cc: str, prev_days: int, cur_days: int
) -> list[str]:
    """电销/投流：留存·新增漏斗，上月整月 vs 本月截至日。"""
    spec = _FUNNEL_ROWS.get(name)
    if not spec:
        return []
    lines = [
        "",
        "**留存 / 新增漏斗（月口径：上月整月 vs 本月截至）**",
        "说明：运单日均=月量÷天数；货主数日均=月去重人数÷天数（强度近似，非真·日活）；成交率/单货主运单为水平指标。",
    ]
    for bucket in ("留存", "新增"):
        lines.append(f"- **{bucket}**")
        fields = spec[bucket]
        # 运单：给日均；货主数：给累计+日均；率/人效：给水平值
        for label, row in fields.items():
            vp = dig._cell(grid, row, pc)
            vc = dig._cell(grid, row, cc)
            if "成交率" in label or "单货主" in label:
                lines.append(
                    f"  - {label}：{_fmt_metric_cell(label, vp)}→{_fmt_metric_cell(label, vc)}"
                )
            elif "运单量" in label:
                dp = (vp or 0) / prev_days
                dc = (vc or 0) / cur_days
                ch = (dc / dp - 1) * 100 if dp and dp > 1e-12 else 0.0
                lines.append(
                    f"  - {label}：累计 {_fmt_metric_cell(label, vp)}→{_fmt_metric_cell(label, vc)}；"
                    f"日均 {_fmt(dp, 3)}→{_fmt(dc, 3)}（{ch:+.0f}%）"
                )
            else:
                # 货主数
                dp = (vp or 0) / prev_days
                dc = (vc or 0) / cur_days
                ch = (dc / dp - 1) * 100 if dp and dp > 1e-9 else 0.0
                lines.append(
                    f"  - {label}：累计 {_fmt_metric_cell(label, vp)}→{_fmt_metric_cell(label, vc)}；"
                    f"日均 {_fmt(dp, 2)}→{_fmt(dc, 2)}（{ch:+.0f}%）"
                )
        # 桶内一句话卡点
        rate_row = fields["货主成交率"]
        ship_row = fields["发货货主数（家）"]
        deal_row = fields["成交货主数（家）"]
        per_row = fields["单货主成交运单数"]
        rate_c = dig._cell(grid, rate_row, cc)
        per_c = dig._cell(grid, per_row, cc)
        per_p = dig._cell(grid, per_row, pc)
        ship_c = dig._cell(grid, ship_row, cc) or 0
        deal_c = dig._cell(grid, deal_row, cc) or 0
        hints = []
        if rate_c is not None:
            rc = rate_c if rate_c <= 1.5 else rate_c / 100.0
            if rc < 0.5:
                hints.append("成交率偏低（转化弱）")
            elif rc >= 0.9:
                hints.append("成交率仍高（转化不差）")
        if per_p and per_c is not None and per_p > 0 and per_c / per_p < 0.6:
            hints.append("单货主运单明显下滑（人效掉）")
        if ship_c > 0 and deal_c / ship_c < 0.45:
            hints.append("发货→成交漏损大")
        if hints:
            lines.append(f"  → {bucket}卡点观察：" + "；".join(hints))
    return lines


def _rate_pair(a: float, b: float) -> str:
    if a <= 1e-9:
        return "—"
    return f"{b / a * 100:.1f}%"


def answer_init_funnel_weekly(name: str) -> str:
    """单举措新客转化漏斗 · 周度（漏斗 CSV，03d 当周首活）。"""
    path = ROOT / "out" / "quickbi_funnel_latest.csv"
    starts = base._funnel_week_starts(path)
    if len(starts) < 2:
        return (
            f"{name}周度漏斗不足两周。请先刷新漏斗（`refresh_sheet_funnel`），"
            f"或去掉「本周」改问「{name}转化漏斗」（月口径）。"
        )
    prev_ws, cur_ws = starts[-2], starts[-1]
    prev_lbl = base._week_label_from_start(prev_ws)
    cur_lbl = base._week_label_from_start(cur_ws)
    csv_init = base._INIT_CSV.get(name, name)

    def m(ws: str, cohort: str, metric: str) -> float:
        return base._funnel_metric(path, ws, csv_init, cohort, metric)

    # 新客主链
    metrics = ("注册企业数", "认证企业数", "发货货主数", "成交货主数", "成交运单量")
    new_p = {k: m(prev_ws, "新货主", k) for k in metrics}
    new_c = {k: m(cur_ws, "新货主", k) for k in metrics}
    # 投流注册/认证常挂在「整体」——仅展示量，不与新货主发货混算转化
    reg_from_overall = False
    if new_p["注册企业数"] < 1e-9 and new_c["注册企业数"] < 1e-9:
        for k in ("注册企业数", "认证企业数"):
            new_p[k] = m(prev_ws, "整体", k)
            new_c[k] = m(cur_ws, "整体", k)
        if new_p["注册企业数"] or new_c["注册企业数"] or new_p["认证企业数"] or new_c["认证企业数"]:
            reg_from_overall = True

    has_new = any(new_c[k] or new_p[k] for k in ("发货货主数", "成交货主数", "成交运单量"))
    has_new = has_new or any(new_c[k] or new_p[k] for k in ("注册企业数", "认证企业数"))
    if not has_new:
        return (
            f"**{name}新客转化漏斗 · 周度**：漏斗 CSV 近两周无「新货主」明细"
            f"（举措名={csv_init}）。可改问月口径「{name}转化漏斗」。"
        )

    lines = [
        f"**{name}新客转化漏斗 · 周度（{prev_lbl}→{cur_lbl}）**",
        "口径：漏斗周度 CSV · **03d 当周首活=新货主**；环比看人货量与转化率。",
    ]
    if reg_from_overall:
        lines.append("说明：注册/认证取自「整体」口径，与新货主发货/成交不可混算认证→发货率。")
    lines.extend(["", "- **新客漏斗**"])

    def _chg(p: float, c: float) -> str:
        if p <= 1e-9:
            return "新起" if c > 1e-9 else "—"
        return f"{(c / p - 1) * 100:+.0f}%"

    steps = [
        ("注册企业数", "注册", False),
        ("认证企业数", "认证", False),
        ("发货货主数", "发货货主", False),
        ("成交货主数", "成交货主", False),
        ("成交运单量", "成交运单", True),
    ]
    for key, label, is_waybill in steps:
        p, c = new_p[key], new_c[key]
        if p < 1e-9 and c < 1e-9:
            continue
        if is_waybill:
            lines.append(
                f"  - {label}：{_fmt(p / 10000, 3)}→{_fmt(c / 10000, 3)} 万（{_chg(p, c)}）"
            )
        else:
            lines.append(f"  - {label}：{p:.0f}→{c:.0f}（{_chg(p, c)}）")

    # 转化率（整体注册不可与新货主发货串联）
    rates = [("注册→认证", "注册企业数", "认证企业数")]
    if not reg_from_overall:
        rates.append(("认证→发货", "认证企业数", "发货货主数"))
    rates.append(("发货→成交", "发货货主数", "成交货主数"))
    rate_bits = []
    for lab, a_k, b_k in rates:
        if (new_p[a_k] > 1e-9 or new_c[a_k] > 1e-9) and (
            new_p[b_k] > 1e-9 or new_c[b_k] > 1e-9
        ):
            rate_bits.append(
                f"{lab} {_rate_pair(new_p[a_k], new_p[b_k])}→{_rate_pair(new_c[a_k], new_c[b_k])}"
            )
    deal_p, deal_c = new_p["成交货主数"], new_c["成交货主数"]
    ord_p, ord_c = new_p["成交运单量"], new_c["成交运单量"]
    if deal_p > 1e-9 or deal_c > 1e-9:
        eff_p = ord_p / deal_p if deal_p > 1e-9 else 0.0
        eff_c = ord_c / deal_c if deal_c > 1e-9 else 0.0
        rate_bits.append(f"单货主运单 {_fmt(eff_p, 1)}→{_fmt(eff_c, 1)}")
    if rate_bits:
        lines.append("  - 转化：" + "；".join(rate_bits))

    # 卡点
    hints = []
    ship_c, deal_c2 = new_c["发货货主数"], new_c["成交货主数"]
    if ship_c > 1e-9 and deal_c2 / ship_c < 0.25:
        hints.append("发货→成交漏损大")
    if new_c["注册企业数"] > 1e-9 and new_c["认证企业数"] / new_c["注册企业数"] < 0.7:
        hints.append("注册→认证偏弱")
    if new_c["认证企业数"] > 1e-9 and ship_c / new_c["认证企业数"] < 0.4:
        hints.append("认证→发货偏弱")
    if ord_c < ord_p * 0.8 and ord_p > 1e-9:
        hints.append("新客运单周环比下滑")
    if hints:
        lines.append(f"  → 卡点观察：{'；'.join(hints)}")
    else:
        lines.append("  → 卡点观察：本周未见单环明显塌方，偏量级仍小。")

    # 老客对照一行
    o_ship_p, o_ship_c = m(prev_ws, "老货主", "发货货主数"), m(cur_ws, "老货主", "发货货主数")
    o_ord_p, o_ord_c = m(prev_ws, "老货主", "成交运单量"), m(cur_ws, "老货主", "成交运单量")
    if o_ord_p or o_ord_c:
        lines.append(
            f"- **留存对照**：发货货主 {o_ship_p:.0f}→{o_ship_c:.0f}；"
            f"运单 {_fmt(o_ord_p / 10000, 3)}→{_fmt(o_ord_c / 10000, 3)} 万"
        )

    tot_c = ord_c + o_ord_c
    sh = ord_c / tot_c * 100 if tot_c > 1e-9 else 0.0
    lines.append(
        f"**总判**：{name}本周新客运单 {_fmt(ord_c / 10000, 3)} 万"
        f"（占本举措 {sh:.1f}%）；"
        + (
            "主体仍靠留存，新客转化需盯发货→成交。"
            if sh < 5
            else "新客有一定贡献，继续盯漏斗最弱一环。"
        )
    )
    lines.append("（要月口径深挖，去掉「本周」直接问「电销为什么掉队」等。）")
    return "\n".join(lines)


def answer_init_focus(name: str, text: str = "") -> str:
    t = base.normalize_query(text or "")
    # 本周/周度，或明确要漏斗环 → 周度新客漏斗；纯「为什么掉队」仍走月口径
    if base._wants_week(t) or any(
        k in t for k in ("漏斗", "转化漏斗", "新客转化", "转化率", "卡在哪", "哪环")
    ):
        return answer_init_funnel_weekly(name)

    grid, snap = _snap()
    tp = snap["time_progress"]
    by = {m.name: m for m in snap["initiatives"]}
    m = by[name]
    prev_days, cur_days, prev_m, cur_m = _as_of_days(snap["as_of"])
    pc, cc = dig.ACTUAL_COL[prev_m], dig.ACTUAL_COL[cur_m]
    r_new, r_old = base._NEWOLD_ROWS[name]
    n_p = dig._cell(grid, r_new, pc) or 0.0
    n_c = dig._cell(grid, r_new, cc) or 0.0
    o_p = dig._cell(grid, r_old, pc) or 0.0
    o_c = dig._cell(grid, r_old, cc) or 0.0
    lines = [
        f"**{name}深挖（截止 {snap['as_of']}）**",
        f"- 月运单 {_fmt(m.actual)}/{_fmt(m.target)}，达成 {_pct(m.rate,1)}，"
        f"vs 进度 {_pct(tp)} 为 **{m.gap_pp(tp):+.0f}pp**",
        f"- 新增日均（月口径） {_fmt(n_p/prev_days,3)}→{_fmt(n_c/cur_days,3)}"
        f"（上月整月÷{prev_days}天 → 本月截至日÷{cur_days}天，**不是**周度日均）；",
        f"  留存日均（月口径） {_fmt(o_p/prev_days,3)}→{_fmt(o_c/cur_days,3)}",
    ]
    sh_c = n_c / (n_c + o_c) * 100 if (n_c + o_c) else 0
    lines.append(f"- 本月新客占比约 {sh_c:.1f}%（越高越靠新增；=本月累计新增÷(新增+留存)）")

    # 电销/投流：完整留存·新增漏斗
    lines.extend(_funnel_block(grid, name, pc, cc, prev_days, cur_days))

    # 类型
    rows = base._load_weekly_rows(ROOT / "out" / "quickbi_weekly_latest.csv")
    csv_init = base._INIT_CSV[name]
    typed = base._type_drag_inside_init(rows, csv_init) if rows else None
    if typed:
        wc, wp, cur_map, prev_map = typed
        lines.append(
            "- 近周类型（**周度** CSV，与月口径漏斗不同）："
            + base._fmt_type_drag(cur_map, prev_map, wc, wp)
        )
    if m.actual < 0.05:
        lines.append(f"**总判**：{name} **几乎没量**，属「目标有、实际未起」。")
    elif m.gap_pp(tp) < -15:
        if name in _FUNNEL_ROWS:
            lines.append(
                f"**总判**：{name} 明显掉队；结合上方漏斗看是**量（发货/成交货主）**还是**人效（单货主运单）**或**成交率**在拖。"
            )
        else:
            lines.append(f"**总判**：{name} 明显掉队；优先看新增是否塌 + 类型是否偏弱。")
    else:
        lines.append(f"**总判**：{name} 相对接近进度，可作托底观察。")
    return "\n".join(lines)


def answer_wow() -> str:
    rows = base._load_weekly_rows(ROOT / "out" / "quickbi_weekly_latest.csv")
    if not rows:
        return "周度 CSV 不可用，请先跑 `refresh_sheet_weekly` / 确认 out/quickbi_weekly_latest.csv。"
    labels = base._weekly_labels_sorted(rows)
    if len(labels) < 2:
        return f"周度数据不足两周（仅有 {labels}）。"
    prev, cur = labels[-2], labels[-1]

    def _sum(label: str, pred) -> float:
        s = 0.0
        for r in rows:
            if str(r.get("week_label", "")).strip() != label:
                continue
            if not pred(r):
                continue
            try:
                s += float(r.get("num") or 0)
            except ValueError:
                pass
        return s

    overall_p = _sum(prev, lambda r: str(r.get("data_index")).strip() == "整体")
    overall_c = _sum(cur, lambda r: str(r.get("data_index")).strip() == "整体")
    wow = (overall_c - overall_p) / overall_p * 100 if overall_p else 0.0
    lines = [
        f"**周环比（{prev}→{cur}）**",
        f"- 整体 {_fmt(overall_p)}→{_fmt(overall_c)} 万（**{wow:+.1f}%**）",
        "- 四举措：",
    ]
    deltas = []
    for cn, csvn in base._INIT_CSV.items():
        p = _sum(
            prev,
            lambda r, n=csvn: str(r.get("data_index")).strip() == "线上举措"
            and str(r.get("index1")).strip() == n,
        )
        c = _sum(
            cur,
            lambda r, n=csvn: str(r.get("data_index")).strip() == "线上举措"
            and str(r.get("index1")).strip() == n,
        )
        deltas.append((cn, p, c, c - p))
        lines.append(f"  - {cn} {_fmt(p)}→{_fmt(c)}（{c-p:+.2f}）")
    deltas.sort(key=lambda x: x[3])
    lines.append(
        f"**总判**：拖累 **{deltas[0][0]}**（{deltas[0][3]:+.2f}），"
        f"贡献 **{deltas[-1][0]}**（{deltas[-1][3]:+.2f}）。"
    )
    return "\n".join(lines)


def answer_retain() -> str:
    grid, snap = _snap()
    prev_days, cur_days, prev_m, cur_m = _as_of_days(snap["as_of"])
    pc, cc = dig.ACTUAL_COL[prev_m], dig.ACTUAL_COL[cur_m]
    lines = [f"**留存是否失血（截止 {snap['as_of']}）**"]
    flags = []
    for name, (r_new, r_old) in base._NEWOLD_ROWS.items():
        o_p = dig._cell(grid, r_old, pc) or 0.0
        o_c = dig._cell(grid, r_old, cc) or 0.0
        n_c = dig._cell(grid, r_new, cc) or 0.0
        dp, dc = o_p / prev_days, o_c / cur_days
        ch = (dc / dp - 1) * 100 if dp > 1e-9 else 0.0
        sh = o_c / (o_c + n_c) * 100 if (o_c + n_c) else 0.0
        lines.append(
            f"- {name}留存日均 {_fmt(dp,3)}→{_fmt(dc,3)}（{ch:+.0f}%）；本月留存占比 {sh:.0f}%"
        )
        if ch < -15:
            flags.append(f"{name}留存日均↓")
        if sh > 90 and ch < 0:
            flags.append(f"{name}靠留存被动抬升占比")
    if not flags:
        lines.append("**总判**：未见全面失血；仍需盯新增是否塌导致占比虚高。")
    else:
        lines.append("**总判**：风险点 — " + "；".join(flags) + "。")
    return "\n".join(lines)


def answer_risk() -> str:
    _, snap = _snap()
    tp = snap["time_progress"]
    items = [
        ("整体月运单", snap["overall"]),
        ("整体日均", snap["overall_avg"]),
        ("线上月运单", snap["online"]),
    ] + [(m.name, m) for m in snap["initiatives"]]
    risks = []
    for name, m in items:
        gap = m.gap_pp(tp)
        if gap < -RISK:
            risks.append((name, m.rate, gap))
    risks.sort(key=lambda x: x[2])
    lines = [f"**风险红灯（截止 {snap['as_of']}，进度 {_pct(tp)}，阈值−{RISK:.0f}pp）**"]
    if not risks:
        lines.append("当前无落后超过阈值的项。")
    else:
        for name, rate, gap in risks[:6]:
            lines.append(f"- {name}：达成 {_pct(rate,1)}，{gap:+.0f}pp")
        lines.append(f"**最红**：{risks[0][0]}（{risks[0][2]:+.0f}pp）。")
    return "\n".join(lines)


def answer_structure() -> str:
    grid, snap = _snap()
    month = dig._month_from_as_of(snap["as_of"])
    tcol, acol = dig.TARGET_COL[month], dig.ACTUAL_COL[month]
    # 目标占比行 79-82；实际用量占比
    target_rows = {"裂变": 79, "电销": 80, "投流": 81, "调度": 82}
    inits = {m.name: m for m in snap["initiatives"]}
    total = sum(m.actual for m in snap["initiatives"]) or 1.0
    lines = [f"**四举措结构偏移（截止 {snap['as_of']}）**"]
    deltas = []
    for name, row in target_rows.items():
        tw = dig._cell(grid, row, tcol)
        if tw is not None and tw > 1:
            tw /= 100.0
        tw = tw or 0.0
        aw = inits[name].actual / total
        dpp = (aw - tw) * 100
        deltas.append((name, aw, tw, dpp))
        lines.append(
            f"- {name}：实际占比 {_pct(aw,1)} / 目标 {_pct(tw,1)}（{dpp:+.1f}pp）"
        )
    deltas.sort(key=lambda x: x[3])
    lines.append(
        f"**总判**：欠配最多 **{deltas[0][0]}**（{deltas[0][3]:+.1f}pp），"
        f"超配最多 **{deltas[-1][0]}**（{deltas[-1][3]:+.1f}pp）。"
    )
    return "\n".join(lines)


def answer_gtv() -> str:
    grid, snap = _snap()
    tp = snap["time_progress"]
    month = dig._month_from_as_of(snap["as_of"])
    acol, tcol = dig.ACTUAL_COL[month], dig.TARGET_COL[month]
    gtv_a = dig._cell(grid, 6, acol)
    gtv_t = dig._cell(grid, 6, tcol)
    o = snap["overall"]
    if not gtv_a or not gtv_t:
        return "GTV 实际/目标缺失，无法拆量与客单。"
    gr = gtv_a / gtv_t
    g_gap = gr * 100 - tp * 100
    o_gap = o.gap_pp(tp)
    if o_gap < g_gap - 3:
        cause = "运单量缺口大于 GTV 缺口 → 偏**量**的问题（客单可能在撑）"
    elif g_gap < o_gap - 3:
        cause = "GTV 落后更重 → 偏**客单/结构**问题"
    else:
        cause = "GTV 与运单落后幅度接近 → **量为主、客单未明显对冲**"
    return "\n".join(
        [
            f"**GTV（截止 {snap['as_of']}）**",
            f"- GTV {_fmt(gtv_a)}/{_fmt(gtv_t)} 亿，达成 {_pct(gr)}（{g_gap:+.0f}pp）",
            f"- 整体运单达成 {_pct(o.rate)}（{o_gap:+.0f}pp）",
            f"**总判**：{cause}。",
        ]
    )


def answer_one_liner() -> str:
    _, snap = _snap()
    tp = snap["time_progress"]
    ranked = sorted(snap["initiatives"], key=lambda x: x.gap_pp(tp))
    worst, best = ranked[0], ranked[-1]
    o = snap["overall"]
    return (
        f"截止 {snap['as_of']}：整体达成 {_pct(o.rate)}，落后时间进度 {o.gap_pp(tp):+.0f}pp；"
        f"主拖累 **{worst.name}**（{worst.gap_pp(tp):+.0f}pp），"
        f"相对托底 **{best.name}**（{best.gap_pp(tp):+.0f}pp）。"
    )


def answer_funnel_stub() -> str:
    path = ROOT / "out" / "quickbi_funnel_latest.csv"
    if not path.is_file():
        return "漏斗 CSV 不存在。请先跑 `refresh_sheet_funnel`，或改问「新客贡献有没有提升」。"
    try:
        rows = list(csv.DictReader(path.open(encoding="utf-8-sig")))
    except OSError:
        return "漏斗 CSV 无法读取（权限/路径）。"
    return (
        f"已读到漏斗文件 {path.name}（{len(rows)} 行）。"
        "精细环比卡点解析待按 03c/03d 字段对齐后增强；可先问「新客贡献」或「进度为什么慢」。"
    )


def answer_daily_proxy() -> str:
    _, snap = _snap()
    prev_days, cur_days, prev_m, cur_m = _as_of_days(snap["as_of"])
    # 用整体月运单日均近似
    grid = dig._read_sheet_grid()
    pc, cc = dig.ACTUAL_COL[prev_m], dig.ACTUAL_COL[cur_m]
    p = dig._cell(grid, 5, pc) or 0.0
    c = dig._cell(grid, 5, cc) or 0.0
    dp, dc = p / prev_days, c / cur_days
    ch = (dc / dp - 1) * 100 if dp else 0.0
    flag = "偏弱（低于上月日均 20%+）" if ch < -20 else ("大致相当" if ch > -10 else "略弱")
    return (
        f"**日度异常（近似，非真·日粒度）**\n"
        f"本月截至日均 {_fmt(dc)} vs 上月日均 {_fmt(dp)}（{ch:+.0f}%）→ {flag}。\n"
        f"真·「今天是否异常」需日粒度 Quick BI，当前用月内日均代理。"
    )


def _fmt(v, d=2):
    return base._fmt(v, d)


def _pct(r, d=0):
    return base._pct(r, d)
