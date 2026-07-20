/* 注册/认证 + 新老货主 + 发货/成交 | 周度 + 月度
 * 投流注册账号/注册企业/认证企业：宽口径（信息流+拼表单货主，按事件日归期，不要求事件日>=引流日）
 */
WITH tim AS (
    SELECT
        DATE '2026-07-01' AS range_start,
        DATE '2026-07-20' AS range_end,   /* 统计截止日，右闭：event_dt <= range_end */
        DATE '2026-07-01' AS cutoff_dt  /* 新老货主分界 */
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
        WHERE b.user_base_id <> ''
    ) ad
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t1
        ON ad.user_id = t1.user_base_id
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t3
        ON t3.psn_acct_user_base_id = ad.user_id
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
company_pool AS (
    SELECT company_id, company_name FROM comp
    UNION
    SELECT DISTINCT
        process_shipper_company_id AS company_id,
        process_shipper_company_name AS company_name
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf
    WHERE process_shipper_company_id IS NOT NULL
),
company_initiative AS (
    SELECT company_id, '货主招募' AS initiative FROM company_zm
    UNION
    SELECT company_id, '投流' FROM company_tl
    UNION
    SELECT cp.company_id, '电销'
    FROM company_pool cp
    INNER JOIN company_dx dx ON dx.company_name_dx = cp.company_name
    UNION
    SELECT cp.company_id, '调度'
    FROM company_pool cp
    INNER JOIN company_dd dd ON dd.company_name_dd = cp.company_name
    UNION
    SELECT company_id, '线下'
    FROM company_wxx
    WHERE sales_lv1_company_id IS NOT NULL
    UNION
    SELECT cp.company_id, '无线下销售归属'
    FROM company_pool cp
    LEFT JOIN company_wxx w  ON w.company_id = cp.company_id
    LEFT JOIN company_zm zm ON zm.company_id = cp.company_id
    LEFT JOIN company_tl tl ON tl.company_id = cp.company_id
    LEFT JOIN company_dx dx ON dx.company_name_dx = cp.company_name
    LEFT JOIN company_dd dd ON dd.company_name_dd = cp.company_name
    WHERE w.sales_lv1_company_id IS NULL
      AND zm.company_id IS NULL
      AND tl.company_id IS NULL
      AND dx.company_name_dx IS NULL
      AND dd.company_name_dd IS NULL
),
register_fact AS (
    SELECT
        c.company_id,
        ci.initiative,
        ow.shipper_type,
        DATE(c.register_dt) AS event_dt
    FROM comp c
    INNER JOIN company_initiative ci ON ci.company_id = c.company_id
    LEFT JOIN old_new ow ON ow.company_id = c.company_id
    CROSS JOIN tim t
    WHERE c.register_dt >= t.range_start
      AND c.register_dt <= t.range_end
),
certify_fact AS (
    SELECT
        c.company_id,
        ci.initiative,
        ow.shipper_type,
        DATE(c.audit_dt) AS event_dt
    FROM comp c
    INNER JOIN company_initiative ci ON ci.company_id = c.company_id
    LEFT JOIN old_new ow ON ow.company_id = c.company_id
    CROSS JOIN tim t
    WHERE c.audit_dt IS NOT NULL
      AND c.audit_dt >= t.range_start
      AND c.audit_dt <= t.range_end
),
ship_fact AS (
    SELECT
        b.company_id,
        ci.initiative,
        ow.shipper_type,
        DATE(b.create_dt) AS event_dt
    FROM base b
    INNER JOIN company_initiative ci ON ci.company_id = b.company_id
    INNER JOIN old_new ow ON ow.company_id = b.company_id
    CROSS JOIN tim t
    WHERE b.create_dt >= t.range_start
      AND b.create_dt <= t.range_end
),
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        waybill.shipper_company_id,
        DATE(waybill.accept_dt) AS event_dt,
        old_new.shipper_type,
        CASE WHEN wxx.sales_lv1_company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_offline,
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
    LEFT JOIN old_new
        ON old_new.company_id = waybill.shipper_company_id
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
waybill_split AS (
    SELECT
        *,
        hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx AS hit_cnt
    FROM waybill_hit
),
waybill_initiative AS (
    SELECT event_dt, shipper_company_id, shipper_type, waybill_id, '货主招募' AS initiative,
           CASE WHEN hit_zm = 1 THEN 1.0 / NULLIF(hit_cnt, 0) ELSE 0 END AS weight
    FROM waybill_split WHERE hit_cnt > 0
    UNION ALL
    SELECT event_dt, shipper_company_id, shipper_type, waybill_id, '投流',
           CASE WHEN hit_tl = 1 THEN 1.0 / NULLIF(hit_cnt, 0) ELSE 0 END
    FROM waybill_split WHERE hit_cnt > 0
    UNION ALL
    SELECT event_dt, shipper_company_id, shipper_type, waybill_id, '电销',
           CASE WHEN hit_dx = 1 THEN 1.0 / NULLIF(hit_cnt, 0) ELSE 0 END
    FROM waybill_split WHERE hit_cnt > 0
    UNION ALL
    SELECT event_dt, shipper_company_id, shipper_type, waybill_id, '调度',
           CASE WHEN hit_dd = 1 THEN 1.0 / NULLIF(hit_cnt, 0) ELSE 0 END
    FROM waybill_split WHERE hit_cnt > 0
    UNION ALL
    SELECT event_dt, shipper_company_id, shipper_type, waybill_id, '无线下销售归属',
           CASE WHEN hit_wxx = 1 THEN 1.0 / NULLIF(hit_cnt, 0) ELSE 0 END
    FROM waybill_split WHERE hit_cnt > 0
    UNION ALL
    SELECT event_dt, shipper_company_id, shipper_type, waybill_id, '线下',
           CASE WHEN hit_offline = 1 THEN 1.0 ELSE 0 END
    FROM waybill_split
),
waybill_initiative_filtered AS (
    SELECT * FROM waybill_initiative
    WHERE weight > 0 AND shipper_type IS NOT NULL
),
metric_union AS (
    /* 注册/认证企业：投流改走宽口径 tl_*_metric，此处排除投流避免双计 */
    SELECT '月' AS stat_granularity, DATE_FORMAT(event_dt, '%Y-%m-01') AS period_start,
           initiative, shipper_type, '注册企业数' AS metric_type, COUNT(DISTINCT company_id) AS metric_value
    FROM register_fact WHERE shipper_type IS NOT NULL AND initiative <> '投流'
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type
    UNION ALL
    SELECT '周', DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
           initiative, shipper_type, '注册企业数', COUNT(DISTINCT company_id)
    FROM register_fact WHERE shipper_type IS NOT NULL AND initiative <> '投流'
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY), initiative, shipper_type
    UNION ALL
    SELECT '月', DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type, '认证企业数', COUNT(DISTINCT company_id)
    FROM certify_fact WHERE shipper_type IS NOT NULL AND initiative <> '投流'
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type
    UNION ALL
    SELECT '周', DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
           initiative, shipper_type, '认证企业数', COUNT(DISTINCT company_id)
    FROM certify_fact WHERE shipper_type IS NOT NULL AND initiative <> '投流'
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY), initiative, shipper_type
    UNION ALL
    SELECT '月', DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type, '发货货主数', COUNT(DISTINCT company_id)
    FROM ship_fact
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type
    UNION ALL
    SELECT '周', DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
           initiative, shipper_type, '发货货主数', COUNT(DISTINCT company_id)
    FROM ship_fact
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY), initiative, shipper_type
    UNION ALL
    SELECT '月', DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type, '成交货主数', COUNT(DISTINCT shipper_company_id)
    FROM waybill_initiative_filtered
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type
    UNION ALL
    SELECT '周', DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
           initiative, shipper_type, '成交货主数', COUNT(DISTINCT shipper_company_id)
    FROM waybill_initiative_filtered
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY), initiative, shipper_type
    UNION ALL
    SELECT '月', DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type, '成交运单量', SUM(weight)
    FROM waybill_initiative_filtered
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type
    UNION ALL
    SELECT '周', DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
           initiative, shipper_type, '成交运单量', SUM(weight)
    FROM waybill_initiative_filtered
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY), initiative, shipper_type
),

/* ========== 投流宽口径（对齐漏斗 ktf_*：不要求事件日>=引流日） ========== */
/* 用户池：信息流 + 拼表单，货主；企业池：company_tl 全量（不限 is_shipper） */
tl_user AS (
    SELECT DISTINCT
        ad.user_id,
        SUBSTR(ad.ad_time, 1, 10) AS ad_dt,
        COALESCE(SUBSTR(t1.register_time, 1, 10), SUBSTR(t2.register_time, 1, 10)) AS register_dt
    FROM (
        SELECT
            a.user_id,
            COALESCE(a.login_convert_time, a.auth_convert_time, a.consign_convert_time) AS ad_time
        FROM dwd_vlsp_mt_bt_advertise_placement_business_process_minf a
        WHERE a.user_id <> ''
        UNION ALL
        SELECT
            b.user_base_id AS user_id,
            a.clue_time AS ad_time
        FROM match_shipper_table_advertise_info a
        LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf b
            ON a.telephone = b.telephone
        WHERE b.user_base_id <> ''
    ) ad
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t1
        ON ad.user_id = t1.user_base_id
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t2
        ON t1.psn_acct_user_base_id = t2.user_base_id
    WHERE t1.is_shipper = 1 OR t2.is_shipper = 1
),
/* 注册账号-宽口径：ktf_zc_acct_cnt，按个人注册日归期 */
tl_register_account_base AS (
    SELECT
        DATE(u.register_dt) AS event_dt,
        u.user_id
    FROM tl_user u
    CROSS JOIN tim t
    WHERE u.register_dt IS NOT NULL
      AND u.register_dt >= t.range_start
      AND u.register_dt <= t.range_end
),
tl_register_account_metric AS (
    SELECT
        '月' AS stat_granularity,
        DATE_FORMAT(event_dt, '%Y-%m-01') AS period_start,
        '投流' AS initiative,
        '整体' AS shipper_type,
        '注册账号' AS metric_type,
        COUNT(DISTINCT user_id) AS metric_value
    FROM tl_register_account_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
    UNION ALL
    SELECT
        '周',
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        '投流', '整体', '注册账号',
        COUNT(DISTINCT user_id)
    FROM tl_register_account_base
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY)
),
/* 注册企业数-宽口径：ktf_qyzc_comp_cnt = company_tl ∩ 期间创建企业，不拆新老、不限 is_shipper */
tl_register_comp_base AS (
    SELECT
        DATE(c.register_dt) AS event_dt,
        c.company_id
    FROM comp c
    INNER JOIN company_tl tl ON tl.company_id = c.company_id
    CROSS JOIN tim t
    WHERE c.register_dt >= t.range_start
      AND c.register_dt <= t.range_end
),
tl_register_comp_metric AS (
    SELECT
        '月' AS stat_granularity,
        DATE_FORMAT(event_dt, '%Y-%m-01') AS period_start,
        '投流' AS initiative,
        '整体' AS shipper_type,
        '注册企业数' AS metric_type,
        COUNT(DISTINCT company_id) AS metric_value
    FROM tl_register_comp_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
    UNION ALL
    SELECT
        '周',
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        '投流', '整体', '注册企业数',
        COUNT(DISTINCT company_id)
    FROM tl_register_comp_base
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY)
),
/* 认证企业数-宽口径：ktf_qyrz_comp_cnt = company_tl ∩ 期间认证企业 */
tl_certify_comp_base AS (
    SELECT
        DATE(c.audit_dt) AS event_dt,
        c.company_id
    FROM comp c
    INNER JOIN company_tl tl ON tl.company_id = c.company_id
    CROSS JOIN tim t
    WHERE c.audit_dt IS NOT NULL
      AND c.audit_dt >= t.range_start
      AND c.audit_dt <= t.range_end
),
tl_certify_comp_metric AS (
    SELECT
        '月' AS stat_granularity,
        DATE_FORMAT(event_dt, '%Y-%m-01') AS period_start,
        '投流' AS initiative,
        '整体' AS shipper_type,
        '认证企业数' AS metric_type,
        COUNT(DISTINCT company_id) AS metric_value
    FROM tl_certify_comp_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
    UNION ALL
    SELECT
        '周',
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        '投流', '整体', '认证企业数',
        COUNT(DISTINCT company_id)
    FROM tl_certify_comp_base
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY)
),

metric_all AS (
    SELECT * FROM metric_union
    UNION ALL
    SELECT * FROM tl_register_account_metric
    UNION ALL
    SELECT * FROM tl_register_comp_metric
    UNION ALL
    SELECT * FROM tl_certify_comp_metric
)
SELECT
    CONCAT(
        initiative, '-', shipper_type, '-', metric_type
    ) AS 主键,
    CASE stat_granularity WHEN '月' THEN '月度' WHEN '周' THEN '周度' END AS 月周标识,
    period_start AS 周期起始日,
    initiative AS 举措,
    shipper_type AS 新老货主,
    metric_type AS 指标类型,
    metric_value AS 指标值
FROM metric_all
ORDER BY
    CASE stat_granularity WHEN '月' THEN 1 WHEN '周' THEN 2 END,
    period_start,
    CASE initiative
        WHEN '货主招募' THEN 1 WHEN '投流' THEN 2 WHEN '电销' THEN 3
        WHEN '调度' THEN 4 WHEN '线下' THEN 5 WHEN '无线下销售归属' THEN 6 ELSE 99
    END,
    CASE shipper_type WHEN '新货主' THEN 1 WHEN '老货主' THEN 2 WHEN '整体' THEN 0 ELSE 99 END,
    CASE metric_type
        WHEN '注册企业数' THEN 1 WHEN '注册账号' THEN 2 WHEN '认证企业数' THEN 3
        WHEN '发货货主数' THEN 4 WHEN '成交货主数' THEN 5 WHEN '成交运单量' THEN 6
    END;
