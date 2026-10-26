#!/usr/bin/env python3
"""QCleBZ：KPI概览 / KPI举措 / 平台运营-矩阵 周度列改为公式引用「周度详细数据」。

依赖参数（与第一表共用）：
  J2=上周周起始  K2=本周周起始  L2=月实际列(N)
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SHEET_URL = "https://wanlianyida.feishu.cn/sheets/L91EsEtAohwjhStD4y6cYLCGnVe"
SHEET_ID = "QCleBZ"
W = "周度详细数据"

ops: list[dict] = []


def _lark(*args: str) -> dict:
    cmd = ["lark-cli", "sheets", *args, "--url", SHEET_URL, "--as", "user", "--format", "json"]
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    raw = proc.stdout or proc.stderr
    i = raw.find("{")
    if proc.returncode != 0 or i < 0:
        raise SystemExit(raw[-2000:] or "lark failed")
    data = json.loads(raw[i:])
    if not data.get("ok", True):
        raise SystemExit(json.dumps(data.get("error") or data, ensure_ascii=False)[:2000])
    return data


def put(addr: str, *, value=None, formula=None):
    cell: dict = {}
    if formula is not None:
        cell["formula"] = formula if str(formula).startswith("=") else f"={formula}"
    elif value is not None:
        cell["value"] = value
    else:
        return
    ops.append(
        {
            "shortcut": "+cells-set",
            "input": {"sheet_id": SHEET_ID, "range": addr, "cells": [[cell]]},
        }
    )


def week_wan(week_cell: str, index2: str) -> str:
    """按周起始日 + 层级维度 取万单（无前导=，便于嵌套）。"""
    return (
        f"SUMIFS('{W}'!$F:$F,'{W}'!$A:$A,{week_cell},"
        f"'{W}'!$E:$E,\"{index2}\")"
    )


def week_orders(week_cell: str, index2: str) -> str:
    """万单 → 单（无前导=）。"""
    return f"IFERROR({week_wan(week_cell, index2)}*10000,0)"


def mon(row: int | str) -> str:
    return f'IFERROR(1*INDIRECT("整合表!"&$L$2&"{row}"),0)'


def main() -> int:
    # ========== KPI概览：I=W1 J=W2 K=环比（去掉旧 M9W5 作为当前周）==========
    put("B88", formula=f'="KPI概览（时间进度:"&TEXT(DAY(DATEVALUE($K$2))/DAY(EOMONTH(DATEVALUE($K$2),0)),"0%")&"）"')
    put("C88", formula='="10月(时间进度"&TEXT(DAY(DATEVALUE($K$2))/DAY(EOMONTH(DATEVALUE($K$2),0)),"0%")&"）"')
    put("I89", formula='="W1("&TEXT($J$2,"m/d")&")"')
    put("J89", formula='="W2("&TEXT($K$2,"m/d")&")"')
    put("K89", value="周环比")
    put("L89", value="")

    # 月实际（单 / 占比）← 整合表
    put("E91", formula=f"={mon(65)}*10000")  # 线上运单
    put("E92", formula=f"={mon(88)}*10000")  # 网货
    put("E93", formula=f"={mon(87)}*10000")  # 撮合
    put("E94", formula=f"={mon(86)}*10000")  # TMS
    put("E95", formula='=IFERROR(E92/E91,"")')
    put("E96", formula='=IFERROR(E93/E91,"")')
    put("E97", formula='=IFERROR(E94/E91,"")')
    put("E98", formula=f'=IFERROR({mon(65)}/{mon(5)},"")')  # 线上/整体
    put("F91", formula='=IFERROR(E91/D91,"")')
    put("F98", formula='=IFERROR(E98/D98,"")')

    # 周度运单（单）
    for row, idx in (
        (91, "整体-线上"),
        (92, "线上-网货"),
        (93, "线上-撮合"),
        (94, "线上-TMS"),
    ):
        put(f"I{row}", formula=f"={week_orders('$J$2', idx)}")
        put(f"J{row}", formula=f"={week_orders('$K$2', idx)}")
        put(f"K{row}", formula=f'=IFERROR((J{row}-I{row})/I{row},"")')
        put(f"L{row}", value="")

    # 占比周度
    for row, num_row in ((95, 92), (96, 93), (97, 94)):
        put(f"I{row}", formula=f"=IFERROR(I{num_row}/I91,\"\")")
        put(f"J{row}", formula=f"=IFERROR(J{num_row}/J91,\"\")")
        put(f"K{row}", formula=f"=IFERROR(J{row}-I{row},\"\")")  # pp（小数）
        put(f"L{row}", value="")
    put("I98", formula=f"=IFERROR(I91/{week_orders('$J$2','整体-整体')},\"\")")
    put("J98", formula=f"=IFERROR(J91/{week_orders('$K$2','整体-整体')},\"\")")
    put("K98", formula="=IFERROR(J98-I98,\"\")")
    put("L98", value="")

    # 发货货主周度：周表无该指标，清空旧周列避免误导
    put("I90", value="")
    put("J90", value="")
    put("K90", value="")
    put("L90", value="")

    # ========== KPI举措：H=W1 I=W2 J=环比 ==========
    put("B101", formula='="KPI举措（时间进度:"&TEXT(DAY(DATEVALUE($K$2))/DAY(EOMONTH(DATEVALUE($K$2),0)),"0%")&"）"')
    put(
        "C101",
        formula='="10月｜周度=W1("&TEXT($J$2,"m/d")&")&W2("&TEXT($K$2,"m/d")&")｜源=周度详细数据"',
    )
    put("H102", formula='="W1("&TEXT($J$2,"m/d")&")"')
    put("I102", formula='="W2("&TEXT($K$2,"m/d")&")"')
    put("J102", value="周环比")
    put("K102", value="")

    # 月实际 ← 第一表合计（已对齐03d）
    put("D103", formula="=D4")
    put("D107", formula="=D17")
    put("D111", formula="=D43")
    put("D115", formula="=D66")
    for row, tgt_row in ((103, "C103"), (107, "C107"), (111, "C111"), (115, "C115")):
        put(f"E{row}", formula=f"=IFERROR(D{row}/{tgt_row},\"\")")

    # 周度万单
    init_rows = [
        (103, "线上举措-货主招募"),
        (104, "线上举措-货主招募-TMS"),
        (105, "线上举措-货主招募-撮合"),
        (106, "线上举措-货主招募-网货"),
        (107, "线上举措-电销"),
        (108, "线上举措-电销-TMS"),
        (109, "线上举措-电销-撮合"),
        (110, "线上举措-电销-网货"),
        (111, "线上举措-投流"),
        (112, "线上举措-投流-TMS"),
        (113, "线上举措-投流-撮合"),
        (114, "线上举措-投流-网货"),
        (115, "线上举措-调度"),
        (116, "线上举措-调度-TMS"),
        (117, "线上举措-调度-撮合"),
        (118, "线上举措-调度-网货"),
    ]
    for row, idx in init_rows:
        put(f"H{row}", formula=f"={week_wan('$J$2', idx)}")
        put(f"I{row}", formula=f"={week_wan('$K$2', idx)}")
        put(f"J{row}", formula=f'=IFERROR((I{row}-H{row})/H{row},"")')
        put(f"K{row}", value="")

    # ========== 平台运营-矩阵：J=W1 K=W2 L=环比 ==========
    put("B122", value="平台运营-矩阵")
    put("J122", formula='="W1("&TEXT($J$2,"m/d")&")"')
    put("K122", formula='="W2("&TEXT($K$2,"m/d")&")"')
    put("L122", value="周环比")
    # 清掉更旧周列残留
    for col in ("M", "N", "O"):
        put(f"{col}122", value="")

    # 10月月量（单）← 整合表
    put("H123", formula=f"=({mon(5)}-{mon(65)})*10000")  # 线下≈整体-线上
    put("H124", formula=f"={mon(65)}*10000")
    put("H125", formula=f"={mon(73)}*10000")  # 裂变
    put("H126", formula=f"={mon(75)}*10000")  # 投流
    put("H127", formula=f"={mon(74)}*10000")  # 电销
    put("H128", formula=f"={mon(76)}*10000")  # 调度
    put("I123", formula='=IFERROR(H123/G123-1,"")')
    put("I124", formula='=IFERROR(H124/G124-1,"")')
    put("I125", formula='=IFERROR(H125/G125-1,"")')
    put("I126", formula='=IFERROR(H126/G126-1,"")')
    put("I127", formula='=IFERROR(H127/G127-1,"")')
    put("I128", formula='=IFERROR(H128/G128-1,"")')

    # 月占比
    put("H129", formula="=IFERROR(H123/(H123+H124),\"\")")
    put("H130", formula="=IFERROR(H124/(H123+H124),\"\")")
    put("H131", formula="=IFERROR(H125/(H123+H124),\"\")")
    put("H132", formula="=IFERROR(H126/(H123+H124),\"\")")
    put("H133", formula="=IFERROR(H127/(H123+H124),\"\")")
    put("H134", formula="=IFERROR(H128/(H123+H124),\"\")")
    for row in range(129, 135):
        put(f"I{row}", formula=f"=IFERROR(H{row}-G{row},\"\")")  # vs 9月 pp

    matrix_idx = [
        (123, "整体-线下"),
        (124, "整体-线上"),
        (125, "线上举措-货主招募"),
        (126, "线上举措-投流"),
        (127, "线上举措-电销"),
        (128, "线上举措-调度"),
    ]
    for row, idx in matrix_idx:
        put(f"J{row}", formula=f"={week_orders('$J$2', idx)}")
        put(f"K{row}", formula=f"={week_orders('$K$2', idx)}")
        put(f"L{row}", formula=f'=IFERROR((K{row}-J{row})/J{row},"")')

    # 周占比（分母=线下+线上）
    for row, num_row in (
        (129, 123),
        (130, 124),
        (131, 125),
        (132, 126),
        (133, 127),
        (134, 128),
    ):
        put(f"J{row}", formula=f"=IFERROR(J{num_row}/(J123+J124),\"\")")
        put(f"K{row}", formula=f"=IFERROR(K{num_row}/(K123+K124),\"\")")
        put(f"L{row}", formula=f"=IFERROR(K{row}-J{row},\"\")")

    # 清理测试格
    for r in range(40, 48):
        put(f"Z{r}", value="")

    os.chdir(ROOT)
    print(f"ops={len(ops)}")
    CHUNK = 50
    for i in range(0, len(ops), CHUNK):
        chunk = ops[i : i + CHUNK]
        p = ROOT / "logs" / f"qclebz_kpi_formula_{i // CHUNK}.json"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(chunk, ensure_ascii=False), encoding="utf-8")
        print(f"chunk {i // CHUNK} n={len(chunk)}")
        _lark("+batch-update", "--yes", "--operations", f"@./{p.relative_to(ROOT).as_posix()}")

    print("--- verify ---")
    for addr in [
        "I89",
        "J89",
        "I91",
        "J91",
        "K91",
        "E91",
        "H102",
        "H107",
        "I107",
        "J107",
        "D107",
        "H115",
        "I115",
        "J122",
        "J124",
        "K124",
        "H124",
        "J128",
        "K128",
    ]:
        v = _lark("+cells-get", "--sheet-id", SHEET_ID, "--range", addr)
        print(addr, (v["data"]["ranges"][0]["cells"][0][0] or {}).get("value"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
