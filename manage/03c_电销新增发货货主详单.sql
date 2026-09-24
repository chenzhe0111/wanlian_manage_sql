/* 电销 · 新增发货货主详单 / 周核对（口径对齐 03c）
 *
 * 【为何「周数加总」会比详单行数高出近一倍】
 *   03c 周度 = 每个自然周 COUNT(DISTINCT company_id)
 *   本详单默认 = 整个统计期内企业去重（一行一企）
 *   同一企业若在多周都有「新增发货」，周指标会周周各记 1，加总会重复；
 *   首月内连续发货的新客，加总≈详单×2 很常见。
 *
 * 正确核对方式：
 *   1) 对某一周：用本脚本「周×企业」明细 COUNT → 应等于 03c 该周 电销/新货主/发货货主数
 *   2) 对整段期间：用「期间去重」行数 → 应等于各周企业集合的并集，不是周数之和
 *
 * 发货 / 电销 / 新老：同 03c ship_fact + company_initiative
 * 改 tim0 与 03c 保持一致
 */
WITH tim0 AS (
    SELECT
        DATE '2026-07-01' AS range_start,
        DATE '2026-09-01' AS as_of_dt
),
tim AS (
    SELECT
        range_start,
        as_of_dt,
        DATE_SUB(range_start, INTERVAL 1 MONTH) AS data_start
    FROM tim0
),
/* 输出周：同 03c（周三起始） */
week_meta AS (
    SELECT DISTINCT
        ws.week_start,
        LEAST(DATE_ADD(ws.week_start, INTERVAL 6 DAY), t.as_of_dt) AS week_end
    FROM tim t
    CROSS JOIN (
        SELECT
            DATE_SUB(
                DATE_ADD(t2.data_start, INTERVAL s.n DAY),
                INTERVAL ((WEEKDAY(DATE_ADD(t2.data_start, INTERVAL s.n DAY)) - 2 + 7) % 7) DAY
            ) AS week_start
        FROM tim t2
        CROSS JOIN (
            SELECT 0 AS n UNION ALL SELECT 7 UNION ALL SELECT 14 UNION ALL SELECT 21
            UNION ALL SELECT 28 UNION ALL SELECT 35 UNION ALL SELECT 42 UNION ALL SELECT 49
            UNION ALL SELECT 56 UNION ALL SELECT 63 UNION ALL SELECT 70 UNION ALL SELECT 77
            UNION ALL SELECT 84 UNION ALL SELECT 91 UNION ALL SELECT 98 UNION ALL SELECT 105
        ) s
        WHERE DATE_ADD(t2.data_start, INTERVAL s.n DAY) <= t2.as_of_dt
    ) ws
    WHERE ws.week_start <= t.as_of_dt
      AND LEAST(DATE_ADD(ws.week_start, INTERVAL 6 DAY), t.as_of_dt) >= t.range_start
),
comp AS (
    SELECT
        SUBSTR(create_date, 1, 10) AS register_dt,
        CASE
            WHEN original_company_type IN (5, 7, 8)
             AND license_aptitude_status = 3
                THEN SUBSTR(license_aptitude_time, 1, 10)
            WHEN original_company_type IN (1, 2, 3, 4)
             AND license_aptitude_status = 3
             AND authorize_audit_status = 30
                THEN SUBSTR(
                    IF(license_aptitude_time > authorize_audit_time,
                       license_aptitude_time,
                       authorize_audit_time),
                    1, 10
                )
        END AS audit_dt,
        company_id,
        company_name
    FROM dwd_vlsp_mt_em_company_manage_info_minf
    WHERE company_id IS NOT NULL
      AND is_fake_company_apply_user = '0'
),
tms_waybill AS (
    SELECT waybill_create_time, shipper_company_id, waybill_id
    FROM dwd_vlsp_mt_match_waybill_tms_business_process_minf
    WHERE COALESCE(shipper_company_id, '') NOT IN (
        '065d39e9afac48d8a0bdc5896c18d96c',
        '1993982792389951488',
        '1993985265305452544',
        '1994003031330062336'
    )
      AND tms_flag = 10
    GROUP BY 1, 2, 3
),
goods AS (
    SELECT create_dt, publish_company_id, goods_id
    FROM dwd_vlsp_mt_em_goods_manage_info_minf
    WHERE goods_status <> 10
      AND COALESCE(publish_company_id, '') NOT IN (
        '065d39e9afac48d8a0bdc5896c18d96c',
        '1993982792389951488',
        '1993985265305452544',
        '1994003031330062336'
    )
      AND goods_id NOT IN ('CHQY20251204000000016246', 'CHQY20251211000000012094')
    GROUP BY 1, 2, 3
),
base AS (
    SELECT DATE(waybill_create_time) AS create_dt, shipper_company_id AS company_id
    FROM tms_waybill
    UNION
    SELECT create_dt, publish_company_id AS company_id
    FROM goods
),
company_first AS (
    SELECT company_id, create_dt AS first_dt
    FROM (
        SELECT
            company_id,
            create_dt,
            ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY create_dt) AS rn
        FROM base
    ) t
    WHERE rn = 1
),
company_dx AS (
    SELECT DISTINCT company_name AS company_name_dx
    FROM match_shipper_telesales_leads_info
),
company_pool AS (
    SELECT company_id, company_name FROM comp
    UNION
    SELECT DISTINCT
        process_shipper_company_id AS company_id,
        process_shipper_company_name AS company_name
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf
    WHERE process_shipper_company_id IS NOT NULL
),
/* 与 03c 完全一致：只保留电销 */
company_dx_id AS (
    SELECT DISTINCT cp.company_id
    FROM company_pool cp
    INNER JOIN company_dx dx ON dx.company_name_dx = cp.company_name
),
/* 同 03c ship_fact，仅电销 × 新货主 */
ship_fact_dx_new AS (
    SELECT
        b.company_id,
        DATE(b.create_dt) AS event_dt,
        cf.first_dt
    FROM base b
    INNER JOIN company_dx_id dx ON dx.company_id = b.company_id
    INNER JOIN company_first cf ON cf.company_id = b.company_id
    CROSS JOIN tim t
    WHERE b.create_dt >= t.data_start
      AND b.create_dt <= t.as_of_dt
      AND cf.first_dt >= DATE_FORMAT(DATE(b.create_dt), '%Y-%m-01')
),
/* ---------- A. 周核对汇总：应与 03c 周度 电销/新货主/发货货主数 逐周相等 ---------- */
week_check AS (
    SELECT
        w.week_start AS 周起始,
        w.week_end AS 周结束,
        COUNT(DISTINCT f.company_id) AS 电销新增发货货主数
    FROM week_meta w
    INNER JOIN ship_fact_dx_new f
        ON f.event_dt >= w.week_start
       AND f.event_dt <= w.week_end
    WHERE w.week_start >= (SELECT range_start FROM tim0)  /* 只看输出期周，不含纯对照周 */
    GROUP BY w.week_start, w.week_end
),
/* ---------- B. 周×企业明细（按周去重；多周出现的企业会有多行） ---------- */
week_detail AS (
    SELECT
        w.week_start AS 周起始,
        f.company_id AS 企业ID,
        MAX(c.company_name) AS 企业名称,
        MIN(f.first_dt) AS 首活日,
        MIN(f.event_dt) AS 本周首次新增发货日,
        MAX(f.event_dt) AS 本周末次新增发货日,
        COUNT(DISTINCT f.event_dt) AS 本周新增发货天数
    FROM week_meta w
    INNER JOIN ship_fact_dx_new f
        ON f.event_dt >= w.week_start
       AND f.event_dt <= w.week_end
    LEFT JOIN comp c ON c.company_id = f.company_id
    WHERE w.week_start >= (SELECT range_start FROM tim0)
    GROUP BY w.week_start, f.company_id
),
/* ---------- C. 期间去重详单（一行一企；不能与周数加总直接比） ---------- */
period_detail AS (
    SELECT
        f.company_id AS 企业ID,
        MAX(c.company_name) AS 企业名称,
        MIN(f.first_dt) AS 首活日,
        MIN(f.event_dt) AS 期间首次新增发货日,
        MAX(f.event_dt) AS 期间末次新增发货日,
        COUNT(DISTINCT f.event_dt) AS 新增发货天数,
        COUNT(DISTINCT DATE_SUB(
            f.event_dt,
            INTERVAL ((WEEKDAY(f.event_dt) - 2 + 7) % 7) DAY
        )) AS 有发货周数,
        MAX(c.register_dt) AS 注册日,
        MAX(c.audit_dt) AS 认证日
    FROM ship_fact_dx_new f
    CROSS JOIN tim0 t
    LEFT JOIN comp c ON c.company_id = f.company_id
    WHERE f.event_dt >= t.range_start
      AND f.event_dt <= t.as_of_dt
    GROUP BY f.company_id
)

/* ===== 切换输出：三选一，注释掉另外两个 ===== */

/* ① 周核对汇总（先跑这个对数） */
SELECT * FROM week_check
ORDER BY 周起始
;

/* ② 周×企业明细（展开看谁被周周重复计）
SELECT * FROM week_detail
ORDER BY 周起始, 企业ID
;
*/

/* ③ 期间去重详单（业务名单；行数 ≠ 周指标之和）
SELECT * FROM period_detail
ORDER BY 期间首次新增发货日, 企业ID
;
*/
