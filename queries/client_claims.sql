-- aggregate all_claims data into policy level information

WITH
    individual_claims AS (
        SELECT
            *
        FROM
            `prj-t-analytics-uk-7e3a.uk_data_science.ajh_all_claims`
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

    ,client_data AS (
        SELECT
            ic.policy_number,
            EXTRACT(YEAR FROM ic.inception_date) AS contract_year,
            ic.client_name,
            ic.broker_name,
            vy.vehicle_years,
            SUM(total_indemnity_paid) AS indemnity_spend,
            SUM(total_future_indemnity) AS indemnity_reserve,
            AVG(EXTRACT(DAY FROM (ic.reported_date - ic.damage_date))) AS fnol,
            COUNT(*) AS claim_count
        FROM
            individual_claims AS ic
        LEFT JOIN
            vehicle_years AS vy
                ON ic.policy_number = vy.policy_no
        GROUP BY
            policy_number,
            contract_year,
            client_name,
            broker_name,
            vehicle_years
    )

SELECT * FROM client_data ORDER BY policy_number