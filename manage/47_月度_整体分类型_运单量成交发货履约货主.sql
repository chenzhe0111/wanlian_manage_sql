/* 月度 | 全部 + 运单类型（网货/TMS/撮合）
 * 指标：运单量、成交货主数、发货货主数、履约货主数
 *
 * 口径（对齐 01c / 03c）：
 *   1) 运单量 / 履约货主：unload_time 落月；load/unload 均非空；剔「异常剔除+申诉中」
 *   2) 成交货主：accept_dt 落月（接单成交）；同有效运单过滤；不要求已卸货
 *   3) 发货货主：load_time 落月（装货）；与成交/履约同表，便于分类型
 *      ※ 漏斗「货源∪TMS建单」发货口径见文末备注（仅适合「全部」、难分类型）
 *   4) 类型：invoice_type=20→网货；invoice_type=10且tms_flag=10→TMS；其余→撮合
 *   5) 货主键：shipper_company_id；月内去重（类型行相加 ≠ 全部，一货主可跨类型）
 *
 * 改期：tim.range_start / as_of_dt
 */
WITH tim AS (
    SELECT
        DATE '2026-01-01' AS range_start,
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS as_of_dt   /* 右闭；可改 DATE '2026-09-14' */
),
/* ===== 异常运单判定（同 01c） ===== */
ab_raw AS (
    SELECT
        ab.waybill_id,
        CASE
            WHEN scenario_tags LIKE '%账号登录异常-剔除%'
              OR scenario_tags LIKE '%同时段履约多单-剔除%'
              OR scenario_tags LIKE '%装卸货打卡异常-剔除%'
              OR scenario_tags LIKE '%司机近30天行程异常-剔除%'
              OR scenario_tags LIKE '%司机月度行程异常-剔除%'
            THEN '剔除'
            ELSE '下发'
        END AS 类别
    FROM ads.ads_vlsp_mt_match_waybill_abnormal_detail_info_df ab
    WHERE (
        scenario_tags LIKE '%运费异常%'
        OR scenario_tags LIKE '%秒装秒卸%'
        OR scenario_tags LIKE '%时速异常高%'
        OR scenario_tags LIKE '%装卸货打卡异常-申诉%'
        OR scenario_tags LIKE '%装卸货打卡异常-剔除%'
        OR scenario_tags LIKE '%司机近30天行程异常%'
        OR scenario_tags LIKE '%司机月度行程异常%'
        OR scenario_tags LIKE '%账号登录异常%'
        OR scenario_tags LIKE '%同时段履约多单-剔除%'
        OR scenario_tags LIKE '%运单间隔过短%'
    )
),
ab AS (
    SELECT
        waybill_id,
        CASE WHEN MAX(CASE WHEN 类别 = '剔除' THEN 1 ELSE 0 END) = 1 THEN '剔除' ELSE '下发' END AS 类别
    FROM ab_raw
    GROUP BY waybill_id
),
ss_raw AS (
    SELECT DISTINCT waybill_id, '申诉成功' AS 是否申诉成功
    FROM match_way_abnormal_appeal_approved_info
    WHERE waybill_id NOT IN (SELECT DISTINCT waybill_id FROM match_way_abnormal_appeal_failed_info)
    UNION ALL
    SELECT DISTINCT waybill_id, '申诉失败' AS 是否申诉成功
    FROM match_way_abnormal_appeal_failed_info
    UNION ALL
    SELECT DISTINCT
        waybill_id,
        CASE
            WHEN appl_status IN (100, 300, 310, 410, 500) THEN '申诉中'
            WHEN appl_status IN (400) THEN '申诉成功'
            WHEN appl_status IN (110, 200, 320, 440) THEN '申诉失败'
            ELSE CAST(appl_status AS STRING)
        END AS 是否申诉成功
    FROM ads.ads_vlsp_mt_match_waybill_high_abnormal_detail_info_minf
),
ss AS (
    SELECT
        waybill_id,
        CASE
            WHEN MAX(CASE WHEN 是否申诉成功 = '申诉成功' THEN 1 ELSE 0 END) = 1 THEN '申诉成功'
            WHEN MAX(CASE WHEN 是否申诉成功 = '申诉中' THEN 1 ELSE 0 END) = 1 THEN '申诉中'
            WHEN MAX(CASE WHEN 是否申诉成功 = '申诉失败' THEN 1 ELSE 0 END) = 1 THEN '申诉失败'
            ELSE NULL
        END AS 是否申诉成功
    FROM ss_raw
    GROUP BY waybill_id
),
type_ab AS (
    SELECT
        ab.waybill_id,
        CASE
            WHEN ab.类别 = '剔除'
              OR (ab.类别 = '下发' AND ss.是否申诉成功 = '申诉失败')
            THEN '异常剔除'
            WHEN ab.类别 = '下发' AND (ss.waybill_id IS NULL OR ss.是否申诉成功 = '申诉中')
            THEN '申诉中'
            WHEN ab.类别 = '下发' AND ss.是否申诉成功 = '申诉成功'
            THEN '申诉成功'
            ELSE NULL
        END AS 异常类别
    FROM ab
    LEFT JOIN ss ON ab.waybill_id = ss.waybill_id
),
abnormal_waybill AS (
    SELECT DISTINCT waybill_id
    FROM type_ab
    WHERE 异常类别 IN ('异常剔除', '申诉中')
),
company_wxx AS (
    SELECT customer_company_id, MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
),
month_spine AS (
    SELECT
        DATE_FORMAT(DATE_ADD(t.range_start, INTERVAL n.n MONTH), '%Y-%m-01') AS mon
    FROM tim t
    JOIN (
        SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
        UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
        UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11
    ) n
        ON DATE_ADD(t.range_start, INTERVAL n.n MONTH)
           <= DATE_FORMAT(t.as_of_dt, '%Y-%m-01')
),
out_dim AS (
    SELECT m.mon, d.waybill_type
    FROM month_spine m
    CROSS JOIN (
        SELECT '全部' AS waybill_type
        UNION ALL SELECT '网货'
        UNION ALL SELECT 'TMS'
        UNION ALL SELECT '撮合'
    ) d
),
waybill_base AS (
    SELECT
        w.waybill_id,
        w.shipper_company_id AS company_id,
        DATE(w.accept_dt) AS accept_day,
        DATE(w.load_time) AS load_day,
        DATE(w.unload_time) AS unload_day,
        CASE
            WHEN w.invoice_type = 20 THEN '网货'
            WHEN w.invoice_type = 10 AND w.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_type,
        CASE WHEN abn.waybill_id IS NULL THEN 0 ELSE 1 END AS is_abnormal
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf w
    CROSS JOIN tim t
    LEFT JOIN company_wxx
        ON company_wxx.customer_company_id = w.process_shipper_company_id
    LEFT JOIN abnormal_waybill abn
        ON abn.waybill_id = w.waybill_id
    WHERE (
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
      AND (
            (w.accept_dt IS NOT NULL AND DATE(w.accept_dt) BETWEEN t.range_start AND t.as_of_dt)
         OR (w.load_time IS NOT NULL AND DATE(w.load_time) BETWEEN t.range_start AND t.as_of_dt)
         OR (w.unload_time IS NOT NULL AND DATE(w.unload_time) BETWEEN t.range_start AND t.as_of_dt)
      )
),
/* 履约：运单量 + 履约货主 */
fulfill_agg AS (
    SELECT
        DATE_FORMAT(unload_day, '%Y-%m-01') AS mon,
        waybill_type,
        COUNT(DISTINCT waybill_id) AS waybill_cnt,
        COUNT(DISTINCT company_id) AS fulfill_shipper_cnt
    FROM waybill_base
    CROSS JOIN tim t
    WHERE unload_day IS NOT NULL
      AND load_day IS NOT NULL
      AND unload_day BETWEEN t.range_start AND t.as_of_dt
      AND is_abnormal = 0
    GROUP BY DATE_FORMAT(unload_day, '%Y-%m-01'), waybill_type

    UNION ALL

    SELECT
        DATE_FORMAT(unload_day, '%Y-%m-01') AS mon,
        '全部' AS waybill_type,
        COUNT(DISTINCT waybill_id) AS waybill_cnt,
        COUNT(DISTINCT company_id) AS fulfill_shipper_cnt
    FROM waybill_base
    CROSS JOIN tim t
    WHERE unload_day IS NOT NULL
      AND load_day IS NOT NULL
      AND unload_day BETWEEN t.range_start AND t.as_of_dt
      AND is_abnormal = 0
    GROUP BY DATE_FORMAT(unload_day, '%Y-%m-01')
),
/* 成交货主：接单日 */
deal_agg AS (
    SELECT
        DATE_FORMAT(accept_day, '%Y-%m-01') AS mon,
        waybill_type,
        COUNT(DISTINCT company_id) AS deal_shipper_cnt
    FROM waybill_base
    CROSS JOIN tim t
    WHERE accept_day IS NOT NULL
      AND accept_day BETWEEN t.range_start AND t.as_of_dt
    GROUP BY DATE_FORMAT(accept_day, '%Y-%m-01'), waybill_type

    UNION ALL

    SELECT
        DATE_FORMAT(accept_day, '%Y-%m-01') AS mon,
        '全部' AS waybill_type,
        COUNT(DISTINCT company_id) AS deal_shipper_cnt
    FROM waybill_base
    CROSS JOIN tim t
    WHERE accept_day IS NOT NULL
      AND accept_day BETWEEN t.range_start AND t.as_of_dt
    GROUP BY DATE_FORMAT(accept_day, '%Y-%m-01')
),
/* 发货货主：装货日 */
ship_agg AS (
    SELECT
        DATE_FORMAT(load_day, '%Y-%m-01') AS mon,
        waybill_type,
        COUNT(DISTINCT company_id) AS ship_shipper_cnt
    FROM waybill_base
    CROSS JOIN tim t
    WHERE load_day IS NOT NULL
      AND load_day BETWEEN t.range_start AND t.as_of_dt
    GROUP BY DATE_FORMAT(load_day, '%Y-%m-01'), waybill_type

    UNION ALL

    SELECT
        DATE_FORMAT(load_day, '%Y-%m-01') AS mon,
        '全部' AS waybill_type,
        COUNT(DISTINCT company_id) AS ship_shipper_cnt
    FROM waybill_base
    CROSS JOIN tim t
    WHERE load_day IS NOT NULL
      AND load_day BETWEEN t.range_start AND t.as_of_dt
    GROUP BY DATE_FORMAT(load_day, '%Y-%m-01')
)
SELECT
    d.mon AS 月份,
    d.waybill_type AS 运单类型,
    COALESCE(f.waybill_cnt, 0) AS 运单量,
    ROUND(COALESCE(f.waybill_cnt, 0) / 10000.0, 4) AS 运单量_万,
    COALESCE(deal.deal_shipper_cnt, 0) AS 成交货主数,
    COALESCE(s.ship_shipper_cnt, 0) AS 发货货主数,
    COALESCE(f.fulfill_shipper_cnt, 0) AS 履约货主数,
    ROUND(
        COALESCE(f.waybill_cnt, 0) * 1.0 / NULLIF(f.fulfill_shipper_cnt, 0),
        1
    ) AS 单货主履约运单数
FROM out_dim d
LEFT JOIN fulfill_agg f
    ON f.mon = d.mon AND f.waybill_type = d.waybill_type
LEFT JOIN deal_agg deal
    ON deal.mon = d.mon AND deal.waybill_type = d.waybill_type
LEFT JOIN ship_agg s
    ON s.mon = d.mon AND s.waybill_type = d.waybill_type
ORDER BY
    d.mon,
    CASE d.waybill_type
        WHEN '全部' THEN 0
        WHEN '网货' THEN 1
        WHEN 'TMS' THEN 2
        WHEN '撮合' THEN 3
        ELSE 9
    END;

/*
 * 备注｜漏斗「发货」= 货源发布 ∪ TMS建单（仅「全部」，难拆网货/撮合）：
 * 用 dwd_vlsp_mt_em_goods_manage_info_minf(create_dt) ∪
 *     dwd_vlsp_mt_match_waybill_tms_business_process_minf(waybill_create_time, tms_flag=10)
 * 替换本 SQL 的 ship_agg（装货日口径）。
 */
