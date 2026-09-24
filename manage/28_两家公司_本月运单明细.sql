/* 北京锦辰鸿业运输有限公司 / 青岛金华顺供应链科技有限公司
 * 本月成交运单明细（具体到日）
 * 口径同月度汇总：有效成交；线下线索 OR 非微信主体；剔除测试公司
 * 改 tim 可换月
 */
WITH tim AS (
    SELECT
        DATE '2026-08-01' AS range_start,
        DATE '2026-08-13' AS range_end   /* 右闭；整月可改为月末 */
),
company_wxx AS (
    SELECT customer_company_id, MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
)
SELECT
    SUBSTR(waybill.accept_dt, 1, 10) AS 成交日期,
    waybill.accept_dt AS 成交时间,
    waybill.waybill_id AS 运单号,
    waybill.process_shipper_company_id AS 公司ID,
    waybill.process_shipper_company_name AS 公司名称,
    CASE
        WHEN waybill.invoice_type = 20 THEN '网货'
        WHEN waybill.invoice_type = 10 AND waybill.tms_flag = 10 THEN 'TMS'
        ELSE '撮合'
    END AS 运单类型,
    waybill.waybill_status AS 运单状态,
    waybill.tms_flag AS tms_flag,
    waybill.invoice_type AS invoice_type
FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
CROSS JOIN tim t
LEFT JOIN company_wxx
    ON company_wxx.customer_company_id = waybill.process_shipper_company_id
WHERE SUBSTR(waybill.accept_dt, 1, 10) BETWEEN t.range_start AND t.range_end
  AND waybill.process_shipper_company_name IN (
      '北京锦辰鸿业运输有限公司',
      '青岛金华顺供应链科技有限公司'
  )
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
ORDER BY
    waybill.process_shipper_company_name,
    waybill.accept_dt,
    waybill.waybill_id;
