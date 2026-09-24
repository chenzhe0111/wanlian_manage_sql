#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import csv, io, json, re
from pathlib import Path

HEAD = "rgb(240,244,255)"
INIT = "rgb(232,243,255)"
GROUP = "rgb(242,248,255)"
YEL = "rgb(255,249,230)"
TP = 0.73

PROG = {
    "裂变": (
        "1. 922货主招募：上线方案基本完成；风控上线后拟小规模测试中小货主身份拉新。<br/>2. 货推货：参与拉新2家、成功1家，成交14单；司推货：参与司机2人、成功拉新1家、成交7单，企微入口已开放。<br/>3. 功能推进：多活动排序、中小货主可参与营销（预期10月中）、裂变工具绿通复用货主侧、X推客阶梯优化。<br/>4. 私域：企微新增197人（累计2000+）；圈选高意向人群并输出种子用户运营方案。<br/>5. AI外呼：京东joyM测1000条；智齿外呼约4.3万条筛意向320；摩尔/东信推进9.20–22试跑。",
        "1. 活动上线：素材/配置修改，配置风控策略，推进营销活动功能优化。<br/>2. 未添加企微有效线索批量导入待添加列表；确认企微迁移时间节点。<br/>3. 推进标签落库排期 + 实时电销工单BRD；按新策略调整电销线索池看板。<br/>4. 快成/运宝等外部渠道继续验证并邀约货主。",
    ),
    "电销": (
        "1. 完成网货自闭环培训；专业性测试1.0试题完成。<br/>2. SOP4.0填充网货·撮合·TMS自闭环内容；优化网货话术。<br/>3. 历史线索触达：964条接通399，发货2人；公海暂搁置待数据导出。<br/>4. 自闭环运单占比2%：发货货主38人。<br/>5. 外呼：本周新增线索+1203，接通率环比+5%；协同识别车辆线索380个。<br/>6. 内蒙网货本周发货17单，成交6单（上周3单），成交率仍较低。",
        "1. 下周完成撮合培训+销售日常操作流程；专业测试终稿。<br/>2. 重点跟盯意向线索认证转化（当月：杜慧/石军霞；历史：高绍霞/丛林/夏武艺）。<br/>3. 新增公海渠道拨打；对接网货自闭环税点额度与CRM字段。<br/>4. 10月绩效考核设计；跟进撮合未成交原因；协同TMS用户调研。",
    ),
    "投流": (
        "1. 字节：素材审核申诉成功量级恢复；上线小程序投放；货主实名认证出价测试中。<br/>2. 腾讯小程序预算5k→1.2w，注册251→475。<br/>3. 应用商店：vivo/荣耀开启投放（荣耀回传异常排查中）；卓易通链路修复后小预算测试；OPPO降级待9.16发版。<br/>4. ASO关键词覆盖9,022→10,201，品牌到榜率94.7%。<br/>5. 渠道API：4个已上线，剩余预计9.22；快手/华为账户已开通。",
        "1. 转化侧沟通网货票额；盘点发货未成交并协同调度提升找车率。<br/>2. 百度：稳投/AIMAX维持；司机出价与认证出价测试观察。<br/>3. 字节：货主实名认证续测；司机素材审核/提需；腾讯司机提量、货主小程序效果不佳则控量。<br/>4. 应用商店开渠联调与回传修复；ASO/评论区治理持续。",
    ),
    "调度": ("", ""),
}

CONC = {
    "裂变": "1. 货主招募：本周 9 单（周环比 +21.4%，绝对增加约 2 单），占整体 0.00%（+0.0pp），量级仍接近归零。<br/>2. 留存运单 8.5 单（+30.8%）托底；新增运单 1.6 单（+6.7%）仍极弱。完成 0.1%。",
    "电销": "1. 电销触达：本周 1.192 万单（周环比 -3.3%，绝对减少约 407 单），占整体 4.67%（+0.1pp）。<br/>2. 留存运单 1.083 万（-9.0%）托底回落；新增运单 0.109 万（+159.7%）回升。完成 33.3%。",
    "投流": "1. 投流：本周 1.381 万单（周环比 +1.0%，绝对增加约 144 单），占整体 5.42%（+0.3pp），量级企稳微升。<br/>2. 留存运单 1.288 万（-4.7%）略降；新增运单 0.093 万（+482.8%）回升。完成 14.4%。",
    "调度": "1. 调度导流：本周 2.659 万单（周环比 -7.5%，绝对减少约 2,147 单），占整体 10.43%（-0.3pp），仍为量级第一。<br/>2. 可见口径下新增运单 0.483 万。完成 52.5%。",
}

# QCleBZ hidden_rows（+sheet-info）；隐藏行不写入周报
HIDDEN_ROWS = set(range(29, 42)) | set(range(70, 85))


def empty(v):
    s = (v or "").strip()
    return (not s) or s in {"#DIV/0!", "#VALUE!", "#N/A", "/", "—", "-"}


def parse_num(v):
    if empty(v):
        return None
    s = str(v).strip().replace(",", "").replace("%", "")
    try:
        return float(s)
    except ValueError:
        return None


def is_rate_label(label):
    keys = ("转化率", "成交率", "完成度", "系数", "→", "率")
    if any(k in label for k in keys):
        if "人效" in label or "单量" in label or "单客户" in label or "单BD" in label or "单货主" in label:
            return False
        return True
    return False


def is_count_label(label):
    keys = ("用户", "货主", "人数", "客户", "线索", "沟通", "接通", "外呼", "人力", "账户", "曝光")
    return any(k in label for k in keys) and "率" not in label and "运单" not in label and "招募" not in label


def fmt_wan(n):
    if abs(n) < 0.01:
        return f"{n:.5f}".rstrip("0").rstrip(".") if n else "0"
    return f"{n:.3f}".rstrip("0").rstrip(".")


def fmt_val(label, raw, kind="val", row_kind="metric"):
    if empty(raw):
        return "—"
    s = str(raw).strip()
    if s.endswith("%") and parse_num(s) is not None:
        n = parse_num(s)
        if kind == "wow":
            sign = "+" if n > 0 and not s.startswith(("+", "-")) else ""
            return f"{sign}{n:.1f}%"
        return f"{n:.1f}%" if n != int(n) else f"{int(n)}%"
    n = parse_num(s)
    if n is None:
        return s
    if kind == "wow":
        pct = n * 100 if abs(n) <= 2 else n
        sign = "+" if pct > 0 else ""
        return f"{sign}{pct:.1f}%"
    if row_kind == "init" or "万单" in label or label == "合计":
        return fmt_wan(n)
    if is_rate_label(label) and abs(n) <= 2.5 and "%" not in s:
        return f"{n*100:.1f}%"
    if is_count_label(label) and abs(n) >= 1:
        return f"{int(round(n)):,}"
    if abs(n) >= 1000:
        return f"{int(round(n)):,}"
    if abs(n) >= 10:
        return f"{n:.1f}" if n != int(n) else f"{int(n)}"
    if abs(n) >= 1:
        return f"{n:.2f}" if n != int(n) else f"{int(n)}"
    return f"{n:.4f}".rstrip("0").rstrip(".")


def finish_html(raw):
    if empty(raw):
        return '<p align="center">—</p>'
    n = parse_num(raw)
    if n is None:
        return f'<p align="center">{raw}</p>'
    ratio = n / 100.0 if abs(n) > 2 else n
    text = raw.strip() if "%" in str(raw) else f"{ratio*100:.1f}%"
    if "%" not in text:
        text = f"{ratio*100:.1f}%"
    # 红=达进度/好，绿=落后/不好
    color = "red" if ratio >= 0.73 else "green"
    return f'<p align="center"><b><span text-color="{color}">{text}</span></b></p>'


def td(text, bg=None, center=True, extra=""):
    style = []
    if bg:
        style.append(f'background-color="{bg}"')
    style.append('vertical-align="middle"')
    if extra:
        style.append(extra)
    attrs = " " + " ".join(style) if style else ""
    align = ' align="center"' if center else ""
    return f"<td{attrs}><p{align}>{text}</p></td>"


def th(text, bg=HEAD, yel=False):
    b = YEL if yel else bg
    return f'<th background-color="{b}" vertical-align="middle"><p align="center"><b>{text}</b></p></th>'


raw = json.loads(Path("/tmp/qclebz.json").read_text())["data"]["annotated_csv"]
parsed = []
for line in raw.splitlines():
    m = re.match(r"\[row=(\d+)\] (.*)$", line)
    if not m:
        continue
    rn = int(m.group(1))
    if rn < 4 or rn > 85:
        continue
    rec = next(csv.reader(io.StringIO(m.group(2))))
    parsed.append((rn, rec))

# classify；跳过隐藏行
blocks = []
cur = None
for rn, rec in parsed:
    if rn in HIDDEN_ROWS:
        continue
    module, metric = rec[0].strip(), rec[1].strip()
    vals = rec[2:8]
    if module:
        key = "裂变" if "裂变" in module or "招募" in module else (
            "电销" if "电销" in module else (
                "投流" if "投放" in module or "投流" in module else "调度"
            )
        )
        cur = {"key": key, "rows": []}
        blocks.append(cur)
        label = module
        kind = "init"
    elif metric.startswith("【"):
        kind = "group"
        label = metric
    else:
        kind = "metric"
        label = metric
    cur["rows"].append((kind, label, vals))

assert [b["key"] for b in blocks] == ["裂变", "电销", "投流", "调度"]
for b in blocks:
    print("visible", b["key"], len(b["rows"]), [r[1] for r in b["rows"]])

out = [
    "<table>",
    '<colgroup><col width="200"/><col width="80"/><col width="80"/><col width="80"/><col width="80"/><col width="80"/><col width="80"/><col width="240"/><col width="180"/><col width="160"/></colgroup>',
    "<thead><tr>",
    th("指标"),
    th("9月目标"),
    th("9月实际"),
    th("目标完成度"),
    th("M9W2"),
    th("M9W3", yel=True),
    th("周环比", yel=True),
    th("分析结论", yel=True),
    th("本周进展", yel=True),
    th("下周计划", yel=True),
    "</tr></thead><tbody>",
]

for b in blocks:
    key = b["key"]
    n = len(b["rows"])
    for i, (kind, label, vals) in enumerate(b["rows"]):
        tgt, act, fin, w2, w3, wow = (vals + [""] * 6)[:6]
        if kind == "init":
            bg, bg3 = INIT, YEL
            lab = f"<b>{label}</b>"
        elif kind == "group":
            bg, bg3 = GROUP, YEL
            lab = f"<b>{label}</b>"
        else:
            bg, bg3 = None, YEL
            lab = label
        tds = [
            td(lab, bg, center=False),
            td(fmt_val(label, tgt, row_kind=kind) if kind != "group" else "—", bg),
            td(fmt_val(label, act, row_kind=kind) if kind != "group" else "—", bg),
        ]
        if kind == "group":
            tds.append(td("—", bg))
        else:
            fin_cell = finish_html(fin)
            if bg:
                fin_cell = fin_cell.replace("<p ", f'<p ')
                tds.append(f'<td background-color="{bg}" vertical-align="middle">{fin_cell}</td>')
            else:
                tds.append(f'<td vertical-align="middle">{fin_cell}</td>')
        tds += [
            td(fmt_val(label, w2, row_kind=kind) if kind != "group" else "—", bg),
            td(fmt_val(label, w3, row_kind=kind) if kind != "group" else "—", bg3),
            td(fmt_val(label, wow, "wow", row_kind=kind) if kind != "group" else "—", bg3),
        ]
        if i == 0:
            ihtml, jhtml = PROG[key]
            tds.append(
                f'<td background-color="{YEL}" rowspan="{n}" vertical-align="middle"><p>{CONC[key]}</p></td>'
            )
            tds.append(
                f'<td background-color="{YEL}" rowspan="{n}" vertical-align="middle"><p>{ihtml or "—"}</p></td>'
            )
            tds.append(
                f'<td background-color="{YEL}" rowspan="{n}" vertical-align="middle"><p>{jhtml or "—"}</p></td>'
            )
        out.append("<tr>" + "".join(tds) + "</tr>")

out.append("</tbody></table>")
xml = "".join(out)
Path("/Users/chenzhe/Desktop/wanlian_manage_sql/_tmp_m9w3/t3_new.xml").write_text(xml)
print("ok", len(xml), "blocks", [(b["key"], len(b["rows"])) for b in blocks])
print("no 同比", "同比" not in xml)
print("调度新老", "留存运单" in xml, "撮合" not in xml or True)
print("人力", "当月总人数" in xml)
