/* 周度汇总 | 履约口径 + 剔除异常运单
 * 相对 02_周度汇总.sql（成交 accept_dt）的差异：
 *   1) 时间轴：unload_time（履约卸货日），且 load_time / unload_time 均非空
 *   2) 异常口径 type_ab（履约新口径，同 01c）：排除 异常剔除 + 申诉中；申诉成功计入履约
 *      行程：司机近30天行程异常；线上申诉中(100/300/310/410/500)、成功(400)、失败(110/200/320/440)
 * 其余：线下线索 OR 非微信主体；五举措等权分摊；输出结构同 02
 * 周起始：周三（与 02 一致）
 */
WITH
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
    /* 剔除异常：异常剔除 + 申诉中；申诉成功 / 未命中场景 = 履约 */
    SELECT DISTINCT waybill_id
    FROM type_ab
    WHERE 异常类别 IN ('异常剔除', '申诉中')
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
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        DATE_SUB(
            DATE(waybill.unload_time),
            INTERVAL ((WEEKDAY(waybill.unload_time) - 2 + 7) % 7) DAY
        ) AS week_start,
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
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    WHERE DATE(waybill.unload_time) >= DATE '2026-06-01'
      AND DATE(waybill.unload_time) <= CURRENT_DATE()
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
        wh.waybill_id,
        wh.week_start,
        wh.waybill_category,
        wh.hit_offline,
        wh.hit_zm, wh.hit_tl, wh.hit_dx, wh.hit_dd, wh.hit_wxx,
        CASE WHEN wh.hit_zm  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN wh.hit_tl  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN wh.hit_dx  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN wh.hit_dd  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_dd,
        CASE WHEN wh.hit_wxx = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_wxx
    FROM waybill_hit wh
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = wh.waybill_id
    WHERE abn.waybill_id IS NULL
),
agg AS (
    SELECT
        week_start,
        waybill_category,
        COUNT(DISTINCT waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN hit_offline = 1 THEN waybill_id END) AS offline_cnt,
        COUNT(DISTINCT CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN waybill_id END) AS online_cnt,
        SUM(w_zm)  AS zm_cnt,
        SUM(w_tl)  AS tl_cnt,
        SUM(w_dx)  AS dx_cnt,
        SUM(w_dd)  AS dd_cnt,
        SUM(w_wxx) AS wxx_cnt
    FROM waybill_split
    GROUP BY week_start, waybill_category
),
agg_all AS (
    SELECT
        week_start,
        SUM(total_cnt)   AS total_cnt,
        SUM(offline_cnt) AS offline_cnt,
        SUM(online_cnt)  AS online_cnt,
        SUM(zm_cnt)      AS zm_cnt,
        SUM(tl_cnt)      AS tl_cnt,
        SUM(dx_cnt)      AS dx_cnt,
        SUM(dd_cnt)      AS dd_cnt,
        SUM(wxx_cnt)     AS wxx_cnt
    FROM agg
    GROUP BY week_start
),
result AS (
    /* 整体 */
    SELECT week_start, '整体' AS stat_level, '整体' AS stat_dim, total_cnt AS waybill_cnt FROM agg_all
    UNION ALL
    /* 整体-运单类型：网货 / TMS / 撮合 */
    SELECT week_start, '整体', waybill_category, total_cnt FROM agg
    UNION ALL
    /* 整体-线上 / 整体-线下 */
    SELECT week_start, '整体', '线上', online_cnt FROM agg_all
    UNION ALL
    SELECT week_start, '整体', '线下', offline_cnt FROM agg_all
    UNION ALL
    /* 线上-运单类型 */
    SELECT week_start, '线上', waybill_category, online_cnt FROM agg
    UNION ALL
    /* 线上举措 */
    SELECT week_start, '线上举措', '货主招募', zm_cnt FROM agg_all
    UNION ALL
    SELECT week_start, '线上举措', '投流', tl_cnt FROM agg_all
    UNION ALL
    SELECT week_start, '线上举措', '电销', dx_cnt FROM agg_all
    UNION ALL
    SELECT week_start, '线上举措', '调度', dd_cnt FROM agg_all
    UNION ALL
    SELECT week_start, '线上举措', '无线下销售归属', wxx_cnt FROM agg_all
    /* 线上举措 × 运单类型 */
    UNION ALL
    SELECT week_start, '线上举措', CONCAT('货主招募-', waybill_category), zm_cnt FROM agg
    UNION ALL
    SELECT week_start, '线上举措', CONCAT('投流-', waybill_category), tl_cnt FROM agg
    UNION ALL
    SELECT week_start, '线上举措', CONCAT('电销-', waybill_category), dx_cnt FROM agg
    UNION ALL
    SELECT week_start, '线上举措', CONCAT('调度-', waybill_category), dd_cnt FROM agg
    UNION ALL
    SELECT week_start, '线上举措', CONCAT('无线下销售归属-', waybill_category), wxx_cnt FROM agg
)
SELECT
    week_start AS 周起始日,
    stat_level AS 统计层级,
    stat_dim   AS 维度,
    CONCAT(stat_level, '-', stat_dim) AS 层级维度,
    waybill_cnt / 10000 AS 运单量
FROM result
ORDER BY
    week_start,
    CASE stat_level
        WHEN '整体'   THEN 1
        WHEN '线上'   THEN 2
        WHEN '线上举措' THEN 3
        ELSE 99
    END,
    CASE
        WHEN stat_dim = '整体' THEN 0
        WHEN stat_dim = '网货' THEN 1
        WHEN stat_dim = 'TMS' THEN 2
        WHEN stat_dim = '撮合' THEN 3
        WHEN stat_dim = '线上' THEN 4
        WHEN stat_dim = '线下' THEN 5
        WHEN stat_dim = '货主招募' THEN 10
        WHEN stat_dim = '投流' THEN 11
        WHEN stat_dim = '电销' THEN 12
        WHEN stat_dim = '调度' THEN 13
        WHEN stat_dim = '无线下销售归属' THEN 14
        WHEN stat_dim LIKE '货主招募-%' THEN 30
        WHEN stat_dim LIKE '投流-%' THEN 31
        WHEN stat_dim LIKE '电销-%' THEN 32
        WHEN stat_dim LIKE '调度-%' THEN 33
        WHEN stat_dim LIKE '无线下销售归属-%' THEN 34
        ELSE 99
    END,
    stat_dim;
