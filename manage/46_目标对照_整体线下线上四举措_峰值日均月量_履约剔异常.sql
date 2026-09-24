/* 目标表 sheet1 对照取数 | 整体 / 运单类型 / 线下线上 / 四举措 / 举措×新老
 * 对齐飞书：wiki/JGW0wwgczijA1Gk6mJ1cUcdWnmg?sheet=1074dd（整合表）
 *
 * 口径（履约剔异常，同 01c / 03c）：
 *   1) 时间轴：unload_time（load/unload 均非空）
 *   2) 剔除：异常剔除 + 申诉中；申诉成功 / 未命中异常场景保留
 *   3) 整体 = 过滤后全部运单（去重）
 *   4) 运单类型：invoice_type=20→网货；invoice_type=10且tms_flag=10→TMS；其余→撮合
 *   5) 线下 = hit_offline=1（销售线索）
 *   6) 线上 = 命中五标签任一（裂变/投流/电销/调度/无线下），可与线下重叠（同 01c）
 *   7) 四举措 = 等权分摊（分母含无线下命中，同 01c）；本输出仅四举措行（不含无线下）
 *   8) 新老（同 03c）：货主历史首活日 first_dt（TMS创建∪货源发布）≥ 卸货月月初 → 新货主，否则老货主
 *
 * 维度（长表）：
 *   - 整体；整体-网货/撮合/TMS
 *   - 线下；线上；线上-网货/撮合/TMS
 *   - 货主招募/电销/投流/调度（合计）
 *   - 四举措各自 × 新货主/老货主
 *
 * 指标：
 *   - 月运单量_万单 / 日均_万单 / 日峰值_万单 / 峰值日
 *   - 月GTV_亿 / 客单价_元（金额字段同 07：freight_transact_amount；
 *     GTV_亿 = SUM(运费)/1e8；客单价 = SUM(运费)/运单量；举措行按等权分摊权重加权）
 *
 * 改日期：改 tim.range_start / as_of_dt
 */
WITH tim AS (
    SELECT
        DATE '2026-08-01' AS range_start,                 /* 对照目标从 8 月起；可改 2026-01-01 */
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS as_of_dt
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
            WHEN appl_status IN (100, 300, 310, 410, 500) THEN '申诉中'
            WHEN appl_status IN (400) THEN '申诉成功'
            WHEN appl_status IN (110, 200, 320, 440) THEN '申诉失败'
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
/* ===== 货主首活日（同 03c，用于新老） ===== */
tms_waybill AS (
    SELECT waybill_create_time, shipper_company_id, waybill_id
    FROM dwd_vlsp_mt_match_waybill_tms_business_process_minf
    WHERE COALESCE(shipper_company_id, '') NOT IN (
        '065d39e9afac48d8a0bdc5896c18d96c',
        '1993982792389951488',
        '1993985265305452544',
        '1994003031330062336'
    )
      AND tms_flag = 10
    GROUP BY 1, 2, 3
),
goods AS (
    SELECT create_dt, publish_company_id, goods_id
    FROM dwd_vlsp_mt_em_goods_manage_info_minf
    WHERE goods_status <> 10
      AND COALESCE(publish_company_id, '') NOT IN (
        '065d39e9afac48d8a0bdc5896c18d96c',
        '1993982792389951488',
        '1993985265305452544',
        '1994003031330062336'
      )
      AND goods_id NOT IN ('CHQY20251204000000016246', 'CHQY20251211000000012094')
    GROUP BY 1, 2, 3
),
base AS (
    SELECT DATE(waybill_create_time) AS create_dt, shipper_company_id AS company_id
    FROM tms_waybill
    UNION
    SELECT create_dt, publish_company_id AS company_id
    FROM goods
),
company_first AS (
    SELECT company_id, create_dt AS first_dt
    FROM (
        SELECT
            company_id,
            create_dt,
            ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY create_dt) AS rn
        FROM base
    ) t
    WHERE rn = 1
),
/* ===== 举措归属 ===== */
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
    SELECT DATE_FORMAT(DATE_ADD(t.range_start, INTERVAL n.n MONTH), '%Y-%m-01') AS mon
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
        END AS day_n,
        t.as_of_dt
    FROM month_spine m
    CROSS JOIN tim t
),
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        DATE(waybill.unload_time) AS dt,
        DATE_FORMAT(waybill.unload_time, '%Y-%m-01') AS mon,
        CASE
            WHEN waybill.invoice_type = 20 THEN '网货'
            WHEN waybill.invoice_type = 10 AND waybill.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_category,
        CASE
            WHEN cf.first_dt IS NULL THEN NULL
            WHEN cf.first_dt >= DATE_FORMAT(waybill.unload_time, '%Y-%m-01') THEN '新货主'
            ELSE '老货主'
        END AS shipper_type,
        /* 同 07：运费成交额（元）→ GTV / 客单价 */
        NVL(waybill.freight_transact_amount, 0) AS freight_amt,
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
    LEFT JOIN company_first cf ON cf.company_id = waybill.shipper_company_id
    WHERE DATE(waybill.unload_time) >= t.range_start
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
waybill_ok AS (
    SELECT wh.*
    FROM waybill_hit wh
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = wh.waybill_id
    WHERE abn.waybill_id IS NULL
),
waybill_split AS (
    SELECT
        waybill_id, dt, mon, waybill_category, shipper_type, freight_amt,
        hit_offline, hit_zm, hit_tl, hit_dx, hit_dd, hit_wxx,
        /* 等权分摊：分母含无线下（同 01c） */
        CASE WHEN hit_zm  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN hit_tl  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN hit_dx  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN hit_dd  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dd
    FROM waybill_ok
),
/* ===== 月 GTV（元）：同维度切分；举措按权重分摊运费 ===== */
month_money AS (
    SELECT
        mon,
        SUM(freight_amt) AS total_gtv,
        SUM(CASE WHEN waybill_category = '网货' THEN freight_amt ELSE 0 END) AS total_wh_gtv,
        SUM(CASE WHEN waybill_category = '撮合' THEN freight_amt ELSE 0 END) AS total_ch_gtv,
        SUM(CASE WHEN waybill_category = 'TMS'  THEN freight_amt ELSE 0 END) AS total_tms_gtv,
        SUM(CASE WHEN hit_offline = 1 THEN freight_amt ELSE 0 END) AS offline_gtv,
        SUM(CASE
            WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN freight_amt ELSE 0
        END) AS online_gtv,
        SUM(CASE
            WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 AND waybill_category = '网货'
            THEN freight_amt ELSE 0
        END) AS online_wh_gtv,
        SUM(CASE
            WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 AND waybill_category = '撮合'
            THEN freight_amt ELSE 0
        END) AS online_ch_gtv,
        SUM(CASE
            WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 AND waybill_category = 'TMS'
            THEN freight_amt ELSE 0
        END) AS online_tms_gtv,
        SUM(w_zm * freight_amt) AS zm_gtv,
        SUM(w_tl * freight_amt) AS tl_gtv,
        SUM(w_dx * freight_amt) AS dx_gtv,
        SUM(w_dd * freight_amt) AS dd_gtv,
        SUM(CASE WHEN shipper_type = '新货主' THEN w_zm * freight_amt ELSE 0 END) AS zm_new_gtv,
        SUM(CASE WHEN shipper_type = '老货主' THEN w_zm * freight_amt ELSE 0 END) AS zm_old_gtv,
        SUM(CASE WHEN shipper_type = '新货主' THEN w_tl * freight_amt ELSE 0 END) AS tl_new_gtv,
        SUM(CASE WHEN shipper_type = '老货主' THEN w_tl * freight_amt ELSE 0 END) AS tl_old_gtv,
        SUM(CASE WHEN shipper_type = '新货主' THEN w_dx * freight_amt ELSE 0 END) AS dx_new_gtv,
        SUM(CASE WHEN shipper_type = '老货主' THEN w_dx * freight_amt ELSE 0 END) AS dx_old_gtv,
        SUM(CASE WHEN shipper_type = '新货主' THEN w_dd * freight_amt ELSE 0 END) AS dd_new_gtv,
        SUM(CASE WHEN shipper_type = '老货主' THEN w_dd * freight_amt ELSE 0 END) AS dd_old_gtv
    FROM waybill_split
    GROUP BY mon
),
/* ===== 天粒度：整体 / 类型 / 线下线上 / 四举措 / 举措×新老 ===== */
daily AS (
    SELECT
        dt,
        mon,
        COUNT(DISTINCT waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN waybill_category = '网货' THEN waybill_id END) AS total_wh_cnt,
        COUNT(DISTINCT CASE WHEN waybill_category = '撮合' THEN waybill_id END) AS total_ch_cnt,
        COUNT(DISTINCT CASE WHEN waybill_category = 'TMS'  THEN waybill_id END) AS total_tms_cnt,
        COUNT(DISTINCT CASE WHEN hit_offline = 1 THEN waybill_id END) AS offline_cnt,
        COUNT(DISTINCT CASE
            WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN waybill_id
        END) AS online_cnt,
        COUNT(DISTINCT CASE
            WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 AND waybill_category = '网货' THEN waybill_id
        END) AS online_wh_cnt,
        COUNT(DISTINCT CASE
            WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 AND waybill_category = '撮合' THEN waybill_id
        END) AS online_ch_cnt,
        COUNT(DISTINCT CASE
            WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 AND waybill_category = 'TMS' THEN waybill_id
        END) AS online_tms_cnt,
        SUM(w_zm) AS zm_cnt,
        SUM(w_tl) AS tl_cnt,
        SUM(w_dx) AS dx_cnt,
        SUM(w_dd) AS dd_cnt,
        SUM(CASE WHEN shipper_type = '新货主' THEN w_zm ELSE 0 END) AS zm_new_cnt,
        SUM(CASE WHEN shipper_type = '老货主' THEN w_zm ELSE 0 END) AS zm_old_cnt,
        SUM(CASE WHEN shipper_type = '新货主' THEN w_tl ELSE 0 END) AS tl_new_cnt,
        SUM(CASE WHEN shipper_type = '老货主' THEN w_tl ELSE 0 END) AS tl_old_cnt,
        SUM(CASE WHEN shipper_type = '新货主' THEN w_dx ELSE 0 END) AS dx_new_cnt,
        SUM(CASE WHEN shipper_type = '老货主' THEN w_dx ELSE 0 END) AS dx_old_cnt,
        SUM(CASE WHEN shipper_type = '新货主' THEN w_dd ELSE 0 END) AS dd_new_cnt,
        SUM(CASE WHEN shipper_type = '老货主' THEN w_dd ELSE 0 END) AS dd_old_cnt
    FROM waybill_split
    GROUP BY dt, mon
),
month_agg AS (
    SELECT
        mon,
        SUM(total_cnt)      AS total_month,
        SUM(total_wh_cnt)   AS total_wh_month,
        SUM(total_ch_cnt)   AS total_ch_month,
        SUM(total_tms_cnt)  AS total_tms_month,
        SUM(offline_cnt)    AS offline_month,
        SUM(online_cnt)     AS online_month,
        SUM(online_wh_cnt)  AS online_wh_month,
        SUM(online_ch_cnt)  AS online_ch_month,
        SUM(online_tms_cnt) AS online_tms_month,
        SUM(zm_cnt)         AS zm_month,
        SUM(tl_cnt)         AS tl_month,
        SUM(dx_cnt)         AS dx_month,
        SUM(dd_cnt)         AS dd_month,
        SUM(zm_new_cnt)     AS zm_new_month,
        SUM(zm_old_cnt)     AS zm_old_month,
        SUM(tl_new_cnt)     AS tl_new_month,
        SUM(tl_old_cnt)     AS tl_old_month,
        SUM(dx_new_cnt)     AS dx_new_month,
        SUM(dx_old_cnt)     AS dx_old_month,
        SUM(dd_new_cnt)     AS dd_new_month,
        SUM(dd_old_cnt)     AS dd_old_month,
        MAX(total_cnt)      AS total_peak,
        MAX(total_wh_cnt)   AS total_wh_peak,
        MAX(total_ch_cnt)   AS total_ch_peak,
        MAX(total_tms_cnt)  AS total_tms_peak,
        MAX(offline_cnt)    AS offline_peak,
        MAX(online_cnt)     AS online_peak,
        MAX(online_wh_cnt)  AS online_wh_peak,
        MAX(online_ch_cnt)  AS online_ch_peak,
        MAX(online_tms_cnt) AS online_tms_peak,
        MAX(zm_cnt)         AS zm_peak,
        MAX(tl_cnt)         AS tl_peak,
        MAX(dx_cnt)         AS dx_peak,
        MAX(dd_cnt)         AS dd_peak,
        MAX(zm_new_cnt)     AS zm_new_peak,
        MAX(zm_old_cnt)     AS zm_old_peak,
        MAX(tl_new_cnt)     AS tl_new_peak,
        MAX(tl_old_cnt)     AS tl_old_peak,
        MAX(dx_new_cnt)     AS dx_new_peak,
        MAX(dx_old_cnt)     AS dx_old_peak,
        MAX(dd_new_cnt)     AS dd_new_peak,
        MAX(dd_old_cnt)     AS dd_old_peak
    FROM daily
    GROUP BY mon
),
peak_day AS (
    SELECT mon, '整体' AS dim, MIN(dt) AS peak_dt
    FROM daily d WHERE total_cnt = (SELECT MAX(d2.total_cnt) FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '整体-网货', MIN(dt) FROM daily d WHERE total_wh_cnt  = (SELECT MAX(d2.total_wh_cnt)  FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '整体-撮合', MIN(dt) FROM daily d WHERE total_ch_cnt  = (SELECT MAX(d2.total_ch_cnt)  FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '整体-TMS',  MIN(dt) FROM daily d WHERE total_tms_cnt = (SELECT MAX(d2.total_tms_cnt) FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '线下',      MIN(dt) FROM daily d WHERE offline_cnt   = (SELECT MAX(d2.offline_cnt)   FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '线上',      MIN(dt) FROM daily d WHERE online_cnt    = (SELECT MAX(d2.online_cnt)    FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '线上-网货', MIN(dt) FROM daily d WHERE online_wh_cnt = (SELECT MAX(d2.online_wh_cnt) FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '线上-撮合', MIN(dt) FROM daily d WHERE online_ch_cnt = (SELECT MAX(d2.online_ch_cnt) FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '线上-TMS',  MIN(dt) FROM daily d WHERE online_tms_cnt= (SELECT MAX(d2.online_tms_cnt)FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '货主招募',  MIN(dt) FROM daily d WHERE zm_cnt        = (SELECT MAX(d2.zm_cnt)        FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '电销',      MIN(dt) FROM daily d WHERE dx_cnt        = (SELECT MAX(d2.dx_cnt)        FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '投流',      MIN(dt) FROM daily d WHERE tl_cnt        = (SELECT MAX(d2.tl_cnt)        FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '调度',      MIN(dt) FROM daily d WHERE dd_cnt        = (SELECT MAX(d2.dd_cnt)        FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '货主招募-新货主', MIN(dt) FROM daily d WHERE zm_new_cnt = (SELECT MAX(d2.zm_new_cnt) FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '货主招募-老货主', MIN(dt) FROM daily d WHERE zm_old_cnt = (SELECT MAX(d2.zm_old_cnt) FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '电销-新货主',     MIN(dt) FROM daily d WHERE dx_new_cnt = (SELECT MAX(d2.dx_new_cnt) FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '电销-老货主',     MIN(dt) FROM daily d WHERE dx_old_cnt = (SELECT MAX(d2.dx_old_cnt) FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '投流-新货主',     MIN(dt) FROM daily d WHERE tl_new_cnt = (SELECT MAX(d2.tl_new_cnt) FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '投流-老货主',     MIN(dt) FROM daily d WHERE tl_old_cnt = (SELECT MAX(d2.tl_old_cnt) FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '调度-新货主',     MIN(dt) FROM daily d WHERE dd_new_cnt = (SELECT MAX(d2.dd_new_cnt) FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
    UNION ALL SELECT mon, '调度-老货主',     MIN(dt) FROM daily d WHERE dd_old_cnt = (SELECT MAX(d2.dd_old_cnt) FROM daily d2 WHERE d2.mon = d.mon) GROUP BY mon
),
long_raw AS (
    SELECT a.mon, '整体'     AS 维度层级, '整体'            AS 维度,
           a.total_month AS month_cnt, a.total_peak AS peak_cnt, m.total_gtv AS gtv_yuan
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '运单类型', '整体-网货', a.total_wh_month, a.total_wh_peak, m.total_wh_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '运单类型', '整体-撮合', a.total_ch_month, a.total_ch_peak, m.total_ch_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '运单类型', '整体-TMS', a.total_tms_month, a.total_tms_peak, m.total_tms_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '线下线上', '线下', a.offline_month, a.offline_peak, m.offline_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '线下线上', '线上', a.online_month, a.online_peak, m.online_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '运单类型', '线上-网货', a.online_wh_month, a.online_wh_peak, m.online_wh_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '运单类型', '线上-撮合', a.online_ch_month, a.online_ch_peak, m.online_ch_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '运单类型', '线上-TMS', a.online_tms_month, a.online_tms_peak, m.online_tms_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '线上举措', '货主招募', a.zm_month, a.zm_peak, m.zm_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '线上举措', '电销', a.dx_month, a.dx_peak, m.dx_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '线上举措', '投流', a.tl_month, a.tl_peak, m.tl_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '线上举措', '调度', a.dd_month, a.dd_peak, m.dd_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '举措新老', '货主招募-新货主', a.zm_new_month, a.zm_new_peak, m.zm_new_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '举措新老', '货主招募-老货主', a.zm_old_month, a.zm_old_peak, m.zm_old_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '举措新老', '电销-新货主', a.dx_new_month, a.dx_new_peak, m.dx_new_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '举措新老', '电销-老货主', a.dx_old_month, a.dx_old_peak, m.dx_old_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '举措新老', '投流-新货主', a.tl_new_month, a.tl_new_peak, m.tl_new_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '举措新老', '投流-老货主', a.tl_old_month, a.tl_old_peak, m.tl_old_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '举措新老', '调度-新货主', a.dd_new_month, a.dd_new_peak, m.dd_new_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
    UNION ALL SELECT a.mon, '举措新老', '调度-老货主', a.dd_old_month, a.dd_old_peak, m.dd_old_gtv
    FROM month_agg a JOIN month_money m ON m.mon = a.mon
)
SELECT
    DATE_FORMAT(r.mon, '%Y-%m') AS 月份,
    r.维度层级,
    r.维度,
    mm.day_n AS 统计天数,
    ROUND(r.month_cnt / 10000.0, 4) AS 月运单量_万单,
    ROUND(r.month_cnt / 10000.0 / NULLIF(mm.day_n, 0), 4) AS 日均_万单,
    ROUND(r.peak_cnt / 10000.0, 4) AS 日峰值_万单,
    pd.peak_dt AS 峰值日,
    /* 同 07 字段 freight_transact_amount；sheet 用亿，07 输出为万 */
    ROUND(r.gtv_yuan / 100000000.0, 4) AS 月GTV_亿,
    ROUND(r.gtv_yuan / 10000.0, 4) AS 月GTV_万,
    ROUND(r.gtv_yuan / NULLIF(r.month_cnt, 0), 2) AS 客单价_元,
    CASE r.维度
        WHEN '整体'            THEN '一、整体-月运单量 / 日均值 / 峰值 / 月GTV'
        WHEN '整体-网货'       THEN '二、业务线-网货（GTV/客单价）'
        WHEN '整体-撮合'       THEN '二、业务线-撮合（GTV/客单价）'
        WHEN '整体-TMS'        THEN '二、业务线-TMS（GTV/客单价）'
        WHEN '线下'            THEN '三、线下转化'
        WHEN '线上'            THEN '三、线上整体'
        WHEN '线上-网货'       THEN '六、线上-网货'
        WHEN '线上-撮合'       THEN '六、线上-撮合'
        WHEN '线上-TMS'        THEN '六、线上-TMS'
        WHEN '货主招募'        THEN '四、营销裂变（货主招募）'
        WHEN '电销'            THEN '四、电销挖潜'
        WHEN '投流'            THEN '四、线上投放（投流）'
        WHEN '调度'            THEN '四、资源转化（调度）'
        WHEN '货主招募-新货主' THEN '七、裂变-新增运单'
        WHEN '货主招募-老货主' THEN '七、裂变-留存运单'
        WHEN '电销-新货主'     THEN '七、电销-新增运单'
        WHEN '电销-老货主'     THEN '七、电销-留存运单'
        WHEN '投流-新货主'     THEN '七、投流-新增运单'
        WHEN '投流-老货主'     THEN '七、投流-留存运单'
        WHEN '调度-新货主'     THEN '七、调度-新增运单'
        WHEN '调度-老货主'     THEN '七、调度-留存运单'
    END AS sheet1_对齐行
FROM long_raw r
JOIN month_meta mm ON mm.mon = r.mon
LEFT JOIN peak_day pd ON pd.mon = r.mon AND pd.dim = r.维度
ORDER BY
    r.mon,
    CASE r.维度
        WHEN '整体' THEN 1
        WHEN '整体-网货' THEN 2 WHEN '整体-撮合' THEN 3 WHEN '整体-TMS' THEN 4
        WHEN '线下' THEN 5 WHEN '线上' THEN 6
        WHEN '线上-网货' THEN 7 WHEN '线上-撮合' THEN 8 WHEN '线上-TMS' THEN 9
        WHEN '货主招募' THEN 10 WHEN '电销' THEN 11 WHEN '投流' THEN 12 WHEN '调度' THEN 13
        WHEN '货主招募-新货主' THEN 14 WHEN '货主招募-老货主' THEN 15
        WHEN '电销-新货主' THEN 16 WHEN '电销-老货主' THEN 17
        WHEN '投流-新货主' THEN 18 WHEN '投流-老货主' THEN 19
        WHEN '调度-新货主' THEN 20 WHEN '调度-老货主' THEN 21
    END
;
