USE [AIM_DB]
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF @@TRANCOUNT <> 0
    THROW 51100, 'Run this staging test outside an existing transaction.', 1;

IF NOT EXISTS
(
    SELECT 1 FROM sys.triggers
    WHERE object_id = OBJECT_ID(N'dbo.trg_PERMS_logs_SMS_on_sent') AND is_disabled = 0
)
    THROW 51101, 'The revised SMS trigger must be enabled.', 1;

IF EXISTS
(
    SELECT 1 FROM sys.triggers
    WHERE parent_id = OBJECT_ID(N'dbo.PERMS_logs_SMS') AND is_disabled = 0
      AND name <> 'trg_PERMS_logs_SMS_on_sent'
)
    THROW 51102, 'Disable other PERMS_logs_SMS triggers in staging before testing.', 1;

IF EXISTS
(
    SELECT 1
    FROM
    (
        VALUES
            ('PERMS-0067',   0.00,   5.00),
            ('PERMS-0068',   0.00,   5.00),
            ('PERMS-0069', -25.00, -15.00),
            ('PERMS-0070', -25.00, -15.00),
            ('PERMS-0071', -25.00, -15.00),
            ('PERMS-0072', -25.00, -15.00),
            ('PERMS-0073', -25.00, -15.00)
    ) AS expected(device_name, min_temp, max_temp)
    LEFT JOIN dbo.PERMS_TR_Device AS device ON device.device_name = expected.device_name
    WHERE device.device_name IS NULL
       OR device.min_temp <> expected.min_temp OR device.max_temp <> expected.max_temp
       OR expected.min_temp NOT BETWEEN device.min_temp AND device.max_temp
       OR expected.max_temp NOT BETWEEN device.min_temp AND device.max_temp
       OR expected.min_temp - 0.01 BETWEEN device.min_temp AND device.max_temp
       OR expected.max_temp + 0.01 BETWEEN device.min_temp AND device.max_temp
)
    THROW 51103, 'TR mappings or inclusive temperature boundaries do not match the supplied limits.', 1;

IF
(
    SELECT COUNT(*) FROM dbo.PMContactGroup
    WHERE LTRIM(RTRIM(Location)) = 'TR' AND LTRIM(RTRIM(App)) = 'PERMS'
) <> 1
    THROW 51104, 'Exactly one TR / PERMS contact group is required.', 1;

DECLARE @GroupID INT =
(
    SELECT ID FROM dbo.PMContactGroup
    WHERE LTRIM(RTRIM(Location)) = 'TR' AND LTRIM(RTRIM(App)) = 'PERMS'
);

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.PMUserGroup AS membership
    INNER JOIN dbo.PMContacts AS contact ON contact.ID = membership.PmContactID
    WHERE membership.PMContactGroup = @GroupID
      AND NULLIF(LTRIM(RTRIM(contact.CellNumber)), '') IS NOT NULL
)
    THROW 51105, 'Assign a valid phone contact to the TR / PERMS group before testing.', 1;

IF (SELECT COUNT(*) FROM dbo.PERMS_logs_SMS WHERE device_name = 'PERMS-0069') <> 1
 OR (SELECT COUNT(*) FROM dbo.PERMS_logs_SMS WHERE device_name = 'PERMS-0072') <> 1
    THROW 51106, 'Existing PERMS-0069 and PERMS-0072 source rows are required for this staging test.', 1;

DECLARE @ActiveSource INT = (SELECT id FROM dbo.PERMS_logs_SMS WHERE device_name = 'PERMS-0069');
DECLARE @DisabledSource INT = (SELECT id FROM dbo.PERMS_logs_SMS WHERE device_name = 'PERMS-0072');
DECLARE @LastQueueID INT;

BEGIN TRY
    BEGIN TRANSACTION;

    SELECT @LastQueueID = ISNULL(MAX(queue_id), 0) FROM dbo.SMS_Queue;
    UPDATE dbo.PERMS_TR_Device SET alerts_enabled = 1 WHERE device_name = 'PERMS-0069';
    UPDATE dbo.PERMS_TR_Device SET alerts_enabled = 0 WHERE device_name = 'PERMS-0072';

    UPDATE dbo.SMS_Queue SET is_processed = 1
    WHERE source_id IN (@ActiveSource, @DisabledSource) AND is_processed = 0;

    UPDATE dbo.PERMS_logs_SMS
       SET temperature = -20, val = 0, is_activated = 1, date_time = GETDATE()
    WHERE id IN (@ActiveSource, @DisabledSource);

    UPDATE dbo.PERMS_logs_SMS
       SET temperature = -26, val = 9, date_time = GETDATE()
    WHERE id IN (@ActiveSource, @DisabledSource);

    IF EXISTS
    (
        SELECT 1 FROM dbo.SMS_Queue
        WHERE queue_id > @LastQueueID AND source_id IN (@ActiveSource, @DisabledSource)
    )
        THROW 51107, 'A TR alert was queued below val 10.', 1;

    UPDATE dbo.PERMS_logs_SMS SET val = 10
    WHERE id IN (@ActiveSource, @DisabledSource);

    IF
    (
        SELECT COUNT(*) FROM dbo.SMS_Queue
        WHERE queue_id > @LastQueueID AND source_id = @ActiveSource AND pm_user_group = @GroupID
          AND msg_content LIKE '%Area: 1F WAREHOUSE%'
          AND msg_content LIKE '%Machine: FREEZER 1%'
    ) <> 1
        THROW 51108, 'Expected one TR-routed alert with the area and equipment name at val 10.', 1;

    IF EXISTS
    (
        SELECT 1 FROM dbo.SMS_Queue WHERE queue_id > @LastQueueID AND source_id = @DisabledSource
    )
        THROW 51109, 'A disabled TR device queued an alert.', 1;

    UPDATE dbo.PERMS_logs_SMS SET val = 11 WHERE id = @ActiveSource;

    IF (SELECT COUNT(*) FROM dbo.SMS_Queue WHERE queue_id > @LastQueueID AND source_id = @ActiveSource) <> 1
        THROW 51110, 'An intermediate counter update queued a duplicate TR alert.', 1;

    ROLLBACK TRANSACTION;
    SELECT 'PASS: Seven TR ranges, inclusive boundaries, val 10 routing, area/equipment text, disabled-device suppression, and no duplicate at val 11. Changes rolled back; sender was not called.' AS result;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO