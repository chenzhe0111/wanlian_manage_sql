/* 注册/认证 + 新老货主 + 发货/成交 | 周度 + 月度 | 履约剔异常 + 投流新口径
 * 基于 03c_...履约剔异常.sql，不覆盖 03 / 03c / 03d。
 * 履约 / 异常 / 输出结构同 03c；本版升级投流：
 *   1) company_tl：同 01d（投放账户链路 + 拼表单 + 卓易通 → 非假企货主企业）
 *   2) tl_user 宽口径注册账号池：同源三路 + 个人/企业账户链路
 *
 * 新老口径（与 03d 一致）：
 *   月度：first_dt >= 事件所在月月初（当月首次发货/首活算新增）
 *   周度：first_dt >= 当周 week_start（当周首次发货/首活算新增；对照周用 prev_week_start）
 *   老版 03c/旧 03e 仍为「周也按月月初」；本文件已改为周按周首活
 *
 * 同期口径（同 01 月度汇总）：
 *   月度：本月 1 日～截止日序 vs 上月 1 日～上月同日（无则取上月月末）
 *   周度：本周（周三起始，截到 as_of）vs 上周同长度（上周起始～起始+本周已过天数）
 * 输出：指标值 / 上月同期指标值 / 较上月同期
 */
WITH tim0 AS (
    SELECT
        DATE '2026-07-01' AS range_start,
        DATE '2026-09-22' AS as_of_dt   /* 统计截止日，右闭；可改 DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) */
),
tim AS (
    SELECT
        range_start,
        as_of_dt,
        /* 为上月同期多取一个月数据（不单独输出该月，仅作对比） */
        DATE_SUB(range_start, INTERVAL 1 MONTH) AS data_start
    FROM tim0
),
/* 输出月份：range_start 所在月 ～ as_of 所在月；截止日序同 01 */
month_spine AS (
    SELECT
        DATE_FORMAT(DATE_ADD(t.range_start, INTERVAL n.n MONTH), '%Y-%m-01') AS mon
    FROM tim t
    JOIN (
        SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
        UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
        UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11
    ) n
        ON DATE_ADD(t.range_start, INTERVAL n.n MONTH)
           <= DATE_FORMAT(t.as_of_dt, '%Y-%m-01')
),
month_meta AS (
    SELECT
        m.mon,
        CASE
            WHEN m.mon = DATE_FORMAT(t.as_of_dt, '%Y-%m-01') THEN DAY(t.as_of_dt)
            ELSE DAY(LAST_DAY(m.mon))
        END AS cutoff_dom,
        DATE_SUB(m.mon, INTERVAL 1 MONTH) AS prev_mon,
        t.as_of_dt
    FROM month_spine m
    CROSS JOIN tim t
),
/* 输出周：覆盖 [range_start, as_of]；跨月周保留；同期=上周同长度 */
week_meta AS (
    SELECT DISTINCT
        ws.week_start,
        LEAST(DATE_ADD(ws.week_start, INTERVAL 6 DAY), t.as_of_dt) AS week_end,
        DATEDIFF(LEAST(DATE_ADD(ws.week_start, INTERVAL 6 DAY), t.as_of_dt), ws.week_start) AS span_days,
        DATE_SUB(ws.week_start, INTERVAL 7 DAY) AS prev_week_start
    FROM tim t
    CROSS JOIN (
        SELECT
            DATE_SUB(
                DATE_ADD(t2.data_start, INTERVAL s.n DAY),
                INTERVAL ((WEEKDAY(DATE_ADD(t2.data_start, INTERVAL s.n DAY)) - 2 + 7) % 7) DAY
            ) AS week_start
        FROM tim t2
        CROSS JOIN (
            /* 周偏移：必须覆盖到 as_of；原最大 n=105 时 data_start=6/1 → 只到 9/14 → 周三对齐停在 9/9，漏掉 9/16 本周 */
            SELECT 0 AS n UNION ALL SELECT 7 UNION ALL SELECT 14 UNION ALL SELECT 21
            UNION ALL SELECT 28 UNION ALL SELECT 35 UNION ALL SELECT 42 UNION ALL SELECT 49
            UNION ALL SELECT 56 UNION ALL SELECT 63 UNION ALL SELECT 70 UNION ALL SELECT 77
            UNION ALL SELECT 84 UNION ALL SELECT 91 UNION ALL SELECT 98 UNION ALL SELECT 105
            UNION ALL SELECT 112 UNION ALL SELECT 119 UNION ALL SELECT 126 UNION ALL SELECT 133
            UNION ALL SELECT 140 UNION ALL SELECT 147 UNION ALL SELECT 154 UNION ALL SELECT 161
            UNION ALL SELECT 168 UNION ALL SELECT 175 UNION ALL SELECT 182 UNION ALL SELECT 189
        ) s
        WHERE DATE_ADD(t2.data_start, INTERVAL s.n DAY) <= t2.as_of_dt
    ) ws
    WHERE ws.week_start <= t.as_of_dt
      AND LEAST(DATE_ADD(ws.week_start, INTERVAL 6 DAY), t.as_of_dt) >= t.range_start
),
/* ===== 异常运单判定（type_ab，同 01c / 31） ===== */
ab_raw AS (
    SELECT
        ab.waybill_id,
        CASE
            WHEN scenario_tags LIKE '%账号登录异常-剔除%'
              OR scenario_tags LIKE '%同时段履约多单-剔除%'
              OR scenario_tags LIKE '%装卸货打卡异常-剔除%'
              OR scenario_tags LIKE '%司机月度行程异常-剔除%'
            THEN '剔除'
            ELSE '下发'
        END AS 类别
    FROM ads.ads_vlsp_mt_match_waybill_abnormal_detail_info_df ab
    WHERE (
        scenario_tags LIKE '%运费异常%'
        OR scenario_tags LIKE '%秒装秒卸%'
        OR scenario_tags LIKE '%时速异常高%'
        OR scenario_tags LIKE '%装卸货打卡异常-申诉%'
        OR scenario_tags LIKE '%装卸货打卡异常-剔除%'
        OR scenario_tags LIKE '%司机月度行程异常%'
        OR scenario_tags LIKE '%账号登录异常%'
        OR scenario_tags LIKE '%同时段履约多单-剔除%'
        OR scenario_tags LIKE '%运单间隔过短%'
    )
),
ab AS (
    SELECT
        waybill_id,
        CASE WHEN MAX(CASE WHEN 类别 = '剔除' THEN 1 ELSE 0 END) = 1 THEN '剔除' ELSE '下发' END AS 类别
    FROM ab_raw
    GROUP BY waybill_id
),
ss_raw AS (
    SELECT DISTINCT waybill_id, '申诉成功' AS 是否申诉成功
    FROM match_way_abnormal_appeal_approved_info
    WHERE waybill_id NOT IN (SELECT DISTINCT waybill_id FROM match_way_abnormal_appeal_failed_info)
    UNION ALL
    SELECT DISTINCT waybill_id, '申诉失败' AS 是否申诉成功
    FROM match_way_abnormal_appeal_failed_info
    UNION ALL
    SELECT DISTINCT
        waybill_id,
        CASE
            WHEN appl_status IN (300, 410, 310, 420, 100, 500) THEN '申诉中'
            WHEN appl_status IN (400, 430) THEN '申诉成功'
            WHEN appl_status IN (200, 320, 440) THEN '申诉失败'
            ELSE CAST(appl_status AS STRING)
        END AS 是否申诉成功
    FROM ads.ads_vlsp_mt_match_waybill_high_abnormal_detail_info_minf
),
ss AS (
    SELECT
        waybill_id,
        CASE
            WHEN MAX(CASE WHEN 是否申诉成功 = '申诉成功' THEN 1 ELSE 0 END) = 1 THEN '申诉成功'
            WHEN MAX(CASE WHEN 是否申诉成功 = '申诉中' THEN 1 ELSE 0 END) = 1 THEN '申诉中'
            WHEN MAX(CASE WHEN 是否申诉成功 = '申诉失败' THEN 1 ELSE 0 END) = 1 THEN '申诉失败'
            ELSE NULL
        END AS 是否申诉成功
    FROM ss_raw
    GROUP BY waybill_id
),
type_ab AS (
    SELECT
        ab.waybill_id,
        CASE
            WHEN ab.类别 = '剔除'
              OR (ab.类别 = '下发' AND ss.是否申诉成功 = '申诉失败')
            THEN '异常剔除'
            WHEN ab.类别 = '下发' AND (ss.waybill_id IS NULL OR ss.是否申诉成功 = '申诉中')
            THEN '申诉中'
            WHEN ab.类别 = '下发' AND ss.是否申诉成功 = '申诉成功'
            THEN '申诉成功'
            ELSE NULL
        END AS 异常类别
    FROM ab
    LEFT JOIN ss ON ab.waybill_id = ss.waybill_id
),
abnormal_waybill AS (
    SELECT DISTINCT waybill_id
    FROM type_ab
    WHERE 异常类别 IN ('异常剔除', '申诉中')
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
/* 投流新口径：信息流/搜索/商店/表单投放 ∪ 拼表单 ∪ 卓易通 → 货主企业（同 01d） */
company_tl AS (
    SELECT DISTINCT comp.company_id
    FROM (
        SELECT
            a.user_id,
            a.psn_user_id,
            a.emp_user_id,
            a.co_id
        FROM dwd_vlsp_mt_bt_advertise_placement_business_process_minf a
        WHERE a.user_id <> ''
        UNION ALL
        SELECT
            b.user_base_id AS user_id,
            CAST(NULL AS STRING) AS psn_user_id,
            CAST(NULL AS STRING) AS emp_user_id,
            CAST(NULL AS STRING) AS co_id
        FROM match_shipper_table_advertise_info a
        LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf b
            ON a.telephone = b.telephone
        WHERE b.user_base_id <> ''
        UNION ALL
        SELECT
            user_base_id AS user_id,
            CAST(NULL AS STRING) AS psn_user_id,
            CAST(NULL AS STRING) AS emp_user_id,
            CAST(NULL AS STRING) AS co_id
        FROM dwd_vlsp_mt_tracking_event_unique_device_mi
        WHERE event_type IN ('hc_release_enter')
          AND client_type IN ('app')
          AND role_type IN ('50', '货主')
          AND app_channel IN ('zyt')
          AND event_time >= '2026-09-01 00:00:00'
          AND user_base_id IS NOT NULL
          AND user_base_id <> ''
        GROUP BY user_base_id
    ) ad
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t1
        ON COALESCE(ad.emp_user_id, ad.user_id) = t1.user_base_id
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t2
        ON t1.psn_acct_user_base_id = t2.user_base_id
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t3
        ON t3.psn_acct_user_base_id = COALESCE(ad.psn_user_id, ad.user_id)
    LEFT JOIN (
        SELECT company_id
        FROM dwd_vlsp_mt_em_company_manage_info_minf
        WHERE is_fake_company_apply_user = '0'
    ) comp
        ON COALESCE(ad.co_id, t1.company_id, t3.company_id) = comp.company_id
    WHERE (t1.is_shipper = 1 OR t2.is_shipper = 1)
      AND t1.is_fake_user = '0'
      AND comp.company_id IS NOT NULL
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
        cf.first_dt,
        /* 月度用：按事件月月初；周度在 metric 里按 week_start 重算 */
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
    WHERE c.register_dt >= t.data_start
      AND c.register_dt <= t.as_of_dt
),
certify_fact AS (
    SELECT
        c.company_id,
        ci.initiative,
        cf.first_dt,
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
      AND c.audit_dt >= t.data_start
      AND c.audit_dt <= t.as_of_dt
),
ship_fact AS (
    SELECT
        b.company_id,
        ci.initiative,
        cf.first_dt,
        CASE
            WHEN cf.first_dt >= DATE_FORMAT(DATE(b.create_dt), '%Y-%m-01') THEN '新货主'
            ELSE '老货主'
        END AS shipper_type,
        DATE(b.create_dt) AS event_dt
    FROM base b
    INNER JOIN company_initiative ci ON ci.company_id = b.company_id
    INNER JOIN company_first cf ON cf.company_id = b.company_id
    CROSS JOIN tim t
    WHERE b.create_dt >= t.data_start
      AND b.create_dt <= t.as_of_dt
),
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        waybill.shipper_company_id,
        DATE(waybill.unload_time) AS event_dt,
        cf.first_dt,
        CASE
            WHEN cf.first_dt IS NULL THEN NULL
            WHEN cf.first_dt >= DATE_FORMAT(DATE(waybill.unload_time), '%Y-%m-01') THEN '新货主'
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
    WHERE DATE(waybill.unload_time) >= t.data_start
      AND DATE(waybill.unload_time) <= t.as_of_dt
      AND waybill.load_time IS NOT NULL
      AND waybill.unload_time IS NOT NULL
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
        wh.*,
        wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx AS hit_cnt
    FROM waybill_hit wh
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = wh.waybill_id
    WHERE abn.waybill_id IS NULL
),
waybill_initiative AS (
    SELECT event_dt, shipper_company_id, first_dt, shipper_type, waybill_id, '货主招募' AS initiative,
           CASE WHEN hit_zm = 1 THEN 1.0 / NULLIF(hit_cnt, 0) ELSE 0 END AS weight
    FROM waybill_split WHERE hit_cnt > 0
    UNION ALL
    SELECT event_dt, shipper_company_id, first_dt, shipper_type, waybill_id, '投流',
           CASE WHEN hit_tl = 1 THEN 1.0 / NULLIF(hit_cnt, 0) ELSE 0 END
    FROM waybill_split WHERE hit_cnt > 0
    UNION ALL
    SELECT event_dt, shipper_company_id, first_dt, shipper_type, waybill_id, '电销',
           CASE WHEN hit_dx = 1 THEN 1.0 / NULLIF(hit_cnt, 0) ELSE 0 END
    FROM waybill_split WHERE hit_cnt > 0
    UNION ALL
    SELECT event_dt, shipper_company_id, first_dt, shipper_type, waybill_id, '调度',
           CASE WHEN hit_dd = 1 THEN 1.0 / NULLIF(hit_cnt, 0) ELSE 0 END
    FROM waybill_split WHERE hit_cnt > 0
    UNION ALL
    SELECT event_dt, shipper_company_id, first_dt, shipper_type, waybill_id, '无线下销售归属',
           CASE WHEN hit_wxx = 1 THEN 1.0 / NULLIF(hit_cnt, 0) ELSE 0 END
    FROM waybill_split WHERE hit_cnt > 0
    UNION ALL
    SELECT event_dt, shipper_company_id, first_dt, shipper_type, waybill_id, '线下',
           CASE WHEN hit_offline = 1 THEN 1.0 ELSE 0 END
    FROM waybill_split
),
waybill_initiative_filtered AS (
    SELECT * FROM waybill_initiative
    WHERE weight > 0 AND first_dt IS NOT NULL
),
/* ========== 投流宽口径（对齐漏斗 ktf_*：不要求事件日>=引流日；投流新口径） ========== */
/* 用户池：投放业务表 + 拼表单 + 卓易通，货主（账户链路同 01d）；企业池：company_tl */
tl_user AS (
    SELECT DISTINCT
        CASE
            WHEN t1.account_type = 10 THEN ad.user_id
            ELSE t2.user_base_id
        END AS user_id,
        SUBSTR(ad.ad_time, 1, 10) AS ad_dt,
        COALESCE(SUBSTR(t1.register_time, 1, 10), SUBSTR(t2.register_time, 1, 10)) AS register_dt
    FROM (
        SELECT
            a.user_id,
            a.psn_user_id,
            a.emp_user_id,
            a.co_id,
            a.create_time AS ad_time
        FROM dwd_vlsp_mt_bt_advertise_placement_business_process_minf a
        WHERE a.user_id <> ''
        UNION ALL
        SELECT
            b.user_base_id AS user_id,
            CAST(NULL AS STRING) AS psn_user_id,
            CAST(NULL AS STRING) AS emp_user_id,
            CAST(NULL AS STRING) AS co_id,
            a.clue_time AS ad_time
        FROM match_shipper_table_advertise_info a
        LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf b
            ON a.telephone = b.telephone
        WHERE b.user_base_id <> ''
        UNION ALL
        SELECT
            user_base_id AS user_id,
            CAST(NULL AS STRING) AS psn_user_id,
            CAST(NULL AS STRING) AS emp_user_id,
            CAST(NULL AS STRING) AS co_id,
            MIN(event_time) AS ad_time
        FROM dwd_vlsp_mt_tracking_event_unique_device_mi
        WHERE event_type IN ('hc_release_enter')
          AND client_type IN ('app')
          AND role_type IN ('50', '货主')
          AND app_channel IN ('zyt')
          AND event_time >= '2026-09-01 00:00:00'
          AND user_base_id IS NOT NULL
          AND user_base_id <> ''
        GROUP BY user_base_id
    ) ad
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t1
        ON COALESCE(ad.emp_user_id, ad.user_id) = t1.user_base_id
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t2
        ON t1.psn_acct_user_base_id = t2.user_base_id
    WHERE (t1.is_shipper = 1 OR t2.is_shipper = 1)
      AND t1.is_fake_user = '0'
      AND CASE
            WHEN t1.account_type = 10 THEN ad.user_id
            ELSE t2.user_base_id
          END IS NOT NULL
),
/* 注册账号-宽口径：ktf_zc_acct_cnt，按个人注册日归期 */
tl_register_account_base AS (
    SELECT
        DATE(u.register_dt) AS event_dt,
        u.user_id
    FROM tl_user u
    CROSS JOIN tim t
    WHERE u.register_dt IS NOT NULL
      AND u.register_dt >= t.data_start
      AND u.register_dt <= t.as_of_dt
),
/* 注册企业数-宽口径：ktf_qyzc_comp_cnt = company_tl ∩ 期间注册企业，不拆新老、不限 is_shipper */
tl_register_comp_base AS (
    SELECT
        DATE(c.register_dt) AS event_dt,
        c.company_id
    FROM comp c
    INNER JOIN company_tl tl ON tl.company_id = c.company_id
    CROSS JOIN tim t
    WHERE c.register_dt >= t.data_start
      AND c.register_dt <= t.as_of_dt
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
      AND c.audit_dt >= t.data_start
      AND c.audit_dt <= t.as_of_dt
),

metric_sides AS (
    /* side=cur 本期；side=prev 上月同期(月) / 上周同期(周)，period_start 均对齐到本期 */
    SELECT '月' AS stat_granularity, 'cur' AS side, mm.mon AS period_start,
           f.initiative, '新货主' AS shipper_type, '注册企业数' AS metric_type,
           COUNT(DISTINCT f.company_id) AS metric_value
    FROM register_fact f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    WHERE f.initiative IN ('电销', '货主招募')
    GROUP BY mm.mon, f.initiative
    UNION ALL
    SELECT '月', 'prev', mm.mon, f.initiative, '新货主', '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM register_fact f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    WHERE f.initiative IN ('电销', '货主招募')
    GROUP BY mm.mon, f.initiative
    UNION ALL
    SELECT '周', 'cur', w.week_start, f.initiative, '新货主', '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM register_fact f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    WHERE f.initiative IN ('电销', '货主招募')
    GROUP BY w.week_start, f.initiative
    UNION ALL
    SELECT '周', 'prev', w.week_start, f.initiative, '新货主', '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM register_fact f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    WHERE f.initiative IN ('电销', '货主招募')
    GROUP BY w.week_start, f.initiative
    UNION ALL
    SELECT '月', 'cur', mm.mon, f.initiative, '新货主', '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM certify_fact f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    WHERE f.initiative IN ('电销', '货主招募')
    GROUP BY mm.mon, f.initiative
    UNION ALL
    SELECT '月', 'prev', mm.mon, f.initiative, '新货主', '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM certify_fact f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    WHERE f.initiative IN ('电销', '货主招募')
    GROUP BY mm.mon, f.initiative
    UNION ALL
    SELECT '周', 'cur', w.week_start, f.initiative, '新货主', '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM certify_fact f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    WHERE f.initiative IN ('电销', '货主招募')
    GROUP BY w.week_start, f.initiative
    UNION ALL
    SELECT '周', 'prev', w.week_start, f.initiative, '新货主', '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM certify_fact f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    WHERE f.initiative IN ('电销', '货主招募')
    GROUP BY w.week_start, f.initiative
    UNION ALL
    SELECT '月', 'cur', mm.mon, f.initiative, f.shipper_type, '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM register_fact f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    WHERE f.shipper_type IS NOT NULL
      AND f.initiative NOT IN ('投流', '电销', '货主招募')
    GROUP BY mm.mon, f.initiative, f.shipper_type
    UNION ALL
    SELECT '月', 'prev', mm.mon, f.initiative, f.shipper_type, '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM register_fact f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    WHERE f.shipper_type IS NOT NULL
      AND f.initiative NOT IN ('投流', '电销', '货主招募')
    GROUP BY mm.mon, f.initiative, f.shipper_type
    UNION ALL
    SELECT '周', 'cur', w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.week_start THEN '新货主' ELSE '老货主' END, '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM register_fact f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    WHERE f.first_dt IS NOT NULL
      AND f.initiative NOT IN ('投流', '电销', '货主招募')
    GROUP BY w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.week_start THEN '新货主' ELSE '老货主' END
    UNION ALL
    SELECT '周', 'prev', w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.prev_week_start THEN '新货主' ELSE '老货主' END, '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM register_fact f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    WHERE f.first_dt IS NOT NULL
      AND f.initiative NOT IN ('投流', '电销', '货主招募')
    GROUP BY w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.prev_week_start THEN '新货主' ELSE '老货主' END
    UNION ALL
    SELECT '月', 'cur', mm.mon, f.initiative, f.shipper_type, '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM certify_fact f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    WHERE f.shipper_type IS NOT NULL
      AND f.initiative NOT IN ('投流', '电销', '货主招募')
    GROUP BY mm.mon, f.initiative, f.shipper_type
    UNION ALL
    SELECT '月', 'prev', mm.mon, f.initiative, f.shipper_type, '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM certify_fact f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    WHERE f.shipper_type IS NOT NULL
      AND f.initiative NOT IN ('投流', '电销', '货主招募')
    GROUP BY mm.mon, f.initiative, f.shipper_type
    UNION ALL
    SELECT '周', 'cur', w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.week_start THEN '新货主' ELSE '老货主' END, '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM certify_fact f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    WHERE f.first_dt IS NOT NULL
      AND f.initiative NOT IN ('投流', '电销', '货主招募')
    GROUP BY w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.week_start THEN '新货主' ELSE '老货主' END
    UNION ALL
    SELECT '周', 'prev', w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.prev_week_start THEN '新货主' ELSE '老货主' END, '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM certify_fact f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    WHERE f.first_dt IS NOT NULL
      AND f.initiative NOT IN ('投流', '电销', '货主招募')
    GROUP BY w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.prev_week_start THEN '新货主' ELSE '老货主' END
    UNION ALL
    SELECT '月', 'cur', mm.mon, f.initiative, f.shipper_type, '发货货主数',
           COUNT(DISTINCT f.company_id)
    FROM ship_fact f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    GROUP BY mm.mon, f.initiative, f.shipper_type
    UNION ALL
    SELECT '月', 'prev', mm.mon, f.initiative, f.shipper_type, '发货货主数',
           COUNT(DISTINCT f.company_id)
    FROM ship_fact f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon, f.initiative, f.shipper_type
    UNION ALL
    SELECT '周', 'cur', w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.week_start THEN '新货主' ELSE '老货主' END, '发货货主数',
           COUNT(DISTINCT f.company_id)
    FROM ship_fact f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    GROUP BY w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.week_start THEN '新货主' ELSE '老货主' END
    UNION ALL
    SELECT '周', 'prev', w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.prev_week_start THEN '新货主' ELSE '老货主' END, '发货货主数',
           COUNT(DISTINCT f.company_id)
    FROM ship_fact f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.prev_week_start THEN '新货主' ELSE '老货主' END
    UNION ALL
    SELECT '月', 'cur', mm.mon, f.initiative, f.shipper_type, '成交货主数',
           COUNT(DISTINCT f.shipper_company_id)
    FROM waybill_initiative_filtered f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    GROUP BY mm.mon, f.initiative, f.shipper_type
    UNION ALL
    SELECT '月', 'prev', mm.mon, f.initiative, f.shipper_type, '成交货主数',
           COUNT(DISTINCT f.shipper_company_id)
    FROM waybill_initiative_filtered f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon, f.initiative, f.shipper_type
    UNION ALL
    SELECT '周', 'cur', w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.week_start THEN '新货主' ELSE '老货主' END, '成交货主数',
           COUNT(DISTINCT f.shipper_company_id)
    FROM waybill_initiative_filtered f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    GROUP BY w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.week_start THEN '新货主' ELSE '老货主' END
    UNION ALL
    SELECT '周', 'prev', w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.prev_week_start THEN '新货主' ELSE '老货主' END, '成交货主数',
           COUNT(DISTINCT f.shipper_company_id)
    FROM waybill_initiative_filtered f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.prev_week_start THEN '新货主' ELSE '老货主' END
    UNION ALL
    SELECT '月', 'cur', mm.mon, f.initiative, f.shipper_type, '成交运单量',
           SUM(f.weight)
    FROM waybill_initiative_filtered f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    GROUP BY mm.mon, f.initiative, f.shipper_type
    UNION ALL
    SELECT '月', 'prev', mm.mon, f.initiative, f.shipper_type, '成交运单量',
           SUM(f.weight)
    FROM waybill_initiative_filtered f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon, f.initiative, f.shipper_type
    UNION ALL
    SELECT '周', 'cur', w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.week_start THEN '新货主' ELSE '老货主' END, '成交运单量',
           SUM(f.weight)
    FROM waybill_initiative_filtered f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    GROUP BY w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.week_start THEN '新货主' ELSE '老货主' END
    UNION ALL
    SELECT '周', 'prev', w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.prev_week_start THEN '新货主' ELSE '老货主' END, '成交运单量',
           SUM(f.weight)
    FROM waybill_initiative_filtered f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start, f.initiative,
           CASE WHEN f.first_dt >= w.prev_week_start THEN '新货主' ELSE '老货主' END
    UNION ALL
    SELECT '月', 'cur', mm.mon, '投流', '整体', '注册账号',
           COUNT(DISTINCT f.user_id)
    FROM tl_register_account_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    GROUP BY mm.mon
    UNION ALL
    SELECT '月', 'prev', mm.mon, '投流', '整体', '注册账号',
           COUNT(DISTINCT f.user_id)
    FROM tl_register_account_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon
    UNION ALL
    SELECT '周', 'cur', w.week_start, '投流', '整体', '注册账号',
           COUNT(DISTINCT f.user_id)
    FROM tl_register_account_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    GROUP BY w.week_start
    UNION ALL
    SELECT '周', 'prev', w.week_start, '投流', '整体', '注册账号',
           COUNT(DISTINCT f.user_id)
    FROM tl_register_account_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start
    UNION ALL
    SELECT '月', 'cur', mm.mon, '投流', '整体', '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM tl_register_comp_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    GROUP BY mm.mon
    UNION ALL
    SELECT '月', 'prev', mm.mon, '投流', '整体', '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM tl_register_comp_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon
    UNION ALL
    SELECT '周', 'cur', w.week_start, '投流', '整体', '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM tl_register_comp_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    GROUP BY w.week_start
    UNION ALL
    SELECT '周', 'prev', w.week_start, '投流', '整体', '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM tl_register_comp_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start
    UNION ALL
    SELECT '月', 'cur', mm.mon, '投流', '整体', '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM tl_certify_comp_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    GROUP BY mm.mon
    UNION ALL
    SELECT '月', 'prev', mm.mon, '投流', '整体', '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM tl_certify_comp_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon
    UNION ALL
    SELECT '周', 'cur', w.week_start, '投流', '整体', '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM tl_certify_comp_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    GROUP BY w.week_start
    UNION ALL
    SELECT '周', 'prev', w.week_start, '投流', '整体', '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM tl_certify_comp_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start
),
metric_pivot AS (
    SELECT
        stat_granularity,
        period_start,
        initiative,
        shipper_type,
        metric_type,
        MAX(CASE WHEN side = 'cur' THEN metric_value END) AS metric_value,
        COALESCE(MAX(CASE WHEN side = 'prev' THEN metric_value END), 0) AS prev_metric_value
    FROM metric_sides
    GROUP BY
        stat_granularity, period_start, initiative, shipper_type, metric_type
)
SELECT
    CONCAT(initiative, '-', shipper_type, '-', metric_type) AS 主键,
    CASE stat_granularity WHEN '月' THEN '月度' WHEN '周' THEN '周度' END AS 月周标识,
    period_start AS 周期起始日,
    initiative AS 举措,
    shipper_type AS 新老货主,
    metric_type AS 指标类型,
    metric_value AS 指标值,
    prev_metric_value AS 上月同期指标值,
    ROUND(
        (metric_value - prev_metric_value) * 1.0 / NULLIF(prev_metric_value, 0),
        4
    ) AS 较上月同期
FROM metric_pivot
WHERE metric_value IS NOT NULL
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
