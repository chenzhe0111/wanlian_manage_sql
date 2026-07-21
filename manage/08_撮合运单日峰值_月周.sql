/* 撮合运单日峰值 | 每月最高日 + 每周最高日（周三起始周）
 * 口径：仅撮合（排除网货、TMS）；有效运单过滤与管理专项一致
 */
WITH waybill_base AS (
    SELECT
        DATE(SUBSTR(waybill.accept_dt, 1, 10)) AS accept_day,
        waybill.waybill_id
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    WHERE SUBSTR(waybill.accept_dt, 1, 10) >= DATE '2026-01-01'
      AND SUBSTR(waybill.accept_dt, 1, 10) <= CURRENT_DATE()
      AND waybill.waybill_status NOT IN (540, 100)
      AND NVL(waybill.shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          1993982792389951488,
          1993985265305452544,
          1994003031330062336
      )
      AND (waybill.tms_flag = 20
           OR (waybill.tms_flag = 10 AND waybill.driver_operate_accept_time IS NOT NULL))
      /* 仅撮合 */
      AND NOT (waybill.invoice_type = 20)
      AND NOT (waybill.invoice_type = 10 AND waybill.tms_flag = 10)
),
daily AS (
    SELECT
        accept_day,
        DATE_FORMAT(accept_day, '%Y-%m-01') AS mon,
        DATE_SUB(accept_day, INTERVAL ((WEEKDAY(accept_day) - 2 + 7) % 7) DAY) AS week_start,
        COUNT(DISTINCT waybill_id) AS day_cnt
    FROM waybill_base
    GROUP BY accept_day
),
/* 每月：该月内日运单量最高的一天 */
month_peak AS (
    SELECT
        '月日峰值' AS peak_type,
        mon AS period_start,
        accept_day AS peak_day,
        day_cnt AS peak_cnt
    FROM (
        SELECT
            mon,
            accept_day,
            day_cnt,
            ROW_NUMBER() OVER (PARTITION BY mon ORDER BY day_cnt DESC, accept_day) AS rn
        FROM daily
    ) t
    WHERE rn = 1
),
/* 每周：该周内日运单量最高的一天 */
week_peak AS (
    SELECT
        '周日峰值' AS peak_type,
        week_start AS period_start,
        accept_day AS peak_day,
        day_cnt AS peak_cnt
    FROM (
        SELECT
            week_start,
            accept_day,
            day_cnt,
            ROW_NUMBER() OVER (PARTITION BY week_start ORDER BY day_cnt DESC, accept_day) AS rn
        FROM daily
    ) t
    WHERE rn = 1
)
SELECT
    peak_type AS 峰值类型,
    period_start AS 周期起始日,
    peak_day AS 峰值日期,
    peak_cnt AS 日峰值运单量
FROM (
    SELECT * FROM month_peak
    UNION ALL
    SELECT * FROM week_peak
) t
ORDER BY
    CASE peak_type WHEN '月日峰值' THEN 1 WHEN '周日峰值' THEN 2 END,
    period_start;
