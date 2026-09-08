WITH
    internal_clients AS (
        SELECT
            dp_c.party_name AS client,
            dp_b.party_name AS broker,
            dc.contract_origin_and_generation AS policy_no,
            dc.contract_segment AS segment,
            dc.contract_type,
            dp_c.party_nace AS nace,
            CAST(dc.contract_gross_period_premium AS NUMERIC) AS gwp,
            EXTRACT(YEAR FROM dc.contract_valid_from) AS contract_year,
            dc.contract_valid_from,
            dc.contract_valid_to
        FROM
            `prj-p-big-query-f190.datamart_analytics.dim_contract` AS dc
        LEFT JOIN
            `prj-p-big-query-f190.datamart_analytics.dim_party` AS dp_c
            ON dc.contract_policy_holder_id = dp_c.party_id
        LEFT JOIN
            `prj-p-big-query-f190.datamart_analytics.dim_party` AS dp_b
            ON dc.contract_broker_house_id = dp_b.party_id
        WHERE
            dc.contract_country_code = 'GB'
            AND dc.contract_type = 'Motor Fleet'
            AND dc.contract_valid_from < CURRENT_DATE()
        QUALIFY ROW_NUMBER() OVER (PARTITION BY dc.contract_origin_and_generation, EXTRACT(YEAR FROM dc.contract_valid_from)
                                    ORDER BY dc.contract_version DESC) = 1
    )

    ,internal_claims_base AS (
        SELECT
            ROW_NUMBER() OVER () AS claim_row_id,
            sc.contract_concern_customer_name AS client,
            sc.policy_no_and_renewal_id AS policy_no,
            sc.damage_date AS claim_date,
            sc.reported_date AS notification_date,
            sc.net_paid AS paid,
            sc.claim_cause
        FROM
            `prj-p-analytics-uk-9917.uk_claims_team.subclaims` AS sc
        WHERE
            sc.country = 'United Kingdom'
            AND sc.settlement_company_name_eng = 'Protector Forsikring ASA'
            AND sc.product_eng = 'Motor'
            AND sc.contract_concern_customer_name IS NOT NULL
    )

    ,internal_claims AS (
        SELECT
            icb.client,
            icb.policy_no,
            icb.claim_date,
            icb.notification_date,
            icb.paid,
            COALESCE(ct.claim_category, 'Unknown & Other') AS claim_type
        FROM internal_claims_base icb
        LEFT JOIN `prj-t-big-query-69e0.uk_analytics.claim_types_motor` ct
            ON (ct.match_type = 'EXACT' AND UPPER(icb.claim_cause) = ct.pattern)
            OR (ct.match_type = 'LIKE' AND UPPER(icb.claim_cause) LIKE ct.pattern)
            OR (ct.match_type = 'REGEXP' AND REGEXP_CONTAINS(UPPER(icb.claim_cause), ct.pattern))
        QUALIFY ROW_NUMBER() OVER (PARTITION BY icb.claim_row_id ORDER BY ct.priority) = 1
    )

    ,latest_contracts AS (
        SELECT DISTINCT
            contract_origin_and_generation AS policy_no,
            EXTRACT(YEAR FROM contract_valid_from) AS contract_year,
            contract_valid_from,
            dim_contract_key
        FROM `prj-p-big-query-f190.datamart_analytics.dim_contract`
        WHERE contract_country_code = 'GB'
            AND contract_type = 'Motor Fleet'
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY contract_origin_and_generation, EXTRACT(YEAR FROM contract_valid_from)
            ORDER BY contract_version DESC
        ) = 1
    )

    ,vehicle_exposure AS (
        SELECT DISTINCT
            lc.policy_no,
            lc.contract_year,
            dv.vehicle_registration_number AS reg_no,
            dv.vehicle_valid_from,
            dv.vehicle_valid_to,
            DATE_DIFF(dv.vehicle_valid_to, dv.vehicle_valid_from, DAY) + 1 AS days,
            DATE_DIFF(
                DATE_SUB(DATE_ADD(lc.contract_valid_from, INTERVAL 1 YEAR), INTERVAL 1 DAY),
                dv.vehicle_valid_from,
                DAY
            ) + 1 AS year_end_days,
            DATE_DIFF(
                DATE_SUB(DATE_ADD(lc.contract_valid_from, INTERVAL 1 YEAR), INTERVAL 1 DAY),
                lc.contract_valid_from,
                DAY
            ) + 1 AS year_days
        FROM latest_contracts lc
        INNER JOIN `prj-p-big-query-f190.datamart_analytics.fact_object_cover` AS foc
            ON lc.dim_contract_key = foc.dim_contract_key
        INNER JOIN `prj-p-big-query-f190.datamart_analytics.dim_vehicle` AS dv
            ON foc.dim_vehicle_key = dv.dim_vehicle_key
        INNER JOIN `prj-p-big-query-f190.datamart_analytics.dim_group_type` AS dgt
            ON foc.dim_group_type_key = dgt.dim_group_type_key
        WHERE dgt.group_type_name IN ('Agricultural Vehicles', 'Coaches - over 16 seats, up to 58 seats', 'Commercial Vehicles - over 15T, up to 29T', 'Commercial Vehicles - over 29T, up to 32T', 'Commercial Vehicles - over 3.5T, up to 7.5T', 'Commercial Vehicles - over 32T, up to 44T', 'Commercial Vehicles - over 44T', 'Commercial Vehicles - over 7.5T, up to 15T', 'Light Commercial Vehicles - up to 3.5T', 'Minibuses - up to 16 seats', 'Fire Appliances', 'Motorcycles', 'Private Cars', 'Trade Plates')
            AND dv.vehicle_registration_number IS NOT NULL
    )

    ,vehicle_years AS (
        SELECT
            policy_no,
            contract_year,
            SUM(
                CASE
                    WHEN vehicle_valid_from IS NULL THEN 0
                    WHEN days < year_end_days THEN days
                    ELSE year_end_days
                END
            ) / MAX(year_days) AS vehicle_years
        FROM vehicle_exposure
        GROUP BY policy_no, contract_year
    )

    ,claims_aggregated AS (
        SELECT
            ic.client,
            ic.policy_no,
            icl.claim_type,
            COUNT(*) AS cnt,
            SUM(icl.paid) AS paid_total,
            COUNTIF(icl.paid > 0) AS cnt_ex_nil,
            SUM(LEAST(icl.paid, 50000)) AS paid_capped
        FROM internal_clients ic
        LEFT JOIN internal_claims icl
            ON TRIM(UPPER(ic.client)) = TRIM(UPPER(icl.client))
            AND ic.policy_no = icl.policy_no
        WHERE icl.claim_type IS NOT NULL
        GROUP BY ic.client, ic.policy_no, icl.claim_type
    )

    ,pivoted AS (
        SELECT
            ic.client,
            ic.policy_no,
            MAX(IF(ca.claim_type = 'Collision - At Fault', ca.cnt, 0)) AS count_collision_at_fault,
            MAX(IF(ca.claim_type = 'Collision - At Fault', ca.paid_total, 0)) AS paid_collision_at_fault,
            MAX(IF(ca.claim_type = 'Collision - At Fault', ca.cnt_ex_nil, 0)) AS count_collision_at_fault_ex_nil,
            MAX(IF(ca.claim_type = 'Collision - At Fault', ca.paid_capped, 0)) AS paid_collision_at_fault_capped,

            MAX(IF(ca.claim_type = 'Collision - Not At Fault', ca.cnt, 0)) AS count_collision_not_at_fault,
            MAX(IF(ca.claim_type = 'Collision - Not At Fault', ca.paid_total, 0)) AS paid_collision_not_at_fault,
            MAX(IF(ca.claim_type = 'Collision - Not At Fault', ca.cnt_ex_nil, 0)) AS count_collision_not_at_fault_ex_nil,
            MAX(IF(ca.claim_type = 'Collision - Not At Fault', ca.paid_capped, 0)) AS paid_collision_not_at_fault_capped,

            MAX(IF(ca.claim_type = 'Multi-Vehicle Collision', ca.cnt, 0)) AS count_multi_vehicle_collision,
            MAX(IF(ca.claim_type = 'Multi-Vehicle Collision', ca.paid_total, 0)) AS paid_multi_vehicle_collision,
            MAX(IF(ca.claim_type = 'Multi-Vehicle Collision', ca.cnt_ex_nil, 0)) AS count_multi_vehicle_collision_ex_nil,
            MAX(IF(ca.claim_type = 'Multi-Vehicle Collision', ca.paid_capped, 0)) AS paid_multi_vehicle_collision_capped,

            MAX(IF(ca.claim_type = 'Junction & Roundabout', ca.cnt, 0)) AS count_junction_roundabout,
            MAX(IF(ca.claim_type = 'Junction & Roundabout', ca.paid_total, 0)) AS paid_junction_roundabout,
            MAX(IF(ca.claim_type = 'Junction & Roundabout', ca.cnt_ex_nil, 0)) AS count_junction_roundabout_ex_nil,
            MAX(IF(ca.claim_type = 'Junction & Roundabout', ca.paid_capped, 0)) AS paid_junction_roundabout_capped,

            MAX(IF(ca.claim_type = 'Windscreen & Glass', ca.cnt, 0)) AS count_windscreen_glass,
            MAX(IF(ca.claim_type = 'Windscreen & Glass', ca.paid_total, 0)) AS paid_windscreen_glass,
            MAX(IF(ca.claim_type = 'Windscreen & Glass', ca.cnt_ex_nil, 0)) AS count_windscreen_glass_ex_nil,
            MAX(IF(ca.claim_type = 'Windscreen & Glass', ca.paid_capped, 0)) AS paid_windscreen_glass_capped,

            MAX(IF(ca.claim_type = 'Theft & Security', ca.cnt, 0)) AS count_theft_security,
            MAX(IF(ca.claim_type = 'Theft & Security', ca.paid_total, 0)) AS paid_theft_security,
            MAX(IF(ca.claim_type = 'Theft & Security', ca.cnt_ex_nil, 0)) AS count_theft_security_ex_nil,
            MAX(IF(ca.claim_type = 'Theft & Security', ca.paid_capped, 0)) AS paid_theft_security_capped,

            MAX(IF(ca.claim_type = 'Malicious Damage & Vandalism', ca.cnt, 0)) AS count_malicious_damage,
            MAX(IF(ca.claim_type = 'Malicious Damage & Vandalism', ca.paid_total, 0)) AS paid_malicious_damage,
            MAX(IF(ca.claim_type = 'Malicious Damage & Vandalism', ca.cnt_ex_nil, 0)) AS count_malicious_damage_ex_nil,
            MAX(IF(ca.claim_type = 'Malicious Damage & Vandalism', ca.paid_capped, 0)) AS paid_malicious_damage_capped,

            MAX(IF(ca.claim_type = 'Weather & Natural Perils', ca.cnt, 0)) AS count_weather,
            MAX(IF(ca.claim_type = 'Weather & Natural Perils', ca.paid_total, 0)) AS paid_weather,
            MAX(IF(ca.claim_type = 'Weather & Natural Perils', ca.cnt_ex_nil, 0)) AS count_weather_ex_nil,
            MAX(IF(ca.claim_type = 'Weather & Natural Perils', ca.paid_capped, 0)) AS paid_weather_capped,

            MAX(IF(ca.claim_type = 'Fire & Explosion', ca.cnt, 0)) AS count_fire_explosion,
            MAX(IF(ca.claim_type = 'Fire & Explosion', ca.paid_total, 0)) AS paid_fire_explosion,
            MAX(IF(ca.claim_type = 'Fire & Explosion', ca.cnt_ex_nil, 0)) AS count_fire_explosion_ex_nil,
            MAX(IF(ca.claim_type = 'Fire & Explosion', ca.paid_capped, 0)) AS paid_fire_explosion_capped,

            MAX(IF(ca.claim_type = 'Accidental Damage', ca.cnt, 0)) AS count_accidental_damage,
            MAX(IF(ca.claim_type = 'Accidental Damage', ca.paid_total, 0)) AS paid_accidental_damage,
            MAX(IF(ca.claim_type = 'Accidental Damage', ca.cnt_ex_nil, 0)) AS count_accidental_damage_ex_nil,
            MAX(IF(ca.claim_type = 'Accidental Damage', ca.paid_capped, 0)) AS paid_accidental_damage_capped,

            MAX(IF(ca.claim_type = 'Mechanical & Maintenance', ca.cnt, 0)) AS count_mechanical_maintenance,
            MAX(IF(ca.claim_type = 'Mechanical & Maintenance', ca.paid_total, 0)) AS paid_mechanical_maintenance,
            MAX(IF(ca.claim_type = 'Mechanical & Maintenance', ca.cnt_ex_nil, 0)) AS count_mechanical_maintenance_ex_nil,
            MAX(IF(ca.claim_type = 'Mechanical & Maintenance', ca.paid_capped, 0)) AS paid_mechanical_maintenance_capped,

            MAX(IF(ca.claim_type = 'Pedestrian & Cyclist', ca.cnt, 0)) AS count_pedestrian_cyclist,
            MAX(IF(ca.claim_type = 'Pedestrian & Cyclist', ca.paid_total, 0)) AS paid_pedestrian_cyclist,
            MAX(IF(ca.claim_type = 'Pedestrian & Cyclist', ca.cnt_ex_nil, 0)) AS count_pedestrian_cyclist_ex_nil,
            MAX(IF(ca.claim_type = 'Pedestrian & Cyclist', ca.paid_capped, 0)) AS paid_pedestrian_cyclist_capped,

            MAX(IF(ca.claim_type = 'Animal Collision', ca.cnt, 0)) AS count_animal_collision,
            MAX(IF(ca.claim_type = 'Animal Collision', ca.paid_total, 0)) AS paid_animal_collision,
            MAX(IF(ca.claim_type = 'Animal Collision', ca.cnt_ex_nil, 0)) AS count_animal_collision_ex_nil,
            MAX(IF(ca.claim_type = 'Animal Collision', ca.paid_capped, 0)) AS paid_animal_collision_capped,

            MAX(IF(ca.claim_type = 'Non-Motor Claims', ca.cnt, 0)) AS count_non_motor,
            MAX(IF(ca.claim_type = 'Non-Motor Claims', ca.paid_total, 0)) AS paid_non_motor,
            MAX(IF(ca.claim_type = 'Non-Motor Claims', ca.cnt_ex_nil, 0)) AS count_non_motor_ex_nil,
            MAX(IF(ca.claim_type = 'Non-Motor Claims', ca.paid_capped, 0)) AS paid_non_motor_capped,

            MAX(IF(ca.claim_type = 'Unknown & Other', ca.cnt, 0)) AS count_unknown_other,
            MAX(IF(ca.claim_type = 'Unknown & Other', ca.paid_total, 0)) AS paid_unknown_other,
            MAX(IF(ca.claim_type = 'Unknown & Other', ca.cnt_ex_nil, 0)) AS count_unknown_other_ex_nil,
            MAX(IF(ca.claim_type = 'Unknown & Other', ca.paid_capped, 0)) AS paid_unknown_other_capped
        FROM internal_clients ic
        LEFT JOIN claims_aggregated ca
            ON ic.client = ca.client
            AND ic.policy_no = ca.policy_no
        GROUP BY ic.client, ic.policy_no
    )

SELECT
    ic.client,
    ic.policy_no,

    ic.contract_year,
    ic.contract_valid_from,
    ic.contract_valid_to,
    
    ic.segment,
    ic.nace,
    ic.broker,
    
    vy.vehicle_years,
    ic.gwp,
    CASE
        WHEN ic.contract_year = EXTRACT(YEAR FROM CURRENT_DATE()) AND CURRENT_DATE() < ic.contract_valid_to THEN
            SAFE_DIVIDE(
                DATE_DIFF(ic.contract_valid_to, ic.contract_valid_from, DAY) + 1,
                DATE_DIFF(CURRENT_DATE(), ic.contract_valid_from, DAY) + 1
            )
        ELSE 1.0
    END AS year_projection_factor,

    p.* EXCEPT(client, policy_no)

FROM internal_clients ic
LEFT JOIN vehicle_years vy
    ON ic.policy_no = vy.policy_no
    AND ic.contract_year = vy.contract_year
LEFT JOIN pivoted p
    ON TRIM(UPPER(ic.client)) = TRIM(UPPER(p.client))
    AND ic.policy_no = p.policy_no
ORDER BY client, policy_no