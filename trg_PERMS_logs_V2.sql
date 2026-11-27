USE [AIM_DB]
GO
/****** Object:  Trigger [dbo].[trg_PERMS_logs_V2]    Script Date: 10/23/2026 9:37:29 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER TRIGGER [dbo].[trg_PERMS_logs_V2]
ON [dbo].[PERMS_logs_V2]
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
    i AS
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
            'PERMS-0039',
            'PERMS-0037',
            'PERMS-0030',
            'PERMS-0031',
            'PERMS-0032',
            'PERMS-0040',
            'PERMS-0041',
            'PERMS-TEST',
            'PERMS-TR',
            'PERMS-MCR',
            'PERMS-0048'
        )
    ),
    last_vals AS
    (
        SELECT
            s.device_name,
            MAX(s.val) AS last_val
        FROM [AIM_DB].[dbo].[PERMS_logs_SMS] AS s WITH (UPDLOCK, HOLDLOCK)
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

                   WHEN i.temp_num IS NOT NULL
                    AND i.min_temp IS NULL
                    AND
                    (
                        (i.temp_num NOT BETWEEN -38.00 AND -17.00)
                        AND i.device_name IN
                        (
                            'PERMS-0034',
                            'PERMS-0033',
                            'PERMS-0036',
                            'PERMS-0037',
                            'PERMS-0030',
                            'PERMS-0031',
                            'PERMS-0032',
                            'PERMS-TEST',
                            'PERMS-TR',
                            'PERMS-MCR',
                            'PERMS-0048'
                        )
                    ) THEN lv.last_val + 1

                   WHEN i.temp_num IS NOT NULL
                    AND i.min_temp IS NULL
                    AND
                    (
                        (i.temp_num NOT BETWEEN -68.00 AND -42.00)
                        AND i.device_name IN
                        (
                            'PERMS-0039',
                            'PERMS-0040',
                            'PERMS-0041'
                        )
                    ) THEN lv.last_val + 1

                   ELSE 0
               END
    FROM [AIM_DB].[dbo].[PERMS_logs_SMS] AS s
    JOIN i
        ON i.device_name = s.device_name
    JOIN last_vals AS lv
        ON lv.device_name = s.device_name;
END;
GO