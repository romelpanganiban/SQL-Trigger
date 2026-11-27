USE [AIM_DB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE dbo.Process_PERMS_SMS_Queue
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @@TRANCOUNT <> 0
        THROW 51001, 'Run the SMS processor outside an existing transaction.', 1;

    DECLARE @LockResult INT;
    DECLARE @Now DATETIME2(0);
    DECLARE @ToProcess TABLE
    (
        queue_id INT NOT NULL PRIMARY KEY,
        source_id INT NOT NULL
    );
    DECLARE @Recipients TABLE
    (
        queue_id INT NOT NULL,
        mobile_numb VARCHAR(50) NOT NULL,
        PRIMARY KEY (queue_id, mobile_numb)
    );

    EXEC @LockResult = sys.sp_getapplock
        @Resource = N'PERMS_SMS_QueueProcessor',
        @LockMode = 'Exclusive',
        @LockOwner = 'Session',
        @LockTimeout = 0;

    IF @LockResult < 0 RETURN;

    BEGIN TRY
        EXEC dbo.Queue_PERMS_MCR_Escalations;
        SET @Now = SYSDATETIME();

        UPDATE queue
           SET queue.is_processed = 1,
               queue.processed_dtm = GETDATE(),
               queue.error_message = 'Cancelled TR alert: device not ready or deactivated.'
        FROM dbo.SMS_Queue AS queue
        INNER JOIN dbo.PERMS_logs_SMS AS target
            ON target.id = queue.source_id
        INNER JOIN dbo.PERMS_TR_Device AS device
            ON device.device_name = target.device_name
        WHERE queue.is_processed = 0
          AND (device.alerts_enabled = 0 OR ISNULL(target.is_activated, 0) <> 1);

        UPDATE queue
           SET queue.is_processed = 1,
               queue.processed_dtm = GETDATE(),
               queue.error_message = 'Cancelled legacy MCR alert: replaced by timed escalation.'
        FROM dbo.SMS_Queue AS queue
        INNER JOIN dbo.PERMS_logs_SMS AS target
            ON target.id = queue.source_id
        INNER JOIN dbo.PERMS_MCR_Device AS device
            ON device.device_name = target.device_name
        WHERE queue.is_processed = 0
          AND NOT EXISTS
          (
              SELECT 1 FROM dbo.PERMS_MCR_Notification AS notification
              WHERE notification.queue_id = queue.queue_id
          );

        UPDATE queue
           SET queue.is_processed = 1,
               queue.processed_dtm = GETDATE(),
               queue.error_message = 'Cancelled MCR reminder: alarm ended, reading stale, or hour superseded.'
        FROM dbo.SMS_Queue AS queue
        INNER JOIN dbo.PERMS_MCR_Notification AS notification
            ON notification.queue_id = queue.queue_id
        WHERE queue.is_processed = 0
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.PERMS_MCR_DueAlarm(@Now) AS alarm
              WHERE alarm.source_id = notification.source_id
                AND alarm.alarm_sequence = notification.alarm_sequence
                AND alarm.notification_hour = notification.notification_hour
          );

        INSERT INTO @Recipients (queue_id, mobile_numb)
        SELECT queue.queue_id, LTRIM(RTRIM(contact.CellNumber))
        FROM dbo.SMS_Queue AS queue
        INNER JOIN dbo.PMUserGroup AS membership
            ON membership.PMContactGroup = queue.pm_user_group
        INNER JOIN dbo.PMContacts AS contact
            ON contact.ID = membership.PmContactID
        WHERE queue.is_processed = 0
          AND NULLIF(LTRIM(RTRIM(contact.CellNumber)), '') IS NOT NULL
          AND NOT EXISTS
          (
              SELECT 1 FROM dbo.PERMS_MCR_Notification AS notification
              WHERE notification.queue_id = queue.queue_id
          )
        UNION
        SELECT queue.queue_id, recipient.mobile_numb
        FROM dbo.SMS_Queue AS queue
        INNER JOIN dbo.PERMS_MCR_NotificationRecipient AS recipient
            ON recipient.queue_id = queue.queue_id
        WHERE queue.is_processed = 0
          AND EXISTS
          (
              SELECT 1
              FROM dbo.PMUserGroup AS membership
              INNER JOIN dbo.PMContacts AS contact
                  ON contact.ID = membership.PmContactID
              WHERE membership.PMContactGroup = queue.pm_user_group
                AND LTRIM(RTRIM(contact.CellNumber)) = recipient.mobile_numb
          );

        UPDATE queue
           SET queue.error_message = 'No valid recipients: check group membership, tiers, and phone numbers.'
        FROM dbo.SMS_Queue AS queue
        WHERE queue.is_processed = 0
          AND NOT EXISTS
          (
              SELECT 1 FROM @Recipients AS recipient
              WHERE recipient.queue_id = queue.queue_id
          );

        INSERT INTO @ToProcess (queue_id, source_id)
        SELECT TOP (10) queue.queue_id, queue.source_id
        FROM dbo.SMS_Queue AS queue
        WHERE queue.is_processed = 0
          AND EXISTS
          (
              SELECT 1 FROM @Recipients AS recipient
              WHERE recipient.queue_id = queue.queue_id
          )
        ORDER BY queue.queue_id;

        IF EXISTS (SELECT 1 FROM @ToProcess)
        BEGIN
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
            SELECT
                recipient.mobile_numb,
                queue.msg_from,
                queue.msg_content,
                GETDATE(),
                '1',
                '1',
                ''
            FROM dbo.SMS_Queue AS queue
            INNER JOIN @ToProcess AS selected
                ON selected.queue_id = queue.queue_id
            INNER JOIN @Recipients AS recipient
                ON recipient.queue_id = queue.queue_id;

            BEGIN TRANSACTION;

            UPDATE queue
               SET queue.is_processed = 1,
                   queue.processed_dtm = GETDATE(),
                   queue.error_message = NULL
            FROM dbo.SMS_Queue AS queue
            INNER JOIN @ToProcess AS selected
                ON selected.queue_id = queue.queue_id;

            UPDATE target
               SET target.val = 0,
                   target.is_sms_sent = 0
            FROM dbo.PERMS_logs_SMS AS target
            INNER JOIN @ToProcess AS selected
                ON selected.source_id = target.id
            WHERE NOT EXISTS
            (
                SELECT 1
                FROM dbo.PERMS_MCR_Device AS device
                WHERE device.device_name = target.device_name
            );

            COMMIT TRANSACTION;
        END;

        EXEC sys.sp_releaseapplock
            @Resource = N'PERMS_SMS_QueueProcessor', @LockOwner = 'Session';
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        UPDATE queue
           SET queue.error_message = ERROR_MESSAGE()
        FROM dbo.SMS_Queue AS queue
        INNER JOIN @ToProcess AS selected
            ON selected.queue_id = queue.queue_id
        WHERE queue.is_processed = 0;

        EXEC sys.sp_releaseapplock
            @Resource = N'PERMS_SMS_QueueProcessor', @LockOwner = 'Session';
        THROW;
    END CATCH;
END;
GO