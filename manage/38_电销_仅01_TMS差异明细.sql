/* 电销 · 仅01 差异明细（TMS + 有 goods_id）
 * 01 命中（公司名 ∈ leads）但旧 leads 两路径未覆盖的单
 * 典型：ZYYD/TMS 单 goods_id 不在撮合货源池
 * 加路径3 TMS直挂后应归零；本 SQL 供业务核对
 * 改月份：调整 tim
 */
WITH tim AS (
    SELECT
        DATE '2026-08-01' AS range_start,
        DATE '2026-08-31' AS range_end
),
company_dx AS (
    SELECT DISTINCT company_name AS company_name_dx
    FROM match_shipper_telesales_leads_info
    WHERE company_name IS NOT NULL AND company_name <> ''
),
company_wxx AS (
    SELECT customer_company_id, MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
),
comp AS (
    SELECT company_id, company_name
    FROM dwd_vlsp_mt_em_company_manage_info_minf
    WHERE company_id IS NOT NULL
),
leads AS (
    SELECT DISTINCT company_name
    FROM match_shipper_telesales_leads_info
    WHERE company_name IS NOT NULL AND company_name <> ''
),
goods AS (
    SELECT goods_id, publish_company_id
    FROM dwd_vlsp_mt_em_goods_manage_info_minf
    WHERE create_dt >= '2025-12-01'
      AND goods_status <> 10
      AND publish_main_body_type IN (10, 20)
),
waybill_base AS (
    SELECT
        w.waybill_id,
        w.accept_dt,
        w.process_shipper_company_id,
        w.process_shipper_company_name,
        CASE
            WHEN w.uppermost_goods_id IS NOT NULL AND w.uppermost_goods_id <> '' THEN w.uppermost_goods_id
            ELSE w.goods_id
        END AS goods_id_cur,
        CASE
            WHEN w.invoice_type = 20 THEN '网货'
            WHEN w.invoice_type = 10 AND w.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_type,
        CASE
            WHEN REGEXP_EXTRACT(w.waybill_id, '^([a-zA-Z]+)', 1) = 'TLYD' THEN '不开票-撮合铁路运单'
            WHEN REGEXP_EXTRACT(w.waybill_id, '^([a-zA-Z]+)', 1) = 'ZYYD' THEN '不开票-TMS运单'
            WHEN REGEXP_EXTRACT(w.waybill_id, '^([a-zA-Z]+)', 1) = 'CHYD' THEN '不开票-撮合公路运单'
            WHEN REGEXP_EXTRACT(w.waybill_id, '^([a-zA-Z]+)', 1) = 'YD'   THEN '开票-网货运单'
            ELSE '其他'
        END AS waybill_tag
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf w
    CROSS JOIN tim t
    LEFT JOIN company_wxx wx ON wx.customer_company_id = w.process_shipper_company_id
    WHERE SUBSTR(w.accept_dt, 1, 10) BETWEEN t.range_start AND t.range_end
      AND (
          wx.sales_lv1_company_id IS NOT NULL
          OR NVL(w.shipper_company_name, '') NOT IN (
              SELECT DISTINCT dept_name FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
      AND w.waybill_status NOT IN (540, 100)
      AND NVL(w.shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c', 1993982792389951488,
          1993985265305452544, 1994003031330062336
      )
      AND (w.tms_flag = 20 OR (w.tms_flag = 10 AND w.driver_operate_accept_time IS NOT NULL))
),
hit_01 AS (
    SELECT wb.*
    FROM waybill_base wb
    INNER JOIN company_dx dx ON dx.company_name_dx = wb.process_shipper_company_name
),
hit_leads_old AS (
    /* 旧口径：仅路径1+2，不含 TMS 直挂 */
    SELECT waybill_id FROM (
        SELECT DISTINCT wb.waybill_id
        FROM waybill_base wb
        INNER JOIN goods g ON g.goods_id = wb.goods_id_cur
        INNER JOIN comp c ON c.company_id = g.publish_company_id
        INNER JOIN leads l ON l.company_name = c.company_name
        UNION
        SELECT DISTINCT wb.waybill_id
        FROM waybill_base wb
        INNER JOIN comp c ON c.company_id = wb.process_shipper_company_id
        INNER JOIN leads l ON l.company_name = c.company_name
        WHERE wb.goods_id_cur IS NULL OR wb.goods_id_cur = ''
    ) t
)
SELECT
    SUBSTR(h.accept_dt, 1, 10) AS 成交日期,
    h.waybill_id AS 运单ID,
    h.waybill_type AS 运单类型,
    h.waybill_tag,
    h.process_shipper_company_id AS 公司ID,
    h.process_shipper_company_name AS 公司名称,
    h.goods_id_cur AS goods_id,
    CASE WHEN c.company_id IS NOT NULL THEN 'Y' ELSE 'N' END AS leads能关联comp,
    c.company_id AS comp表company_id,
    CASE WHEN g.goods_id IS NOT NULL THEN 'Y' ELSE 'N' END AS goods池能匹配
FROM hit_01 h
LEFT JOIN hit_leads_old ho ON ho.waybill_id = h.waybill_id
LEFT JOIN comp c ON c.company_name = h.process_shipper_company_name
LEFT JOIN goods g
    ON g.publish_company_id = c.company_id
   AND g.goods_id = h.goods_id_cur
WHERE ho.waybill_id IS NULL
  AND h.waybill_tag = '不开票-TMS运单'
  AND h.goods_id_cur IS NOT NULL
  AND h.goods_id_cur <> ''
ORDER BY h.process_shipper_company_name, h.accept_dt, h.waybill_id;
