/* 月度汇总 × 异常/正常运单（不拆运单类型）
 * 维度：整体（整体/线上整体/线下整体）/ 线上举措 / 举措
 * 异常口径：运费异常、秒装秒卸、时速异常高、装卸货打卡异常
 * 输出：整体运单、异常运单、正常运单（正常 = 整体 - 异常）
 */
WITH company_zm AS (
    SELECT DISTINCT invitee_id
    FROM dwd_vlsp_mt_user_recruitment_business_process_minf zm
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t1
        ON zm.invitee_company_user_id = t1.psn_acct_user_base_id
        AND t1.is_fake_user = '0'
    WHERE activity_title = '货主招募活动'
      AND invitee_id IS NOT NULL AND invitee_id <> ''
),
company_tl AS (
    SELECT DISTINCT COALESCE(t1.company_id, t3.company_id) AS company_id
    FROM (
        SELECT a.user_id
        FROM dwd_vlsp_mt_bt_advertise_placement_business_process_minf a
        WHERE a.user_id <> ''
        UNION
        SELECT b.user_base_id AS user_id
        FROM match_shipper_table_advertise_info a
        LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf b
            ON a.telephone = b.telephone
            AND b.is_fake_user = '0'
        WHERE b.user_base_id <> ''
    ) ad
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t1
        ON ad.user_id = t1.user_base_id
        AND t1.is_fake_user = '0'
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t3
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
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
),
abnormal_waybill AS (
    SELECT DISTINCT waybill_id
    FROM ads_vlsp_mt_match_waybill_abnormal_detail_info_df
    WHERE scenario_tags LIKE '%运费异常%'
       OR scenario_tags LIKE '%秒装秒卸%'
       OR scenario_tags LIKE '%时速异常高%'
       OR scenario_tags LIKE '%装卸货打卡异常%'
),
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        DATE_FORMAT(waybill.accept_dt, '%Y-%m-01') AS mon,
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
        CASE WHEN ab.waybill_id IS NOT NULL THEN 1 ELSE 0 END AS is_abnormal
    FROM dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    LEFT JOIN abnormal_waybill ab ON ab.waybill_id = waybill.waybill_id
    WHERE SUBSTR(waybill.accept_dt, 1, 10) BETWEEN DATE '2026-01-01' AND DATE '2026-07-31'
      AND (
          company_wxx.sales_lv1_company_id IS NOT NULL
          OR NVL(waybill.shipper_company_name, '') NOT IN (
              SELECT DISTINCT dept_name
              FROM dim_vlsp_weixin_biz_company_minf
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
        waybill_id, mon,
        hit_offline, hit_zm, hit_tl, hit_dx, hit_dd, hit_wxx, is_abnormal,
        CASE WHEN hit_zm  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN hit_tl  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN hit_dx  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN hit_dd  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dd,
        CASE WHEN hit_wxx = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_wxx
    FROM waybill_hit
),
agg_all AS (
    SELECT
        mon,
        COUNT(DISTINCT waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN is_abnormal = 1 THEN waybill_id END) AS abnormal_cnt,
        COUNT(DISTINCT CASE WHEN is_abnormal = 0 THEN waybill_id END) AS normal_cnt,
        COUNT(DISTINCT CASE WHEN hit_offline = 1 THEN waybill_id END) AS offline_cnt,
        COUNT(DISTINCT CASE WHEN hit_offline = 1 AND is_abnormal = 1 THEN waybill_id END) AS offline_abn,
        COUNT(DISTINCT CASE WHEN hit_offline = 1 AND is_abnormal = 0 THEN waybill_id END) AS offline_nrm,
        COUNT(DISTINCT CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN waybill_id END) AS online_cnt,
        COUNT(DISTINCT CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 AND is_abnormal = 1 THEN waybill_id END) AS online_abn,
        COUNT(DISTINCT CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 AND is_abnormal = 0 THEN waybill_id END) AS online_nrm,
        SUM(w_zm) AS zm_cnt,
        SUM(CASE WHEN is_abnormal = 1 THEN w_zm ELSE 0 END) AS zm_abn,
        SUM(CASE WHEN is_abnormal = 0 THEN w_zm ELSE 0 END) AS zm_nrm,
        SUM(w_tl) AS tl_cnt,
        SUM(CASE WHEN is_abnormal = 1 THEN w_tl ELSE 0 END) AS tl_abn,
        SUM(CASE WHEN is_abnormal = 0 THEN w_tl ELSE 0 END) AS tl_nrm,
        SUM(w_dx) AS dx_cnt,
        SUM(CASE WHEN is_abnormal = 1 THEN w_dx ELSE 0 END) AS dx_abn,
        SUM(CASE WHEN is_abnormal = 0 THEN w_dx ELSE 0 END) AS dx_nrm,
        SUM(w_dd) AS dd_cnt,
        SUM(CASE WHEN is_abnormal = 1 THEN w_dd ELSE 0 END) AS dd_abn,
        SUM(CASE WHEN is_abnormal = 0 THEN w_dd ELSE 0 END) AS dd_nrm,
        SUM(w_wxx) AS wxx_cnt,
        SUM(CASE WHEN is_abnormal = 1 THEN w_wxx ELSE 0 END) AS wxx_abn,
        SUM(CASE WHEN is_abnormal = 0 THEN w_wxx ELSE 0 END) AS wxx_nrm
    FROM waybill_split
    GROUP BY mon
),
result AS (
    /* ===== 整体 / 线上整体 / 线下整体 ===== */
    SELECT mon, '整体' AS stat_level, '整体' AS stat_dim,
           total_cnt, abnormal_cnt, normal_cnt FROM agg_all
    UNION ALL
    SELECT mon, '整体', '线上整体',
           online_cnt, online_abn, online_nrm FROM agg_all
    UNION ALL
    SELECT mon, '整体', '线下整体',
           offline_cnt, offline_abn, offline_nrm FROM agg_all
    /* ===== 线上举措 ===== */
    UNION ALL
    SELECT mon, '线上举措', '货主招募', zm_cnt, zm_abn, zm_nrm FROM agg_all
    UNION ALL
    SELECT mon, '线上举措', '投流', tl_cnt, tl_abn, tl_nrm FROM agg_all
    UNION ALL
    SELECT mon, '线上举措', '电销', dx_cnt, dx_abn, dx_nrm FROM agg_all
    UNION ALL
    SELECT mon, '线上举措', '调度', dd_cnt, dd_abn, dd_nrm FROM agg_all
    UNION ALL
    SELECT mon, '线上举措', '无线下销售归属', wxx_cnt, wxx_abn, wxx_nrm FROM agg_all
    /* ===== 举措（含线下整体） ===== */
    UNION ALL
    SELECT mon, '举措', '货主招募', zm_cnt, zm_abn, zm_nrm FROM agg_all
    UNION ALL
    SELECT mon, '举措', '投流', tl_cnt, tl_abn, tl_nrm FROM agg_all
    UNION ALL
    SELECT mon, '举措', '电销', dx_cnt, dx_abn, dx_nrm FROM agg_all
    UNION ALL
    SELECT mon, '举措', '调度', dd_cnt, dd_abn, dd_nrm FROM agg_all
    UNION ALL
    SELECT mon, '举措', '无线下销售归属', wxx_cnt, wxx_abn, wxx_nrm FROM agg_all
    UNION ALL
    SELECT mon, '举措', '线下整体', offline_cnt, offline_abn, offline_nrm FROM agg_all
)
SELECT
    mon AS 月份,
    stat_level AS 统计层级,
    stat_dim AS 维度,
    CONCAT(stat_level, '-', stat_dim) AS 层级维度,
    total_cnt / 10000 AS 整体运单,
    abnormal_cnt / 10000 AS 异常运单,
    normal_cnt / 10000 AS 正常运单,
    abnormal_cnt / NULLIF(total_cnt, 0) AS 异常占比
FROM result
ORDER BY
    mon,
    CASE stat_level
        WHEN '整体' THEN 1
        WHEN '线上举措' THEN 2
        WHEN '举措' THEN 3
        ELSE 99
    END,
    CASE
        WHEN stat_dim = '整体' THEN 0
        WHEN stat_dim = '线上整体' THEN 1
        WHEN stat_dim = '线下整体' THEN 2
        WHEN stat_dim = '货主招募' THEN 10
        WHEN stat_dim = '投流' THEN 11
        WHEN stat_dim = '电销' THEN 12
        WHEN stat_dim = '调度' THEN 13
        WHEN stat_dim = '无线下销售归属' THEN 14
        ELSE 99
    END,
    stat_dim;
