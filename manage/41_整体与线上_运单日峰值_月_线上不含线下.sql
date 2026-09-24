/* 整体 / 线上 运单日峰值（月）| 线上不含线下
 * 口径：
 *   - 有效运单过滤同 01 / 01b / 29（线下线索 OR 非微信主体；剔除测试公司；有效成交）
 *   - 整体 = 过滤后全部运单
 *   - 线上 = 命中线上标签（货主招募/投流/电销/调度/无线下）且 hit_offline=0（不含线下，同 01b）
 * 输出：每月整体&线上的月量、日均、日峰值（万单）、峰值日、峰值环比、占比
 * 改 tim 可调统计起止日
 *
 * 若还需要举措 / 运单类型 / 举措×类型峰值，见 40_整体与线上_运单日峰值_月_线上不含线下.sql
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
daily AS (
    SELECT
        dt,
        DATE_FORMAT(dt, '%Y-%m-01') AS mon,
        COUNT(DISTINCT waybill_id) AS total_cnt,
        /* 线上不含线下：非线下 ∩ 命中任一线上标签（含无线下） */
        COUNT(DISTINCT CASE
            WHEN hit_offline = 0
             AND hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0
            THEN waybill_id
        END) AS online_cnt
    FROM waybill_hit
    GROUP BY dt
),
month_agg AS (
    SELECT
        mon,
        SUM(total_cnt) AS total_month_cnt,
        SUM(online_cnt) AS online_month_cnt,
        COUNT(DISTINCT dt) AS day_n,
        MAX(total_cnt) AS total_peak_cnt,
        MAX(online_cnt) AS online_peak_cnt
    FROM daily
    GROUP BY mon
),
total_peak_day AS (
    SELECT mon, MIN(dt) AS peak_dt
    FROM daily d
    WHERE total_cnt = (
        SELECT MAX(d2.total_cnt) FROM daily d2 WHERE d2.mon = d.mon
    )
    GROUP BY mon
),
online_peak_day AS (
    SELECT mon, MIN(dt) AS peak_dt
    FROM daily d
    WHERE online_cnt = (
        SELECT MAX(d2.online_cnt) FROM daily d2 WHERE d2.mon = d.mon
    )
    GROUP BY mon
)
SELECT
    m.mon AS 月份,
    m.day_n AS 统计天数,
    /* ===== 整体 ===== */
    ROUND(m.total_month_cnt / 10000.0, 4) AS 整体运单量_万单,
    ROUND(m.total_month_cnt / 10000.0 / m.day_n, 4) AS 整体日均_万单,
    ROUND(m.total_peak_cnt / 10000.0, 4) AS 整体日峰值_万单,
    tp.peak_dt AS 整体峰值日,
    ROUND(
        m.total_peak_cnt * 1.0 / NULLIF(LAG(m.total_peak_cnt) OVER (ORDER BY m.mon), 0) - 1,
        4
    ) AS 整体峰值环比,
    /* ===== 线上（不含线下） ===== */
    ROUND(m.online_month_cnt / 10000.0, 4) AS 线上运单量_万单,
    ROUND(m.online_month_cnt / 10000.0 / m.day_n, 4) AS 线上日均_万单,
    ROUND(m.online_peak_cnt / 10000.0, 4) AS 线上日峰值_万单,
    op.peak_dt AS 线上峰值日,
    ROUND(
        m.online_peak_cnt * 1.0 / NULLIF(LAG(m.online_peak_cnt) OVER (ORDER BY m.mon), 0) - 1,
        4
    ) AS 线上峰值环比,
    /* 占比 */
    ROUND(m.online_month_cnt * 1.0 / NULLIF(m.total_month_cnt, 0), 4) AS 线上量占比,
    ROUND(m.online_peak_cnt * 1.0 / NULLIF(m.total_peak_cnt, 0), 4) AS 峰值日线上占比
FROM month_agg m
LEFT JOIN total_peak_day tp ON tp.mon = m.mon
LEFT JOIN online_peak_day op ON op.mon = m.mon
ORDER BY m.mon;
