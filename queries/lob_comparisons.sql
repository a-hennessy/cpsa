-- calculate total claims paid, earned prenium and claim/premium ratio per lob

WITH
    claim_by_lob AS (
        SELECT
            CASE claim_line_of_business_eng
                WHEN 'Motor Fleet insurance' THEN 'Motor'
                WHEN 'Combined Liability insurance' THEN 'Liability'
                WHEN 'Property Damage insurance' THEN 'Property'
                ELSE null
            END AS lob,
            SUM(claim_current_net_paid) AS total_paid
        FROM
            `prj-p-big-query-f190.datamart_analytics.dim_claim`
        WHERE contract_segment = 'Commercial'
        GROUP BY
            lob
    )

    ,gwp_by_lob AS (
        SELECT
            CASE contract_type
                WHEN 'Motor Fleet' THEN 'Motor'
                WHEN 'Combined Liability' THEN 'Liability'
                WHEN 'Property Damage' THEN 'Property'
                ELSE null
            END AS lob,
            SUM(contract_gross_period_premium) AS gep
        FROM
            `prj-p-big-query-f190.datamart_analytics.dim_contract`
        WHERE contract_segment = 'Commercial'
        GROUP BY
            lob
    )

SELECT
    clm.lob,
    clm.total_paid AS claims_paid,
    gwp.gep AS earned_premium,
    clm.total_paid/gwp.gep AS claims_per_premium
FROM
    claim_by_lob AS clm
LEFT JOIN
    gwp_by_lob AS gwp
    ON clm.lob = gwp.lob
ORDER BY lob