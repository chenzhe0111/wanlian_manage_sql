/* 月度新老货主 | 对齐整合表第七部分（举措 × 新增/留存）
 * 【本文件】不覆盖 03_月度周度新老漏斗_认证注册发货成交.sql
 * 逻辑同 03（成交轴 accept_dt，不是 46b 的履约剔异常）：
 *   1) 新老：first_dt（TMS创建∪货源发布）≥ 事件月月初 → 新货主，否则老货主
 *   2) 发货货主 / 成交货主 / 成交运单：四举措按 03 的等权分摊
 *   3) 电销、货主招募的注册/认证：全量记在新货主（03 原规则）
 *   4) 投流注册账号/注册企业/认证企业：宽口径，单独「投流-整体 / 投流-注册账号」，不拆新老
 *   5) 只出月度；截止日 = 昨天（T-1）
 *
 * 对齐飞书：https://wanlianyida.feishu.cn/sheets/L91EsEtAohwjhStD4y6cYLCGnVe 整合表
 *   新货主 → 新增；老货主 → 留存
 *   货主成交率 = 成交货主数 / 发货货主数
 *   单货主成交运单数 = 成交运单量 / 成交货主数（不是百分数）
 *   成交运单_万单 = 等权分摊后的运单量 / 10000
 *
 * 改日期：tim.range_start / range_end
 */
WITH tim AS (
    SELECT
        DATE '2026-08-01' AS range_start,                 /* 对照整合表从 8 月起 */
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS range_end
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
/* 仅存首活日；新老在各 fact 里按「事件月月初」动态判定 */
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
        CASE
            WHEN cf.first_dt IS NULL THEN NULL
            WHEN cf.first_dt >= DATE_FORMAT(DATE(c.register_dt), '%Y-%m-01') THEN '新货主'
            ELSE '老货主'
        END AS shipper_type,
        DATE(c.register_dt) AS event_dt
    FROM comp c
    INNER JOIN company_initiative ci ON ci.company_id = c.company_id
    LEFT JOIN company_first cf ON cf.company_id = c.company_id
    CROSS JOIN tim t
    WHERE c.register_dt >= t.range_start
      AND c.register_dt <= t.range_end
),
certify_fact AS (
    SELECT
        c.company_id,
        ci.initiative,
        CASE
            WHEN cf.first_dt IS NULL THEN NULL
            WHEN cf.first_dt >= DATE_FORMAT(DATE(c.audit_dt), '%Y-%m-01') THEN '新货主'
            ELSE '老货主'
        END AS shipper_type,
        DATE(c.audit_dt) AS event_dt
    FROM comp c
    INNER JOIN company_initiative ci ON ci.company_id = c.company_id
    LEFT JOIN company_first cf ON cf.company_id = c.company_id
    CROSS JOIN tim t
    WHERE c.audit_dt IS NOT NULL
      AND c.audit_dt >= t.range_start
      AND c.audit_dt <= t.range_end
),
ship_fact AS (
    SELECT
        b.company_id,
        ci.initiative,
        CASE
            WHEN cf.first_dt >= DATE_FORMAT(DATE(b.create_dt), '%Y-%m-01') THEN '新货主'
            ELSE '老货主'
        END AS shipper_type,
        DATE(b.create_dt) AS event_dt
    FROM base b
    INNER JOIN company_initiative ci ON ci.company_id = b.company_id
    INNER JOIN company_first cf ON cf.company_id = b.company_id
    CROSS JOIN tim t
    WHERE b.create_dt >= t.range_start
      AND b.create_dt <= t.range_end
),
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        waybill.shipper_company_id,
        DATE(waybill.accept_dt) AS event_dt,
        CASE
            WHEN cf.first_dt IS NULL THEN NULL
            WHEN cf.first_dt >= DATE_FORMAT(DATE(waybill.accept_dt), '%Y-%m-01') THEN '新货主'
            ELSE '老货主'
        END AS shipper_type,
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
            AND b.is_fake_user = '0'
        WHERE b.user_base_id <> ''
    ) ad
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t1
        ON ad.user_id = t1.user_base_id
        AND t1.is_fake_user = '0'
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t2
        ON t1.psn_acct_user_base_id = t2.user_base_id
        AND t2.is_fake_user = '0'
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

month_metric AS (
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01') AS mon,
           initiative, '新货主' AS shipper_type, '注册企业数' AS metric_type,
           COUNT(DISTINCT company_id) AS metric_value
    FROM register_fact
    WHERE initiative IN ('电销', '货主招募')
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative
    UNION ALL
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, '新货主', '认证企业数',
           COUNT(DISTINCT company_id)
    FROM certify_fact
    WHERE initiative IN ('电销', '货主招募')
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative
    UNION ALL
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type, '注册企业数',
           COUNT(DISTINCT company_id)
    FROM register_fact
    WHERE shipper_type IS NOT NULL
      AND initiative = '调度'
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type
    UNION ALL
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type, '认证企业数',
           COUNT(DISTINCT company_id)
    FROM certify_fact
    WHERE shipper_type IS NOT NULL
      AND initiative = '调度'
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type
    UNION ALL
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type, '发货货主数',
           COUNT(DISTINCT company_id)
    FROM ship_fact
    WHERE initiative IN ('货主招募', '电销', '投流', '调度')
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type
    UNION ALL
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type, '成交货主数',
           COUNT(DISTINCT shipper_company_id)
    FROM waybill_initiative_filtered
    WHERE initiative IN ('货主招募', '电销', '投流', '调度')
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type
    UNION ALL
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type, '成交运单量',
           SUM(weight)
    FROM waybill_initiative_filtered
    WHERE initiative IN ('货主招募', '电销', '投流', '调度')
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01'), initiative, shipper_type
),
tl_wide AS (
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01') AS mon, '注册账号' AS metric_type, COUNT(DISTINCT user_id) AS metric_value
    FROM tl_register_account_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
    UNION ALL
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01'), '注册企业数', COUNT(DISTINCT company_id)
    FROM tl_register_comp_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
    UNION ALL
    SELECT DATE_FORMAT(event_dt, '%Y-%m-01'), '认证企业数', COUNT(DISTINCT company_id)
    FROM tl_certify_comp_base
    GROUP BY DATE_FORMAT(event_dt, '%Y-%m-01')
),
pivoted AS (
    SELECT
        mon,
        initiative,
        shipper_type,
        SUM(CASE WHEN metric_type = '发货货主数' THEN metric_value END) AS ship_cnt,
        SUM(CASE WHEN metric_type = '成交货主数' THEN metric_value END) AS deal_cnt,
        SUM(CASE WHEN metric_type = '成交运单量' THEN metric_value END) AS waybill_cnt,
        SUM(CASE WHEN metric_type = '注册企业数' THEN metric_value END) AS reg_cnt,
        SUM(CASE WHEN metric_type = '认证企业数' THEN metric_value END) AS audit_cnt
    FROM month_metric
    GROUP BY mon, initiative, shipper_type
),
out_rows AS (
    SELECT
        DATE_FORMAT(p.mon, '%Y-%m') AS 月份,
        '举措新老' AS 维度层级,
        CONCAT(p.initiative, '-', p.shipper_type) AS 维度,
        CASE p.shipper_type WHEN '新货主' THEN '新增' WHEN '老货主' THEN '留存' END AS 表内新老,
        ROUND(p.ship_cnt, 0) AS 发货货主数,
        ROUND(p.deal_cnt, 0) AS 成交货主数,
        ROUND(p.waybill_cnt, 2) AS 成交运单量,
        ROUND(p.waybill_cnt / 10000.0, 4) AS 成交运单_万单,
        ROUND(p.deal_cnt / NULLIF(p.ship_cnt, 0), 4) AS 货主成交率,
        ROUND(p.waybill_cnt / NULLIF(p.deal_cnt, 0), 2) AS 单货主成交运单数,
        ROUND(p.reg_cnt, 0) AS 注册企业数,
        ROUND(p.audit_cnt, 0) AS 认证企业数,
        CASE CONCAT(p.initiative, '-', p.shipper_type)
            WHEN '货主招募-新货主' THEN '七、裂变-新增（运单/发货货主/成交货主）'
            WHEN '货主招募-老货主' THEN '七、裂变-留存（运单/发货货主/成交货主）'
            WHEN '电销-新货主' THEN '七、电销-新增（运单/发货货主/成交货主）'
            WHEN '电销-老货主' THEN '七、电销-留存（运单/发货货主/成交货主）'
            WHEN '投流-新货主' THEN '七、投流-新增（运单/发货货主/成交货主）'
            WHEN '投流-老货主' THEN '七、投流-留存（运单/发货货主/成交货主）'
            WHEN '调度-新货主' THEN '七、调度-新增运单'
            WHEN '调度-老货主' THEN '七、调度-留存运单'
        END AS sheet1_对齐行,
        CASE CONCAT(p.initiative, '-', p.shipper_type)
            WHEN '货主招募-新货主' THEN 1 WHEN '货主招募-老货主' THEN 2
            WHEN '电销-新货主' THEN 3 WHEN '电销-老货主' THEN 4
            WHEN '投流-新货主' THEN 5 WHEN '投流-老货主' THEN 6
            WHEN '调度-新货主' THEN 7 WHEN '调度-老货主' THEN 8
            ELSE 99
        END AS sort_key
    FROM pivoted p
    UNION ALL
    SELECT
        DATE_FORMAT(w.mon, '%Y-%m'),
        '投流宽口径',
        '投流-整体',
        '整体',
        NULL, NULL, NULL, NULL, NULL, NULL,
        ROUND(SUM(CASE WHEN w.metric_type = '注册企业数' THEN w.metric_value END), 0),
        ROUND(SUM(CASE WHEN w.metric_type = '认证企业数' THEN w.metric_value END), 0),
        '七、投流-转化漏斗（注册企业/认证企业）',
        9
    FROM tl_wide w
    GROUP BY w.mon
    UNION ALL
    SELECT
        DATE_FORMAT(w.mon, '%Y-%m'),
        '投流宽口径',
        '投流-注册账号',
        '整体',
        NULL, NULL, NULL, NULL, NULL, NULL,
        ROUND(w.metric_value, 0),
        NULL,
        '七、投流-注册账户数',
        10
    FROM tl_wide w
    WHERE w.metric_type = '注册账号'
)
SELECT
    月份, 维度层级, 维度, 表内新老,
    发货货主数, 成交货主数, 成交运单量, 成交运单_万单,
    货主成交率, 单货主成交运单数,
    注册企业数, 认证企业数,
    sheet1_对齐行
FROM out_rows
ORDER BY 月份, sort_key
;
