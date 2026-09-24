/* 调度：每个客户本周成交运单量（均分 vs 不均分）
 * 口径同 01/09/18：
 *   - 过滤：线下线索 OR 非微信主体；剔除测试公司；有效成交运单
 *   - 调度命中：match_shipper_dispatching_leads_info（公司名）
 *   - 均分：命中调度时 1/线上五渠道 hit_cnt
 *   - 不均分：命中调度整单计 1
 * 周度：周三为一周起点（与业务周报一致）；改 tim 即可换周
 */
WITH tim AS (
    SELECT
        DATE '2026-08-12' AS week_start,  /* 本周周三 */
        DATE '2026-08-13' AS range_end    /* 统计截止日，右闭；整周可改为 week_start+6 */
),
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
        waybill.process_shipper_company_id AS company_id,
        waybill.process_shipper_company_name AS company_name,
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
    WHERE SUBSTR(waybill.accept_dt, 1, 10) BETWEEN t.week_start AND t.range_end
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
waybill_dd AS (
    SELECT
        waybill_id,
        company_id,
        company_name,
        waybill_category,
        hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx AS hit_cnt,
        /* 均分 */
        1.0 / NULLIF(hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx, 0) AS w_dd_share,
        /* 不均分 */
        1.0 AS w_dd_full
    FROM waybill_hit
    WHERE hit_dd = 1
),
by_company AS (
    SELECT
        company_id,
        company_name,
        COUNT(DISTINCT waybill_id) AS waybill_cnt_raw,
        SUM(w_dd_share) AS cnt_share,
        SUM(w_dd_full) AS cnt_full
    FROM waybill_dd
    GROUP BY company_id, company_name
),
tot AS (
    SELECT
        SUM(cnt_share) AS share_sum,
        SUM(cnt_full) AS full_sum
    FROM by_company
)
SELECT
    (SELECT week_start FROM tim) AS 周起始日,
    (SELECT range_end FROM tim) AS 统计截止日,
    b.company_id AS 公司ID,
    b.company_name AS 公司名称,
    b.waybill_cnt_raw AS 命中调度运单数_去重,
    ROUND(b.cnt_share, 4) AS 运单量_均分,
    ROUND(b.cnt_full, 4) AS 运单量_不均分,
    ROUND(b.cnt_share / NULLIF(t.share_sum, 0) * 100, 2) AS 占调度本周_均分_pct,
    ROUND(b.cnt_full / NULLIF(t.full_sum, 0) * 100, 2) AS 占调度本周_不均分_pct
FROM by_company b
CROSS JOIN tot t
ORDER BY b.cnt_full DESC, b.cnt_share DESC;
