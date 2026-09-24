/* 撮合运单量 | 周维度（周三起始）：整体 / 线上 / 线下
 * 口径同 01/02/16：
 *   撮合 = 非网货、非TMS
 *   线下 = 有线下销售归属（sales_lv1，biz_segment=2001 & prod_line=3002）
 *   线上 = 命中裂变/投流/电销/调度/无线下 任一（与线下可重叠）
 * 成交判定、微信主体过滤、测试公司剔除同 02_周度汇总
 */
WITH company_zm AS (
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
waybill_base AS (
    SELECT
        waybill.waybill_id,
        DATE_SUB(
            DATE(waybill.accept_dt),
            INTERVAL ((WEEKDAY(waybill.accept_dt) - 2 + 7) % 7) DAY
        ) AS week_start,
        CASE
            WHEN waybill.invoice_type = 20 THEN '网货'
            WHEN waybill.invoice_type = 10 AND waybill.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_category,
        CASE WHEN company_wxx.sales_lv1_company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_offline,
        CASE WHEN company_zm.invitee_id IS NOT NULL THEN 1 ELSE 0 END AS hit_zm,
        CASE WHEN company_tl.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_tl,
        CASE WHEN company_dx.company_name_dx IS NOT NULL THEN 1 ELSE 0 END AS hit_dx,
        CASE WHEN company_dd.company_name_dd IS NOT NULL THEN 1 ELSE 0 END AS hit_dd,
        CASE
            WHEN company_wxx.sales_lv1_company_id IS NULL
             AND company_zm.invitee_id IS NULL
             AND company_tl.company_id IS NULL
             AND company_dx.company_name_dx IS NULL
             AND company_dd.company_name_dd IS NULL
            THEN 1 ELSE 0
        END AS hit_wxx
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    LEFT JOIN company_zm
        ON company_zm.invitee_id = waybill.process_shipper_company_id
    LEFT JOIN company_tl
        ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN company_dx
        ON company_dx.company_name_dx = waybill.process_shipper_company_name
    LEFT JOIN company_dd
        ON company_dd.company_name_dd = waybill.process_shipper_company_name
    LEFT JOIN company_wxx
        ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    WHERE SUBSTR(waybill.accept_dt, 1, 10) >= DATE '2026-04-01'
      AND SUBSTR(waybill.accept_dt, 1, 10) <= CURRENT_DATE()
      AND (
          company_wxx.sales_lv1_company_id IS NOT NULL
          OR NVL(waybill.shipper_company_name, '') NOT IN (
              SELECT DISTINCT dept_name
              FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
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
)
SELECT
    week_start AS 周起始日,
    COUNT(DISTINCT waybill_id) AS 撮合整体_单,
    COUNT(DISTINCT CASE
        WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN waybill_id
    END) AS 撮合线上_单,
    COUNT(DISTINCT CASE
        WHEN hit_offline = 1 THEN waybill_id
    END) AS 撮合线下_单,
    ROUND(COUNT(DISTINCT waybill_id) / 10000, 4) AS 撮合整体_万单,
    ROUND(COUNT(DISTINCT CASE
        WHEN hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0 THEN waybill_id
    END) / 10000, 4) AS 撮合线上_万单,
    ROUND(COUNT(DISTINCT CASE
        WHEN hit_offline = 1 THEN waybill_id
    END) / 10000, 4) AS 撮合线下_万单
FROM waybill_base
WHERE waybill_category = '撮合'
GROUP BY week_start
ORDER BY week_start;
