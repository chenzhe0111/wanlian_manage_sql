/* 投流端：每个货主 上周 vs 上上周 成交运单量
 * 口径对齐 02_周度汇总：
 *   - 投流 = company_tl 宽口径（信息流 + 拼表单）
 *   - 成交运单 = accept_dt 落在统计周、有效运单过滤
 *   - 周 = 周三起始（WEEKDAY-2）
 * 上周 = 当前周三周往前 7 天（完整周）；上上周 = 再往前 7 天（完整周）
 * 例：今天 2026-08-19（周三）→ 上周 8/12–8/18，上上周 8/5–8/11
 */
WITH weeks AS (
    SELECT
        DATE_SUB(
            CURRENT_DATE(),
            INTERVAL ((WEEKDAY(CURRENT_DATE()) - 2 + 7) % 7) DAY
        ) AS this_week_start
),
week_range AS (
    SELECT
        DATE_SUB(this_week_start, INTERVAL 7 DAY) AS last_week_start,
        DATE_SUB(this_week_start, INTERVAL 1 DAY) AS last_week_end,
        DATE_SUB(this_week_start, INTERVAL 14 DAY) AS prev_week_start,
        DATE_SUB(this_week_start, INTERVAL 8 DAY) AS prev_week_end
    FROM weeks
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
waybill_tl AS (
    SELECT
        DATE(waybill.accept_dt) AS event_dt,
        waybill.process_shipper_company_id AS company_id,
        MAX(waybill.process_shipper_company_name) AS company_name,
        waybill.waybill_id
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf waybill
    INNER JOIN company_tl
        ON company_tl.company_id = waybill.process_shipper_company_id
    LEFT JOIN (
        SELECT customer_company_id, MAX(sales_lv1_company_id) AS sales_lv1_company_id
        FROM dwd_vlsp_mt_bt_sale_cluer_record_business_process_minf
        WHERE biz_segment_code = 2001 AND prod_line_code IN (3002) AND status <> 13
          AND customer_company_id IS NOT NULL
        GROUP BY customer_company_id
    ) company_wxx
        ON company_wxx.customer_company_id = waybill.process_shipper_company_id
    CROSS JOIN week_range wr
    WHERE DATE(waybill.accept_dt) >= wr.prev_week_start
      AND DATE(waybill.accept_dt) <= wr.last_week_end
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
      AND (waybill.tms_flag = 20 OR (waybill.tms_flag = 10 AND waybill.driver_operate_accept_time IS NOT NULL))
    GROUP BY DATE(waybill.accept_dt), waybill.process_shipper_company_id, waybill.waybill_id
),
shipper_week AS (
    SELECT
        w.company_id,
        MAX(w.company_name) AS company_name,
        COUNT(DISTINCT CASE
            WHEN w.event_dt >= wr.prev_week_start AND w.event_dt <= wr.prev_week_end
            THEN w.waybill_id END) AS prev_week_cnt,
        COUNT(DISTINCT CASE
            WHEN w.event_dt >= wr.last_week_start AND w.event_dt <= wr.last_week_end
            THEN w.waybill_id END) AS last_week_cnt
    FROM waybill_tl w
    CROSS JOIN week_range wr
    GROUP BY w.company_id
)
SELECT
    wr.prev_week_start AS 上上周起始日,
    wr.last_week_start AS 上周起始日,
    s.company_id AS 货主ID,
    s.company_name AS 货主名称,
    s.prev_week_cnt AS 上上周运单量,
    s.last_week_cnt AS 上周运单量,
    s.last_week_cnt - s.prev_week_cnt AS 较上上周变化,
    CASE
        WHEN s.prev_week_cnt = 0 THEN NULL
        ELSE ROUND((s.last_week_cnt - s.prev_week_cnt) * 1.0 / s.prev_week_cnt, 4)
    END AS 周环比
FROM shipper_week s
CROSS JOIN week_range wr
ORDER BY s.last_week_cnt DESC, s.prev_week_cnt DESC, s.company_id;
