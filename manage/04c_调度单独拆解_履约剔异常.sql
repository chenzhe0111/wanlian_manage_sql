/* 调度专项分析 | 履约剔异常 | 周度+月度
 * 相对 04_调度单独拆解.sql 的差异（成交运单量/成交货主数/产生调度）：
 *   1) 时间轴：unload_time；load_time / unload_time 均非空
 *   2) 异常口径 type_ab（履约新口径，同 01c）：排除 异常剔除 + 申诉中；申诉成功计入履约
 * 注册/认证/发货/TMS创建/三方调度累计注册认证：逻辑不变
 *
 * 新老口径（跨月周关键，同 03）：
 *   first_dt = 货主历史首次发货/运单日；cutoff = 事件月月初
 *   当前输出维度仍是「类型」不是「新老」；shipper_type 在 base 层预留
 *
 * 同期口径（同 01 / 03c）：
 *   月度：本月 1 日～截止日序 vs 上月 1 日～上月同日
 *   周度：本周（周三起始，截到 as_of）vs 上周同长度
 *   三方调度注册/认证：累计至当期末 vs 累计至上月/上周同期末日
 * 输出：指标值 / 上月同期指标值 / 较上月同期
 */
WITH tim0 AS (
    SELECT
        DATE '2026-07-01' AS range_start,
        DATE '2026-09-01' AS as_of_dt   /* 统计截止日，右闭；可改 DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) */
),
tim AS (
    SELECT
        range_start,
        as_of_dt,
        DATE_SUB(range_start, INTERVAL 1 MONTH) AS data_start
    FROM tim0
),
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
        CASE
            WHEN m.mon = DATE_FORMAT(t.as_of_dt, '%Y-%m-01') THEN t.as_of_dt
            ELSE LAST_DAY(m.mon)
        END AS period_end,
        LEAST(
            DATE_ADD(DATE_SUB(m.mon, INTERVAL 1 MONTH), INTERVAL (
                CASE
                    WHEN m.mon = DATE_FORMAT(t.as_of_dt, '%Y-%m-01') THEN DAY(t.as_of_dt)
                    ELSE DAY(LAST_DAY(m.mon))
                END - 1
            ) DAY),
            LAST_DAY(DATE_SUB(m.mon, INTERVAL 1 MONTH))
        ) AS prev_period_end,
        t.as_of_dt
    FROM month_spine m
    CROSS JOIN tim t
),
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
            SELECT 0 AS n UNION ALL SELECT 7 UNION ALL SELECT 14 UNION ALL SELECT 21
            UNION ALL SELECT 28 UNION ALL SELECT 35 UNION ALL SELECT 42 UNION ALL SELECT 49
            UNION ALL SELECT 56 UNION ALL SELECT 63 UNION ALL SELECT 70 UNION ALL SELECT 77
            UNION ALL SELECT 84 UNION ALL SELECT 91 UNION ALL SELECT 98 UNION ALL SELECT 105
        ) s
        WHERE DATE_ADD(t2.data_start, INTERVAL s.n DAY) <= t2.as_of_dt
    ) ws
    WHERE ws.week_start <= t.as_of_dt
      AND LEAST(DATE_ADD(ws.week_start, INTERVAL 6 DAY), t.as_of_dt) >= t.range_start
),
/* ===== 异常运单判定（履约新口径，同 01c） ===== */
ab_raw AS (
    SELECT
        ab.waybill_id,
        CASE
            WHEN scenario_tags LIKE '%账号登录异常-剔除%'
              OR scenario_tags LIKE '%同时段履约多单-剔除%'
              OR scenario_tags LIKE '%装卸货打卡异常-剔除%'
              OR scenario_tags LIKE '%司机近30天行程异常-剔除%'
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
        OR scenario_tags LIKE '%司机近30天行程异常%'
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
            WHEN appl_status IN (100, 300, 310, 410, 500) THEN '申诉中'   /* 100待推送 500已作废 */
            WHEN appl_status IN (400) THEN '申诉成功'
            WHEN appl_status IN (110, 200, 320, 440) THEN '申诉失败'
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
/* 仅存首活日；新老在各 fact 里按「事件月月初」动态判定（勿用全局 cutoff） */
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
        DATE(waybill.unload_time) AS event_dt,
        CASE
            WHEN waybill.invoice_type = 20 THEN '网货'
            WHEN waybill.invoice_type = 10 AND waybill.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_category,
        /* 事件月新老（跨月周：7月段看7/1，8月段看8/1） */
        CASE
            WHEN cf.first_dt IS NULL THEN NULL
            WHEN cf.first_dt >= DATE_FORMAT(DATE(waybill.unload_time), '%Y-%m-01') THEN '新货主'
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
dispatch_waybill_base AS (
    SELECT
        wh.event_dt,
        wh.waybill_id,
        wh.shipper_company_id,
        wh.waybill_category,
        wh.shipper_type,
        1.0 / NULLIF(wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx, 0) AS weight
    FROM waybill_hit wh
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = wh.waybill_id
    WHERE wh.hit_dd = 1
      AND wh.hit_zm + wh.hit_tl + wh.hit_dx + wh.hit_dd + wh.hit_wxx > 0
      AND abn.waybill_id IS NULL
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
    WHERE c.register_dt >= t.data_start
      AND c.register_dt <= t.as_of_dt
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
      AND c.audit_dt >= t.data_start
      AND c.audit_dt <= t.as_of_dt
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
    WHERE b.create_dt >= t.data_start
      AND b.create_dt <= t.as_of_dt
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
      AND DATE(waybill.waybill_create_time) >= t.data_start
      AND DATE(waybill.waybill_create_time) <= t.as_of_dt
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
      AND DATE(goods.create_dt) >= t.data_start
      AND DATE(goods.create_dt) <= t.as_of_dt
),
tms_create_base AS (
    SELECT event_dt, company_name FROM tms_waybill_create
    UNION
    SELECT event_dt, company_name FROM tms_jhd_create
),
/* 三方调度员账号 */
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
/* 产生调度：运单上 dispatcher 命中三方调度员 */
third_dispatch_base AS (
    SELECT
        DATE(w.unload_time) AS event_dt,
        w.dispatcher_user_id AS user_base_id
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf w
    INNER JOIN dispatcher_user d
        ON d.user_base_id = w.dispatcher_user_id
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = w.waybill_id
    CROSS JOIN tim t
    WHERE DATE(w.unload_time) >= t.data_start
      AND DATE(w.unload_time) <= t.as_of_dt
      AND w.load_time IS NOT NULL
      AND w.unload_time IS NOT NULL
      AND COALESCE(w.dispatcher_user_id, '') <> ''
      AND w.waybill_status NOT IN (540, 100)
      AND abn.waybill_id IS NULL
    GROUP BY DATE(w.unload_time), w.dispatcher_user_id
),
metric_sides AS (
    /* side=cur 本期；side=prev 上月同期(月)/上周同期(周)；period_start 对齐本期 */
    SELECT '月' AS stat_granularity, 'cur' AS side, mm.mon AS period_start,
           '调度' AS initiative, f.waybill_category AS waybill_type, '成交运单量' AS metric_type,
           SUM(f.weight) AS metric_value
    FROM dispatch_waybill_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    GROUP BY mm.mon, f.waybill_category
    UNION ALL
    SELECT '月', 'prev', mm.mon, '调度', f.waybill_category, '成交运单量', SUM(f.weight)
    FROM dispatch_waybill_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon, f.waybill_category
    UNION ALL
    SELECT '周', 'cur', w.week_start, '调度', f.waybill_category, '成交运单量', SUM(f.weight)
    FROM dispatch_waybill_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    GROUP BY w.week_start, f.waybill_category
    UNION ALL
    SELECT '周', 'prev', w.week_start, '调度', f.waybill_category, '成交运单量', SUM(f.weight)
    FROM dispatch_waybill_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start, f.waybill_category
    UNION ALL
    SELECT '月', 'cur', mm.mon, '调度', f.waybill_category, '成交货主数',
           COUNT(DISTINCT f.shipper_company_id)
    FROM dispatch_waybill_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    GROUP BY mm.mon, f.waybill_category
    UNION ALL
    SELECT '月', 'prev', mm.mon, '调度', f.waybill_category, '成交货主数',
           COUNT(DISTINCT f.shipper_company_id)
    FROM dispatch_waybill_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon, f.waybill_category
    UNION ALL
    SELECT '周', 'cur', w.week_start, '调度', f.waybill_category, '成交货主数',
           COUNT(DISTINCT f.shipper_company_id)
    FROM dispatch_waybill_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    GROUP BY w.week_start, f.waybill_category
    UNION ALL
    SELECT '周', 'prev', w.week_start, '调度', f.waybill_category, '成交货主数',
           COUNT(DISTINCT f.shipper_company_id)
    FROM dispatch_waybill_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start, f.waybill_category
    UNION ALL
    SELECT '月', 'cur', mm.mon, '调度', 'TMS', '创建运单货主数',
           COUNT(DISTINCT f.company_name)
    FROM tms_create_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    GROUP BY mm.mon
    UNION ALL
    SELECT '月', 'prev', mm.mon, '调度', 'TMS', '创建运单货主数',
           COUNT(DISTINCT f.company_name)
    FROM tms_create_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon
    UNION ALL
    SELECT '周', 'cur', w.week_start, '调度', 'TMS', '创建运单货主数',
           COUNT(DISTINCT f.company_name)
    FROM tms_create_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    GROUP BY w.week_start
    UNION ALL
    SELECT '周', 'prev', w.week_start, '调度', 'TMS', '创建运单货主数',
           COUNT(DISTINCT f.company_name)
    FROM tms_create_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start
    UNION ALL
    SELECT '月', 'cur', mm.mon, '调度', '网货', '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM dispatch_register_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    GROUP BY mm.mon
    UNION ALL
    SELECT '月', 'prev', mm.mon, '调度', '网货', '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM dispatch_register_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon
    UNION ALL
    SELECT '周', 'cur', w.week_start, '调度', '网货', '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM dispatch_register_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    GROUP BY w.week_start
    UNION ALL
    SELECT '周', 'prev', w.week_start, '调度', '网货', '注册企业数',
           COUNT(DISTINCT f.company_id)
    FROM dispatch_register_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start
    UNION ALL
    SELECT '月', 'cur', mm.mon, '调度', '网货', '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM dispatch_certify_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    GROUP BY mm.mon
    UNION ALL
    SELECT '月', 'prev', mm.mon, '调度', '网货', '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM dispatch_certify_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon
    UNION ALL
    SELECT '周', 'cur', w.week_start, '调度', '网货', '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM dispatch_certify_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    GROUP BY w.week_start
    UNION ALL
    SELECT '周', 'prev', w.week_start, '调度', '网货', '认证企业数',
           COUNT(DISTINCT f.company_id)
    FROM dispatch_certify_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start
    UNION ALL
    SELECT '月', 'cur', mm.mon, '调度', '网货', '发货货主数',
           COUNT(DISTINCT f.company_id)
    FROM dispatch_ship_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    GROUP BY mm.mon
    UNION ALL
    SELECT '月', 'prev', mm.mon, '调度', '网货', '发货货主数',
           COUNT(DISTINCT f.company_id)
    FROM dispatch_ship_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon
    UNION ALL
    SELECT '周', 'cur', w.week_start, '调度', '网货', '发货货主数',
           COUNT(DISTINCT f.company_id)
    FROM dispatch_ship_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    GROUP BY w.week_start
    UNION ALL
    SELECT '周', 'prev', w.week_start, '调度', '网货', '发货货主数',
           COUNT(DISTINCT f.company_id)
    FROM dispatch_ship_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.prev_week_start
       AND f.event_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start
    UNION ALL
    SELECT '月', 'cur', mm.mon, '调度', '撮合', '三方调度注册用户量',
           COUNT(DISTINCT d.user_base_id)
    FROM month_meta mm
    CROSS JOIN dispatcher_user d
    WHERE d.register_dt IS NULL OR d.register_dt <= mm.period_end
    GROUP BY mm.mon
    UNION ALL
    SELECT '月', 'prev', mm.mon, '调度', '撮合', '三方调度注册用户量',
           COUNT(DISTINCT d.user_base_id)
    FROM month_meta mm
    CROSS JOIN dispatcher_user d
    WHERE d.register_dt IS NULL OR d.register_dt <= mm.prev_period_end
    GROUP BY mm.mon
    UNION ALL
    SELECT '周', 'cur', w.week_start, '调度', '撮合', '三方调度注册用户量',
           COUNT(DISTINCT d.user_base_id)
    FROM week_meta w
    CROSS JOIN dispatcher_user d
    WHERE d.register_dt IS NULL OR d.register_dt <= w.week_end
    GROUP BY w.week_start
    UNION ALL
    SELECT '周', 'prev', w.week_start, '调度', '撮合', '三方调度注册用户量',
           COUNT(DISTINCT d.user_base_id)
    FROM week_meta w
    CROSS JOIN dispatcher_user d
    WHERE d.register_dt IS NULL
       OR d.register_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start
    UNION ALL
    SELECT '月', 'cur', mm.mon, '调度', '撮合', '三方调度认证注册量',
           COUNT(DISTINCT d.user_base_id)
    FROM month_meta mm
    CROSS JOIN dispatcher_user d
    WHERE d.register_dt IS NULL OR d.register_dt <= mm.period_end
    GROUP BY mm.mon
    UNION ALL
    SELECT '月', 'prev', mm.mon, '调度', '撮合', '三方调度认证注册量',
           COUNT(DISTINCT d.user_base_id)
    FROM month_meta mm
    CROSS JOIN dispatcher_user d
    WHERE d.register_dt IS NULL OR d.register_dt <= mm.prev_period_end
    GROUP BY mm.mon
    UNION ALL
    SELECT '周', 'cur', w.week_start, '调度', '撮合', '三方调度认证注册量',
           COUNT(DISTINCT d.user_base_id)
    FROM week_meta w
    CROSS JOIN dispatcher_user d
    WHERE d.register_dt IS NULL OR d.register_dt <= w.week_end
    GROUP BY w.week_start
    UNION ALL
    SELECT '周', 'prev', w.week_start, '调度', '撮合', '三方调度认证注册量',
           COUNT(DISTINCT d.user_base_id)
    FROM week_meta w
    CROSS JOIN dispatcher_user d
    WHERE d.register_dt IS NULL
       OR d.register_dt <= DATE_ADD(w.prev_week_start, INTERVAL w.span_days DAY)
    GROUP BY w.week_start
    UNION ALL
    SELECT '月', 'cur', mm.mon, '调度', '撮合', '产生调度的用户量',
           COUNT(DISTINCT f.user_base_id)
    FROM third_dispatch_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.mon
       AND DAY(f.event_dt) <= mm.cutoff_dom
    GROUP BY mm.mon
    UNION ALL
    SELECT '月', 'prev', mm.mon, '调度', '撮合', '产生调度的用户量',
           COUNT(DISTINCT f.user_base_id)
    FROM third_dispatch_base f
    INNER JOIN month_meta mm
        ON DATE_FORMAT(f.event_dt, '%Y-%m-01') = mm.prev_mon
       AND DAY(f.event_dt) <= LEAST(mm.cutoff_dom, DAY(LAST_DAY(mm.prev_mon)))
    GROUP BY mm.mon
    UNION ALL
    SELECT '周', 'cur', w.week_start, '调度', '撮合', '产生调度的用户量',
           COUNT(DISTINCT f.user_base_id)
    FROM third_dispatch_base f
    INNER JOIN week_meta w
        ON f.event_dt >= w.week_start AND f.event_dt <= w.week_end
    GROUP BY w.week_start
    UNION ALL
    SELECT '周', 'prev', w.week_start, '调度', '撮合', '产生调度的用户量',
           COUNT(DISTINCT f.user_base_id)
    FROM third_dispatch_base f
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
        waybill_type,
        metric_type,
        MAX(CASE WHEN side = 'cur' THEN metric_value END) AS metric_value,
        COALESCE(MAX(CASE WHEN side = 'prev' THEN metric_value END), 0) AS prev_metric_value
    FROM metric_sides
    GROUP BY
        stat_granularity, period_start, initiative, waybill_type, metric_type
)
SELECT
    CONCAT(initiative, '-', waybill_type, '-', metric_type) AS 主键,
    CASE stat_granularity WHEN '月' THEN '月度' WHEN '周' THEN '周度' END AS 月周标识,
    period_start AS 周期起始日,
    initiative AS 举措,
    waybill_type AS 类型,
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
    CASE waybill_type WHEN '网货' THEN 1 WHEN 'TMS' THEN 2 WHEN '撮合' THEN 3 ELSE 99 END,
    CASE metric_type
        WHEN '注册企业数' THEN 1 WHEN '认证企业数' THEN 2 WHEN '发货货主数' THEN 3
        WHEN '创建运单货主数' THEN 4 WHEN '成交运单量' THEN 5 WHEN '成交货主数' THEN 6
        WHEN '三方调度注册用户量' THEN 7 WHEN '三方调度认证注册量' THEN 8
        WHEN '产生调度的用户量' THEN 9
        ELSE 99
    END;
