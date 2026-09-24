/* 整体 / 线上 运单日峰值（月）+ 举措 / 运单类型 / 举措×类型
 * 口径：
 *   - 有效运单过滤同 01 / 01b / 29
 *   - 整体 = 过滤后全部运单
 *   - 线上 = 命中线上标签（招募/投流/电销/调度/无线下）且 hit_offline=0（不含线下，同 01b）
 *   - 举措等权分摊：仅非线下运单分摊；多举措命中 1/N（同 01b）
 *   - 运单类型：网货(invoice_type=20) / TMS(invoice_type=10 & tms_flag=10) / 撮合(其余)
 * 输出长表：月份 | 统计层 | 维度 | 运单类型 | 统计天数 | 月量/日均/日峰值(万单) | 峰值日 | 峰值环比
 * 改 tim 可调统计起止日
 */
WITH tim AS (
    SELECT
        DATE '2026-01-01' AS range_start,
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS as_of_dt
),
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
        CAST(waybill.accept_dt AS DATE) AS dt,
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
    CROSS JOIN tim t
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    WHERE DATE(waybill.accept_dt) >= t.range_start
      AND DATE(waybill.accept_dt) <= t.as_of_dt
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
        /* 仅非线下才分摊到线上举措；与线下重合的运单权重归 0（同 01b） */
        CASE WHEN hit_offline = 0 AND hit_zm  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN hit_offline = 0 AND hit_tl  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN hit_offline = 0 AND hit_dx  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN hit_offline = 0 AND hit_dd  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dd,
        CASE WHEN hit_offline = 0 AND hit_wxx = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_wxx
    FROM waybill_hit
),
/* 日 × 运单类型 */
daily_type AS (
    SELECT
        dt,
        DATE_FORMAT(dt, '%Y-%m-01') AS mon,
        waybill_type,
        COUNT(DISTINCT waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE
            WHEN hit_offline = 0 AND hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0
            THEN waybill_id
        END) AS online_cnt,
        SUM(w_zm)  AS zm_cnt,
        SUM(w_tl)  AS tl_cnt,
        SUM(w_dx)  AS dx_cnt,
        SUM(w_dd)  AS dd_cnt,
        SUM(w_wxx) AS wxx_cnt
    FROM waybill_split
    GROUP BY dt, waybill_type
),
/* 日合计 */
daily_all AS (
    SELECT
        dt,
        mon,
        SUM(total_cnt)  AS total_cnt,
        SUM(online_cnt) AS online_cnt,
        SUM(zm_cnt)     AS zm_cnt,
        SUM(tl_cnt)     AS tl_cnt,
        SUM(dx_cnt)     AS dx_cnt,
        SUM(dd_cnt)     AS dd_cnt,
        SUM(wxx_cnt)    AS wxx_cnt
    FROM daily_type
    GROUP BY dt, mon
),
/* 统一成长表：dt | mon | 统计层 | 维度 | 运单类型 | cnt */
daily_long AS (
    /* ----- 整体合计 ----- */
    SELECT dt, mon, '整体' AS stat_level, '整体' AS dim_name, '合计' AS waybill_type, total_cnt AS cnt
    FROM daily_all
    UNION ALL
    /* ----- 整体 × 运单类型 ----- */
    SELECT dt, mon, '整体', '整体', waybill_type, total_cnt
    FROM daily_type
    UNION ALL
    /* ----- 线上合计（不含线下） ----- */
    SELECT dt, mon, '线上', '线上', '合计', online_cnt
    FROM daily_all
    UNION ALL
    /* ----- 线上 × 运单类型 ----- */
    SELECT dt, mon, '线上', '线上', waybill_type, online_cnt
    FROM daily_type
    UNION ALL
    /* ----- 举措合计 ----- */
    SELECT dt, mon, '举措', '货主招募', '合计', zm_cnt  FROM daily_all
    UNION ALL
    SELECT dt, mon, '举措', '投流',     '合计', tl_cnt  FROM daily_all
    UNION ALL
    SELECT dt, mon, '举措', '电销',     '合计', dx_cnt  FROM daily_all
    UNION ALL
    SELECT dt, mon, '举措', '调度',     '合计', dd_cnt  FROM daily_all
    UNION ALL
    SELECT dt, mon, '举措', '无线下销售归属', '合计', wxx_cnt FROM daily_all
    UNION ALL
    /* ----- 举措 × 运单类型 ----- */
    SELECT dt, mon, '举措', '货主招募', waybill_type, zm_cnt  FROM daily_type
    UNION ALL
    SELECT dt, mon, '举措', '投流',     waybill_type, tl_cnt  FROM daily_type
    UNION ALL
    SELECT dt, mon, '举措', '电销',     waybill_type, dx_cnt  FROM daily_type
    UNION ALL
    SELECT dt, mon, '举措', '调度',     waybill_type, dd_cnt  FROM daily_type
    UNION ALL
    SELECT dt, mon, '举措', '无线下销售归属', waybill_type, wxx_cnt FROM daily_type
),
month_agg AS (
    SELECT
        mon,
        stat_level,
        dim_name,
        waybill_type,
        SUM(cnt) AS month_cnt,
        COUNT(DISTINCT dt) AS day_n,
        MAX(cnt) AS peak_cnt
    FROM daily_long
    GROUP BY mon, stat_level, dim_name, waybill_type
),
peak_day AS (
    /* 并列峰值取最早日期 */
    SELECT
        d.mon, d.stat_level, d.dim_name, d.waybill_type,
        MIN(d.dt) AS peak_dt
    FROM daily_long d
    JOIN month_agg m
      ON m.mon = d.mon
     AND m.stat_level = d.stat_level
     AND m.dim_name = d.dim_name
     AND m.waybill_type = d.waybill_type
     AND d.cnt = m.peak_cnt
    GROUP BY d.mon, d.stat_level, d.dim_name, d.waybill_type
)
SELECT
    m.mon AS 月份,
    m.stat_level AS 统计层,
    m.dim_name AS 维度,
    m.waybill_type AS 运单类型,
    m.day_n AS 统计天数,
    ROUND(m.month_cnt / 10000.0, 4) AS 运单量_万单,
    ROUND(m.month_cnt / 10000.0 / m.day_n, 4) AS 日均_万单,
    ROUND(m.peak_cnt / 10000.0, 4) AS 日峰值_万单,
    p.peak_dt AS 峰值日,
    ROUND(
        m.peak_cnt * 1.0 / NULLIF(
            LAG(m.peak_cnt) OVER (
                PARTITION BY m.stat_level, m.dim_name, m.waybill_type
                ORDER BY m.mon
            ),
            0
        ) - 1,
        4
    ) AS 峰值环比
FROM month_agg m
LEFT JOIN peak_day p
  ON p.mon = m.mon
 AND p.stat_level = m.stat_level
 AND p.dim_name = m.dim_name
 AND p.waybill_type = m.waybill_type
ORDER BY
    m.mon,
    CASE m.stat_level
        WHEN '整体' THEN 1
        WHEN '线上' THEN 2
        WHEN '举措' THEN 3
        ELSE 9
    END,
    CASE m.dim_name
        WHEN '整体' THEN 1
        WHEN '线上' THEN 2
        WHEN '货主招募' THEN 3
        WHEN '投流' THEN 4
        WHEN '电销' THEN 5
        WHEN '调度' THEN 6
        WHEN '无线下销售归属' THEN 7
        ELSE 9
    END,
    CASE m.waybill_type
        WHEN '合计' THEN 1
        WHEN 'TMS' THEN 2
        WHEN '撮合' THEN 3
        WHEN '网货' THEN 4
        ELSE 9
    END;
