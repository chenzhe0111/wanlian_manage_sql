/* 注册司机 · 业务分类型（对齐「注册司机车辆数据」41UJIa）
 * https://wanlianyida.feishu.cn/sheets/L91EsEtAohwjhStD4y6cYLCGnVe?sheet=41UJIa
 *
 * 口径：
 *   1) 当月新增注册 = 当月注册成功司机（register_status=1，不限是否有单）
 *   2) 业务分类型 = 注册当月、注册日及之后的首单类型（TMS / 撮合 / 网货）
 *      当月无履约单的不进三类，故三类合计 ≤ 当月新增
 *   3) 各类型运单量 = 当月全部履约运单（按运单类型，不限是否新注册）
 *   4) 单注册司机运单量 = 该类型运单量 / 该类型注册司机数（单/人，不是万）
 *   5) 累计注册量 = 截至该月末、且不晚于 pt 的注册成功司机去重
 *   6) pt = 昨天；注册日、卸货日都不含今天
 *
 * 回写「注册司机车辆数据」时（实际列在 J 前插入后）：
 *   J=9月实际  K=10月实际  L=11月实际  M=12月实际
 *   行：5累计 / 6当月新增 / 7业务合计 / 8-10 TMS / 11-13 撮合 / 14-16 网货
 *   单位：注册与运单用「_万」；单司机运单用「单/人」
 *   末尾整数字段对齐表内第 68 行起的月明细（人数、运单数，不除以万）
 */
WITH params AS (
    SELECT DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) AS pt
),
registered_driver AS (
    SELECT
        telephone,
        MIN(DATE(create_date)) AS register_dt
    FROM dwd_vlsp_mt_em_driver_manage_info_minf
    CROSS JOIN params p
    WHERE register_status = 1
      AND telephone IS NOT NULL
      AND telephone <> ''
      AND create_date IS NOT NULL
      AND DATE(create_date) <= p.pt
    GROUP BY telephone
),
waybill_base AS (
    SELECT
        waybill_id,
        unload_time,
        DATE(unload_time) AS unload_day,
        DATE_FORMAT(unload_time, '%Y-%m-01') AS unload_mon,
        driver_mobile,
        CASE
            WHEN invoice_type = 20 THEN '网货'
            WHEN invoice_type = 10 AND tms_flag = 10 THEN 'TMS'
            ELSE '撮合'
        END AS waybill_type
    FROM dwd_vlsp_mt_match_waybill_match_business_process_minf
    CROSS JOIN params p
    WHERE load_time IS NOT NULL
      AND unload_time IS NOT NULL
      AND DATE(unload_time) <= p.pt
      AND waybill_status NOT IN (540, 100)
      AND (tms_flag = 20 OR (tms_flag = 10 AND driver_operate_accept_time IS NOT NULL))
      AND NVL(shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          '1993982792389951488',
          '1993985265305452544',
          '1994003031330062336'
      )
),
/* —— 新注册司机：当月首单定类型 —— */
waybill_reg_month AS (
    SELECT w.*
    FROM waybill_base w
    INNER JOIN registered_driver d
        ON w.driver_mobile = d.telephone
       AND w.unload_mon = DATE_FORMAT(d.register_dt, '%Y-%m-01')
       AND w.unload_day >= d.register_dt
    WHERE w.driver_mobile IS NOT NULL
      AND w.driver_mobile <> ''
),
driver_month_first AS (
    SELECT
        driver_mobile,
        unload_mon AS reg_mon,
        waybill_type AS driver_type,
        ROW_NUMBER() OVER (
            PARTITION BY driver_mobile, unload_mon
            ORDER BY unload_time ASC, waybill_id ASC
        ) AS rn
    FROM waybill_reg_month
),
driver_attr AS (
    SELECT
        d.telephone,
        DATE_FORMAT(d.register_dt, '%Y-%m-01') AS reg_mon,
        f.driver_type
    FROM registered_driver d
    LEFT JOIN driver_month_first f
        ON d.telephone = f.driver_mobile
       AND f.reg_mon = DATE_FORMAT(d.register_dt, '%Y-%m-01')
       AND f.rn = 1
),
driver_cnt AS (
    SELECT
        reg_mon AS mon,
        COUNT(DISTINCT telephone) AS reg_all,
        COUNT(DISTINCT CASE WHEN driver_type = 'TMS'  THEN telephone END) AS tms_drv,
        COUNT(DISTINCT CASE WHEN driver_type = '撮合' THEN telephone END) AS ch_drv,
        COUNT(DISTINCT CASE WHEN driver_type = '网货' THEN telephone END) AS wh_drv
    FROM driver_attr
    GROUP BY reg_mon
),
/* —— 整体运单量：按运单类型，不限新注册 —— */
waybill_cnt AS (
    SELECT
        unload_mon AS mon,
        COUNT(DISTINCT waybill_id) AS wb_all,
        COUNT(DISTINCT CASE WHEN waybill_type = 'TMS'  THEN waybill_id END) AS tms_wb,
        COUNT(DISTINCT CASE WHEN waybill_type = '撮合' THEN waybill_id END) AS ch_wb,
        COUNT(DISTINCT CASE WHEN waybill_type = '网货' THEN waybill_id END) AS wh_wb
    FROM waybill_base
    GROUP BY unload_mon
),
joined AS (
    SELECT
        COALESCE(d.mon, w.mon) AS mon,
        NVL(d.reg_all, 0) AS reg_all,
        NVL(d.tms_drv, 0) AS tms_drv,
        NVL(d.ch_drv, 0)  AS ch_drv,
        NVL(d.wh_drv, 0)  AS wh_drv,
        NVL(w.wb_all, 0)  AS wb_all,
        NVL(w.tms_wb, 0)  AS tms_wb,
        NVL(w.ch_wb, 0)   AS ch_wb,
        NVL(w.wh_wb, 0)   AS wh_wb
    FROM driver_cnt d
    FULL OUTER JOIN waybill_cnt w
        ON d.mon = w.mon
),
/* 累计含 2026 年前存量；输出再截到 2026 年 */
month_base AS (
    SELECT
        j.*,
        SUM(j.reg_all) OVER (ORDER BY j.mon) AS cum_reg
    FROM joined j
)
SELECT
    p.pt,
    DATE_FORMAT(b.mon, '%Y-%m') AS 月份,
    ROUND(b.cum_reg / 10000.0, 4) AS 累计注册量_万,
    ROUND(b.reg_all / 10000.0, 4) AS 当月新增注册量_万,
    ROUND((b.tms_drv + b.ch_drv + b.wh_drv) / 10000.0, 4) AS 业务注册司机合计_万,
    ROUND(b.tms_drv / 10000.0, 4) AS TMS注册司机数_万,
    ROUND(b.tms_wb * 1.0 / NULLIF(b.tms_drv, 0), 2) AS TMS单注册司机运单量,
    ROUND(b.tms_wb / 10000.0, 4) AS TMS运单量_万,
    ROUND(b.ch_drv / 10000.0, 4) AS 撮合注册司机数_万,
    ROUND(b.ch_wb * 1.0 / NULLIF(b.ch_drv, 0), 2) AS 撮合单注册司机运单量,
    ROUND(b.ch_wb / 10000.0, 4) AS 撮合运单量_万,
    ROUND(b.wh_drv / 10000.0, 4) AS 网货注册司机数_万,
    ROUND(b.wh_wb * 1.0 / NULLIF(b.wh_drv, 0), 2) AS 网货单注册司机运单量,
    ROUND(b.wh_wb / 10000.0, 4) AS 网货运单量_万,
    b.reg_all AS 注册司机数,
    b.tms_drv AS TMS注册司机数,
    b.ch_drv  AS 撮合注册司机数,
    b.wh_drv  AS 网货注册司机数,
    b.wb_all  AS 整体运单量,
    b.tms_wb  AS TMS运单量,
    b.ch_wb   AS 撮合运单量,
    b.wh_wb   AS 网货运单量
FROM month_base b
CROSS JOIN params p
WHERE b.mon >= '2026-01-01'
  AND b.mon <  '2027-01-01'
ORDER BY b.mon;
