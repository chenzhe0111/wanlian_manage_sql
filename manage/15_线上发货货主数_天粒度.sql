/* 线上发货货主数 | 天粒度（2026-04-01 ~ 2026-07-31）
 * 口径同 manage/05_发货货主数据_线上发货货主数.sql
 * 指标：当日有发货行为的线上货主企业去重数（家）
 * 线上 = 命中货主招募/投流/电销/调度/无线下销售归属 任一
 * 发货事件 = TMS建单(tms_flag=10) ∪ 货源发布(goods_status<>10)
 */
WITH company_zm AS (
    SELECT DISTINCT invitee_id AS company_id
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
    SELECT customer_company_id AS company_id,
           MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
),
tms_waybill AS (
    SELECT
        SUBSTR(waybill_create_time, 1, 10) AS ship_dt,
        shipper_company_id AS company_id
    FROM dwd_vlsp_mt_match_waybill_tms_business_process_minf
    WHERE NVL(shipper_company_id, '') NOT IN (
              '065d39e9afac48d8a0bdc5896c18d96c', '1993982792389951488',
              '1993985265305452544', '1994003031330062336'
          )
      AND tms_flag = 10
    GROUP BY 1, 2
),
goods AS (
    SELECT
        SUBSTR(create_dt, 1, 10) AS ship_dt,
        publish_company_id AS company_id
    FROM dwd_vlsp_mt_em_goods_manage_info_minf
    WHERE goods_status <> 10
      AND NVL(publish_company_id, '') NOT IN (
              '065d39e9afac48d8a0bdc5896c18d96c', '1993982792389951488',
              '1993985265305452544', '1994003031330062336'
          )
      AND goods_id NOT IN ('CHQY20251204000000016246', 'CHQY20251211000000012094')
    GROUP BY 1, 2
),
ship_event AS (
    SELECT ship_dt, company_id FROM tms_waybill
    UNION
    SELECT ship_dt, company_id FROM goods
),
company_info AS (
    SELECT company_id, company_name
    FROM dwd_vlsp_mt_em_company_manage_info_minf
    WHERE company_id IS NOT NULL
      AND is_fake_company_apply_user = '0'
    GROUP BY 1, 2
),
ship_hit AS (
    SELECT
        DATE(s.ship_dt) AS event_dt,
        s.company_id,
        CASE WHEN company_zm.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_zm,
        CASE WHEN company_tl.company_id IS NOT NULL THEN 1 ELSE 0 END AS hit_tl,
        CASE WHEN company_dx.company_name_dx IS NOT NULL THEN 1 ELSE 0 END AS hit_dx,
        CASE WHEN company_dd.company_name_dd IS NOT NULL THEN 1 ELSE 0 END AS hit_dd,
        CASE
            WHEN company_wxx.sales_lv1_company_id IS NULL
             AND company_zm.company_id IS NULL
             AND company_tl.company_id IS NULL
             AND company_dx.company_name_dx IS NULL
             AND company_dd.company_name_dd IS NULL
            THEN 1 ELSE 0
        END AS hit_wxx
    FROM ship_event s
    INNER JOIN company_info ci ON ci.company_id = s.company_id
    LEFT JOIN company_zm  ON company_zm.company_id = s.company_id
    LEFT JOIN company_tl  ON company_tl.company_id = s.company_id
    LEFT JOIN company_dx  ON company_dx.company_name_dx = ci.company_name
    LEFT JOIN company_dd  ON company_dd.company_name_dd = ci.company_name
    LEFT JOIN company_wxx ON company_wxx.company_id = s.company_id
    WHERE s.ship_dt >= DATE '2026-04-01'
      AND s.ship_dt <  DATE '2026-08-01'
      AND (
          company_wxx.sales_lv1_company_id IS NOT NULL
          OR NVL(ci.company_name, '') NOT IN (
              SELECT DISTINCT dept_name FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
),
ship_online AS (
    SELECT event_dt, company_id
    FROM ship_hit
    WHERE hit_zm + hit_tl + hit_dx + hit_dd + hit_wxx > 0
)
SELECT
    CONCAT('日度-', event_dt, '-线上发货货主数') AS 主键,
    '日度' AS 粒度,
    event_dt AS 统计日,
    DATE_FORMAT(event_dt, '%Y-%m') AS 所属月,
    COUNT(DISTINCT company_id) AS 线上发货货主数
FROM ship_online
GROUP BY event_dt
ORDER BY event_dt;
