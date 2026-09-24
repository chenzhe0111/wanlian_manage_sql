/* 整体单货主成交运单量
 * 口径：成交运单量 / 成交货主数
 *   成交运单 = accept_dt 落在统计期、有效运单（同月度汇总过滤）
 *   成交货主 = 期内有成交运单的 DISTINCT shipper_company_id
 * 输出：月度 + 周度（周三对齐周，与业务周报一致）
 */
WITH tim AS (
    SELECT
        DATE '2026-01-01' AS range_start,
        DATE '2026-08-11' AS range_end   /* 右闭 */
),
waybill_base AS (
    SELECT
        DATE(w.accept_dt) AS event_dt,
        w.shipper_company_id AS company_id,
        w.waybill_id
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf w
    LEFT JOIN (
        SELECT customer_company_id, MAX(sales_lv1_company_id) AS sales_lv1_company_id
        FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
        WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
          AND customer_company_id IS NOT NULL
        GROUP BY customer_company_id
    ) company_wxx
        ON company_wxx.customer_company_id = w.process_shipper_company_id
    CROSS JOIN tim t
    WHERE DATE(w.accept_dt) >= t.range_start
      AND DATE(w.accept_dt) <= t.range_end
      AND (
          company_wxx.sales_lv1_company_id IS NOT NULL
          OR NVL(w.shipper_company_name, '') NOT IN (
              SELECT DISTINCT dept_name
              FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
      AND w.waybill_status NOT IN (540, 100)
      AND NVL(w.shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          1993982792389951488,
          1993985265305452544,
          1994003031330062336
      )
      AND (w.tms_flag = 20 OR (w.tms_flag = 10 AND w.driver_operate_accept_time IS NOT NULL))
),
/* 月度 */
month_agg AS (
    SELECT
        '月' AS 时间粒度,
        DATE_FORMAT(event_dt, '%Y-%m-01') AS 周期起始,
        COUNT(DISTINCT waybill_id) AS 成交运单量,
        COUNT(DISTINCT company_id) AS 成交货主数
    FROM waybill_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
),
/* 周度：周三为一周起点（与业务周报一致） */
week_agg AS (
    SELECT
        '周' AS 时间粒度,
        DATE(DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY)) AS 周期起始,
        COUNT(DISTINCT waybill_id) AS 成交运单量,
        COUNT(DISTINCT company_id) AS 成交货主数
    FROM waybill_base
    GROUP BY DATE(DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY))
)
SELECT
    时间粒度,
    周期起始,
    成交运单量,
    成交货主数,
    ROUND(成交运单量 * 1.0 / NULLIF(成交货主数, 0), 1) AS 单货主成交运单量
FROM (
    SELECT * FROM month_agg
    UNION ALL
    SELECT * FROM week_agg
) u
ORDER BY
    CASE 时间粒度 WHEN '月' THEN 1 WHEN '周' THEN 2 END,
    周期起始;
