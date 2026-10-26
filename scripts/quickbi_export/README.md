# Quick BI 数据集 → 本地定时导出

## 前提

1. Quick BI **专业版**，对目标数据集建好 **数据服务 API**，复制 **ApiId**
2. 阿里云 RAM AccessKey，权限含 `quickbi-public:QueryData`
3. 本机 Python 3.9+

> 数据集本身不能直接下载；必须先挂「数据服务」，再用 `QueryData` 拉结果落 CSV。

## 一次性配置

```bash
cd scripts/quickbi_export
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# 编辑 .env：填 AK/SK、QUICKBI_API_ID
```

手动试跑：

```bash
./run.sh                  # 默认拉前一天（pt=yesterday）
./run.sh --pt all         # 不按 pt 过滤
./run.sh --pt 2026-09-19  # 指定分区日
python3 export_dataset.py --dry-run
```

成功后文件在：

- `out/<prefix>_YYYYMMDD_HHMMSS.csv`（带时间戳）
- `out/<prefix>_latest.csv`（每次覆盖，方便下游固定路径读取）

## 定时（macOS launchd，推荐）

每天 **10:00** 自动拉前一天数据：

```bash
cp com.wanlian.quickbi.export.plist ~/Library/LaunchAgents/
launchctl unload ~/Library/LaunchAgents/com.wanlian.quickbi.export.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.wanlian.quickbi.export.plist
launchctl start com.wanlian.quickbi.export   # 立刻试跑
```

日志：`logs/export.out.log` / `logs/export.err.log`

### 飞书回写（整合表 / 周度）

| 任务 | plist | 时间 | 脚本 |
|---|---|---|---|
| 整合表月实际 | `com.wanlian.sheet.actuals` | 10:00 | `refresh_sheet_actuals.py`（sheet `1074dd`，实际列 M–P，截止日 O1；线上 65/66/67） |
| 新老货主 | `com.wanlian.sheet.newold` | 10:02 | `refresh_sheet_newold.py`（同表第七部分，列 M–P，截止日 O1） |
| 注册司机 | `com.wanlian.sheet.driver` | 10:04 | `refresh_sheet_driver.py`（sheet `41UJIa`，实际列 J–M） |
| 周度最近两周 | `com.wanlian.sheet.weekly` | 10:06 | `refresh_sheet_weekly.py`（ApiId=`6148260aafa3` → sheet `66mgnV`） |
| 月度+周度漏斗 | `com.wanlian.sheet.funnel` | 10:08 | `refresh_sheet_funnel.py`（ApiId=`9cd9d778e4fd` → sheet `QbfdXI`） |
| 每日达成简报 | `com.wanlian.daily.digest` | 10:20 | `daily_target_digest.py`（读整合表 → 模板文案+四举措图 → 群/机器人推送；要求 O1=昨天） |

每日简报不依赖 AI：从整合表读当月实际/目标/时间进度，固定模板填数后机器人推送。优先发群 `FEISHU_DIGEST_CHAT_ID`，否则按 `FEISHU_DIGEST_OPEN_IDS` 私聊。

**新鲜度门槛**：推送前要求 O1「统计截止日」== 昨天（与 `refresh_sheet_actuals` 一致），且当月整体月运单实际格有数；未更新则 `SKIP` 退出（不发旧数）。紧急强推加 `--force`。

```bash
# 手动试跑（不发送）
./run_daily_digest.sh --dry-run
# 正式发送
./run_daily_digest.sh
# 忽略新鲜度强推
./run_daily_digest.sh --force

cp com.wanlian.daily.digest.plist ~/Library/LaunchAgents/
launchctl unload ~/Library/LaunchAgents/com.wanlian.daily.digest.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.wanlian.daily.digest.plist
launchctl start com.wanlian.daily.digest
```

日志：`logs/daily_digest.out.log` / `logs/daily_digest.err.log`；产物：`out/digest_latest.png`、`out/digest_latest.md`。

### 飞书群规则问答（常驻，不经过 AI）

群里问「为什么运单偏低 / 进度怎么样 / 帮助」，机器人用整合表规则归因后回复。默认只响应日简报群。

运行目录在 `~/Library/Application Support/wanlian_qa/`（避开 Desktop 的 TCC 权限）；源码仍在本目录，改完需同步：

```bash
# 本地试分析（不发飞书）
/Users/chenzhe/bin/python3 qa_analyze.py "为什么运单偏低"

# 同步并重启常驻
RUNTIME="$HOME/Library/Application Support/wanlian_qa"
cp daily_target_digest.py qa_analyze.py qa_bot.py run_qa_bot.sh "$RUNTIME/"
cp com.wanlian.qa.bot.plist ~/Library/LaunchAgents/
launchctl unload ~/Library/LaunchAgents/com.wanlian.qa.bot.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.wanlian.qa.bot.plist

# 日志
tail -f "$RUNTIME/logs/qa_bot.out.log" "$RUNTIME/logs/qa_bot.err.log"
```

前提：开放平台已订阅 `im.message.receive_v1`；在「线上目标达成日简报」群里 @机器人 再提问。

分析思路（已固化全表）：`QA_ANALYSIS_PLAYBOOK.md`；实现 `qa_analyze.py` + `qa_playbooks.py`；Cursor skill 见 `.cursor/skills/wanlian-online-data-analysis/SKILL.md` 章节 D–F。草稿已归档于 `QA_ANALYSIS_PLAYBOOK_DRAFT.md`。

```bash
cp com.wanlian.sheet.weekly.plist ~/Library/LaunchAgents/
launchctl unload ~/Library/LaunchAgents/com.wanlian.sheet.weekly.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.wanlian.sheet.weekly.plist
launchctl start com.wanlian.sheet.weekly

cp com.wanlian.sheet.funnel.plist ~/Library/LaunchAgents/
launchctl unload ~/Library/LaunchAgents/com.wanlian.sheet.funnel.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.wanlian.sheet.funnel.plist
launchctl start com.wanlian.sheet.funnel
```

周度口径：周三～周二；每天回写最近两周（含进行中周）。数据服务 `pt` 实际编译为 `周起始日 > pt`（不是分区等号），脚本用相邻 pt 差分还原单周；本地 CSV：`out/quickbi_weekly_*.csv`。

漏斗口径：本月（月初）+ 近两周（周三起始）；`pt` 编译为 `周期起始日 > pt`，同样差分还原；本地 CSV：`out/quickbi_funnel_*.csv`。

## 定时（cron 备选）

```cron
0 10 * * * /Users/chenzhe/Desktop/wanlian_manage_sql/scripts/quickbi_export/run.sh --pt yesterday >> /Users/chenzhe/Desktop/wanlian_manage_sql/scripts/quickbi_export/logs/cron.log 2>&1
```

## 常见问题

| 现象 | 处理 |
|---|---|
| API.No.Permission | RAM 未授权，或数据服务未对该 AK 开放 |
| Cube.Not.Exist / Datasource.Sql.ExecuteFailed | 数据集/底层表权限或 SQL 问题（同你在 BI 里跑自定义 SQL） |
| 超时 60s | 缩小 ReturnFields / 加 Conditions，或拆多个 API |
| 行级权限拦截 | 传 `QUICKBI_USER_ID` 指定有权限的用户 |

把 `.env` 留在本机，**不要提交 git**。
