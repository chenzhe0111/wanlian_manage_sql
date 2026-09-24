/* 2026-07 无线下销售归属：按公司 + 运单量，带联系人手机号/姓名
 * 口径同 01：无线下销售 + 未命中裂变/投流/电销/调度
 * 联系人：一企业一行；优先注册表有手机号且人名1～5字，否则企业表同条件；人名超长则联系人置空仍可留手机号
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
        NVL(NULLIF(TRIM(waybill.process_shipper_company_name), ''), '(空名称)') AS company_name,
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
    WHERE SUBSTR(waybill.accept_dt, 1, 10) BETWEEN DATE '2026-07-01' AND DATE '2026-07-31'
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
company_agg AS (
    SELECT
        company_id,
        company_name,
        COUNT(DISTINCT waybill_id) AS waybill_cnt
    FROM waybill_hit
    WHERE hit_wxx = 1
    GROUP BY company_id, company_name
),
/* 用户注册表：一公司取一条（优先有手机号 + 人名≤5字） */
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
/* 企业表：一公司取一条（优先有申请手机号 + 人名≤5字） */
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
    CASE
        WHEN u.telephone IS NOT NULL AND TRIM(u.telephone) <> ''
         AND u.username IS NOT NULL
         AND CHAR_LENGTH(TRIM(u.username)) BETWEEN 1 AND 5
        THEN '用户注册表'
        WHEN c.company_apply_user_telephone IS NOT NULL
         AND TRIM(c.company_apply_user_telephone) <> ''
         AND c.company_apply_user_name IS NOT NULL
         AND CHAR_LENGTH(TRIM(c.company_apply_user_name)) BETWEEN 1 AND 5
        THEN '企业表'
        WHEN u.telephone IS NOT NULL AND TRIM(u.telephone) <> '' THEN '用户注册表-无人名'
        WHEN c.company_apply_user_telephone IS NOT NULL
         AND TRIM(c.company_apply_user_telephone) <> '' THEN '企业表-无人名'
        ELSE '无'
    END AS 联系人来源,
    a.waybill_cnt AS 运单量
FROM company_agg a
LEFT JOIN user_contact u
    ON u.company_id = a.company_id
LEFT JOIN company_contact c
    ON c.company_id = a.company_id
ORDER BY a.waybill_cnt DESC;
