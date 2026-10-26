#!/usr/bin/env python3
"""黄金问句意图回归。用法：python3 qa_intent_regress.py

退出码：0 全过；1 有失败。改 classify / 同义词后必跑。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

import qa_analyze as qa  # noqa: E402


def main() -> int:
    path = ROOT / "qa_intent_cases.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    cases = data.get("cases") or []
    failed: list[str] = []
    for i, c in enumerate(cases, 1):
        q = c["q"]
        expect = c["intent"]
        prev = c.get("prev")
        got = qa.classify_intent(q, prev_intent=prev)
        if got != expect:
            failed.append(
                f"#{i} q={q!r} prev={prev!r} expect={expect} got={got}"
                + (f" ({c['note']})" if c.get("note") else "")
            )
    total = len(cases)
    ok = total - len(failed)
    print(f"qa_intent_regress: {ok}/{total} passed")
    for line in failed:
        print("FAIL", line)
    # smoke：unknown 必须带候选
    unk = qa.answer_unknown("乱七八糟xyz")
    if "你是不是想问" not in unk:
        print("FAIL unknown clarification missing")
        return 1
    # smoke：冲突句
    if qa.classify_intent("本周电销新客转化漏斗") != "init_tel":
        print("FAIL conflict 电销漏斗")
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
