/* 2026年7月：整体 + 运单类型（网货/TMS/撮合）
 * 指标：运单量、日均运单量（÷自然日31天）、峰值（日最大）及峰值日
 * 口径对齐月度汇总 / 天粒度汇总：accept_dt、有效运单过滤、类型按 invoice_type + tms_flag
 */
WITH waybill_base AS (
    SELECT
        waybill.waybill_id,
        CAST(waybill.accept_dt AS DATE) AS dt,
        CASE
            WHEN waybill.invoice_type = 20 THEN '网货'
            WHEN waybill.invoice_type = 10 AND waybill.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_type
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    LEFT JOIN (
        SELECT customer_company_id, MAX(sales_lv1_company_id) AS sales_lv1_company_id
        FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
        WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
          AND customer_company_id IS NOT NULL
        GROUP BY customer_company_id
    ) company_wxx
        ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    WHERE SUBSTR(waybill.accept_dt, 1, 10) BETWEEN DATE '2026-07-01' AND DATE '2026-07-31'
      AND (
          company_wxx.sales_lv1_company_id IS NOT NULL
          OR NVL(waybill.shipper_company_name, '') NOT IN (
              SELECT DISTINCT dept_name
              FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
      AND waybill.waybill_status NOT IN (540, 100)
      AND NVL(waybill.shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c', 1993982792389951488,
          1993985265305452544, 1994003031330062336
      )
      AND (waybill.tms_flag = 20 OR (waybill.tms_flag = 10 AND waybill.driver_operate_accept_time IS NOT NULL))
),
daily AS (
    /* 日 × 类型 */
    SELECT
        dt,
        waybill_type,
        COUNT(DISTINCT waybill_id) AS cnt
    FROM waybill_base
    GROUP BY dt, waybill_type

    UNION ALL

    /* 日 × 整体 */
    SELECT
        dt,
        '整体' AS waybill_type,
        COUNT(DISTINCT waybill_id) AS cnt
    FROM waybill_base
    GROUP BY dt
),
month_sum AS (
    SELECT
        waybill_type,
        SUM(cnt) AS waybill_cnt,
        MAX(cnt) AS peak_cnt
    FROM daily
    GROUP BY waybill_type
),
peak_day AS (
    /* 并列峰值取最早日期 */
    SELECT waybill_type, MIN(dt) AS peak_dt
    FROM daily d
    WHERE cnt = (
        SELECT MAX(d2.cnt)
        FROM daily d2
        WHERE d2.waybill_type = d.waybill_type
    )
    GROUP BY waybill_type
)
SELECT
    m.waybill_type AS 运单类型,
    m.waybill_cnt AS 运单量,
    ROUND(m.waybill_cnt * 1.0 / 31, 2) AS 日均运单量,
    m.peak_cnt AS 峰值运单量,
    p.peak_dt AS 峰值日
FROM month_sum m
LEFT JOIN peak_day p ON m.waybill_type = p.waybill_type
ORDER BY
    CASE m.waybill_type
        WHEN '整体' THEN 1
        WHEN '网货' THEN 2
        WHEN 'TMS' THEN 3
        WHEN '撮合' THEN 4
        ELSE 9
    END;
