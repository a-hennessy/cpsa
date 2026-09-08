WITH
    motor_claims AS (
        SELECT
            fsc.claim_id,
            fsc.sub_claim_id,

            dc.contract_origin_and_generation AS policy_number,
            UPPER(dpp.party_name) AS client_name,
            UPPER(dpb.party_name) AS broker_name,
            CASE
                WHEN UPPER(dcl.claim_source) = 'DWH' THEN COALESCE(CAST(dcl.claim_external_id AS STRING), CAST(dcl.claim_id AS STRING))
                ELSE CAST(dcl.claim_id AS STRING)
            END AS claim_number,
            CAST(fsc.claim_damage_date AS DATE) AS damage_date,
            CAST(fsc.claim_reported_date AS DATE) AS reported_date,
            UPPER(fsc.claim_status_local) AS claim_status

        FROM `prj-p-big-query-f190.datamart_analytics.fact_sub_claim` AS fsc
        LEFT JOIN `prj-p-big-query-f190.datamart_analytics.dim_claim` AS dcl
            ON fsc.dim_claim_key = dcl.dim_claim_key
        LEFT JOIN `prj-p-big-query-f190.datamart_analytics.dim_contract` AS dc
            ON fsc.dim_contract_key = dc.dim_contract_key
        LEFT JOIN `prj-p-big-query-f190.datamart_analytics.dim_party` AS dpp
            ON fsc.dim_party_policy_holder_key = dpp.dim_party_key
        LEFT JOIN `prj-p-big-query-f190.datamart_analytics.dim_party` AS dpb
            ON fsc.dim_party_broker_key = dpb.dim_party_key
        WHERE fsc.claim_country_code = 'GB'
            AND UPPER(fsc.claim_line_of_business_local) = 'MOTOR FLEET INSURANCE'
            AND (dcl.claim_deleted != 'Yes' OR dcl.claim_deleted IS NULL)
            AND dc.contract_origin_and_generation IS NOT NULL
    )
    
    ,indemnity_transactions AS (
        SELECT
            fsct.claim_id,
            fsct.sub_claim_id,
            SUM(COALESCE(fsct.delta_net_paid, 0)) AS indemnity_paid,
            SUM(COALESCE(fsct.delta_remaining_reserves, 0)) AS indemnity_outstanding,
            SUM(COALESCE(fsct.delta_incurred, 0)) AS indemnity_incurred
        FROM `prj-p-big-query-f190.datamart_analytics.fact_sub_claim_transaction` AS fsct
        INNER JOIN `prj-p-big-query-f190.datamart_analytics.dim_claim_transaction_classification` AS dtc
            ON fsct.dim_claim_transaction_classification_key = dtc.dim_claim_transaction_classification_key
        WHERE dtc.claim_transaction_classification_id IN (1, 2, 3, 4, 5, 85, 6, 92, 93)
        GROUP BY fsct.claim_id, fsct.sub_claim_id
    )

    ,claims_agg_indemnity AS (
        SELECT
            mc.policy_number,
            mc.client_name,
            mc.broker_name,
            mc.claim_number,
            mc.damage_date,
            mc.reported_date,
            mc.claim_status,
            ROUND(SUM(COALESCE(it.indemnity_paid, 0)), 2) AS total_indemnity_paid,
            ROUND(SUM(COALESCE(it.indemnity_outstanding, 0)), 2) AS total_future_indemnity,
            ROUND(SUM(COALESCE(it.indemnity_incurred, 0)), 2) AS total_indemnity_cost,
            COUNT(DISTINCT mc.sub_claim_id) AS sub_claim_count
        FROM motor_claims AS mc
        LEFT JOIN indemnity_transactions AS it
            ON mc.claim_id = it.claim_id
            AND mc.sub_claim_id = it.sub_claim_id
        GROUP BY
            mc.policy_number,
            mc.client_name,
            mc.broker_name,
            mc.claim_number,
            mc.damage_date,
            mc.reported_date,
            mc.claim_status
        ORDER BY
            mc.client_name,
            mc.policy_number,
            mc.damage_date DESC
    )
SELECT
    *
FROM
    claims_agg_indemnity
