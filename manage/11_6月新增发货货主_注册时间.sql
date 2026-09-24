/* 6月新增发货货主的注册时间 | 仅投流渠道
 * 口径对齐 03：发货=TMS运单创建日 ∪ 货源发布日；新增=企业历史上首次发货日落在6月
 * 投流= company_tl 宽口径（信息流+拼表单）；注册时间=企业 create_date
 */
WITH tim AS (
    SELECT
        DATE '2026-06-01' AS month_start,
        DATE '2026-06-30' AS month_end
),
comp AS (
    SELECT
        DATE(SUBSTR(create_date, 1, 10)) AS register_dt,
        company_id,
        company_name
    FROM dwd_vlsp_mt_em_company_manage_info_minf
    WHERE company_id IS NOT NULL
      AND is_fake_company_apply_user = '0'
),
company_tl AS (
    SELECT DISTINCT COALESCE(t1.company_id, t3.company_id) AS company_id
    FROM (
        /* 信息流投放 */
        SELECT a.user_id
        FROM dwd_vlsp_mt_bt_advertise_placement_business_process_minf a
        WHERE a.user_id <> ''
        UNION
        /* 拼表单投放 */
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
/* 企业首次发货日 */
first_ship AS (
    SELECT
        company_id,
        MIN(create_dt) AS first_ship_dt
    FROM base
    GROUP BY company_id
),
/* 6月新增发货货主（仅投流）：首次发货日落在6月且命中投流 */
june_new_shipper AS (
    SELECT
        fs.company_id,
        fs.first_ship_dt,
        c.company_name,
        c.register_dt
    FROM first_ship fs
    INNER JOIN company_tl tl
        ON tl.company_id = fs.company_id
    LEFT JOIN comp c
        ON c.company_id = fs.company_id
    CROSS JOIN tim t
    WHERE fs.first_ship_dt >= t.month_start
      AND fs.first_ship_dt <= t.month_end
)

/* ===== 明细 ===== */
SELECT
    company_id AS 企业ID,
    company_name AS 企业名称,
    register_dt AS 注册日期,
    first_ship_dt AS 首次发货日,
    DATEDIFF(first_ship_dt, register_dt) AS 注册到首次发货天数,
    DATE_FORMAT(register_dt, '%Y-%m') AS 注册月份,
    DATE(DATE_SUB(register_dt, INTERVAL ((WEEKDAY(register_dt) - 2 + 7) % 7) DAY)) AS 注册周起始日
FROM june_new_shipper
ORDER BY register_dt, first_ship_dt, company_id;

/* ===== 如需按注册月份汇总，可改用下面这段替换上面 SELECT =====
SELECT
    DATE_FORMAT(register_dt, '%Y-%m') AS 注册月份,
    COUNT(DISTINCT company_id) AS 货主数
FROM june_new_shipper
GROUP BY DATE_FORMAT(register_dt, '%Y-%m')
ORDER BY 注册月份;
*/
