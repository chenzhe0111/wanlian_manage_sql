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

每天 **09:30** 自动拉前一天数据：

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
| 整合表月实际 | `com.wanlian.sheet.actuals` | 09:30 | `refresh_sheet_actuals.py` |
| 新老货主 | `com.wanlian.sheet.newold` | 09:32 | `refresh_sheet_newold.py` |
| 注册司机 | `com.wanlian.sheet.driver` | 09:34 | `refresh_sheet_driver.py` |
| 周度最近两周 | `com.wanlian.sheet.weekly` | 09:36 | `refresh_sheet_weekly.py`（ApiId=`6148260aafa3` → sheet `66mgnV`） |
| 月度+周度漏斗 | `com.wanlian.sheet.funnel` | 09:38 | `refresh_sheet_funnel.py`（ApiId=`9cd9d778e4fd` → sheet `QbfdXI`） |

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
30 9 * * * /Users/chenzhe/Desktop/wanlian_manage_sql/scripts/quickbi_export/run.sh --pt yesterday >> /Users/chenzhe/Desktop/wanlian_manage_sql/scripts/quickbi_export/logs/cron.log 2>&1
```

## 常见问题

| 现象 | 处理 |
|---|---|
| API.No.Permission | RAM 未授权，或数据服务未对该 AK 开放 |
| Cube.Not.Exist / Datasource.Sql.ExecuteFailed | 数据集/底层表权限或 SQL 问题（同你在 BI 里跑自定义 SQL） |
| 超时 60s | 缩小 ReturnFields / 加 Conditions，或拆多个 API |
| 行级权限拦截 | 传 `QUICKBI_USER_ID` 指定有权限的用户 |

把 `.env` 留在本机，**不要提交 git**。
