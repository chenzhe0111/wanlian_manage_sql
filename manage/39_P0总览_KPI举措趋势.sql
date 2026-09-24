/* P0 总览页 | 线上举措目标看板
 * 对齐：https://wanlianyida.feishu.cn/docx/EoZsdyEhjocuafxAzYvc6f4PnAh §三
 * 口径：运单同 01_月度汇总；发货货主同 05
 *
 * 改数入口：
 *   tim.mon / tim.as_of_dt     — 统计月、截止日（默认 T-1）
 *   target_cfg                 — 月目标，对齐目标 Excel
 *
 * 产出 section：
 *   meta / kpi / initiative / trend_daily
 *
 * 红绿灯：完成率 vs 时间进度 ±2pp → 红/绿；结构任一类型偏差 >5pp → 红
 */

WITH tim AS (
    SELECT
        DATE '2026-08-01' AS mon,
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS as_of_dt
),
target_cfg AS (
    SELECT
        /* 线上运单卡 = 四举措合计目标（万单） */
        35.19  AS tgt_online_wb_wan,
        0.08   AS tgt_online_share,           /* 线上占比 */
        1565   AS tgt_shipper_cnt,            /* 发货货主·家 */
        /* 结构健康：线上运单类型目标占比（按 Excel 改撮合/网货） */
        0.41   AS tgt_share_tms,
        0.35   AS tgt_share_cuohe,
        0.24   AS tgt_share_wanghuo,
        /* 四举措运单目标（万单） */
        3.33   AS tgt_zm,
        17.25  AS tgt_tl,
        5.81   AS tgt_dx,
        8.80   AS tgt_dd
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
month_meta AS (
    SELECT
        t.mon,
        LEAST(t.as_of_dt, LAST_DAY(t.mon)) AS as_of_dt,
        DAY(LEAST(t.as_of_dt, LAST_DAY(t.mon))) AS cutoff_dom,
        DAY(LAST_DAY(t.mon)) AS days_in_month,
        DAY(LEAST(t.as_of_dt, LAST_DAY(t.mon))) * 1.0
            / DAY(LAST_DAY(t.mon)) AS time_progress
    FROM tim t
),
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        DATE(waybill.accept_dt) AS accept_day,
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
    CROSS JOIN month_meta mm
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    WHERE DATE(waybill.accept_dt) >= mm.mon
      AND DATE(waybill.accept_dt) <= mm.as_of_dt
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
        waybill_id, accept_day, waybill_category,
        hit_offline, hit_zm, hit_tl, hit_dx, hit_dd, hit_wxx,
        CASE WHEN hit_zm  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN hit_tl  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN hit_dx  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN hit_dd  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dd,
        CASE WHEN hit_wxx = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_wxx
    FROM waybill_hit
),
agg_month AS (
    SELECT
        COUNT(DISTINCT waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN hit_offline = 1 THEN waybill_id END) AS offline_cnt,
        COUNT(DISTINCT CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN waybill_id END) AS online_cnt,
        SUM(w_zm) AS zm_cnt,
        SUM(w_tl) AS tl_cnt,
        SUM(w_dx) AS dx_cnt,
        SUM(w_dd) AS dd_cnt,
        SUM(w_wxx) AS wxx_cnt,
        COUNT(DISTINCT CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0
                             AND waybill_category = 'TMS'  THEN waybill_id END) AS online_tms,
        COUNT(DISTINCT CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0
                             AND waybill_category = '撮合' THEN waybill_id END) AS online_cuohe,
        COUNT(DISTINCT CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0
                             AND waybill_category = '网货' THEN waybill_id END) AS online_wanghuo
    FROM waybill_split
),
agg_day AS (
    SELECT
        accept_day AS dt,
        COUNT(DISTINCT waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN waybill_id END) AS online_cnt,
        SUM(w_zm) AS zm_cnt,
        SUM(w_tl) AS tl_cnt,
        SUM(w_dx) AS dx_cnt,
        SUM(w_dd) AS dd_cnt,
        SUM(w_wxx) AS wxx_cnt
    FROM waybill_split
    GROUP BY accept_day
),
tms_waybill AS (
    SELECT
        SUBSTR(waybill_create_time, 1, 10) AS ship_dt,
        shipper_company_id AS company_id
    FROM dwd_vlsp_mt_match_waybill_tms_business_process_minf
    WHERE NVL(shipper_company_id, '') NOT IN (
              '065d39e9afac48d8a0bdc5896c18d96c', '1993982792389951488',
              '1993985265305452544', '1994003031330062336'
          )
      AND tms_flag = 10
    GROUP BY 1, 2
),
goods AS (
    SELECT
        SUBSTR(create_dt, 1, 10) AS ship_dt,
        publish_company_id AS company_id
    FROM dwd_vlsp_mt_em_goods_manage_info_minf
    WHERE goods_status <> 10
      AND NVL(publish_company_id, '') NOT IN (
              '065d39e9afac48d8a0bdc5896c18d96c', '1993982792389951488',
              '1993985265305452544', '1994003031330062336'
          )
      AND goods_id NOT IN ('CHQY20251204000000016246', 'CHQY20251211000000012094')
    GROUP BY 1, 2
),
ship_event AS (
    SELECT ship_dt, company_id FROM tms_waybill
    UNION
    SELECT ship_dt, company_id FROM goods
),
company_info AS (
    SELECT company_id, company_name
    FROM dwd_vlsp_mt_em_company_manage_info_minf
    WHERE company_id IS NOT NULL
      AND is_fake_company_apply_user = '0'
    GROUP BY 1, 2
),
ship_online AS (
    SELECT DISTINCT s.company_id
    FROM ship_event s
    CROSS JOIN month_meta mm
    INNER JOIN company_info ci ON ci.company_id = s.company_id
    LEFT JOIN company_zm  ON company_zm.invitee_id = s.company_id
    LEFT JOIN company_tl  ON company_tl.company_id = s.company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = ci.company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = ci.company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = s.company_id
    WHERE DATE(s.ship_dt) >= mm.mon
      AND DATE(s.ship_dt) <= mm.as_of_dt
      AND (
          company_wxx.sales_lv1_company_id IS NOT NULL
          OR NVL(ci.company_name, '') NOT IN (
              SELECT DISTINCT dept_name FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
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
shipper_month AS (
    SELECT COUNT(*) AS shipper_cnt FROM ship_online
),
kpi_base AS (
    SELECT
        mm.mon,
        mm.as_of_dt,
        mm.time_progress,
        (a.zm_cnt + a.tl_cnt + a.dx_cnt + a.dd_cnt) / 10000.0 AS four_wb_wan,
        a.online_cnt / 10000.0 AS online_wb_wan,
        a.total_cnt / 10000.0 AS total_wb_wan,
        a.online_cnt * 1.0 / NULLIF(a.total_cnt, 0) AS online_share,
        a.zm_cnt / 10000.0 AS zm_wan,
        a.tl_cnt / 10000.0 AS tl_wan,
        a.dx_cnt / 10000.0 AS dx_wan,
        a.dd_cnt / 10000.0 AS dd_wan,
        a.online_tms * 1.0 / NULLIF(a.online_cnt, 0) AS share_tms,
        a.online_cuohe * 1.0 / NULLIF(a.online_cnt, 0) AS share_cuohe,
        a.online_wanghuo * 1.0 / NULLIF(a.online_cnt, 0) AS share_wanghuo,
        s.shipper_cnt,
        tg.tgt_online_wb_wan,
        tg.tgt_online_share,
        tg.tgt_shipper_cnt,
        tg.tgt_share_tms,
        tg.tgt_share_cuohe,
        tg.tgt_share_wanghuo,
        tg.tgt_zm,
        tg.tgt_tl,
        tg.tgt_dx,
        tg.tgt_dd
    FROM month_meta mm
    CROSS JOIN agg_month a
    CROSS JOIN shipper_month s
    CROSS JOIN target_cfg tg
)
SELECT
    section AS 模块,
    metric AS 指标,
    label AS 展示文案,
    ROUND(actual_num, 6) AS 实际,
    ROUND(target_num, 6) AS 目标,
    ROUND(completion_rate, 4) AS 完成率,
    ROUND(gap_num, 4) AS 缺口或偏差,
    ROUND(vs_progress_pp, 4) AS vs时间进度pp,
    status AS 红绿灯,
    remark AS 备注,
    dt AS 日期,
    ROUND(online_share_d, 6) AS 当日线上占比,
    ROUND(zm_wan_d, 4) AS 当日货主招募万单,
    ROUND(tl_wan_d, 4) AS 当日投流万单,
    ROUND(dx_wan_d, 4) AS 当日电销万单,
    ROUND(dd_wan_d, 4) AS 当日调度万单
FROM (
    /* —— meta —— */
    SELECT
        'meta' AS section, 0 AS sort_key, '统计窗' AS metric,
        CONCAT(DATE_FORMAT(mon, '%Y-%m'), ' · 截至', MONTH(as_of_dt), '/', DAY(as_of_dt)) AS label,
        time_progress AS actual_num,
        CAST(NULL AS DOUBLE) AS target_num,
        time_progress AS completion_rate,
        CAST(NULL AS DOUBLE) AS gap_num,
        CAST(NULL AS DOUBLE) AS vs_progress_pp,
        CAST(NULL AS STRING) AS status,
        CONCAT('时间进度 ', ROUND(time_progress * 100, 1), '%') AS remark,
        CAST(NULL AS DATE) AS dt,
        CAST(NULL AS DOUBLE) AS online_share_d,
        CAST(NULL AS DOUBLE) AS zm_wan_d,
        CAST(NULL AS DOUBLE) AS tl_wan_d,
        CAST(NULL AS DOUBLE) AS dx_wan_d,
        CAST(NULL AS DOUBLE) AS dd_wan_d
    FROM kpi_base

    UNION ALL
    /* 线上运单 = 四举措合计（对齐目标卡；remark 附线上去重/整体） */
    SELECT
        'kpi', 1, '线上运单',
        CONCAT(ROUND(four_wb_wan, 3), '万/', ROUND(tgt_online_wb_wan, 2), '万'),
        four_wb_wan, tgt_online_wb_wan,
        four_wb_wan / NULLIF(tgt_online_wb_wan, 0),
        tgt_online_wb_wan - four_wb_wan,
        four_wb_wan / NULLIF(tgt_online_wb_wan, 0) - time_progress,
        CASE
            WHEN four_wb_wan / NULLIF(tgt_online_wb_wan, 0) < time_progress - 0.02 THEN '红'
            WHEN four_wb_wan / NULLIF(tgt_online_wb_wan, 0) > time_progress + 0.02 THEN '绿'
            ELSE '黄'
        END,
        CONCAT('线上去重 ', ROUND(online_wb_wan, 3), '万；整体 ', ROUND(total_wb_wan, 3), '万'),
        CAST(NULL AS DATE), NULL, NULL, NULL, NULL, NULL
    FROM kpi_base

    UNION ALL
    SELECT
        'kpi', 2, '线上占比',
        CONCAT(ROUND(online_share * 100, 2), '%/', ROUND(tgt_online_share * 100, 1), '%'),
        online_share, tgt_online_share,
        online_share / NULLIF(tgt_online_share, 0),
        (online_share - tgt_online_share) * 100,   /* 正=超目标 pp */
        online_share / NULLIF(tgt_online_share, 0) - time_progress,
        CASE
            WHEN online_share / NULLIF(tgt_online_share, 0) < time_progress - 0.02 THEN '红'
            WHEN online_share / NULLIF(tgt_online_share, 0) > time_progress + 0.02 THEN '绿'
            ELSE '黄'
        END,
        '线上去重运单/整体运单',
        CAST(NULL AS DATE), NULL, NULL, NULL, NULL, NULL
    FROM kpi_base

    UNION ALL
    SELECT
        'kpi', 3, '发货货主',
        CONCAT(CAST(shipper_cnt AS STRING), '/', CAST(tgt_shipper_cnt AS STRING)),
        shipper_cnt * 1.0, tgt_shipper_cnt * 1.0,
        shipper_cnt * 1.0 / NULLIF(tgt_shipper_cnt, 0),
        (tgt_shipper_cnt - shipper_cnt) * 1.0,
        shipper_cnt * 1.0 / NULLIF(tgt_shipper_cnt, 0) - time_progress,
        CASE
            WHEN shipper_cnt * 1.0 / NULLIF(tgt_shipper_cnt, 0) < time_progress - 0.02 THEN '红'
            WHEN shipper_cnt * 1.0 / NULLIF(tgt_shipper_cnt, 0) > time_progress + 0.02 THEN '绿'
            ELSE '黄'
        END,
        '当月发货去重·线上（同05）',
        CAST(NULL AS DATE), NULL, NULL, NULL, NULL, NULL
    FROM kpi_base

    UNION ALL
    SELECT
        'kpi', 4, '结构健康',
        CONCAT(
            'TMS ', ROUND(share_tms * 100, 0), '%',
            ' 撮合 ', ROUND(share_cuohe * 100, 0), '%',
            ' 网货 ', ROUND(share_wanghuo * 100, 0), '%'
        ),
        share_tms, tgt_share_tms,
        CAST(NULL AS DOUBLE),
        GREATEST(
            ABS(share_tms - tgt_share_tms),
            ABS(share_cuohe - tgt_share_cuohe),
            ABS(share_wanghuo - tgt_share_wanghuo)
        ) * 100,                                 /* 最大偏差 pp */
        (share_tms - tgt_share_tms) * 100,       /* TMS vs 目标 pp */
        CASE
            WHEN GREATEST(
                     ABS(share_tms - tgt_share_tms),
                     ABS(share_cuohe - tgt_share_cuohe),
                     ABS(share_wanghuo - tgt_share_wanghuo)
                 ) > 0.05 THEN '红'
            ELSE '绿'
        END,
        CONCAT(
            '目标 TMS', ROUND(tgt_share_tms * 100, 0), '%',
            '/撮合', ROUND(tgt_share_cuohe * 100, 0), '%',
            '/网货', ROUND(tgt_share_wanghuo * 100, 0), '%'
        ),
        CAST(NULL AS DATE), NULL, NULL, NULL, NULL, NULL
    FROM kpi_base

    UNION ALL
    SELECT 'initiative', 10, '货主招募',
        CONCAT(ROUND(zm_wan, 3), '/', ROUND(tgt_zm, 2)),
        zm_wan, tgt_zm, zm_wan / NULLIF(tgt_zm, 0), tgt_zm - zm_wan,
        zm_wan / NULLIF(tgt_zm, 0) - time_progress,
        CASE
            WHEN zm_wan / NULLIF(tgt_zm, 0) < time_progress - 0.02 THEN '红'
            WHEN zm_wan / NULLIF(tgt_zm, 0) > time_progress + 0.02 THEN '绿'
            ELSE '黄'
        END,
        CONCAT('vs进度 ', ROUND((zm_wan / NULLIF(tgt_zm, 0) - time_progress) * 100, 1), 'pp'),
        CAST(NULL AS DATE), NULL, NULL, NULL, NULL, NULL
    FROM kpi_base
    UNION ALL
    SELECT 'initiative', 11, '投流',
        CONCAT(ROUND(tl_wan, 3), '/', ROUND(tgt_tl, 2)),
        tl_wan, tgt_tl, tl_wan / NULLIF(tgt_tl, 0), tgt_tl - tl_wan,
        tl_wan / NULLIF(tgt_tl, 0) - time_progress,
        CASE
            WHEN tl_wan / NULLIF(tgt_tl, 0) < time_progress - 0.02 THEN '红'
            WHEN tl_wan / NULLIF(tgt_tl, 0) > time_progress + 0.02 THEN '绿'
            ELSE '黄'
        END,
        CONCAT('vs进度 ', ROUND((tl_wan / NULLIF(tgt_tl, 0) - time_progress) * 100, 1), 'pp'),
        CAST(NULL AS DATE), NULL, NULL, NULL, NULL, NULL
    FROM kpi_base
    UNION ALL
    SELECT 'initiative', 12, '电销',
        CONCAT(ROUND(dx_wan, 3), '/', ROUND(tgt_dx, 2)),
        dx_wan, tgt_dx, dx_wan / NULLIF(tgt_dx, 0), tgt_dx - dx_wan,
        dx_wan / NULLIF(tgt_dx, 0) - time_progress,
        CASE
            WHEN dx_wan / NULLIF(tgt_dx, 0) < time_progress - 0.02 THEN '红'
            WHEN dx_wan / NULLIF(tgt_dx, 0) > time_progress + 0.02 THEN '绿'
            ELSE '黄'
        END,
        CONCAT('vs进度 ', ROUND((dx_wan / NULLIF(tgt_dx, 0) - time_progress) * 100, 1), 'pp'),
        CAST(NULL AS DATE), NULL, NULL, NULL, NULL, NULL
    FROM kpi_base
    UNION ALL
    SELECT 'initiative', 13, '调度',
        CONCAT(ROUND(dd_wan, 3), '/', ROUND(tgt_dd, 2)),
        dd_wan, tgt_dd, dd_wan / NULLIF(tgt_dd, 0), tgt_dd - dd_wan,
        dd_wan / NULLIF(tgt_dd, 0) - time_progress,
        CASE
            WHEN dd_wan / NULLIF(tgt_dd, 0) < time_progress - 0.02 THEN '红'
            WHEN dd_wan / NULLIF(tgt_dd, 0) > time_progress + 0.02 THEN '绿'
            ELSE '黄'
        END,
        CONCAT('vs进度 ', ROUND((dd_wan / NULLIF(tgt_dd, 0) - time_progress) * 100, 1), 'pp'),
        CAST(NULL AS DATE), NULL, NULL, NULL, NULL, NULL
    FROM kpi_base

    UNION ALL
    /* 日趋势：实际=当日线上万单；目标列空；完成率空 */
    SELECT
        'trend_daily',
        100 + DATEDIFF(d.dt, kb.mon),
        '日趋势',
        DATE_FORMAT(d.dt, '%m/%d'),
        d.online_cnt / 10000.0,
        CAST(NULL AS DOUBLE),
        CAST(NULL AS DOUBLE),
        CAST(NULL AS DOUBLE),
        CAST(NULL AS DOUBLE),
        CAST(NULL AS STRING),
        CONCAT('整体', ROUND(d.total_cnt / 10000.0, 4), '万'),
        d.dt,
        d.online_cnt * 1.0 / NULLIF(d.total_cnt, 0),
        d.zm_cnt / 10000.0,
        d.tl_cnt / 10000.0,
        d.dx_cnt / 10000.0,
        d.dd_cnt / 10000.0
    FROM agg_day d
    CROSS JOIN kpi_base kb
) u
ORDER BY
    CASE section
        WHEN 'meta' THEN 1
        WHEN 'kpi' THEN 2
        WHEN 'initiative' THEN 3
        WHEN 'trend_daily' THEN 4
        ELSE 9
    END,
    sort_key;
