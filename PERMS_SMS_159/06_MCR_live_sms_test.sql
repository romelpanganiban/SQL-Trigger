USE [PERMS_SMS]
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DummyID INT = -2147483644;
DECLARE @GroupID INT;
DECLARE @QueueID INT;
DECLARE @LockResult INT;
DECLARE @OriginalSendingEnabled BIT;
DECLARE @FixtureCommitted BIT = 0;

IF DB_NAME() <> N'PERMS_SMS'
    THROW 51500, 'Connect to .159 and select PERMS_SMS.', 1;
IF @@TRANCOUNT <> 0
    THROW 51501, 'Run the entire live test outside an existing transaction.', 1;
IF OBJECT_ID(N'dbo.Process_PERMS_SMS_Queue', N'P') IS NULL
 OR OBJECT_ID(N'dbo.Queue_PERMS_Notifications', N'P') IS NULL
    THROW 51502, 'Install polling scripts 01, 02, and 03 first.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE name = N'POSTGRESQL30')
    THROW 51503, 'Configure POSTGRESQL30 on .159 before the live test.', 1;
IF EXISTS
(
    SELECT 1 FROM sys.triggers
    WHERE parent_id IN (OBJECT_ID(N'dbo.PERMS_logs_SMS'), OBJECT_ID(N'dbo.SMS_Queue'))
      AND is_disabled = 0
)
    THROW 51504, 'Enabled local status or queue triggers must be reviewed before testing.', 1;

EXEC @LockResult = sys.sp_getapplock
    @Resource = N'PERMS_SMS_159_Pipeline', @LockMode = 'Exclusive',
    @LockOwner = 'Session', @LockTimeout = 0;
IF @LockResult < 0
    THROW 51505, 'Another cycle is running. Retry later.', 1;

BEGIN TRY
    SELECT @OriginalSendingEnabled = sending_enabled
    FROM dbo.PERMS_SMS_Control WHERE control_id = 1;
    IF @OriginalSendingEnabled IS NULL
        THROW 51506, 'The SMS control row is missing. Complete setup first.', 1;
    IF EXISTS (SELECT 1 FROM dbo.SMS_Queue WHERE is_processed = 0)
        THROW 51507, 'Pending alerts exist. This test will not send or modify them.', 1;
    IF EXISTS (SELECT 1 FROM dbo.PERMS_logs_SMS WHERE id = @DummyID)
        THROW 51508, 'This dummy device already exists. Review the previous test before resending.', 1;
    IF (SELECT COUNT(*) FROM dbo.PMContactGroup WHERE Location = 'MCR' AND App = 'PERMS') <> 1
        THROW 51509, 'Exactly one MCR/PERMS contact group is required.', 1;

    SELECT @GroupID = ID FROM dbo.PMContactGroup
    WHERE Location = 'MCR' AND App = 'PERMS';

    IF EXISTS
    (
        SELECT 1
        FROM dbo.PMUserGroup AS membership
        INNER JOIN dbo.PMContacts AS contact ON contact.ID = membership.PmContactID
        LEFT JOIN dbo.PERMS_MCR_ContactTier AS tier ON tier.PmContactID = contact.ID
        WHERE membership.PMContactGroup = @GroupID
          AND NULLIF(LTRIM(RTRIM(contact.CellNumber)), '') IS NOT NULL
          AND tier.PmContactID IS NULL
    )
        THROW 51515, 'An MCR member has no tier. Configure MCR tiers before testing all members.', 1;

    BEGIN TRANSACTION;

    INSERT INTO dbo.PERMS_logs_SMS
        (id, device_name, temperature, date_time, val, is_activated,
         alarm_sequence, abnormal_started_dtm, last_reading_id)
    SELECT @DummyID, device_name, CONVERT(NVARCHAR(50), min_temp - 1),
           GETDATE(), 120, 1, 1, GETDATE(), 0
    FROM dbo.PERMS_SMS_DeviceRule
    WHERE device_name = N'PERMS-MCR' AND Location = 'MCR' AND alerts_enabled = 1;
    IF @@ROWCOUNT <> 1
        THROW 51510, 'The PERMS-MCR test rule is missing or disabled.', 1;

    EXEC dbo.Queue_PERMS_Notifications;

    SELECT @QueueID = queue_id FROM dbo.PERMS_SMS_Notification
    WHERE source_id = @DummyID AND alarm_sequence = 1 AND notification_hour = 4;
    IF @QueueID IS NULL
        THROW 51511, 'The dummy MCR notification was not created.', 1;
    IF EXISTS (SELECT 1 FROM dbo.SMS_Queue WHERE is_processed = 0 AND queue_id <> @QueueID)
        THROW 51512, 'Other devices are due for alerts. Test rolled back without sending.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.PERMS_SMS_Recipient WHERE queue_id = @QueueID)
        THROW 51513, 'No eligible MCR phone numbers were captured. Nothing sent.', 1;

    UPDATE dbo.SMS_Queue
         SET msg_content = 'TEST ONLY - MCR RETEST - NO ACTION REQUIRED' + CHAR(13) + CHAR(10)
                       + 'MCR all-tier delivery test. Simulated count 120, not real equipment.' + CHAR(13) + CHAR(10)
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
        THROW 51514, 'The sender did not confirm spool forwarding. Inspect the test queue.', 1;

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
            'Forwarded to SMS spool. Ask recipients to confirm receipt; delivery is not confirmed here.' AS result
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
               error_message = 'Live test stopped; automatic retry disabled. Remote acceptance may have occurred. ' + ERROR_MESSAGE()
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