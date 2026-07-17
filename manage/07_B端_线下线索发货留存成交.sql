/*
 * 三段 SQL 合并 | 仅月维度
 * 段1：线下线索发货货主数（货源 + clue，按月去重 publish_company_id）
 * 段2：留存发货货主数（上月有发货 且 本月也有发货 的去重 publish_company_id）
 * 段3：线下成交（sales_name IS NOT NULL → 运单数/货主数/GTV）
 *
 * 对应原 ad-hoc 区间：6月整月 + 7月1~7日（range_end 右开为 2026-07-08）
 */

WITH tim AS (
    SELECT
        DATE '2026-06-01' AS range_start,
        DATE '2026-07-08' AS range_end
),
month_dim AS (
    SELECT DATE '2026-06-01' AS stat_mon
    UNION ALL
    SELECT DATE '2026-07-01'
),
clue AS (
    SELECT *
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE company_name NOT LIKE '%测试%'
      AND biz_segment_code = 2001              /* 2001整车物流 */
      AND prod_line_code IN (3002)             /* 3002撮合 */
      AND status <> 13
),
/* 段1+段2 公共明细：按月 + 货主 */
ship_event AS (
    SELECT DISTINCT
        DATE_FORMAT(a.create_dt, '%Y-%m-01') AS stat_mon,
        a.publish_company_id
    FROM dwd_vlsp_mt_em_goods_manage_info_minf a
    INNER JOIN clue
        ON a.publish_company_id = clue.customer_company_id
    CROSS JOIN tim t
    WHERE a.goods_status <> 10
      AND COALESCE(a.publish_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          '1993982792389951488',
          '1993985265305452544',
          '1994003031330062336'
      )
      AND a.goods_id NOT IN (
          'CHQY20251204000000016246',
          'CHQY20251211000000012094'
      )
      AND a.create_dt >= t.range_start
      AND a.create_dt <  t.range_end
),
/* 段1：月发货货主数 */
ship_month AS (
    SELECT
        stat_mon,
        COUNT(DISTINCT publish_company_id) AS shipper_cnt
    FROM ship_event
    GROUP BY stat_mon
),
/* 段2：留存 = 本月发货货主 ∩ 上月发货货主（7月行 = 6月∩7/1~7/7） */
ship_retain AS (
    SELECT
        cur.stat_mon,
        COUNT(DISTINCT cur.publish_company_id) AS retain_shipper_cnt
    FROM ship_event cur
    INNER JOIN ship_event prev
        ON cur.publish_company_id = prev.publish_company_id
       AND prev.stat_mon = DATE_FORMAT(DATE_SUB(cur.stat_mon, INTERVAL 1 MONTH), '%Y-%m-01')
    GROUP BY cur.stat_mon
),
/* 段3：月成交运单/货主/GTV */
waybill_month AS (
    SELECT
        DATE_FORMAT(a.accept_dt, '%Y-%m-01') AS stat_mon,
        COUNT(a.waybill_id) AS deal_waybill_cnt,
        COUNT(DISTINCT a.process_shipper_company_name) AS deal_shipper_cnt,
        SUM(a.freight_transact_amount) / 10000 AS deal_gtv_wan
    FROM dwd_vlsp_mt_match_waybill_match_business_process_minf a
    CROSS JOIN tim t
    WHERE a.accept_dt >= t.range_start
      AND a.accept_dt <  t.range_end
      AND a.waybill_status NOT IN (100, 540)
      AND a.sales_name IS NOT NULL
      AND COALESCE(a.shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          '1993982792389951488',
          '1993985265305452544',
          '1994003031330062336'
      )
      AND (
          a.tms_flag = 20
          OR a.driver_operate_accept_time IS NOT NULL
      )
    GROUP BY DATE_FORMAT(a.accept_dt, '%Y-%m-01')
)
SELECT
    m.stat_mon AS 月份,
    COALESCE(s.shipper_cnt, 0) AS 发货货主数,
    COALESCE(r.retain_shipper_cnt, 0) AS 留存发货货主数,
    COALESCE(w.deal_waybill_cnt, 0) AS 成交运单数,
    COALESCE(w.deal_shipper_cnt, 0) AS 成交货主数,
    COALESCE(w.deal_gtv_wan, 0) AS 运单GTV_万
FROM month_dim m
LEFT JOIN ship_month s ON s.stat_mon = m.stat_mon
LEFT JOIN ship_retain r ON r.stat_mon = m.stat_mon
LEFT JOIN waybill_month w ON w.stat_mon = m.stat_mon
ORDER BY m.stat_mon;
