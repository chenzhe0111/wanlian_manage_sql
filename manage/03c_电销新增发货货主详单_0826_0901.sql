/* 电销 · 新增发货货主详单 | 2026-08-26～09-01（对齐 03c：周也按「当月首活」）
 * 若要对齐「当周首次发货算新增」，改用 03d_电销新增发货货主详单_0826_0901.sql
 *
 * 口径同 03c：
 *   发货 = TMS 运单创建日 ∪ 货源发布日
 *   电销 = company_pool 企业名命中电销 leads
 *   新货主 = first_dt >= 发货日所在月月初
 *
 * 本周一行一企；行数应 = 03c 该周 电销/新货主/发货货主数
 */
WITH tim0 AS (
    SELECT
        DATE '2026-08-26' AS range_start,
        DATE '2026-09-01' AS as_of_dt
),
comp AS (
    SELECT
        SUBSTR(create_date, 1, 10) AS register_dt,
        CASE
            WHEN original_company_type IN (5, 7, 8)
             AND license_aptitude_status = 3
                THEN SUBSTR(license_aptitude_time, 1, 10)
            WHEN original_company_type IN (1, 2, 3, 4)
             AND license_aptitude_status = 3
             AND authorize_audit_status = 30
                THEN SUBSTR(
                    IF(license_aptitude_time > authorize_audit_time,
                       license_aptitude_time,
                       authorize_audit_time),
                    1, 10
                )
        END AS audit_dt,
        company_id,
        company_name
    FROM dwd_vlsp_mt_em_company_manage_info_minf
    WHERE company_id IS NOT NULL
      AND is_fake_company_apply_user = '0'
),
tms_waybill AS (
    SELECT waybill_create_time, shipper_company_id, waybill_id
    FROM dwd_vlsp_mt_match_waybill_tms_business_process_minf
    WHERE COALESCE(shipper_company_id, '') NOT IN (
        '065d39e9afac48d8a0bdc5896c18d96c',
        '1993982792389951488',
        '1993985265305452544',
        '1994003031330062336'
    )
      AND tms_flag = 10
    GROUP BY 1, 2, 3
),
goods AS (
    SELECT create_dt, publish_company_id, goods_id
    FROM dwd_vlsp_mt_em_goods_manage_info_minf
    WHERE goods_status <> 10
      AND COALESCE(publish_company_id, '') NOT IN (
        '065d39e9afac48d8a0bdc5896c18d96c',
        '1993982792389951488',
        '1993985265305452544',
        '1994003031330062336'
    )
      AND goods_id NOT IN ('CHQY20251204000000016246', 'CHQY20251211000000012094')
    GROUP BY 1, 2, 3
),
base AS (
    SELECT DATE(waybill_create_time) AS create_dt, shipper_company_id AS company_id
    FROM tms_waybill
    UNION
    SELECT create_dt, publish_company_id AS company_id
    FROM goods
),
company_first AS (
    SELECT company_id, create_dt AS first_dt
    FROM (
        SELECT
            company_id,
            create_dt,
            ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY create_dt) AS rn
        FROM base
    ) t
    WHERE rn = 1
),
company_dx AS (
    SELECT DISTINCT company_name AS company_name_dx
    FROM match_shipper_telesales_leads_info
),
company_pool AS (
    SELECT company_id, company_name FROM comp
    UNION
    SELECT DISTINCT
        process_shipper_company_id AS company_id,
        process_shipper_company_name AS company_name
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf
    WHERE process_shipper_company_id IS NOT NULL
),
company_dx_id AS (
    SELECT DISTINCT cp.company_id
    FROM company_pool cp
    INNER JOIN company_dx dx ON dx.company_name_dx = cp.company_name
),
ship_fact_dx_new AS (
    SELECT
        b.company_id,
        DATE(b.create_dt) AS event_dt,
        cf.first_dt
    FROM base b
    INNER JOIN company_dx_id dx ON dx.company_id = b.company_id
    INNER JOIN company_first cf ON cf.company_id = b.company_id
    CROSS JOIN tim0 t
    WHERE b.create_dt >= t.range_start
      AND b.create_dt <= t.as_of_dt
      AND cf.first_dt >= DATE_FORMAT(DATE(b.create_dt), '%Y-%m-01')
)
SELECT
    f.company_id AS 企业ID,
    MAX(c.company_name) AS 企业名称,
    MIN(f.first_dt) AS 首活日,
    MIN(f.event_dt) AS 本周首次新增发货日,
    MAX(f.event_dt) AS 本周末次新增发货日,
    COUNT(DISTINCT f.event_dt) AS 本周新增发货天数,
    MAX(c.register_dt) AS 注册日,
    MAX(c.audit_dt) AS 认证日
FROM ship_fact_dx_new f
LEFT JOIN comp c ON c.company_id = f.company_id
GROUP BY f.company_id
ORDER BY 本周首次新增发货日, f.company_id
;
