/* 运单量 MTD 对比 | 履约剔异常 | 本月 vs 上个月同期
 * 在 06_月同比_本月vs上月同期.sql 基础上仅改履约口径：
 *   1) 时间轴：accept_dt → unload_time；load_time / unload_time 均非空
 *   2) 异常口径 type_ab（履约新口径，同 01c）：排除 异常剔除 + 申诉中；申诉成功计入履约
 *      行程：司机近30天行程异常；申诉中(100/300/310/410/500)、成功(400)、失败(110/200/320/440)
 * 其余同 06：截止到昨天；四举措输出（货主招募/投流/电销/调度）；无线下参与等权分摊但不输出
 */
WITH tim AS (
    SELECT
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS as_of_dt,          /* 统计截止日=昨天 */
        DATE_FORMAT(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), '%Y-%m-01') AS this_month_start,
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS this_month_end,    /* 展示：截止到昨天 */
        CURRENT_DATE() AS this_month_end_excl,                         /* 过滤：今天0点，含昨天全天 */
        DATE_FORMAT(
            DATE_SUB(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), INTERVAL 1 MONTH),
            '%Y-%m-01'
        ) AS last_month_start,
        /* 上月同日(相对昨天)：昨天7/13 → 上月截止6/13；上月无该日取上月最后一天 */
        LEAST(
            DATE_ADD(
                DATE_FORMAT(
                    DATE_SUB(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), INTERVAL 1 MONTH),
                    '%Y-%m-01'
                ),
                INTERVAL DAY(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)) - 1 DAY
            ),
            LAST_DAY(DATE_SUB(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), INTERVAL 1 MONTH))
        ) AS last_month_end,
        DATE_ADD(
            LEAST(
                DATE_ADD(
                    DATE_FORMAT(
                        DATE_SUB(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), INTERVAL 1 MONTH),
                        '%Y-%m-01'
                    ),
                    INTERVAL DAY(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)) - 1 DAY
                ),
                LAST_DAY(DATE_SUB(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), INTERVAL 1 MONTH))
            ),
            INTERVAL 1 DAY
        ) AS last_month_end_excl                                       /* 过滤：上月截止日次日0点 */
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
        waybill.unload_time,
        CASE
            WHEN waybill.unload_time >= t.this_month_start
             AND waybill.unload_time <  t.this_month_end_excl
                THEN '本月'
            WHEN waybill.unload_time >= t.last_month_start
             AND waybill.unload_time <  t.last_month_end_excl
                THEN '上个月'
        END AS period_tag,
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
    WHERE (
            (waybill.unload_time >= t.this_month_start AND waybill.unload_time < t.this_month_end_excl)
         OR (waybill.unload_time >= t.last_month_start AND waybill.unload_time < t.last_month_end_excl)
          )
      AND waybill.load_time IS NOT NULL
      AND waybill.unload_time IS NOT NULL
      /* 与月度SQL一致：线下线索保留，或企业名不在微信主体维表 */
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
        wh.period_tag,
        wh.hit_offline,
        wh.hit_zm, wh.hit_tl, wh.hit_dx, wh.hit_dd, wh.hit_wxx,
        CASE WHEN wh.hit_zm  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN wh.hit_tl  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN wh.hit_dx  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN wh.hit_dd  = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_dd,
        CASE WHEN wh.hit_wxx = 1 THEN 1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) ELSE 0 END AS w_wxx
    FROM waybill_hit wh
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = wh.waybill_id
    WHERE wh.period_tag IS NOT NULL
      AND abn.waybill_id IS NULL   /* 履约剔异常 */
),
agg AS (
    SELECT
        period_tag,
        SUM(w_zm)  AS zm_cnt,
        SUM(w_tl)  AS tl_cnt,
        SUM(w_dx)  AS dx_cnt,
        SUM(w_dd)  AS dd_cnt
    FROM waybill_split
    GROUP BY period_tag
),
long_fmt AS (
    SELECT period_tag, '线上举措' AS stat_level, '货主招募' AS stat_dim, zm_cnt AS waybill_cnt FROM agg
    UNION ALL
    SELECT period_tag, '线上举措', '投流', tl_cnt FROM agg
    UNION ALL
    SELECT period_tag, '线上举措', '电销', dx_cnt FROM agg
    UNION ALL
    SELECT period_tag, '线上举措', '调度', dd_cnt FROM agg
)
SELECT
    l.stat_level AS 统计层级,
    CASE l.stat_dim
        WHEN '电销' THEN '电销触达'
        WHEN '调度' THEN '调度导流'
        ELSE l.stat_dim
    END AS 维度,
    ROUND(SUM(CASE WHEN l.period_tag = '上个月' THEN l.waybill_cnt END) / 10000, 4) AS 上个月运单量,
    ROUND(SUM(CASE WHEN l.period_tag = '本月'   THEN l.waybill_cnt END) / 10000, 4) AS 本月运单量,
    t.last_month_start AS 上个月起始日,
    t.last_month_end   AS 上个月截止日,
    t.this_month_start AS 本月起始日,
    t.this_month_end   AS 本月截止日
FROM long_fmt l
CROSS JOIN tim t
GROUP BY l.stat_level, l.stat_dim, t.last_month_start, t.last_month_end, t.this_month_start, t.this_month_end
ORDER BY
    CASE l.stat_dim
        WHEN '货主招募' THEN 1
        WHEN '投流' THEN 2
        WHEN '电销' THEN 3
        WHEN '调度' THEN 4
        ELSE 99
    END;
