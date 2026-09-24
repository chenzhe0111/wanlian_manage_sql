/* 调度举措 · 按类型（网货/TMS/撮合）月周指标
 * 口径与 03_月度周度新老漏斗 对齐：
 *   - 运单分摊权重、调度名单（企业名匹配）逻辑不变
 *   - 发货侧首活日用 company_first；跨月周若后续扩展新老，按「事件所在月月初」判定
 *     first_dt >= DATE_FORMAT(event_dt,'%Y-%m-01') → 新；否则老
 *   - 本 SQL 输出维度是「类型」不是「新老」（与周报表调度漏斗一致）
 * 三方调度注册/认证：累计至当周期末日（跨月周 0729-0804 的 period_end=range_end）
 */
WITH tim AS (
    SELECT
        DATE '2026-07-01' AS range_start,
        DATE '2026-08-04' AS range_end   /* 右闭；含 0729-0804 跨月周，按需改 */
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
/* 仅存首活日（与 03 一致）；本 SQL 类型维度不输出新老，发货仍要求能判到首活 */
company_first AS (
    SELECT
        company_id,
        create_dt AS first_dt
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
company_tl AS (
    SELECT DISTINCT COALESCE(t1.company_id, t3.company_id) AS company_id
    FROM (
        SELECT a.user_id
        FROM dwd_vlsp_mt_bt_advertise_placement_business_process_minf a
        WHERE a.user_id <> ''
        UNION
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
company_dx AS (
    SELECT DISTINCT company_name AS company_name_dx
    FROM match_shipper_telesales_leads_info
),
company_dd AS (
    SELECT DISTINCT company_name AS company_name_dd
    FROM match_shipper_dispatching_leads_info
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
        /* 事件月新老（跨月周：7月段看7/1，8月段看8/1）；当前指标未按此拆分，预留与 03 对齐 */
        CASE
            WHEN cf.first_dt IS NULL THEN NULL
            WHEN cf.first_dt >= DATE_FORMAT(DATE(waybill.accept_dt), '%Y-%m-01') THEN '新货主'
            ELSE '老货主'
        END AS shipper_type,
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
    LEFT JOIN company_first cf
        ON cf.company_id = waybill.shipper_company_id
    CROSS JOIN tim t
    WHERE DATE(waybill.accept_dt) >= t.range_start
      AND DATE(waybill.accept_dt) <= t.range_end
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
        wh.shipper_type,
        1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) AS weight
    FROM waybill_hit wh
    WHERE wh.hit_dd = 1
      AND wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx > 0
),
dispatch_register_base AS (
    SELECT
        c.company_id,
        DATE(c.register_dt) AS event_dt,
        CASE
            WHEN cf.first_dt IS NULL THEN NULL
            WHEN cf.first_dt >= DATE_FORMAT(DATE(c.register_dt), '%Y-%m-01') THEN '新货主'
            ELSE '老货主'
        END AS shipper_type
    FROM comp c
    INNER JOIN company_dispatch dd ON dd.company_id = c.company_id
    LEFT JOIN company_first cf ON cf.company_id = c.company_id
    CROSS JOIN tim t
    WHERE c.register_dt >= t.range_start
      AND c.register_dt <= t.range_end
),
dispatch_certify_base AS (
    SELECT
        c.company_id,
        DATE(c.audit_dt) AS event_dt,
        CASE
            WHEN cf.first_dt IS NULL THEN NULL
            WHEN cf.first_dt >= DATE_FORMAT(DATE(c.audit_dt), '%Y-%m-01') THEN '新货主'
            ELSE '老货主'
        END AS shipper_type
    FROM comp c
    INNER JOIN company_dispatch dd ON dd.company_id = c.company_id
    LEFT JOIN company_first cf ON cf.company_id = c.company_id
    CROSS JOIN tim t
    WHERE c.audit_dt IS NOT NULL
      AND c.audit_dt >= t.range_start
      AND c.audit_dt <= t.range_end
),
dispatch_ship_base AS (
    SELECT
        b.company_id,
        DATE(b.create_dt) AS event_dt,
        CASE
            WHEN cf.first_dt >= DATE_FORMAT(DATE(b.create_dt), '%Y-%m-01') THEN '新货主'
            ELSE '老货主'
        END AS shipper_type
    FROM base b
    INNER JOIN company_dispatch cd ON cd.company_id = b.company_id
    INNER JOIN company_first cf ON cf.company_id = b.company_id
    CROSS JOIN tim t
    WHERE b.create_dt >= t.range_start
      AND b.create_dt <= t.range_end
),
/* TMS 创建运单货主数：TMS运单创建 + 计划单JHD创建，调度名单按企业名匹配 */
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
      AND DATE(waybill.waybill_create_time) <= t.range_end
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
      AND DATE(goods.create_dt) <= t.range_end
),
tms_create_base AS (
    SELECT event_dt, company_name FROM tms_waybill_create
    UNION
    SELECT event_dt, company_name FROM tms_jhd_create
),
dispatcher_user AS (
    SELECT
        user_base_id,
        DATE(SUBSTR(register_dt, 1, 10)) AS register_dt
    FROM dwd.dwd_vlsp_mt_em_user_manage_info_minf
    WHERE is_dispatcher = 1
      AND is_fake_user = '0'
      AND deleted = 21
      AND user_status = 11
      AND dispatch_type = 30
      AND COALESCE(user_base_id, '') <> ''
    GROUP BY user_base_id, DATE(SUBSTR(register_dt, 1, 10))
),
third_dispatch_base AS (
    SELECT
        DATE(w.accept_dt) AS event_dt,
        w.dispatcher_user_id AS user_base_id
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf w
    INNER JOIN dispatcher_user d
        ON d.user_base_id = w.dispatcher_user_id
    CROSS JOIN tim t
    WHERE DATE(w.accept_dt) >= t.range_start
      AND DATE(w.accept_dt) <= t.range_end
      AND COALESCE(w.dispatcher_user_id, '') <> ''
      AND w.waybill_status NOT IN (540, 100)
    GROUP BY DATE(w.accept_dt), w.dispatcher_user_id
),
/* 周期清单：月=range 内每个自然月（跨月周也出齐各月）；周=周三起始；跨月周 period_end = min(周结束, range_end) */
third_period AS (
    SELECT
        '月' AS stat_granularity,
        ADD_MONTHS(DATE_FORMAT(t.range_start, '%Y-%m-01'), m.n) AS period_start,
        LEAST(
            LAST_DAY(ADD_MONTHS(DATE_FORMAT(t.range_start, '%Y-%m-01'), m.n)),
            t.range_end
        ) AS period_end
    FROM tim t
    CROSS JOIN (
        SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2
        UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
    ) m
    WHERE ADD_MONTHS(DATE_FORMAT(t.range_start, '%Y-%m-01'), m.n) <= t.range_end
    UNION
    SELECT DISTINCT
        '周',
        ws.week_start,
        LEAST(DATE_ADD(ws.week_start, INTERVAL 6 DAY), t.range_end)
    FROM tim t
    CROSS JOIN (
        SELECT
            DATE_SUB(
                DATE_ADD(t2.range_start, INTERVAL s.n DAY),
                INTERVAL ((WEEKDAY(DATE_ADD(t2.range_start, INTERVAL s.n DAY)) - 2 + 7) % 7) DAY
            ) AS week_start
        FROM tim t2
        CROSS JOIN (
            SELECT 0 AS n UNION ALL SELECT 7 UNION ALL SELECT 14
            UNION ALL SELECT 21 UNION ALL SELECT 28 UNION ALL SELECT 35
            UNION ALL SELECT 42 UNION ALL SELECT 49 UNION ALL SELECT 56
            UNION ALL SELECT 63 UNION ALL SELECT 70 UNION ALL SELECT 77
        ) s
        WHERE DATE_ADD(t2.range_start, INTERVAL s.n DAY) <= t2.range_end
    ) ws
    WHERE ws.week_start <= t.range_end
      AND ws.week_start >= DATE_SUB(
            t.range_start,
            INTERVAL ((WEEKDAY(t.range_start) - 2 + 7) % 7) DAY
        )
),
/* 注册=认证：按周期累计至 period_end（0729 周累计到 0804） */
dispatcher_cum_by_period AS (
    SELECT
        p.stat_granularity,
        p.period_start,
        COUNT(DISTINCT d.user_base_id) AS total_cnt
    FROM third_period p
    CROSS JOIN dispatcher_user d
    WHERE d.register_dt IS NULL
       OR d.register_dt <= p.period_end
    GROUP BY p.stat_granularity, p.period_start
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
    UNION ALL
    SELECT
        c.stat_granularity,
        c.period_start,
        '调度',
        '撮合',
        '三方调度注册用户量',
        c.total_cnt
    FROM dispatcher_cum_by_period c
    UNION ALL
    SELECT
        c.stat_granularity,
        c.period_start,
        '调度',
        '撮合',
        '三方调度认证注册量',
        c.total_cnt
    FROM dispatcher_cum_by_period c
    UNION ALL
    SELECT
        '月',
        DATE_FORMAT(event_dt, '%Y-%m-01'),
        '调度',
        '撮合',
        '产生调度的用户量',
        COUNT(DISTINCT user_base_id)
    FROM third_dispatch_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
    UNION ALL
    SELECT
        '周',
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        '调度',
        '撮合',
        '产生调度的用户量',
        COUNT(DISTINCT user_base_id)
    FROM third_dispatch_base
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
        WHEN '三方调度注册用户量' THEN 7 WHEN '三方调度认证注册量' THEN 8
        WHEN '产生调度的用户量' THEN 9
        ELSE 99
    END;
