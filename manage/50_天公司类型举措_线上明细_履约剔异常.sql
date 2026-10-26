/* 线上明细：天 × 公司 × 运单类型 × 举措 × 运单量 | 履约剔异常 + 等权分摊
 * 用途：拆网货同比/环比——按公司、举措、日看贡献
 *
 * 口径（同 02c / 01c / 46b）：
 *   1) 时间轴：unload_time；load/unload 均非空
 *   2) 异常：排除 异常剔除 + 申诉中
 *   3) 线上：五标签任一命中（裂变/投流/电销/调度/无线下）
 *   4) 运单类型：网货 / TMS / 撮合
 *   5) 举措：等权分摊（分母含无线下）；一单多举措 → 多行，运单量=权重
 *
 * 默认窗口：本年本月 1 日～T-1，以及去年同期同日序（便于同比）
 * 改 tim 可只跑本月，或扩到 9–10 月
 *
 * 分析网货同比建议：
 *   WHERE waybill_category = '网货'
 *   再按 period / initiative / company_name 透视
 */
WITH tim AS (
    SELECT
        /* 本年本月 */
        DATE_FORMAT(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), '%Y-%m-01') AS cur_month_start,
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS as_of_dt,
        /* 去年同期：同月 1 日 → 去年同日序 */
        DATE_SUB(
            DATE_FORMAT(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), '%Y-%m-01'),
            INTERVAL 1 YEAR
        ) AS yoy_month_start,
        DATE_SUB(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), INTERVAL 1 YEAR) AS yoy_as_of_dt
),
/* ===== 异常运单（履约新口径，同 02c） ===== */
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
    SELECT DISTINCT waybill_id, '申诉失败'
    FROM match_way_abnormal_appeal_failed_info
    UNION ALL
    SELECT DISTINCT
        waybill_id,
        CASE
            WHEN appl_status IN (100, 300, 310, 410, 500) THEN '申诉中'
            WHEN appl_status IN (400) THEN '申诉成功'
            WHEN appl_status IN (110, 200, 320, 440) THEN '申诉失败'
            ELSE CAST(appl_status AS STRING)
        END
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
/* ===== 五举措货主池 ===== */
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
            ON a.telephone = b.telephone AND b.is_fake_user = '0'
        WHERE b.user_base_id <> ''
    ) ad
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t1
        ON ad.user_id = t1.user_base_id AND t1.is_fake_user = '0'
    LEFT JOIN dwd_vlsp_mt_em_user_manage_info_minf t3
        ON t3.psn_acct_user_base_id = ad.user_id AND t3.is_fake_user = '0'
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
/* ===== 履约线上运单（本年本月 + 去年同期） ===== */
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        DATE(waybill.unload_time) AS dt,
        CASE
            WHEN DATE(waybill.unload_time) BETWEEN t.cur_month_start AND t.as_of_dt
            THEN '本年本月'
            ELSE '去年同期'
        END AS period_tag,
        waybill.process_shipper_company_id AS company_id,
        NVL(waybill.process_shipper_company_name, waybill.shipper_company_name) AS company_name,
        CASE
            WHEN waybill.invoice_type = 20 THEN '网货'
            WHEN waybill.invoice_type = 10 AND waybill.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_category,
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
    CROSS JOIN tim t
    LEFT JOIN company_zm  ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl  ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = waybill.waybill_id
    WHERE (
            DATE(waybill.unload_time) BETWEEN t.cur_month_start AND t.as_of_dt
         OR DATE(waybill.unload_time) BETWEEN t.yoy_month_start AND t.yoy_as_of_dt
          )
      AND waybill.load_time IS NOT NULL
      AND waybill.unload_time IS NOT NULL
      AND abn.waybill_id IS NULL
      AND (
          company_wxx.sales_lv1_company_id IS NOT NULL
          OR NVL(waybill.shipper_company_name, '') NOT IN (
              SELECT DISTINCT dept_name FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
      AND waybill.waybill_status NOT IN (540, 100)
      AND NVL(waybill.shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c', 1993982792389951488,
          1993985265305452544, 1994003031330062336
      )
      AND (waybill.tms_flag = 20 OR (waybill.tms_flag = 10 AND waybill.driver_operate_accept_time IS NOT NULL))
      /* 仅线上 */
      AND (
          company_zm.invitee_id IS NOT NULL
          OR company_tl.company_id IS NOT NULL
          OR company_dx.company_name_dx IS NOT NULL
          OR company_dd.company_name_dd IS NOT NULL
          OR (
              company_wxx.sales_lv1_company_id IS NULL
              AND company_zm.invitee_id IS NULL
              AND company_tl.company_id IS NULL
              AND company_dx.company_name_dx IS NULL
              AND company_dd.company_name_dd IS NULL
          )
      )
),
waybill_w AS (
    SELECT
        waybill_id,
        dt,
        period_tag,
        company_id,
        company_name,
        waybill_category,
        hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx AS hit_n,
        hit_zm, hit_tl, hit_dx, hit_dd, hit_wxx,
        CASE WHEN hit_zm  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_zm,
        CASE WHEN hit_tl  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_tl,
        CASE WHEN hit_dx  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dx,
        CASE WHEN hit_dd  = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_dd,
        CASE WHEN hit_wxx = 1 THEN 1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) ELSE 0 END AS w_wxx
    FROM waybill_hit
),
/* 等权展开：一行一举措 */
waybill_init AS (
    SELECT waybill_id, dt, period_tag, company_id, company_name, waybill_category, '货主招募' AS initiative, w_zm AS w
    FROM waybill_w WHERE w_zm > 0
    UNION ALL
    SELECT waybill_id, dt, period_tag, company_id, company_name, waybill_category, '投流', w_tl
    FROM waybill_w WHERE w_tl > 0
    UNION ALL
    SELECT waybill_id, dt, period_tag, company_id, company_name, waybill_category, '电销', w_dx
    FROM waybill_w WHERE w_dx > 0
    UNION ALL
    SELECT waybill_id, dt, period_tag, company_id, company_name, waybill_category, '调度', w_dd
    FROM waybill_w WHERE w_dd > 0
    UNION ALL
    SELECT waybill_id, dt, period_tag, company_id, company_name, waybill_category, '无线下销售归属', w_wxx
    FROM waybill_w WHERE w_wxx > 0
)
SELECT
    period_tag AS 期间,
    dt AS 天,
    company_id AS 公司ID,
    company_name AS 公司,
    waybill_category AS 运单类型,
    initiative AS 举措,
    ROUND(SUM(w), 4) AS 运单量,
    ROUND(SUM(w) / 10000.0, 6) AS 运单_万单
FROM waybill_init
GROUP BY period_tag, dt, company_id, company_name, waybill_category, initiative
ORDER BY period_tag, dt, 运单量 DESC;

/* ========== 可选：只看网货同比贡献（公司 Top）==========
SELECT
    company_name AS 公司,
    initiative AS 举措,
    SUM(CASE WHEN period_tag = '本年本月' THEN w ELSE 0 END) AS 本年网货,
    SUM(CASE WHEN period_tag = '去年同期' THEN w ELSE 0 END) AS 去年网货,
    SUM(CASE WHEN period_tag = '本年本月' THEN w ELSE 0 END)
      - SUM(CASE WHEN period_tag = '去年同期' THEN w ELSE 0 END) AS 增量
FROM waybill_init
WHERE waybill_category = '网货'
GROUP BY company_name, initiative
ORDER BY 增量 DESC
LIMIT 50;
*/
