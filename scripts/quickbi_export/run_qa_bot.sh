#!/bin/bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
mkdir -p logs
export PATH="/Users/chenzhe/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
PY="/Users/chenzhe/bin/python3"
[[ -x "$PY" ]] || PY="python3"
echo "[$(date '+%F %T')] run_qa_bot starting" >> logs/qa_bot.out.log

# stdin 保活：tail | consume | handler
tail -f /dev/null | lark-cli event consume im.message.receive_v1 --as bot 2>>logs/qa_bot.err.log \
  | "$PY" -u "$ROOT/qa_bot.py" >>logs/qa_bot.out.log 2>&1
echo "[$(date '+%F %T')] run_qa_bot exited rc=$?" >> logs/qa_bot.out.log
