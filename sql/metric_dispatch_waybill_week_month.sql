/* 调度专项分析 | 网货：调度整体注册/认证/发货+网货成交；TMS：创建运单货主数+成交；撮合：成交 | 周度+月度 */
WITH tim AS (
    SELECT
        DATE '2026-07-01' AS range_start,
        DATE '2026-07-12' AS range_end,
        DATE '2026-07-01' AS cutoff_dt  /* 新老货主分界，发货口径与主 SQL 一致 */
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
old_new AS (
    SELECT
        company_id,
        CASE
            WHEN create_dt >= (SELECT cutoff_dt FROM tim) THEN '新货主'
            WHEN create_dt <  (SELECT cutoff_dt FROM tim) THEN '老货主'
        END AS shipper_type
    FROM (
        SELECT
            company_id,
            create_dt,
            ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY create_dt) AS rn
        FROM base
    ) t
    WHERE rn = 1
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
company_zm AS (
    SELECT DISTINCT invitee_id AS company_id
    FROM dwd_vlsp_mt_user_recruitment_business_process_minf
    WHERE activity_title = '货主招募活动'
      AND invitee_id IS NOT NULL
      AND invitee_id <> ''
),
company_tl_channel AS (
    SELECT DISTINCT company.company_id
    FROM dwd_vlsp_mt_em_user_manage_info_minf usr
    INNER JOIN ads.ads_vlsp_tms_advertise_placement_channel_info_df channel
        ON channel.telephone = usr.telephone
    INNER JOIN dwd_vlsp_mt_em_company_manage_info_minf company
        ON company.company_apply_user_base_id = usr.user_base_id
    WHERE usr.user_status = 11
      AND usr.deleted = 21
      AND usr.account_type = 10
      AND company.company_id IS NOT NULL
),
company_tl AS (
    SELECT company_id
    FROM (
        SELECT u.company_id
        FROM dwd.dwd_vlsp_mt_bt_advertise_placement_business_process_minf ad
        LEFT JOIN (
            SELECT user_base_id, company_id
            FROM dwd.dwd_vlsp_mt_em_user_manage_info_minf
            WHERE user_status = 11 AND deleted = 21
            GROUP BY user_base_id, company_id
        ) u ON u.user_base_id = ad.user_id
        WHERE ad.user_id <> ''
          AND ad.consign_callback_status = 10
          AND u.company_id IS NOT NULL
        UNION
        SELECT company_id FROM company_tl_channel
    ) t
    GROUP BY company_id
),
company_dx AS (
    SELECT DISTINCT shipper_company_name AS company_name_dx
    FROM ads.ads_vlsp_tms_shipper_and_dispatch_info_df
    WHERE shipper_source = '电销'
),
company_dd AS (
    SELECT DISTINCT shipper_company_name AS company_name_dd
    FROM ads.ads_vlsp_tms_shipper_and_dispatch_info_df
    WHERE shipper_source = '调度'
),
company_dispatch AS (
    SELECT cp.company_id
    FROM company_pool cp
    INNER JOIN company_dd dd ON dd.company_name_dd = cp.company_name
    GROUP BY cp.company_id
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
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        waybill.shipper_company_id,
        DATE(waybill.accept_dt) AS event_dt,
        CASE
            WHEN waybill.invoice_type = 20 THEN '网货'
            WHEN waybill.invoice_type = 10 AND waybill.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_category,
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
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    LEFT JOIN company_zm zm
        ON zm.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl tl
        ON tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx dx
        ON dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd dd
        ON dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx wxx
        ON wxx.company_id = waybill.process_shipper_company_id
    CROSS JOIN tim t
    WHERE DATE(waybill.accept_dt) >= t.range_start
      AND DATE(waybill.accept_dt) <  t.range_end
      AND waybill.waybill_status NOT IN (540, 100)
      AND NVL(waybill.shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          1993982792389951488,
          1993985265305452544,
          1994003031330062336
      )
      AND (
          waybill.tms_flag = 20
          OR (waybill.tms_flag = 10 AND waybill.driver_operate_accept_time IS NOT NULL)
      )
),
dispatch_waybill_base AS (
    SELECT
        wh.event_dt,
        wh.waybill_id,
        wh.shipper_company_id,
        wh.waybill_category,
        1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) AS weight
    FROM waybill_hit wh
    WHERE wh.hit_dd = 1
      AND wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx > 0
),
dispatch_register_base AS (
    SELECT
        c.company_id,
        DATE(c.register_dt) AS event_dt
    FROM comp c
    INNER JOIN company_dispatch dd ON dd.company_id = c.company_id
    CROSS JOIN tim t
    WHERE c.register_dt >= t.range_start
      AND c.register_dt <  t.range_end
),
dispatch_certify_base AS (
    SELECT
        c.company_id,
        DATE(c.audit_dt) AS event_dt
    FROM comp c
    INNER JOIN company_dispatch dd ON dd.company_id = c.company_id
    CROSS JOIN tim t
    WHERE c.audit_dt IS NOT NULL
      AND c.audit_dt >= t.range_start
      AND c.audit_dt <  t.range_end
),
dispatch_ship_base AS (
    SELECT
        b.company_id,
        DATE(b.create_dt) AS event_dt
    FROM base b
    INNER JOIN company_dispatch cd ON cd.company_id = b.company_id
    INNER JOIN old_new ow ON ow.company_id = b.company_id
    CROSS JOIN tim t
    WHERE b.create_dt >= t.range_start
      AND b.create_dt <  t.range_end
),
/* TMS 创建运单货主数：TMS运单创建(waybill_create) + 计划单JHD创建(jhd_create)，调度名单按企业名匹配 */
tms_waybill_create AS (
    SELECT DISTINCT
        DATE(waybill.waybill_create_time) AS event_dt,
        waybill.shipper_company_name AS company_name
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    INNER JOIN company_dd dd ON dd.company_name_dd = waybill.shipper_company_name
    CROSS JOIN tim t
    WHERE COALESCE(waybill.shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          '1993982792389951488',
          '1993985265305452544',
          '1994003031330062336'
      )
      AND waybill.tms_flag = 10
      AND DATE(waybill.waybill_create_time) >= t.range_start
      AND DATE(waybill.waybill_create_time) <  t.range_end
),
tms_jhd_create AS (
    SELECT DISTINCT
        DATE(goods.create_dt) AS event_dt,
        goods.publish_company_name AS company_name
    FROM dwd_vlsp_mt_em_goods_manage_info_minf goods
    INNER JOIN company_dd dd ON dd.company_name_dd = goods.publish_company_name
    CROSS JOIN tim t
    WHERE goods.goods_status <> 10
      AND COALESCE(goods.publish_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          '1993982792389951488',
          '1993985265305452544',
          '1994003031330062336'
      )
      AND goods.goods_id NOT IN ('CHQY20251204000000016246', 'CHQY20251211000000012094')
      AND goods.goods_id LIKE 'JHD%'
      AND DATE(goods.create_dt) >= t.range_start
      AND DATE(goods.create_dt) <  t.range_end
),
tms_create_base AS (
    SELECT event_dt, company_name FROM tms_waybill_create
    UNION
    SELECT event_dt, company_name FROM tms_jhd_create
),
metric_union AS (
    SELECT
        '月' AS stat_granularity,
        DATE_FORMAT(event_dt, '%Y-%m-01') AS period_start,
        '调度' AS initiative,
        waybill_category AS waybill_type,
        '成交运单量' AS metric_type,
        SUM(weight) AS metric_value
    FROM dispatch_waybill_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), waybill_category
    UNION ALL
    SELECT
        '周',
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        '调度',
        waybill_category,
        '成交运单量',
        SUM(weight)
    FROM dispatch_waybill_base
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY), waybill_category
    UNION ALL
    SELECT
        '月',
        DATE_FORMAT(event_dt, '%Y-%m-01'),
        '调度',
        waybill_category,
        '成交货主数',
        COUNT(DISTINCT shipper_company_id)
    FROM dispatch_waybill_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), waybill_category
    UNION ALL
    SELECT
        '周',
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        '调度',
        waybill_category,
        '成交货主数',
        COUNT(DISTINCT shipper_company_id)
    FROM dispatch_waybill_base
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY), waybill_category
    UNION ALL
    SELECT
        '月',
        DATE_FORMAT(event_dt, '%Y-%m-01'),
        '调度',
        'TMS',
        '创建运单货主数',
        COUNT(DISTINCT company_name)
    FROM tms_create_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
    UNION ALL
    SELECT
        '周',
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        '调度',
        'TMS',
        '创建运单货主数',
        COUNT(DISTINCT company_name)
    FROM tms_create_base
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY)
    UNION ALL
    SELECT
        '月',
        DATE_FORMAT(event_dt, '%Y-%m-01'),
        '调度',
        '网货',
        '注册企业数',
        COUNT(DISTINCT company_id)
    FROM dispatch_register_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
    UNION ALL
    SELECT
        '周',
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        '调度',
        '网货',
        '注册企业数',
        COUNT(DISTINCT company_id)
    FROM dispatch_register_base
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY)
    UNION ALL
    SELECT
        '月',
        DATE_FORMAT(event_dt, '%Y-%m-01'),
        '调度',
        '网货',
        '认证企业数',
        COUNT(DISTINCT company_id)
    FROM dispatch_certify_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
    UNION ALL
    SELECT
        '周',
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        '调度',
        '网货',
        '认证企业数',
        COUNT(DISTINCT company_id)
    FROM dispatch_certify_base
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY)
    UNION ALL
    SELECT
        '月',
        DATE_FORMAT(event_dt, '%Y-%m-01'),
        '调度',
        '网货',
        '发货货主数',
        COUNT(DISTINCT company_id)
    FROM dispatch_ship_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
    UNION ALL
    SELECT
        '周',
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        '调度',
        '网货',
        '发货货主数',
        COUNT(DISTINCT company_id)
    FROM dispatch_ship_base
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY)
)
SELECT
    CONCAT(initiative, '-', waybill_type, '-', metric_type) AS 主键,
    CASE stat_granularity WHEN '月' THEN '月度' WHEN '周' THEN '周度' END AS 月周标识,
    period_start AS 周期起始日,
    initiative AS 举措,
    waybill_type AS 类型,
    metric_type AS 指标类型,
    metric_value AS 指标值
FROM metric_union
ORDER BY
    CASE stat_granularity WHEN '月' THEN 1 WHEN '周' THEN 2 END,
    period_start,
    CASE waybill_type WHEN '网货' THEN 1 WHEN 'TMS' THEN 2 WHEN '撮合' THEN 3 ELSE 99 END,
    CASE metric_type
        WHEN '注册企业数' THEN 1 WHEN '认证企业数' THEN 2 WHEN '发货货主数' THEN 3
        WHEN '创建运单货主数' THEN 4 WHEN '成交运单量' THEN 5 WHEN '成交货主数' THEN 6
        ELSE 99
    END;
