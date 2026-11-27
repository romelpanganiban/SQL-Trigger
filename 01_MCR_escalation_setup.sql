USE [AIM_DB]
GO
SET XACT_ABORT ON;

DECLARE @MissingTable NVARCHAR(128);

SELECT TOP (1) @MissingTable = required.table_name
FROM
(
    VALUES
        (N'dbo.SMS_Queue'),
        (N'dbo.PERMS_logs_SMS'),
        (N'dbo.PMContactGroup'),
        (N'dbo.PMUserGroup'),
        (N'dbo.PMContacts')
) AS required(table_name)
WHERE OBJECT_ID(required.table_name, N'U') IS NULL
ORDER BY required.table_name;

IF @MissingTable IS NOT NULL
BEGIN
    DECLARE @SetupError NVARCHAR(2048) =
        N'MCR setup cannot continue in ' + DB_NAME() + N': missing existing table '
        + @MissingTable + N'. Verify the server and database before running setup.';
    THROW 51022, @SetupError, 1;
END;

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'dbo.PERMS_MCR_Device', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.PERMS_MCR_Device
        (
            device_name VARCHAR(50) NOT NULL PRIMARY KEY,
            AreaName VARCHAR(100) NOT NULL,
            MachineName VARCHAR(50) NOT NULL,
            min_temp DECIMAL(10, 2) NOT NULL,
            max_temp DECIMAL(10, 2) NOT NULL,
            max_reading_age_minutes INT NOT NULL DEFAULT (15),
            CHECK (min_temp <= max_temp),
            CHECK (max_reading_age_minutes > 0)
        );
    END;

    INSERT INTO dbo.PERMS_MCR_Device
        (device_name, AreaName, MachineName, min_temp, max_temp)
    SELECT device_name, AreaName, MachineName, min_temp, max_temp
    FROM
    (
        VALUES
            ('PERMS-0023', '2F Paste Storage Area', 'Freezer 1', -30.00, -20.00),
            ('PERMS-0051', '2F Paste Storage Area', 'Freezer 2', -30.00, -20.00),
            ('PERMS-0052', '2F Paste Storage Area', 'Chiller 1',   0.00,   4.00),
            ('PERMS-0053', '2F Paste Storage Area', 'Chiller 2',   0.00,   4.00),
            ('PERMS-0054', '2F Paste Storage Area', 'Chiller 3',   0.00,   4.00),
            ('PERMS-0055', '2F Paste Storage Area', 'Chiller 4',   0.00,   4.00),
            ('PERMS-0056', '2F Paste Storage Area', 'Chiller 5',   5.00,  30.00),
            ('PERMS-0057', '2F Paste Storage Area', 'PE Chiller',  0.00,   4.00),
            ('PERMS-0058', '2F Paste Storage Area', 'PE Freezer', -30.00, -20.00),
            ('PERMS-0059', 'Paste Blending Area', 'Freezer',     -30.00, -20.00),
            ('PERMS-0060', 'Paste Blending Area', 'V Paste Chiller', 0.00, 10.00),
            ('PERMS-0061', 'Paste Blending Area', 'W Paste Chiller', 5.00, 30.00),
            ('PERMS-0062', '1F PMR Storage Area', 'Freezer',      -30.00, -20.00),
            ('PERMS-0064', '1F PMR Storage Area', 'Chiller',        0.00,   4.00),
            ('PERMS-MCR', 'MCR Test', 'Test MCR',                -38.00, -17.00)
    ) AS devices(device_name, AreaName, MachineName, min_temp, max_temp)
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM dbo.PERMS_MCR_Device AS existing
        WHERE existing.device_name = devices.device_name
    );

    IF OBJECT_ID(N'dbo.PERMS_MCR_ContactTier', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.PERMS_MCR_ContactTier
        (
            PmContactID INT NOT NULL PRIMARY KEY,
            Tier TINYINT NOT NULL CHECK (Tier BETWEEN 1 AND 3)
        );
    END;

    IF OBJECT_ID(N'dbo.PERMS_MCR_AlarmState', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.PERMS_MCR_AlarmState
        (
            source_id INT NOT NULL PRIMARY KEY,
            alarm_sequence BIGINT NOT NULL DEFAULT (0),
            abnormal_started_dtm DATETIME2(0) NULL,
            last_observed_dtm DATETIME2(0) NOT NULL,
            last_queued_hour INT NOT NULL DEFAULT (0)
        );
    END;

    IF OBJECT_ID(N'dbo.PERMS_MCR_Notification', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.PERMS_MCR_Notification
        (
            queue_id INT NOT NULL PRIMARY KEY,
            source_id INT NOT NULL,
            alarm_sequence BIGINT NOT NULL,
            notification_hour INT NOT NULL CHECK (notification_hour >= 1),
            UNIQUE (source_id, alarm_sequence, notification_hour),
            FOREIGN KEY (queue_id) REFERENCES dbo.SMS_Queue(queue_id)
        );
    END;

    IF OBJECT_ID(N'dbo.PERMS_MCR_NotificationRecipient', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.PERMS_MCR_NotificationRecipient
        (
            queue_id INT NOT NULL,
            mobile_numb VARCHAR(50) NOT NULL,
            PRIMARY KEY (queue_id, mobile_numb),
            FOREIGN KEY (queue_id) REFERENCES dbo.PERMS_MCR_Notification(queue_id)
        );
    END;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

SELECT
    DB_NAME() AS database_name,
    required.table_name,
    CASE WHEN OBJECT_ID(required.table_name, N'U') IS NOT NULL THEN 'Ready' ELSE 'Missing' END
        AS setup_status
FROM
(
    VALUES
        (N'dbo.PERMS_MCR_Device'),
        (N'dbo.PERMS_MCR_ContactTier'),
        (N'dbo.PERMS_MCR_AlarmState'),
        (N'dbo.PERMS_MCR_Notification'),
        (N'dbo.PERMS_MCR_NotificationRecipient')
) AS required(table_name)
ORDER BY required.table_name;
GO