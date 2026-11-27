USE [AIM_DB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID(N'dbo.PERMS_MCR_DueAlarm', N'IF') IS NULL
    EXEC(N'CREATE FUNCTION dbo.PERMS_MCR_DueAlarm(@Now DATETIME2(0))
           RETURNS TABLE AS RETURN (SELECT CAST(NULL AS INT) AS source_id WHERE 1 = 0);');
GO

ALTER FUNCTION dbo.PERMS_MCR_DueAlarm(@Now DATETIME2(0))
RETURNS TABLE
AS
RETURN
(
    SELECT
        target.id AS source_id,
        target.device_name,
        target.temperature,
        target.date_time,
        device.AreaName,
        device.MachineName,
        state.alarm_sequence,
        state.abnormal_started_dtm,
        state.last_queued_hour,
        contact_group.ID AS pm_user_group,
        elapsed.notification_hour,
        CASE
            WHEN elapsed.notification_hour >= 4 THEN 3
            WHEN elapsed.notification_hour >= 2 THEN 2
            ELSE 1
        END AS maximum_tier
    FROM dbo.PERMS_MCR_AlarmState AS state
    INNER JOIN dbo.PERMS_logs_SMS AS target
        ON target.id = state.source_id
    INNER JOIN dbo.PERMS_MCR_Device AS device
        ON device.device_name = target.device_name
    INNER JOIN dbo.PMContactGroup AS contact_group
        ON LTRIM(RTRIM(contact_group.Location)) = 'MCR'
       AND LTRIM(RTRIM(contact_group.App)) = 'PERMS'
    CROSS APPLY
    (
        SELECT CONVERT(INT, FLOOR(ISNULL(target.val, 0) / 30.0)) AS notification_hour
    ) AS elapsed
    WHERE state.abnormal_started_dtm IS NOT NULL
      AND state.abnormal_started_dtm <= @Now
      AND @Now <= DATEADD(MINUTE, device.max_reading_age_minutes, state.last_observed_dtm)
      AND ISNULL(target.is_activated, 0) = 1
      AND TRY_CONVERT(DECIMAL(10, 2), target.temperature)
          NOT BETWEEN device.min_temp AND device.max_temp
);
GO

IF OBJECT_ID(N'dbo.Queue_PERMS_MCR_Escalations', N'P') IS NULL
    EXEC(N'CREATE PROCEDURE dbo.Queue_PERMS_MCR_Escalations AS RETURN;');
GO

ALTER PROCEDURE dbo.Queue_PERMS_MCR_Escalations
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(0) = SYSDATETIME();
    DECLARE @LockResult INT;
    DECLARE @OwnTransaction BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    DECLARE @LockedSources TABLE (source_id INT NOT NULL PRIMARY KEY);
    DECLARE @Due TABLE
    (
        source_id INT NOT NULL PRIMARY KEY,
        alarm_sequence BIGINT NOT NULL,
        notification_hour INT NOT NULL,
        maximum_tier INT NOT NULL,
        pm_user_group INT NOT NULL,
        msg_content VARCHAR(MAX) NOT NULL
    );
    DECLARE @Recipients TABLE
    (
        source_id INT NOT NULL,
        mobile_numb VARCHAR(50) NOT NULL,
        PRIMARY KEY (source_id, mobile_numb)
    );
    DECLARE @NewQueues TABLE
    (
        queue_id INT NOT NULL PRIMARY KEY,
        source_id INT NOT NULL UNIQUE
    );

    BEGIN TRY
        IF @OwnTransaction = 1
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION PERMS_MCR_SchedulerSave;

        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'PERMS_MCR_EscalationScheduler',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 0;

        IF @LockResult < 0
        BEGIN
            IF @OwnTransaction = 1
                ROLLBACK TRANSACTION;
            ELSE
                ROLLBACK TRANSACTION PERMS_MCR_SchedulerSave;
            RETURN;
        END;

        IF
        (
            SELECT COUNT(*)
            FROM dbo.PMContactGroup
            WHERE LTRIM(RTRIM(Location)) = 'MCR'
              AND LTRIM(RTRIM(App)) = 'PERMS'
        ) <> 1
            THROW 51000, 'Exactly one MCR / PERMS contact group is required.', 1;

        INSERT INTO @LockedSources (source_id)
        SELECT target.id
        FROM dbo.PERMS_logs_SMS AS target WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN dbo.PERMS_MCR_Device AS device
            ON device.device_name = target.device_name;

        INSERT INTO @Due
            (source_id, alarm_sequence, notification_hour, maximum_tier, pm_user_group, msg_content)
        SELECT
            alarm.source_id,
            alarm.alarm_sequence,
            alarm.notification_hour,
            alarm.maximum_tier,
            alarm.pm_user_group,
            'PERMS INFORMATION' + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10)
            + 'Location: MCR' + CHAR(13) + CHAR(10)
            + 'Area: ' + alarm.AreaName + CHAR(13) + CHAR(10)
            + 'Device Name: ' + alarm.device_name + CHAR(13) + CHAR(10)
            + 'Machine: ' + alarm.MachineName + CHAR(13) + CHAR(10)
            + 'Temperature: ' + ISNULL(CONVERT(VARCHAR(50), alarm.temperature), '')
            + CHAR(13) + CHAR(10)
            + 'Date: ' + ISNULL(CONVERT(VARCHAR(19), alarm.date_time, 120), '')
            + CHAR(13) + CHAR(10)
            + 'Abnormal since: ' + CONVERT(VARCHAR(19), alarm.abnormal_started_dtm, 120)
            + CHAR(13) + CHAR(10)
            + 'Counter-based hours (2 min/reading): ' + CONVERT(VARCHAR(12), alarm.notification_hour)
            + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10)
            + '[This is an automated message please do not reply]'
        FROM dbo.PERMS_MCR_DueAlarm(@Now) AS alarm
        WHERE alarm.notification_hour >= 1
          AND alarm.notification_hour > alarm.last_queued_hour;

        INSERT INTO @Recipients (source_id, mobile_numb)
        SELECT DISTINCT due.source_id, LTRIM(RTRIM(contact.CellNumber))
        FROM @Due AS due
        INNER JOIN dbo.PMUserGroup AS membership
            ON membership.PMContactGroup = due.pm_user_group
        INNER JOIN dbo.PERMS_MCR_ContactTier AS tier
            ON tier.PmContactID = membership.PmContactID
           AND tier.Tier <= due.maximum_tier
        INNER JOIN dbo.PMContacts AS contact
            ON contact.ID = membership.PmContactID
        WHERE NULLIF(LTRIM(RTRIM(contact.CellNumber)), '') IS NOT NULL;

        DELETE due
        FROM @Due AS due
        WHERE NOT EXISTS
        (
            SELECT 1 FROM @Recipients AS recipient
            WHERE recipient.source_id = due.source_id
        );

        INSERT INTO dbo.SMS_Queue (source_id, pm_user_group, msg_from, msg_content)
        OUTPUT inserted.queue_id, inserted.source_id INTO @NewQueues (queue_id, source_id)
        SELECT source_id, pm_user_group, 'PostgreSQL', msg_content
        FROM @Due;

        INSERT INTO dbo.PERMS_MCR_Notification
            (queue_id, source_id, alarm_sequence, notification_hour)
        SELECT queue.queue_id, due.source_id, due.alarm_sequence, due.notification_hour
        FROM @NewQueues AS queue
        INNER JOIN @Due AS due ON due.source_id = queue.source_id;

        INSERT INTO dbo.PERMS_MCR_NotificationRecipient (queue_id, mobile_numb)
        SELECT queue.queue_id, recipient.mobile_numb
        FROM @NewQueues AS queue
        INNER JOIN @Recipients AS recipient ON recipient.source_id = queue.source_id;

        UPDATE state
           SET state.last_queued_hour = due.notification_hour
        FROM dbo.PERMS_MCR_AlarmState AS state
        INNER JOIN @Due AS due ON due.source_id = state.source_id;

        UPDATE target
           SET target.is_sms_sent = 1
        FROM dbo.PERMS_logs_SMS AS target
        INNER JOIN @NewQueues AS queue ON queue.source_id = target.id;

        IF @OwnTransaction = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1
            ROLLBACK TRANSACTION;
        ELSE IF XACT_STATE() = 1
        BEGIN
            IF @OwnTransaction = 1
                ROLLBACK TRANSACTION;
            ELSE
                ROLLBACK TRANSACTION PERMS_MCR_SchedulerSave;
        END;
        THROW;
    END CATCH;
END;
GO