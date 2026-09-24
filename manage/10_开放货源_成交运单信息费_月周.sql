/* 开放货源 + 成交率 + 开放货源运单量 + 信息费 | 月度 + 周度 | 2026年4-6月 */
WITH tim AS (
    SELECT
        '2026-04-01' AS range_start,
        '2026-07-01' AS range_end   /* 含6月，不含7月 */
),
open_goods AS (
    SELECT
        goods_id,
        create_time
    FROM dwd_vlsp_mt_em_goods_manage_info_minf g
    WHERE goods_status IN (30, 50, 60, 70, 80, 90)
      AND publish_main_body_type = 10          /* 司机货源 */
      AND goods_source_service_type IN (10, 30)
      AND COALESCE(publish_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          '1993982792389951488',
          '1993985265305452544',
          '1994003031330062336'
      )
      AND goods_id NOT IN ('CHQY20251204000000016246', 'CHQY20251211000000012094')
      AND plf_driver_receive_flag = 10         /* 允许平台司机接单 */
),
goods_cj AS (
    SELECT
        goods_id,
        COUNT(CASE WHEN TRIM(dispatcher_user_id) <> '' THEN waybill_id END) AS dispatcher_cnt,
        COUNT(CASE WHEN TRIM(dispatcher_user_id) = '' THEN waybill_id END) AS not_dispatcher_cnt,
        COUNT(waybill_id) AS total_cnt
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf
    WHERE NVL(shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          '1993982792389951488',
          '1993985265305452544',
          '1994003031330062336'
      )
      AND tms_flag = 20
      AND waybill_status NOT IN (540, 100)
    GROUP BY goods_id
),
open_goods_waybill AS (
    SELECT
        og.goods_id,
        og.create_time,
        cj.dispatcher_cnt,
        cj.not_dispatcher_cnt,
        cj.total_cnt
    FROM open_goods og
    LEFT JOIN goods_cj cj
        ON og.goods_id = cj.goods_id
),
waybill AS (
    SELECT
        w.goods_id,
        w.waybill_id,
        w.accept_dt,
        w.dispatcher_user_id
    FROM dwd.dwd_vlsp_mt_match_waybill_match_business_process_minf w
    CROSS JOIN tim
    WHERE NVL(shipper_company_id, '') NOT IN (
          '065d39e9afac48d8a0bdc5896c18d96c',
          '1993982792389951488',
          '1993985265305452544',
          '1994003031330062336'
      )
      AND tms_flag = 20
      AND w.waybill_status NOT IN (540, 100)
      AND DATE_FORMAT(w.accept_dt, '%Y-%m-%d') >= tim.range_start
      AND DATE_FORMAT(w.accept_dt, '%Y-%m-%d') <  tim.range_end
),
waybill_info_fee AS (
    SELECT
        r.waybill_id,
        r.info_fee,
        r.info_fee_pay_time
    FROM dwd.dwd_vlsp_mt_settle_waybill_revenue_share_business_process_minf r
    CROSS JOIN tim
    WHERE r.info_fee > 0
      AND r.dispatch_type IN (20, 30)           /* 区域/三方调度 */
      AND r.dispatcher_user_id NOT IN (
          '1993495329000587264',
          '2061773197266493440',
          '2048625413768757248',
          '1993985265305452544'
      )
      AND r.info_fee_pay_status = 30            /* 支付成功 */
      /* 与原文一致：用 DATE_FORMAT 字符串比较，避免 DATE() 对时间字段解析失败导致信息费全空 */
      AND DATE_FORMAT(r.info_fee_pay_time, '%Y-%m-%d') >= tim.range_start
      AND DATE_FORMAT(r.info_fee_pay_time, '%Y-%m-%d') <  tim.range_end
),

/* ========== ① 开放货源统计（按货源创建时间） ========== */
metric_open_goods AS (
    SELECT
        '月' AS gran,
        DATE(DATE_FORMAT(create_time, '%Y-%m-01')) AS period_start,
        COUNT(goods_id) AS open_goods_cnt,
        COUNT(CASE WHEN total_cnt IS NOT NULL THEN goods_id END) AS cj_open_goods_cnt,
        ROUND(
            COUNT(CASE WHEN total_cnt IS NOT NULL THEN goods_id END) * 1.0
            / NULLIF(COUNT(goods_id), 0),
            4
        ) AS cj_open_goods_rat
    FROM open_goods_waybill
    CROSS JOIN tim
    WHERE DATE_FORMAT(create_time, '%Y-%m-%d') >= tim.range_start
      AND DATE_FORMAT(create_time, '%Y-%m-%d') <  tim.range_end
    GROUP BY DATE(DATE_FORMAT(create_time, '%Y-%m-01'))
    UNION ALL
    SELECT
        '周',
        DATE(DATE_SUB(create_time, INTERVAL ((WEEKDAY(create_time) - 2 + 7) % 7) DAY)),
        COUNT(goods_id),
        COUNT(CASE WHEN total_cnt IS NOT NULL THEN goods_id END),
        ROUND(
            COUNT(CASE WHEN total_cnt IS NOT NULL THEN goods_id END) * 1.0
            / NULLIF(COUNT(goods_id), 0),
            4
        )
    FROM open_goods_waybill
    CROSS JOIN tim
    WHERE DATE_FORMAT(create_time, '%Y-%m-%d') >= tim.range_start
      AND DATE_FORMAT(create_time, '%Y-%m-%d') <  tim.range_end
    GROUP BY DATE(DATE_SUB(create_time, INTERVAL ((WEEKDAY(create_time) - 2 + 7) % 7) DAY))
),

/* ========== ② 开放货源运单量（按接单时间） ========== */
metric_open_waybill AS (
    SELECT
        '月' AS gran,
        DATE(DATE_FORMAT(w.accept_dt, '%Y-%m-01')) AS period_start,
        COUNT(w.waybill_id) AS open_goods_waybill_cnt
    FROM open_goods og
    INNER JOIN waybill w
        ON og.goods_id = w.goods_id
    WHERE w.dispatcher_user_id NOT IN (
          '1993495329000587264',
          '2061773197266493440',
          '2048625413768757248',
          '1993985265305452544'
      )
    GROUP BY DATE(DATE_FORMAT(w.accept_dt, '%Y-%m-01'))
    UNION ALL
    SELECT
        '周',
        DATE(DATE_SUB(w.accept_dt, INTERVAL ((WEEKDAY(w.accept_dt) - 2 + 7) % 7) DAY)),
        COUNT(w.waybill_id)
    FROM open_goods og
    INNER JOIN waybill w
        ON og.goods_id = w.goods_id
    WHERE w.dispatcher_user_id NOT IN (
          '1993495329000587264',
          '2061773197266493440',
          '2048625413768757248',
          '1993985265305452544'
      )
    GROUP BY DATE(DATE_SUB(w.accept_dt, INTERVAL ((WEEKDAY(w.accept_dt) - 2 + 7) % 7) DAY))
),

/* ========== ③ 信息费支付（按支付成功时间） ========== */
metric_info_fee AS (
    SELECT
        '月' AS gran,
        DATE(DATE_FORMAT(info_fee_pay_time, '%Y-%m-01')) AS period_start,
        COUNT(waybill_id) AS info_fee_pay_cnt,
        SUM(info_fee) AS info_fee_pay_amount,
        ROUND(SUM(info_fee) / NULLIF(COUNT(waybill_id), 0), 2) AS avg_info_fee
    FROM waybill_info_fee
    GROUP BY DATE(DATE_FORMAT(info_fee_pay_time, '%Y-%m-01'))
    UNION ALL
    SELECT
        '周',
        DATE(DATE_SUB(info_fee_pay_time, INTERVAL ((WEEKDAY(info_fee_pay_time) - 2 + 7) % 7) DAY)),
        COUNT(waybill_id),
        SUM(info_fee),
        ROUND(SUM(info_fee) / NULLIF(COUNT(waybill_id), 0), 2)
    FROM waybill_info_fee
    GROUP BY DATE(DATE_SUB(info_fee_pay_time, INTERVAL ((WEEKDAY(info_fee_pay_time) - 2 + 7) % 7) DAY))
),

/* 周期维表：三块指标的月/周并集 */
period_dim AS (
    SELECT gran, period_start FROM metric_open_goods
    UNION
    SELECT gran, period_start FROM metric_open_waybill
    UNION
    SELECT gran, period_start FROM metric_info_fee
)

SELECT
    CASE p.gran WHEN '月' THEN '月度' WHEN '周' THEN '周度' END AS 月周标识,
    p.period_start AS 周期起始日,
    g.open_goods_cnt AS 开放货源数,
    g.cj_open_goods_cnt AS 成交开放货源数,
    g.cj_open_goods_rat AS 开放货源成交率,
    w.open_goods_waybill_cnt AS 开放货源运单量,
    f.info_fee_pay_cnt AS 信息费支付运单量,
    f.info_fee_pay_amount AS 信息费支付金额,
    f.avg_info_fee AS 单均信息费金额
FROM period_dim p
LEFT JOIN metric_open_goods g
    ON g.gran = p.gran AND g.period_start = p.period_start
LEFT JOIN metric_open_waybill w
    ON w.gran = p.gran AND w.period_start = p.period_start
LEFT JOIN metric_info_fee f
    ON f.gran = p.gran AND f.period_start = p.period_start
ORDER BY
    CASE p.gran WHEN '月' THEN 1 WHEN '周' THEN 2 END,
    p.period_start;
