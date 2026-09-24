/* 月度汇总 | 本月 vs 上月同期 | 线上不含线下
 * 基于 01_月度汇总：表结构/过滤/等权分摊不变
 * 差异：线上与线下互斥 —— 命中线下线索的运单只计入线下，不再计入线上及线上举措
 *       即 online = (命中线上标签) AND hit_offline=0
 *       校验：线上 + 线下 = 整体（去重后互斥）
 * 本月：该月 1 日～截止日；上月同期：上月 1 日～上月同日
 */
WITH tim AS (
    SELECT
        DATE '2026-01-01' AS range_start,
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS as_of_dt   /* 统计截止日，右闭；可改成 DATE '2026-08-16' */
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
        /* 信息流投放 */
        SELECT a.user_id
        FROM dwd_vlsp_mt_bt_advertise_placement_business_process_minf a
        WHERE a.user_id <> ''
        UNION
        /* 拼表单投放 */
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
/* 输出月份：range_start 所在月 ～ as_of 所在月 */
month_spine AS (
    SELECT
        DATE_FORMAT(DATE_ADD(t.range_start, INTERVAL n.n MONTH), '%Y-%m-01') AS mon
    FROM tim t
    JOIN (
        SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
        UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
        UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11
    ) n
        ON DATE_ADD(t.range_start, INTERVAL n.n MONTH)
           <= DATE_FORMAT(t.as_of_dt, '%Y-%m-01')
),
month_meta AS (
    SELECT
        m.mon,
        CASE
            WHEN m.mon = DATE_FORMAT(t.as_of_dt, '%Y-%m-01') THEN DAY(t.as_of_dt)
            ELSE DAY(LAST_DAY(m.mon))
        END AS cutoff_dom,
        DATE_SUB(m.mon, INTERVAL 1 MONTH) AS prev_mon,
        t.as_of_dt
    FROM month_spine m
    CROSS JOIN tim t
),
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        DATE(waybill.accept_dt) AS accept_day,
        DATE_FORMAT(waybill.accept_dt, '%Y-%m-01') AS mon,
        DAY(waybill.accept_dt) AS accept_dom,
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
    CROSS JOIN tim t
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    WHERE DATE(waybill.accept_dt) >= DATE_SUB(t.range_start, INTERVAL 1 MONTH)  /* 含首月的上月同期 */
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
        waybill_id, mon, accept_dom, waybill_category,
        hit_offline, hit_zm, hit_tl, hit_dx, hit_dd, hit_wxx,
        /* 仅非线下才分摊到线上举措；与线下重合的运单权重归 0 */
        CASE WHEN hit_offline = 0 AND hit_zm  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN hit_offline = 0 AND hit_tl  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN hit_offline = 0 AND hit_dx  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN hit_offline = 0 AND hit_dd  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dd,
        CASE WHEN hit_offline = 0 AND hit_wxx = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_wxx
    FROM waybill_hit
),
/* 本月：落在 mon 且日序 ≤ cutoff_dom */
agg_cur AS (
    SELECT
        mm.mon,
        ws.waybill_category,
        COUNT(DISTINCT ws.waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN ws.hit_offline = 1 THEN ws.waybill_id END) AS offline_cnt,
        COUNT(DISTINCT CASE WHEN ws.hit_offline = 0 AND ws.hit_zm + ws.hit_tl + ws.hit_dx + ws.hit_dd + ws.hit_wxx > 0 THEN ws.waybill_id END) AS online_cnt,
        SUM(ws.w_zm) AS zm_cnt, SUM(ws.w_tl) AS tl_cnt, SUM(ws.w_dx) AS dx_cnt,
        SUM(ws.w_dd) AS dd_cnt, SUM(ws.w_wxx) AS wxx_cnt
    FROM month_meta mm
    JOIN waybill_split ws
        ON ws.mon = mm.mon
       AND ws.accept_dom <= mm.cutoff_dom
    GROUP BY mm.mon, ws.waybill_category
),
/* 上月同期：落在 prev_mon 且日序 ≤ LEAST(cutoff_dom, 上月天数) */
agg_prev AS (
    SELECT
        mm.mon,
        ws.waybill_category,
        COUNT(DISTINCT ws.waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN ws.hit_offline = 1 THEN ws.waybill_id END) AS offline_cnt,
        COUNT(DISTINCT CASE WHEN ws.hit_offline = 0 AND ws.hit_zm + ws.hit_tl + ws.hit_dx + ws.hit_dd + ws.hit_wxx > 0 THEN ws.waybill_id END) AS online_cnt,
        SUM(ws.w_zm) AS zm_cnt, SUM(ws.w_tl) AS tl_cnt, SUM(ws.w_dx) AS dx_cnt,
        SUM(ws.w_dd) AS dd_cnt, SUM(ws.w_wxx) AS wxx_cnt
    FROM month_meta mm
    JOIN waybill_split ws
        ON ws.mon = mm.prev_mon
       AND ws.accept_dom <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon, ws.waybill_category
),
agg_cur_all AS (
    SELECT
        mon,
        SUM(total_cnt) AS total_cnt, SUM(offline_cnt) AS offline_cnt, SUM(online_cnt) AS online_cnt,
        SUM(zm_cnt) AS zm_cnt, SUM(tl_cnt) AS tl_cnt, SUM(dx_cnt) AS dx_cnt,
        SUM(dd_cnt) AS dd_cnt, SUM(wxx_cnt) AS wxx_cnt
    FROM agg_cur
    GROUP BY mon
),
agg_prev_all AS (
    SELECT
        mon,
        SUM(total_cnt) AS total_cnt, SUM(offline_cnt) AS offline_cnt, SUM(online_cnt) AS online_cnt,
        SUM(zm_cnt) AS zm_cnt, SUM(tl_cnt) AS tl_cnt, SUM(dx_cnt) AS dx_cnt,
        SUM(dd_cnt) AS dd_cnt, SUM(wxx_cnt) AS wxx_cnt
    FROM agg_prev
    GROUP BY mon
),
result AS (
    /* ===== 整体：合计 + 运单类型 ===== */
    SELECT c.mon, '整体' AS stat_level, '整体' AS stat_dim,
           c.total_cnt AS cnt_cur, COALESCE(p.total_cnt, 0) AS cnt_prev
    FROM agg_cur_all c
    LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL
    SELECT c.mon, '整体', c.waybill_category, c.total_cnt, COALESCE(p.total_cnt, 0)
    FROM agg_cur c
    LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    /* ===== 线上线下 ===== */
    UNION ALL
    SELECT c.mon, '线上线下', '线下', c.offline_cnt, COALESCE(p.offline_cnt, 0)
    FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL
    SELECT c.mon, '线上线下', '线上', c.online_cnt, COALESCE(p.online_cnt, 0)
    FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    /* ===== 线上 + 运单类型 ===== */
    UNION ALL
    SELECT c.mon, '线上', '线上', c.online_cnt, COALESCE(p.online_cnt, 0)
    FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL
    SELECT c.mon, '线上', c.waybill_category, c.online_cnt, COALESCE(p.online_cnt, 0)
    FROM agg_cur c
    LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    /* ===== 线上举措：合计 ===== */
    UNION ALL SELECT c.mon, '线上举措', '货主招募', c.zm_cnt, COALESCE(p.zm_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '线上举措', '投流', c.tl_cnt, COALESCE(p.tl_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '线上举措', '电销', c.dx_cnt, COALESCE(p.dx_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '线上举措', '调度', c.dd_cnt, COALESCE(p.dd_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '线上举措', '无线下销售归属', c.wxx_cnt, COALESCE(p.wxx_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    /* ===== 线上举措 × 运单类型 ===== */
    UNION ALL SELECT c.mon, '线上举措', CONCAT('货主招募-', c.waybill_category), c.zm_cnt, COALESCE(p.zm_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '线上举措', CONCAT('投流-', c.waybill_category), c.tl_cnt, COALESCE(p.tl_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '线上举措', CONCAT('电销-', c.waybill_category), c.dx_cnt, COALESCE(p.dx_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '线上举措', CONCAT('调度-', c.waybill_category), c.dd_cnt, COALESCE(p.dd_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '线上举措', CONCAT('无线下销售归属-', c.waybill_category), c.wxx_cnt, COALESCE(p.wxx_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    /* ===== 举措：合计 ===== */
    UNION ALL SELECT c.mon, '举措', '货主招募', c.zm_cnt, COALESCE(p.zm_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '举措', '投流', c.tl_cnt, COALESCE(p.tl_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '举措', '电销', c.dx_cnt, COALESCE(p.dx_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '举措', '调度', c.dd_cnt, COALESCE(p.dd_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '举措', '无线下销售归属', c.wxx_cnt, COALESCE(p.wxx_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '举措', '线下', c.offline_cnt, COALESCE(p.offline_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    /* ===== 举措 × 运单类型 ===== */
    UNION ALL SELECT c.mon, '举措', CONCAT('货主招募-', c.waybill_category), c.zm_cnt, COALESCE(p.zm_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '举措', CONCAT('投流-', c.waybill_category), c.tl_cnt, COALESCE(p.tl_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '举措', CONCAT('电销-', c.waybill_category), c.dx_cnt, COALESCE(p.dx_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '举措', CONCAT('调度-', c.waybill_category), c.dd_cnt, COALESCE(p.dd_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '举措', CONCAT('无线下销售归属-', c.waybill_category), c.wxx_cnt, COALESCE(p.wxx_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '举措', CONCAT('线下-', c.waybill_category), c.offline_cnt, COALESCE(p.offline_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
)
SELECT
    r.mon AS 月份,
    mm.cutoff_dom AS 截止日序,
    r.stat_level AS 统计层级,
    r.stat_dim AS 维度,
    CONCAT(r.stat_level, '-', r.stat_dim) AS 层级维度,
    ROUND(r.cnt_cur / 10000, 4) AS 运单量,
    ROUND(r.cnt_prev / 10000, 4) AS 上月同期运单量,
    ROUND(
        (r.cnt_cur - r.cnt_prev) * 1.0 / NULLIF(r.cnt_prev, 0),
        4
    ) AS 较上月同期
FROM result r
JOIN month_meta mm ON mm.mon = r.mon
ORDER BY
    r.mon,
    CASE r.stat_level
        WHEN '整体' THEN 1
        WHEN '线上线下' THEN 2
        WHEN '线上' THEN 3
        WHEN '线上举措' THEN 4
        WHEN '举措' THEN 5
        ELSE 99
    END,
    CASE
        WHEN r.stat_dim = '整体' THEN 0
        WHEN r.stat_dim = '线上' THEN 1
        WHEN r.stat_dim = '线下' THEN 2
        WHEN r.stat_dim = '货主招募' THEN 10
        WHEN r.stat_dim = '投流' THEN 11
        WHEN r.stat_dim = '电销' THEN 12
        WHEN r.stat_dim = '调度' THEN 13
        WHEN r.stat_dim = '无线下销售归属' THEN 14
        WHEN r.stat_dim = '网货' THEN 20
        WHEN r.stat_dim = 'TMS' THEN 21
        WHEN r.stat_dim = '撮合' THEN 22
        WHEN r.stat_dim LIKE '货主招募-%' THEN 30
        WHEN r.stat_dim LIKE '投流-%' THEN 31
        WHEN r.stat_dim LIKE '电销-%' THEN 32
        WHEN r.stat_dim LIKE '调度-%' THEN 33
        WHEN r.stat_dim LIKE '无线下销售归属-%' THEN 34
        WHEN r.stat_dim LIKE '线下-%' THEN 35
        ELSE 99
    END,
    r.stat_dim;
