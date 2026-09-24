/* 2026年5–8月：整体 / 线上 / 自闭环 七指标核对（双口径）
 * 口径：
 *   A) 成交（accept_dt）— 同 01 / 01b / 41
 *   B) 履约剔异常（unload_time）— 同 01c：
 *      - 时间轴：unload_time（load/unload 均非空）
 *      - 剔除：异常剔除 + 申诉中；申诉成功 / 未命中异常场景保留
 *   - 整体 = 过滤后全部运单
 *   - 线上（01）= 命中线上五标签任一（可与线下重叠）
 *   - 自闭环（01b）= 线上且 hit_offline=0（不含线下）
 *   - 峰值 = 月内单日最大值（万单）；日均 = 月量 / 月天数
 *
 * 8月目标值（成交口径对照，见末列）：峰值4.47 | 线上17.60/0.57/0.09 | 峰值线上2.07% | 线上量21.43% | 自闭环28.43%
 */
WITH month_spine AS (
    SELECT DATE '2026-05-01' AS mon, 31 AS day_n, DATE '2026-05-01' AS mon_start, DATE '2026-05-31' AS mon_end
    UNION ALL SELECT DATE '2026-06-01', 30, DATE '2026-06-01', DATE '2026-06-30'
    UNION ALL SELECT DATE '2026-07-01', 31, DATE '2026-07-01', DATE '2026-07-31'
    UNION ALL SELECT DATE '2026-08-01', 31, DATE '2026-08-01', DATE '2026-08-31'
),
/* ===== 异常运单判定（履约口径，同 01c） ===== */
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
    FROM ads.ads_vlsp_mt_match_waybill_abnormal_detail_info_df ab
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
            WHEN appl_status IN (300, 410, 310, 420, 100, 500) THEN '申诉中'
            WHEN appl_status IN (400, 430) THEN '申诉成功'
            WHEN appl_status IN (200, 320, 440) THEN '申诉失败'
            ELSE CAST(appl_status AS STRING)
        END AS 是否申诉成功
    FROM ads.ads_vlsp_mt_match_waybill_high_abnormal_detail_info_minf
),
ss AS (
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
waybill_base AS (
    SELECT
        waybill.waybill_id,
        waybill.load_time,
        waybill.unload_time,
        CAST(waybill.accept_dt AS DATE) AS accept_dt,
        CAST(waybill.unload_time AS DATE) AS unload_dt,
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
    WHERE (
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
      AND (
          DATE(waybill.accept_dt) BETWEEN DATE '2026-05-01' AND DATE '2026-08-31'
          OR DATE(waybill.unload_time) BETWEEN DATE '2026-05-01' AND DATE '2026-08-31'
      )
),
/* ===== A) 成交口径 ===== */
waybill_accept AS (
    SELECT wb.*
    FROM waybill_base wb
    JOIN month_spine ms
        ON wb.accept_dt BETWEEN ms.mon_start AND ms.mon_end
),
daily_accept AS (
    SELECT
        ms.mon,
        ms.day_n,
        wb.accept_dt AS dt,
        COUNT(DISTINCT wb.waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE
            WHEN wb.hit_zm + wb.hit_tl + wb.hit_dx + wb.hit_dd + wb.hit_wxx > 0
            THEN wb.waybill_id
        END) AS online_cnt,
        COUNT(DISTINCT CASE
            WHEN wb.hit_offline = 0
             AND wb.hit_zm + wb.hit_tl + wb.hit_dx + wb.hit_dd + wb.hit_wxx > 0
            THEN wb.waybill_id
        END) AS zibihuan_cnt
    FROM waybill_accept wb
    JOIN month_spine ms
        ON wb.accept_dt BETWEEN ms.mon_start AND ms.mon_end
    GROUP BY ms.mon, ms.day_n, wb.accept_dt
),
/* ===== B) 履约剔异常口径 ===== */
waybill_unload AS (
    SELECT wb.*
    FROM waybill_base wb
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = wb.waybill_id
    JOIN month_spine ms
        ON wb.unload_dt BETWEEN ms.mon_start AND ms.mon_end
    WHERE wb.load_time IS NOT NULL
      AND wb.unload_time IS NOT NULL
      AND abn.waybill_id IS NULL
),
daily_unload AS (
    SELECT
        ms.mon,
        ms.day_n,
        wb.unload_dt AS dt,
        COUNT(DISTINCT wb.waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE
            WHEN wb.hit_zm + wb.hit_tl + wb.hit_dx + wb.hit_dd + wb.hit_wxx > 0
            THEN wb.waybill_id
        END) AS online_cnt,
        COUNT(DISTINCT CASE
            WHEN wb.hit_offline = 0
             AND wb.hit_zm + wb.hit_tl + wb.hit_dx + wb.hit_dd + wb.hit_wxx > 0
            THEN wb.waybill_id
        END) AS zibihuan_cnt
    FROM waybill_unload wb
    JOIN month_spine ms
        ON wb.unload_dt BETWEEN ms.mon_start AND ms.mon_end
    GROUP BY ms.mon, ms.day_n, wb.unload_dt
),
daily_all AS (
    SELECT '成交' AS caliber, mon, day_n, dt, total_cnt, online_cnt, zibihuan_cnt FROM daily_accept
    UNION ALL
    SELECT '履约剔异常', mon, day_n, dt, total_cnt, online_cnt, zibihuan_cnt FROM daily_unload
),
month_agg AS (
    SELECT
        caliber,
        mon,
        day_n,
        SUM(total_cnt) AS total_month_cnt,
        SUM(online_cnt) AS online_month_cnt,
        SUM(zibihuan_cnt) AS zibihuan_month_cnt,
        MAX(total_cnt) AS total_peak_cnt,
        MAX(online_cnt) AS online_peak_cnt,
        MAX(zibihuan_cnt) AS zibihuan_peak_cnt
    FROM daily_all
    GROUP BY caliber, mon, day_n
),
total_peak_day AS (
    SELECT d.caliber, d.mon, MIN(d.dt) AS total_peak_dt
    FROM daily_all d
    JOIN month_agg m
        ON m.caliber = d.caliber
       AND m.mon = d.mon
       AND d.total_cnt = m.total_peak_cnt
    GROUP BY d.caliber, d.mon
),
online_peak_day AS (
    SELECT d.caliber, d.mon, MIN(d.dt) AS online_peak_dt
    FROM daily_all d
    JOIN month_agg m
        ON m.caliber = d.caliber
       AND m.mon = d.mon
       AND d.online_cnt = m.online_peak_cnt
    GROUP BY d.caliber, d.mon
),
zibihuan_peak_day AS (
    SELECT d.caliber, d.mon, MIN(d.dt) AS zibihuan_peak_dt
    FROM daily_all d
    JOIN month_agg m
        ON m.caliber = d.caliber
       AND m.mon = d.mon
       AND d.zibihuan_cnt = m.zibihuan_peak_cnt
    GROUP BY d.caliber, d.mon
)
SELECT
    m.caliber AS 口径,
    DATE_FORMAT(m.mon, '%Y-%m') AS 月份,
    m.day_n AS 统计天数,

    /* ===== 整体 ===== */
    ROUND(m.total_month_cnt / 10000.0, 2) AS 整体运单量_万单,
    ROUND(m.total_month_cnt / 10000.0 / m.day_n, 2) AS 整体日均_万单,
    ROUND(m.total_peak_cnt / 10000.0, 2) AS 整体峰值_万单,
    tp.total_peak_dt AS 整体峰值日,

    /* ===== 线上（01，可与线下重叠） ===== */
    ROUND(m.online_month_cnt / 10000.0, 2) AS 线上运单量_万单,
    ROUND(m.online_month_cnt / 10000.0 / m.day_n, 2) AS 线上日均_万单,
    ROUND(m.online_peak_cnt / 10000.0, 2) AS 线上峰值_万单,
    op.online_peak_dt AS 线上峰值日,

    /* ===== 自闭环（01b，线上不含线下） ===== */
    ROUND(m.zibihuan_month_cnt / 10000.0, 2) AS 自闭环运单量_万单,
    ROUND(m.zibihuan_month_cnt / 10000.0 / m.day_n, 2) AS 自闭环日均_万单,
    ROUND(m.zibihuan_peak_cnt / 10000.0, 2) AS 自闭环峰值_万单,
    zp.zibihuan_peak_dt AS 自闭环峰值日,

    /* ===== 占比 ===== */
    CONCAT(ROUND(m.online_peak_cnt * 100.0 / NULLIF(m.total_peak_cnt, 0), 2), '%') AS 峰值线上占比,
    CONCAT(ROUND(m.online_month_cnt * 100.0 / NULLIF(m.total_month_cnt, 0), 2), '%') AS 线上量占比,
    CONCAT(ROUND(m.zibihuan_month_cnt * 100.0 / NULLIF(m.online_month_cnt, 0), 2), '%') AS 自闭环占线上,
    CONCAT(ROUND(m.zibihuan_month_cnt * 100.0 / NULLIF(m.total_month_cnt, 0), 2), '%') AS 自闭环占整体,
    CONCAT(ROUND(m.zibihuan_peak_cnt * 100.0 / NULLIF(m.total_peak_cnt, 0), 2), '%') AS 峰值自闭环占比,

    /* ===== 8月目标值（成交口径对照，仅 2026-08 成交行有值） ===== */
    CASE WHEN m.caliber = '成交' AND m.mon = DATE '2026-08-01' THEN 4.47 END AS 目标_峰值运单量_万单,
    CASE WHEN m.caliber = '成交' AND m.mon = DATE '2026-08-01' THEN 17.60 END AS 目标_线上运单量_万单,
    CASE WHEN m.caliber = '成交' AND m.mon = DATE '2026-08-01' THEN 0.57 END AS 目标_线上日均_万单,
    CASE WHEN m.caliber = '成交' AND m.mon = DATE '2026-08-01' THEN 0.09 END AS 目标_线上峰值_万单,
    CASE WHEN m.caliber = '成交' AND m.mon = DATE '2026-08-01' THEN '2.07%' END AS 目标_峰值线上占比,
    CASE WHEN m.caliber = '成交' AND m.mon = DATE '2026-08-01' THEN '21.43%' END AS 目标_线上量占比,
    CASE WHEN m.caliber = '成交' AND m.mon = DATE '2026-08-01' THEN '28.43%' END AS 目标_自闭环运单占比
FROM month_agg m
LEFT JOIN total_peak_day tp
    ON tp.caliber = m.caliber AND tp.mon = m.mon
LEFT JOIN online_peak_day op
    ON op.caliber = m.caliber AND op.mon = m.mon
LEFT JOIN zibihuan_peak_day zp
    ON zp.caliber = m.caliber AND zp.mon = m.mon
ORDER BY
    m.mon,
    CASE m.caliber WHEN '成交' THEN 1 WHEN '履约剔异常' THEN 2 ELSE 99 END;

/* 日明细（排查峰值日，改 caliber / 月份后取消注释）
-- SELECT caliber AS 口径, mon AS 月份, dt AS 日期, total_cnt AS 整体, online_cnt AS 线上, zibihuan_cnt AS 自闭环
-- FROM daily_all
-- WHERE mon = DATE '2026-08-01'
-- ORDER BY caliber, dt;
*/
