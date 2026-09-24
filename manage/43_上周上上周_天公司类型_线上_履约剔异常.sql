/* 上周 + 上上周：天 × 公司 × 线上运单类型 × 举措信息 运单量 | 履约剔异常
 * 用途：排查「各举措单货主成交运单数」下降——看类型结构 + 举措归属 + 头部公司日波动
 *
 * 口径（对齐 01c / 06c / 09 / 27c / 34）：
 *   1) 时间轴：unload_time（履约卸货日）；load_time / unload_time 均非空
 *   2) 异常：排除 type_ab ∈ {异常剔除, 申诉中}
 *   3) 线上：命中裂变/投流/电销/调度/无线下销售归属 任一（hit_zm+tl+dx+dd+wxx > 0）
 *   4) 运单类型：网货 / TMS / 撮合（invoice_type + tms_flag）
 *   5) 公司计数：一单一计；适合算单货主运单数
 *   6) 周：周三为一周起点（与业务周报一致）
 *   7) 举措字段（公司级命中，多举措可并存）：
 *        命中举措 = 拼接（裂变,投流,电销,调度,无线下销售归属）
 *        命中数   = hit_zm+tl+dx+dd+wxx
 *        主举措   = 唯一归属，优先级：调度 > 电销 > 投流 > 裂变 > 无线下销售归属
 *        （主举措用于互斥拆盘；看举措 KPI 不均分请用文末 D 段展开）
 *
 * 默认窗口（相对跑数日自动算）：
 *   本周一起点 = 最近一个周三
 *   上周 week_start = this_week_start - 7；上上周 = this_week_start - 14
 *   区间右闭到 this_week_start - 1（不含本周）
 *
 * 输出：
 *   A) 默认明细：周 | 天 | 公司 | 类型 | 命中举措/主举措 | 运单量
 *   B/C/D) 注释段：公司周汇总 / 类型KPI / 举措不均分KPI
 */
WITH tim AS (
    SELECT
        /* 本周周三起点；若今天就是周三则为今天 */
        DATE_SUB(
            CURRENT_DATE(),
            INTERVAL ((WEEKDAY(CURRENT_DATE()) - 2 + 7) % 7) DAY
        ) AS this_week_start
),
tim2 AS (
    SELECT
        this_week_start,
        DATE_SUB(this_week_start, INTERVAL 7 DAY)  AS last_week_start,      /* 上周三 */
        DATE_SUB(this_week_start, INTERVAL 14 DAY) AS prev_week_start,      /* 上上周三 */
        DATE_SUB(this_week_start, INTERVAL 1 DAY)  AS range_end             /* 上周日（周二） */
    FROM tim
),
/* ===== 异常运单判定（type_ab，同 01c / 27c） ===== */
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
/* ===== 线上渠道命中 ===== */
company_zm AS (
    SELECT DISTINCT invitee_id
    FROM dwd.dwd_vlsp_mt_user_recruitment_business_process_minf zm
    LEFT JOIN dwd.dwd_vlsp_mt_em_user_manage_info_minf t1
        ON zm.invitee_company_user_id = t1.psn_acct_user_base_id
        AND t1.is_fake_user = '0'
    WHERE activity_title = '货主招募活动'
      AND invitee_id IS NOT NULL AND invitee_id <> ''
),
company_tl AS (
    SELECT DISTINCT COALESCE(t1.company_id, t3.company_id) AS company_id
    FROM (
        SELECT a.user_id
        FROM dwd.dwd_vlsp_mt_bt_advertise_placement_business_process_minf a
        WHERE a.user_id <> ''
        UNION
        SELECT b.user_base_id AS user_id
        FROM match_shipper_table_advertise_info a
        LEFT JOIN dwd.dwd_vlsp_mt_em_user_manage_info_minf b
            ON a.telephone = b.telephone
            AND b.is_fake_user = '0'
        WHERE b.user_base_id <> ''
    ) ad
    LEFT JOIN dwd.dwd_vlsp_mt_em_user_manage_info_minf t1
        ON ad.user_id = t1.user_base_id
        AND t1.is_fake_user = '0'
    LEFT JOIN dwd.dwd_vlsp_mt_em_user_manage_info_minf t3
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
    FROM dwd.dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
),
waybill_base AS (
    SELECT
        waybill.waybill_id,
        DATE(waybill.unload_time) AS dt,
        DATE_SUB(
            DATE(waybill.unload_time),
            INTERVAL ((WEEKDAY(waybill.unload_time) - 2 + 7) % 7) DAY
        ) AS week_start,
        waybill.process_shipper_company_id AS company_id,
        waybill.process_shipper_company_name AS company_name,
        CASE
            WHEN waybill.invoice_type = 20 THEN '网货'
            WHEN waybill.invoice_type = 10 AND waybill.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_type,
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
    CROSS JOIN tim2 t
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    WHERE DATE(waybill.unload_time) BETWEEN t.prev_week_start AND t.range_end
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
online_clean AS (
    SELECT
        wb.*,
        (wb.hit_zm + wb.hit_tl + wb.hit_dx + wb.hit_dd + wb.hit_wxx) AS hit_cnt,
        CONCAT_WS(
            ',',
            CASE WHEN wb.hit_zm  = 1 THEN '裂变' END,
            CASE WHEN wb.hit_tl  = 1 THEN '投流' END,
            CASE WHEN wb.hit_dx  = 1 THEN '电销' END,
            CASE WHEN wb.hit_dd  = 1 THEN '调度' END,
            CASE WHEN wb.hit_wxx = 1 THEN '无线下销售归属' END
        ) AS initiatives_label,
        /* 主举措：互斥归属，优先级 调度>电销>投流>裂变>无线下 */
        CASE
            WHEN wb.hit_dd  = 1 THEN '调度'
            WHEN wb.hit_dx  = 1 THEN '电销'
            WHEN wb.hit_tl  = 1 THEN '投流'
            WHEN wb.hit_zm  = 1 THEN '裂变'
            WHEN wb.hit_wxx = 1 THEN '无线下销售归属'
        END AS primary_initiative,
        CASE
            WHEN wb.week_start = t.last_week_start THEN '上周'
            WHEN wb.week_start = t.prev_week_start THEN '上上周'
        END AS week_label
    FROM waybill_base wb
    CROSS JOIN tim2 t
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = wb.waybill_id
    WHERE abn.waybill_id IS NULL
      AND (wb.hit_zm + wb.hit_tl + wb.hit_dx + wb.hit_dd + wb.hit_wxx) > 0   /* 仅线上 */
      AND wb.week_start IN (t.last_week_start, t.prev_week_start)
),
/* ========== A) 天 × 公司 × 类型 × 举措信息 明细 ========== */
detail_day AS (
    SELECT
        week_label,
        week_start,
        dt,
        company_id,
        company_name,
        waybill_type,
        hit_zm,
        hit_tl,
        hit_dx,
        hit_dd,
        hit_wxx,
        hit_cnt,
        initiatives_label,
        primary_initiative,
        COUNT(DISTINCT waybill_id) AS waybill_cnt
    FROM online_clean
    GROUP BY
        week_label, week_start, dt, company_id, company_name, waybill_type,
        hit_zm, hit_tl, hit_dx, hit_dd, hit_wxx, hit_cnt, initiatives_label, primary_initiative
)
/* 默认跑明细；若要公司×周 / 举措KPI，把下面 SELECT 换成注释里的 B/C/D 段 */
SELECT
    week_label AS 周标签,
    week_start AS 周起始三,
    dt AS 履约日,
    company_id AS 公司ID,
    company_name AS 公司名称,
    waybill_type AS 运单类型,
    initiatives_label AS 命中举措,
    hit_cnt AS 命中数,
    primary_initiative AS 主举措,
    hit_zm AS 命中裂变,
    hit_tl AS 命中投流,
    hit_dx AS 命中电销,
    hit_dd AS 命中调度,
    hit_wxx AS 命中无线下,
    waybill_cnt AS 运单量
FROM detail_day
ORDER BY
    CASE week_label WHEN '上上周' THEN 1 WHEN '上周' THEN 2 ELSE 9 END,
    dt,
    waybill_cnt DESC,
    company_name,
    CASE waybill_type WHEN '撮合' THEN 1 WHEN 'TMS' THEN 2 WHEN '网货' THEN 3 ELSE 9 END;

/*
========== B) 公司 × 周 × 类型 汇总（带举措字段）==========
把上面最终 SELECT 换成：

SELECT
    week_label AS 周标签,
    week_start AS 周起始三,
    company_id AS 公司ID,
    company_name AS 公司名称,
    initiatives_label AS 命中举措,
    hit_cnt AS 命中数,
    primary_initiative AS 主举措,
    waybill_type AS 运单类型,
    SUM(waybill_cnt) AS 运单量
FROM detail_day
GROUP BY
    week_label, week_start, company_id, company_name,
    initiatives_label, hit_cnt, primary_initiative, waybill_type
ORDER BY week_label, SUM(waybill_cnt) DESC;

========== C) 周度 KPI（按运单类型 / 主举措互斥）==========
SELECT
    week_label AS 周标签,
    week_start AS 周起始三,
    primary_initiative AS 主举措,
    waybill_type AS 运单类型,
    COUNT(DISTINCT company_id) AS 成交货主数,
    COUNT(DISTINCT waybill_id) AS 成交运单量,
    ROUND(COUNT(DISTINCT waybill_id) * 1.0 / NULLIF(COUNT(DISTINCT company_id), 0), 2) AS 单货主成交运单数
FROM online_clean
GROUP BY week_label, week_start, primary_initiative, waybill_type
ORDER BY 1, 3, 4;

========== D) 周度 KPI（举措不均分展开，对齐 09 不均分）==========
多举措命中会在多个举措各计 1 次运单/货主；看「各举措单货主」用这段：

initiative_explode AS (
    SELECT week_label, week_start, company_id, waybill_id, waybill_type, '裂变' AS initiative
    FROM online_clean WHERE hit_zm = 1
    UNION ALL
    SELECT week_label, week_start, company_id, waybill_id, waybill_type, '投流'
    FROM online_clean WHERE hit_tl = 1
    UNION ALL
    SELECT week_label, week_start, company_id, waybill_id, waybill_type, '电销'
    FROM online_clean WHERE hit_dx = 1
    UNION ALL
    SELECT week_label, week_start, company_id, waybill_id, waybill_type, '调度'
    FROM online_clean WHERE hit_dd = 1
    UNION ALL
    SELECT week_label, week_start, company_id, waybill_id, waybill_type, '无线下销售归属'
    FROM online_clean WHERE hit_wxx = 1
)
SELECT
    week_label AS 周标签,
    week_start AS 周起始三,
    initiative AS 举措,
    waybill_type AS 运单类型,
    COUNT(DISTINCT company_id) AS 成交货主数,
    COUNT(DISTINCT waybill_id) AS 成交运单量_不均分,
    ROUND(COUNT(DISTINCT waybill_id) * 1.0 / NULLIF(COUNT(DISTINCT company_id), 0), 2) AS 单货主成交运单数
FROM initiative_explode
GROUP BY week_label, week_start, initiative, waybill_type

UNION ALL

SELECT
    week_label,
    week_start,
    initiative,
    '合计' AS waybill_type,
    COUNT(DISTINCT company_id),
    COUNT(DISTINCT waybill_id),
    ROUND(COUNT(DISTINCT waybill_id) * 1.0 / NULLIF(COUNT(DISTINCT company_id), 0), 2)
FROM initiative_explode
GROUP BY week_label, week_start, initiative
ORDER BY 1, 3, 4;
*/
