#!/bin/bash
# launchd / 手动入口：与其它 sheet 定时任务一样走本目录，避免 Desktop TCC 拦错 Python
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
export PATH="/Users/chenzhe/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# 优先 venv（与 actuals 同解释器，launchd 更稳）；无 matplotlib 则回退本机 python3
PY="$ROOT/.venv/bin/python"
if ! "$PY" -c "import matplotlib" 2>/dev/null; then
  PY="/Users/chenzhe/bin/python3"
fi

exec "$PY" "$ROOT/daily_target_digest.py" "$@"
