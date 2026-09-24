/* 线上自闭环 | 周度 + 月度 | 运单量 & 占比
 * 口径（履约剔异常，同 01c / 02c / 03d）：
 *   1) 时间轴：unload_time（load/unload 均非空）
 *   2) 异常口径（type_ab，履约新口径）：
 *      - 异常剔除 = 标签「剔除」OR（「下发」且申诉失败）
 *      - 申诉中   = 「下发」且（无申诉记录 OR 申诉中）
 *      - 申诉成功 = 「下发」且申诉成功 → 计入履约
 *      - 未命中异常场景 = 履约（保留）
 *      汇总仅排除 异常剔除 + 申诉中
 *      行程异常标签：司机近30天行程异常（含 -剔除）
 *      线上申诉：中(100/300/310/410/500)；成功(400)；失败(110/200/320/440)
 *   3) 同运单多标签 / 多申诉来源去重（任一剔除即剔除；申诉成功>申诉中>申诉失败）
 *   4) 整体 = 过滤后全部运单（去重）
 *   5) 线上 = 命中五标签任一（裂变/投流/电销/调度/无线下），可与线下重叠（同 01）
 *   6) 自闭环 = 线上且 hit_offline=0（不含线下，同 01b / 42）
 * 周起始：周三（与 02 / 02c 一致）
 *
 * 输出：周度 / 月度
 *   整体运单量、线上运单量、自闭环运单量
 *   线上占整体、自闭环占整体、自闭环占线上
 *
 * 改日期：改 waybill_hit 里 unload_time 区间即可
 */
WITH
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
    /* 同一运单多标签：任一剔除即剔除 */
    SELECT
        waybill_id,
        CASE WHEN MAX(CASE WHEN 类别 = '剔除' THEN 1 ELSE 0 END) = 1 THEN '剔除' ELSE '下发' END AS 类别
    FROM ab_raw
    GROUP BY waybill_id
),
ss_raw AS (
    /* 线下申诉成功 */
    SELECT DISTINCT waybill_id, '申诉成功' AS 是否申诉成功
    FROM match_way_abnormal_appeal_approved_info
    WHERE waybill_id NOT IN (SELECT DISTINCT waybill_id FROM match_way_abnormal_appeal_failed_info)
    UNION ALL
    /* 线下申诉失败 */
    SELECT DISTINCT waybill_id, '申诉失败' AS 是否申诉成功
    FROM match_way_abnormal_appeal_failed_info
    UNION ALL
    /* 线上申诉 */
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
    /* 多来源冲突：申诉成功 > 申诉中 > 申诉失败 */
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
    /* 剔除异常：异常剔除 + 申诉中；申诉成功 / 未命中场景不算异常 */
    SELECT DISTINCT waybill_id
    FROM type_ab
    WHERE 异常类别 IN ('异常剔除', '申诉中')
),
/* ===== 举措归属 ===== */
company_zm AS (
    SELECT DISTINCT invitee_id
    FROM dwd_vlsp_mt_user_recruitment_business_process_minf zm
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t1
        ON zm.invitee_company_user_id = t1.psn_acct_user_base_id
        AND t1.is_fake_user = '0'
    WHERE activity_title = '货主招募活动'
      AND invitee_id IS NOT NULL AND invitee_id <> ''
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
company_wxx AS (
    SELECT customer_company_id, MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
),
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        DATE(waybill.unload_time) AS unload_dt,
        DATE_FORMAT(waybill.unload_time, '%Y-%m-01') AS mon,
        DATE_SUB(
            DATE(waybill.unload_time),
            INTERVAL ((WEEKDAY(waybill.unload_time) - 2 + 7) % 7) DAY
        ) AS week_start,
        CASE WHEN company_wxx.sales_lv1_company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_offline,
        CASE WHEN company_zm.invitee_id IS NOT NULL THEN 1 ELSE 0 END AS hit_zm,
        CASE WHEN company_tl.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_tl,
        CASE WHEN company_dx.company_name_dx IS NOT NULL THEN 1 ELSE 0 END AS hit_dx,
        CASE WHEN company_dd.company_name_dd IS NOT NULL THEN 1 ELSE 0 END AS hit_dd,
        CASE
            WHEN company_wxx.sales_lv1_company_id IS NULL
             AND company_zm.invitee_id IS NULL AND company_tl.company_id IS NULL
             AND company_dx.company_name_dx IS NULL AND company_dd.company_name_dd IS NULL
            THEN 1 ELSE 0
        END AS hit_wxx
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    WHERE DATE(waybill.unload_time) >= DATE '2026-05-01'
      AND DATE(waybill.unload_time) <= CURRENT_DATE()
      AND waybill.load_time IS NOT NULL
      AND waybill.unload_time IS NOT NULL
      AND (
          company_wxx.sales_lv1_company_id IS NOT NULL
          OR NVL(waybill.shipper_company_name, '') NOT IN (
              SELECT DISTINCT dept_name
              FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
      AND waybill.waybill_status NOT IN (540, 100)
      AND NVL(waybill.shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c', 1993982792389951488,
          1993985265305452544, 1994003031330062336
      )
      AND (waybill.tms_flag = 20 OR (waybill.tms_flag = 10 AND waybill.driver_operate_accept_time IS NOT NULL))
),
waybill_ok AS (
    SELECT wh.*
    FROM waybill_hit wh
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = wh.waybill_id
    WHERE abn.waybill_id IS NULL
),
/* ===== 周度 ===== */
agg_week AS (
    SELECT
        week_start,
        COUNT(DISTINCT waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE
            WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0
            THEN waybill_id
        END) AS online_cnt,
        COUNT(DISTINCT CASE
            WHEN hit_offline = 0
             AND hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0
            THEN waybill_id
        END) AS zibihuan_cnt
    FROM waybill_ok
    GROUP BY week_start
),
/* ===== 月度 ===== */
agg_month AS (
    SELECT
        mon,
        COUNT(DISTINCT waybill_id) AS total_cnt,
        COUNT(DISTINCT CASE
            WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0
            THEN waybill_id
        END) AS online_cnt,
        COUNT(DISTINCT CASE
            WHEN hit_offline = 0
             AND hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0
            THEN waybill_id
        END) AS zibihuan_cnt
    FROM waybill_ok
    GROUP BY mon
)
SELECT
    '周度' AS 统计粒度,
    DATE_FORMAT(week_start, '%Y-%m-%d') AS 期间起点,
    CONCAT(
        DATE_FORMAT(week_start, '%m/%d'),
        '-',
        DATE_FORMAT(DATE_ADD(week_start, INTERVAL 6 DAY), '%m/%d')
    ) AS 期间标签,
    total_cnt AS 整体运单量,
    online_cnt AS 线上运单量,
    zibihuan_cnt AS 自闭环运单量,
    ROUND(online_cnt * 100.0 / NULLIF(total_cnt, 0), 2) AS 线上占整体_pct,
    ROUND(zibihuan_cnt * 100.0 / NULLIF(total_cnt, 0), 2) AS 自闭环占整体_pct,
    ROUND(zibihuan_cnt * 100.0 / NULLIF(online_cnt, 0), 2) AS 自闭环占线上_pct
FROM agg_week

UNION ALL

SELECT
    '月度' AS 统计粒度,
    DATE_FORMAT(mon, '%Y-%m-%d') AS 期间起点,
    DATE_FORMAT(mon, '%Y-%m') AS 期间标签,
    total_cnt AS 整体运单量,
    online_cnt AS 线上运单量,
    zibihuan_cnt AS 自闭环运单量,
    ROUND(online_cnt * 100.0 / NULLIF(total_cnt, 0), 2) AS 线上占整体_pct,
    ROUND(zibihuan_cnt * 100.0 / NULLIF(total_cnt, 0), 2) AS 自闭环占整体_pct,
    ROUND(zibihuan_cnt * 100.0 / NULLIF(online_cnt, 0), 2) AS 自闭环占线上_pct
FROM agg_month

ORDER BY 统计粒度 DESC, 期间起点
;
