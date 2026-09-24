/* 调度：上传前已有订单公司数 / 运单数 | 周度 | 8月至今
 * 问题：调度名单公司里，有多少在「上传(create_time)」之前就已经产生过履约订单？产生了多少单？
 *
 * 口径：
 *   1) 上传时间：match_shipper_dispatching_leads_info.create_time
 *      同一公司多条名单 → 取最早上传日 first_upload_dt
 *   2) 公司匹配：名单 company_name = 运单 process_shipper_company_name（同 01c 调度命中）
 *   3) 运单：履约剔异常（unload_time；load/unload 非空；剔 异常剔除+申诉中）
 *   4) 「上传前已有订单」：该公司存在 unload_day < first_upload_dt 的履约剔异常运单
 *   5) 周起始=周三；按「首次上传日」所在周汇总；默认 2026-08-01 ～ 昨天
 *
 * 输出：
 *   周起始日 / 当周新上传公司数 / 上传前已有订单公司数 / 占比
 *   上传前历史运单数 / 万单
 *   （附）这些「上传前已有单」公司在上传后～截止日的履约剔异常运单数
 */
WITH tim AS (
    SELECT
        DATE '2026-08-01' AS range_start,
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS as_of_dt   /* 右闭；可改 DATE '2026-09-10' */
),
/* ===== 异常运单判定（type_ab，同 01c） ===== */
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
/* ===== 调度名单：公司最早上传日 ===== */
dd_company AS (
    SELECT
        TRIM(company_name) AS company_name,
        MIN(DATE(create_time)) AS first_upload_dt,
        MIN(create_time) AS first_upload_ts
    FROM match_shipper_dispatching_leads_info
    CROSS JOIN tim t
    WHERE company_name IS NOT NULL
      AND TRIM(company_name) <> ''
      AND create_time IS NOT NULL
      AND DATE(create_time) <= t.as_of_dt
    GROUP BY TRIM(company_name)
),
/* 只看 8 月至今首次上传的公司（按周归因） */
dd_aug AS (
    SELECT
        d.company_name,
        d.first_upload_dt,
        d.first_upload_ts,
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
/* ===== 调度名单公司的履约剔异常运单（含上传前历史，故不截 8 月） ===== */
waybill_dd AS (
    SELECT
        waybill.waybill_id,
        DATE(waybill.unload_time) AS unload_day,
        waybill.process_shipper_company_name AS company_name,
        d.first_upload_dt,
        d.upload_week_start,
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
),
/* 公司级：是否上传前已有单 + 单量 */
company_flag AS (
    SELECT
        d.company_name,
        d.first_upload_dt,
        d.upload_week_start,
        MAX(CASE WHEN w.is_before_upload = 1 THEN 1 ELSE 0 END) AS has_before_upload,
        COUNT(DISTINCT CASE WHEN w.is_before_upload = 1 THEN w.waybill_id END) AS before_cnt,
        COUNT(DISTINCT CASE WHEN w.is_after_upload_to_asof = 1 THEN w.waybill_id END) AS after_cnt
    FROM dd_aug d
    LEFT JOIN waybill_dd w
        ON w.company_name = d.company_name
    GROUP BY d.company_name, d.first_upload_dt, d.upload_week_start
)
SELECT
    upload_week_start AS 周起始日,
    COUNT(*) AS 当周新上传公司数,
    SUM(has_before_upload) AS 上传前已有订单公司数,
    ROUND(SUM(has_before_upload) * 100.0 / NULLIF(COUNT(*), 0), 2) AS 上传前已有订单公司占比_pct,
    SUM(before_cnt) AS 上传前历史运单数,
    ROUND(SUM(before_cnt) / 10000.0, 3) AS 上传前历史运单_万单,
    SUM(CASE WHEN has_before_upload = 1 THEN after_cnt ELSE 0 END) AS 上传前已有单公司_上传后至截止运单数,
    ROUND(SUM(CASE WHEN has_before_upload = 1 THEN after_cnt ELSE 0 END) / 10000.0, 3)
        AS 上传前已有单公司_上传后至截止运单_万单
FROM company_flag
GROUP BY upload_week_start
ORDER BY upload_week_start
;
