/* 线上来源货主 × 无线下销售绑定 · 详细名单
 *
 * 口径：
 *   1) 履约剔异常：unload_time 轴；load/unload 均非空；剔「异常剔除+申诉中」（同 01c/50）
 *   2) 线上来源：命中四举措任一（裂变/投流/电销/调度）——不含「仅无线下残差」
 *   3) 无线下销售绑定：销售线索表无有效记录
 *        dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
 *        biz_segment_code=2001 AND prod_line_code=3002 AND status<>13
 *   4) 一行一货主公司；带联系人、命中举措、统计期内运单量
 *
 * 改 tim 调整窗口（默认：本月1日～T-1）
 */
WITH tim AS (
    SELECT
        DATE_FORMAT(DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY), '%Y-%m-01') AS range_start,
        DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS as_of_dt
),
/* ===== 异常运单（履约新口径） ===== */
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
/* ===== 四举措 + 线下销售线索 ===== */
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
/* 线下销售绑定 = 有效销售线索 */
company_offline AS (
    SELECT
        customer_company_id,
        MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001
      AND prod_line_code IN (3002)
      AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
),
/* ===== 履约运单打标 ===== */
waybill_hit AS (
    SELECT
        waybill.waybill_id,
        DATE(waybill.unload_time) AS unload_dt,
        waybill.process_shipper_company_id AS company_id,
        NVL(
            NULLIF(TRIM(waybill.process_shipper_company_name), ''),
            NVL(NULLIF(TRIM(waybill.shipper_company_name), ''), '(空名称)')
        ) AS company_name,
        CASE
            WHEN waybill.invoice_type = 20 THEN '网货'
            WHEN waybill.invoice_type = 10 AND waybill.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_category,
        CASE WHEN company_zm.invitee_id IS NOT NULL THEN 1 ELSE 0 END AS hit_zm,
        CASE WHEN company_tl.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_tl,
        CASE WHEN company_dx.company_name_dx IS NOT NULL THEN 1 ELSE 0 END AS hit_dx,
        CASE WHEN company_dd.company_name_dd IS NOT NULL THEN 1 ELSE 0 END AS hit_dd,
        CASE WHEN company_offline.sales_lv1_company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_offline
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    CROSS JOIN tim t
    LEFT JOIN company_zm ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_offline ON company_offline.customer_company_id = waybill.process_shipper_company_id
    LEFT JOIN abnormal_waybill abn ON abn.waybill_id = waybill.waybill_id
    WHERE DATE(waybill.unload_time) BETWEEN t.range_start AND t.as_of_dt
      AND waybill.load_time IS NOT NULL
      AND waybill.unload_time IS NOT NULL
      AND abn.waybill_id IS NULL
      AND (
          company_offline.sales_lv1_company_id IS NOT NULL
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
/* 线上四举措命中 且 无线下绑定 */
target_waybill AS (
    SELECT *
    FROM waybill_hit
    WHERE hit_offline = 0
      AND (hit_zm + hit_tl + hit_dx + hit_dd) > 0
),
company_agg AS (
    SELECT
        company_id,
        MAX(company_name) AS company_name,
        MAX(hit_zm) AS hit_zm,
        MAX(hit_tl) AS hit_tl,
        MAX(hit_dx) AS hit_dx,
        MAX(hit_dd) AS hit_dd,
        COUNT(DISTINCT waybill_id) AS waybill_cnt,
        COUNT(DISTINCT CASE WHEN waybill_category = '撮合' THEN waybill_id END) AS 撮合运单,
        COUNT(DISTINCT CASE WHEN waybill_category = 'TMS' THEN waybill_id END) AS TMS运单,
        COUNT(DISTINCT CASE WHEN waybill_category = '网货' THEN waybill_id END) AS 网货运单,
        MIN(unload_dt) AS 首履约日,
        MAX(unload_dt) AS 末履约日
    FROM target_waybill
    GROUP BY company_id
),
user_contact AS (
    SELECT company_id, telephone, username
    FROM (
        SELECT
            company_id,
            telephone,
            username,
            ROW_NUMBER() OVER (
                PARTITION BY company_id
                ORDER BY
                    CASE
                        WHEN telephone IS NOT NULL AND TRIM(telephone) <> ''
                         AND username IS NOT NULL
                         AND CHAR_LENGTH(TRIM(username)) BETWEEN 1 AND 5
                        THEN 0
                        WHEN telephone IS NOT NULL AND TRIM(telephone) <> '' THEN 1
                        ELSE 2
                    END,
                    telephone
            ) AS rn
        FROM dwd_vlsp_mt_em_user_manage_info_minf
        WHERE company_id IS NOT NULL
          AND is_fake_user = '0'
    ) t
    WHERE rn = 1
),
company_contact AS (
    SELECT company_id, company_apply_user_name, company_apply_user_telephone
    FROM (
        SELECT
            company_id,
            company_apply_user_name,
            company_apply_user_telephone,
            ROW_NUMBER() OVER (
                PARTITION BY company_id
                ORDER BY
                    CASE
                        WHEN company_apply_user_telephone IS NOT NULL
                         AND TRIM(company_apply_user_telephone) <> ''
                         AND company_apply_user_name IS NOT NULL
                         AND CHAR_LENGTH(TRIM(company_apply_user_name)) BETWEEN 1 AND 5
                        THEN 0
                        WHEN company_apply_user_telephone IS NOT NULL
                         AND TRIM(company_apply_user_telephone) <> ''
                        THEN 1
                        ELSE 2
                    END,
                    company_apply_user_telephone
            ) AS rn
        FROM dwd_vlsp_mt_em_company_manage_info_minf
        WHERE company_id IS NOT NULL
          AND is_fake_company_apply_user = '0'
    ) t
    WHERE rn = 1
)
SELECT
    a.company_name AS 公司名称,
    a.company_id AS 公司ID,
    CONCAT_WS(
        '+',
        CASE WHEN a.hit_zm = 1 THEN '裂变' END,
        CASE WHEN a.hit_tl = 1 THEN '投流' END,
        CASE WHEN a.hit_dx = 1 THEN '电销' END,
        CASE WHEN a.hit_dd = 1 THEN '调度' END
    ) AS 命中线上举措,
    a.hit_zm AS 裂变,
    a.hit_tl AS 投流,
    a.hit_dx AS 电销,
    a.hit_dd AS 调度,
    '否' AS 是否线下销售绑定,
    CASE
        WHEN u.telephone IS NOT NULL AND TRIM(u.telephone) <> ''
         AND u.username IS NOT NULL
         AND CHAR_LENGTH(TRIM(u.username)) BETWEEN 1 AND 5
        THEN u.telephone
        WHEN c.company_apply_user_telephone IS NOT NULL
         AND TRIM(c.company_apply_user_telephone) <> ''
         AND c.company_apply_user_name IS NOT NULL
         AND CHAR_LENGTH(TRIM(c.company_apply_user_name)) BETWEEN 1 AND 5
        THEN c.company_apply_user_telephone
        WHEN u.telephone IS NOT NULL AND TRIM(u.telephone) <> '' THEN u.telephone
        ELSE c.company_apply_user_telephone
    END AS 手机号,
    CASE
        WHEN u.telephone IS NOT NULL AND TRIM(u.telephone) <> ''
         AND u.username IS NOT NULL
         AND CHAR_LENGTH(TRIM(u.username)) BETWEEN 1 AND 5
        THEN TRIM(u.username)
        WHEN c.company_apply_user_telephone IS NOT NULL
         AND TRIM(c.company_apply_user_telephone) <> ''
         AND c.company_apply_user_name IS NOT NULL
         AND CHAR_LENGTH(TRIM(c.company_apply_user_name)) BETWEEN 1 AND 5
        THEN TRIM(c.company_apply_user_name)
        ELSE NULL
    END AS 联系人,
    a.waybill_cnt AS 履约运单量,
    a.撮合运单,
    a.TMS运单,
    a.网货运单,
    a.首履约日,
    a.末履约日
FROM company_agg a
LEFT JOIN user_contact u ON u.company_id = a.company_id
LEFT JOIN company_contact c ON c.company_id = a.company_id
ORDER BY a.waybill_cnt DESC, a.company_name
;
