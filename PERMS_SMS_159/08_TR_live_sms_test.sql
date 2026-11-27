USE [PERMS_SMS]
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DummyID INT = -2147483645;
DECLARE @GroupID INT;
DECLARE @QueueID INT;
DECLARE @LockResult INT;
DECLARE @OriginalSendingEnabled BIT;
DECLARE @FixtureCommitted BIT = 0;
DECLARE @TestDelayMinutes INT = 0;
DECLARE @ExpectedNotificationHour INT = 0;

IF DB_NAME() <> N'PERMS_SMS'
    THROW 51700, 'Select the PERMS_SMS database before testing.', 1;
IF @@TRANCOUNT <> 0
    THROW 51701, 'Run the entire live test outside an existing transaction.', 1;
IF OBJECT_ID(N'dbo.Process_PERMS_SMS_Queue', N'P') IS NULL
 OR OBJECT_ID(N'dbo.Queue_PERMS_Notifications', N'P') IS NULL
    THROW 51702, 'Install polling scripts 01, 02, and 03 first.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE name = N'POSTGRESQL30')
    THROW 51703, 'Configure POSTGRESQL30 before the live test.', 1;
IF EXISTS
(
    SELECT 1 FROM sys.triggers
    WHERE parent_id IN (OBJECT_ID(N'dbo.PERMS_logs_SMS'), OBJECT_ID(N'dbo.SMS_Queue'))
      AND is_disabled = 0
)
    THROW 51704, 'Enabled local status or queue triggers must be reviewed before testing.', 1;

EXEC @LockResult = sys.sp_getapplock
    @Resource = N'PERMS_SMS_159_Pipeline', @LockMode = 'Exclusive',
    @LockOwner = 'Session', @LockTimeout = 0;
IF @LockResult < 0
    THROW 51705, 'Another cycle is running. Retry later.', 1;

BEGIN TRY
    SELECT @OriginalSendingEnabled = sending_enabled
    FROM dbo.PERMS_SMS_Control WHERE control_id = 1;
    IF @OriginalSendingEnabled IS NULL
        THROW 51706, 'The SMS control row is missing. Complete setup first.', 1;
    IF EXISTS (SELECT 1 FROM dbo.SMS_Queue WHERE is_processed = 0)
        THROW 51707, 'Pending alerts exist. This test will not send or modify them.', 1;
    IF EXISTS (SELECT 1 FROM dbo.PERMS_logs_SMS WHERE id = @DummyID)
        THROW 51708, 'This TR dummy device already exists. Review the previous test before resending.', 1;
    IF (SELECT COUNT(*) FROM dbo.PMContactGroup WHERE Location = 'TR' AND App = 'PERMS') <> 1
        THROW 51709, 'Exactly one TR/PERMS contact group is required.', 1;

    SELECT @GroupID = ID FROM dbo.PMContactGroup
    WHERE Location = 'TR' AND App = 'PERMS';

        SELECT @TestDelayMinutes = tier1_minutes,
            @ExpectedNotificationHour = -1 - tier1_minutes
        FROM dbo.PERMS_SMS_EscalationPolicy WHERE Location = 'TR' AND enabled = 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.PMUserGroup AS membership
        INNER JOIN dbo.PMContacts AS contact ON contact.ID = membership.PmContactID
                LEFT JOIN dbo.PERMS_SMS_ContactTier AS tier
                        ON tier.Location = 'TR' AND tier.PmContactID = contact.ID
        WHERE membership.PMContactGroup = @GroupID
          AND NULLIF(LTRIM(RTRIM(contact.CellNumber)), '') IS NOT NULL
                    AND (@TestDelayMinutes = 0 OR tier.Tier = 1)
    )
                THROW 51710, 'No eligible TR/PERMS phone numbers. With timed escalation enabled, configure Tier 1 members first.', 1;

    BEGIN TRANSACTION;

    INSERT INTO dbo.PERMS_logs_SMS
        (id, device_name, temperature, date_time, val, is_activated,
         alarm_sequence, abnormal_started_dtm, last_reading_id)
    SELECT @DummyID, device_name, CONVERT(NVARCHAR(50), min_temp - 1),
            GETDATE(), 10, 1, 1, DATEADD(MINUTE, -@TestDelayMinutes, GETDATE()), 0
    FROM dbo.PERMS_SMS_DeviceRule
    WHERE device_name = N'PERMS-TR' AND Location = 'TR' AND alerts_enabled = 1;
    IF @@ROWCOUNT <> 1
        THROW 51711, 'The PERMS-TR test rule is missing or disabled.', 1;

    EXEC dbo.Queue_PERMS_Notifications;

    SELECT @QueueID = queue_id FROM dbo.PERMS_SMS_Notification
    WHERE source_id = @DummyID AND alarm_sequence = 1
    AND notification_hour = @ExpectedNotificationHour AND Location = 'TR';
    IF @QueueID IS NULL
        THROW 51712, 'The dummy TR notification was not created.', 1;
    IF EXISTS (SELECT 1 FROM dbo.SMS_Queue WHERE is_processed = 0 AND queue_id <> @QueueID)
        THROW 51713, 'Other devices are due for alerts. Test rolled back without sending.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.PERMS_SMS_Recipient WHERE queue_id = @QueueID)
        THROW 51714, 'No eligible TR phone numbers were captured. Nothing sent.', 1;

    UPDATE dbo.SMS_Queue
       SET msg_content = 'TEST ONLY - TR - NO ACTION REQUIRED' + CHAR(13) + CHAR(10)
                       + 'Simulated count 10 and elapsed minutes ' + CONVERT(VARCHAR(12), @TestDelayMinutes)
                       + ', not real equipment.' + CHAR(13) + CHAR(10)
                       + msg_content
    WHERE queue_id = @QueueID;

    UPDATE dbo.PERMS_SMS_Control SET sending_enabled = 1 WHERE control_id = 1;
    COMMIT TRANSACTION;
    SET @FixtureCommitted = 1;

    EXEC dbo.Process_PERMS_SMS_Queue;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.SMS_Queue
        WHERE queue_id = @QueueID AND is_processed = 1 AND error_message IS NULL
    )
        THROW 51715, 'The sender did not confirm spool forwarding. Inspect the TR test queue.', 1;

    BEGIN TRANSACTION;
    UPDATE dbo.PERMS_SMS_Control
       SET sending_enabled = @OriginalSendingEnabled WHERE control_id = 1;
    UPDATE dbo.PERMS_logs_SMS
       SET is_activated = 0, val = 0, is_sms_sent = 0,
           abnormal_started_dtm = NULL, last_queued_hour = 0
    WHERE id = @DummyID;
    COMMIT TRANSACTION;

    SELECT queue.queue_id, recipient.mobile_numb, queue.msg_content,
           queue.is_processed, queue.processed_dtm, queue.error_message,
           'Forwarded to SMS spool. Ask TR recipients to confirm receipt; delivery is not confirmed here.' AS result
    FROM dbo.SMS_Queue AS queue
    INNER JOIN dbo.PERMS_SMS_Recipient AS recipient ON recipient.queue_id = queue.queue_id
    WHERE queue.queue_id = @QueueID
    ORDER BY recipient.mobile_numb;

    EXEC sys.sp_releaseapplock
        @Resource = N'PERMS_SMS_159_Pipeline', @LockOwner = 'Session';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @FixtureCommitted = 1
    BEGIN
        BEGIN TRANSACTION;
        UPDATE dbo.PERMS_SMS_Control
           SET sending_enabled = @OriginalSendingEnabled WHERE control_id = 1;
        UPDATE dbo.SMS_Queue
           SET is_processed = 1, processed_dtm = GETDATE(),
               error_message = 'Live TR test stopped; automatic retry disabled. Remote acceptance may have occurred. ' + ERROR_MESSAGE()
        WHERE queue_id = @QueueID AND is_processed = 0;
        UPDATE dbo.PERMS_logs_SMS
           SET is_activated = 0, val = 0, is_sms_sent = 0,
               abnormal_started_dtm = NULL, last_queued_hour = 0
        WHERE id = @DummyID;
        COMMIT TRANSACTION;
    END;
    EXEC sys.sp_releaseapplock
        @Resource = N'PERMS_SMS_159_Pipeline', @LockOwner = 'Session';
    THROW;
END CATCH;
GO