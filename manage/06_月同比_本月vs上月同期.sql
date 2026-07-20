/* 运单量 MTD 对比 | 本月 vs 上个月同期
 * 截止口径：截止到「昨天」全天（右开：accept_dt < 昨天次日0点）
 * 线上过滤：与月度拆分SQL一致（线下线索 OR 非微信主体）
 *
 * 对齐说明（为何会和「按月汇总SQL」对不上）：
 *   1) 本月 MTD 可对齐：月度SQL 里 mon=当月 且 accept 截止到昨天
 *   2) 「上个月」是上月1日~上月同日(相对昨天)，不是上月整月
 *   3) 月度SQL含「整体×运单类型/线上×运单类型」等更多拆分；本SQL只出合计维度
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
company_zm AS (
    SELECT DISTINCT invitee_id
    FROM dwd_vlsp_mt_user_recruitment_business_process_minf zm
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t1
        ON zm.invitee_company_user_id = t1.psn_acct_user_base_id
    WHERE activity_title = '货主招募活动'
      AND invitee_id IS NOT NULL AND invitee_id <> ''
),
company_tl_channel AS (
    SELECT DISTINCT company.company_id
    FROM dwd_vlsp_mt_em_user_manage_info_minf usr
    INNER JOIN ads.ads_vlsp_tms_advertise_placement_channel_info_df channel
        ON channel.telephone = usr.telephone
    INNER JOIN dwd_vlsp_mt_em_company_manage_info_minf company
        ON company.company_apply_user_base_id = usr.user_base_id
    WHERE usr.user_status = 11 AND usr.deleted = 21 AND usr.account_type = 10
      AND company.company_id IS NOT NULL
),
company_tl AS (
    SELECT company_id
    FROM (
        SELECT u.company_id
        FROM dwd.dwd_vlsp_mt_bt_advertise_placement_business_process_minf advertise
        LEFT JOIN (
            SELECT user_base_id, company_id
            FROM dwd.dwd_vlsp_mt_em_user_manage_info_minf
            WHERE user_status = 11 AND deleted = 21
            GROUP BY 1, 2
        ) u ON u.user_base_id = advertise.user_id
        WHERE advertise.user_id <> '' AND advertise.consign_callback_status = 10
          AND u.company_id IS NOT NULL
        UNION
        SELECT company_id FROM company_tl_channel
    ) t
    GROUP BY company_id
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
        waybill.accept_dt,
        CASE
            WHEN waybill.accept_dt >= t.this_month_start
             AND waybill.accept_dt <  t.this_month_end_excl
                THEN '本月'
            WHEN waybill.accept_dt >= t.last_month_start
             AND waybill.accept_dt <  t.last_month_end_excl
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
            (waybill.accept_dt >= t.this_month_start AND waybill.accept_dt < t.this_month_end_excl)
         OR (waybill.accept_dt >= t.last_month_start AND waybill.accept_dt < t.last_month_end_excl)
          )
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
        waybill_id,
        period_tag,
        hit_offline,
        hit_zm, hit_tl, hit_dx, hit_dd, hit_wxx,
        CASE WHEN hit_zm  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN hit_tl  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN hit_dx  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN hit_dd  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dd,
        CASE WHEN hit_wxx = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_wxx
    FROM waybill_hit
    WHERE period_tag IS NOT NULL
),
agg AS (
    SELECT
        period_tag,
        COUNT(DISTINCT waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE WHEN hit_offline = 1 THEN waybill_id END) AS offline_cnt,
        COUNT(DISTINCT CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN waybill_id END) AS online_cnt,
        SUM(w_zm)  AS zm_cnt,
        SUM(w_tl)  AS tl_cnt,
        SUM(w_dx)  AS dx_cnt,
        SUM(w_dd)  AS dd_cnt,
        SUM(w_wxx) AS wxx_cnt
    FROM waybill_split
    GROUP BY period_tag
),
long_fmt AS (
    SELECT period_tag, '整体' AS stat_level, '整体' AS stat_dim, total_cnt AS waybill_cnt FROM agg
    UNION ALL
    SELECT period_tag, '线上线下', '线上', online_cnt FROM agg
    UNION ALL
    SELECT period_tag, '线上线下', '线下', offline_cnt FROM agg
    UNION ALL
    SELECT period_tag, '线上举措', '货主招募', zm_cnt FROM agg
    UNION ALL
    SELECT period_tag, '线上举措', '投流', tl_cnt FROM agg
    UNION ALL
    SELECT period_tag, '线上举措', '电销', dx_cnt FROM agg
    UNION ALL
    SELECT period_tag, '线上举措', '调度', dd_cnt FROM agg
    UNION ALL
    SELECT period_tag, '线上举措', '无线下销售归属', wxx_cnt FROM agg
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
        WHEN '整体' THEN 1
        WHEN '线下' THEN 2
        WHEN '线上' THEN 3
        WHEN '货主招募' THEN 4
        WHEN '投流' THEN 5
        WHEN '电销' THEN 6
        WHEN '调度' THEN 7
        WHEN '无线下销售归属' THEN 8
        ELSE 99
    END;
