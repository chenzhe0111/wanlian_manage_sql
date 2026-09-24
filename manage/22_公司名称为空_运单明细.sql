/* 运单表：公司名称为空的明细
 * 空 = process_shipper_company_name 为 NULL / '' / 纯空格
 * 日期可按需改；默认 2026-07
 */
SELECT
    waybill.waybill_id AS 运单号,
    waybill.accept_dt AS 成交时间,
    waybill.process_shipper_company_id AS process公司ID,
    waybill.process_shipper_company_name AS process公司名称,
    waybill.shipper_company_id AS shipper公司ID,
    waybill.shipper_company_name AS shipper公司名称,
    waybill.waybill_status AS 运单状态,
    waybill.tms_flag AS tms_flag,
    waybill.invoice_type AS invoice_type
FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
WHERE SUBSTR(waybill.accept_dt, 1, 10) BETWEEN DATE '2026-07-01' AND DATE '2026-07-31'
  AND (
      waybill.process_shipper_company_name IS NULL
      OR TRIM(waybill.process_shipper_company_name) = ''
  )
ORDER BY waybill.accept_dt, waybill.waybill_id;
