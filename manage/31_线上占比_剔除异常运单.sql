/* 整体 / 分举措：线上运单占比 & 剔除异常运单后的线上运单占比
 * 异常口径：异常剔除 + 申诉中 算异常；申诉成功不算异常；未命中异常场景不算异常
 * 举措口径：同 01_月度汇总（五举措等权分摊；线上=命中任一线上举措）
 * 线上运单占比 = 线上运单 / 整体运单
 * 剔异常后线上运单占比 = 线上非异常运单 / 整体非异常运单
 */
WITH tim AS (
    SELECT
        DATE '2026-01-01' AS range_start,
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS as_of_dt   /* 可改成 DATE '2026-08-31' */
),
/* ===== 异常运单判定（用户口径） ===== */
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
    FROM ads_vlsp_mt_match_waybill_abnormal_detail_info_df ab
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
    /* 同一运单多标签时：任一剔除即剔除 */
    SELECT
        waybill_id,
        CASE WHEN MAX(CASE WHEN 类别 = '剔除' THEN 1 ELSE 0 END) = 1 THEN '剔除' ELSE '下发' END AS 类别
    FROM ab_raw
    GROUP BY waybill_id
),
ss_raw AS (
    /* 线下申诉成功 */
    SELECT DISTINCT waybill_id, '申诉成功' AS 是否申诉成功
    FROM match_way_abnormal_appeal_approved_info
    WHERE waybill_id NOT IN (SELECT DISTINCT waybill_id FROM match_way_abnormal_appeal_failed_info)
    UNION ALL
    /* 线下申诉失败 */
    SELECT DISTINCT waybill_id, '申诉失败' AS 是否申诉成功
    FROM match_way_abnormal_appeal_failed_info
    UNION ALL
    /* 线上申诉 */
    SELECT DISTINCT
        waybill_id,
        CASE
            WHEN appl_status IN (300, 410, 310, 420, 100, 500) THEN '申诉中'   /* 100待推送 500已作废 */
            WHEN appl_status IN (400, 430) THEN '申诉成功'
            WHEN appl_status IN (200, 320, 440) THEN '申诉失败'
            ELSE CAST(appl_status AS STRING)
        END AS 是否申诉成功
    FROM ads_vlsp_mt_match_waybill_high_abnormal_detail_info_minf
),
ss AS (
    /* 多来源冲突时：申诉成功 > 申诉中 > 申诉失败 */
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
/* ===== 举措归属（同 01） ===== */
company_zm AS (
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
        CASE WHEN abn.waybill_id IS NOT NULL THEN 1 ELSE 0 END AS is_abnormal
    FROM dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    CROSS JOIN tim t
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = waybill.waybill_id
    WHERE DATE(waybill.accept_dt) BETWEEN t.range_start AND t.as_of_dt
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
        waybill_id,
        mon,
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
agg AS (
    SELECT
        mon,
        COUNT(DISTINCT waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN is_online = 1 THEN waybill_id END) AS online_cnt,
        COUNT(DISTINCT CASE WHEN is_abnormal = 0 THEN waybill_id END) AS normal_cnt,
        COUNT(DISTINCT CASE WHEN is_online = 1 AND is_abnormal = 0 THEN waybill_id END) AS online_normal_cnt,
        SUM(w_zm) AS zm_cnt,
        SUM(CASE WHEN is_abnormal = 0 THEN w_zm ELSE 0 END) AS zm_normal_cnt,
        SUM(w_tl) AS tl_cnt,
        SUM(CASE WHEN is_abnormal = 0 THEN w_tl ELSE 0 END) AS tl_normal_cnt,
        SUM(w_dx) AS dx_cnt,
        SUM(CASE WHEN is_abnormal = 0 THEN w_dx ELSE 0 END) AS dx_normal_cnt,
        SUM(w_dd) AS dd_cnt,
        SUM(CASE WHEN is_abnormal = 0 THEN w_dd ELSE 0 END) AS dd_normal_cnt,
        SUM(w_wxx) AS wxx_cnt,
        SUM(CASE WHEN is_abnormal = 0 THEN w_wxx ELSE 0 END) AS wxx_normal_cnt
    FROM waybill_split
    GROUP BY mon
),
result AS (
    SELECT mon, '整体' AS stat_dim, total_cnt, online_cnt, normal_cnt, online_normal_cnt
    FROM agg
    UNION ALL
    SELECT mon, '货主招募', total_cnt, zm_cnt, normal_cnt, zm_normal_cnt FROM agg
    UNION ALL
    SELECT mon, '投流', total_cnt, tl_cnt, normal_cnt, tl_normal_cnt FROM agg
    UNION ALL
    SELECT mon, '电销', total_cnt, dx_cnt, normal_cnt, dx_normal_cnt FROM agg
    UNION ALL
    SELECT mon, '调度', total_cnt, dd_cnt, normal_cnt, dd_normal_cnt FROM agg
    UNION ALL
    SELECT mon, '无线下销售归属', total_cnt, wxx_cnt, normal_cnt, wxx_normal_cnt FROM agg
)
SELECT
    mon AS 月份,
    stat_dim AS 维度,
    total_cnt / 10000 AS 整体运单_万,
    online_cnt / 10000 AS 线上运单_万,
    online_cnt / NULLIF(total_cnt, 0) AS 线上运单占比,
    normal_cnt / 10000 AS 剔异常后整体运单_万,
    online_normal_cnt / 10000 AS 剔异常后线上运单_万,
    online_normal_cnt / NULLIF(normal_cnt, 0) AS 剔异常后线上运单占比,
    /* 分举措行：线上运单_万 = 该举措分摊量；占比 = 举措量/整体 */
    CASE WHEN stat_dim = '整体' THEN NULL ELSE online_cnt / NULLIF(total_cnt, 0) END AS 举措占整体,
    CASE WHEN stat_dim = '整体' THEN NULL ELSE online_normal_cnt / NULLIF(normal_cnt, 0) END AS 剔异常后举措占整体
FROM result
ORDER BY
    mon,
    CASE stat_dim
        WHEN '整体' THEN 0
        WHEN '货主招募' THEN 1
        WHEN '投流' THEN 2
        WHEN '电销' THEN 3
        WHEN '调度' THEN 4
        WHEN '无线下销售归属' THEN 5
        ELSE 99
    END;
