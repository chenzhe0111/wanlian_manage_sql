-- 来源: 飞书知识库

WITH company_zm AS (
    SELECT DISTINCT invitee_id
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
    SELECT customer_company_id, MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
),
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        DATE_SUB(
            DATE(waybill.accept_dt),
            INTERVAL ((WEEKDAY(waybill.accept_dt) - 2 + 7) % 7) DAY
        ) AS week_start,
        CASE
            WHEN waybill.invoice_type = 20 THEN '网货'
            WHEN waybill.invoice_type = 10 AND waybill.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_category,
        CASE WHEN company_wxx.sales_lv1_company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_offline,
        CASE WHEN company_zm.invitee_id IS NOT NULL THEN 1 ELSE 0 END AS hit_zm,
        CASE WHEN company_tl.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_tl,
        CASE WHEN company_dx.company_name_dx IS NOT NULL THEN 1 ELSE 0 END AS hit_dx,
        CASE WHEN company_dd.company_name_dd IS NOT NULL THEN 1 ELSE 0 END AS hit_dd,
        CASE
            WHEN company_wxx.sales_lv1_company_id IS NULL
             AND company_zm.invitee_id IS NULL AND company_tl.company_id IS NULL
             AND company_dx.company_name_dx IS NULL AND company_dd.company_name_dd IS NULL
            THEN 1 ELSE 0
        END AS hit_wxx
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    WHERE SUBSTR(waybill.accept_dt, 1, 10) >= DATE '2026-06-01'
      AND SUBSTR(waybill.accept_dt, 1, 10) <= CURRENT_DATE()
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
waybill_split AS (
    SELECT
        waybill_id,
        week_start,
        waybill_category,
        hit_offline,
        hit_zm, hit_tl, hit_dx, hit_dd, hit_wxx,
        CASE WHEN hit_zm  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN hit_tl  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN hit_dx  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN hit_dd  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dd,
        CASE WHEN hit_wxx = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_wxx
    FROM waybill_hit
),
agg AS (
    SELECT
        week_start,
        waybill_category,
        COUNT(DISTINCT waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN hit_offline = 1 THEN waybill_id END) AS offline_cnt,
        COUNT(DISTINCT CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN waybill_id END) AS online_cnt,
        SUM(w_zm)  AS zm_cnt,
        SUM(w_tl)  AS tl_cnt,
        SUM(w_dx)  AS dx_cnt,
        SUM(w_dd)  AS dd_cnt,
        SUM(w_wxx) AS wxx_cnt
    FROM waybill_split
    GROUP BY week_start, waybill_category
),
agg_all AS (
    SELECT
        week_start,
        SUM(total_cnt)   AS total_cnt,
        SUM(offline_cnt) AS offline_cnt,
        SUM(online_cnt)  AS online_cnt,
        SUM(zm_cnt)      AS zm_cnt,
        SUM(tl_cnt)      AS tl_cnt,
        SUM(dx_cnt)      AS dx_cnt,
        SUM(dd_cnt)      AS dd_cnt,
        SUM(wxx_cnt)     AS wxx_cnt
    FROM agg
    GROUP BY week_start
),
result AS (
    /* 整体 */
    SELECT week_start, '整体' AS stat_level, '整体' AS stat_dim, total_cnt AS waybill_cnt FROM agg_all
    UNION ALL
    /* 整体-线上 / 整体-线下 */
    SELECT week_start, '整体', '线上', online_cnt FROM agg_all
    UNION ALL
    SELECT week_start, '整体', '线下', offline_cnt FROM agg_all
    UNION ALL
    /* 线上-运单类型 */
    SELECT week_start, '线上', waybill_category, online_cnt FROM agg
    UNION ALL
    /* ★ 新增：线上-举措 */
    SELECT week_start, '线上举措', '货主招募', zm_cnt FROM agg_all
    UNION ALL
    SELECT week_start, '线上举措', '投流', tl_cnt FROM agg_all
    UNION ALL
    SELECT week_start, '线上举措', '电销', dx_cnt FROM agg_all
    UNION ALL
    SELECT week_start, '线上举措', '调度', dd_cnt FROM agg_all
    UNION ALL
    SELECT week_start, '线上举措', '无线下销售归属', wxx_cnt FROM agg_all
    /* 线上举措 × 运单类型 */
    UNION ALL
    SELECT week_start, '线上举措', CONCAT('货主招募-', waybill_category), zm_cnt FROM agg
    UNION ALL
    SELECT week_start, '线上举措', CONCAT('投流-', waybill_category), tl_cnt FROM agg
    UNION ALL
    SELECT week_start, '线上举措', CONCAT('电销-', waybill_category), dx_cnt FROM agg
    UNION ALL
    SELECT week_start, '线上举措', CONCAT('调度-', waybill_category), dd_cnt FROM agg
    UNION ALL
    SELECT week_start, '线上举措', CONCAT('无线下销售归属-', waybill_category), wxx_cnt FROM agg
)
SELECT
    week_start AS 周起始日,
    stat_level AS 统计层级,
    stat_dim   AS 维度,
    CONCAT(stat_level, '-', stat_dim) AS 层级维度,
    waybill_cnt / 10000 AS 运单量
FROM result
ORDER BY
    week_start,
    CASE stat_level
        WHEN '整体'   THEN 1
        WHEN '线上'   THEN 2
        WHEN '线上举措' THEN 3
        ELSE 99
    END,
    CASE
        WHEN stat_dim = '整体' THEN 0
        WHEN stat_dim = '线上' THEN 1
        WHEN stat_dim = '线下' THEN 2
        WHEN stat_dim = '货主招募' THEN 10
        WHEN stat_dim = '投流' THEN 11
        WHEN stat_dim = '电销' THEN 12
        WHEN stat_dim = '调度' THEN 13
        WHEN stat_dim = '无线下销售归属' THEN 14
        WHEN stat_dim = '网货' THEN 20
        WHEN stat_dim = 'TMS' THEN 21
        WHEN stat_dim = '撮合' THEN 22
        WHEN stat_dim LIKE '货主招募-%' THEN 30
        WHEN stat_dim LIKE '投流-%' THEN 31
        WHEN stat_dim LIKE '电销-%' THEN 32
        WHEN stat_dim LIKE '调度-%' THEN 33
        WHEN stat_dim LIKE '无线下销售归属-%' THEN 34
        ELSE 99
    END,
    stat_dim;
