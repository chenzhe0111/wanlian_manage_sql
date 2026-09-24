/* 各举措成交运单量：均分 vs 不均分 | 月度汇总口径（不区分新老）
 * 命中/过滤与 01_月度汇总 一致：
 *   - 线下线索 OR 非微信主体
 *   - 均分：线上五渠道 1/hit_cnt；线下整单 COUNT DISTINCT
 *   - 不均分：命中举措整单计 1（多举措同单会重复）
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
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        DATE_FORMAT(waybill.accept_dt, '%Y-%m-01') AS mon,
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
    WHERE SUBSTR(waybill.accept_dt, 1, 10) BETWEEN DATE '2026-01-01' AND DATE '2026-07-14'
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
        waybill_id, mon, waybill_category,
        hit_offline, hit_zm, hit_tl, hit_dx, hit_dd, hit_wxx,
        hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx AS hit_cnt,
        /* 均分 */
        CASE WHEN hit_zm  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_zm_share,
        CASE WHEN hit_tl  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_tl_share,
        CASE WHEN hit_dx  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dx_share,
        CASE WHEN hit_dd  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dd_share,
        CASE WHEN hit_wxx = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_wxx_share,
        /* 不均分：命中即整单 1 */
        CASE WHEN hit_zm  = 1 THEN 1.0 ELSE 0 END AS w_zm_full,
        CASE WHEN hit_tl  = 1 THEN 1.0 ELSE 0 END AS w_tl_full,
        CASE WHEN hit_dx  = 1 THEN 1.0 ELSE 0 END AS w_dx_full,
        CASE WHEN hit_dd  = 1 THEN 1.0 ELSE 0 END AS w_dd_full,
        CASE WHEN hit_wxx = 1 THEN 1.0 ELSE 0 END AS w_wxx_full
    FROM waybill_hit
),
agg AS (
    SELECT
        mon, waybill_category,
        COUNT(DISTINCT waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN hit_offline = 1 THEN waybill_id END) AS offline_cnt,
        COUNT(DISTINCT CASE WHEN hit_cnt > 0 THEN waybill_id END) AS online_cnt,
        /* 均分 */
        SUM(w_zm_share)  AS zm_share,
        SUM(w_tl_share)  AS tl_share,
        SUM(w_dx_share)  AS dx_share,
        SUM(w_dd_share)  AS dd_share,
        SUM(w_wxx_share) AS wxx_share,
        /* 不均分 */
        SUM(w_zm_full)  AS zm_full,
        SUM(w_tl_full)  AS tl_full,
        SUM(w_dx_full)  AS dx_full,
        SUM(w_dd_full)  AS dd_full,
        SUM(w_wxx_full) AS wxx_full
    FROM waybill_split
    GROUP BY mon, waybill_category
),
agg_all AS (
    SELECT
        mon,
        SUM(total_cnt)   AS total_cnt,
        SUM(offline_cnt) AS offline_cnt,
        SUM(online_cnt)  AS online_cnt,
        SUM(zm_share)  AS zm_share,  SUM(tl_share)  AS tl_share,
        SUM(dx_share)  AS dx_share,  SUM(dd_share)  AS dd_share,
        SUM(wxx_share) AS wxx_share,
        SUM(zm_full)   AS zm_full,   SUM(tl_full)   AS tl_full,
        SUM(dx_full)   AS dx_full,   SUM(dd_full)   AS dd_full,
        SUM(wxx_full)  AS wxx_full
    FROM agg
    GROUP BY mon
),
result AS (
    /* 整体 */
    SELECT mon, '整体' AS stat_level, '整体' AS stat_dim,
           total_cnt AS cnt_share, total_cnt AS cnt_full FROM agg_all
    UNION ALL
    SELECT mon, '整体', waybill_category, total_cnt, total_cnt FROM agg
    /* 线上线下（线下/线上按去重运单，两种口径相同） */
    UNION ALL
    SELECT mon, '线上线下', '线下', offline_cnt, offline_cnt FROM agg_all
    UNION ALL
    SELECT mon, '线上线下', '线上', online_cnt, online_cnt FROM agg_all
    UNION ALL
    SELECT mon, '线上', '线上', online_cnt, online_cnt FROM agg_all
    UNION ALL
    SELECT mon, '线上', waybill_category, online_cnt, online_cnt FROM agg
    /* 线上举措：合计 */
    UNION ALL SELECT mon, '线上举措', '货主招募', zm_share, zm_full FROM agg_all
    UNION ALL SELECT mon, '线上举措', '投流', tl_share, tl_full FROM agg_all
    UNION ALL SELECT mon, '线上举措', '电销', dx_share, dx_full FROM agg_all
    UNION ALL SELECT mon, '线上举措', '调度', dd_share, dd_full FROM agg_all
    UNION ALL SELECT mon, '线上举措', '无线下销售归属', wxx_share, wxx_full FROM agg_all
    /* 线上举措 × 运单类型 */
    UNION ALL SELECT mon, '线上举措', CONCAT('货主招募-', waybill_category), zm_share, zm_full FROM agg
    UNION ALL SELECT mon, '线上举措', CONCAT('投流-', waybill_category), tl_share, tl_full FROM agg
    UNION ALL SELECT mon, '线上举措', CONCAT('电销-', waybill_category), dx_share, dx_full FROM agg
    UNION ALL SELECT mon, '线上举措', CONCAT('调度-', waybill_category), dd_share, dd_full FROM agg
    UNION ALL SELECT mon, '线上举措', CONCAT('无线下销售归属-', waybill_category), wxx_share, wxx_full FROM agg
    /* 举措：合计（含线下） */
    UNION ALL SELECT mon, '举措', '货主招募', zm_share, zm_full FROM agg_all
    UNION ALL SELECT mon, '举措', '投流', tl_share, tl_full FROM agg_all
    UNION ALL SELECT mon, '举措', '电销', dx_share, dx_full FROM agg_all
    UNION ALL SELECT mon, '举措', '调度', dd_share, dd_full FROM agg_all
    UNION ALL SELECT mon, '举措', '无线下销售归属', wxx_share, wxx_full FROM agg_all
    UNION ALL SELECT mon, '举措', '线下', offline_cnt, offline_cnt FROM agg_all
    /* 举措 × 运单类型 */
    UNION ALL SELECT mon, '举措', CONCAT('货主招募-', waybill_category), zm_share, zm_full FROM agg
    UNION ALL SELECT mon, '举措', CONCAT('投流-', waybill_category), tl_share, tl_full FROM agg
    UNION ALL SELECT mon, '举措', CONCAT('电销-', waybill_category), dx_share, dx_full FROM agg
    UNION ALL SELECT mon, '举措', CONCAT('调度-', waybill_category), dd_share, dd_full FROM agg
    UNION ALL SELECT mon, '举措', CONCAT('无线下销售归属-', waybill_category), wxx_share, wxx_full FROM agg
    UNION ALL SELECT mon, '举措', CONCAT('线下-', waybill_category), offline_cnt, offline_cnt FROM agg
)
SELECT
    mon AS 月份,
    stat_level AS 统计层级,
    stat_dim AS 维度,
    CONCAT(stat_level, '-', stat_dim) AS 层级维度,
    ROUND(cnt_share, 4) AS 运单量_均分,
    ROUND(cnt_full, 4) AS 运单量_不均分
FROM result
ORDER BY
    mon,
    CASE stat_level
        WHEN '整体' THEN 1
        WHEN '线上线下' THEN 2
        WHEN '线上' THEN 3
        WHEN '线上举措' THEN 4
        WHEN '举措' THEN 5
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
        WHEN stat_dim LIKE '线下-%' THEN 35
        ELSE 99
    END,
    stat_dim;
