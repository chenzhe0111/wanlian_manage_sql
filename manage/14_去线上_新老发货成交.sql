/* 发货货主 + 成交 | 整体 / 线下 / 线上 / 去线上 | 2026-01 ~ 2026-07 | 不拆新老
 * 线上：命中 招募/投流/电销/调度/无线下销售归属 任一
 * 线下：有线下销售归属（sales_lv1）
 * 去线上：未命中线上五渠道（线上权重和=0）
 */
WITH tim AS (
    SELECT
        DATE '2026-01-01' AS range_start,
        DATE '2026-07-31' AS range_end
),
company_zm AS (
    SELECT DISTINCT invitee_id AS company_id
    FROM dwd_vlsp_mt_user_recruitment_business_process_minf
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
    SELECT
        customer_company_id AS company_id,
        MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001
      AND prod_line_code IN (3002)
      AND status <> 13
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
tms_waybill AS (
    SELECT DATE(waybill_create_time) AS create_dt, shipper_company_id AS company_id
    FROM dwd_vlsp_mt_match_waybill_tms_business_process_minf
    WHERE COALESCE(shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          '1993982792389951488',
          '1993985265305452544',
          '1994003031330062336'
      )
      AND tms_flag = 10
    GROUP BY 1, 2
),
goods AS (
    SELECT create_dt, publish_company_id AS company_id
    FROM dwd_vlsp_mt_em_goods_manage_info_minf
    WHERE goods_status <> 10
      AND COALESCE(publish_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          '1993982792389951488',
          '1993985265305452544',
          '1994003031330062336'
      )
      AND goods_id NOT IN ('CHQY20251204000000016246', 'CHQY20251211000000012094')
    GROUP BY 1, 2
),
base AS (
    SELECT create_dt, company_id FROM tms_waybill
    UNION
    SELECT create_dt, company_id FROM goods
),
/* 发货事件 + 线上/线下命中 */
ship_hit AS (
    SELECT
        DATE(b.create_dt) AS event_dt,
        b.company_id,
        CASE WHEN wxx.sales_lv1_company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_offline,
        CASE WHEN zm.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_zm,
        CASE WHEN tl.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_tl,
        CASE WHEN dx.company_name_dx IS NOT NULL THEN 1 ELSE 0 END AS hit_dx,
        CASE WHEN dd.company_name_dd IS NOT NULL THEN 1 ELSE 0 END AS hit_dd,
        CASE
            WHEN wxx.sales_lv1_company_id IS NULL
             AND zm.company_id IS NULL
             AND tl.company_id IS NULL
             AND dx.company_name_dx IS NULL
             AND dd.company_name_dd IS NULL
            THEN 1 ELSE 0
        END AS hit_wxx
    FROM base b
    INNER JOIN company_info ci ON ci.company_id = b.company_id
    LEFT JOIN company_zm zm ON zm.company_id = b.company_id
    LEFT JOIN company_tl tl ON tl.company_id = b.company_id
    LEFT JOIN company_dx dx ON dx.company_name_dx = ci.company_name
    LEFT JOIN company_dd dd ON dd.company_name_dd = ci.company_name
    LEFT JOIN company_wxx wxx ON wxx.company_id = b.company_id
    CROSS JOIN tim t
    WHERE b.create_dt >= t.range_start
      AND b.create_dt <= t.range_end
      AND (
          wxx.sales_lv1_company_id IS NOT NULL
          OR NVL(ci.company_name, '') NOT IN (
              SELECT DISTINCT dept_name FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
),
ship_tag AS (
    SELECT
        event_dt,
        company_id,
        hit_offline,
        CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN 1 ELSE 0 END AS hit_online
    FROM ship_hit
),
/* 成交运单 + 线上/线下命中 */
waybill_hit AS (
    SELECT
        DATE(w.accept_dt) AS event_dt,
        w.shipper_company_id AS company_id,
        w.waybill_id,
        CASE WHEN wxx.sales_lv1_company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_offline,
        CASE WHEN zm.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_zm,
        CASE WHEN tl.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_tl,
        CASE WHEN dx.company_name_dx IS NOT NULL THEN 1 ELSE 0 END AS hit_dx,
        CASE WHEN dd.company_name_dd IS NOT NULL THEN 1 ELSE 0 END AS hit_dd,
        CASE
            WHEN wxx.sales_lv1_company_id IS NULL
             AND zm.company_id IS NULL
             AND tl.company_id IS NULL
             AND dx.company_name_dx IS NULL
             AND dd.company_name_dd IS NULL
            THEN 1 ELSE 0
        END AS hit_wxx
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf w
    LEFT JOIN company_info ci ON ci.company_id = w.shipper_company_id
    LEFT JOIN company_zm zm ON zm.company_id = w.shipper_company_id
    LEFT JOIN company_tl tl ON tl.company_id = w.shipper_company_id
    LEFT JOIN company_dx dx ON dx.company_name_dx = COALESCE(ci.company_name, w.shipper_company_name)
    LEFT JOIN company_dd dd ON dd.company_name_dd = COALESCE(ci.company_name, w.shipper_company_name)
    LEFT JOIN company_wxx wxx ON wxx.company_id = w.shipper_company_id
    CROSS JOIN tim t
    WHERE DATE(w.accept_dt) >= t.range_start
      AND DATE(w.accept_dt) <= t.range_end
      AND NVL(w.shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          1993982792389951488,
          1993985265305452544,
          1994003031330062336
      )
      AND (w.tms_flag = 20 OR (w.tms_flag = 10 AND w.driver_operate_accept_time IS NOT NULL))
      AND w.waybill_status NOT IN (100, 540)
      AND (
          wxx.sales_lv1_company_id IS NOT NULL
          OR NVL(COALESCE(ci.company_name, w.shipper_company_name), '') NOT IN (
              SELECT DISTINCT dept_name FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
),
waybill_tag AS (
    SELECT
        event_dt,
        company_id,
        waybill_id,
        hit_offline,
        CASE WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN 1 ELSE 0 END AS hit_online
    FROM waybill_hit
),
/* 发货货主数：月份 × 口径 */
ship_metric AS (
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01') AS mon, '整体' AS scope,
           COUNT(DISTINCT company_id) AS ship_cnt
    FROM ship_tag GROUP BY 1
    UNION ALL
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01'), '线下',
           COUNT(DISTINCT CASE WHEN hit_offline = 1 THEN company_id END)
    FROM ship_tag GROUP BY 1
    UNION ALL
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01'), '线上',
           COUNT(DISTINCT CASE WHEN hit_online = 1 THEN company_id END)
    FROM ship_tag GROUP BY 1
    UNION ALL
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01'), '去线上',
           COUNT(DISTINCT CASE WHEN hit_online = 0 THEN company_id END)
    FROM ship_tag GROUP BY 1
),
/* 成交货主数 / 运单量：月份 × 口径 */
deal_metric AS (
    SELECT
        DATE_FORMAT(event_dt, '%Y-%m-01') AS mon,
        '整体' AS scope,
        COUNT(DISTINCT company_id) AS deal_shipper_cnt,
        COUNT(DISTINCT waybill_id) AS deal_waybill_cnt
    FROM waybill_tag
    GROUP BY 1
    UNION ALL
    SELECT
        DATE_FORMAT(event_dt, '%Y-%m-01'),
        '线下',
        COUNT(DISTINCT CASE WHEN hit_offline = 1 THEN company_id END),
        COUNT(DISTINCT CASE WHEN hit_offline = 1 THEN waybill_id END)
    FROM waybill_tag
    GROUP BY 1
    UNION ALL
    SELECT
        DATE_FORMAT(event_dt, '%Y-%m-01'),
        '线上',
        COUNT(DISTINCT CASE WHEN hit_online = 1 THEN company_id END),
        COUNT(DISTINCT CASE WHEN hit_online = 1 THEN waybill_id END)
    FROM waybill_tag
    GROUP BY 1
    UNION ALL
    SELECT
        DATE_FORMAT(event_dt, '%Y-%m-01'),
        '去线上',
        COUNT(DISTINCT CASE WHEN hit_online = 0 THEN company_id END),
        COUNT(DISTINCT CASE WHEN hit_online = 0 THEN waybill_id END)
    FROM waybill_tag
    GROUP BY 1
)
SELECT
    s.mon AS 月份,
    s.scope AS 口径,
    s.ship_cnt AS 发货货主数,
    d.deal_shipper_cnt AS 成交货主数,
    d.deal_waybill_cnt AS 成交运单量,
    ROUND(d.deal_waybill_cnt / NULLIF(d.deal_shipper_cnt, 0), 1) AS 单货主成交运单量
FROM ship_metric s
LEFT JOIN deal_metric d
    ON d.mon = s.mon AND d.scope = s.scope
ORDER BY
    s.mon,
    CASE s.scope
        WHEN '整体' THEN 1
        WHEN '线下' THEN 2
        WHEN '线上' THEN 3
        WHEN '去线上' THEN 4
        ELSE 99
    END;
