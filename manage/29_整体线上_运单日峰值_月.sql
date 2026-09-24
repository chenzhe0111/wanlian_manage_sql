/* 整体线上订单：月度日峰值
 * 口径对齐 16_天粒度_整体线上线下 / 01_月度汇总：
 *   - 有效运单过滤一致
 *   - 线上 = 命中 货主招募 / 投流 / 电销 / 调度 / 无线下销售归属 任一
 * 输出：每月线上运单量、日均、日峰值（万单）、峰值日、峰值环比
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
waybill_online AS (
    SELECT
        waybill.waybill_id,
        CAST(waybill.accept_dt AS DATE) AS dt
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    CROSS JOIN tim t
    WHERE SUBSTR(waybill.accept_dt, 1, 10) BETWEEN t.range_start AND t.as_of_dt
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
      /* 线上五渠道任一命中 */
      AND (
          company_zm.invitee_id IS NOT NULL
          OR company_tl.company_id IS NOT NULL
          OR company_dx.company_name_dx IS NOT NULL
          OR company_dd.company_name_dd IS NOT NULL
          OR (
              company_wxx.sales_lv1_company_id IS NULL
              AND company_zm.invitee_id IS NULL
              AND company_tl.company_id IS NULL
              AND company_dx.company_name_dx IS NULL
              AND company_dd.company_name_dd IS NULL
          )
      )
),
daily AS (
    SELECT
        dt,
        DATE_FORMAT(dt, '%Y-%m-01') AS mon,
        COUNT(DISTINCT waybill_id) AS day_cnt
    FROM waybill_online
    GROUP BY dt
),
month_agg AS (
    SELECT
        mon,
        SUM(day_cnt) AS month_cnt,
        COUNT(DISTINCT dt) AS day_n,
        MAX(day_cnt) AS peak_cnt
    FROM daily
    GROUP BY mon
),
peak_day AS (
    /* 并列峰值取最早日期 */
    SELECT mon, MIN(dt) AS peak_dt
    FROM daily d
    WHERE day_cnt = (
        SELECT MAX(d2.day_cnt)
        FROM daily d2
        WHERE d2.mon = d.mon
    )
    GROUP BY mon
)
SELECT
    m.mon AS 月份,
    ROUND(m.month_cnt / 10000.0, 4) AS 线上运单量_万单,
    ROUND(m.month_cnt / 10000.0 / m.day_n, 4) AS 日均运单量_万单,
    ROUND(m.peak_cnt / 10000.0, 4) AS 日峰值_万单,
    p.peak_dt AS 峰值日,
    ROUND(
        m.peak_cnt * 1.0 / NULLIF(LAG(m.peak_cnt) OVER (ORDER BY m.mon), 0) - 1,
        4
    ) AS 峰值环比
FROM month_agg m
LEFT JOIN peak_day p ON m.mon = p.mon
ORDER BY m.mon;
