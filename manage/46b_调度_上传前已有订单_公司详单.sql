/* 调度：上传前已有订单 · 公司详单 | 8月至今
 * 口径同 46_调度_上传前已有订单_周度.sql：
 *   - 上传日 = 名单最早 create_time
 *   - 公司名匹配运单；履约剔异常
 *   - 「上传前」= unload_day < first_upload_dt
 *   - 最远产生订单时间 = 上传前最早一单的 unload_time（时间点）
 *
 * 用途：写分析报告用公司粒度明细；默认可先筛 是否上传前已有订单=1
 * 改日期：tim.range_start / as_of_dt
 */
WITH tim AS (
    SELECT
        DATE '2026-08-01' AS range_start,
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS as_of_dt
),
ab_raw AS (
    SELECT
        ab.waybill_id,
        CASE
            WHEN scenario_tags LIKE '%账号登录异常-剔除%'
              OR scenario_tags LIKE '%同时段履约多单-剔除%'
              OR scenario_tags LIKE '%装卸货打卡异常-剔除%'
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
            WHEN appl_status IN (300, 410, 310, 420, 100, 500) THEN '申诉中'
            WHEN appl_status IN (400, 430) THEN '申诉成功'
            WHEN appl_status IN (200, 320, 440) THEN '申诉失败'
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
dd_company AS (
    SELECT
        TRIM(company_name) AS company_name,
        MIN(DATE(create_time)) AS first_upload_dt,
        MIN(create_time) AS first_upload_ts,
        COUNT(*) AS leads_row_cnt
    FROM match_shipper_dispatching_leads_info
    CROSS JOIN tim t
    WHERE company_name IS NOT NULL
      AND TRIM(company_name) <> ''
      AND create_time IS NOT NULL
      AND DATE(create_time) <= t.as_of_dt
    GROUP BY TRIM(company_name)
),
dd_aug AS (
    SELECT
        d.company_name,
        d.first_upload_dt,
        d.first_upload_ts,
        d.leads_row_cnt,
        DATE_SUB(
            d.first_upload_dt,
            INTERVAL ((WEEKDAY(d.first_upload_dt) - 2 + 7) % 7) DAY
        ) AS upload_week_start
    FROM dd_company d
    CROSS JOIN tim t
    WHERE d.first_upload_dt >= t.range_start
      AND d.first_upload_dt <= t.as_of_dt
),
company_wxx AS (
    SELECT customer_company_id, MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd.dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
),
waybill_dd AS (
    SELECT
        waybill.waybill_id,
        waybill.unload_time AS unload_ts,
        DATE(waybill.unload_time) AS unload_day,
        waybill.process_shipper_company_id AS company_id,
        waybill.process_shipper_company_name AS company_name,
        d.first_upload_dt,
        CASE
            WHEN waybill.invoice_type = 20 THEN '网货'
            WHEN waybill.invoice_type = 10 AND waybill.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_type,
        CASE
            WHEN DATE(waybill.unload_time) < d.first_upload_dt THEN 1 ELSE 0
        END AS is_before_upload,
        CASE
            WHEN DATE(waybill.unload_time) >= d.first_upload_dt
             AND DATE(waybill.unload_time) <= t.as_of_dt
            THEN 1 ELSE 0
        END AS is_after_upload_to_asof
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    INNER JOIN dd_aug d
        ON d.company_name = waybill.process_shipper_company_name
    CROSS JOIN tim t
    LEFT JOIN company_wxx
        ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    LEFT JOIN abnormal_waybill aw
        ON aw.waybill_id = waybill.waybill_id
    WHERE waybill.load_time IS NOT NULL
      AND waybill.unload_time IS NOT NULL
      AND DATE(waybill.unload_time) <= t.as_of_dt
      AND aw.waybill_id IS NULL
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
)
SELECT
    d.upload_week_start AS 上传周起始日,
    d.first_upload_dt AS 首次上传日,
    d.first_upload_ts AS 首次上传时间,
    d.company_name AS 公司名称,
    MAX(w.company_id) AS 公司ID样例,
    d.leads_row_cnt AS 名单行数,
    CASE WHEN MAX(CASE WHEN w.is_before_upload = 1 THEN 1 ELSE 0 END) = 1 THEN 1 ELSE 0 END
        AS 是否上传前已有订单,
    /* —— 上传前 —— */
    COUNT(DISTINCT CASE WHEN w.is_before_upload = 1 THEN w.waybill_id END) AS 上传前运单数,
    ROUND(COUNT(DISTINCT CASE WHEN w.is_before_upload = 1 THEN w.waybill_id END) / 10000.0, 3)
        AS 上传前运单_万单,
    /* 最远=上传前最早一单的履约时间点 */
    MIN(CASE WHEN w.is_before_upload = 1 THEN w.unload_ts END) AS 最远产生订单时间,
    MIN(CASE WHEN w.is_before_upload = 1 THEN w.unload_day END) AS 上传前首单履约日,
    MAX(CASE WHEN w.is_before_upload = 1 THEN w.unload_day END) AS 上传前末单履约日,
    DATEDIFF(
        d.first_upload_dt,
        MIN(CASE WHEN w.is_before_upload = 1 THEN w.unload_day END)
    ) AS 首单距上传天数,
    COUNT(DISTINCT CASE WHEN w.is_before_upload = 1 AND w.waybill_type = '撮合' THEN w.waybill_id END)
        AS 上传前_撮合,
    COUNT(DISTINCT CASE WHEN w.is_before_upload = 1 AND w.waybill_type = 'TMS' THEN w.waybill_id END)
        AS 上传前_TMS,
    COUNT(DISTINCT CASE WHEN w.is_before_upload = 1 AND w.waybill_type = '网货' THEN w.waybill_id END)
        AS 上传前_网货,
    /* —— 上传后至截止 —— */
    COUNT(DISTINCT CASE WHEN w.is_after_upload_to_asof = 1 THEN w.waybill_id END) AS 上传后至截止运单数,
    ROUND(COUNT(DISTINCT CASE WHEN w.is_after_upload_to_asof = 1 THEN w.waybill_id END) / 10000.0, 3)
        AS 上传后至截止运单_万单,
    MIN(CASE WHEN w.is_after_upload_to_asof = 1 THEN w.unload_day END) AS 上传后首单履约日,
    MAX(CASE WHEN w.is_after_upload_to_asof = 1 THEN w.unload_day END) AS 上传后末单履约日,
    COUNT(DISTINCT CASE WHEN w.is_after_upload_to_asof = 1 AND w.waybill_type = '撮合' THEN w.waybill_id END)
        AS 上传后_撮合,
    COUNT(DISTINCT CASE WHEN w.is_after_upload_to_asof = 1 AND w.waybill_type = 'TMS' THEN w.waybill_id END)
        AS 上传后_TMS,
    COUNT(DISTINCT CASE WHEN w.is_after_upload_to_asof = 1 AND w.waybill_type = '网货' THEN w.waybill_id END)
        AS 上传后_网货
FROM dd_aug d
LEFT JOIN waybill_dd w
    ON w.company_name = d.company_name
GROUP BY
    d.upload_week_start,
    d.first_upload_dt,
    d.first_upload_ts,
    d.company_name,
    d.leads_row_cnt
ORDER BY
    是否上传前已有订单 DESC,
    上传前运单数 DESC,
    上传周起始日,
    公司名称
;
