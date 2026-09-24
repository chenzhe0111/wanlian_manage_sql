/* 天津市佳贺金属制品有限公司 | 2026-07-31 电销运单号 */
WITH company_dx AS (
    SELECT DISTINCT company_name AS company_name_dx
    FROM match_shipper_telesales_leads_info
),
company_wxx AS (
    SELECT customer_company_id, MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
)
SELECT DISTINCT waybill.waybill_id AS 运单号
FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
INNER JOIN company_dx
    ON company_dx.company_name_dx = waybill.process_shipper_company_name
LEFT JOIN company_wxx
    ON company_wxx.customer_company_id = waybill.process_shipper_company_id
WHERE SUBSTR(waybill.accept_dt, 1, 10) = DATE '2026-07-31'
  AND waybill.process_shipper_company_name = '天津市佳贺金属制品有限公司'
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
ORDER BY waybill.waybill_id;
