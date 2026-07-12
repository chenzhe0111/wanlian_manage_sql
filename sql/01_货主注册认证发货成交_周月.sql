/*
 * ============================================================================
 * 【脚本编号】sql/01
 * 【脚本名称】货主举措漏斗 — 注册 / 认证 / 发货 / 成交（周度 + 月度）
 * 【业务用途】
 *   - 按「举措 × 新老货主」统计：注册企业数、认证企业数、发货货主数、
 *     成交货主数、成交运单量
 *   - 「注册账号」为投流独立口径，UNION ALL 合并，不拆新老货主
 * 【输出字段】主键 | 月周标识 | 周期起始日 | 举措 | 新老货主 | 指标类型 | 指标值
 * 【举措】货主招募 | 投流 | 电销 | 调度 | 线下 | 无线下销售归属
 * 【新老货主】cutoff_dt 前首次发货 = 老货主，否则 = 新货主
 * 【时间参数】修改 tim：range_start / range_end（左闭右开）/ cutoff_dt
 * 【注册账号口径】login_callback_status=10 + party3/push_client 筛选，日期右闭
 * 【来源文档】https://wanlianyida.feishu.cn/wiki/JMtSwHtBVi7O97k1YxDcx2j0n8g
 * ============================================================================
 */
/* 注册/认证 + 新老货主 + 发货/成交 | 周度 + 月度；注册账号独立计算后 UNION ALL 合并 */
WITH tim AS (
    SELECT
        DATE '2026-07-01' AS range_start,
        DATE '2026-07-12' AS range_end,
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
      AND c.register_dt <  t.range_end
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
      AND c.audit_dt <  t.range_end
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
      AND b.create_dt <  t.range_end
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
    SELECT '月' AS stat_granularity, DATE_FORMAT(event_dt, '%Y-%m-01') AS period_start,
           initiative, shipper_type, '注册企业数' AS metric_type, COUNT(DISTINCT company_id) AS metric_value
    FROM register_fact WHERE shipper_type IS NOT NULL
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type
    UNION ALL
    SELECT '周', DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
           initiative, shipper_type, '注册企业数', COUNT(DISTINCT company_id)
    FROM register_fact WHERE shipper_type IS NOT NULL
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY), initiative, shipper_type
    UNION ALL
    SELECT '月', DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type, '认证企业数', COUNT(DISTINCT company_id)
    FROM certify_fact WHERE shipper_type IS NOT NULL
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type
    UNION ALL
    SELECT '周', DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
           initiative, shipper_type, '认证企业数', COUNT(DISTINCT company_id)
    FROM certify_fact WHERE shipper_type IS NOT NULL
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

/* ========== 注册账号：独立口径（不融入举措/新老货主逻辑） ========== */
/* 与看板一致：users + ad 完整 CTE，LEFT JOIN ad ON user_base_id = ad.user_id，投放=ad.user_id IS NOT NULL */
/* zc_users = COUNT(DISTINCT CASE WHEN is_shipper=1 THEN user_base_id END)；日期右闭 register_dt <= range_end */
reg_users AS (
    SELECT
        register_dt,
        reg_source_code,
        real_name_cert_status,
        user_base_id,
        is_shipper
    FROM dwd_vlsp_mt_em_user_manage_info_minf
    WHERE user_status = 11
      AND deleted = 21
      AND account_type = 10
    GROUP BY 1, 2, 3, 4, 5
),
reg_ad AS (
    SELECT
        ad.user_id,
        t2.user_base_id
    FROM (
        SELECT user_id
        FROM dwd_vlsp_mt_bt_advertise_placement_business_process_minf
        WHERE login_callback_status = 10
          AND user_id <> ''
          AND (
              party3_plf_acct_id IN (78862151, 78862170)
              OR push_client_type IN (20, 21)
          )
    ) ad
    LEFT JOIN (
        SELECT
            user_base_id,
            CASE
                WHEN psn_acct_user_base_id IS NULL OR TRIM(psn_acct_user_base_id) = ''
                    THEN user_base_id
                ELSE psn_acct_user_base_id
            END AS psn_acct_user_base_id,
            company_id
        FROM dwd_vlsp_mt_em_user_manage_info_minf
    ) t1 ON ad.user_id = t1.user_base_id
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t2
        ON t2.user_base_id = t1.psn_acct_user_base_id
       AND t2.account_type = 10
),
register_account_base AS (
    SELECT
        DATE(SUBSTR(u.register_dt, 1, 10)) AS event_dt,
        u.user_base_id
    FROM reg_users u
    LEFT JOIN reg_ad ad ON u.user_base_id = ad.user_id
    CROSS JOIN tim t
    WHERE ad.user_id IS NOT NULL                         /* user_tags = '投放' */
      AND u.is_shipper = 1
      AND CAST(u.register_dt AS DATE) >= t.range_start
      AND CAST(u.register_dt AS DATE) <= t.range_end     /* 右闭，与看板 register_dt<='2026-07-12' 一致 */
),
register_account_metric AS (
    SELECT
        '月' AS stat_granularity,
        DATE_FORMAT(event_dt, '%Y-%m-01') AS period_start,
        '投流' AS initiative,
        '整体' AS shipper_type,
        '注册账号' AS metric_type,
        COUNT(DISTINCT user_base_id) AS metric_value
    FROM register_account_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
    UNION ALL
    SELECT
        '周',
        DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY),
        '投流', '整体', '注册账号',
        COUNT(DISTINCT user_base_id)
    FROM register_account_base
    GROUP BY DATE_SUB(event_dt, INTERVAL ((WEEKDAY(event_dt) - 2 + 7) % 7) DAY)
),

metric_all AS (
    SELECT * FROM metric_union
    UNION ALL
    SELECT * FROM register_account_metric
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
