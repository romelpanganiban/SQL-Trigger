USE [PERMS_SMS]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF DB_NAME() <> N'PERMS_SMS'
 OR OBJECT_ID(N'dbo.PERMS_SMS_Control', N'U') IS NULL
 OR OBJECT_ID(N'dbo.Queue_PERMS_Notifications', N'P') IS NULL
 OR OBJECT_ID(N'dbo.PERMS_SMS_TimedTier', N'IF') IS NULL
 OR OBJECT_ID(N'dbo.PERMS_SMS_EscalationPolicy', N'U') IS NULL
 OR OBJECT_ID(N'dbo.PERMS_SMS_ContactTier', N'U') IS NULL
BEGIN
    RAISERROR('Stop: select PERMS_SMS and complete scripts 01 and 02 first.', 16, 1);
    SET NOEXEC ON;
END;
GO

CREATE OR ALTER PROCEDURE dbo.Process_PERMS_SMS_Queue
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @@TRANCOUNT <> 0
        THROW 51215, 'Run the SMS cycle outside an existing transaction.', 1;
    IF APPLOCK_MODE(N'public', N'PERMS_SMS_159_Pipeline', N'Session') <> N'Exclusive'
        THROW 51216, 'Use Run_PERMS_SMS_Cycle to import readings before sending.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.PERMS_SMS_Control WHERE control_id = 1 AND sending_enabled = 1)
        THROW 51217, 'Sending is disabled in PERMS_SMS_Control.', 1;
    IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE name = N'POSTGRESQL30')
        THROW 51218, 'The POSTGRESQL30 linked server must be configured on .159 before sending.', 1;

    DECLARE @Now DATETIME = GETDATE();
    DECLARE @Selected TABLE (queue_id INT NOT NULL PRIMARY KEY);

    CREATE TABLE #Handoff
    (
        queue_id INT NOT NULL,
        mobile_numb VARCHAR(50) NOT NULL,
        msg_from VARCHAR(50) NOT NULL,
        msg_content VARCHAR(MAX) NOT NULL,
        PRIMARY KEY (queue_id, mobile_numb)
    );

    BEGIN TRY
        UPDATE queue
           SET queue.is_processed = 1,
               queue.processed_dtm = GETDATE(),
               queue.error_message = 'Cancelled: recovered, inactive, stale, reconfigured, or superseded.'
        FROM dbo.SMS_Queue AS queue
        INNER JOIN dbo.PERMS_SMS_Notification AS notification ON notification.queue_id = queue.queue_id
        LEFT JOIN dbo.PERMS_logs_SMS AS target ON target.id = notification.source_id
        LEFT JOIN dbo.PERMS_SMS_DeviceRule AS device_rule ON device_rule.device_name = target.device_name
        LEFT JOIN dbo.PERMS_SMS_EscalationPolicy AS policy
            ON policy.Location = notification.Location AND policy.enabled = 1
        OUTER APPLY dbo.PERMS_SMS_Tier(target.val) AS tier
        OUTER APPLY dbo.PERMS_SMS_TimedTier
            (target.abnormal_started_dtm, @Now, policy.tier1_minutes,
             policy.tier2_minutes, policy.tier3_minutes, policy.repeat_minutes) AS timed
        WHERE queue.is_processed = 0
          AND
          (
              target.id IS NULL OR device_rule.device_name IS NULL
              OR target.is_activated = 0 OR device_rule.alerts_enabled = 0
              OR target.val = 0 OR target.alarm_sequence <> notification.alarm_sequence
              OR device_rule.Location <> notification.Location
              OR TRY_CONVERT(DECIMAL(10, 2), target.temperature) IS NULL
              OR TRY_CONVERT(DECIMAL(10, 2), target.temperature) BETWEEN device_rule.min_temp AND device_rule.max_temp
              OR target.date_time IS NULL OR target.date_time > @Now
              OR @Now > DATEADD(MINUTE, device_rule.max_reading_age_minutes, target.date_time)
              OR (notification.Location = 'MCR' AND tier.notification_hour <> notification.notification_hour)
              OR (notification.Location <> 'MCR' AND policy.Location IS NULL AND notification.notification_hour <> 0)
              OR (policy.Location IS NOT NULL AND
                  (timed.notification_hour IS NULL OR timed.notification_hour <> notification.notification_hour))
          );

        INSERT INTO #Handoff (queue_id, mobile_numb, msg_from, msg_content)
        SELECT queue.queue_id, recipient.mobile_numb, queue.msg_from, queue.msg_content
        FROM dbo.SMS_Queue AS queue
        INNER JOIN dbo.PERMS_SMS_Notification AS notification ON notification.queue_id = queue.queue_id
        INNER JOIN dbo.PERMS_SMS_Recipient AS recipient ON recipient.queue_id = queue.queue_id
        INNER JOIN dbo.PERMS_logs_SMS AS target ON target.id = notification.source_id
        LEFT JOIN dbo.PERMS_SMS_EscalationPolicy AS policy
            ON policy.Location = notification.Location AND policy.enabled = 1
        OUTER APPLY dbo.PERMS_SMS_TimedTier
            (target.abnormal_started_dtm, @Now, policy.tier1_minutes,
             policy.tier2_minutes, policy.tier3_minutes, policy.repeat_minutes) AS timed
        WHERE queue.is_processed = 0
          AND EXISTS
          (
              SELECT 1
              FROM dbo.PMUserGroup AS membership
              INNER JOIN dbo.PMContacts AS contact ON contact.ID = membership.PmContactID
              LEFT JOIN dbo.PERMS_MCR_ContactTier AS tier ON tier.PmContactID = contact.ID
              LEFT JOIN dbo.PERMS_SMS_ContactTier AS timed_tier
                  ON timed_tier.Location = notification.Location AND timed_tier.PmContactID = contact.ID
              WHERE membership.PMContactGroup = queue.pm_user_group
                AND LTRIM(RTRIM(contact.CellNumber)) = recipient.mobile_numb
                AND
                (
                    notification.Location <> 'MCR'
                    OR tier.Tier <= CASE
                        WHEN notification.notification_hour >= 4 THEN 3
                        WHEN notification.notification_hour >= 2 THEN 2
                        ELSE 1 END
                )
                    AND (policy.Location IS NULL OR timed_tier.Tier <= timed.maximum_tier)
          );

        UPDATE queue
           SET queue.error_message = 'No eligible snapshot recipients; verify memberships, phone numbers, and contact tiers.'
        FROM dbo.SMS_Queue AS queue
        WHERE queue.is_processed = 0
          AND NOT EXISTS (SELECT 1 FROM #Handoff AS handoff WHERE handoff.queue_id = queue.queue_id);

        INSERT INTO @Selected (queue_id)
        SELECT TOP (10) queue.queue_id
        FROM dbo.SMS_Queue AS queue
        WHERE queue.is_processed = 0
          AND EXISTS (SELECT 1 FROM #Handoff AS handoff WHERE handoff.queue_id = queue.queue_id)
        ORDER BY queue.queue_id;

        DELETE handoff FROM #Handoff AS handoff
        WHERE NOT EXISTS (SELECT 1 FROM @Selected AS selected WHERE selected.queue_id = handoff.queue_id);

        IF NOT EXISTS (SELECT 1 FROM @Selected) RETURN;

        EXEC sys.sp_executesql N'
            INSERT INTO [POSTGRESQL30].[spooldb].[public].[odbc_queue]
                (mobile_numb, msg_from, msg_content, created_dtm, inter_fmt, [priority], modem_label)
            SELECT mobile_numb, msg_from, msg_content, GETDATE(), ''1'', ''1'', ''''
            FROM #Handoff;';

        BEGIN TRANSACTION;

        UPDATE queue
           SET queue.is_processed = 1, queue.processed_dtm = GETDATE(), queue.error_message = NULL
        FROM dbo.SMS_Queue AS queue
        INNER JOIN @Selected AS selected ON selected.queue_id = queue.queue_id;

        UPDATE target
           SET target.val = 0, target.is_sms_sent = 0,
               target.abnormal_started_dtm = NULL, target.last_queued_hour = 0
        FROM dbo.PERMS_logs_SMS AS target
        INNER JOIN dbo.PERMS_SMS_Notification AS notification
            ON notification.source_id = target.id AND notification.alarm_sequence = target.alarm_sequence
        INNER JOIN @Selected AS selected ON selected.queue_id = notification.queue_id
        WHERE notification.Location <> 'MCR' AND notification.notification_hour = 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        UPDATE queue SET queue.error_message = ERROR_MESSAGE()
        FROM dbo.SMS_Queue AS queue
        INNER JOIN @Selected AS selected ON selected.queue_id = queue.queue_id
        WHERE queue.is_processed = 0;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.Run_PERMS_SMS_Cycle
    @Send BIT = 0,
    @BatchSize INT = 1000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @LockResult INT;

    IF @@TRANCOUNT <> 0 THROW 51219, 'Run the SMS cycle outside an existing transaction.', 1;

    EXEC @LockResult = sys.sp_getapplock
        @Resource = N'PERMS_SMS_159_Pipeline', @LockMode = 'Exclusive',
        @LockOwner = 'Session', @LockTimeout = 0;
    IF @LockResult < 0 THROW 51220, 'Another PERMS_SMS cycle is running; retry later.', 1;

    BEGIN TRY
        IF EXISTS
        (
            SELECT 1 FROM sys.triggers
            WHERE parent_id = OBJECT_ID(N'dbo.PERMS_logs_SMS') AND is_disabled = 0
        )
            THROW 51221, 'Disable legacy triggers in PERMS_SMS before running this polling design.', 1;

        EXEC dbo.Import_PERMS_Readings @BatchSize = @BatchSize;
        EXEC dbo.Queue_PERMS_Notifications;
        IF @Send = 1 EXEC dbo.Process_PERMS_SMS_Queue;

        EXEC sys.sp_releaseapplock @Resource = N'PERMS_SMS_159_Pipeline', @LockOwner = 'Session';
    END TRY
    BEGIN CATCH
        EXEC sys.sp_releaseapplock @Resource = N'PERMS_SMS_159_Pipeline', @LockOwner = 'Session';
        THROW;
    END CATCH;
END;
GO
SET NOEXEC OFF;
GO