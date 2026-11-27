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