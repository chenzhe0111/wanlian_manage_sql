/* 天粒度：整体 / 线上 / 各举措 × 运单类型（合计+撮合/TMS/网货）
 * 口径同 01_月度汇总：运单过滤一致；多举措命中等权分摊
 * 输出：日期 | 统计层 | 维度 | 运单类型 | 运单量
 * 改日期：调整下方 accept_dt 区间即可
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
        CAST(SUBSTR(waybill.accept_dt, 1, 10) AS DATE) AS dt,
        CASE
            WHEN waybill.invoice_type = 20 THEN '网货'
            WHEN waybill.invoice_type = 10 AND waybill.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_type,
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
    WHERE SUBSTR(waybill.accept_dt, 1, 10) BETWEEN DATE '2026-08-01' AND DATE '2026-08-25'
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
        waybill_id, dt, waybill_type,
        hit_offline, hit_zm, hit_tl, hit_dx, hit_dd, hit_wxx,
        CASE WHEN hit_zm  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN hit_tl  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN hit_dx  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN hit_dd  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dd,
        CASE WHEN hit_wxx = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_wxx
    FROM waybill_hit
),
/* 按日 × 运单类型 */
agg_type AS (
    SELECT
        dt,
        waybill_type,
        COUNT(DISTINCT waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN hit_offline = 1 THEN waybill_id END) AS offline_cnt,
        COUNT(DISTINCT CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN waybill_id END) AS online_cnt,
        SUM(w_zm)  AS zm_cnt,
        SUM(w_tl)  AS tl_cnt,
        SUM(w_dx)  AS dx_cnt,
        SUM(w_dd)  AS dd_cnt,
        SUM(w_wxx) AS wxx_cnt
    FROM waybill_split
    GROUP BY dt, waybill_type
),
/* 按日合计 */
agg_day AS (
    SELECT
        dt,
        SUM(total_cnt)   AS total_cnt,
        SUM(offline_cnt) AS offline_cnt,
        SUM(online_cnt)  AS online_cnt,
        SUM(zm_cnt)      AS zm_cnt,
        SUM(tl_cnt)      AS tl_cnt,
        SUM(dx_cnt)      AS dx_cnt,
        SUM(dd_cnt)      AS dd_cnt,
        SUM(wxx_cnt)     AS wxx_cnt
    FROM agg_type
    GROUP BY dt
),
result AS (
    /* ----- 整体 ----- */
    SELECT dt, '整体' AS 统计层, '整体' AS 维度, '合计' AS 运单类型, total_cnt AS 运单量 FROM agg_day
    UNION ALL
    SELECT dt, '整体', '整体', waybill_type, total_cnt FROM agg_type

    /* ----- 线上 ----- */
    UNION ALL
    SELECT dt, '线上', '线上', '合计', online_cnt FROM agg_day
    UNION ALL
    SELECT dt, '线上', '线上', waybill_type, online_cnt FROM agg_type

    /* ----- 线下（补充） ----- */
    UNION ALL
    SELECT dt, '线下', '线下', '合计', offline_cnt FROM agg_day
    UNION ALL
    SELECT dt, '线下', '线下', waybill_type, offline_cnt FROM agg_type

    /* ----- 各举措合计 ----- */
    UNION ALL
    SELECT dt, '举措', '货主招募', '合计', zm_cnt  FROM agg_day
    UNION ALL
    SELECT dt, '举措', '投流',     '合计', tl_cnt  FROM agg_day
    UNION ALL
    SELECT dt, '举措', '电销',     '合计', dx_cnt  FROM agg_day
    UNION ALL
    SELECT dt, '举措', '调度',     '合计', dd_cnt  FROM agg_day
    UNION ALL
    SELECT dt, '举措', '无线下销售归属', '合计', wxx_cnt FROM agg_day

    /* ----- 各举措 × 运单类型 ----- */
    UNION ALL
    SELECT dt, '举措', '货主招募', waybill_type, zm_cnt  FROM agg_type
    UNION ALL
    SELECT dt, '举措', '投流',     waybill_type, tl_cnt  FROM agg_type
    UNION ALL
    SELECT dt, '举措', '电销',     waybill_type, dx_cnt  FROM agg_type
    UNION ALL
    SELECT dt, '举措', '调度',     waybill_type, dd_cnt  FROM agg_type
    UNION ALL
    SELECT dt, '举措', '无线下销售归属', waybill_type, wxx_cnt FROM agg_type
)
SELECT
    dt AS 日期,
    统计层,
    维度,
    运单类型,
    ROUND(运单量, 2) AS 运单量
FROM result
ORDER BY
    日期,
    CASE 统计层
        WHEN '整体' THEN 1
        WHEN '线上' THEN 2
        WHEN '线下' THEN 3
        WHEN '举措' THEN 4
        ELSE 9
    END,
    CASE 维度
        WHEN '整体' THEN 0
        WHEN '线上' THEN 1
        WHEN '线下' THEN 2
        WHEN '货主招募' THEN 10
        WHEN '投流' THEN 11
        WHEN '电销' THEN 12
        WHEN '调度' THEN 13
        WHEN '无线下销售归属' THEN 14
        ELSE 99
    END,
    CASE 运单类型
        WHEN '合计' THEN 0
        WHEN '撮合' THEN 1
        WHEN 'TMS' THEN 2
        WHEN '网货' THEN 3
        ELSE 9
    END;
