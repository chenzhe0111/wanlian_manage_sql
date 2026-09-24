/* 电销运单量 · leads 口径（货源关联 + 无货源直挂 + TMS直挂）
 * 基于电销 leads 表按公司名关联 comp，再分别：
 *   1) goods.goods_id = waybill.goods_id_cur
 *   2) 无 goods_id 时 comp.company_id = waybill.process_shipper_company_id
 *   3) TMS 有 goods_id 时 comp.company_id = waybill.process_shipper_company_id（不进撮合货源池）
 * 8 月运单量：COUNT DISTINCT waybill_id
 * 改月份：调整 tim 区间
 */
WITH tim AS (
    SELECT
        DATE '2026-08-01' AS range_start,
        DATE '2026-08-31' AS range_end   /* 右闭；未完结月改截止日 */
),
comp AS (
    SELECT
        substr(create_date, 1, 10) AS register_dt,
        CASE
            WHEN original_company_type IN (5, 7, 8) AND license_aptitude_status = 3
                THEN substr(license_aptitude_time, 1, 10)
            WHEN original_company_type IN (1, 2, 3, 4)
                 AND license_aptitude_status = 3
                 AND authorize_audit_status = 30
                THEN substr(
                    IF(license_aptitude_time > authorize_audit_time, license_aptitude_time, authorize_audit_time),
                    1, 10
                )
        END AS audit_dt,
        company_id,
        company_name
    FROM dwd_vlsp_mt_em_company_manage_info_minf
    WHERE company_id IS NOT NULL
),
goods AS (
    SELECT
        goods_id,
        publish_company_id,
        create_time,
        ROW_NUMBER() OVER (PARTITION BY publish_company_id ORDER BY create_time ASC) AS fh_rank
    FROM dwd_vlsp_mt_em_goods_manage_info_minf
    WHERE create_dt >= '2025-12-01'
      AND goods_status <> 10
      AND publish_main_body_type IN (10, 20)
),
waybill AS (
    SELECT
        accept_dt,
        process_shipper_company_id,
        CASE
            WHEN uppermost_goods_id IS NOT NULL AND uppermost_goods_id <> '' THEN uppermost_goods_id
            ELSE goods_id
        END AS goods_id_cur,
        CASE
            WHEN REGEXP_EXTRACT(waybill_id, '^([a-zA-Z]+)', 1) = 'TLYD' THEN '不开票-撮合铁路运单'
            WHEN REGEXP_EXTRACT(waybill_id, '^([a-zA-Z]+)', 1) = 'ZYYD' THEN '不开票-TMS运单'
            WHEN REGEXP_EXTRACT(waybill_id, '^([a-zA-Z]+)', 1) = 'CHYD' THEN '不开票-撮合公路运单'
            WHEN REGEXP_EXTRACT(waybill_id, '^([a-zA-Z]+)', 1) = 'YD'   THEN '开票-网货运单'
        END AS waybill_tag,
        waybill_id
    FROM dwd_vlsp_mt_match_waybill_match_business_process_minf
    CROSS JOIN tim t
    WHERE SUBSTR(accept_dt, 1, 10) BETWEEN t.range_start AND t.range_end
      AND waybill_status NOT IN (100, 540)
      AND (tms_flag = 20 OR (tms_flag = 10 AND driver_operate_accept_time IS NOT NULL))
),
leads AS (
    SELECT
        users_name,
        company_name,
        resource_name,
        bind_time
    FROM match_shipper_telesales_leads_info
    GROUP BY 1, 2, 3, 4
),
/* 路径1：有货源关联 */
dx_via_goods AS (
    SELECT DISTINCT
        waybill.waybill_id,
        SUBSTR(waybill.accept_dt, 1, 10) AS accept_dt,
        waybill.waybill_tag,
        comp.company_id,
        comp.company_name,
        '货源关联' AS link_type
    FROM leads
    LEFT JOIN comp
        ON leads.company_name = comp.company_name
    LEFT JOIN goods
        ON comp.company_id = goods.publish_company_id
    INNER JOIN waybill
        ON goods.goods_id = waybill.goods_id_cur
    WHERE waybill.waybill_id IS NOT NULL
      AND waybill.waybill_id <> ''
),
/* 路径2：无货源，按公司直挂 */
dx_via_company AS (
    SELECT DISTINCT
        waybill.waybill_id,
        SUBSTR(waybill.accept_dt, 1, 10) AS accept_dt,
        waybill.waybill_tag,
        comp.company_id,
        comp.company_name,
        '无货源直挂' AS link_type
    FROM leads
    LEFT JOIN comp
        ON leads.company_name = comp.company_name
    INNER JOIN waybill
        ON comp.company_id = waybill.process_shipper_company_id
    WHERE waybill.waybill_id IS NOT NULL
      AND waybill.waybill_id <> ''
      AND (waybill.goods_id_cur = '' OR waybill.goods_id_cur IS NULL)
),
/* 路径3：TMS 有 goods_id，按 company_id 直挂（goods_id 不在撮合货源池） */
dx_via_tms AS (
    SELECT DISTINCT
        waybill.waybill_id,
        SUBSTR(waybill.accept_dt, 1, 10) AS accept_dt,
        waybill.waybill_tag,
        comp.company_id,
        comp.company_name,
        'TMS直挂' AS link_type
    FROM leads
    LEFT JOIN comp
        ON leads.company_name = comp.company_name
    INNER JOIN waybill
        ON comp.company_id = waybill.process_shipper_company_id
    WHERE waybill.waybill_id IS NOT NULL
      AND waybill.waybill_id <> ''
      AND waybill.waybill_tag = '不开票-TMS运单'
      AND waybill.goods_id_cur IS NOT NULL
      AND waybill.goods_id_cur <> ''
),
dx_all AS (
    SELECT * FROM dx_via_goods
    UNION ALL
    SELECT * FROM dx_via_company
    UNION ALL
    SELECT * FROM dx_via_tms
)
/* ----- 汇总：8 月电销运单量 ----- */
SELECT
    '2026-08' AS 月份,
    COUNT(DISTINCT waybill_id) AS 运单量
FROM dx_all

UNION ALL

/* 分运单类型 */
SELECT
    waybill_tag AS 月份,
    COUNT(DISTINCT waybill_id) AS 运单量
FROM dx_all
GROUP BY waybill_tag

UNION ALL

/* 分关联路径（核对用） */
SELECT
    link_type AS 月份,
    COUNT(DISTINCT waybill_id) AS 运单量
FROM dx_all
GROUP BY link_type

ORDER BY 月份;
