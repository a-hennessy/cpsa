SELECT
  EXTRACT(YEAR FROM dc.contract_valid_from) AS contract_year,
  count(*)
FROM `prj-p-big-query-f190.datamart_analytics.fact_sub_claim` AS fsc
        LEFT JOIN `prj-p-big-query-f190.datamart_analytics.dim_contract` AS dc
            ON fsc.dim_contract_key = dc.dim_contract_key
GROUP BY 1
ORDER BY 1 ASC