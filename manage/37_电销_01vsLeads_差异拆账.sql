/* 电销运单量：01 月度汇总 vs leads 口径 · 差异拆账
 *
 * 01 命中：waybill.process_shipper_company_name ∈ leads.company_name
 * leads 命中：leads→comp→(goods_id 关联 | 无 goods_id 直挂 | TMS 直挂 company_id)
 *
 * 输出：
 *   1) 四桶汇总（仅01 / 仅leads / 双边 / 均无）
 *   2) 仅01 再拆：goods_id 是否为空、能否 join comp、能否 join goods
 *   3) 仅01 按运单类型
 *
 * 改月份：调整 tim
 */
WITH tim AS (
    SELECT
        DATE '2026-08-01' AS range_start,
        DATE '2026-08-31' AS range_end
),
/* ---------- 01 侧：电销公司名池 ---------- */
company_dx AS (
    SELECT DISTINCT company_name AS company_name_dx
    FROM match_shipper_telesales_leads_info
    WHERE company_name IS NOT NULL AND company_name <> ''
),
company_wxx AS (
    SELECT customer_company_id, MAX(sales_lv1_company_id) AS sales_lv1_company_id
    FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
    WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
      AND customer_company_id IS NOT NULL
    GROUP BY customer_company_id
),
/* ---------- leads 侧：comp / goods ---------- */
comp AS (
    SELECT company_id, company_name
    FROM dwd_vlsp_mt_em_company_manage_info_minf
    WHERE company_id IS NOT NULL
),
leads AS (
    SELECT DISTINCT company_name
    FROM match_shipper_telesales_leads_info
    WHERE company_name IS NOT NULL AND company_name <> ''
),
leads_comp AS (
    SELECT DISTINCT
        l.company_name AS leads_company_name,
        c.company_id   AS comp_company_id
    FROM leads l
    LEFT JOIN comp c ON l.company_name = c.company_name
),
goods AS (
    SELECT goods_id, publish_company_id
    FROM dwd_vlsp_mt_em_goods_manage_info_minf
    WHERE create_dt >= '2025-12-01'
      AND goods_status <> 10
      AND publish_main_body_type IN (10, 20)
),
/* ---------- 8 月有效运单基表 ---------- */
waybill_base AS (
    SELECT
        w.waybill_id,
        SUBSTR(w.accept_dt, 1, 10) AS accept_dt,
        w.process_shipper_company_id,
        w.process_shipper_company_name,
        CASE
            WHEN w.uppermost_goods_id IS NOT NULL AND w.uppermost_goods_id <> '' THEN w.uppermost_goods_id
            ELSE w.goods_id
        END AS goods_id_cur,
        CASE
            WHEN w.invoice_type = 20 THEN '网货'
            WHEN w.invoice_type = 10 AND w.tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_type,
        CASE
            WHEN REGEXP_EXTRACT(w.waybill_id, '^([a-zA-Z]+)', 1) = 'TLYD' THEN '不开票-撮合铁路运单'
            WHEN REGEXP_EXTRACT(w.waybill_id, '^([a-zA-Z]+)', 1) = 'ZYYD' THEN '不开票-TMS运单'
            WHEN REGEXP_EXTRACT(w.waybill_id, '^([a-zA-Z]+)', 1) = 'CHYD' THEN '不开票-撮合公路运单'
            WHEN REGEXP_EXTRACT(w.waybill_id, '^([a-zA-Z]+)', 1) = 'YD'   THEN '开票-网货运单'
            ELSE '其他'
        END AS waybill_tag
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf w
    CROSS JOIN tim t
    LEFT JOIN company_wxx wx ON wx.customer_company_id = w.process_shipper_company_id
    WHERE SUBSTR(w.accept_dt, 1, 10) BETWEEN t.range_start AND t.range_end
      AND (
          wx.sales_lv1_company_id IS NOT NULL
          OR NVL(w.shipper_company_name, '') NOT IN (
              SELECT DISTINCT dept_name FROM dim.dim_vlsp_weixin_biz_company_minf
          )
      )
      AND w.waybill_status NOT IN (540, 100)
      AND NVL(w.shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c', 1993982792389951488,
          1993985265305452544, 1994003031330062336
      )
      AND (w.tms_flag = 20 OR (w.tms_flag = 10 AND w.driver_operate_accept_time IS NOT NULL))
),
/* ---------- 01 命中标记 ---------- */
hit_01 AS (
    SELECT
        wb.*,
        CASE WHEN dx.company_name_dx IS NOT NULL THEN 1 ELSE 0 END AS is_01
    FROM waybill_base wb
    LEFT JOIN company_dx dx
        ON dx.company_name_dx = wb.process_shipper_company_name
),
/* ---------- leads 路径1：货源关联（同36，经 leads→comp→goods→waybill） ---------- */
hit_leads_goods AS (
    SELECT DISTINCT wb.waybill_id
    FROM waybill_base wb
    INNER JOIN goods g
        ON g.goods_id = wb.goods_id_cur
    INNER JOIN comp c
        ON c.company_id = g.publish_company_id
    INNER JOIN leads l
        ON l.company_name = c.company_name
),
/* ---------- leads 路径2：无货源直挂（同36，经 leads→comp→company_id） ---------- */
hit_leads_company AS (
    SELECT DISTINCT wb.waybill_id
    FROM waybill_base wb
    INNER JOIN comp c
        ON c.company_id = wb.process_shipper_company_id
    INNER JOIN leads l
        ON l.company_name = c.company_name
    WHERE wb.goods_id_cur IS NULL OR wb.goods_id_cur = ''
),
/* ---------- leads 路径3：TMS 有 goods_id 直挂（同36） ---------- */
hit_leads_tms AS (
    SELECT DISTINCT wb.waybill_id
    FROM waybill_base wb
    INNER JOIN comp c
        ON c.company_id = wb.process_shipper_company_id
    INNER JOIN leads l
        ON l.company_name = c.company_name
    WHERE wb.waybill_tag = '不开票-TMS运单'
      AND wb.goods_id_cur IS NOT NULL
      AND wb.goods_id_cur <> ''
),
hit_leads AS (
    SELECT waybill_id FROM hit_leads_goods
    UNION
    SELECT waybill_id FROM hit_leads_company
    UNION
    SELECT waybill_id FROM hit_leads_tms
),
/* ---------- 合并 + 辅助诊断字段 ---------- */
tagged AS (
    SELECT
        h.waybill_id,
        h.accept_dt,
        h.process_shipper_company_id,
        h.process_shipper_company_name,
        h.goods_id_cur,
        h.waybill_type,
        h.waybill_tag,
        h.is_01,
        CASE WHEN hl.waybill_id IS NOT NULL THEN 1 ELSE 0 END AS is_leads,
        CASE
            WHEN lc.comp_company_id IS NOT NULL THEN 1 ELSE 0
        END AS leads_join_comp_ok,
        CASE
            WHEN h.goods_id_cur IS NULL OR h.goods_id_cur = '' THEN '无goods_id'
            ELSE '有goods_id'
        END AS goods_id_flag,
        CASE
            WHEN g_match.goods_id IS NOT NULL THEN 1 ELSE 0
        END AS goods_match_ok,
        CASE
            WHEN lc.comp_company_id IS NOT NULL
             AND lc.comp_company_id = h.process_shipper_company_id THEN 1 ELSE 0
        END AS company_id_match_ok
    FROM hit_01 h
    LEFT JOIN hit_leads hl ON hl.waybill_id = h.waybill_id
    LEFT JOIN leads_comp lc
        ON lc.leads_company_name = h.process_shipper_company_name
    LEFT JOIN goods g_match
        ON g_match.publish_company_id = lc.comp_company_id
       AND g_match.goods_id = h.goods_id_cur
),
bucketed AS (
    SELECT
        *,
        CASE
            WHEN is_01 = 1 AND is_leads = 1 THEN 'C_双边命中'
            WHEN is_01 = 1 AND is_leads = 0 THEN 'A_仅01'
            WHEN is_01 = 0 AND is_leads = 1 THEN 'B_仅leads'
            ELSE 'D_均无'
        END AS bucket
    FROM tagged
)

/* ==================== 结果1：四桶汇总 ==================== */
SELECT
    '1_四桶汇总' AS 报表,
    bucket AS 维度,
    COUNT(DISTINCT waybill_id) AS 运单量
FROM bucketed
WHERE is_01 = 1 OR is_leads = 1
GROUP BY bucket

UNION ALL

SELECT
    '1_四桶汇总',
    '合计_01口径',
    COUNT(DISTINCT CASE WHEN is_01 = 1 THEN waybill_id END)
FROM bucketed

UNION ALL

SELECT
    '1_四桶汇总',
    '合计_leads口径',
    COUNT(DISTINCT CASE WHEN is_leads = 1 THEN waybill_id END)
FROM bucketed

UNION ALL

SELECT
    '1_四桶汇总',
    '差异_01减leads',
    COUNT(DISTINCT CASE WHEN is_01 = 1 THEN waybill_id END)
    - COUNT(DISTINCT CASE WHEN is_leads = 1 THEN waybill_id END)
FROM bucketed

UNION ALL

/* ==================== 结果2：仅01 → 原因拆解 ==================== */
SELECT
    '2_仅01原因',
    CASE
        WHEN goods_id_flag = '无goods_id' AND leads_join_comp_ok = 0
            THEN '无goods_id且leads未关联到comp'
        WHEN goods_id_flag = '无goods_id' AND leads_join_comp_ok = 1 AND company_id_match_ok = 0
            THEN '无goods_id但运单company_id与comp不一致'
        WHEN goods_id_flag = '有goods_id' AND leads_join_comp_ok = 0
            THEN '有goods_id且leads未关联到comp'
        WHEN goods_id_flag = '有goods_id' AND waybill_tag = '不开票-TMS运单'
            THEN 'TMS有goods_id未走TMS直挂(查comp链)'
        WHEN goods_id_flag = '有goods_id' AND leads_join_comp_ok = 1 AND goods_match_ok = 0
            THEN '有goods_id且comp有但货源池对不上(非TMS)'
        WHEN goods_id_flag = '有goods_id' AND leads_join_comp_ok = 1 AND goods_match_ok = 1
            THEN '有goods_id且货源可匹配但仍未进leads(查逻辑)'
        ELSE '其他'
    END AS 维度,
    COUNT(DISTINCT waybill_id) AS 运单量
FROM bucketed
WHERE bucket = 'A_仅01'
GROUP BY 1, 2

UNION ALL

/* ==================== 结果3：仅01 × goods_id 是否为空 ==================== */
SELECT
    '3_仅01_goods维度',
    goods_id_flag AS 维度,
    COUNT(DISTINCT waybill_id) AS 运单量
FROM bucketed
WHERE bucket = 'A_仅01'
GROUP BY goods_id_flag

UNION ALL

/* ==================== 结果4：仅01 × 运单类型 ==================== */
SELECT
    '4_仅01_运单类型',
    waybill_type AS 维度,
    COUNT(DISTINCT waybill_id) AS 运单量
FROM bucketed
WHERE bucket = 'A_仅01'
GROUP BY waybill_type

UNION ALL

SELECT
    '4_仅01_运单类型',
    waybill_tag AS 维度,
    COUNT(DISTINCT waybill_id) AS 运单量
FROM bucketed
WHERE bucket = 'A_仅01'
GROUP BY waybill_tag

UNION ALL

/* ==================== 结果5：仅leads（一般很少，供核对） ==================== */
SELECT
    '5_仅leads',
    waybill_type AS 维度,
    COUNT(DISTINCT waybill_id) AS 运单量
FROM bucketed
WHERE bucket = 'B_仅leads'
GROUP BY waybill_type

ORDER BY 报表, 维度;
