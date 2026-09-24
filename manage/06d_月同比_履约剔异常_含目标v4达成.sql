/* 运单量 MTD：本月 vs 上月同期 | 履约剔异常（新口径同 01c） | 含目标v4达成度
 * 异常口径 type_ab（履约新口径，同 01c/06c）：
 *   - 行程异常标签：司机近30天行程异常（含 -剔除）
 *   - 线上申诉：中(100/300/310/410/500)；成功(400)；失败(110/200/320/440)
 *   - 汇总仅排除 异常剔除 + 申诉中；申诉成功计入履约
 * 目标来源：飞书「目标v4」wiki SovCwkvzCiH80MkJWURc6L47nme / Sheet1
 *   v1线上目标拆解（8月=实际基准；9–12月=v1目标）：
 *   - 线上合计 / 四举措（裂变=货主招募）/ 线上×类型 / 举措×类型
 * 达成度 = 本月MTD运单量 / 月目标；无目标维度（整体/线下/无线下等）输出 NULL
 * 时间进度 = 截止日序 / 当月天数；相对时间进度 = 达成度 / 时间进度
 */
WITH tim AS (
    SELECT
        DATE '2026-01-01' AS range_start,
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS as_of_dt   /* 统计截止日，右闭；可改成 DATE '2026-08-16' */
),
/* ===== 目标v4 · v1线上拆解（万单）| mon=月初 · dim_key=层级维度 =====
 * 列：8月实际 / 9 / 10 / 11 / 12；裂变→货主招募
 */
month_target AS (
    /* ----- 线上合计（校验行） ----- */
    SELECT DATE '2026-08-01' AS mon, '线上线下-线上' AS dim_key, 23.25 AS target_wan UNION ALL
    SELECT DATE '2026-09-01', '线上线下-线上', 44.80 UNION ALL
    SELECT DATE '2026-10-01', '线上线下-线上', 56.60 UNION ALL
    SELECT DATE '2026-11-01', '线上线下-线上', 66.80 UNION ALL
    SELECT DATE '2026-12-01', '线上线下-线上', 84.30 UNION ALL
    /* ----- 线上举措合计（裂变=货主招募） ----- */
    SELECT DATE '2026-08-01', '线上举措-货主招募', 0.22  UNION ALL
    SELECT DATE '2026-09-01', '线上举措-货主招募', 5.34  UNION ALL
    SELECT DATE '2026-10-01', '线上举措-货主招募', 8.08  UNION ALL
    SELECT DATE '2026-11-01', '线上举措-货主招募', 10.99 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-货主招募', 15.74 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-电销', 5.49  UNION ALL
    SELECT DATE '2026-09-01', '线上举措-电销', 7.42  UNION ALL
    SELECT DATE '2026-10-01', '线上举措-电销', 9.64  UNION ALL
    SELECT DATE '2026-11-01', '线上举措-电销', 11.83 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-电销', 15.52 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-投流', 7.95  UNION ALL
    SELECT DATE '2026-09-01', '线上举措-投流', 20.47 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-投流', 24.44 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-投流', 27.61 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-投流', 33.54 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-调度', 9.35  UNION ALL
    SELECT DATE '2026-09-01', '线上举措-调度', 11.57 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-调度', 14.44 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-调度', 16.37 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-调度', 19.50 UNION ALL
    /* ----- 线上 × 运单类型 ----- */
    SELECT DATE '2026-08-01', '线上-TMS', 12.68 UNION ALL
    SELECT DATE '2026-09-01', '线上-TMS', 21.95 UNION ALL
    SELECT DATE '2026-10-01', '线上-TMS', 28.86 UNION ALL
    SELECT DATE '2026-11-01', '线上-TMS', 33.40 UNION ALL
    SELECT DATE '2026-12-01', '线上-TMS', 42.15 UNION ALL
    SELECT DATE '2026-08-01', '线上-撮合', 6.04  UNION ALL
    SELECT DATE '2026-09-01', '线上-撮合', 14.34 UNION ALL
    SELECT DATE '2026-10-01', '线上-撮合', 19.25 UNION ALL
    SELECT DATE '2026-11-01', '线上-撮合', 22.05 UNION ALL
    SELECT DATE '2026-12-01', '线上-撮合', 28.67 UNION ALL
    SELECT DATE '2026-08-01', '线上-网货', 4.53  UNION ALL
    SELECT DATE '2026-09-01', '线上-网货', 8.51  UNION ALL
    SELECT DATE '2026-10-01', '线上-网货', 8.49  UNION ALL
    SELECT DATE '2026-11-01', '线上-网货', 11.35 UNION ALL
    SELECT DATE '2026-12-01', '线上-网货', 13.49 UNION ALL
    /* ----- 线上举措 × 运单类型 ----- */
    SELECT DATE '2026-08-01', '线上举措-货主招募-TMS', 0.02 UNION ALL
    SELECT DATE '2026-09-01', '线上举措-货主招募-TMS', 2.62 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-货主招募-TMS', 4.12 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-货主招募-TMS', 5.49 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-货主招募-TMS', 7.87 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-货主招募-撮合', 0.20 UNION ALL
    SELECT DATE '2026-09-01', '线上举措-货主招募-撮合', 1.71 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-货主招募-撮合', 2.74 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-货主招募-撮合', 3.62 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-货主招募-撮合', 5.35 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-货主招募-网货', 0.00 UNION ALL
    SELECT DATE '2026-09-01', '线上举措-货主招募-网货', 1.02 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-货主招募-网货', 1.21 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-货主招募-网货', 1.87 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-货主招募-网货', 2.52 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-电销-TMS', 2.84 UNION ALL
    SELECT DATE '2026-09-01', '线上举措-电销-TMS', 3.64 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-电销-TMS', 4.92 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-电销-TMS', 5.92 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-电销-TMS', 7.76 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-电销-撮合', 1.63 UNION ALL
    SELECT DATE '2026-09-01', '线上举措-电销-撮合', 2.38 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-电销-撮合', 3.28 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-电销-撮合', 3.90 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-电销-撮合', 5.28 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-电销-网货', 1.02 UNION ALL
    SELECT DATE '2026-09-01', '线上举措-电销-网货', 1.41 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-电销-网货', 1.45 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-电销-网货', 2.01 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-电销-网货', 2.49 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-投流-TMS', 2.29 UNION ALL
    SELECT DATE '2026-09-01', '线上举措-投流-TMS', 10.02 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-投流-TMS', 12.47 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-投流-TMS', 13.81 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-投流-TMS', 16.77 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-投流-撮合', 3.33 UNION ALL
    SELECT DATE '2026-09-01', '线上举措-投流-撮合', 6.55 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-投流-撮合', 8.31 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-投流-撮合', 9.11 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-投流-撮合', 11.40 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-投流-网货', 2.33 UNION ALL
    SELECT DATE '2026-09-01', '线上举措-投流-网货', 3.89 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-投流-网货', 3.66 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-投流-网货', 4.70 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-投流-网货', 5.36 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-调度-TMS', 7.52 UNION ALL
    SELECT DATE '2026-09-01', '线上举措-调度-TMS', 5.67 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-调度-TMS', 7.37 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-调度-TMS', 8.18 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-调度-TMS', 9.74 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-调度-撮合', 0.85 UNION ALL
    SELECT DATE '2026-09-01', '线上举措-调度-撮合', 3.71 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-调度-撮合', 4.91 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-调度-撮合', 5.40 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-调度-撮合', 6.63 UNION ALL
    SELECT DATE '2026-08-01', '线上举措-调度-网货', 0.98 UNION ALL
    SELECT DATE '2026-09-01', '线上举措-调度-网货', 2.19 UNION ALL
    SELECT DATE '2026-10-01', '线上举措-调度-网货', 2.16 UNION ALL
    SELECT DATE '2026-11-01', '线上举措-调度-网货', 2.78 UNION ALL
    SELECT DATE '2026-12-01', '线上举措-调度-网货', 3.12
),
/* ===== 异常运单判定（履约新口径，同 01c） ===== */
ab_raw AS (
    SELECT
        ab.waybill_id,
        CASE
            WHEN scenario_tags LIKE '%账号登录异常-剔除%'
              OR scenario_tags LIKE '%同时段履约多单-剔除%'
              OR scenario_tags LIKE '%装卸货打卡异常-剔除%'
              OR scenario_tags LIKE '%司机近30天行程异常-剔除%'
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
        OR scenario_tags LIKE '%司机近30天行程异常%'
        OR scenario_tags LIKE '%账号登录异常%'
        OR scenario_tags LIKE '%同时段履约多单-剔除%'
        OR scenario_tags LIKE '%运单间隔过短%'
    )
),
ab AS (
    /* 同一运单多标签：任一剔除即剔除 */
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
            WHEN appl_status IN (100, 300, 310, 410, 500) THEN '申诉中'   /* 100待推送 500已作废 */
            WHEN appl_status IN (400) THEN '申诉成功'
            WHEN appl_status IN (110, 200, 320, 440) THEN '申诉失败'
            ELSE CAST(appl_status AS STRING)
        END AS 是否申诉成功
    FROM ads.ads_vlsp_mt_match_waybill_high_abnormal_detail_info_minf
),
ss AS (
    /* 多来源冲突：申诉成功 > 申诉中 > 申诉失败 */
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
    /* 剔除异常：异常剔除 + 申诉中；申诉成功 / 未命中场景不算异常 */
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
        DAY(LAST_DAY(m.mon)) AS mon_days,
        DATE_SUB(m.mon, INTERVAL 1 MONTH) AS prev_mon,
        t.as_of_dt
    FROM month_spine m
    CROSS JOIN tim t
),
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        DATE(waybill.unload_time) AS unload_day,
        DATE_FORMAT(waybill.unload_time, '%Y-%m-01') AS mon,
        DAY(waybill.unload_time) AS unload_dom,
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
    FROM dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    CROSS JOIN tim t
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    WHERE DATE(waybill.unload_time) >= DATE_SUB(t.range_start, INTERVAL 1 MONTH)
      AND DATE(waybill.unload_time) <= t.as_of_dt
      AND waybill.load_time IS NOT NULL
      AND waybill.unload_time IS NOT NULL
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
        wh.waybill_id, wh.mon, wh.unload_dom, wh.waybill_category,
        wh.hit_offline, wh.hit_zm, wh.hit_tl, wh.hit_dx, wh.hit_dd, wh.hit_wxx,
        CASE WHEN wh.hit_zm  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN wh.hit_tl  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN wh.hit_dx  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN wh.hit_dd  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_dd,
        CASE WHEN wh.hit_wxx = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_wxx
    FROM waybill_hit wh
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = wh.waybill_id
    WHERE abn.waybill_id IS NULL
),
agg_cur AS (
    SELECT
        mm.mon,
        ws.waybill_category,
        COUNT(DISTINCT ws.waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN ws.hit_offline = 1 THEN ws.waybill_id END) AS offline_cnt,
        COUNT(DISTINCT CASE WHEN ws.hit_zm + ws.hit_tl + ws.hit_dx + ws.hit_dd + ws.hit_wxx > 0 THEN ws.waybill_id END) AS online_cnt,
        SUM(ws.w_zm) AS zm_cnt, SUM(ws.w_tl) AS tl_cnt, SUM(ws.w_dx) AS dx_cnt,
        SUM(ws.w_dd) AS dd_cnt, SUM(ws.w_wxx) AS wxx_cnt
    FROM month_meta mm
    JOIN waybill_split ws
        ON ws.mon = mm.mon
       AND ws.unload_dom <= mm.cutoff_dom
    GROUP BY mm.mon, ws.waybill_category
),
agg_prev AS (
    SELECT
        mm.mon,
        ws.waybill_category,
        COUNT(DISTINCT ws.waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN ws.hit_offline = 1 THEN ws.waybill_id END) AS offline_cnt,
        COUNT(DISTINCT CASE WHEN ws.hit_zm + ws.hit_tl + ws.hit_dx + ws.hit_dd + ws.hit_wxx > 0 THEN ws.waybill_id END) AS online_cnt,
        SUM(ws.w_zm) AS zm_cnt, SUM(ws.w_tl) AS tl_cnt, SUM(ws.w_dx) AS dx_cnt,
        SUM(ws.w_dd) AS dd_cnt, SUM(ws.w_wxx) AS wxx_cnt
    FROM month_meta mm
    JOIN waybill_split ws
        ON ws.mon = mm.prev_mon
       AND ws.unload_dom <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
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
    SELECT c.mon, '整体' AS stat_level, '整体' AS stat_dim,
           c.total_cnt AS cnt_cur, COALESCE(p.total_cnt, 0) AS cnt_prev
    FROM agg_cur_all c
    LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL
    SELECT c.mon, '整体', c.waybill_category, c.total_cnt, COALESCE(p.total_cnt, 0)
    FROM agg_cur c
    LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL
    SELECT c.mon, '线上线下', '线下', c.offline_cnt, COALESCE(p.offline_cnt, 0)
    FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL
    SELECT c.mon, '线上线下', '线上', c.online_cnt, COALESCE(p.online_cnt, 0)
    FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL
    SELECT c.mon, '线上', '线上', c.online_cnt, COALESCE(p.online_cnt, 0)
    FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL
    SELECT c.mon, '线上', c.waybill_category, c.online_cnt, COALESCE(p.online_cnt, 0)
    FROM agg_cur c
    LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '线上举措', '货主招募', c.zm_cnt, COALESCE(p.zm_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '线上举措', '投流', c.tl_cnt, COALESCE(p.tl_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '线上举措', '电销', c.dx_cnt, COALESCE(p.dx_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '线上举措', '调度', c.dd_cnt, COALESCE(p.dd_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '线上举措', '无线下销售归属', c.wxx_cnt, COALESCE(p.wxx_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '线上举措', CONCAT('货主招募-', c.waybill_category), c.zm_cnt, COALESCE(p.zm_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '线上举措', CONCAT('投流-', c.waybill_category), c.tl_cnt, COALESCE(p.tl_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '线上举措', CONCAT('电销-', c.waybill_category), c.dx_cnt, COALESCE(p.dx_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '线上举措', CONCAT('调度-', c.waybill_category), c.dd_cnt, COALESCE(p.dd_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '线上举措', CONCAT('无线下销售归属-', c.waybill_category), c.wxx_cnt, COALESCE(p.wxx_cnt, 0) FROM agg_cur c LEFT JOIN agg_prev p ON p.mon = c.mon AND p.waybill_category = c.waybill_category
    UNION ALL SELECT c.mon, '举措', '货主招募', c.zm_cnt, COALESCE(p.zm_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '举措', '投流', c.tl_cnt, COALESCE(p.tl_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '举措', '电销', c.dx_cnt, COALESCE(p.dx_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '举措', '调度', c.dd_cnt, COALESCE(p.dd_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '举措', '无线下销售归属', c.wxx_cnt, COALESCE(p.wxx_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
    UNION ALL SELECT c.mon, '举措', '线下', c.offline_cnt, COALESCE(p.offline_cnt, 0) FROM agg_cur_all c LEFT JOIN agg_prev_all p ON p.mon = c.mon
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
    ) AS 较上月同期,
    tg.target_wan AS 月目标_万单,
    ROUND(
        (r.cnt_cur / 10000.0) / NULLIF(tg.target_wan, 0),
        4
    ) AS 目标达成度,
    ROUND(mm.cutoff_dom * 1.0 / mm.mon_days, 4) AS 时间进度,
    ROUND(
        ((r.cnt_cur / 10000.0) / NULLIF(tg.target_wan, 0))
        / NULLIF(mm.cutoff_dom * 1.0 / mm.mon_days, 0),
        4
    ) AS 相对时间进度
FROM result r
JOIN month_meta mm ON mm.mon = r.mon
LEFT JOIN month_target tg
    ON tg.mon = r.mon
   AND tg.dim_key = CASE
        /* 别名对齐整合表标签 */
        WHEN r.stat_level = '线上' AND r.stat_dim = '线上' THEN '线上线下-线上'
        WHEN r.stat_level = '举措' AND r.stat_dim = '线下' THEN '线上线下-线下'
        WHEN r.stat_level = '举措'
         AND (
             r.stat_dim IN ('货主招募', '投流', '电销', '调度')
             OR r.stat_dim LIKE '货主招募-%'
             OR r.stat_dim LIKE '投流-%'
             OR r.stat_dim LIKE '电销-%'
             OR r.stat_dim LIKE '调度-%'
         )
        THEN CONCAT('线上举措-', r.stat_dim)
        ELSE CONCAT(r.stat_level, '-', r.stat_dim)
    END
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
