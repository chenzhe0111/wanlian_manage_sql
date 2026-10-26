#!/usr/bin/env python3
"""QCleBZ「七、线上举措转化」：10月实际 / 周度 改为公式引用。

参数格（可改）：
  J2 = 上周周起始日（如 2026-10-07）
  K2 = 本周周起始日（如 2026-10-14）
  L2 = 月实际列字母（10月=N，11月=O，12月=P）

月实际 ← INDIRECT(\"整合表!\"&$L$2&行号)
周度   ← SUMIFS(月度周度漏斗数据 … 按周起始+举措+新老+指标)
完成度/环比 ← 本表公式
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SHEET_URL = "https://wanlianyida.feishu.cn/sheets/L91EsEtAohwjhStD4y6cYLCGnVe"
SHEET_ID = "QCleBZ"
FUN = "月度周度漏斗数据"

# 当前默认参数（10月 as_of=10-20 → M10W1/M10W2）
WEEK1 = "2026-10-07"
WEEK2 = "2026-10-14"
MONTH_COL = "N"


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


ops: list[dict] = []


def put(addr: str, *, value=None, formula=None):
    cell: dict = {}
    if formula is not None:
        cell["formula"] = formula if formula.startswith("=") else f"={formula}"
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


def mon(row: int | str) -> str:
    # 空单元格当 0，避免合计出现 #VALUE!
    return f'=IFERROR(1*INDIRECT("整合表!"&$L$2&"{row}"),0)'


def fun(week_cell: str, init: str, shipper: str, metric: str, *, wan: bool = False) -> str:
    base = (
        f"=SUMIFS('{FUN}'!$G:$G,'{FUN}'!$C:$C,{week_cell},"
        f"'{FUN}'!$D:$D,\"{init}\",'{FUN}'!$E:$E,\"{shipper}\",'{FUN}'!$F:$F,\"{metric}\")"
    )
    return base + ("/10000" if wan else "")


def main() -> int:
    # ---- 参数区 ----
    put("J1", value="上周周起始")
    put("K1", value="本周周起始")
    put("L1", value="月实际列")
    put("J2", value=WEEK1)
    put("K2", value=WEEK2)
    put("L2", value=MONTH_COL)

    put(
        "A2",
        value=(
            "目标←本表C列；实际D←整合表月实际列(参数L2)；"
            "周度F/G←月度周度漏斗数据 SUMIFS(参数J2/K2)；"
            "完成度E=D/C；环比H=(G-F)/F｜改周改J2/K2，换月改L2"
        ),
    )
    put("F3", formula='="M10W1("&TEXT($J$2,"m/d")&")"')
    put("G3", formula='="M10W2("&TEXT($K$2,"m/d")&")"')

    # ---- 裂变 ----
    put("D6", formula=mon(98))  # 种子（整合表有该行；新老脚本未必回写）
    put("D8", formula=mon(100))
    put("D10", formula=mon(102))
    put("D11", formula=mon(103))
    put("D12", formula=mon(104))
    put("D14", formula=mon(107))
    put("D15", formula=mon(108))
    put("D16", formula=mon(109))
    put("D4", formula="=N(D11)+N(D14)")
    put("D7", formula='=IFERROR(D8/D6,"")')
    put("D9", formula='=IFERROR(D10/D8,"")')

    put("F11", formula=fun("$J$2", "货主招募", "新货主", "成交运单量", wan=True))
    put("G11", formula=fun("$K$2", "货主招募", "新货主", "成交运单量", wan=True))
    put("F10", formula=fun("$J$2", "货主招募", "新货主", "发货货主数"))
    put("G10", formula=fun("$K$2", "货主招募", "新货主", "发货货主数"))
    put("F14", formula=fun("$J$2", "货主招募", "老货主", "成交运单量", wan=True))
    put("G14", formula=fun("$K$2", "货主招募", "老货主", "成交运单量", wan=True))
    put("F15", formula=fun("$J$2", "货主招募", "老货主", "成交货主数"))
    put("G15", formula=fun("$K$2", "货主招募", "老货主", "成交货主数"))
    put("F16", formula='=IFERROR(F14*10000/F15,"")')
    put("G16", formula='=IFERROR(G14*10000/G15,"")')
    put("F4", formula="=IFERROR(F11,0)+IFERROR(F14,0)")
    put("G4", formula="=IFERROR(G11,0)+IFERROR(G14,0)")

    # ---- 电销 ----
    put("D19", formula=mon(113))
    put("D20", formula=mon(114))
    put("D21", formula=mon(115))
    put("D22", formula=mon(116))
    put("D23", formula=mon(117))
    put("D25", formula=mon(120))
    put("D26", formula=mon(121))
    put("D27", formula=mon(122))
    put("D28", formula=mon(123))
    put("D29", formula=mon(124))
    put("D32", formula=mon(128))
    put("D17", formula="=N(D19)+N(D25)")

    for col, wk in (("F", "$J$2"), ("G", "$K$2")):
        put(f"{col}19", formula=fun(wk, "电销", "老货主", "成交运单量", wan=True))
        put(f"{col}20", formula=fun(wk, "电销", "老货主", "发货货主数"))
        put(f"{col}21", formula=fun(wk, "电销", "老货主", "成交货主数"))
        put(f"{col}22", formula=f'=IFERROR({col}21/{col}20,"")')
        put(f"{col}23", formula=f'=IFERROR({col}19*10000/{col}21,"")')
        put(f"{col}25", formula=fun(wk, "电销", "新货主", "成交运单量", wan=True))
        put(f"{col}26", formula=fun(wk, "电销", "新货主", "发货货主数"))
        put(f"{col}27", formula=fun(wk, "电销", "新货主", "成交货主数"))
        put(f"{col}28", formula=f'=IFERROR({col}27/{col}26,"")')
        put(f"{col}29", formula=f'=IFERROR({col}25*10000/{col}27,"")')
        put(f"{col}32", formula=fun(wk, "电销", "新货主", "认证企业数"))
        put(f"{col}17", formula=f"=IFERROR({col}19,0)+IFERROR({col}25,0)")

    # ---- 投流 ----
    put("D45", formula=mon(142))
    put("D46", formula=mon(143))
    put("D47", formula=mon(144))
    put("D48", formula=mon(145))
    put("D49", formula=mon(146))
    put("D51", formula=mon(149))
    put("D52", formula=mon(150))
    put("D53", formula=mon(151))
    put("D54", formula=mon(152))
    put("D55", formula=mon(153))
    put("D57", formula=mon(156))
    put("D58", formula=mon(157))
    put("D59", formula=mon(158))
    put("D43", formula="=N(D45)+N(D51)")
    put("D62", formula='=IFERROR(D58/D59,"")')
    put("D63", formula='=IFERROR(D57/D58,"")')
    put("D64", formula='=IFERROR(D52/D57,"")')

    for col, wk in (("F", "$J$2"), ("G", "$K$2")):
        put(f"{col}45", formula=fun(wk, "投流", "老货主", "成交运单量", wan=True))
        put(f"{col}46", formula=fun(wk, "投流", "老货主", "发货货主数"))
        put(f"{col}47", formula=fun(wk, "投流", "老货主", "成交货主数"))
        put(f"{col}48", formula=f'=IFERROR({col}47/{col}46,"")')
        put(f"{col}49", formula=f'=IFERROR({col}45*10000/{col}47,"")')
        put(f"{col}51", formula=fun(wk, "投流", "新货主", "成交运单量", wan=True))
        put(f"{col}52", formula=fun(wk, "投流", "新货主", "发货货主数"))
        put(f"{col}53", formula=fun(wk, "投流", "新货主", "成交货主数"))
        put(f"{col}54", formula=f'=IFERROR({col}53/{col}52,"")')
        put(f"{col}55", formula=f'=IFERROR({col}51*10000/{col}53,"")')
        put(f"{col}57", formula=fun(wk, "投流", "整体", "认证企业数"))
        put(f"{col}58", formula=fun(wk, "投流", "整体", "注册企业数"))
        put(f"{col}59", formula=fun(wk, "投流", "整体", "注册账号"))
        put(f"{col}62", formula=f'=IFERROR({col}58/{col}59,"")')
        put(f"{col}63", formula=f'=IFERROR({col}57/{col}58,"")')
        put(f"{col}64", formula=f'=IFERROR({col}52/{col}57,"")')
        put(f"{col}43", formula=f"=IFERROR({col}45,0)+IFERROR({col}51,0)")

    # ---- 调度 ----
    put("D68", formula=mon(168))
    put("D69", formula=mon(169))
    put("D70", formula=mon(170))
    put("D75", formula=mon(176))
    put("D81", formula=mon(182))
    put("D66", formula="=N(D68)")

    for col, wk in (("F", "$J$2"), ("G", "$K$2")):
        put(f"{col}69", formula=fun(wk, "调度", "新货主", "成交运单量", wan=True))
        put(f"{col}70", formula=fun(wk, "调度", "老货主", "成交运单量", wan=True))
        put(f"{col}68", formula=f"=IFERROR({col}69,0)+IFERROR({col}70,0)")
        put(f"{col}66", formula=f"=IFERROR({col}68,0)")
        put(f"{col}75", formula=fun(wk, "调度", "新货主", "发货货主数"))
        put(f"{col}81", formula=fun(wk, "调度", "老货主", "发货货主数"))

    # ---- 完成度 E、环比 H（数量行）----
    metric_rows = [
        4,
        6,
        8,
        10,
        11,
        12,
        14,
        15,
        16,
        17,
        19,
        20,
        21,
        23,
        25,
        26,
        27,
        29,
        32,
        43,
        45,
        46,
        47,
        49,
        51,
        52,
        53,
        55,
        57,
        58,
        59,
        66,
        68,
        69,
        70,
        75,
        81,
    ]
    rate_rows = [22, 28, 48, 54, 62, 63, 64]  # 率：环比用 pp

    for r in metric_rows:
        put(f"E{r}", formula=f'=IF(OR(C{r}="",C{r}=0),"",D{r}/C{r})')
        put(f"H{r}", formula=f'=IF(OR(F{r}="",F{r}=0),"",(G{r}-F{r})/F{r})')
    for r in rate_rows:
        put(f"E{r}", formula=f'=IF(OR(C{r}="",C{r}=0),"",D{r}/IF(C{r}>1.5,C{r}/100,C{r}))')
        put(f"H{r}", formula=f'=IF(OR(F{r}="",G{r}=""),"",G{r}-F{r})')  # 小数差；显示可自行设 pp

    # 清理测试格
    for addr in ["Z1", "Z10", "Z11", "Z12", "Z20", "Z21", "Z22", "Z23", "Z30", "Z31", "Z32", "Z33"]:
        put(addr, value="")

    os.chdir(ROOT)
    print(f"ops={len(ops)}")
    CHUNK = 60
    for i in range(0, len(ops), CHUNK):
        chunk = ops[i : i + CHUNK]
        p = ROOT / "logs" / f"qclebz_formula_chunk_{i // CHUNK}.json"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(chunk, ensure_ascii=False), encoding="utf-8")
        print(f"write chunk {i // CHUNK} n={len(chunk)}")
        _lark("+batch-update", "--yes", "--operations", f"@./{p.relative_to(ROOT).as_posix()}")

    # verify
    v = _lark("+cells-get", "--sheet-id", SHEET_ID, "--range", "J2:L2")
    print("params", json.dumps(v.get("data"), ensure_ascii=False)[:400])
    for rng in ["D4", "D17", "D43", "D66", "G17", "G43", "G66", "F17", "E17"]:
        vv = _lark("+cells-get", "--sheet-id", SHEET_ID, "--range", rng)
        cell = vv["data"]["ranges"][0]["cells"][0][0] or {}
        print(rng, cell.get("value"))
    print("done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
