USE [AIM_DB]
GO
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'dbo.PERMS_TR_Device', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.PERMS_TR_Device
        (
            device_name VARCHAR(50) NOT NULL PRIMARY KEY,
            AreaName VARCHAR(100) NOT NULL,
            MachineName VARCHAR(50) NOT NULL,
            min_temp DECIMAL(10, 2) NOT NULL,
            max_temp DECIMAL(10, 2) NOT NULL,
            InstallationStatus VARCHAR(100) NOT NULL,
            alerts_enabled BIT NOT NULL DEFAULT (0),
            CHECK (min_temp <= max_temp)
        );
    END;

    INSERT INTO dbo.PERMS_TR_Device
    (
        device_name, AreaName, MachineName, min_temp, max_temp,
        InstallationStatus, alerts_enabled
    )
    SELECT
        device_name, AreaName, MachineName, min_temp, max_temp,
        InstallationStatus, alerts_enabled
    FROM
    (
        VALUES
            ('PERMS-0067', '1F RESIN ROOM 1', 'CHILLER', 0.00, 5.00,
             'FOR INSTALLATION', 0),
            ('PERMS-0068', '1F RESIN ROOM 2', 'CHILLER', 0.00, 5.00,
             'FOR INSTALLATION', 0),
            ('PERMS-0069', '1F WAREHOUSE', 'FREEZER 1', -25.00, -15.00,
             'ACTIVE', 1),
            ('PERMS-0070', '1F WAREHOUSE', 'FREEZER 2', -25.00, -15.00,
             'ACTIVE', 1),
            ('PERMS-0071', 'PD 2 PASTE STORAGE AREA', 'FREEZER 1', -25.00, -15.00,
             'ACTIVE', 1),
            ('PERMS-0072', 'PD 2 PASTE STORAGE AREA', 'FREEZER 2', -25.00, -15.00,
             'ACTIVE BUT TEMPERATURE SETTING NOT YET SET', 0),
            ('PERMS-0073', 'PD 3 PASTE STORAGE AREA', 'FREEZER', -25.00, -15.00,
             'INSTALLED BUT NOT YET ACTIVE', 0)
    ) AS devices
    (
        device_name, AreaName, MachineName, min_temp, max_temp,
        InstallationStatus, alerts_enabled
    )
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dbo.PERMS_TR_Device AS existing
        WHERE existing.device_name = devices.device_name
    );

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

SELECT
    device.device_name,
    device.AreaName,
    device.MachineName,
    device.min_temp,
    device.max_temp,
    device.InstallationStatus,
    device.alerts_enabled,
    target.id AS sms_source_id,
    target.is_activated
FROM dbo.PERMS_TR_Device AS device
LEFT JOIN dbo.PERMS_logs_SMS AS target
    ON target.device_name = device.device_name
ORDER BY device.device_name;
GO