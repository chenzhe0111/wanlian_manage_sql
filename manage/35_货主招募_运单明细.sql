/* 货主招募：运单明细
 * 字段：运单类型 | 公司ID | 公司名称 | 运单ID
 * 口径同 01_月度汇总：有效成交；线下线索 OR 非微信主体；剔除测试公司
 * 改 tim 可换日期区间
 */
WITH tim AS (
    SELECT
        DATE '2026-08-01' AS range_start,
        DATE '2026-08-25' AS range_end   /* 右闭；整月可改为月末 */
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
company_wxx AS (
    SELECT customer_company_id, MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
)
SELECT
    CASE
        WHEN waybill.invoice_type = 20 THEN '网货'
        WHEN waybill.invoice_type = 10 AND waybill.tms_flag = 10 THEN 'TMS'
        ELSE '撮合'
    END AS 运单类型,
    waybill.process_shipper_company_id AS 公司ID,
    waybill.process_shipper_company_name AS 公司名称,
    waybill.waybill_id AS 运单ID,
    SUBSTR(waybill.accept_dt, 1, 10) AS 成交日期,
    waybill.accept_dt AS 成交时间
FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
CROSS JOIN tim t
INNER JOIN company_zm
    ON company_zm.invitee_id = waybill.process_shipper_company_id
LEFT JOIN company_wxx
    ON company_wxx.customer_company_id = waybill.process_shipper_company_id
WHERE SUBSTR(waybill.accept_dt, 1, 10) BETWEEN t.range_start AND t.range_end
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
