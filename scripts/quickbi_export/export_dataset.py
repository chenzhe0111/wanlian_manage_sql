#!/usr/bin/env python3
"""从 Quick BI「数据服务」定时拉数，落本地 CSV。

前置：
1. 专业版 Quick BI，对目标数据集创建「数据服务」API，拿到 ApiId
2. RAM 账号具备 quickbi-public:QueryData
3. 复制 .env.example → .env 并填密钥

用法：
  python3 export_dataset.py
  python3 export_dataset.py --api-id xxx --out ~/Desktop/data
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent
load_dotenv(ROOT / ".env")

# Quick BI 默认 read_timeout=10s，早高峰易超时；可用环境变量覆盖
_READ_TIMEOUT_MS = int(os.environ.get("QUICKBI_READ_TIMEOUT_MS", "120000"))
_CONNECT_TIMEOUT_MS = int(os.environ.get("QUICKBI_CONNECT_TIMEOUT_MS", "20000"))
_MAX_ATTEMPTS = int(os.environ.get("QUICKBI_MAX_ATTEMPTS", "5"))
_RETRY_BASE_SEC = float(os.environ.get("QUICKBI_RETRY_BASE_SEC", "5"))


def _parse_json_opt(raw: str | None):
    if not raw or not str(raw).strip():
        return None
    return json.loads(raw)


def _normalize_rows(values) -> list[dict]:
    """兼容 Values 为 list[dict] 或嵌套 list 的返回。"""
    if values is None:
        return []
    if not isinstance(values, list):
        raise TypeError(f"unexpected Values type: {type(values)}")
    if not values:
        return []
    # [[{...},{...}]] → flatten one level when outer is single wrapper
    if len(values) == 1 and isinstance(values[0], list):
        values = values[0]
    rows = []
    for item in values:
        if isinstance(item, dict):
            rows.append(item)
        elif isinstance(item, list):
            for sub in item:
                if isinstance(sub, dict):
                    rows.append(sub)
                else:
                    raise TypeError(f"row element not dict: {type(sub)}")
        else:
            raise TypeError(f"row not dict/list: {type(item)}")
    return rows


def _is_retryable(exc: BaseException) -> bool:
    msg = str(exc).lower()
    needles = (
        "timed out",
        "timeout",
        "temporarily unavailable",
        "connection reset",
        "connection aborted",
        "remote disconnected",
        "max retries exceeded",
        "503",
        "502",
        "504",
    )
    return any(n in msg for n in needles)


def query_data(
    api_id: str,
    user_id: str | None = None,
    conditions: str | None = None,
    return_fields: str | None = None,
) -> dict:
    from alibabacloud_quickbi_public20220101.client import Client
    from alibabacloud_quickbi_public20220101 import models as qb_models
    from alibabacloud_tea_openapi import models as open_models

    ak = os.environ.get("ALIBABA_CLOUD_ACCESS_KEY_ID") or os.environ.get("ACCESS_KEY_ID")
    sk = os.environ.get("ALIBABA_CLOUD_ACCESS_KEY_SECRET") or os.environ.get("ACCESS_KEY_SECRET")
    if not ak or not sk:
        raise SystemExit("缺少 ALIBABA_CLOUD_ACCESS_KEY_ID / ALIBABA_CLOUD_ACCESS_KEY_SECRET")

    config = open_models.Config(
        access_key_id=ak,
        access_key_secret=sk,
        endpoint="quickbi-public.cn-hangzhou.aliyuncs.com",
        read_timeout=_READ_TIMEOUT_MS,
        connect_timeout=_CONNECT_TIMEOUT_MS,
    )
    client = Client(config)

    req = qb_models.QueryDataRequest(
        api_id=api_id,
        user_id=user_id or None,
        conditions=conditions or None,
        return_fields=return_fields or None,
    )

    last_exc: BaseException | None = None
    for attempt in range(1, _MAX_ATTEMPTS + 1):
        try:
            resp = client.query_data(req)
            body = resp.body
            if body is None:
                raise RuntimeError("empty response body")
            if not getattr(body, "success", True):
                raise RuntimeError(f"QueryData failed: {body}")
            # Tea model → dict
            if hasattr(body, "to_map"):
                return body.to_map()
            return {
                "Success": body.success,
                "RequestId": body.request_id,
                "Result": body.result.to_map()
                if body.result and hasattr(body.result, "to_map")
                else body.result,
            }
        except Exception as exc:  # noqa: BLE001 — 网络/SDK 异常统一重试判断
            last_exc = exc
            if attempt >= _MAX_ATTEMPTS or not _is_retryable(exc):
                raise
            wait = _RETRY_BASE_SEC * (2 ** (attempt - 1))
            print(
                f"[retry {attempt}/{_MAX_ATTEMPTS}] QueryData failed: {exc}; sleep {wait:.0f}s",
                file=sys.stderr,
            )
            time.sleep(wait)
    assert last_exc is not None
    raise last_exc


def write_csv(rows: list[dict], headers: list[str] | None, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if headers:
        fieldnames = headers
    elif rows:
        # stable column order: union of keys, first-seen order
        fieldnames = []
        seen = set()
        for r in rows:
            for k in r.keys():
                if k not in seen:
                    seen.add(k)
                    fieldnames.append(k)
    else:
        fieldnames = []

    with out_path.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k) for k in fieldnames})


def _yesterday_pt() -> str:
    from datetime import timedelta

    return (datetime.now().date() - timedelta(days=1)).strftime("%Y-%m-%d")


def _filter_pt(rows: list[dict], pt: str) -> list[dict]:
    """只保留 pt=目标日；无 pt 列则原样返回。"""
    if not rows or "pt" not in rows[0]:
        return rows
    return [r for r in rows if str(r.get("pt", "")).strip()[:10] == pt]


def main() -> int:
    p = argparse.ArgumentParser(description="Export Quick BI Data Service API result to local CSV")
    p.add_argument("--api-id", default=os.environ.get("QUICKBI_API_ID"), help="数据服务 ApiId")
    p.add_argument("--user-id", default=os.environ.get("QUICKBI_USER_ID") or None)
    p.add_argument("--conditions", default=os.environ.get("QUICKBI_CONDITIONS") or None)
    p.add_argument("--return-fields", default=os.environ.get("QUICKBI_RETURN_FIELDS") or None)
    p.add_argument(
        "--pt",
        default=os.environ.get("QUICKBI_PT") or "yesterday",
        help="分区日：yesterday / YYYY-MM-DD / all（默认 yesterday=前一天）",
    )
    p.add_argument(
        "--out",
        default=os.environ.get("QUICKBI_OUT_DIR") or str(ROOT / "out"),
        help="输出目录",
    )
    p.add_argument(
        "--prefix",
        default=os.environ.get("QUICKBI_FILE_PREFIX") or "quickbi_dataset",
        help="文件名前缀",
    )
    p.add_argument("--dry-run", action="store_true", help="只打印行数不写文件")
    args = p.parse_args()

    if not args.api_id:
        print("请设置 --api-id 或环境变量 QUICKBI_API_ID", file=sys.stderr)
        return 2

    target_pt = None
    if args.pt and str(args.pt).lower() not in ("all", "*", ""):
        target_pt = _yesterday_pt() if str(args.pt).lower() == "yesterday" else str(args.pt)

    conditions = args.conditions
    if not conditions and target_pt:
        conditions = json.dumps({"pt": target_pt}, ensure_ascii=False)

    # validate optional JSON early
    if conditions:
        _parse_json_opt(conditions)
    if args.return_fields:
        _parse_json_opt(args.return_fields)

    print(f"[{datetime.now():%F %T}] QueryData api_id={args.api_id} pt={target_pt or 'all'}")
    payload = query_data(
        api_id=args.api_id,
        user_id=args.user_id,
        conditions=conditions,
        return_fields=args.return_fields,
    )
    result = payload.get("Result") or payload.get("result") or {}
    if isinstance(result, dict):
        values = result.get("Values") or result.get("values") or []
        hdrs = result.get("Headers") or result.get("headers") or []
    else:
        values, hdrs = [], []

    rows = _normalize_rows(values)
    raw_n = len(rows)
    if target_pt:
        rows = _filter_pt(rows, target_pt)
    header_labels = []
    for h in hdrs:
        if isinstance(h, dict):
            lab = h.get("Label") or h.get("label")
            if lab:
                header_labels.append(lab)

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = Path(args.out).expanduser() / f"{args.prefix}_{ts}.csv"
    latest = Path(args.out).expanduser() / f"{args.prefix}_latest.csv"

    print(
        f"rows={len(rows)}"
        + (f" (raw={raw_n})" if target_pt and raw_n != len(rows) else "")
        + f" request_id={payload.get('RequestId') or payload.get('request_id')}"
    )
    if args.dry_run:
        if rows:
            print("sample keys:", list(rows[0].keys()))
        return 0

    write_csv(rows, header_labels or None, out_path)
    write_csv(rows, header_labels or None, latest)
    print(f"wrote {out_path}")
    print(f"wrote {latest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
