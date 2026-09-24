#!/bin/bash
# 一键试跑 / cron 入口
set -euo pipefail
cd "$(dirname "$0")"
if [[ -d .venv ]]; then
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi
exec python3 export_dataset.py "$@"
