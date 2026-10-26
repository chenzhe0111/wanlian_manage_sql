#!/usr/bin/env python3
"""飞书群规则问答消费端：读 lark-cli event consume 的 NDJSON，回群。

启动：./run_qa_bot.sh
仅处理白名单群（默认 FEISHU_DIGEST_CHAT_ID）；忽略机器人自己的消息。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parent
os.chdir(ROOT)
sys.path.insert(0, str(ROOT))

# 复用 digest 的 .env 加载
import daily_target_digest as dig  # noqa: E402
import qa_analyze  # noqa: E402

SEEN: deque[str] = deque(maxlen=200)
# 每群上一轮意图，供短跟进（「按周度看一下」等）承接
LAST_INTENT: dict[str, str] = {}
LOG = ROOT / "logs" / "qa_bot.handler.log"


def _log(msg: str) -> None:
    LOG.parent.mkdir(parents=True, exist_ok=True)
    line = f"[{time.strftime('%F %T')}] {msg}"
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def _allowed_chats() -> set[str]:
    raw = os.environ.get("FEISHU_QA_CHAT_IDS") or os.environ.get("FEISHU_DIGEST_CHAT_ID") or ""
    return {x.strip() for x in raw.split(",") if x.strip()}


def _reply(message_id: str, markdown: str) -> None:
    cmd = [
        "lark-cli",
        "im",
        "+messages-reply",
        "--as",
        "bot",
        "--message-id",
        message_id,
        "--markdown",
        markdown,
        "--format",
        "json",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    raw = (proc.stdout or "") + (proc.stderr or "")
    i = raw.find("{")
    if proc.returncode != 0 or i < 0:
        raise RuntimeError(raw[-1500:] or f"reply failed rc={proc.returncode}")
    data = json.loads(raw[i:])
    if not data.get("ok", True):
        raise RuntimeError(json.dumps(data.get("error") or data, ensure_ascii=False)[:1500])


def handle_event(ev: dict) -> None:
    if ev.get("sender_type") == "bot":
        return
    mid = ev.get("message_id") or ev.get("id") or ""
    if not mid or mid in SEEN:
        return
    SEEN.append(mid)

    chat_id = ev.get("chat_id") or ""
    allowed = _allowed_chats()
    if allowed and chat_id not in allowed:
        return

    content = (ev.get("content") or "").strip()
    if not content:
        return

    prev = LAST_INTENT.get(chat_id)
    intent = qa_analyze.classify_intent(content, prev_intent=prev)
    mentions = ev.get("mentions") or []
    # 群聊：无 @ 且完全 unknown 时不抢话；有候选澄清仍回复（需 @ 或已是私聊）
    if ev.get("chat_type") == "group" and not mentions and intent == "unknown":
        return

    _log(
        f"handle chat={chat_id} intent={intent} prev={prev or '-'} "
        f"mid={mid} text={content[:80]!r}"
    )
    try:
        ans = qa_analyze.answer(content, intent=intent, prev_intent=prev)
        _reply(mid, ans)
        if intent not in ("unknown", "empty"):
            LAST_INTENT[chat_id] = intent
        _log(f"replied mid={mid} intent={intent}")
    except Exception as e:  # noqa: BLE001
        _log(f"error mid={mid}: {e}")
        try:
            _reply(mid, f"分析失败：{e}"[:500])
        except Exception as e2:  # noqa: BLE001
            _log(f"reply-error failed: {e2}")


def main() -> int:
    allowed = _allowed_chats()
    _log(f"qa_bot start allowed_chats={allowed or '{ALL}'}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            _log(f"bad json: {line[:120]!r}")
            continue
        # consume 可能包一层
        if "event" in ev and isinstance(ev["event"], dict) and "message_id" not in ev:
            ev = ev["event"]
        handle_event(ev)
    _log("qa_bot stdin closed, exit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
