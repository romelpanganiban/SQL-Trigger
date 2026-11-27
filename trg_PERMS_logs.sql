USE [AIM_DB]
GO
/****** Object:  Trigger [dbo].[trg_PERMS_logs]    Script Date: 10/23/2026 9:24:57 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER TRIGGER [dbo].[trg_PERMS_logs]
ON [dbo].[PERMS_logs]
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH device_limits AS
    (
        SELECT device_name, min_temp, max_temp, CAST(1 AS BIT) AS alerts_enabled
        FROM dbo.PERMS_MCR_Device
        UNION ALL
        SELECT device_name, min_temp, max_temp, alerts_enabled
        FROM dbo.PERMS_TR_Device
    ),
    inserted_values AS
    (
        SELECT
            reading.device_name,
            TRY_CONVERT(DECIMAL(10, 2), temperature) AS temp_num,
            temperature,
            humidity,
            date_time,
            limits.min_temp,
            limits.max_temp,
            limits.alerts_enabled
        FROM inserted AS reading
        LEFT JOIN device_limits AS limits
            ON limits.device_name = reading.device_name
        WHERE limits.device_name IS NOT NULL
           OR reading.device_name IN
        (
            'PERMS-0034',
            'PERMS-0033',
            'PERMS-0036',
            'PERMS-0037',
            'PERMS-0030',
            'PERMS-0031',
            'PERMS-0032',
            'PERMS-0038',
            'PERMS-0039',
            'PERMS-0040',
            'PERMS-TEST'
        )
    ),
    last_values AS
    (
        SELECT
            s.device_name,
            ISNULL(MAX(s.val), 0) AS last_val
        FROM dbo.PERMS_logs_SMS AS s WITH (UPDLOCK, HOLDLOCK)
        GROUP BY s.device_name
    )
    UPDATE s
       SET s.temperature = i.temperature,
           s.humidity    = i.humidity,
           s.date_time   = i.date_time,
           s.val =
               CASE
                   WHEN i.alerts_enabled = 0 THEN 0

                   WHEN i.temp_num IS NOT NULL
                    AND i.min_temp IS NOT NULL
                    AND i.temp_num NOT BETWEEN i.min_temp AND i.max_temp
                       THEN ISNULL(lv.last_val, 0) + 1

                   --------------------------------------------------
                   -- Standard freezer range: -38 to -17
                   --------------------------------------------------
                   WHEN i.temp_num IS NOT NULL
                    AND i.min_temp IS NULL
                    AND i.device_name IN
                    (
                        'PERMS-0034',
                        'PERMS-0033',
                        'PERMS-0036',
                        'PERMS-0037',
                        'PERMS-0030',
                        'PERMS-0031',
                        'PERMS-0032',
                        'PERMS-TEST'
                    )
                    AND i.temp_num NOT BETWEEN -38.00 AND -17.00
                       THEN ISNULL(lv.last_val, 0) + 1

                   --------------------------------------------------
                   -- Ultra-low freezer range: -68 to -42
                   --------------------------------------------------
                   WHEN i.temp_num IS NOT NULL
                    AND i.min_temp IS NULL
                    AND i.device_name IN
                    (
                        'PERMS-0038',
                        'PERMS-0039',
                        'PERMS-0040'
                    )
                    AND i.temp_num NOT BETWEEN -68.00 AND -42.00
                       THEN ISNULL(lv.last_val, 0) + 1

                   --------------------------------------------------
                   -- Temperature is normal or invalid
                   --------------------------------------------------
                   ELSE 0
               END
    FROM dbo.PERMS_logs_SMS AS s
    INNER JOIN inserted_values AS i
        ON i.device_name = s.device_name
    INNER JOIN last_values AS lv
        ON lv.device_name = s.device_name;
END;
GO