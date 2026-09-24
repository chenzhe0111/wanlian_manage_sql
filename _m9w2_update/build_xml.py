# -*- coding: utf-8 -*-
"""Build 9M2W doc XML fragments from sheet 6wePyq."""
from pathlib import Path

OUT = Path(__file__).resolve().parent
TP = 26.67
YELLOW = "rgb(255,249,230)"
BLUE = "rgb(240,244,255)"
LBLUE = "rgb(232,243,255)"


def rate_html(rate: str) -> str:
    if rate in ("/", "—", "-", None, ""):
        return f'<p align="center">{rate or "—"}</p>'
    s = str(rate).strip().replace("%", "")
    try:
        v = float(s)
    except ValueError:
        return f'<p align="center">{rate}</p>'
    # 红=好(达进度及以上)，绿=不好(落后)
    color = "rgb(216,57,49)" if v >= TP else "rgb(46,161,33)"
    disp = rate if str(rate).endswith("%") else f"{v:.2f}%"
    return f'<p align="center"><b><span text-color="{color}">{disp}</span></b></p>'


def td(text, align="center", bg=None, bold=False):
    attrs = ' vertical-align="middle"'
    if bg:
        attrs += f' background-color="{bg}"'
    inner = f"<b>{text}</b>" if bold else str(text)
    return f'<td{attrs}><p align="{align}">{inner}</p></td>'


def td_rate(rate, bg=None):
    attrs = ' vertical-align="middle"'
    if bg:
        attrs += f' background-color="{bg}"'
    return f"<td{attrs}>{rate_html(rate)}</td>"


def th(text, yellow=False):
    b = YELLOW if yellow else BLUE
    return (
        f'<th background-color="{b}" vertical-align="middle">'
        f'<p align="center"><b>{text}</b></p></th>'
    )


# ----- callout / headings / bullets -----
(OUT / "callout.xml").write_text(
    """<callout emoji="✍️" background-color="rgb(255,245,235)" border-color="rgb(254,212,164)"><p>本周（M9W2）平台贡献运单 65,037 单（周环比 +71%，绝对增加约 27,108 单），总单量占比 24.01%（周环比 +8.0pp）。调度是本周绝对增量主力（约 +24,837 单，周环比 +157%），投流 +18%、电销微增 +2%；货主招募再降约 27 单。结构上 TMS 周度占比升至 73%（+11.1pp），网货占比回落至 14%（-10.2pp）。</p>
<p>9月MTD 线上 7.36 万单，完成目标 15.62%（时间进度 26.67%），落后约 11.1pp，同比 -19.1%；线上占比 24.07%（较8月同期 +7.4pp）。</p></callout>""",
    encoding="utf-8",
)
(OUT / "h1.xml").write_text(
    "<h1>一、线上订单KPI目标进度（时间进度：26.67%）</h1>", encoding="utf-8"
)
(OUT / "h2_s2.xml").write_text(
    "<h2>2、各举措订单结构情况（时间进度26.67%）</h2>", encoding="utf-8"
)
(OUT / "h2_s3.xml").write_text(
    "<h2>3、线上订单进展（时间进度26.67%）</h2>", encoding="utf-8"
)

(OUT / "s1_ol.xml").write_text(
    """<ol>
<li seq="1" seq-marker="1. "><b>发货货主</b>：周度634（+13.0%）；月累计645，完成31.34%（超前时间进度约4.7pp），同比-2.0%。</li>
<li seq-marker="2. "><b>整体订单</b>：周度6.50万（+71.5%，绝对约+27,108单）；TMS周环比+102%、撮合+60%、网货-0.5%。月累计7.36万，完成15.62%（落后约11.1pp），同比-19.1%。</li>
<li seq-marker="3. "><b>线上成交占比</b>：周度24.01%（+8.0pp）；月累计24.07%，大幅超目标8.50%（较8月同期+7.4pp），主要由调度/TMS放量拉动。</li>
</ol>""",
    encoding="utf-8",
)

(OUT / "s2_ol.xml").write_text(
    """<ol>
<li seq="1" seq-marker="1. "><b>裂变营销</b>：周度79单（-26%，约-27单），占整体仅0.03%，体量仍极小；月累计0.01万，完成0.2%，同比-91.4%。</li>
<li seq-marker="2. "><b>资源转化</b>：周度10,414单（+2%，约+201单），占整体3.84%（-0.5pp）；月累计1.19万，完成15.3%（落后约11.4pp），同比-40.9%。</li>
<li seq-marker="3. "><b>端外（投流）</b>：周度13,666单（+18%，约+2,086单），占整体5.04%（+0.2pp）；月累计1.56万，完成7.2%（落后约19.5pp），同比-46.2%。TMS周环比+83%为主要回升点。</li>
<li seq-marker="4. "><b>资源合作</b>：周度40,637单（+157%，约+24,837单），占整体15.00%（+8.3pp），是本周放量与占比抬升第一贡献；月累计4.58万，完成37.6%（超前约10.9pp），同比+13.8%。以TMS为主（周度3.51万，+160%）。</li>
</ol>""",
    encoding="utf-8",
)

# ----- table 1 -----
rows1 = [
    ("线上合计发货货主数", "1,145", "2,058", "645", "31.34%", "-2.0%", "658", "586", "561", "634", "+13.01%", True),
    ("线上合计成交运单数", "232,483", "471,495", "73,641", "15.62%", "-19.1%", "91,062", "42,976", "37,929", "65,037", "+71.47%", True),
    ("开票-网货运单", "45,291", "89,584", "10,487", "11.71%", "-25.6%", "14,096", "9,053", "9,237", "9,188", "-0.53%", True),
    ("撮合不开票运单", "60,379", "150,878", "9,472", "6.28%", "-68.6%", "30,166", "7,414", "5,180", "8,300", "+60.23%", True),
    ("TMS运单", "126,813", "231,033", "53,682", "23.24%", "+14.7%", "46,800", "26,509", "23,512", "47,549", "+102.23%", True),
    ("开票-网货运单占比", "19.48%", "19%", "14%", "/", "-1.2pp", "15.48%", "21%", "24%", "14%", "-10.2pp", False),
    ("撮合不开票运单占比", "25.97%", "32%", "13%", "/", "-20.3pp", "33.13%", "17%", "14%", "13%", "-0.9pp", False),
    ("TMS运单占比", "54.55%", "49%", "73%", "/", "+21.5pp", "51.39%", "62%", "62%", "73%", "+11.1pp", False),
    ("线上成交运单数%", "15.65%", "8.50%", "24.07%", "283.20%", "+7.4pp", "16.68%", "17.21%", "15.98%", "24.01%", "+8.0pp", True),
]
parts = [
    "<table><colgroup>"
    + "".join(f'<col width="{w}"/>' for w in [160, 90, 80, 80, 80, 70, 90, 80, 80, 80, 90])
    + "</colgroup><thead><tr>",
    th("KPI（时间进度26.67%）"),
]
for h in ["8月实际值", "9月目标", "9月实际", "完成率", "同比", "8月同期", "M8W4", "M9W1"]:
    parts.append(th(h))
parts += [th("M9W2", yellow=True), th("周环比", yellow=True), "</tr></thead><tbody>"]
for label, aug, tgt, act, rate, yoy, aug_s, w4, w1, w2, wow, dc in rows1:
    parts.append("<tr>")
    parts.append(td(label, align="left", bold=True))
    parts.append(td(aug, bold=True))
    parts.append(td(tgt))
    parts.append(td(act))
    parts.append(td_rate(rate) if dc else td(rate))
    parts.append(td(yoy))
    parts.append(td(aug_s))
    parts.append(td(w4))
    parts.append(td(w1))
    parts.append(td(w2, bg=YELLOW))
    parts.append(td(wow, bg=YELLOW))
    parts.append("</tr>")
parts.append("</tbody></table>")
(OUT / "s1_table.xml").write_text("".join(parts), encoding="utf-8")

# ----- table 2 -----
rows2 = [
    ("裂变营销", "5.62", "0.01", "0.2%", "0.11", "-91.4%", "0.01", "0.01", "0.01", "-25.9%", True),
    ("— TMS运单", "2.76", "0.01", "0.2%", "0.00", "0.0%", "0.01", "0.01", "0.01", "-32.0%", False),
    ("— 撮合不开票运单", "1.80", "0.00", "0.2%", "0.11", "-97.4%", "0.00", "0.00", "0.00", "-7.3%", False),
    ("— 开票-网货运单", "1.07", "0.00", "0.0%", "0.00", "0.0%", "0.00", "0.00", "0.00", "-50.0%", False),
    ("资源转化", "7.81", "1.19", "15.3%", "2.02", "-40.9%", "1.20", "1.02", "1.04", "+2.0%", True),
    ("— TMS运单", "3.83", "0.86", "22.5%", "0.72", "—", "0.86", "0.73", "0.75", "+3.1%", False),
    ("— 撮合不开票运单", "2.50", "0.08", "3.3%", "1.02", "-91.8%", "0.10", "0.06", "0.07", "+26.2%", False),
    ("— 开票-网货运单", "1.48", "0.25", "16.8%", "0.28", "-10.5%", "0.24", "0.23", "0.22", "-7.6%", False),
    ("端外线上流量转化", "21.54", "1.56", "7.2%", "2.90", "-46.2%", "1.31", "1.16", "1.37", "+18.0%", True),
    ("— TMS运单", "10.55", "0.55", "5.2%", "1.04", "-46.9%", "0.32", "0.27", "0.49", "+83.4%", False),
    ("— 撮合不开票运单", "6.89", "0.47", "6.9%", "1.13", "-58.3%", "0.55", "0.41", "0.41", "+0.4%", False),
    ("— 开票-网货运单", "4.09", "0.54", "13.1%", "0.73", "-26.4%", "0.44", "0.48", "0.47", "-3.1%", False),
    ("资源合作", "12.18", "4.58", "37.6%", "4.02", "+13.8%", "1.73", "1.58", "4.06", "+157.2%", True),
    ("— TMS运单", "5.97", "3.95", "66.2%", "2.92", "+35.4%", "1.46", "1.35", "3.51", "+160.5%", False),
    ("— 撮合不开票运单", "3.90", "0.37", "9.6%", "0.74", "-49.6%", "0.08", "0.05", "0.33", "+591.1%", False),
    ("— 开票-网货运单", "2.31", "0.25", "11.0%", "0.37", "-30.7%", "0.19", "0.19", "0.23", "+21.9%", False),
]
parts = [
    "<table><colgroup>"
    + "".join(f'<col width="{w}"/>' for w in [160, 80, 80, 80, 80, 80, 80, 80, 80, 90])
    + "</colgroup><thead><tr>",
    th("举措/类型（万单）"),
]
for h in ["9月目标", "9月实际", "完成率", "8月同期", "同比", "M8W4", "M9W1"]:
    parts.append(th(h))
parts += [th("M9W2", yellow=True), th("周环比", yellow=True), "</tr></thead><tbody>"]
for label, tgt, act, rate, aug_s, yoy, w4, w1, w2, wow, is_main in rows2:
    bg = LBLUE if is_main else None
    parts.append("<tr>")
    parts.append(td(label, align="left", bold=is_main, bg=bg))
    parts.append(td(tgt, bg=bg))
    parts.append(td(act, bg=bg))
    parts.append(td_rate(rate, bg=bg))
    parts.append(td(aug_s, bg=bg))
    parts.append(td(yoy, bg=bg))
    parts.append(td(w4, bg=bg))
    parts.append(td(w1, bg=bg))
    parts.append(td(w2, bg=YELLOW))
    parts.append(td(wow, bg=YELLOW))
    parts.append("</tr>")
parts.append("</tbody></table>")
(OUT / "s2_table.xml").write_text("".join(parts), encoding="utf-8")

# ----- table 3 funnel -----
# conclusions (merged)
concl = {
    "liebian": (
        "1. 周度：79单（-26%，约-27单），占整体0.03%，体量仍极小；近两周维持百单以下。<br/>"
        "2. vs时间进度26.67%：完成0.2%（实际0.010万），同比-91.0%。订单几乎全部来自留存；新增本周为0。"
    ),
    "dx": (
        "1. 周度：10,414单（+2%，约+201单），占整体3.84%（-0.5pp）；绝对量企稳但占比被资源合作稀释。<br/>"
        "2. vs时间进度26.67%：完成15.3%（实际1.19万），同比-40.8%，落后约11.4pp。<br/>"
        "3. 留存运单周环比+83%（0.56→1.02万），单货主运单回升；新增运单周环比-96%（0.46→0.02万），"
        "新增成交货主12家（-76%），是月度进度拖累点。"
    ),
    "tl": (
        "1. 周度：13,666单（+18%，约+2,086单），占整体5.04%（+0.2pp）；结束连续四周下行。<br/>"
        "2. vs时间进度26.67%：完成7.2%（实际1.56万），同比-46.2%，落后约19.5pp。<br/>"
        "3. 留存运单周环比+33%；新增运单仍弱（0.016万，-89%）。注册账号周环比+40%，"
        "但认证→发货转化回落，新增成交货主仅15家。"
    ),
    "dd": (
        "1. 周度：40,637单（+157%，约+24,837单），占整体15.00%（+8.3pp），为本周量与占比抬升第一贡献；"
        "TMS托底（3.51万，+161%），撮合周度从0.05跳至0.33万（+591%）。<br/>"
        "2. vs时间进度26.67%：完成37.6%（实际4.58万），同比+13.8%，超前约10.9pp。"
        "漏斗内撮合月实际与KPI不完全一致，以KPI模块为准。"
    ),
}
prog = "待本周业务周报确认（本次仅刷数+分析结论）。"
plan = "待本周业务周报确认。"

# Funnel rows: (label, tgt, act, yoy, rate, w1, w2, wow, is_header_group)
# rate None -> —
# For merged cells: first row of each initiative carries rowspan + concl/prog/plan


def fmt_yoy(v):
    if v in (None, "", "—"):
        return "—"
    if isinstance(v, str) and (v.endswith("%") or "pp" in v or v in ("—", "-")):
        return v
    try:
        x = float(v)
        if abs(x) <= 3:  # likely ratio like -0.91
            return f"{x*100:.1f}%"
        return f"{x:.1f}%"
    except Exception:
        return str(v)


def fmt_wow(v):
    if v in (None, "", "—", "#N/A", "#DIV/0!", "#VALUE!"):
        return "—"
    s = str(v).strip()
    if s.endswith("%"):
        return s if s.startswith(("+", "-")) or s == "0%" else s
    try:
        x = float(s)
        if abs(x) <= 20:
            return f"{x*100:.0f}%" if abs(x) < 5 else f"{x:.0f}%"
        return f"{x:.0f}%"
    except Exception:
        return s


def fmt_num(v, kind="num"):
    if v in (None, "", "—", "#N/A", "#DIV/0!", "#VALUE!", "#N/A"):
        return "—"
    if isinstance(v, str) and any(x in v for x in ["#", "N/A"]):
        return "—"
    try:
        x = float(str(v).replace(",", "").replace("%", ""))
    except Exception:
        return str(v)
    if kind == "wan":
        return f"{x:.3f}".rstrip("0").rstrip(".") if x < 10 else f"{x:.2f}"
    if kind == "pct":
        if x <= 1.5 and not str(v).endswith("%"):
            return f"{x*100:.0f}%"
        return f"{x:.0f}%" if x >= 1 else f"{x*100:.0f}%"
    if kind == "int":
        return f"{int(round(x)):,}"
    if kind == "ship":
        return f"{x:.1f}" if x < 100 else f"{x:.0f}"
    return str(v)


# Build funnel data from sheet mapping (hand-curated for display)
# Columns: tgt, act_mtd, yoy, rate, m9w1, m9w2, wow

liebian_rows = [
    ("①裂变营销", "5.62", "0.010", "-91.0%", "0.2%", "0.011", "0.008", "-26%", "wan", True),
    ("留存", "3.10", "0.010", "-91.0%", "0.3%", "0.004", "0.008", "+83%", "wan", True),
    ("发货货主数", "90", "4", "+33%", "—", "4", "4", "0%", "int", False),
    ("成交货主数", "78", "4", "+33%", "—", "5", "4", "-20%", "int", False),
    ("成交运单数（万单）", "3.10", "0.010", "-91.0%", "—", "0.004", "0.008", "+83%", "wan", False),
    ("--货主成交率", "86%", "100%", "—", "—", "125%", "100%", "-20%", "pct", False),
    ("--单货主成交运单数", "402", "24.0", "-93%", "—", "8.6", "19.6", "+128%", "ship", False),
    ("新增", "2.50", "0", "—", "0.0%", "0.006", "0", "—", "wan", True),
    ("注册货主数", "357", "—", "—", "—", "2", "0", "—", "int", False),
    ("认证货主数", "178", "—", "—", "—", "2", "0", "—", "int", False),
    ("新增转介绍 发货货主数（家）", "161", "—", "—", "—", "1", "0", "—", "int", False),
    ("成交货主数", "161", "—", "—", "—", "2", "0", "—", "int", False),
    ("成交运单数（万单）", "2.50", "0", "—", "—", "0.006", "0", "—", "wan", False),
    ("--货主成交率", "100%", "—", "—", "—", "200%", "—", "—", "pct", False),
    ("--单货主成交运单数", "156", "—", "—", "—", "31.5", "—", "—", "ship", False),
]

dx_rows = [
    ("②资源转化（万单）", "7.81", "1.195", "-40.8%", "15.3%", "1.023", "1.043", "+2%", "wan", True),
    ("留存", "5.45", "1.174", "-39.3%", "21.5%", "0.559", "1.023", "+83%", "wan", True),
    ("发货货主数", "172", "168", "+24%", "—", "139", "156", "+12%", "int", False),
    ("成交货主数", "168", "170", "+17%", "—", "148", "165", "+11%", "int", False),
    ("成交运单数（万单）", "5.00", "1.174", "-39.3%", "—", "0.559", "1.023", "+83%", "wan", False),
    ("--货主成交率", "98%", "101%", "-6%", "—", "106%", "106%", "-1%", "pct", False),
    ("--单货主成交运单数", "324", "69.0", "—", "—", "38", "62", "+64%", "ship", False),
    ("新增", "2.36", "0.021", "-74.9%", "0.9%", "0.464", "0.021", "-96%", "wan", True),
    ("注册货主数（家）", "564", "108", "-23%", "—", "71", "92", "+30%", "int", False),
    ("认证货主数（家）", "282", "106", "-17%", "—", "70", "90", "+29%", "int", False),
    ("新增 发货货主数（家）", "254", "62", "+48%", "—", "88", "58", "-34%", "int", False),
    ("成交货主数", "130", "12", "-33%", "—", "49", "12", "-76%", "int", False),
    ("成交运单量（万单）", "2.36", "0.021", "-74.9%", "—", "0.464", "0.021", "-96%", "wan", False),
    ("--注册 转 认证 转化率", "50%", "98%", "+8%", "—", "99%", "98%", "-1%", "pct", False),
    ("--认证 转 发货 转化率", "90%", "58%", "+78%", "—", "126%", "64%", "-49%", "pct", False),
    ("--货主成交率", "51%", "19%", "-55%", "—", "56%", "21%", "-63%", "pct", False),
    ("--单货主成交运单数", "182", "17", "—", "—", "95", "17", "-82%", "ship", False),
]

tl_rows = [
    ("③ 端外线上流量转化（万单）", "21.54", "1.560", "-46.2%", "7.2%", "1.158", "1.367", "+18%", "wan", True),
    ("留存", "16.19", "1.545", "-43.5%", "9.5%", "1.019", "1.351", "+33%", "wan", True),
    ("发货货主数", "790", "289", "-13%", "—", "275", "278", "+1%", "int", False),
    ("成交货主数", "774", "297", "-14%", "—", "279", "293", "+5%", "int", False),
    ("成交运单数（万单）", "16.19", "1.545", "-43.5%", "—", "1.019", "1.351", "+33%", "wan", False),
    ("--货主成交率", "98%", "103%", "-1%", "—", "101%", "105%", "+4%", "pct", False),
    ("--单货主成交运单数", "209", "52.0", "—", "—", "37", "46", "+26%", "ship", False),
    ("新增", "5.35", "0.016", "-90.6%", "0.3%", "0.139", "0.016", "-89%", "wan", True),
    ("曝光量（次）", "44,883", "—", "—", "—", "8,369,488", "8,369,488", "0%", "int", False),
    ("点击量（次）", "898", "—", "—", "—", "180,204", "180,204", "0%", "int", False),
    ("注册货主数（账号）", "25,680", "3,766", "+25%", "—", "2,289", "3,194", "+40%", "int", False),
    ("注册货主数（家）", "718", "58", "+26%", "—", "31", "53", "+71%", "int", False),
    ("认证货主数（家）", "359", "60", "+40%", "—", "31", "55", "+77%", "int", False),
    ("新增 发货货主数（家）", "323", "51", "+55%", "—", "63", "49", "-22%", "int", False),
    ("成交货主数", "194", "15", "-12%", "—", "42", "15", "-64%", "int", False),
    ("成交运单数（万单）", "5.35", "0.016", "-90.6%", "—", "0.139", "0.016", "-89%", "wan", False),
    ("--点击率", "2%", "—", "—", "—", "2.2%", "2.2%", "0%", "pct", False),
    ("--点击 转 注册率", "80%", "—", "—", "—", "0.02%", "0.03%", "+71%", "pct", False),
    ("--注册 转 认证 转化率", "50%", "103%", "+11%", "—", "100%", "104%", "+4%", "pct", False),
    ("--认证 转 发货 转化率", "90%", "85%", "+11%", "—", "203%", "89%", "-56%", "pct", False),
    ("--货主成交率", "60%", "29%", "-43%", "—", "67%", "31%", "-54%", "pct", False),
    ("--单货主成交运单数", "276", "10", "—", "—", "33", "10", "-69%", "ship", False),
]

dd_rows = [
    ("④资源合作（万单）", "12.18", "4.576", "+13.8%", "37.6%", "1.580", "4.064", "+157%", "wan", True),
    ("1-撮合", "3.90", "0.37", "-49.6%", "9.6%", "0.047", "0.328", "+591%", "wan", True),
    ("注册三方资源合作人数", "1,299", "180", "+9%", "—", "166", "180", "+8%", "int", False),
    ("认证三方资源合作人数", "1,039", "180", "+9%", "—", "166", "180", "+8%", "int", False),
    ("三方资源合作人数", "520", "7", "—", "—", "—", "7", "—", "int", False),
    ("成交运单量（万单）", "3.90", "0.37", "-49.6%", "—", "0.047", "0.328", "+591%", "wan", False),
    ("--资源合作人效", "75", "532", "—", "—", "—", "469", "—", "ship", False),
    ("--认证转化率", "50%", "4%", "—", "—", "—", "4%", "—", "pct", False),
    ("--注册转认证率", "80%", "100%", "0%", "—", "100%", "100%", "0%", "pct", False),
    ("2-TMS", "5.97", "3.949", "+35.4%", "66.2%", "1.347", "3.510", "+161%", "wan", True),
    ("创建运单（计划单）货主数", "284", "111", "+4%", "—", "56", "110", "+96%", "int", False),
    ("成交货主数", "264", "113", "+28%", "—", "62", "111", "+79%", "int", False),
    ("成交运单量（万单）", "5.97", "3.949", "+35.4%", "—", "1.347", "3.510", "+161%", "wan", False),
    ("--成交/创建", "93%", "102%", "+24%", "—", "111%", "101%", "-9%", "pct", False),
    ("--单货主成交运单数", "226", "350", "—", "—", "217", "316", "+46%", "ship", False),
    ("3-网货", "2.31", "0.254", "-30.7%", "11.0%", "0.185", "0.226", "+22%", "wan", True),
    ("注册货主数（家）", "274", "11", "-31%", "—", "1", "10", "+900%", "int", False),
    ("认证货主数（家）", "137", "11", "-27%", "—", "1", "10", "+900%", "int", False),
    ("发货货主数（家）", "123", "185", "+2%", "—", "118", "182", "+54%", "int", False),
    ("成交货主数", "102", "57", "-12%", "—", "50", "57", "+14%", "int", False),
    ("成交运单数（万单）", "2.31", "0.254", "-30.7%", "—", "0.185", "0.226", "+22%", "wan", False),
    ("--注册 转 认证 转化率", "50%", "100%", "+7%", "—", "100%", "100%", "0%", "pct", False),
    ("--认证 转 发货 转化率", "90%", "—", "—", "—", "118%", "—", "—", "pct", False),
    ("--货主成交率", "83%", "31%", "-14%", "—", "42%", "31%", "-26%", "pct", False),
    ("--单货主成交运单数", "226", "44.5", "—", "—", "37", "40", "+7%", "ship", False),
]


def build_funnel_block(rows, concl_html, rowspan):
    out = []
    for i, (label, tgt, act, yoy, rate, w1, w2, wow, kind, is_group) in enumerate(rows):
        bg = LBLUE if is_group else None
        out.append("<tr>")
        out.append(td(label, align="left", bold=is_group, bg=bg))
        out.append(td(tgt, bg=bg))
        out.append(td(act, bg=bg))
        out.append(td(yoy, bg=bg))
        if rate == "—":
            out.append(td("—", bg=bg))
        else:
            out.append(td_rate(rate, bg=bg))
        out.append(td(w1, bg=bg))
        out.append(td(w2, bg=YELLOW))
        out.append(td(wow, bg=YELLOW))
        if i == 0:
            ystyle = f' background-color="{YELLOW}"'
            out.append(
                f'<td rowspan="{rowspan}" vertical-align="middle"{ystyle}>'
                f"<p>{concl_html}</p></td>"
            )
            out.append(
                f'<td rowspan="{rowspan}" vertical-align="middle"{ystyle}>'
                f"<p>{prog}</p></td>"
            )
            out.append(
                f'<td rowspan="{rowspan}" vertical-align="middle"{ystyle}>'
                f"<p>{plan}</p></td>"
            )
        out.append("</tr>")
    return out


parts = [
    "<table><colgroup>"
    + "".join(
        f'<col width="{w}"/>'
        for w in [170, 70, 70, 70, 70, 70, 70, 70, 220, 160, 140]
    )
    + "</colgroup><thead><tr>",
    th("指标"),
]
for h in ["9月目标值", "9月实际", "同比", "目标完成度", "M9W1"]:
    parts.append(th(h))
parts += [
    th("M9W2", yellow=True),
    th("周环比", yellow=True),
    th("分析结论", yellow=True),
    th("本周进展", yellow=True),
    th("下周计划", yellow=True),
    "</tr></thead><tbody>",
]
parts += build_funnel_block(liebian_rows, concl["liebian"], len(liebian_rows))
parts += build_funnel_block(dx_rows, concl["dx"], len(dx_rows))
parts += build_funnel_block(tl_rows, concl["tl"], len(tl_rows))
parts += build_funnel_block(dd_rows, concl["dd"], len(dd_rows))
parts.append("</tbody></table>")
(OUT / "s3_table.xml").write_text("".join(parts), encoding="utf-8")

print("wrote", list(OUT.glob("*.xml")))
print("s3 rows", len(liebian_rows) + len(dx_rows) + len(tl_rows) + len(dd_rows))
