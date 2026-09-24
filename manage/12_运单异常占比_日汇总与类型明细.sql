/* 运单异常占比 | 每日汇总 + 运单类型×异常子类型明细 */
WITH total_by_day_type AS (
    /* 1. 总运单：按日期 + 运单类型 */
    SELECT
        CAST(unload_time AS DATE) AS unload_dt,
        CASE
            WHEN LEFT(waybill_id, 4) = 'ZYYD' THEN 'TMS运单'
            WHEN LEFT(waybill_id, 4) = 'CHYD' THEN '撮合运单'
            WHEN LEFT(waybill_id, 2) = 'YD' THEN '网货运单'
            ELSE '其他'
        END AS waybill_type,
        COUNT(DISTINCT waybill_id) AS total_cnt
    FROM dwd_vlsp_mt_match_waybill_match_business_process_minf
    WHERE waybill_status NOT IN (540, 100)
      AND (
          tms_flag = 20
          OR (tms_flag = 10 AND driver_operate_accept_time IS NOT NULL)
      )
    GROUP BY 1, 2
),
abnormal_by_day_type_sub AS (
    /* 2. 异常：按日期 + 运单类型 + 异常子类型 */
    SELECT
        CAST(unload_time AS DATE) AS unload_dt,
        CASE
            WHEN LEFT(waybill_id, 4) = 'ZYYD' THEN 'TMS运单'
            WHEN LEFT(waybill_id, 4) = 'CHYD' THEN '撮合运单'
            WHEN LEFT(waybill_id, 2) = 'YD' THEN '网货运单'
            ELSE '其他'
        END AS waybill_type,
        CASE
            WHEN scenario_tags LIKE '%运费异常%' THEN '运费异常'
            WHEN scenario_tags LIKE '%秒装秒卸%' THEN '秒装秒卸'
            WHEN scenario_tags LIKE '%时速异常高%' THEN '时速异常高'
            WHEN scenario_tags LIKE '%装卸货打卡异常-申诉%' THEN '装卸货打卡异常'
            ELSE '其他'
        END AS abnormal_sub_type,
        COUNT(waybill_id) AS abnormal_cnt
    FROM ads_vlsp_mt_match_waybill_abnormal_detail_info_df
    GROUP BY 1, 2, 3
),
result AS (
    /* 第一部分：每天整体异常占比（不分运单类型） */
    SELECT
        '每日汇总' AS stat_dim,
        t_daily.unload_dt AS dt,
        '全部' AS waybill_type,
        '全部' AS abnormal_sub_type,
        COALESCE(a_daily.abnormal_cnt, 0) AS abnormal_cnt,
        t_daily.total_cnt AS total_cnt,
        COALESCE(a_daily.abnormal_cnt, 0) / NULLIF(t_daily.total_cnt, 0) AS abnormal_rate
    FROM (
        SELECT unload_dt, SUM(total_cnt) AS total_cnt
        FROM total_by_day_type
        GROUP BY unload_dt
    ) t_daily
    LEFT JOIN (
        SELECT unload_dt, SUM(abnormal_cnt) AS abnormal_cnt
        FROM abnormal_by_day_type_sub
        WHERE abnormal_sub_type != '其他'
        GROUP BY unload_dt
    ) a_daily
        ON t_daily.unload_dt = a_daily.unload_dt

    UNION ALL

    /* 第二部分：运单类型 + 异常子类型明细占比 */
    SELECT
        '类型明细' AS stat_dim,
        a.unload_dt AS dt,
        a.waybill_type,
        a.abnormal_sub_type,
        a.abnormal_cnt,
        t.total_cnt,
        a.abnormal_cnt / NULLIF(t.total_cnt, 0) AS abnormal_rate
    FROM abnormal_by_day_type_sub a
    LEFT JOIN total_by_day_type t
        ON a.unload_dt = t.unload_dt
       AND a.waybill_type = t.waybill_type
    WHERE a.abnormal_sub_type != '其他'
)
SELECT
    stat_dim AS 统计维度,
    dt AS 日期,
    waybill_type AS 运单类型,
    abnormal_sub_type AS 异常子类型,
    abnormal_cnt AS 异常运单数,
    total_cnt AS 总运单数,
    abnormal_rate AS 异常占比
FROM result
ORDER BY
    dt DESC,
    CASE stat_dim WHEN '每日汇总' THEN 1 WHEN '类型明细' THEN 2 END,
    waybill_type,
    abnormal_sub_type;
