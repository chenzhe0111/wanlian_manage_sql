#!/usr/bin/env python3
"""规则问答：从整合表（+可选周度 CSV）回答「为什么运单偏低」等。

不调用大模型；口径对齐 daily_target_digest / refresh_sheet_actuals。
"""

from __future__ import annotations

import csv
import re
from pathlib import Path

import daily_target_digest as dig

ROOT = Path(__file__).resolve().parent
RISK_PP = dig.RISK_BUFFER_PP


def _fmt(v: float | None, d: int = 2) -> str:
    if v is None:
        return "—"
    if abs(v) < 0.005:
        return "~0"
    return f"{v:.{d}f}"


def _pct(rate: float, d: int = 0) -> str:
    return f"{rate * 100:.{d}f}%"


# ---------------------------------------------------------------------------
# 意图冲突优先级（高 → 低；改路由必须同步 qa_intent_cases.json）
# 1 help / empty
# 2 one_liner / risk / catchup
# 3 分举措深挖 init_*（含漏斗/转化/掉队；**高于**新客贡献）
# 4 通用漏斗 stub
# 5 new_contrib（四举措新客；无单举措时）
# 6 上下文短跟进（周度切换等，依赖 prev_intent）
# 7 wow 周环比
# 8 lookup 查数
# 9 retain / structure / gtv / online_share / biz_line / overall / daily
# 10 online_why / why_low
# 11 status
# 12 unknown → 候选澄清
# ---------------------------------------------------------------------------

# 口语/别名 → 标准词（先长后短）
_SYNONYMS: tuple[tuple[str, str], ...] = (
    ("电销挖潜", "电销"),
    ("资源合作", "调度"),
    ("货主招募", "裂变"),
    ("端外投放", "投流"),
    ("端外", "投流"),
    ("新客户", "新客"),
    ("新货主", "新客"),
    ("老货主", "留存"),
    ("老客", "留存"),
    ("转化漏斗", "转化漏斗"),
    ("漏斗转化", "转化漏斗"),
    ("卡点在哪", "卡在哪"),
    ("卡在哪里", "卡在哪"),
    ("哪一环弱", "哪环最弱"),
    ("按周维度", "周度"),
    ("周维度", "周度"),
    ("按周看", "周度"),
    ("改成周", "周度"),
    ("用周看", "周度"),
    ("近一周", "本周"),
    ("这一周", "本周"),
    ("这周", "本周"),
    ("本周呢", "本周"),
    ("上周呢", "上周"),
)

_FUNNEL_KW = ("漏斗", "转化漏斗", "新客转化", "转化率", "卡在哪", "哪环最弱", "转化")

# unknown 澄清：意图 → (匹配词, 示例问法)
_INTENT_HINTS: list[tuple[str, tuple[str, ...], str]] = [
    ("init_tel", ("电销", "漏斗", "转化", "掉队"), "本周电销新客转化漏斗"),
    ("init_ads", ("投流", "端外", "漏斗", "转化", "掉队"), "本周投流转化漏斗"),
    ("init_dispatch", ("调度", "托底", "漏斗"), "调度为什么托底"),
    ("init_fission", ("裂变", "货主招募", "起不来"), "裂变为什么起不来"),
    ("new_contrib", ("新客", "新增", "贡献", "新老"), "本周新客贡献有没有提升"),
    ("wow", ("周环比", "和上周", "本周怎么样", "谁掉"), "这周怎么样 / 周环比"),
    ("why_low", ("为什么", "拖累", "偏低", "掉量", "进度慢"), "为什么运单偏低"),
    ("online_why", ("线上", "完不成", "进度"), "线上进度为什么慢"),
    ("retain", ("留存", "失血", "只靠"), "留存是不是失血"),
    ("biz_line", ("网货", "撮合", "tms", "业务线"), "网货是不是在托 / 撮合为什么弱"),
    ("online_share", ("线上占比", "占比掉", "占比升"), "线上占比为什么掉"),
    ("catchup", ("追赶", "还差", "每天要跑"), "还差多少 / 每天要跑多少"),
    ("risk", ("红灯", "风险"), "红灯 / 盯什么"),
    ("one_liner", ("一句话", "电梯", "今日结论"), "一句话"),
    ("lookup", ("多少", "运单量", "是几", "查一下"), "整体运单量是多少"),
    ("status", ("简报", "达成", "现状", "播报"), "进度简报"),
    ("overall", ("大盘", "峰值", "能不能追上"), "大盘进度"),
    ("gtv", ("gtv", "客单"), "GTV / 客单价怎么样"),
]


def normalize_query(text: str) -> str:
    """去 @、空白，并做业务同义词归一。"""
    t = text or ""
    t = re.sub(r"@_user_\d+", "", t)
    # @机器人 可能带空格：@陈哲的飞书 CLI
    t = re.sub(r"@\S+(?:\s+\S+)*", "", t)
    t = t.strip().lower().replace(" ", "").replace("\u3000", "")
    t = re.sub(r"(的)?飞书cli|cli$", "", t)
    for src, dst in _SYNONYMS:
        if src != dst:
            t = t.replace(src, dst)
    return t


# 「说一下/数据情况/怎么样」等概况词 → 分举措深挖
_SITUATION_KW = (
    "数据",
    "情况",
    "概况",
    "表现",
    "现状",
    "怎么样",
    "如何",
    "说一下",
    "讲一下",
    "看看",
    "汇报",
    "介绍",
    "分析",
)


def _wants_week(t: str) -> bool:
    """是否明确要周度/本周对照（vs 默认月口径）。"""
    return any(
        k in t
        for k in (
            "周度",
            "按周",
            "周维度",
            "周环比",
            "和上周",
            "上周比",
            "本周vs",
            "本周对比",
            "近两周",
            "这周",
            "本周",
            "上周",
        )
    )


def _is_new_contrib_ask(t: str) -> bool:
    return any(
        k in t
        for k in (
            "新客",
            "新客户",
            "新增贡献",
            "新客贡献",
            "新老",
            "留存新增",
            "新增运单",
            "新增有没有",
            "新增是否",
            "新增怎么样",
            "新增提升",
            "新增有没有提升",
        )
    )


def _has_init_topic(t: str) -> bool:
    return any(k in t for k in ("电销", "投流", "调度", "裂变"))


def _is_week_switch_followup(t: str) -> bool:
    """短句切周：几乎只有周度切换词，无运单/环比/举措等主题。"""
    if not _wants_week(t):
        return False
    # 有明确分析主题 → 不是「切周」短跟进
    if _has_init_topic(t) or any(
        k in t
        for k in (
            "漏斗",
            "转化",
            "新客",
            "贡献",
            "留存",
            "占比",
            "gtv",
            "客单",
            "网货",
            "撮合",
            "运单",
            "环比",
            "怎么样",
            "如何",
            "谁",
            "掉了",
            "拖累",
            "为什么",
            "为啥",
            "和上周",
            "上周比",
        )
    ):
        return False
    return any(
        k in t
        for k in ("维度", "看一下", "看看", "再看", "切换", "改成周", "用周", "周度")
    ) or (len(t) <= 8 and any(k in t for k in ("本周", "上周", "近两周")))


def _followup_from_prev(t: str, prev_intent: str | None) -> str | None:
    """承接上一意图的短跟进；返回意图或 None。"""
    if not prev_intent or prev_intent in ("unknown", "empty", "help"):
        return None
    # 「周度/本周看一下」→ 留在上一主题
    if _is_week_switch_followup(t):
        if prev_intent.startswith("init_"):
            return prev_intent
        if prev_intent == "new_contrib":
            return "new_contrib"
        if prev_intent in ("wow", "why_low", "status", "online_why", "overall"):
            return "wow"
        return prev_intent
    # 「漏斗呢 / 转化呢」承接分举措（优先于通用 funnel）
    if prev_intent.startswith("init_") and any(
        k in t for k in ("漏斗", "转化", "卡在", "哪环", "新客")
    ):
        if not _has_init_topic(t) or (
            ("电销" in t and prev_intent == "init_tel")
            or ("投流" in t and prev_intent == "init_ads")
            or ("调度" in t and prev_intent == "init_dispatch")
            or ("裂变" in t and prev_intent == "init_fission")
        ):
            return prev_intent
    # 「那新客呢」承接后问贡献
    if prev_intent.startswith("init_") and _is_new_contrib_ask(t) and not any(
        k in t for k in _FUNNEL_KW
    ):
        if not _has_init_topic(t):
            return "new_contrib"
    return None


def classify_intent(text: str, prev_intent: str | None = None) -> str:
    t = normalize_query(text)
    if not t:
        return "empty"
    if any(k in t for k in ("帮助", "你好", "能问什么", "菜单", "怎么用", "help")):
        return "help"
    if any(k in t for k in ("一句话", "电梯", "今日结论", "给我一句")):
        return "one_liner"
    if any(k in t for k in ("红灯", "风险", "盯什么", "哪些指标风险")):
        return "risk"
    if any(k in t for k in ("追赶", "还差多少", "每天要跑", "所需日均")):
        return "catchup"

    # 分举措：漏斗/掉队/本周概况/数据情况 → init_*（高于新客贡献）
    _init_extra = _FUNNEL_KW + _SITUATION_KW + ("为什么", "掉队", "进度", "本周", "上周", "周度")
    if "电销" in t and any(k in t for k in _init_extra):
        return "init_tel"
    if "投流" in t and any(k in t for k in _init_extra + ("完不成", "结构")):
        return "init_ads"
    if "调度" in t and any(k in t for k in _init_extra + ("托底", "会不会", "健康", "掉")):
        return "init_dispatch"
    if "裂变" in t and any(k in t for k in _init_extra + ("起不来", "有没有量", "卡在")):
        return "init_fission"

    # 上下文短跟进（在通用漏斗 / 新客之前）
    followed = _followup_from_prev(t, prev_intent)
    if followed:
        return followed

    if any(k in t for k in ("漏斗", "卡在哪", "哪环最弱", "转化漏斗")):
        return "funnel"

    # 新客贡献（无漏斗/单举措深挖时）
    if _is_new_contrib_ask(t):
        return "new_contrib"
    # 无上下文的短句切周 → 默认新客周口径
    if _is_week_switch_followup(t):
        return "new_contrib"
    if _wants_week(t) and any(
        k in t for k in ("环比", "怎么样", "贡献", "运单", "举措", "整体", "谁")
    ):
        return "wow"
    if any(k in t for k in ("周环比", "和上周", "本周怎么样", "上周比", "本周vs")):
        return "wow"
    # 专题意图先于通用查数，避免「GTV/大盘进度」被 lookup 抢走
    if any(k in t for k in ("留存", "失血", "只靠老客", "只靠留存")):
        return "retain"
    if any(k in t for k in ("结构漂", "结构偏", "占比过高", "结构是不是")):
        return "structure"
    if any(k in t for k in ("gtv", "客单", "客单价")):
        return "gtv"
    if any(k in t for k in ("线上占比", "占比为什么", "占比掉", "占比升")):
        return "online_share"
    if any(k in t for k in ("业务线", "撮合为什么弱", "网货托", "tms占比", "网货是不是", "网货在托")):
        return "biz_line"
    if any(k in t for k in ("大盘", "峰值路径", "还能不能追上")):
        return "overall"
    if any(k in t for k in ("今天特别", "日异常", "是不是特别差")):
        return "daily"
    if "线上" in t and any(k in t for k in ("慢", "为什么", "完不成", "进度")):
        return "online_why"
    if _is_value_ask(t):
        return "lookup"
    if any(
        k in t
        for k in (
            "为什么",
            "为啥",
            "原因",
            "归因",
            "谁拖累",
            "偏低",
            "掉量",
            "下滑",
            "下降",
            "变少",
            "比较低",
            "比较慢",
            "太慢",
            "偏慢",
            "落后",
            "运单低",
            "运单少",
            "太低",
            "弱",
            "进度慢",
            "达成慢",
            "完成慢",
        )
    ):
        return "why_low"
    # 「多少」里的「少」不是负向词
    t_neg = t.replace("多少", "")
    if "运单" in t and any(k in t_neg for k in ("低", "少", "差", "掉", "慢")):
        return "why_low"
    if "进度" in t and any(k in t_neg for k in ("慢", "差", "低", "少", "落后", "拖")):
        return "why_low"
    if any(k in t for k in ("简报", "进度", "达成", "现状", "怎么样", "播报")):
        return "status"
    return "unknown"


def suggest_intents(text: str, top_n: int = 3) -> list[tuple[str, str]]:
    """unknown 时按关键词打分，返回 [(intent, 示例问法), ...]。"""
    t = normalize_query(text)
    scored: list[tuple[int, str, str]] = []
    for intent, keys, example in _INTENT_HINTS:
        score = sum(2 if k in t else 0 for k in keys)
        # 弱匹配：单字举措名
        if score == 0 and any(k in t for k in keys[:1]):
            score = 1
        if score > 0:
            scored.append((score, intent, example))
    scored.sort(key=lambda x: (-x[0], x[1]))
    out: list[tuple[str, str]] = []
    seen: set[str] = set()
    for _s, intent, example in scored:
        if intent in seen:
            continue
        seen.add(intent)
        out.append((intent, example))
        if len(out) >= top_n:
            break
    if not out:
        out = [
            ("why_low", "为什么运单偏低"),
            ("new_contrib", "本周新客贡献有没有提升"),
            ("init_tel", "本周电销新客转化漏斗"),
        ]
    return out


def _is_value_ask(t: str) -> bool:
    """问指标值（不限运单量）。带归因词的仍走分析。"""
    t_neg = t.replace("多少", "")
    if any(
        k in t
        for k in (
            "为什么",
            "为啥",
            "原因",
            "归因",
            "谁拖累",
            "怎么样",
            "如何",
            "有没有",
            "是否",
            "掉队",
            "完不成",
            "托底",
            "偏低",
            "落后",
            "下滑",
            "下降",
            "太慢",
            "偏慢",
            "进度慢",
        )
    ):
        return False
    if "运单" in t and any(k in t_neg for k in ("低", "少", "差", "掉", "慢")):
        return False
    if any(k in t for k in ("追赶", "还差", "每天要跑", "所需日均")):
        return False
    if any(k in t for k in ("多少", "是几", "查一下", "报一下", "告诉我", "现在是", "目前", "当前", "截止")):
        return True
    tokens = (
        "运单",
        "gtv",
        "客单",
        "日均",
        "峰值",
        "占比",
        "货主",
        "成交率",
        "单货主",
        "认证",
        "注册",
    )
    if any(k in t for k in tokens):
        return True
    scopes = ("整体", "大盘", "线上", "裂变", "电销", "投流", "调度", "撮合", "网货", "tms")
    return any(k in t for k in scopes) and len(t) <= 8


# 表内举措名 → 周度 CSV index1 前缀
_INIT_CSV = {
    "裂变": "货主招募",
    "电销": "电销",
    "投流": "投流",
    "调度": "调度",
}
_TYPES = ("TMS", "撮合", "网货")


def _load_weekly_rows(path: Path) -> list[dict]:
    try:
        if not path.is_file():
            return []
        return list(csv.DictReader(path.open(encoding="utf-8-sig")))
    except OSError:
        return []


def _weekly_labels_sorted(rows: list[dict]) -> list[str]:
    starts: dict[str, str] = {}
    for r in rows:
        label = str(r.get("week_label", "")).strip()
        ws = str(r.get("week_start", "")).strip()[:10]
        if not label:
            continue
        if label not in starts or (ws and ws < starts[label]):
            starts[label] = ws or "9999-99-99"
    return sorted(starts.keys(), key=lambda lb: starts[lb])


def _init_type_week_map(
    rows: list[dict], week_label: str, csv_init: str
) -> dict[str, float]:
    """某周某举措下 TMS/撮合/网货 量（万）。"""
    out = {t: 0.0 for t in _TYPES}
    for r in rows:
        if str(r.get("week_label", "")).strip() != week_label:
            continue
        if str(r.get("data_index", "")).strip() != "线上举措":
            continue
        idx1 = str(r.get("index1", "")).strip()
        try:
            num = float(r.get("num") or 0)
        except ValueError:
            continue
        for t in _TYPES:
            if idx1 == f"{csv_init}-{t}":
                out[t] += num
    return out


def _type_drag_inside_init(
    rows: list[dict], csv_init: str
) -> tuple[str, str, dict[str, float], dict[str, float]] | None:
    """在举措内找周环比掉量最大的运单类型。返回 (本周标签, 上周标签, 本周map, 上周map)。"""
    labels = _weekly_labels_sorted(rows)
    if len(labels) < 2:
        # 仅有一周：按量占比最大类型说明结构，无法谈环比拖累
        if not labels:
            return None
        cur = labels[-1]
        cur_m = _init_type_week_map(rows, cur, csv_init)
        return cur, "", cur_m, {}
    prev, cur = labels[-2], labels[-1]
    cur_m = _init_type_week_map(rows, cur, csv_init)
    prev_m = _init_type_week_map(rows, prev, csv_init)
    return cur, prev, cur_m, prev_m


def _fmt_type_drag(cur_m: dict[str, float], prev_m: dict[str, float], week_cur: str, week_prev: str) -> str:
    if not any(cur_m.values()) and not any(prev_m.values()):
        return "该举措近周无 TMS/撮合/网货 拆解数据。"
    # 有上周：按绝对掉量（万）排序
    if week_prev and prev_m:
        deltas = []
        for t in _TYPES:
            d = cur_m.get(t, 0.0) - prev_m.get(t, 0.0)
            deltas.append((t, prev_m.get(t, 0.0), cur_m.get(t, 0.0), d))
        deltas.sort(key=lambda x: x[3])  # 掉最多在前
        worst_t, p0, p1, d = deltas[0]
        parts = [f"{t} {_fmt(a)}→{_fmt(b)}（{dlt:+.2f}）" for t, a, b, dlt in deltas]
        return (
            f"近周 **{week_prev}→{week_cur}** 类型变化：{'；'.join(parts)}。"
            f"举措内拖累类型是 **{worst_t}**（周变动 {d:+.2f} 万）。"
        )
    # 仅本周：看结构占比
    total = sum(cur_m.values()) or 1.0
    ranked = sorted(_TYPES, key=lambda t: cur_m.get(t, 0.0), reverse=True)
    top = ranked[0]
    share = cur_m.get(top, 0.0) / total * 100
    detail = "、".join(f"{t} {_fmt(cur_m.get(t, 0.0))}（{cur_m.get(t, 0.0)/total*100:.0f}%）" for t in ranked)
    return (
        f"近周 **{week_cur}** 类型结构：{detail}。"
        f"量上以 **{top}** 为主（占该举措 {share:.0f}%）；缺上周对照，环比拖累待周度刷新。"
    )


def answer_why_low() -> str:
    """针对性回答：先点名拖累举措，再点名举措内运单类型。"""
    grid = dig._read_sheet_grid()
    snap = dig.build_snapshot(grid)
    as_of = snap["as_of"]
    expected = dig._expected_as_of()
    tp = snap["time_progress"]
    overall = snap["overall"]
    inits: list[dig.Metric] = snap["initiatives"]
    wh, ch, tms = snap["wh_avg"], snap["ch_avg"], snap["tms_avg"]

    ranked = sorted(inits, key=lambda x: x.gap_pp(tp))
    # 主拖累：落后时间进度最多的
    primary = ranked[0]
    secondary = [x for x in ranked[1:] if x.gap_pp(tp) < -15][:2]
    best = ranked[-1]
    biz = sorted([("网货", wh), ("撮合", ch), ("TMS", tms)], key=lambda x: x[1].gap_pp(tp))
    biz_worst = biz[0][0]

    fresh = "数据已到昨天" if as_of == expected else f"注意：期望截止 {expected}，当前 O1={as_of}"

    lines = [
        f"**直接结论（截止 {as_of}，{fresh}）**",
        "",
        f"1. **拖累举措：{primary.name}**"
        f"（月实际 {_fmt(primary.actual)} 万，达成 {_pct(primary.rate, 1)}，"
        f"落后时间进度 **{primary.gap_pp(tp):+.0f}pp**；时间进度 {_pct(tp)}）。",
    ]
    if secondary:
        sec = "、".join(
            f"{x.name}（{_pct(x.rate, 1)}，{x.gap_pp(tp):+.0f}pp）" for x in secondary
        )
        lines.append(f"   其次：{sec}。相对托底：**{best.name}**（{best.gap_pp(tp):+.0f}pp）。")
    else:
        lines.append(f"   相对托底：**{best.name}**（{best.gap_pp(tp):+.0f}pp）。")

    # 类型下钻：优先在「有量」的拖累举措上拆（裂变≈0 时类型无意义）
    rows = _load_weekly_rows(ROOT / "out" / "quickbi_weekly_latest.csv")
    type_host = primary
    typed = None
    for cand in [primary] + secondary + ranked:
        csv_init = _INIT_CSV.get(cand.name, cand.name)
        trial = _type_drag_inside_init(rows, csv_init) if rows else None
        if not trial:
            continue
        _wc, _wp, cur_m, _pm = trial
        vol = sum(cur_m.values())
        # 月实际或近周类型合计有量才下钻
        if cand.actual >= 0.05 or vol >= 0.05:
            type_host, typed = cand, trial
            break

    lines.append("")
    type_focus = biz_worst
    if typed:
        week_cur, week_prev, cur_m, prev_m = typed
        note = ""
        if type_host.name != primary.name:
            note = f"（{primary.name} 月量≈0，类型下钻改看有量的 **{type_host.name}**）"
        lines.append(f"2. **{type_host.name} 里拖累的运单类型：**{note}")
        lines.append("   " + _fmt_type_drag(cur_m, prev_m, week_cur, week_prev))
        if week_prev and prev_m:
            type_focus = min(_TYPES, key=lambda t: cur_m.get(t, 0.0) - prev_m.get(t, 0.0))
        else:
            type_focus = max(_TYPES, key=lambda t: cur_m.get(t, 0.0))
    else:
        lines.append(
            f"2. **运单类型**：近周拆解不可用；大盘业务线落后首位 **{biz_worst}**"
            f"（网货 {_pct(wh.rate)} / 撮合 {_pct(ch.rate)} / TMS {_pct(tms.rate)}）。"
        )

    lines.append("")
    if typed and type_host.name != primary.name:
        lines.append(
            f"3. **一句话**：进度慢，首要是 **{primary.name}**（几乎没量）；"
            f"量级上再盯 **{type_host.name}**，其内类型重点是 **{type_focus}**。"
            f"整体落后时间进度 {overall.gap_pp(tp):+.0f}pp。"
        )
    else:
        lines.append(
            f"3. **一句话**：进度慢，首要拖累举措是 **{primary.name}**；"
            f"该举措内重点看运单类型 **{type_focus}**。"
            f"整体落后时间进度 {overall.gap_pp(tp):+.0f}pp（达成 {_pct(overall.rate)} / 进度 {_pct(tp)}）。"
        )
    return "\n".join(lines)


# 第七部分：举措 → (新增行, 留存行)
_NEWOLD_ROWS = {
    "裂变": (103, 107),
    "电销": (120, 113),
    "投流": (149, 142),
    "调度": (169, 170),
}


def _funnel_week_starts(path: Path) -> list[str]:
    """漏斗 CSV 中周度周期起始日（升序）。"""
    if not path.is_file():
        return []
    starts: set[str] = set()
    with path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            if "周" not in str(row.get("月周标识") or ""):
                continue
            ws = str(row.get("周期起始日") or "").strip()[:10]
            if ws:
                starts.add(ws)
    return sorted(starts)


def _funnel_metric(
    path: Path, week_start: str, init: str, new_old: str, metric: str
) -> float:
    """漏斗 CSV：某周 × 举措 × 新/老 × 指标类型 → 指标值合计。"""
    total = 0.0
    with path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            if "周" not in str(row.get("月周标识") or ""):
                continue
            if str(row.get("周期起始日") or "").strip()[:10] != week_start:
                continue
            if str(row.get("举措") or "").strip() != init:
                continue
            if str(row.get("新老货主") or "").strip() != new_old:
                continue
            if str(row.get("指标类型") or "").strip() != metric:
                continue
            try:
                total += float(row.get("指标值") or 0)
            except ValueError:
                pass
    return total


def _funnel_waybill(path: Path, week_start: str, init: str, new_old: str) -> float:
    """漏斗 CSV：某周 × 举措 × 新/老 → 成交运单量（单）。"""
    return _funnel_metric(path, week_start, init, new_old, "成交运单量")


def _week_label_from_start(ws: str) -> str:
    from datetime import date, timedelta

    d = date.fromisoformat(ws)
    first = d.replace(day=1)
    first_wed = first + timedelta(days=(2 - first.weekday()) % 7)
    if d < first_wed:
        # 跨月周：归到上月最后一周标签简化为日期
        return f"{d.month}/{d.day}"
    idx = ((d - first_wed).days // 7) + 1
    return f"M{d.month}W{idx}({d.month}/{d.day})"


def answer_new_contrib_weekly() -> str:
    """周度新客贡献：漏斗 CSV 近两周（03d 当周首活）新增量 + 新客占比。"""
    path = ROOT / "out" / "quickbi_funnel_latest.csv"
    starts = _funnel_week_starts(path)
    if len(starts) < 2:
        return (
            "周度新客数据不足两周。请先刷新漏斗（`refresh_sheet_funnel`），"
            "或改问「新客贡献」（默认月口径）。"
        )
    prev_ws, cur_ws = starts[-2], starts[-1]
    prev_lbl, cur_lbl = _week_label_from_start(prev_ws), _week_label_from_start(cur_ws)
    # 漏斗举措名 → 话术名
    inits = [("裂变", "货主招募"), ("电销", "电销"), ("投流", "投流"), ("调度", "调度")]

    lines = [
        f"**四举措新客贡献 · 周度（{prev_lbl}→{cur_lbl}）**",
        "口径：漏斗周度 CSV · **03d 当周首活=新增**；看新增运单周环比 + 新客占本举措比重。",
        "",
    ]
    rows_out = []
    tot_n_p = tot_n_c = 0.0
    for name, csv_init in inits:
        n_p = _funnel_waybill(path, prev_ws, csv_init, "新货主") / 10000.0
        n_c = _funnel_waybill(path, cur_ws, csv_init, "新货主") / 10000.0
        o_p = _funnel_waybill(path, prev_ws, csv_init, "老货主") / 10000.0
        o_c = _funnel_waybill(path, cur_ws, csv_init, "老货主") / 10000.0
        ch = (n_c / n_p - 1) * 100 if n_p > 1e-9 else (-100.0 if n_c < 1e-9 else 999.0)
        sh_p = n_p / (n_p + o_p) * 100 if (n_p + o_p) > 0 else 0.0
        sh_c = n_c / (n_c + o_c) * 100 if (n_c + o_c) > 0 else 0.0
        tot_n_p += n_p
        tot_n_c += n_c
        rows_out.append((name, n_p, n_c, ch, sh_p, sh_c))
        lines.append(
            f"- **{name}**：新增 {_fmt(n_p, 3)}→{_fmt(n_c, 3)} 万（{ch:+.0f}%）；"
            f"新客占比 {sh_p:.1f}%→{sh_c:.1f}%"
        )

    ch_all = (tot_n_c / tot_n_p - 1) * 100 if tot_n_p > 1e-9 else -100.0
    # 量升且占比不掉 → 贡献提升；量升但各举措新客占比仍很低 → 量有回升、贡献仍弱
    improved = [r for r in rows_out if r[3] > 5]
    share_up = [r for r in rows_out if r[5] >= r[4] - 0.3 and r[3] > 5]
    share_still_low = all(r[5] < 5.0 for r in rows_out)  # 本周新客占比均 <5%
    worsened = sorted(rows_out, key=lambda r: r[3])[:2]
    lines.append("")
    if ch_all > 5 and len(share_up) >= 2 and not share_still_low:
        verdict = "**有提升**（周度新增量与占比同步回升）"
    elif ch_all > 5:
        verdict = "**新增量有抬升，但贡献仍弱**（新客占比仍低，主体仍靠留存）"
    elif ch_all > -5:
        verdict = "**基本持平，谈不上提升**"
    else:
        verdict = "**没有提升，周度新增下滑**"
    best = "、".join(f"{r[0]}（{r[3]:+.0f}%）" for r in sorted(improved, key=lambda r: -r[3])[:2]) or "无"
    worst = "、".join(f"{r[0]}（{r[3]:+.0f}%）" for r in worsened)
    lines.append(
        f"{verdict}。四举措新增合计 {_fmt(tot_n_p, 3)}→{_fmt(tot_n_c, 3)} 万（{ch_all:+.0f}%）。"
        f"回升靠前：{best}；偏弱：{worst}。"
    )
    lines.append("（若要月口径日均对比，直接问「新客贡献」，不要带「本周/周度」。）")
    return "\n".join(lines)


def answer_new_contrib(text: str = "") -> str:
    """四举措新客贡献是否提升。

    默认：上月整月 vs 本月截至 O1（月口径日均）。
    问句含本周/周度/和上周 → 改走漏斗近两周。
    """
    t = re.sub(r"@_user_\d+", "", text or "").strip().lower().replace(" ", "")
    if _wants_week(t):
        return answer_new_contrib_weekly()

    import calendar
    from datetime import datetime

    grid = dig._read_sheet_grid()
    as_of_raw = dig._cell_str(grid, 1, "O")
    as_of = dig._parse_as_of_cell(as_of_raw) or dig._expected_as_of()
    d = datetime.strptime(as_of, "%Y-%m-%d").date()
    cur_month = d.strftime("%Y%m")
    # 上一自然月
    if d.month == 1:
        prev_month = f"{d.year - 1}12"
        prev_days = 31
    else:
        prev_month = f"{d.year}{d.month - 1:02d}"
        prev_days = calendar.monthrange(d.year, d.month - 1)[1]
    cur_days = d.day
    prev_col = dig.ACTUAL_COL.get(prev_month)
    cur_col = dig.ACTUAL_COL.get(cur_month)
    if not prev_col or not cur_col:
        return f"当前月 {cur_month} 或不支持的实际列映射，无法算新客贡献。"

    lines = [
        f"**四举措新客贡献（截止 {as_of}）**",
        f"对比：{prev_month[4:]}月整月（{prev_days}天） vs 本月截至 {as_of[5:]}（{cur_days}天）。",
        f"口径：**新增/留存日均 = 月累计÷天数（月口径）**，不是周度日均；另用**新客占比**；忌未完月累计硬比整月绝对量。",
        "（要看本周，请加「本周」或「周度」，如：本周新客贡献有没有提升。）",
        "",
    ]
    rows_out = []
    tot_prev = tot_cur = 0.0
    for name, (r_new, r_old) in _NEWOLD_ROWS.items():
        n_p = dig._cell(grid, r_new, prev_col) or 0.0
        n_c = dig._cell(grid, r_new, cur_col) or 0.0
        o_p = dig._cell(grid, r_old, prev_col) or 0.0
        o_c = dig._cell(grid, r_old, cur_col) or 0.0
        dp, dc = n_p / prev_days, n_c / cur_days
        ch = (dc / dp - 1) * 100 if dp > 1e-9 else (-100.0 if dc < 1e-9 else 999.0)
        sh_p = n_p / (n_p + o_p) * 100 if (n_p + o_p) > 0 else 0.0
        sh_c = n_c / (n_c + o_c) * 100 if (n_c + o_c) > 0 else 0.0
        tot_prev += n_p
        tot_cur += n_c
        rows_out.append((name, n_p, n_c, dp, dc, ch, sh_p, sh_c))
        lines.append(
            f"- **{name}**：新增日均(月) {_fmt(dp, 3)}→{_fmt(dc, 3)}（{ch:+.0f}%）；"
            f"新客占比 {sh_p:.1f}%→{sh_c:.1f}%；月量 {_fmt(n_p)}→{_fmt(n_c)} 万"
        )

    dp_all, dc_all = tot_prev / prev_days, tot_cur / cur_days
    ch_all = (dc_all / dp_all - 1) * 100 if dp_all > 1e-9 else -100.0
    # 判读
    improved = [r[0] for r in rows_out if r[5] > 5 and r[7] >= r[6] - 0.5]
    worsened = sorted(rows_out, key=lambda r: r[5])[:2]
    lines.append("")
    if ch_all > 5 and len(improved) >= 2:
        verdict = "**有提升**"
    elif ch_all > -5:
        verdict = "**基本持平，谈不上提升**"
    else:
        verdict = "**没有提升，整体下滑**"
    worst = "、".join(f"{r[0]}（日均{r[5]:+.0f}%）" for r in worsened)
    lines.append(
        f"{verdict}。四举措新增合计日均 {_fmt(dp_all, 3)}→{_fmt(dc_all, 3)}（{ch_all:+.0f}%）。"
        f"掉最明显：{worst}。"
    )
    return "\n".join(lines)


def _prev_month_key(month: str) -> str | None:
    y, m = int(month[:4]), int(month[4:])
    if m == 1:
        prev = f"{y - 1}12"
    else:
        prev = f"{y}{m - 1:02d}"
    return prev if prev in dig.ACTUAL_COL else None


def _week_total(rows: list[dict], pred) -> tuple[str, str, float] | None:
    """最近一周标签、周起始日、运单量（万）。只加总命中行。"""
    labels = _weekly_labels_sorted(rows)
    if not labels:
        return None
    cur = labels[-1]
    total = 0.0
    ws = ""
    hit = False
    for r in rows:
        if str(r.get("week_label", "")).strip() != cur:
            continue
        if not pred(r):
            continue
        try:
            total += float(r.get("num") or 0)
        except ValueError:
            continue
        hit = True
        ws = str(r.get("week_start", "")).strip()[:10]
    if not hit:
        return None
    return cur, ws, total


# 指标目录：scope, metric, 行号, 单位, 类型(flow/level/peak/avg), 周度键
# flow=可累计量，第三行用日均；level/peak/avg=水平指标，第三行直接跟上月比
_CATALOG = [
    ("整体", "运单量", 5, "万", "flow", "wb:整体"),
    ("整体", "gtv", 6, "亿", "flow", None),
    ("整体", "日均", 3, "万", "avg", "wb:整体"),
    ("整体", "峰值", 4, "万", "peak", None),
    ("线上", "运单量", 65, "万", "flow", "wb:线上"),
    ("线上", "日均", 66, "万", "avg", "wb:线上"),
    ("线上", "峰值", 67, "万", "peak", None),
    ("线上", "占比", 68, "%", "level", None),
    ("裂变", "运单量", 73, "万", "flow", "init:货主招募"),
    ("电销", "运单量", 74, "万", "flow", "init:电销"),
    ("投流", "运单量", 75, "万", "flow", "init:投流"),
    ("调度", "运单量", 76, "万", "flow", "init:调度"),
    ("网货", "占比", 12, "%", "level", None),
    ("网货", "gtv", 13, "亿", "flow", None),
    ("网货", "客单价", 14, "元", "level", None),
    ("网货", "日均", 15, "万", "avg", "wb:网货"),
    ("网货", "峰值", 16, "万", "peak", None),
    ("网货", "运单量", 17, "万", "flow", "wb:网货"),
    ("撮合", "占比", 19, "%", "level", None),
    ("撮合", "gtv", 20, "亿", "flow", None),
    ("撮合", "客单价", 21, "元", "level", None),
    ("撮合", "日均", 22, "万", "avg", "wb:撮合"),
    ("撮合", "峰值", 23, "万", "peak", None),
    ("撮合", "运单量", 24, "万", "flow", "wb:撮合"),
    ("tms", "占比", 26, "%", "level", None),
    ("tms", "gtv", 27, "亿", "flow", None),
    ("tms", "客单价", 28, "元", "level", None),
    ("tms", "日均", 29, "万", "avg", "wb:TMS"),
    ("tms", "峰值", 30, "万", "peak", None),
    ("tms", "运单量", 31, "万", "flow", "wb:TMS"),
    ("线上tms", "运单量", 86, "万", "flow", "ol:TMS"),
    ("线上撮合", "运单量", 87, "万", "flow", "ol:撮合"),
    ("线上网货", "运单量", 88, "万", "flow", "ol:网货"),
    ("电销留存", "运单量", 113, "万", "flow", "fn:电销:老货主:成交运单量"),
    ("电销留存", "发货货主", 114, "家", "flow", "fn:电销:老货主:发货货主数"),
    ("电销留存", "成交货主", 115, "家", "flow", "fn:电销:老货主:成交货主数"),
    ("电销留存", "成交率", 116, "%", "level", "rate:电销:老货主"),
    ("电销留存", "单货主", 117, "单", "level", "eff:电销:老货主"),
    ("电销新增", "运单量", 120, "万", "flow", "fn:电销:新货主:成交运单量"),
    ("电销新增", "发货货主", 121, "家", "flow", "fn:电销:新货主:发货货主数"),
    ("电销新增", "成交货主", 122, "家", "flow", "fn:电销:新货主:成交货主数"),
    ("电销新增", "成交率", 123, "%", "level", "rate:电销:新货主"),
    ("电销新增", "单货主", 124, "单", "level", "eff:电销:新货主"),
    ("投流留存", "运单量", 142, "万", "flow", "fn:投流:老货主:成交运单量"),
    ("投流留存", "发货货主", 143, "家", "flow", "fn:投流:老货主:发货货主数"),
    ("投流留存", "成交货主", 144, "家", "flow", "fn:投流:老货主:成交货主数"),
    ("投流留存", "成交率", 145, "%", "level", "rate:投流:老货主"),
    ("投流留存", "单货主", 146, "单", "level", "eff:投流:老货主"),
    ("投流新增", "运单量", 149, "万", "flow", "fn:投流:新货主:成交运单量"),
    ("投流新增", "发货货主", 150, "家", "flow", "fn:投流:新货主:发货货主数"),
    ("投流新增", "成交货主", 151, "家", "flow", "fn:投流:新货主:成交货主数"),
    ("投流新增", "成交率", 152, "%", "level", "rate:投流:新货主"),
    ("投流新增", "单货主", 153, "单", "level", "eff:投流:新货主"),
    ("调度新增", "发货货主", 176, "家", "flow", "fn:调度:新货主:发货货主数"),
    ("调度留存", "发货货主", 182, "家", "flow", "fn:调度:老货主:发货货主数"),
    ("调度新增", "运单量", 169, "万", "flow", None),
    ("调度留存", "运单量", 170, "万", "flow", None),
]


def _metric_ids(t: str) -> list[str]:
    ids: list[str] = []
    if "gtv" in t:
        ids.append("gtv")
    if "客单" in t:
        ids.append("客单价")
    if "峰值" in t:
        ids.append("峰值")
    if "日均" in t:
        ids.append("日均")
    if "占比" in t:
        ids.append("占比")
    if "成交率" in t:
        ids.append("成交率")
    if "单货主" in t:
        ids.append("单货主")
    if "成交货主" in t:
        ids.append("成交货主")
    if any(k in t for k in ("发货货主", "发货客户", "新货主", "货主数")):
        ids.append("发货货主")
    if "运单" in t:
        ids.append("运单量")
    return ids or ["运单量"]


def _scope_ids(t: str, metric: str) -> list[str]:
    inits = [n for n in ("裂变", "电销", "投流", "调度") if n in t]
    lines = [n for n in ("网货", "撮合", "tms") if n in t]
    online = "线上" in t
    cohorts: list[str] = []
    if any(k in t for k in ("留存", "老货主", "老客")):
        cohorts.append("留存")
    if any(k in t for k in ("新增", "新货主", "新客")) or (
        metric == "发货货主" and inits and "留存" not in cohorts
    ):
        cohorts.append("新增")
    # 货主没写新/留、且该举措两边都有：两边都给
    if metric in ("发货货主", "成交货主", "成交率", "单货主") and inits and not cohorts:
        cohorts = ["留存", "新增"]
    scopes: list[str] = []
    if online and lines:
        scopes.extend("线上" + n for n in lines)
    elif lines and not inits:
        scopes.extend(lines)
    if inits:
        if cohorts and metric != "运单量" or (cohorts and "运单" in t and any(k in t for k in ("留存", "新增", "新货主", "老货主"))):
            for ini in inits:
                for c in cohorts:
                    scopes.append(ini + c)
        elif cohorts and metric == "运单量" and any(k in t for k in ("留存", "新增", "新货主", "老")):
            for ini in inits:
                for c in cohorts:
                    scopes.append(ini + c)
        else:
            scopes.extend(inits)
    if online and not lines and not inits:
        scopes.append("线上")
    if ("整体" in t or "大盘" in t) and not scopes:
        scopes.append("整体")
    if not scopes:
        scopes.append("整体")
    # 去重保序
    out: list[str] = []
    for s in scopes:
        if s not in out:
            out.append(s)
    return out


def _show_num(v: float | None, unit: str) -> str:
    if v is None:
        return "—"
    if unit == "%":
        x = v * 100 if abs(v) <= 1.5 else v
        return f"{x:.1f}%"
    if unit == "家":
        return f"{v:.0f}" if abs(v) >= 20 else f"{v:.1f}"
    if unit == "元":
        return f"{v:.0f}" if abs(v) >= 10 else _fmt(v, 2)
    if unit == "单":
        return _fmt(v, 2)
    if unit == "亿":
        return _fmt(v, 3) if abs(v) < 0.1 else _fmt(v, 2)
    if abs(v) < 0.1:
        return _fmt(v, 4) if abs(v) < 0.01 else _fmt(v, 3)
    return _fmt(v, 2)


def _week_span(ws: str, as_of_d):
    from datetime import datetime, timedelta

    ws_d = datetime.strptime(ws, "%Y-%m-%d").date()
    w_end = min(as_of_d, ws_d + timedelta(days=6))
    w_days = (w_end - ws_d).days + 1
    span = f"{ws_d.month}/{ws_d.day}–{w_end.month}/{w_end.day}，{w_days} 天"
    return span, w_days


def _wb_pred(key: str):
    if key.startswith("init:"):
        name = key.split(":", 1)[1]
        return lambda r, n=name: str(r.get("data_index")).strip() == "线上举措" and str(r.get("index1")).strip() == n
    if key.startswith("ol:"):
        name = key.split(":", 1)[1]
        return lambda r, n=name: str(r.get("data_index")).strip() == "线上" and str(r.get("index1")).strip() == n
    name = key.split(":", 1)[1]
    return lambda r, n=name: str(r.get("data_index")).strip() == "整体" and str(r.get("index1")).strip() == n


def _funnel_week(init: str, cohort: str, metric: str) -> tuple[str, float] | None:
    path = ROOT / "out" / "quickbi_funnel_latest.csv"
    rows = _load_weekly_rows(path)
    hit = []
    for r in rows:
        if str(r.get("月周标识", "")).strip() != "周度":
            continue
        if str(r.get("举措", "")).strip() != init:
            continue
        if str(r.get("新老货主", "")).strip() != cohort:
            continue
        if str(r.get("指标类型", "")).strip() != metric:
            continue
        hit.append(r)
    if not hit:
        return None
    hit.sort(key=lambda r: str(r.get("周期起始日", "")))
    r = hit[-1]
    try:
        return str(r.get("周期起始日", ""))[:10], float(r.get("指标值") or 0)
    except ValueError:
        return None


def _resolve_week(week_key: str | None, weekly_rows, as_of_d) -> tuple[str, float | None]:
    """返回 (当周文案, 可选数值供水平对比)。文案已含标签。"""
    if not week_key:
        return "周度暂无该指标", None
    if week_key.startswith(("wb:", "init:", "ol:")):
        wk = _week_total(weekly_rows, _wb_pred(week_key))
        if not wk:
            return "周度数据暂无", None
        _label, ws, total = wk
        try:
            span, days = _week_span(ws, as_of_d)
        except ValueError:
            return f"**{_fmt(total)}** 万", total
        return f"**{_fmt(total)}** 万（周三起，{span}）", total
    if week_key.startswith("fn:"):
        _, init, cohort, metric = week_key.split(":")
        got = _funnel_week(init, cohort, metric)
        if not got:
            return "漏斗周度暂无", None
        ws, val = got
        try:
            span, _days = _week_span(ws, as_of_d)
        except ValueError:
            span = ws
        if metric == "成交运单量":
            wan = val / 10000.0
            return f"**{_fmt(wan)}** 万（周三起，{span}；漏斗单量÷10000）", wan
        return f"**{val:.0f}** 家（周三起，{span}；漏斗周度）", val
    if week_key.startswith("rate:"):
        _, init, cohort = week_key.split(":")
        ship = _funnel_week(init, cohort, "发货货主数")
        deal = _funnel_week(init, cohort, "成交货主数")
        if not ship or not deal or ship[1] <= 0:
            return "漏斗周度暂无", None
        rate = deal[1] / ship[1]
        span, _ = _week_span(ship[0], as_of_d)
        return f"**{rate * 100:.1f}%**（周三起，{span}；漏斗成交÷发货）", rate
    if week_key.startswith("eff:"):
        _, init, cohort = week_key.split(":")
        orders = _funnel_week(init, cohort, "成交运单量")
        deal = _funnel_week(init, cohort, "成交货主数")
        if not orders or not deal or deal[1] <= 0:
            return "漏斗周度暂无", None
        eff = orders[1] / deal[1]
        span, _ = _week_span(orders[0], as_of_d)
        return f"**{_fmt(eff, 2)}** 单（周三起，{span}；漏斗运单÷成交货主）", eff
    return "周度暂无该指标", None


def _pick_entries(t: str) -> list[tuple]:
    metrics = _metric_ids(t)
    picked = []
    for metric in metrics:
        for scope in _scope_ids(t, metric):
            for ent in _CATALOG:
                if ent[0] == scope and ent[1] == metric:
                    picked.append(ent)
    # 线上+业务线只写了线上撮合运单，客单等仍落业务线
    if not picked:
        for metric in metrics:
            for scope in _scope_ids(t, metric):
                base = scope.replace("线上", "") if scope.startswith("线上") else scope
                for ent in _CATALOG:
                    if ent[0] == base and ent[1] == metric and ent not in picked:
                        picked.append(ent)
    return picked


def answer_lookup(text: str) -> str:
    """任意指标直答：当月截至、当周截至、日均或水平 vs 上月。"""
    import calendar
    from datetime import datetime

    t = re.sub(r"@_user_\d+", "", text or "").strip().lower().replace(" ", "")
    entries = _pick_entries(t)
    if not entries:
        return "没有对上这个指标。可直接发指标名，例如：**整体运单量** / **撮合GTV** / **投流新货主数** / **电销留存成交率**。"
    grid = dig._read_sheet_grid()
    snap = dig.build_snapshot(grid)
    as_of = snap["as_of"]
    month = snap["month"]
    as_of_d = datetime.strptime(as_of, "%Y-%m-%d").date()
    cur_days = as_of_d.day
    prev_key = _prev_month_key(month)
    prev_days = calendar.monthrange(int(prev_key[:4]), int(prev_key[4:]))[1] if prev_key else 0
    acol = dig.ACTUAL_COL[month]
    pcol = dig.ACTUAL_COL[prev_key] if prev_key else None
    weekly_rows = _load_weekly_rows(ROOT / "out" / "quickbi_weekly_latest.csv")
    blocks = []
    for scope, metric, row, unit, kind, week_key in entries:
        scope_show = scope.replace("tms", "TMS")
        label = f"{scope_show}{metric}" if metric != "运单量" else f"{scope_show}运单量"
        if metric == "运单量" and scope.endswith(("留存", "新增")):
            label = f"{scope}运单量"
        cur = dig._cell(grid, row, acol)
        prev = dig._cell(grid, row, pcol) if pcol else None
        lines = [f"**{label}（截止 {as_of}）**"]
        if cur is None:
            lines.append("- 当月截至：表内无当月实际")
        else:
            lines.append(
                f"- 当月截至：**{_show_num(cur, unit)}**"
                + ("" if unit == "%" else f" {unit}")
                + f"（{as_of_d.month}/1–{as_of_d.month}/{as_of_d.day}，{cur_days} 天）"
            )
        week_txt, _week_val = _resolve_week(week_key, weekly_rows, as_of_d)
        if kind == "peak":
            lines.append("- 当周截至：峰值为月内单日高点，周度无峰值")
        elif kind == "avg" and week_key and week_key.startswith(("wb:", "init:", "ol:")):
            wk = _week_total(weekly_rows, _wb_pred(week_key))
            if wk:
                _lb, ws, total = wk
                try:
                    span, w_days = _week_span(ws, as_of_d)
                    lines.append(f"- 当周截至：**{_fmt(total / w_days)}** {unit}/天（周三起，{span}）")
                except ValueError:
                    lines.append(f"- 当周截至：{week_txt}")
            else:
                lines.append("- 当周截至：周度数据暂无")
        else:
            lines.append(f"- 当周截至：{week_txt}")
        if cur is not None and prev is not None:
            if kind == "flow" and cur_days and prev_days:
                ca, pa = cur / cur_days, prev / prev_days
                ch = (ca / pa - 1) * 100 if pa else 0.0
                note = "，月去重÷天数，非日活" if unit == "家" else ""
                lines.append(
                    f"- 日均 vs 上月：本月 **{_show_num(ca, unit)}** {unit}/天"
                    f"（{_show_num(cur, unit)}÷{cur_days}{note}）"
                    f" vs 上月整月 **{_show_num(pa, unit)}** {unit}/天"
                    f"（{_show_num(prev, unit)}÷{prev_days}），**{ch:+.1f}%**"
                )
            elif kind == "peak" and prev:
                lines.append(
                    f"- 对比上月：上月峰值 **{_show_num(prev, unit)}** {unit}，"
                    f"**{(cur / prev - 1) * 100:+.1f}%**"
                )
            elif unit == "%" and prev:
                c_pct = cur * 100 if abs(cur) <= 1.5 else cur
                p_pct = prev * 100 if abs(prev) <= 1.5 else prev
                lines.append(f"- 对比上月：上月 **{p_pct:.1f}%**，**{c_pct - p_pct:+.1f}pp**（率不除天数）")
            elif prev:
                ch = (cur / prev - 1) * 100 if prev else 0.0
                lines.append(
                    f"- 对比上月：上月 **{_show_num(prev, unit)}**"
                    + ("" if unit == "%" else f" {unit}")
                    + f"，**{ch:+.1f}%**（水平指标，不除天数）"
                )
        elif cur is not None and kind == "flow" and cur_days:
            lines.append(f"- 日均：本月 **{_show_num(cur / cur_days, unit)}** {unit}/天（上月列不可比）")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def answer_status() -> str:
    grid = dig._read_sheet_grid()
    snap = dig.build_snapshot(grid)
    tp = snap["time_progress"]
    overall = snap["overall"]
    online = snap["online"]
    inits = snap["initiatives"]
    by = {m.name: m for m in inits}
    return "\n".join(
        [
            f"**达成速览（截止 {snap['as_of']}）**",
            f"- 时间进度 **{_pct(tp)}**",
            f"- 整体月运单 {_fmt(overall.actual)}/{_fmt(overall.target)} 万，达成 {_pct(overall.rate)}（{overall.gap_pp(tp):+.0f}pp）",
            f"- 线上 {_fmt(online.actual)}/{_fmt(online.target)} 万，达成 {_pct(online.rate, 1)}（{online.gap_pp(tp):+.0f}pp）",
            f"- 裂变 {_pct(by['裂变'].rate, 1)} · 电销 {_pct(by['电销'].rate, 1)} · 投流 {_pct(by['投流'].rate, 1)} · 调度 {_pct(by['调度'].rate, 1)}",
            "",
            "深入归因可以说：**为什么运单偏低**",
        ]
    )


def answer_help() -> str:
    return "\n".join(
        [
            "**已固化问法（规则分析）：**",
            "查数（当月/当周/对比上月）：运单、GTV、客单价、占比、货主、成交率 · 进度慢/谁拖累 · 新客贡献 · 大盘/追赶",
            "业务线 · 调度/投流/电销/裂变深挖（可加「本周」看周度漏斗）· 周环比 · 留存 · 红灯 · 结构 · GTV · 一句话",
            "别名：电销挖潜=电销，端外=投流，货主招募=裂变，资源合作=调度。",
            "详析见 `QA_ANALYSIS_PLAYBOOK.md`；意图回归：`python3 qa_intent_regress.py`。",
        ]
    )


def answer_unknown(text: str = "") -> str:
    hints = suggest_intents(text)
    lines = [
        "暂未精确识别意图。你是不是想问：",
    ]
    for i, (_intent, example) in enumerate(hints, 1):
        lines.append(f"{i}. **{example}**")
    lines.append("也可发 **帮助** 看完整清单。")
    return "\n".join(lines)


def answer(
    text: str,
    *,
    intent: str | None = None,
    prev_intent: str | None = None,
) -> str:
    if intent is None:
        intent = classify_intent(text, prev_intent=prev_intent)
    # 短跟进切周时，补「转化漏斗」让分举措走周度漏斗答案
    eff = text
    if (
        intent
        and intent.startswith("init_")
        and _is_week_switch_followup(normalize_query(text))
    ):
        eff = text + " 本周转化漏斗"

    if intent == "help" or intent == "empty":
        return answer_help()
    if intent == "lookup":
        return answer_lookup(text)
    if intent == "status":
        return answer_status()
    if intent == "new_contrib":
        # 短跟进切周：保证走进周口径
        nc_text = text
        if prev_intent == "new_contrib" and _is_week_switch_followup(normalize_query(text)):
            nc_text = text + " 本周"
        return answer_new_contrib(nc_text)
    if intent == "why_low":
        return answer_why_low()

    import qa_playbooks as pb

    dispatch = {
        "online_why": pb.answer_online_why,
        "overall": pb.answer_overall,
        "catchup": pb.answer_catchup,
        "online_share": pb.answer_online_share,
        "biz_line": pb.answer_biz_line,
        "wow": pb.answer_wow,
        "retain": pb.answer_retain,
        "risk": pb.answer_risk,
        "structure": pb.answer_structure,
        "gtv": pb.answer_gtv,
        "one_liner": pb.answer_one_liner,
        "funnel": pb.answer_funnel_stub,
        "daily": pb.answer_daily_proxy,
        "init_dispatch": lambda: pb.answer_init_focus("调度", eff),
        "init_ads": lambda: pb.answer_init_focus("投流", eff),
        "init_tel": lambda: pb.answer_init_focus("电销", eff),
        "init_fission": lambda: pb.answer_init_focus("裂变", eff),
    }
    fn = dispatch.get(intent)
    if fn:
        return fn()
    return answer_unknown(text)


if __name__ == "__main__":
    import sys

    q = " ".join(sys.argv[1:]) or "为什么运单偏低"
    print(answer(q))
