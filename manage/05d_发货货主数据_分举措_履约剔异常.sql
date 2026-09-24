-- 线上发货货主 | 分举措 + 去重对照 | 履约剔异常（对齐 05c）+ 发货事件（对齐 03e/05）
--
-- 为什么 05c「线上发货货主数」< 03e 四举措「发货货主数」加总：
--   1) 去重 vs 加总：05c 是命中任一线上举措后 COUNT DISTINCT（一家只计 1）；
--      03e 按举措分别 COUNT DISTINCT，一家可同时进裂变/投流/电销/调度，加总会重复。
--      无线下与四举措互斥；重叠只发生在四举措之间。
--   2) 事件轴不同：05c = 履约卸货日（load/unload 非空 + 剔异常 + 成交过滤）；
--      03e「发货货主数」= TMS建单 ∪ 货源发布，未履约/未成交也会进漏斗发货。
--      要对齐 03e 发货，看本 SQL 的「发货」轴，不要拿 05c 履约数去加总对比。
--   3) 投流池：本 SQL 已对齐 03e/01d 新口径（投放账户链路 + 拼表单 + 卓易通→非假企货主）。
--      05c 仍是旧口径（投放账户+拼表单），所以「履约 × 线上去重」会略高于 05c。
--   4) 本 SQL / 05c 有微信事业部过滤；03e 发货没有。
--   5) 03e 发货还含「线下」「无线下销售归属」；若把这两条也加进去，加总会更大。
--
-- 用法：拿「发货 × 分举措」对 03e 发货货主；「履约 × 线上去重」对 05c 时须接受投流新口径差；
--       「四举措加总(含重叠) − 四举措去重」= 多举措重复计数。

WITH
/* ===== 异常运单判定（履约，同 05c / 01c） ===== */
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
company_zm AS (
    SELECT DISTINCT invitee_id AS company_id
    FROM dwd_vlsp_mt_user_recruitment_business_process_minf zm
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t1
        ON zm.invitee_company_user_id = t1.psn_acct_user_base_id
        AND t1.is_fake_user = '0'
    WHERE activity_title = '货主招募活动'
      AND invitee_id IS NOT NULL AND invitee_id <> ''
),
/* 投流新口径：同 03e / 01d（投放账户链路 + 拼表单 + 卓易通 → 非假企货主） */
company_tl AS (
    SELECT DISTINCT comp.company_id
    FROM (
        SELECT
            a.user_id,
            a.psn_user_id,
            a.emp_user_id,
            a.co_id
        FROM dwd_vlsp_mt_bt_advertise_placement_business_process_minf a
        WHERE a.user_id <> ''
        UNION ALL
        SELECT
            b.user_base_id AS user_id,
            CAST(NULL AS STRING) AS psn_user_id,
            CAST(NULL AS STRING) AS emp_user_id,
            CAST(NULL AS STRING) AS co_id
        FROM match_shipper_table_advertise_info a
        LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf b
            ON a.telephone = b.telephone
        WHERE b.user_base_id <> ''
        UNION ALL
        SELECT
            user_base_id AS user_id,
            CAST(NULL AS STRING) AS psn_user_id,
            CAST(NULL AS STRING) AS emp_user_id,
            CAST(NULL AS STRING) AS co_id
        FROM dwd_vlsp_mt_tracking_event_unique_device_mi
        WHERE event_type IN ('hc_release_enter')
          AND client_type IN ('app')
          AND role_type IN ('50', '货主')
          AND app_channel IN ('zyt')
          AND event_time >= '2026-09-01 00:00:00'
          AND user_base_id IS NOT NULL
          AND user_base_id <> ''
        GROUP BY user_base_id
    ) ad
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t1
        ON COALESCE(ad.emp_user_id, ad.user_id) = t1.user_base_id
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t2
        ON t1.psn_acct_user_base_id = t2.user_base_id
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t3
        ON t3.psn_acct_user_base_id = COALESCE(ad.psn_user_id, ad.user_id)
    LEFT JOIN (
        SELECT company_id
        FROM dwd_vlsp_mt_em_company_manage_info_minf
        WHERE is_fake_company_apply_user = '0'
    ) comp
        ON COALESCE(ad.co_id, t1.company_id, t3.company_id) = comp.company_id
    WHERE (t1.is_shipper = 1 OR t2.is_shipper = 1)
      AND t1.is_fake_user = '0'
      AND comp.company_id IS NOT NULL
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
    SELECT customer_company_id AS company_id,
           MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
),
company_info AS (
    SELECT company_id, company_name
    FROM dwd_vlsp_mt_em_company_manage_info_minf
    WHERE company_id IS NOT NULL
      AND is_fake_company_apply_user = '0'
    GROUP BY 1, 2
),
/* ===== 履约轴（同 05c）：卸货日 + 剔异常 + 成交过滤 ===== */
fulfill_hit AS (
    SELECT
        DATE(waybill.unload_time) AS event_dt,
        waybill.shipper_company_id AS company_id,
        CASE WHEN company_zm.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_zm,
        CASE WHEN company_tl.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_tl,
        CASE WHEN company_dx.company_name_dx IS NOT NULL THEN 1 ELSE 0 END AS hit_dx,
        CASE WHEN company_dd.company_name_dd IS NOT NULL THEN 1 ELSE 0 END AS hit_dd,
        CASE
            WHEN company_wxx.sales_lv1_company_id IS NULL
             AND company_zm.company_id IS NULL
             AND company_tl.company_id IS NULL
             AND company_dx.company_name_dx IS NULL
             AND company_dd.company_name_dd IS NULL
            THEN 1 ELSE 0
        END AS hit_wxx
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    LEFT JOIN company_zm  ON company_zm.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.company_id = waybill.process_shipper_company_id
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = waybill.waybill_id
    WHERE DATE(waybill.unload_time) >= DATE '2026-01-01'
      AND DATE(waybill.unload_time) < CURRENT_DATE()
      AND waybill.load_time IS NOT NULL
      AND waybill.unload_time IS NOT NULL
      AND abn.waybill_id IS NULL
      AND waybill.waybill_status NOT IN (540, 100)
      AND NVL(waybill.shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c', '1993982792389951488',
          '1993985265305452544', '1994003031330062336'
      )
      AND (waybill.tms_flag = 20 OR (waybill.tms_flag = 10 AND waybill.driver_operate_accept_time IS NOT NULL))
      AND (
          company_wxx.sales_lv1_company_id IS NOT NULL
          OR NVL(waybill.shipper_company_name, '') NOT IN (
              SELECT DISTINCT dept_name FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
),
/* ===== 发货轴（同 03e / 05）：TMS建单 ∪ 货源发布 ===== */
tms_waybill AS (
    SELECT
        DATE(SUBSTR(waybill_create_time, 1, 10)) AS event_dt,
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
        DATE(SUBSTR(create_dt, 1, 10)) AS event_dt,
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
    SELECT event_dt, company_id FROM tms_waybill
    UNION
    SELECT event_dt, company_id FROM goods
),
ship_hit AS (
    SELECT
        s.event_dt,
        s.company_id,
        CASE WHEN company_zm.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_zm,
        CASE WHEN company_tl.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_tl,
        CASE WHEN company_dx.company_name_dx IS NOT NULL THEN 1 ELSE 0 END AS hit_dx,
        CASE WHEN company_dd.company_name_dd IS NOT NULL THEN 1 ELSE 0 END AS hit_dd,
        CASE
            WHEN company_wxx.sales_lv1_company_id IS NULL
             AND company_zm.company_id IS NULL
             AND company_tl.company_id IS NULL
             AND company_dx.company_name_dx IS NULL
             AND company_dd.company_name_dd IS NULL
            THEN 1 ELSE 0
        END AS hit_wxx
    FROM ship_event s
    INNER JOIN company_info ci ON ci.company_id = s.company_id
    LEFT JOIN company_zm  ON company_zm.company_id = s.company_id
    LEFT JOIN company_tl  ON company_tl.company_id = s.company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = ci.company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = ci.company_name
    LEFT JOIN company_wxx ON company_wxx.company_id = s.company_id
    WHERE s.event_dt >= DATE '2026-01-01'
      AND s.event_dt < CURRENT_DATE()
      AND (
          company_wxx.sales_lv1_company_id IS NOT NULL
          OR NVL(ci.company_name, '') NOT IN (
              SELECT DISTINCT dept_name FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
),
hit_all AS (
    SELECT '履约' AS event_axis, event_dt, company_id, hit_zm, hit_tl, hit_dx, hit_dd, hit_wxx
    FROM fulfill_hit
    WHERE company_id IS NOT NULL
    UNION ALL
    SELECT '发货', event_dt, company_id, hit_zm, hit_tl, hit_dx, hit_dd, hit_wxx
    FROM ship_hit
    WHERE company_id IS NOT NULL
),
/* 周期内先把货主打成「本月/本周命中了哪些举措」，再去重 */
hit_period AS (
    SELECT
        event_axis,
        '月' AS stat_granularity,
        DATE_FORMAT(event_dt, '%Y-%m-01') AS period_start,
        company_id,
        MAX(hit_zm) AS hit_zm,
        MAX(hit_tl) AS hit_tl,
        MAX(hit_dx) AS hit_dx,
        MAX(hit_dd) AS hit_dd,
        MAX(hit_wxx) AS hit_wxx
    FROM hit_all
    GROUP BY event_axis, DATE_FORMAT(event_dt, '%Y-%m-01'), company_id
    UNION ALL
    SELECT
        event_axis,
        '周',
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        company_id,
        MAX(hit_zm),
        MAX(hit_tl),
        MAX(hit_dx),
        MAX(hit_dd),
        MAX(hit_wxx)
    FROM hit_all
    GROUP BY
        event_axis,
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        company_id
),
init_long AS (
    SELECT event_axis, stat_granularity, period_start, company_id, '货主招募' AS initiative
    FROM hit_period WHERE hit_zm = 1
    UNION ALL
    SELECT event_axis, stat_granularity, period_start, company_id, '投流'
    FROM hit_period WHERE hit_tl = 1
    UNION ALL
    SELECT event_axis, stat_granularity, period_start, company_id, '电销'
    FROM hit_period WHERE hit_dx = 1
    UNION ALL
    SELECT event_axis, stat_granularity, period_start, company_id, '调度'
    FROM hit_period WHERE hit_dd = 1
    UNION ALL
    SELECT event_axis, stat_granularity, period_start, company_id, '无线下销售归属'
    FROM hit_period WHERE hit_wxx = 1
),
metric_init AS (
    SELECT
        event_axis,
        stat_granularity,
        period_start,
        initiative,
        COUNT(DISTINCT company_id) AS metric_value
    FROM init_long
    GROUP BY event_axis, stat_granularity, period_start, initiative
),
metric_extra AS (
    /* 线上去重 = 05c（履约轴）/ 05（发货轴） */
    SELECT
        event_axis,
        stat_granularity,
        period_start,
        '线上去重' AS initiative,
        COUNT(DISTINCT company_id) AS metric_value
    FROM hit_period
    WHERE hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0
    GROUP BY event_axis, stat_granularity, period_start
    UNION ALL
    /* 四举措去重（不含无线下） */
    SELECT
        event_axis,
        stat_granularity,
        period_start,
        '四举措去重',
        COUNT(DISTINCT company_id)
    FROM hit_period
    WHERE hit_zm + hit_tl + hit_dx + hit_dd > 0
    GROUP BY event_axis, stat_granularity, period_start
    UNION ALL
    /* 命中 ≥2 个四举措的货主（重叠规模） */
    SELECT
        event_axis,
        stat_granularity,
        period_start,
        '命中多举措货主',
        COUNT(DISTINCT company_id)
    FROM hit_period
    WHERE hit_zm + hit_tl + hit_dx + hit_dd >= 2
    GROUP BY event_axis, stat_granularity, period_start
    UNION ALL
    /* 四举措分别计数后再相加（含重叠，对应「03e 四举措加总」） */
    SELECT
        event_axis,
        stat_granularity,
        period_start,
        '四举措加总(含重叠)',
        SUM(metric_value)
    FROM metric_init
    WHERE initiative IN ('货主招募', '投流', '电销', '调度')
    GROUP BY event_axis, stat_granularity, period_start
),
metric_all AS (
    SELECT * FROM metric_init
    UNION ALL
    SELECT * FROM metric_extra
)
SELECT
    CONCAT(
        CASE stat_granularity WHEN '月' THEN '月度' WHEN '周' THEN '周度' END,
        '-', period_start, '-', event_axis, '-', initiative
    ) AS 主键,
    CASE stat_granularity WHEN '月' THEN '月度' WHEN '周' THEN '周度' END AS 月周标识,
    period_start AS 周期起始日,
    event_axis AS 事件轴,
    initiative AS 举措,
    metric_value AS 货主数
FROM metric_all
ORDER BY
    period_start,
    CASE stat_granularity WHEN '月' THEN 1 WHEN '周' THEN 2 END,
    CASE event_axis WHEN '履约' THEN 1 WHEN '发货' THEN 2 ELSE 9 END,
    CASE initiative
        WHEN '货主招募' THEN 1
        WHEN '投流' THEN 2
        WHEN '电销' THEN 3
        WHEN '调度' THEN 4
        WHEN '无线下销售归属' THEN 5
        WHEN '四举措加总(含重叠)' THEN 6
        WHEN '四举措去重' THEN 7
        WHEN '线上去重' THEN 8
        WHEN '命中多举措货主' THEN 9
        ELSE 99
    END;
