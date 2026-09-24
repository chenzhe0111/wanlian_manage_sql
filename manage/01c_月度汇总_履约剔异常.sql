/* 月度汇总 | 履约新口径 + 剔除异常运单 | 本月 vs 上月同期
 * 相对 01_月度汇总.sql（成交 accept_dt）的差异：
 *   1) 时间轴：unload_time（履约卸货日），且 load_time / unload_time 均非空
 *   2) 异常口径（type_ab，履约新口径；02c/03d/04c/05c/06c 对齐本块）：
 *      - 异常剔除 = 标签「剔除」OR（「下发」且申诉失败）
 *      - 申诉中   = 「下发」且（无申诉记录 OR 申诉中）
 *      - 申诉成功 = 「下发」且申诉成功 → 计入履约
 *      - 未命中异常场景 = 履约（保留）
 *      汇总仅排除 异常剔除 + 申诉中
 *      行程异常标签：司机近30天行程异常（含 -剔除）
 *      线上申诉：中(100/300/310/410/500)；成功(400)；失败(110/200/320/440)
 *   3) 同运单多标签 / 多申诉来源去重（任一剔除即剔除；申诉成功>申诉中>申诉失败）
 * 其余：线下线索 OR 非微信主体；五举措等权分摊；输出结构同 01
 * 本月：该月 1 日～截止日；上月同期：上月 1 日～上月同日
 * 司机（月级，不按举措/运单类型拆）：
 *   当月新增注册司机数 = 该月 1 日～截止日注册成功（register_status=1，按手机号去重）
 *   累积注册司机数 = 注册日 ≤ 该月截止日的全部成功注册（含 2026 年前存量）
 */
WITH tim AS (
    SELECT
        DATE '2026-01-01' AS range_start,
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS as_of_dt   /* 统计截止日，右闭；可改成 DATE '2026-08-16' */
),
/* ===== 异常运单判定（履约新口径） ===== */
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
/* 注册成功司机：同一手机号取最早注册日 */
registered_driver AS (
    SELECT
        telephone,
        MIN(DATE(create_date)) AS register_dt
    FROM dwd_vlsp_mt_em_driver_manage_info_minf
    CROSS JOIN tim t
    WHERE register_status = 1
      AND telephone IS NOT NULL
      AND telephone <> ''
      AND create_date IS NOT NULL
      AND DATE(create_date) <= t.as_of_dt
    GROUP BY telephone
),
driver_new AS (
    SELECT
        mm.mon,
        COUNT(DISTINCT d.telephone) AS new_drv
    FROM month_meta mm
    JOIN registered_driver d
        ON DATE_FORMAT(d.register_dt, '%Y-%m-01') = mm.mon
       AND DAY(d.register_dt) <= mm.cutoff_dom
    GROUP BY mm.mon
),
driver_cum AS (
    SELECT
        mm.mon,
        COUNT(DISTINCT d.telephone) AS cum_drv
    FROM month_meta mm
    JOIN registered_driver d
        ON d.register_dt <= DATE_ADD(mm.mon, INTERVAL (mm.cutoff_dom - 1) DAY)
    GROUP BY mm.mon
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
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    CROSS JOIN tim t
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    WHERE DATE(waybill.unload_time) >= DATE_SUB(t.range_start, INTERVAL 1 MONTH)  /* 含首月的上月同期 */
      AND DATE(waybill.unload_time) <= t.as_of_dt
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
        wh.waybill_id, wh.mon, wh.unload_dom, wh.waybill_category,
        wh.hit_offline, wh.hit_zm, wh.hit_tl, wh.hit_dx, wh.hit_dd, wh.hit_wxx,
        CASE WHEN wh.hit_zm  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN wh.hit_tl  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN wh.hit_dx  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN wh.hit_dd  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_dd,
        CASE WHEN wh.hit_wxx = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_wxx
    FROM waybill_hit wh
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = wh.waybill_id
    /* 剔除异常：排除 异常剔除 + 申诉中；申诉成功 / 未命中异常场景保留 */
    WHERE abn.waybill_id IS NULL
),
/* 本月：落在 mon 且日序 ≤ cutoff_dom */
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
/* 上月同期：落在 prev_mon 且日序 ≤ LEAST(cutoff_dom, 上月天数) */
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
    ) AS 较上月同期,
    COALESCE(dn.new_drv, 0) AS 当月新增注册司机数,
    COALESCE(dc.cum_drv, 0) AS 累积注册司机数
FROM result r
JOIN month_meta mm ON mm.mon = r.mon
LEFT JOIN driver_new dn ON dn.mon = r.mon
LEFT JOIN driver_cum dc ON dc.mon = r.mon
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
