USE [PERMS_SMS]
GO
SET XACT_ABORT ON;

IF DB_NAME() <> N'PERMS_SMS'
    THROW 51200, 'Connect to the PERMS_SMS database on .159 before installing.', 1;

IF OBJECT_ID(N'PERMS.dbo.PERMS_logs', N'U') IS NULL
 OR OBJECT_ID(N'PERMS.dbo.PERMS_master', N'U') IS NULL
    THROW 51201, 'Read access to PERMS.dbo.PERMS_logs and PERMS.dbo.PERMS_master is required.', 1;

IF OBJECT_ID(N'dbo.PERMS_logs_SMS', N'U') IS NOT NULL
   AND
   (
       COL_LENGTH(N'dbo.PERMS_logs_SMS', N'last_reading_id') IS NULL
       OR COLUMNPROPERTY(OBJECT_ID(N'dbo.PERMS_logs_SMS'), N'id', 'IsIdentity') = 1
   )
    THROW 51202, 'An incompatible legacy PERMS_logs_SMS table exists. Back up and reconcile it; do not overwrite it.', 1;

IF EXISTS
(
    SELECT 1 FROM sys.triggers
    WHERE parent_id = OBJECT_ID(N'dbo.PERMS_logs_SMS') AND is_disabled = 0
)
    THROW 51203, 'This polling design must not run with legacy triggers on local PERMS_logs_SMS.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'dbo.PMContactGroup', N'U') IS NULL
        CREATE TABLE dbo.PMContactGroup
        (
            ID INT NOT NULL PRIMARY KEY,
            Location VARCHAR(10) NOT NULL,
            App VARCHAR(20) NOT NULL,
            UNIQUE (Location, App)
        );

    INSERT INTO dbo.PMContactGroup (ID, Location, App)
    SELECT group_info.ID, group_info.Location, 'PERMS'
    FROM (VALUES (1, 'LSI'), (3, 'MCR'), (4, 'TR')) AS group_info(ID, Location)
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dbo.PMContactGroup AS existing
        WHERE existing.Location = group_info.Location AND existing.App = 'PERMS'
    );

    IF OBJECT_ID(N'dbo.PMContacts', N'U') IS NULL
        CREATE TABLE dbo.PMContacts
        (
            ID INT IDENTITY(1, 1) NOT NULL PRIMARY KEY,
            Name NVARCHAR(100) NOT NULL,
            Position NVARCHAR(50) NULL,
            CellNumber VARCHAR(50) NOT NULL,
            Location VARCHAR(10) NOT NULL
        );

    IF OBJECT_ID(N'dbo.PMUserGroup', N'U') IS NULL
        CREATE TABLE dbo.PMUserGroup
        (
            PmContactID INT NOT NULL,
            PMContactGroup INT NOT NULL,
            PRIMARY KEY (PmContactID, PMContactGroup)
        );

    IF OBJECT_ID(N'dbo.PERMS_MCR_ContactTier', N'U') IS NULL
        CREATE TABLE dbo.PERMS_MCR_ContactTier
        (
            PmContactID INT NOT NULL PRIMARY KEY,
            Tier TINYINT NOT NULL CHECK (Tier BETWEEN 1 AND 3)
        );

    IF OBJECT_ID(N'dbo.PERMS_SMS_EscalationPolicy', N'U') IS NULL
        CREATE TABLE dbo.PERMS_SMS_EscalationPolicy
        (
            Location VARCHAR(10) NOT NULL PRIMARY KEY CHECK (Location IN ('LSI', 'TR')),
            enabled BIT NOT NULL DEFAULT (0),
            tier1_minutes INT NOT NULL,
            tier2_minutes INT NOT NULL,
            tier3_minutes INT NOT NULL,
            repeat_minutes INT NOT NULL,
            CHECK (tier1_minutes > 0 AND tier2_minutes > tier1_minutes
                   AND tier3_minutes > tier2_minutes AND tier3_minutes <= 525600),
            CHECK (repeat_minutes BETWEEN 1 AND 525600)
        );

    INSERT INTO dbo.PERMS_SMS_EscalationPolicy
        (Location, enabled, tier1_minutes, tier2_minutes, tier3_minutes, repeat_minutes)
    SELECT defaults.Location, 0, 20, 40, 80, 20
    FROM (VALUES ('LSI'), ('TR')) AS defaults(Location)
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dbo.PERMS_SMS_EscalationPolicy AS existing
        WHERE existing.Location = defaults.Location
    );

    IF OBJECT_ID(N'dbo.PERMS_SMS_ContactTier', N'U') IS NULL
        CREATE TABLE dbo.PERMS_SMS_ContactTier
        (
            Location VARCHAR(10) NOT NULL CHECK (Location IN ('LSI', 'TR')),
            PmContactID INT NOT NULL,
            Tier TINYINT NOT NULL CHECK (Tier BETWEEN 1 AND 3),
            PRIMARY KEY (Location, PmContactID)
        );

    IF OBJECT_ID(N'dbo.PERMS_SMS_DeviceRule', N'U') IS NULL
        CREATE TABLE dbo.PERMS_SMS_DeviceRule
        (
            device_name NVARCHAR(50) NOT NULL PRIMARY KEY,
            Location VARCHAR(10) NOT NULL,
            AreaName NVARCHAR(100) NOT NULL,
            MachineName NVARCHAR(50) NOT NULL,
            min_temp DECIMAL(10, 2) NOT NULL,
            max_temp DECIMAL(10, 2) NOT NULL,
            alerts_enabled BIT NOT NULL,
            max_reading_age_minutes INT NOT NULL DEFAULT (15),
            CHECK (min_temp <= max_temp),
            CHECK (Location IN ('LSI', 'MCR', 'TR')),
            CHECK (max_reading_age_minutes > 0)
        );

    INSERT INTO dbo.PERMS_SMS_DeviceRule
        (device_name, Location, AreaName, MachineName, min_temp, max_temp, alerts_enabled)
    SELECT device_name, Location, AreaName, MachineName, min_temp, max_temp, alerts_enabled
    FROM
    (
        VALUES
            ('PERMS-0034', 'LSI', 'LSI', 'Freezer 1', -38.00, -17.00, 1),
            ('PERMS-0033', 'LSI', 'LSI', 'Freezer 2', -38.00, -17.00, 1),
            ('PERMS-0036', 'LSI', 'LSI', 'Freezer 3', -38.00, -17.00, 1),
            ('PERMS-0040', 'LSI', 'LSI', 'Freezer 4', -68.00, -42.00, 1),
            ('PERMS-0037', 'LSI', 'LSI', 'Freezer 5', -38.00, -17.00, 1),
            ('PERMS-0030', 'LSI', 'LSI', 'Freezer 6', -38.00, -17.00, 1),
            ('PERMS-0031', 'LSI', 'LSI', 'Freezer 7', -38.00, -17.00, 1),
            ('PERMS-0032', 'LSI', 'LSI', 'Freezer 8', -38.00, -17.00, 1),
            ('PERMS-0039', 'LSI', 'LSI', 'Freezer 10', -68.00, -42.00, 1),
            ('PERMS-0038', 'LSI', 'LSI', 'Freezer 11', -68.00, -42.00, 1),
            ('PERMS-TEST', 'LSI', 'LSI', 'Freezer TEST', -38.00, -17.00, 1),
            ('PERMS-0023', 'MCR', '2F Paste Storage Area', 'Freezer 1', -30.00, -20.00, 1),
            ('PERMS-0051', 'MCR', '2F Paste Storage Area', 'Freezer 2', -30.00, -20.00, 1),
            ('PERMS-0052', 'MCR', '2F Paste Storage Area', 'Chiller 1', 0.00, 4.00, 1),
            ('PERMS-0053', 'MCR', '2F Paste Storage Area', 'Chiller 2', 0.00, 4.00, 1),
            ('PERMS-0054', 'MCR', '2F Paste Storage Area', 'Chiller 3', 0.00, 4.00, 1),
            ('PERMS-0055', 'MCR', '2F Paste Storage Area', 'Chiller 4', 0.00, 4.00, 1),
            ('PERMS-0056', 'MCR', '2F Paste Storage Area', 'Chiller 5', 5.00, 30.00, 1),
            ('PERMS-0057', 'MCR', '2F Paste Storage Area', 'PE Chiller', 0.00, 4.00, 1),
            ('PERMS-0058', 'MCR', '2F Paste Storage Area', 'PE Freezer', -30.00, -20.00, 1),
            ('PERMS-0059', 'MCR', 'Paste Blending Area', 'Freezer', -30.00, -20.00, 1),
            ('PERMS-0060', 'MCR', 'Paste Blending Area', 'V Paste Chiller', 0.00, 10.00, 1),
            ('PERMS-0061', 'MCR', 'Paste Blending Area', 'W Paste Chiller', 5.00, 30.00, 1),
            ('PERMS-0062', 'MCR', '1F PMR Storage Area', 'Freezer', -30.00, -20.00, 1),
            ('PERMS-0064', 'MCR', '1F PMR Storage Area', 'Chiller', 0.00, 4.00, 1),
            ('PERMS-MCR', 'MCR', 'MCR Test', 'Test MCR', -38.00, -17.00, 1),
            ('PERMS-0067', 'TR', '1F RESIN ROOM 1', 'CHILLER', 0.00, 5.00, 0),
            ('PERMS-0068', 'TR', '1F RESIN ROOM 2', 'CHILLER', 0.00, 5.00, 0),
            ('PERMS-0069', 'TR', '1F WAREHOUSE', 'FREEZER 1', -25.00, -15.00, 1),
            ('PERMS-0070', 'TR', '1F WAREHOUSE', 'FREEZER 2', -25.00, -15.00, 1),
            ('PERMS-0071', 'TR', 'PD 2 PASTE STORAGE AREA', 'FREEZER 1', -25.00, -15.00, 1),
            ('PERMS-0072', 'TR', 'PD 2 PASTE STORAGE AREA', 'FREEZER 2', -25.00, -15.00, 0),
            ('PERMS-0073', 'TR', 'PD 3 PASTE STORAGE AREA', 'FREEZER', -25.00, -15.00, 0),
            ('PERMS-TR', 'TR', 'TR Test', 'Test TR', -38.00, -17.00, 1)
    ) AS rules(device_name, Location, AreaName, MachineName, min_temp, max_temp, alerts_enabled)
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dbo.PERMS_SMS_DeviceRule AS existing
        WHERE existing.device_name = rules.device_name
    );

    IF OBJECT_ID(N'dbo.PERMS_logs_SMS', N'U') IS NULL
        CREATE TABLE dbo.PERMS_logs_SMS
        (
            id INT NOT NULL PRIMARY KEY,
            device_name NVARCHAR(50) NOT NULL,
            temperature NVARCHAR(50) NULL,
            humidity NVARCHAR(50) NULL,
            date_time DATETIME NULL,
            val INT NOT NULL DEFAULT (0),
            is_activated BIT NOT NULL DEFAULT (0),
            is_sms_sent BIT NOT NULL DEFAULT (0),
            alarm_sequence BIGINT NOT NULL DEFAULT (0),
            abnormal_started_dtm DATETIME NULL,
            last_queued_hour INT NOT NULL DEFAULT (0),
            last_reading_id INT NULL
        );

    IF OBJECT_ID(N'dbo.PERMS_SMS_Control', N'U') IS NULL
        CREATE TABLE dbo.PERMS_SMS_Control
        (
            control_id INT NOT NULL PRIMARY KEY CHECK (control_id = 1),
            start_after_id INT NULL,
            sending_enabled BIT NOT NULL DEFAULT (0),
            initialized_dtm DATETIME2(0) NULL
        );

    IF NOT EXISTS (SELECT 1 FROM dbo.PERMS_SMS_Control WHERE control_id = 1)
        INSERT INTO dbo.PERMS_SMS_Control (control_id, sending_enabled) VALUES (1, 0);

    IF OBJECT_ID(N'dbo.PERMS_SMS_ImportedReading', N'U') IS NULL
        CREATE TABLE dbo.PERMS_SMS_ImportedReading
        (
            reading_id INT NOT NULL PRIMARY KEY,
            master_device_id INT NULL,
            import_status VARCHAR(30) NOT NULL,
            imported_dtm DATETIME2(0) NOT NULL DEFAULT (SYSDATETIME())
        );

    IF OBJECT_ID(N'dbo.SMS_Queue', N'U') IS NULL
        CREATE TABLE dbo.SMS_Queue
        (
            queue_id INT IDENTITY(1, 1) NOT NULL PRIMARY KEY,
            source_id INT NOT NULL,
            pm_user_group INT NOT NULL,
            msg_from VARCHAR(50) NOT NULL,
            msg_content VARCHAR(MAX) NOT NULL,
            created_dtm DATETIME NOT NULL DEFAULT (GETDATE()),
            is_processed BIT NOT NULL DEFAULT (0),
            processed_dtm DATETIME NULL,
            error_message VARCHAR(MAX) NULL
        );

    IF OBJECT_ID(N'dbo.PERMS_SMS_Notification', N'U') IS NULL
        CREATE TABLE dbo.PERMS_SMS_Notification
        (
            queue_id INT NOT NULL PRIMARY KEY REFERENCES dbo.SMS_Queue(queue_id),
            source_id INT NOT NULL,
            alarm_sequence BIGINT NOT NULL,
            notification_hour INT NOT NULL,
            Location VARCHAR(10) NOT NULL,
            UNIQUE (source_id, alarm_sequence, notification_hour)
        );

    IF OBJECT_ID(N'dbo.PERMS_SMS_Recipient', N'U') IS NULL
        CREATE TABLE dbo.PERMS_SMS_Recipient
        (
            queue_id INT NOT NULL REFERENCES dbo.PERMS_SMS_Notification(queue_id),
            mobile_numb VARCHAR(50) NOT NULL,
            PRIMARY KEY (queue_id, mobile_numb)
        );

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

SELECT DB_NAME() AS target_database, start_after_id, sending_enabled
FROM dbo.PERMS_SMS_Control;
GO