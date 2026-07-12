-- 线上发货货主数 | 一次查询输出月度+周度（UNION ALL 合并，2026-01-01 起）

WITH company_zm AS (
    SELECT DISTINCT invitee_id AS company_id
    FROM dwd_vlsp_mt_user_recruitment_business_process_minf zm
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t1
        ON zm.invitee_company_user_id = t1.psn_acct_user_base_id
    WHERE activity_title = '货主招募活动'
      AND invitee_id IS NOT NULL AND invitee_id <> ''
),
company_tl_channel AS (
    SELECT DISTINCT company.company_id
    FROM dwd_vlsp_mt_em_user_manage_info_minf user
    INNER JOIN ads.ads_vlsp_tms_advertise_placement_channel_info_df channel
        ON channel.telephone = user.telephone
    INNER JOIN dwd_vlsp_mt_em_company_manage_info_minf company
        ON company.company_apply_user_base_id = user.user_base_id
    WHERE user.user_status = 11 AND user.deleted = 21 AND user.account_type = 10
      AND company.company_id IS NOT NULL
),
company_tl AS (
    SELECT company_id
    FROM (
        SELECT user.company_id
        FROM dwd.dwd_vlsp_mt_bt_advertise_placement_business_process_minf advertise
        LEFT JOIN (
            SELECT user_base_id, company_id
            FROM dwd.dwd_vlsp_mt_em_user_manage_info_minf
            WHERE user_status = 11 AND deleted = 21
            GROUP BY 1, 2
        ) user ON user.user_base_id = advertise.user_id
        WHERE advertise.user_id <> '' AND advertise.consign_callback_status = 10
          AND user.company_id IS NOT NULL
        UNION
        SELECT company_id FROM company_tl_channel
    ) t
    GROUP BY company_id
),
company_dx AS (
    SELECT DISTINCT shipper_company_name AS company_name_dx
    FROM ads.ads_vlsp_tms_shipper_and_dispatch_info_df
    WHERE shipper_source = '电销'
),
company_dd AS (
    SELECT DISTINCT shipper_company_name AS company_name_dd
    FROM ads.ads_vlsp_tms_shipper_and_dispatch_info_df
    WHERE shipper_source = '调度'
),
company_wxx AS (
    SELECT customer_company_id AS company_id,
           MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
),
tms_waybill AS (
    SELECT
        SUBSTR(waybill_create_time, 1, 10) AS ship_dt,
        shipper_company_id AS company_id
    FROM dwd_vlsp_mt_match_waybill_tms_business_process_minf
    WHERE NVL(shipper_company_id, '') NOT IN (
              '065d39e9afac48d8a0bdc5896c18d96c', '1993982792389951488',
              '1993985265305452544', '1994003031330062336'
          )
      AND tms_flag = 10
    GROUP BY 1, 2
),
goods AS (
    SELECT
        SUBSTR(create_dt, 1, 10) AS ship_dt,
        publish_company_id AS company_id
    FROM dwd_vlsp_mt_em_goods_manage_info_minf
    WHERE goods_status <> 10
      AND NVL(publish_company_id, '') NOT IN (
              '065d39e9afac48d8a0bdc5896c18d96c', '1993982792389951488',
              '1993985265305452544', '1994003031330062336'
          )
      AND goods_id NOT IN ('CHQY20251204000000016246', 'CHQY20251211000000012094')
    GROUP BY 1, 2
),
ship_event AS (
    SELECT ship_dt, company_id FROM tms_waybill
    UNION
    SELECT ship_dt, company_id FROM goods
),
company_info AS (
    SELECT company_id, company_name
    FROM dwd_vlsp_mt_em_company_manage_info_minf
    WHERE company_id IS NOT NULL
    GROUP BY 1, 2
),
ship_hit AS (
    SELECT
        DATE(s.ship_dt) AS event_dt,
        s.company_id,
        CASE WHEN company_zm.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_zm,
        CASE WHEN company_tl.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_tl,
        CASE WHEN company_dx.company_name_dx IS NOT NULL THEN 1 ELSE 0 END AS hit_dx,
        CASE WHEN company_dd.company_name_dd IS NOT NULL THEN 1 ELSE 0 END AS hit_dd,
        CASE
            WHEN company_wxx.sales_lv1_company_id IS NULL
             AND company_zm.company_id IS NULL
             AND company_tl.company_id IS NULL
             AND company_dx.company_name_dx IS NULL
             AND company_dd.company_name_dd IS NULL
            THEN 1 ELSE 0
        END AS hit_wxx
    FROM ship_event s
    INNER JOIN company_info ci ON ci.company_id = s.company_id
    LEFT JOIN company_zm  ON company_zm.company_id = s.company_id
    LEFT JOIN company_tl  ON company_tl.company_id = s.company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = ci.company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = ci.company_name
    LEFT JOIN company_wxx ON company_wxx.company_id = s.company_id
    WHERE s.ship_dt >= DATE '2026-01-01'
      AND s.ship_dt <= CURRENT_DATE()
      AND (
          company_wxx.sales_lv1_company_id IS NOT NULL
          OR NVL(ci.company_name, '') NOT IN (
              SELECT DISTINCT dept_name FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
),
ship_online AS (
    SELECT event_dt, company_id
    FROM ship_hit
    WHERE hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0
),
metric_all AS (
    SELECT
        '月' AS stat_granularity,
        DATE_FORMAT(event_dt, '%Y-%m-01') AS period_start,
        COUNT(DISTINCT company_id) AS metric_value
    FROM ship_online
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
    UNION ALL
    SELECT
        '周',
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        COUNT(DISTINCT company_id)
    FROM ship_online
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY)
)
SELECT
    CONCAT(
        CASE stat_granularity WHEN '月' THEN '月度' WHEN '周' THEN '周度' END,
        '-', period_start, '-线上发货货主数'
    ) AS 主键,
    CASE stat_granularity WHEN '月' THEN '月度' WHEN '周' THEN '周度' END AS 月周标识,
    period_start AS 周期起始日,
    metric_value AS 线上发货货主数
FROM metric_all
ORDER BY
    period_start,
    CASE stat_granularity WHEN '月' THEN 1 WHEN '周' THEN 2 END;
