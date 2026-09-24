/* 周度 × 举措：履约口径运单量 vs 履约剔异常运单量 + 剔除占比
 * 口径对齐 02c：
 *   1) 时间轴：unload_time（履约卸货日），且 load_time / unload_time 均非空
 *   2) 异常口径 type_ab：异常剔除 + 申诉中 算剔除；申诉成功 / 未命中场景不算
 *   3) 过滤：线下线索 OR 非微信主体；剔除测试公司；有效成交
 *   4) 五举措等权分摊（货主招募/投流/电销/调度/无线下销售归属）
 *   5) 周起始：周三
 * 剔除占比 = (履约 - 履约剔异常) / 履约
 */
WITH
/* ===== 异常运单判定（type_ab，同 01c / 02c / 31） ===== */
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
/* ===== 举措名单（同 02c） ===== */
company_zm AS (
    SELECT DISTINCT invitee_id
    FROM dwd.dwd_vlsp_mt_user_recruitment_business_process_minf zm
    LEFT JOIN dwd.dwd_vlsp_mt_em_user_manage_info_minf t1
        ON zm.invitee_company_user_id = t1.psn_acct_user_base_id
        AND t1.is_fake_user = '0'
    WHERE activity_title = '货主招募活动'
      AND invitee_id IS NOT NULL AND invitee_id <> ''
),
company_tl AS (
    SELECT DISTINCT COALESCE(t1.company_id, t3.company_id) AS company_id
    FROM (
        SELECT a.user_id
        FROM dwd.dwd_vlsp_mt_bt_advertise_placement_business_process_minf a
        WHERE a.user_id <> ''
        UNION
        SELECT b.user_base_id AS user_id
        FROM match_shipper_table_advertise_info a
        LEFT JOIN dwd.dwd_vlsp_mt_em_user_manage_info_minf b
            ON a.telephone = b.telephone
            AND b.is_fake_user = '0'
        WHERE b.user_base_id <> ''
    ) ad
    LEFT JOIN dwd.dwd_vlsp_mt_em_user_manage_info_minf t1
        ON ad.user_id = t1.user_base_id
        AND t1.is_fake_user = '0'
    LEFT JOIN dwd.dwd_vlsp_mt_em_user_manage_info_minf t3
        ON t3.psn_acct_user_base_id = ad.user_id
        AND t3.is_fake_user = '0'
    WHERE COALESCE(t1.company_id, t3.company_id) IS NOT NULL
),
company_dx AS (
    SELECT DISTINCT company_name AS company_name_dx
    FROM match_shipper_telesales_leads_info
),
company_dd AS (
    SELECT DISTINCT company_name AS company_name_dd
    FROM match_shipper_dispatching_leads_info
),
company_wxx AS (
    SELECT customer_company_id, MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd.dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
),
/* ===== 履约运单 + 举措命中 + 是否异常 ===== */
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        DATE_SUB(
            DATE(waybill.unload_time),
            INTERVAL ((WEEKDAY(waybill.unload_time) - 2 + 7) % 7) DAY
        ) AS week_start,
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
        END AS hit_wxx,
        CASE WHEN abn.waybill_id IS NOT NULL THEN 1 ELSE 0 END AS is_abnormal
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = waybill.waybill_id
    WHERE DATE(waybill.unload_time) >= DATE '2026-06-01'
      AND DATE(waybill.unload_time) <= CURRENT_DATE()
      AND waybill.load_time IS NOT NULL
      AND waybill.unload_time IS NOT NULL
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
        hit_offline,
        is_abnormal,
        CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN 1 ELSE 0 END AS is_online,
        CASE WHEN hit_zm  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN hit_tl  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN hit_dx  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN hit_dd  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dd,
        CASE WHEN hit_wxx = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_wxx
    FROM waybill_hit
),
/* 履约口径 + 履约剔异常 双口径聚合 */
agg AS (
    SELECT
        week_start,
        /* 履约 */
        COUNT(DISTINCT waybill_id) AS fy_total,
        COUNT(DISTINCT CASE WHEN is_online = 1 THEN waybill_id END) AS fy_online,
        SUM(w_zm)  AS fy_zm,
        SUM(w_tl)  AS fy_tl,
        SUM(w_dx)  AS fy_dx,
        SUM(w_dd)  AS fy_dd,
        SUM(w_wxx) AS fy_wxx,
        /* 履约剔异常 */
        COUNT(DISTINCT CASE WHEN is_abnormal = 0 THEN waybill_id END) AS cl_total,
        COUNT(DISTINCT CASE WHEN is_abnormal = 0 AND is_online = 1 THEN waybill_id END) AS cl_online,
        SUM(CASE WHEN is_abnormal = 0 THEN w_zm  ELSE 0 END) AS cl_zm,
        SUM(CASE WHEN is_abnormal = 0 THEN w_tl  ELSE 0 END) AS cl_tl,
        SUM(CASE WHEN is_abnormal = 0 THEN w_dx  ELSE 0 END) AS cl_dx,
        SUM(CASE WHEN is_abnormal = 0 THEN w_dd  ELSE 0 END) AS cl_dd,
        SUM(CASE WHEN is_abnormal = 0 THEN w_wxx ELSE 0 END) AS cl_wxx
    FROM waybill_split
    GROUP BY week_start
),
result AS (
    SELECT week_start, '整体' AS 维度, fy_total AS 履约运单量, cl_total AS 履约剔异常运单量 FROM agg
    UNION ALL
    SELECT week_start, '线上', fy_online, cl_online FROM agg
    UNION ALL
    SELECT week_start, '货主招募', fy_zm, cl_zm FROM agg
    UNION ALL
    SELECT week_start, '投流', fy_tl, cl_tl FROM agg
    UNION ALL
    SELECT week_start, '电销', fy_dx, cl_dx FROM agg
    UNION ALL
    SELECT week_start, '调度', fy_dd, cl_dd FROM agg
    UNION ALL
    SELECT week_start, '无线下销售归属', fy_wxx, cl_wxx FROM agg
)
SELECT
    week_start AS 周起始日,
    维度,
    ROUND(履约运单量 / 10000, 3) AS 履约运单量_万单,
    ROUND(履约剔异常运单量 / 10000, 3) AS 履约剔异常运单量_万单,
    ROUND((履约运单量 - 履约剔异常运单量) / 10000, 3) AS 剔除运单量_万单,
    ROUND((履约运单量 - 履约剔异常运单量) / NULLIF(履约运单量, 0) * 100, 2) AS 剔除占比_pct
FROM result
ORDER BY
    week_start,
    CASE 维度
        WHEN '整体' THEN 0
        WHEN '线上' THEN 1
        WHEN '货主招募' THEN 10
        WHEN '投流' THEN 11
        WHEN '电销' THEN 12
        WHEN '调度' THEN 13
        WHEN '无线下销售归属' THEN 14
        ELSE 99
    END;
