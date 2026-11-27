USE [AIM_DB]
GO
/****** Object:  Trigger [dbo].[trg_PERMS_SendSMS]    Script Date: 10/23/2026 9:30:33 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER TRIGGER [dbo].[trg_PERMS_SendSMS]
ON [dbo].[PERMS_logs_SMS]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    ----------------------------------------------------------
    -- Queue one SMS per contact at the device location
    ----------------------------------------------------------
    INSERT INTO [POSTGRESQL30].[spooldb].[public].[odbc_queue]
    (
        mobile_numb,
        msg_from,
        msg_content,
        created_dtm,
        inter_fmt,
        [priority],
        modem_label
    )
    SELECT DISTINCT
        LTRIM(RTRIM(c.CellNumber)) AS mobile_numb,
        'PostgreSQL' AS msg_from,

        'PERMS INFORMATION'
        + CHAR(13) + CHAR(10)
        + CHAR(13) + CHAR(10)

        + 'Location: '
        + ISNULL(loc.AlarmLocation, '')
        + CHAR(13) + CHAR(10)

        + 'Device Name: '
        + ISNULL(i.device_name, '')
        + CHAR(13) + CHAR(10)

        + CASE i.device_name
              WHEN 'PERMS-0034' THEN 'Machine: Freezer 1'
              WHEN 'PERMS-0033' THEN 'Machine: Freezer 2'
              WHEN 'PERMS-0036' THEN 'Machine: Freezer 3'
              WHEN 'PERMS-0040' THEN 'Machine: Freezer 4'
              WHEN 'PERMS-0037' THEN 'Machine: Freezer 5'
              WHEN 'PERMS-0030' THEN 'Machine: Freezer 6'
              WHEN 'PERMS-0031' THEN 'Machine: Freezer 7'
              WHEN 'PERMS-0032' THEN 'Machine: Freezer 8'
              WHEN 'PERMS-0039' THEN 'Machine: Freezer 10'
              WHEN 'PERMS-0038' THEN 'Machine: Freezer 11'
              WHEN 'PERMS-TEST' THEN 'Machine: Freezer TEST'
              WHEN 'PERMS-MCR'  THEN 'Machine: Test MCR'
              WHEN 'PERMS-TR'   THEN 'Machine: Test TR'
              ELSE 'Machine: Unknown'
          END
        + CHAR(13) + CHAR(10)

        + 'Temperature: '
        + ISNULL(CONVERT(VARCHAR(50), i.temperature), '')
        + CHAR(13) + CHAR(10)

        + 'Date: '
        + ISNULL(CONVERT(VARCHAR(19), i.date_time, 120), '')
        + CHAR(13) + CHAR(10)
        + CHAR(13) + CHAR(10)

        + '[This is an automated message please do not reply]' AS msg_content,

        GETDATE() AS created_dtm,
        '1' AS inter_fmt,
        '1' AS [priority],
        '' AS modem_label
    FROM inserted AS i
    INNER JOIN deleted AS d
        ON d.id = i.id

    ----------------------------------------------------------
    -- Map each device to a location
    ----------------------------------------------------------
    CROSS APPLY
    (
        SELECT
            CASE
                WHEN i.device_name IN
                (
                    'PERMS-0034',
                    'PERMS-0033',
                    'PERMS-0036',
                    'PERMS-0040',
                    'PERMS-0037',
                    'PERMS-0030',
                    'PERMS-0031',
                    'PERMS-0032',
                    'PERMS-0039',
                    'PERMS-0038'
                ) THEN 'LSI'

                WHEN i.device_name IN
                (
                    'PERMS-MCR'
                ) THEN 'MCR'

                WHEN i.device_name IN
                (
                    'PERMS-TR'
                ) THEN 'TR'

                WHEN i.device_name = 'PERMS-TEST'
                    THEN 'TEST'

                ELSE NULL
            END AS AlarmLocation
    ) AS loc

    ----------------------------------------------------------
    -- Confirm location is registered for the PERMS app
    ----------------------------------------------------------
    INNER JOIN dbo.PMContactGroup AS cg
        ON LTRIM(RTRIM(cg.Location)) = loc.AlarmLocation
       AND LTRIM(RTRIM(cg.App)) = 'PERMS'

    ----------------------------------------------------------
    -- Get all contacts assigned to the matching location
    ----------------------------------------------------------
    INNER JOIN dbo.PMContacts AS c
        ON LTRIM(RTRIM(c.Location)) =
           LTRIM(RTRIM(cg.Location))

    WHERE i.val >= 10
      AND ISNULL(i.is_sms_sent, 0) = 0
      AND ISNULL(d.val, 0) < 10
      AND NULLIF(LTRIM(RTRIM(c.CellNumber)), '') IS NOT NULL;

    ----------------------------------------------------------
    -- Mark as sent only when at least one valid recipient exists
    ----------------------------------------------------------
    UPDATE t
       SET t.is_sms_sent = 1
    FROM dbo.PERMS_logs_SMS AS t
    INNER JOIN inserted AS i
        ON i.id = t.id
    INNER JOIN deleted AS d
        ON d.id = i.id

    CROSS APPLY
    (
        SELECT
            CASE
                WHEN i.device_name IN
                (
                    'PERMS-0034',
                    'PERMS-0033',
                    'PERMS-0036',
                    'PERMS-0040',
                    'PERMS-0037',
                    'PERMS-0030',
                    'PERMS-0031',
                    'PERMS-0032',
                    'PERMS-0039',
                    'PERMS-0038'
                ) THEN 'LSI'

                WHEN i.device_name IN
                (
                    'PERMS-MCR'
                ) THEN 'MCR'

                WHEN i.device_name IN
                (
                    'PERMS-TR'
                ) THEN 'TR'

                WHEN i.device_name = 'PERMS-TEST'
                    THEN 'TEST'

                ELSE NULL
            END AS AlarmLocation
    ) AS loc

    WHERE i.val >= 10
      AND ISNULL(i.is_sms_sent, 0) = 0
      AND ISNULL(d.val, 0) < 10
      AND EXISTS
      (
          SELECT 1
          FROM dbo.PMContactGroup AS cg
          INNER JOIN dbo.PMContacts AS c
              ON LTRIM(RTRIM(c.Location)) =
                 LTRIM(RTRIM(cg.Location))
          WHERE LTRIM(RTRIM(cg.Location)) =
                loc.AlarmLocation
            AND LTRIM(RTRIM(cg.App)) = 'PERMS'
            AND NULLIF(
                    LTRIM(RTRIM(c.CellNumber)),
                    ''
                ) IS NOT NULL
      );
END;
GO

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

    ;WITH inserted_values AS
    (
        SELECT
            device_name,
            TRY_CONVERT(DECIMAL(10, 2), temperature) AS temp_num,
            temperature,
            humidity,
            date_time
        FROM inserted
        WHERE device_name IN
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
                   --------------------------------------------------
                   -- Standard freezer range: -38 to -17
                   --------------------------------------------------
                   WHEN i.temp_num IS NOT NULL
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

    ;WITH i AS
    (
        SELECT
            device_name,
            TRY_CONVERT(DECIMAL(10, 2), temperature) AS temp_num,
            temperature,
            humidity,
            date_time
        FROM inserted
        WHERE device_name IN
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
                   WHEN i.temp_num IS NOT NULL
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