#!/usr/bin/env python3
"""每天从飞书整合表读当月实际，生成达成简报+四举措图，机器人推送。

不依赖 AI：数字来自表格公式列，文案为固定模板填数。
建议挂在 sheet.actuals（10:00）之后，默认 10:20。

推送前会校验 O1「统计截止日」== 昨天（与 actuals 回写口径一致）；
未更新到 T-1 则跳过推送，避免用旧数出简报。可用 --force 强推。
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent


class FreshnessSkip(Exception):
    """目标表未更新到 T-1，跳过本日推送。"""


def _load_dotenv(path: Path) -> None:
    """轻量读 .env，避免强依赖 python-dotenv（可用系统自带 matplotlib 的 Python 跑）。"""
    try:
        if not path.is_file():
            return
        text = path.read_text(encoding="utf-8")
    except OSError:
        return
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, _, v = s.partition("=")
        k, v = k.strip(), v.strip().strip('"').strip("'")
        if k and k not in os.environ:
            os.environ[k] = v


_load_dotenv(ROOT / ".env")

SHEET_URL = os.environ.get(
    "FEISHU_SHEET_URL",
    "https://wanlianyida.feishu.cn/sheets/L91EsEtAohwjhStD4y6cYLCGnVe",
)
SHEET_ID = os.environ.get("FEISHU_SHEET_ID_DIGEST", "1074dd")
# 默认推给你（陈哲）；可用 FEISHU_DIGEST_OPEN_IDS=ou_a,ou_b 覆盖
DEFAULT_OPEN_IDS = "ou_67b8837474ba2147d1ace3641ff1c873"
RISK_BUFFER_PP = 5.0  # 达成率 ≥ 时间进度−5pp → 正常

# 目标列（表头 row2）：B=202608 … F=202612
TARGET_COL = {
    "202608": "B",
    "202609": "C",
    "202610": "D",
    "202611": "E",
    "202612": "F",
}
# 实际列：M=9月 … P=12月
ACTUAL_COL = {
    "202609": "M",
    "202610": "N",
    "202611": "O",
    "202612": "P",
}

# 行号（整合表 1074dd，与 refresh_sheet_actuals 一致）
ROW = {
    "overall_avg": 3,
    "overall_peak": 4,
    "overall_month": 5,
    "overall_gtv": 6,
    "wh_share": 12,
    "wh_avg": 15,
    "wh_month": 17,
    "ch_share": 19,
    "ch_avg": 22,
    "ch_month": 24,
    "tms_share": 26,
    "tms_avg": 29,
    "tms_month": 31,
    "online_month": 65,
    "online_avg": 66,
    "online_peak": 67,
    "init_fission": 73,
    "init_tel": 74,
    "init_ads": 75,
    "init_dispatch": 76,
    "init_sum": 77,
    "type_tms": 86,
    "type_ch": 87,
    "type_wh": 88,
    "type_tms_share": 90,
    "type_ch_share": 91,
    "type_wh_share": 92,
}


def _lark_json(args: list[str], *, as_identity: str = "user") -> dict:
    cmd = ["lark-cli", *args, "--as", as_identity, "--format", "json"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    raw = (proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")
    i = raw.find("{")
    if proc.returncode != 0 or i < 0:
        raise SystemExit(raw[-2500:] or f"lark-cli failed rc={proc.returncode}")
    data = json.loads(raw[i:])
    if not data.get("ok", True):
        raise SystemExit(json.dumps(data.get("error") or data, ensure_ascii=False)[:2500])
    return data


def _parse_num(raw: str | None) -> float | None:
    if raw is None:
        return None
    s = str(raw).strip().replace(",", "").replace("，", "")
    if not s or s in {"-", "#VALUE!", "#N/A", "#DIV/0!", "None"}:
        return None
    pct = s.endswith("%")
    if pct:
        s = s[:-1].strip()
    try:
        v = float(s)
    except ValueError:
        return None
    return v / 100.0 if pct else v


def _col_idx(letter: str) -> int:
    n = 0
    for ch in letter.upper():
        n = n * 26 + (ord(ch) - 64)
    return n - 1


def _read_sheet_grid() -> dict[tuple[int, str], str]:
    """读 A1:T95，返回 {(row, ColLetter): cell_text}。"""
    data = _lark_json(
        [
            "sheets",
            "+csv-get",
            "--spreadsheet-token",
            SHEET_URL.rstrip("/").split("/")[-1].split("?")[0],
            "--sheet-id",
            SHEET_ID,
            "--range",
            "A1:T185",  # 含第七部分新老明细（至调度约 170 行）
        ]
    )
    annotated = data.get("data", {}).get("annotated_csv") or ""
    grid: dict[tuple[int, str], str] = {}
    # [row=N] a,b,c,...
    for line in annotated.split("\n"):
        m = re.match(r"^\[row=(\d+)\]\s?(.*)$", line)
        if not m:
            continue
        r = int(m.group(1))
        # RFC csv of remaining
        row_vals = next(csv.reader(io.StringIO(m.group(2))))
        for i, val in enumerate(row_vals):
            # A=0 … T=19
            if i >= 26:
                continue
            letter = chr(ord("A") + i)
            grid[(r, letter)] = val
    if not grid:
        raise SystemExit("整合表读取为空，请检查 lark-cli 登录与 sheet 权限")
    return grid


def _cell(grid: dict[tuple[int, str], str], row: int, col: str) -> float | None:
    return _parse_num(grid.get((row, col.upper())))


def _cell_str(grid: dict[tuple[int, str], str], row: int, col: str) -> str:
    return (grid.get((row, col.upper())) or "").strip()


@dataclass
class Metric:
    name: str
    actual: float
    target: float

    @property
    def rate(self) -> float:
        if self.target == 0:
            return 0.0
        return self.actual / self.target

    def gap_pp(self, time_progress: float) -> float:
        return self.rate * 100 - time_progress * 100


def _month_from_as_of(as_of: str) -> str:
    # YYYY-MM-DD → YYYYMM
    return as_of[:7].replace("-", "")


def _expected_as_of() -> str:
    """与 refresh_sheet_actuals 一致：pt = 昨天。"""
    return (datetime.now().date() - timedelta(days=1)).strftime("%Y-%m-%d")


def _parse_as_of_cell(raw: str) -> str | None:
    s = (raw or "").strip()
    if re.match(r"^\d{4}-\d{2}-\d{2}$", s):
        return s
    # 偶发带时间
    m = re.match(r"^(\d{4}-\d{2}-\d{2})", s)
    return m.group(1) if m else None


def ensure_sheet_fresh(grid: dict[tuple[int, str], str], *, force: bool = False) -> str:
    """确认整合表已回写到前一天；返回规范化 as_of。

    校验：
    1) O1 统计截止日 == 昨天
    2) 当月「整体-月运单量」实际格有数（避免只改了日期、数还是空）
    """
    expected = _expected_as_of()
    raw = _cell_str(grid, 1, "O")
    as_of = _parse_as_of_cell(raw)
    if force:
        print(f"force=1, skip freshness gate (O1={raw!r}, expected={expected})")
        return as_of or expected

    if not as_of:
        raise FreshnessSkip(
            f"SKIP: O1统计截止日无效={raw!r}，期望={expected}。"
            f"请先跑 refresh_sheet_actuals 或确认表已更新。"
        )
    if as_of != expected:
        raise FreshnessSkip(
            f"SKIP: 目标表尚未更新到前一天。"
            f"O1={as_of} 期望={expected}（等 actuals 回写后再推，或加 --force）。"
        )

    month = _month_from_as_of(as_of)
    acol = ACTUAL_COL.get(month)
    if not acol:
        raise FreshnessSkip(f"SKIP: 月份 {month} 无实际列映射")
    month_actual = _cell(grid, ROW["overall_month"], acol)
    if month_actual is None:
        raise FreshnessSkip(
            f"SKIP: O1已是{as_of}，但 {acol}{ROW['overall_month']} 整体月运单为空，疑似未写完。"
        )
    print(f"freshness ok: O1={as_of} {acol}{ROW['overall_month']}={month_actual}")
    return as_of


def _fmt_wan(v: float | None, digits: int = 2) -> str:
    if v is None:
        return "—"
    if abs(v) < 0.005:
        return "~0"
    return f"{v:.{digits}f}"


def _fmt_pct(rate: float | None, digits: int = 1) -> str:
    if rate is None:
        return "—"
    return f"{rate * 100:.{digits}f}%"


def _fmt_pp(pp: float) -> str:
    return f"{pp:+.0f}pp"


def build_snapshot(grid: dict[tuple[int, str], str]) -> dict:
    as_of = _cell_str(grid, 1, "O") or datetime.now().strftime("%Y-%m-%d")
    # 容忍 O1 写成日期序列/文本
    if re.match(r"^\d{5}$", as_of):
        # Excel serial unlikely via csv string; keep as-is
        pass
    month = _month_from_as_of(as_of) if re.match(r"^\d{4}-\d{2}-\d{2}", as_of) else datetime.now().strftime("%Y%m")
    if not re.match(r"^\d{4}-\d{2}-\d{2}", as_of):
        as_of = datetime.now().strftime("%Y-%m-%d")
        month = _month_from_as_of(as_of)

    tcol = TARGET_COL.get(month)
    acol = ACTUAL_COL.get(month)
    if not tcol or not acol:
        raise SystemExit(f"月份 {month} 不在目标/实际列映射内（支持 202609–202612）")

    # 时间进度：优先 Q1，否则 Q3
    tp = _cell(grid, 1, "Q")
    if tp is None or tp > 2:  # 若误读成 58.06 而非 0.5806
        # _parse_num 已处理 %；若无裸数字 58.06 则当百分数
        raw_q = _cell_str(grid, 1, "Q")
        if raw_q and not raw_q.endswith("%"):
            n = _parse_num(raw_q)
            if n is not None and n > 1:
                tp = n / 100.0
    if tp is None:
        tp = _cell(grid, 3, "Q")
        if tp is not None and tp > 1:
            tp = tp / 100.0
    if tp is None:
        # 按当月自然日粗算
        d = datetime.strptime(as_of, "%Y-%m-%d").date()
        import calendar

        days = calendar.monthrange(d.year, d.month)[1]
        tp = d.day / days

    def m(name: str, row: int) -> Metric:
        a = _cell(grid, row, acol) or 0.0
        t = _cell(grid, row, tcol) or 0.0
        return Metric(name, a, t)

    initiatives = [
        m("裂变", ROW["init_fission"]),
        m("电销", ROW["init_tel"]),
        m("投流", ROW["init_ads"]),
        m("调度", ROW["init_dispatch"]),
    ]
    overall = m("整体月运单", ROW["overall_month"])
    overall_avg = m("整体日均", ROW["overall_avg"])
    overall_peak = m("整体峰值", ROW["overall_peak"])
    online = m("线上月运单", ROW["online_month"])
    wh_avg = m("网货日均", ROW["wh_avg"])
    ch_avg = m("撮合日均", ROW["ch_avg"])
    tms_avg = m("TMS日均", ROW["tms_avg"])

    type_tms = _cell(grid, ROW["type_tms"], acol) or 0.0
    type_ch = _cell(grid, ROW["type_ch"], acol) or 0.0
    type_wh = _cell(grid, ROW["type_wh"], acol) or 0.0
    type_sum = type_tms + type_ch + type_wh
    type_shares = {
        "TMS": type_tms / type_sum if type_sum else 0.0,
        "撮合": type_ch / type_sum if type_sum else 0.0,
        "网货": type_wh / type_sum if type_sum else 0.0,
    }

    wh_share = _cell(grid, ROW["wh_share"], acol)
    ch_share = _cell(grid, ROW["ch_share"], acol)
    # 占比格子可能已是 0.46 或 46%
    if wh_share is not None and wh_share > 1:
        wh_share /= 100.0
    if ch_share is not None and ch_share > 1:
        ch_share /= 100.0

    return {
        "as_of": as_of,
        "month": month,
        "month_label": f"{int(month[4:])}月",
        "time_progress": tp,
        "overall": overall,
        "overall_avg": overall_avg,
        "overall_peak": overall_peak,
        "online": online,
        "wh_avg": wh_avg,
        "ch_avg": ch_avg,
        "tms_avg": tms_avg,
        "wh_share": wh_share,
        "ch_share": ch_share,
        "initiatives": initiatives,
        "type_shares": type_shares,
        "type_vals": {"TMS": type_tms, "撮合": type_ch, "网货": type_wh},
    }


def _status(rate: float, tp: float) -> str:
    return "正常" if rate * 100 >= tp * 100 - RISK_BUFFER_PP else "风险"


def _strongest_weakest(inits: list[Metric], tp: float) -> tuple[Metric, list[Metric]]:
    ranked = sorted(inits, key=lambda x: x.gap_pp(tp), reverse=True)
    return ranked[0], ranked[1:]


def render_markdown(snap: dict) -> str:
    tp = snap["time_progress"]
    tp_pct = tp * 100
    as_of = snap["as_of"]
    ml = snap["month_label"]
    overall: Metric = snap["overall"]
    o_avg: Metric = snap["overall_avg"]
    o_peak: Metric = snap["overall_peak"]
    online: Metric = snap["online"]
    wh: Metric = snap["wh_avg"]
    ch: Metric = snap["ch_avg"]
    tms: Metric = snap["tms_avg"]
    inits: list[Metric] = snap["initiatives"]
    best, rest = _strongest_weakest(inits, tp)
    weak_names = "、".join(x.name for x in rest if x.gap_pp(tp) < -RISK_BUFFER_PP) or "—"

    by_name = {x.name: x for x in inits}
    fission, tel, ads, dispatch = by_name["裂变"], by_name["电销"], by_name["投流"], by_name["调度"]
    ts = snap["type_shares"]

    wh_share_s = _fmt_pct(snap["wh_share"]) if snap["wh_share"] is not None else "—"
    ch_share_s = _fmt_pct(snap["ch_share"]) if snap["ch_share"] is not None else "—"

    # 一句话结构：托底 + 相对撑住 + 短板
    bearer = best.name
    support = []
    if wh.rate >= tp - RISK_BUFFER_PP / 100:
        support.append("网货相对撑住")
    drag = []
    if ch.gap_pp(tp) < -15:
        drag.append("撮合塌陷")
    if fission.actual < 0.05:
        drag.append("裂变未起")
    if ads.gap_pp(tp) < -20:
        drag.append("投流远未放量")
    drag_s = " + ".join(drag) if drag else "其余举措偏弱"
    support_s = "、".join(support) if support else "结构分化"

    title_status = "明显落后目标" if overall.gap_pp(tp) < -RISK_BUFFER_PP else "接近时间进度"
    return f"""**{ml}截止 {as_of[5:]}（时间进度 {tp_pct:.0f}%）总判：整体与线上均{title_status}，{bearer}托底、{weak_names}拖累。**

### 整体大盘
- 月运单约 **{_fmt_wan(overall.actual)} 万**（目标 {_fmt_wan(overall.target)} 万），达成约 **{_fmt_pct(overall.rate, 0)}**，落后时间进度约 **{abs(overall.gap_pp(tp)):.0f}pp**
- 日均约 **{_fmt_wan(o_avg.actual)} 万**（目标 {_fmt_wan(o_avg.target)}），峰值约 **{_fmt_wan(o_peak.actual)} 万**（目标 {_fmt_wan(o_peak.target)}）→ {_status(o_avg.rate, tp)}
- 业务线：**网货日均**达成约 {_fmt_pct(wh.rate, 0)}（占比约 {wh_share_s}）；**撮合**达成约 {_fmt_pct(ch.rate, 0)}（占比约 {ch_share_s}）；TMS 日均达成约 {_fmt_pct(tms.rate, 0)}

### 线上与四举措
- 线上月运单约 **{_fmt_wan(online.actual)} 万**（目标 {_fmt_wan(online.target)} 万），达成约 **{_fmt_pct(online.rate, 1)}**，落后约 **{abs(online.gap_pp(tp)):.0f}pp**
- 调度约 **{_fmt_wan(dispatch.actual)} 万**（达成 {_fmt_pct(dispatch.rate, 0)}，{_fmt_pp(dispatch.gap_pp(tp))}）；电销约 **{_fmt_wan(tel.actual)} 万**、投流约 **{_fmt_wan(ads.actual)} 万**；裂变约 **{_fmt_wan(fission.actual, 3)} 万**
- 线上类型：TMS 约 **{ts['TMS']*100:.0f}%**、网货约 **{ts['网货']*100:.0f}%**、撮合约 **{ts['撮合']*100:.0f}%**

**一句话：** {ml}进度是「{bearer}兜底、{support_s}，{drag_s}」，整体/线上相对峰值路径目标均处{_status(overall.rate, tp)}区间。

### 四举措达成对比图
"""


def make_chart(snap: dict, out_path: Path) -> Path:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    matplotlib.rcParams["font.sans-serif"] = [
        "PingFang SC",
        "Heiti SC",
        "Arial Unicode MS",
        "SimHei",
        "DejaVu Sans",
    ]
    matplotlib.rcParams["axes.unicode_minus"] = False

    inits: list[Metric] = snap["initiatives"]
    tp = snap["time_progress"] * 100
    names = [x.name for x in inits]
    achieve = np.array([x.rate * 100 for x in inits])
    gap_pp = achieve - tp
    as_of = snap["as_of"]
    ml = snap["month_label"]

    fig, ax = plt.subplots(figsize=(6.2, 4.0), dpi=160)
    fig.suptitle(
        f"四举措 · {ml}目标达成率 vs 时间进度（截止{as_of[5:]}）",
        fontsize=12,
        fontweight="bold",
        y=1.01,
    )
    colors = ["#E24B4A" if g < -RISK_BUFFER_PP else "#3BA55C" for g in gap_pp]
    bars = ax.bar(names, achieve, color=colors, width=0.55, edgecolor="none")
    ax.axhline(tp, color="#F5A623", linestyle="--", linewidth=1.8, label=f"时间进度 {tp:.0f}%")
    ax.set_ylabel("达成率（%）")
    ax.set_ylim(0, max(75, float(achieve.max()) + 15, tp + 10))
    ax.legend(frameon=False, loc="upper left")
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    for b, a, g in zip(bars, achieve, gap_pp):
        ax.text(
            b.get_x() + b.get_width() / 2,
            b.get_height() + 1.5,
            f"{a:.1f}%\n({g:+.0f}pp)",
            ha="center",
            va="bottom",
            fontsize=9,
            color="#333",
        )
    best = max(inits, key=lambda x: x.gap_pp(snap["time_progress"]))
    fig.text(
        0.5,
        -0.02,
        f"判定：达成率 ≥ 时间进度−{RISK_BUFFER_PP:.0f}pp → 正常；否则风险。"
        f"{best.name}最接近进度（{_fmt_pp(best.gap_pp(snap['time_progress']))}）。",
        ha="center",
        fontsize=8.5,
        color="#666",
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(out_path, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_path


def upload_image(rel_path: str) -> str:
    """rel_path 必须是 cwd 相对路径（lark-cli 拒绝绝对路径与 ..）。"""
    data = _lark_json(
        [
            "im",
            "images",
            "create",
            "--data",
            json.dumps({"image_type": "message"}),
            "--file",
            f"image={rel_path}",
        ],
        as_identity="bot",
    )
    key = (data.get("data") or {}).get("image_key")
    if not key:
        raise SystemExit(f"上传图片失败: {data}")
    return key


def _post_content(markdown_body: str, image_key: str, title: str) -> str:
    sheet_link = f"{SHEET_URL}?sheet={SHEET_ID}"
    footer = f"数据源：[目标管理整合表]({sheet_link})"
    content = {
        "zh_cn": {
            "title": title,
            "content": [
                [{"tag": "md", "text": markdown_body}],
                [{"tag": "img", "image_key": image_key}],
                [{"tag": "md", "text": footer}],
            ],
        }
    }
    return json.dumps(content, ensure_ascii=False)


def _send_one(*, content_json: str, as_identity: str, open_id: str = "", chat_id: str = "") -> str:
    args = ["im", "+messages-send", "--msg-type", "post", "--content", content_json]
    if chat_id:
        args += ["--chat-id", chat_id]
    elif open_id:
        args += ["--user-id", open_id]
    else:
        raise SystemExit("发送目标缺失：需要 chat_id 或 open_id")
    data = _lark_json(args, as_identity=as_identity)
    return (data.get("data") or {}).get("message_id") or ""


def send_digest_chat(chat_id: str, markdown_body: str, image_key: str, title: str) -> None:
    content_json = _post_content(markdown_body, image_key, title)
    mid = _send_one(content_json=content_json, as_identity="bot", chat_id=chat_id)
    print(f"sent chat_id={chat_id} as=bot message_id={mid}")


def send_digest_users(open_ids: list[str], markdown_body: str, image_key: str, title: str) -> None:
    content_json = _post_content(markdown_body, image_key, title)
    prefer = (os.environ.get("FEISHU_DIGEST_AS") or "bot").strip().lower()
    if prefer not in {"bot", "user"}:
        prefer = "bot"
    failures: list[str] = []
    for oid in open_ids:
        identities = [prefer] + ([x for x in ("bot", "user") if x != prefer])
        last_err = ""
        sent = False
        for ident in identities:
            try:
                mid = _send_one(content_json=content_json, as_identity=ident, open_id=oid)
                print(f"sent open_id={oid} as={ident} message_id={mid}")
                sent = True
                break
            except SystemExit as e:
                last_err = str(e)
                if "230013" in last_err or "NO availability" in last_err:
                    print(f"warn open_id={oid} as={ident} unavailable, try next identity")
                    continue
                print(f"warn open_id={oid} as={ident} failed: {last_err[:300]}")
                continue
        if not sent:
            failures.append(f"{oid}: {last_err[:500]}")
    if failures:
        raise SystemExit("部分接收人发送失败:\n" + "\n".join(failures))


def main() -> int:
    ap = argparse.ArgumentParser(description="每日目标达成简报推送")
    ap.add_argument("--dry-run", action="store_true", help="只出图和文案，不发送")
    ap.add_argument("--force", action="store_true", help="跳过「O1必须=昨天」校验，强制推送")
    ap.add_argument("--open-ids", default="", help="逗号分隔 open_id；有 FEISHU_DIGEST_CHAT_ID 时忽略")
    ap.add_argument("--chat-id", default="", help="群 oc_xxx，覆盖环境变量 FEISHU_DIGEST_CHAT_ID")
    args = ap.parse_args()

    print(f"[{datetime.now():%F %T}] daily_target_digest start")
    os.chdir(ROOT)
    grid = _read_sheet_grid()
    try:
        ensure_sheet_fresh(grid, force=args.force)
    except FreshnessSkip as e:
        print(str(e))
        return 0  # 数据未就绪：正常退出，避免 launchd 当成脚本故障

    snap = build_snapshot(grid)
    md = render_markdown(snap)
    title = f"{snap['month_label']}目标达成简报（截止{snap['as_of'][5:]}）"

    out_dir = ROOT / "out"
    chart_path = out_dir / f"digest_{snap['as_of']}.png"
    make_chart(snap, chart_path)
    latest = out_dir / "digest_latest.png"
    latest.write_bytes(chart_path.read_bytes())
    md_path = out_dir / "digest_latest.md"
    md_path.write_text(md, encoding="utf-8")
    print(f"as_of={snap['as_of']} tp={snap['time_progress']*100:.2f}% chart={chart_path}")

    if args.dry_run:
        print("--- markdown preview ---")
        print(md)
        print("--- dry-run: skip send ---")
        return 0

    chat_id = (args.chat_id or os.environ.get("FEISHU_DIGEST_CHAT_ID") or "").strip()
    open_ids_raw = args.open_ids or os.environ.get("FEISHU_DIGEST_OPEN_IDS", DEFAULT_OPEN_IDS)
    open_ids = [x.strip() for x in open_ids_raw.split(",") if x.strip()]
    if not chat_id and not open_ids:
        raise SystemExit("未配置接收目标：FEISHU_DIGEST_CHAT_ID 或 FEISHU_DIGEST_OPEN_IDS")

    upload_rel = "out/digest_latest.png"
    Path(upload_rel).write_bytes(chart_path.read_bytes())
    image_key = upload_image(upload_rel)
    print(f"image_key={image_key}")
    if chat_id:
        send_digest_chat(chat_id, md, image_key, title)
    else:
        send_digest_users(open_ids, md, image_key, title)
    print("done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
