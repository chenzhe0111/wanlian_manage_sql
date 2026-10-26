#!/usr/bin/env python3
"""测量目标管理报表页加载耗时（需本机浏览器 + 登录态）。

目标页：https://bi.10000da.cn/targetManagementCoreIframe
会先跳 SSO（sso-admin.10000da.cn）。未登录时请先跑一次 --save-login。

用法：
  # 1) 首次：弹出浏览器，手动登录，登录成功后回车保存 Cookie
  .venv/bin/python measure_report_load.py --save-login

  # 2) 之后：用已存登录态测加载（可多轮取平均）
  .venv/bin/python measure_report_load.py
  .venv/bin/python measure_report_load.py --rounds 3

  # 默认已等 Quick BI iframe 内图表/指标出齐；也可自定义文案
  .venv/bin/python measure_report_load.py --ready-text "运单量"
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STATE_FILE = ROOT / "logs" / "bi_report_storage_state.json"
DEFAULT_URL = "https://bi.10000da.cn/targetManagementCoreIframe"

# Quick BI 仪表盘在 iframe（bi.aliyun.com）内；用文案+体量+短暂稳定判定「图表已出」
_DASH_SNAP_JS = """() => {
  const body = document.body ? (document.body.innerText || "") : "";
  const svgs = document.querySelectorAll("svg");
  let paths = 0;
  svgs.forEach((s) => { paths += s.querySelectorAll("path").length; });
  const spinning = document.querySelectorAll(".ant-spin-spinning").length;
  return {
    textLen: body.length,
    svg: svgs.length,
    paths,
    spinning,
    hasOverview: body.includes("整体概览"),
    hasOrders: body.includes("运单量"),
    hasTarget: body.includes("目标达成度"),
  };
}"""


def _need_playwright():
    try:
        from playwright.sync_api import sync_playwright  # noqa: F401
    except ImportError:
        print(
            "缺少 playwright。请执行：\n"
            "  .venv/bin/pip install playwright\n"
            "本机 Chrome 即可（macOS 12 无法安装 Playwright 自带 Chromium）。",
            file=sys.stderr,
        )
        raise SystemExit(2)


def _launch_chromium(p, *, headless: bool):
    """Prefer system Chrome: Playwright bundled Chromium needs macOS 14+."""
    return p.chromium.launch(channel="chrome", headless=headless)


def _find_dashboard_frame(page):
    for f in page.frames:
        u = f.url or ""
        if "pageId=" in u and "dashboard" in u:
            return f
    return None


def _wait_charts_ready(page, t0: float, timeout_ms: int) -> tuple[float | None, dict]:
    """等 iframe 内指标/图表出齐并短暂稳定。返回 (charts_ready_ms, snap)."""
    from playwright.sync_api import TimeoutError as PwTimeout

    deadline = t0 + timeout_ms / 1000
    page.wait_for_selector("iframe[src*='dashboard']", timeout=timeout_ms)
    iframe_ms = (time.perf_counter() - t0) * 1000

    dash = None
    while time.perf_counter() < deadline:
        dash = _find_dashboard_frame(page)
        if dash is not None:
            break
        page.wait_for_timeout(200)
    if dash is None:
        return None, {"iframe_ms": iframe_ms, "error": "dashboard_frame_missing"}

    last_sig = None
    stable_since = None
    min_text = 600  # 首屏卡片出齐后正文大约 800+；600 过滤半成品
    stable_need_s = 1.2

    while time.perf_counter() < deadline:
        try:
            snap = dash.evaluate(_DASH_SNAP_JS)
        except Exception:
            page.wait_for_timeout(300)
            continue

        content_ok = (
            snap.get("hasOverview")
            and snap.get("hasOrders")
            and snap.get("hasTarget")
            and snap.get("textLen", 0) >= min_text
            and snap.get("spinning", 0) == 0
        )
        sig = (snap.get("textLen"), snap.get("svg"), snap.get("paths"))
        now = time.perf_counter()
        if content_ok:
            if sig == last_sig:
                if stable_since is None:
                    stable_since = now
                elif now - stable_since >= stable_need_s:
                    snap["iframe_ms"] = round(iframe_ms, 1)
                    snap["stable_for_ms"] = round((now - stable_since) * 1000, 1)
                    return (now - t0) * 1000, snap
            else:
                last_sig = sig
                stable_since = now
        else:
            last_sig = None
            stable_since = None
        page.wait_for_timeout(400)

    # 超时：带回最后一次快照
    try:
        snap = dash.evaluate(_DASH_SNAP_JS)
    except Exception:
        snap = {}
    snap["iframe_ms"] = round(iframe_ms, 1)
    snap["error"] = "charts_ready_timeout"
    return None, snap


def save_login(url: str, headed: bool) -> None:
    from playwright.sync_api import sync_playwright

    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = _launch_chromium(p, headless=not headed)
        context = browser.new_context()
        page = context.new_page()
        page.goto(url, wait_until="domcontentloaded", timeout=120_000)
        print("已打开浏览器。请完成 SSO 登录，直到进入目标管理报表页。")
        print("登录完成后回到终端按回车保存登录态…")
        input()
        context.storage_state(path=str(STATE_FILE))
        browser.close()
    print(f"已保存登录态 → {STATE_FILE}")


def measure_once(
    url: str,
    *,
    headed: bool,
    ready_text: str | None,
    ready_selector: str | None,
    timeout_ms: int,
    wait_charts: bool,
) -> dict:
    from playwright.sync_api import sync_playwright, TimeoutError as PwTimeout

    if not STATE_FILE.exists():
        raise SystemExit(f"未找到登录态 {STATE_FILE}，请先运行 --save-login")

    marks: dict[str, float] = {}
    t0 = time.perf_counter()

    with sync_playwright() as p:
        browser = _launch_chromium(p, headless=not headed)
        context = browser.new_context(
            storage_state=str(STATE_FILE),
            viewport={"width": 1440, "height": 900},
        )
        page = context.new_page()

        api_timings: list[tuple[str, float]] = []
        req_start: dict[str, float] = {}

        def on_request(req):
            try:
                u = req.url
                if any(k in u for k in ("/api/", "quickbi", "query", "dashboard", "data")):
                    req_start[req.url] = time.perf_counter()
            except Exception:
                pass

        def on_response(resp):
            try:
                u = resp.url
                if u in req_start:
                    api_timings.append((u[:140], (time.perf_counter() - req_start.pop(u)) * 1000))
            except Exception:
                pass

        page.on("request", on_request)
        page.on("response", on_response)

        nav = page.goto(url, wait_until="domcontentloaded", timeout=timeout_ms)
        marks["domcontentloaded_ms"] = (time.perf_counter() - t0) * 1000
        marks["http_status"] = nav.status if nav else None

        if "sso-admin" in page.url or "login" in page.url.lower():
            browser.close()
            raise SystemExit("登录态失效，仍跳到 SSO。请重新执行 --save-login")

        try:
            page.wait_for_load_state("networkidle", timeout=min(timeout_ms, 30_000))
            marks["networkidle_ms"] = (time.perf_counter() - t0) * 1000
        except PwTimeout:
            marks["networkidle_ms"] = None
            marks["networkidle_timeout"] = True

        ready_ms = None
        try:
            if ready_selector:
                page.wait_for_selector(ready_selector, timeout=timeout_ms)
                ready_ms = (time.perf_counter() - t0) * 1000
            elif ready_text:
                page.get_by_text(ready_text, exact=False).first.wait_for(timeout=timeout_ms)
                ready_ms = (time.perf_counter() - t0) * 1000
        except PwTimeout:
            marks["ready_timeout"] = True
        marks["ready_ms"] = ready_ms

        charts_ready_ms = None
        if wait_charts:
            remain = max(5_000, timeout_ms - int((time.perf_counter() - t0) * 1000))
            charts_ready_ms, snap = _wait_charts_ready(page, t0, remain)
            marks["charts_ready_ms"] = charts_ready_ms
            marks["charts_snap"] = snap
            if charts_ready_ms is None:
                marks["charts_ready_timeout"] = True

        marks["final_url"] = page.url
        marks["title"] = page.title()
        marks["total_ms"] = (time.perf_counter() - t0) * 1000

        api_timings.sort(key=lambda x: x[1], reverse=True)
        marks["slow_apis_top3"] = [
            {"url": u, "ms": round(ms, 1)} for u, ms in api_timings[:3]
        ]

        browser.close()

    return marks


def _sec(ms) -> str | None:
    if ms is None:
        return None
    return f"{ms / 1000:.1f}s"


def main() -> int:
    _need_playwright()
    ap = argparse.ArgumentParser(description="测量 bi.10000da.cn 目标管理页加载耗时")
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--save-login", action="store_true", help="手动登录并保存 Cookie")
    ap.add_argument("--headed", action="store_true", help="有头模式（默认可视；CI 可关）")
    ap.add_argument("--headless", action="store_true", help="无头模式")
    ap.add_argument("--rounds", type=int, default=1)
    ap.add_argument("--ready-text", default=None, help="出现该文案视为报表可看（外层页）")
    ap.add_argument("--ready-selector", default=None, help="CSS 选择器出现视为报表可看")
    ap.add_argument(
        "--no-wait-charts",
        action="store_true",
        help="不等待 iframe 内图表出齐（仅 DOM/networkidle）",
    )
    ap.add_argument("--timeout-ms", type=int, default=120_000)
    args = ap.parse_args()

    headed = True
    if args.headless:
        headed = False
    elif args.headed:
        headed = True

    if args.save_login:
        save_login(args.url, headed=True)
        return 0

    results = []
    for i in range(args.rounds):
        print(f"\n=== round {i + 1}/{args.rounds} ===")
        r = measure_once(
            args.url,
            headed=headed,
            ready_text=args.ready_text,
            ready_selector=args.ready_selector,
            timeout_ms=args.timeout_ms,
            wait_charts=not args.no_wait_charts,
        )
        results.append(r)
        print(json.dumps(r, ensure_ascii=False, indent=2))
        if r.get("charts_ready_ms") is not None:
            print(f"→ 图表出齐约 {_sec(r['charts_ready_ms'])}")
        elif r.get("charts_ready_timeout"):
            print("→ 图表出齐：超时未判定成功")

    out = {
        "url": args.url,
        "measured_at": datetime.now().isoformat(timespec="seconds"),
        "rounds": results,
    }
    if len(results) > 1:
        for key in (
            "domcontentloaded_ms",
            "networkidle_ms",
            "ready_ms",
            "charts_ready_ms",
            "total_ms",
        ):
            vals = [x[key] for x in results if x.get(key) is not None]
            if vals:
                out[f"avg_{key}"] = round(statistics.mean(vals), 1)
                out[f"p50_{key}"] = round(statistics.median(vals), 1)

    log = ROOT / "logs" / f"report_load_{datetime.now():%Y%m%d_%H%M%S}.json"
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n写入 {log}")
    if "avg_charts_ready_ms" in out:
        print(f"平均图表出齐 {out['avg_charts_ready_ms']:.0f} ms ({_sec(out['avg_charts_ready_ms'])})")
    elif "avg_total_ms" in out:
        print(f"平均总耗时 {out['avg_total_ms']:.0f} ms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
