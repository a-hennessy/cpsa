WITH
    subClaims AS (SELECT DISTINCT dc.contract_origin_and_generation,
                                dc.contract_valid_from,
                                dc.contract_valid_to,
                                UPPER(dc.contract_segment) AS contract_segment,
                                UPPER(dc.contract_type) AS contract_type,
                                UPPER(dc.contract_group) AS contract_group,
                                CASE WHEN UPPER(dpp.party_name) IN ('NA', 'N/A') THEN 'UNKNOWN'
                                    WHEN dpp.party_name IS NULL THEN 'UNKNOWN'
                                    ELSE UPPER(dpp.party_name)
                                END AS client,
                                IFNULL(UPPER(dpb.party_name), 'UNKNOWN') AS broker,
                                CASE WHEN UPPER(dcl.claim_source) = 'DWH' THEN COALESCE(CAST(dcl.claim_external_id AS STRING), CAST(dcl.claim_id AS STRING)) 
                                    ELSE CAST(dcl.claim_id AS STRING) 
                                END AS claims_no,
                                fsc.claim_id,
                                fsc.sub_claim_id,
                                UPPER(dcl.claim_source) AS claim_source,
                                UPPER(fsc.claim_status_local) AS sub_claim_status,
                                UPPER(fsc.claim_line_of_business_local) AS sub_claim_lob,
                                IFNULL(UPPER(fsc.sub_claim_branch_code_eng), 'UNKNOWN') AS sub_claim_branch_code,
                                CAST(fsc.claim_damage_date AS DATE) AS claim_damage_date,
                                CAST(fsc.claim_created_date AS DATE) AS claim_created_date,
                                CAST(fsc.claim_reported_date AS DATE) AS claim_reported_date,
                                CAST(fsc.claim_completed_date AS DATE) AS claim_completed_date,
                                IF(dsc.claim_litigated = 'true', 'YES', 'NO') AS sub_claim_litigated,
                                IFNULL(COALESCE(UPPER(dsc.sub_claim_state), UPPER(dcl.claim_state_type_description)), 'UNKNOWN') AS claim_state,
                                IFNULL(UPPER(dsc.claim_recovery_considered), 'UNKNOWN') AS sub_claim_recovery_considered,
                                IFNULL(UPPER(dct.claim_type_eng), 'UNKNOWN') AS sub_claim_type,
                                IFNULL(UPPER(dcc.claim_cause_eng), 'UNKNOWN') AS sub_claim_cause,
                                IFNULL(CAST(dcl.claim_contract_below_deductible_handling AS STRING), 'UNKNOWN') AS below_deductible_handling,
                                IFNULL(UPPER(dcl.claim_reporting_party), 'UNKNOWN') AS reporting_party,
                                IFNULL(UPPER(dsc.claim_auto_responsibility_eng), 'UNKNOWN') AS sub_claim_responsibility,
                                CASE WHEN UPPER(dcl.claim_division1) = 'N/A' THEN 'UNKNOWN'
                                    WHEN dcl.claim_division1 IS NULL THEN 'UNKNOWN'
                                    ELSE UPPER(dcl.claim_division1)
                                END AS claim_division1,
                                CASE WHEN UPPER(dcl.claim_division2) = 'N/A' THEN 'UNKNOWN'
                                    WHEN dcl.claim_division2 IS NULL THEN 'UNKNOWN'
                                    ELSE UPPER(dcl.claim_division2)
                                END AS claim_division2,
                                CASE WHEN UPPER(dcl.claim_division3) = 'N/A' THEN 'UNKNOWN'
                                    WHEN dcl.claim_division3 IS NULL THEN 'UNKNOWN'
                                    ELSE UPPER(dcl.claim_division3)
                                END AS claim_division3,
                                IF(dsc.claims_reg_num IS NULL, 'UNKNOWN', dsc.claims_reg_num) AS vehicle_registration,
                                fsc.sub_claim_sum_i_x_payments,
                                fsc.sub_claim_sum_i_x_payments_pending,
                                fsc.sub_claim_excess_utilised,
                                fsc.sub_claim_current_net_paid,
                                fsc.sub_claim_sum_remaining_x_reserve,
                                fsc.sub_claim_current_remaining_reserves,
                                fsc.sub_claim_current_incurred,
                                fsc.sub_claim_current_remaining_recourse
                FROM `prj-p-big-query-f190.datamart_analytics.fact_sub_claim` AS fsc
                LEFT JOIN `prj-p-big-query-f190.datamart_analytics.dim_claim` AS dcl ON fsc.dim_claim_key = dcl.dim_claim_key
                LEFT JOIN `prj-p-big-query-f190.datamart_analytics.dim_contract` AS dc ON fsc.dim_contract_key = dc.dim_contract_key
                LEFT JOIN `prj-p-big-query-f190.datamart_analytics.dim_party` AS dpp ON fsc.dim_party_policy_holder_key = dpp.dim_party_key
                LEFT JOIN `prj-p-big-query-f190.datamart_analytics.dim_party` AS dpb ON fsc.dim_party_broker_key = dpb.dim_party_key
                LEFT JOIN `prj-p-big-query-f190.datamart_analytics.dim_sub_claim` AS dsc ON fsc.claim_id = dsc.claim_id AND fsc.sub_claim_id = dsc.sub_claim_id
                LEFT JOIN `prj-p-big-query-f190.datamart_analytics.dim_claim_type` AS dct ON fsc.dim_claim_type_key = dct.dim_claim_type_key
                LEFT JOIN `prj-p-big-query-f190.datamart_analytics.dim_claim_cause` AS dcc ON fsc.dim_claim_cause_key = dcc.dim_claim_cause_key
                WHERE fsc.claim_country_code = 'GB'
                        AND (dcl.claim_deleted != 'Yes' OR dcl.claim_deleted IS NULL)
                        AND UPPER(fsc.claim_line_of_business_local) = 'MOTOR FLEET INSURANCE'),
                
    internalTransactions AS (SELECT sc.claim_id,
                                    sc.sub_claim_id,
                                    fsct.claim_transaction_id,
                                    IFNULL(UPPER(dtc.claim_transaction_classification_reporting_code), 'UNKNOWN') AS claim_transaction_code,
                                    fsct.claim_transaction_type_id,
                                    SUM(COALESCE(fsct.delta_remaining_reserves, 0)) AS delta_remaining_reserves,
                                    SUM(COALESCE(fsct.delta_net_paid, 0)) AS delta_net_paid,
                                    SUM(COALESCE(fsct.claim_transaction_amount, 0)) AS claim_transaction_amount,
                                    SUM(COALESCE(fsct.delta_incurred, 0)) AS delta_incurred,
                                    SUM(COALESCE(fsct.excess_utilised, 0)) AS excess_utilised,
                                    SUM(COALESCE(fsct.excess_recovered, 0)) AS excess_recovered,
                                    SUM(COALESCE(fsct.delta_remaining_recourse, 0)) AS delta_remaining_recourse
                            FROM subClaims AS sc
                             `prj-p-big-query-f190.datamart_analytics.faJOINct_sub_claim_transaction` AS fsct ON sc.claim_id = fsct.claim_id AND sc.sub_claim_id = fsct.sub_claim_id
                            LEFT JOIN `prj-p-big-query-f190.datamart_analytics.dim_claim_transaction_classification` AS dtc ON fsct.dim_claim_transaction_classification_key = dtc.dim_claim_transaction_classification_key
                            WHERE 'MI' = 'MI'
                                OR ('MI' = 'DamageDate' AND CAST(fsct.claim_damage_date AS DATE) <= PARSE_DATE("%d/%m/%Y", "08/09/26"))
                                OR ('MI' = 'CreatedDate' AND CAST(fsct.claim_created_date AS DATE) <= PARSE_DATE("%d/%m/%Y", "08/09/26"))
                                OR ('MI' = 'ReportedDate' AND CAST(fsct.claim_reported_date AS DATE) <= PARSE_DATE("%d/%m/%Y", "08/09/26"))
                                OR ('MI' = 'CompletedDate' AND CAST(fsct.claim_completed_date AS DATE) <= PARSE_DATE("%d/%m/%Y", "08/09/26"))
                                OR ('MI' = 'TransactionDate' AND CAST(fsct.claim_transaction_created_date AS DATE) <= PARSE_DATE("%d/%m/%Y", "08/09/26"))
                            GROUP BY sc.claim_id,
                                    sc.sub_claim_id,
                                    fsct.claim_transaction_id,
                                    IFNULL(UPPER(dtc.claim_transaction_classification_reporting_code), 'UNKNOWN'),
                                    fsct.claim_transaction_type_id),
                
    externalClaims AS (SELECT sc.claim_id,
                            sc.sub_claim_id,
                            sc.sub_claim_type AS claim_transaction_code,
                            COALESCE(sc.sub_claim_current_remaining_reserves, 0) AS delta_remaining_reserves,
                            COALESCE(sc.sub_claim_current_net_paid, 0) AS delta_net_paid,
                            COALESCE(sc.sub_claim_current_incurred, 0) AS delta_incurred,
                            COALESCE(sc.sub_claim_excess_utilised, 0) AS excess_utilised,
                            COALESCE(sc.sub_claim_current_remaining_recourse, 0) AS delta_remaining_recourse
                    FROM subClaims AS sc
                    WHERE NOT EXISTS (SELECT 1
                                        FROM internalTransactions AS it
                                        WHERE sc.claim_id = it.claim_id)
                            AND ('MI' = 'MI'
                                OR ('MI' = 'DamageDate' AND CAST(sc.claim_damage_date AS DATE) <= PARSE_DATE("%d/%m/%Y", "08/09/26"))
                                OR ('MI' = 'CreatedDate' AND CAST(sc.claim_created_date AS DATE) <= PARSE_DATE("%d/%m/%Y", "08/09/26"))
                                OR ('MI' = 'ReportedDate' AND CAST(sc.claim_reported_date AS DATE) <= PARSE_DATE("%d/%m/%Y", "08/09/26"))
                                OR ('MI' = 'CompletedDate' AND CAST(sc.claim_completed_date AS DATE) <= PARSE_DATE("%d/%m/%Y", "08/09/26"))
                                OR ('MI' = 'TransactionDate' AND CAST(sc.claim_reported_date AS DATE) <= PARSE_DATE("%d/%m/%Y", "08/09/26")))),
                
    claimsAggregated AS (SELECT claim_id,
                                SUM(CASE WHEN claim_transaction_code = 'TPPD' THEN delta_remaining_reserves ELSE 0 END) AS tppd_outstanding,
                                SUM(CASE WHEN claim_transaction_code = 'TPPI' THEN delta_remaining_reserves ELSE 0 END) AS tppi_outstanding,
                                SUM(delta_remaining_recourse) AS recovery,
                                SUM(CASE WHEN claim_transaction_code IN ('AD', 'WS') THEN delta_net_paid ELSE 0 END) AS ad_paid,
                                SUM(CASE WHEN claim_transaction_code = 'FT' THEN delta_net_paid ELSE 0 END) AS ft_paid,
                                SUM(CASE WHEN claim_transaction_code = 'TPPD' THEN delta_net_paid ELSE 0 END) AS tppd_paid,
                                SUM(CASE WHEN claim_transaction_code = 'TPPI' THEN delta_net_paid ELSE 0 END) AS tppi_paid,
                                SUM(delta_net_paid) AS total_paid,
                                SUM(IF(claim_transaction_code IN ('AD', 'WS'), delta_remaining_reserves, 0) - IF(claim_transaction_type_id = 343, claim_transaction_amount, 0)) AS ad_outstanding,
                                SUM(CASE WHEN claim_transaction_code = 'FT' THEN delta_remaining_reserves ELSE 0 END) AS ft_outstanding,
                                SUM(delta_remaining_reserves - IF(claim_transaction_type_id = 343, claim_transaction_amount, 0)) AS total_outstanding_conventional,
                                SUM(delta_incurred) AS total_cost,
                                SUM(CASE WHEN claim_transaction_code IN ('AD', 'WS', 'FT') THEN delta_net_paid ELSE 0 END) AS insurer_ad_ft_paid,
                                SUM(CASE WHEN claim_transaction_code = 'TPPD' THEN delta_net_paid ELSE 0 END) AS insurer_tppd_paid,
                                SUM(CASE WHEN claim_transaction_code = 'TPPI' THEN delta_net_paid ELSE 0 END) AS insurer_tppi_paid,
                                SUM(delta_net_paid) AS total_insurer_paid,
                                SUM(CASE WHEN claim_transaction_code IN ('AD', 'FT') THEN excess_utilised + excess_recovered else 0 end)  as client_ad_paid,
                                SUM(CASE WHEN claim_transaction_code = 'TPPD' THEN excess_utilised + excess_recovered else 0 end)  as client_tppd_paid,
                                SUM(CASE WHEN claim_transaction_code = 'TPPI' THEN excess_utilised + excess_recovered else 0 end)  as client_tppi_paid,
                                SUM(CASE WHEN claim_transaction_code IN ('AD', 'FT', 'TPPD', 'TPPI') THEN excess_utilised + excess_recovered ELSE 0 END) AS total_client_paid,
                                SUM(CASE WHEN claim_transaction_code IN ('AD', 'WS', 'FT') THEN delta_remaining_reserves ELSE 0 END) AS ad_ft_outstanding,
                                SUM(delta_remaining_reserves) AS total_outstanding_non_conventional,
                                SUM(IF(claim_transaction_type_id = 343, claim_transaction_amount, 0)) AS excess_recovery_reserve
                        FROM (SELECT it.claim_id,
                                    it.sub_claim_id,
                                    it.claim_transaction_id,
                                    it.claim_transaction_code,
                                    it.claim_transaction_type_id,
                                    it.delta_remaining_reserves,
                                    it.delta_net_paid,
                                    it.claim_transaction_amount,
                                    it.delta_incurred,
                                    it.excess_utilised,
                                    it.excess_recovered,
                                    it.delta_remaining_recourse
                            FROM internalTransactions AS it
                            UNION ALL
                            SELECT ec.claim_id,
                                    ec.sub_claim_id,
                                    NULL AS claim_transaction_id,
                                    ec.claim_transaction_code,
                                    NULL AS claim_transaction_type_id,
                                    ec.delta_remaining_reserves,
                                    ec.delta_net_paid,
                                    0 AS claim_transaction_amount,
                                    ec.delta_incurred,
                                    ec.excess_utilised,
                                    0 AS excess_recovered,
                                    ec.delta_remaining_recourse
                            FROM externalClaims AS ec)
                        GROUP BY claim_id),
            
    claimsSummary AS (SELECT DISTINCT sc.contract_origin_and_generation,
                                    sc.contract_valid_from,
                                    sc.contract_valid_to,
                                    sc.contract_segment,
                                    sc.contract_type,
                                    sc.contract_group,
                                    sc.client,
                                    sc.broker,
                                    sc.claims_no,
                                    sc.claim_id,
                                    sc.claim_source,
                                    sc.sub_claim_status,
                                    sc.sub_claim_lob,
                                    csa.sub_claim_branch_code,
                                    sc.claim_damage_date,
                                    sc.claim_created_date,
                                    sc.claim_reported_date,
                                    csa.claim_completed_date,
                                    csa.sub_claim_litigated,
                                    csa.claim_state,
                                    sc.sub_claim_recovery_considered,
                                    csa.sub_claim_type,
                                    csa.sub_claim_cause,
                                    sc.below_deductible_handling,
                                    sc.reporting_party,
                                    csa.sub_claim_responsibility,
                                    sc.claim_division1,
                                    sc.claim_division2,
                                    sc.claim_division3,
                                    sc.vehicle_registration
                    FROM subClaims AS sc
                    LEFT JOIN (SELECT claim_id,
                                        STRING_AGG(DISTINCT sub_claim_litigated, ' ; ' ORDER BY sub_claim_litigated) AS sub_claim_litigated,
                                        STRING_AGG(DISTINCT sub_claim_branch_code, ' ; ' ORDER BY sub_claim_branch_code) AS sub_claim_branch_code,
                                        STRING_AGG(DISTINCT claim_state, ' ; ' ORDER BY claim_state) AS claim_state,
                                        STRING_AGG(DISTINCT sub_claim_type, ' ; ' ORDER BY sub_claim_type) AS sub_claim_type,
                                        STRING_AGG(DISTINCT sub_claim_cause, ' ; ' ORDER BY sub_claim_cause) AS sub_claim_cause,
                                        STRING_AGG(DISTINCT sub_claim_responsibility, ' ; ' ORDER BY sub_claim_responsibility) AS sub_claim_responsibility,
                                        MAX(claim_completed_date) AS claim_completed_date
                                FROM subClaims
                                GROUP BY claim_id) AS csa ON sc.claim_id = csa.claim_id),
                
    output AS (SELECT cs.*,
                    ROUND(ca.tppd_outstanding, 2) AS tppd_outstanding,
                    ROUND(ca.tppi_outstanding, 2) AS tppi_outstanding,
                    ROUND(ca.recovery, 2) AS recovery,
                    ROUND(ca.ad_paid, 2) AS ad_paid,
                    ROUND(ca.ft_paid, 2) AS ft_paid,
                    ROUND(ca.tppd_paid, 2) AS tppd_paid,
                    ROUND(ca.tppi_paid, 2) AS tppi_paid,
                    ROUND(ca.total_paid, 2) AS total_paid,
                    ROUND(ca.ad_outstanding, 2) AS ad_outstanding,
                    ROUND(ca.ft_outstanding, 2) AS ft_outstanding,
                    ROUND(ca.total_outstanding_conventional, 2) AS total_outstanding_conventional,
                    ROUND(ca.total_cost, 2) AS total_cost,
                    ROUND(ca.insurer_ad_ft_paid, 2) AS insurer_ad_ft_paid,
                    ROUND(ca.insurer_tppd_paid, 2) AS insurer_tppd_paid,
                    ROUND(ca.insurer_tppi_paid, 2) AS insurer_tppi_paid,
                    ROUND(ca.total_insurer_paid, 2) AS total_insurer_paid,
                    ROUND(ca.client_ad_paid, 2) AS client_ad_paid,
                    ROUND(ca.client_tppd_paid, 2) AS client_tppd_paid,
                    ROUND(ca.client_tppi_paid, 2) AS client_tppi_paid,
                    ROUND(ca.total_client_paid, 2) AS total_client_paid,
                    ROUND(ca.ad_ft_outstanding, 2) AS ad_ft_outstanding,
                    ROUND(ca.total_outstanding_non_conventional, 2) AS total_outstanding_non_conventional,
                    ROUND(ca.excess_recovery_reserve, 2) AS excess_recovery_reserve
            FROM claimsSummary AS cs
            JOIN claimsAggregated AS ca ON cs.claim_id = ca.claim_id)

SELECT * FROM output