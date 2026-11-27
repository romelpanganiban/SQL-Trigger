USE [PERMS_SMS]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF DB_NAME() <> N'PERMS_SMS'
 OR OBJECT_ID(N'dbo.PERMS_SMS_Control', N'U') IS NULL
 OR OBJECT_ID(N'dbo.PERMS_SMS_EscalationPolicy', N'U') IS NULL
 OR OBJECT_ID(N'dbo.PERMS_SMS_ContactTier', N'U') IS NULL
BEGIN
    RAISERROR('Stop: select PERMS_SMS and complete 01_local_setup.sql first.', 16, 1);
    SET NOEXEC ON;
END;
GO

CREATE OR ALTER FUNCTION dbo.PERMS_SMS_Counter
(
    @Previous INT,
    @Temperature NVARCHAR(50),
    @Minimum DECIMAL(10, 2),
    @Maximum DECIMAL(10, 2),
    @Activated BIT,
    @Enabled BIT
)
RETURNS TABLE
AS
RETURN
(
    SELECT CASE
        WHEN @Activated = 1 AND @Enabled = 1
         AND TRY_CONVERT(DECIMAL(10, 2), @Temperature) NOT BETWEEN @Minimum AND @Maximum
            THEN ISNULL(@Previous, 0) + 1
        ELSE 0
    END AS new_val
);
GO

CREATE OR ALTER FUNCTION dbo.PERMS_SMS_Tier(@Counter INT)
RETURNS TABLE
AS
RETURN
(
    SELECT
        ISNULL(@Counter, 0) / 30 AS notification_hour,
        CASE WHEN @Counter >= 120 THEN 3 WHEN @Counter >= 60 THEN 2 ELSE 1 END AS maximum_tier
);
GO

CREATE OR ALTER FUNCTION dbo.PERMS_SMS_TimedTier
(
    @Started DATETIME,
    @Now DATETIME,
    @Tier1Minutes INT,
    @Tier2Minutes INT,
    @Tier3Minutes INT,
    @RepeatMinutes INT
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        -1 - CONVERT(INT, stage.start_minutes
            + ((elapsed.minutes - stage.start_minutes) / NULLIF(@RepeatMinutes, 0))
              * @RepeatMinutes) AS notification_hour,
        stage.maximum_tier
    FROM (SELECT DATEDIFF_BIG(SECOND, @Started, @Now) / 60 AS minutes) AS elapsed
    CROSS APPLY
    (
        SELECT
            CASE WHEN elapsed.minutes >= @Tier3Minutes THEN @Tier3Minutes
                 WHEN elapsed.minutes >= @Tier2Minutes THEN @Tier2Minutes
                 ELSE @Tier1Minutes END AS start_minutes,
            CASE WHEN elapsed.minutes >= @Tier3Minutes THEN 3
                 WHEN elapsed.minutes >= @Tier2Minutes THEN 2
                 ELSE 1 END AS maximum_tier
    ) AS stage
    WHERE @Now >= @Started AND elapsed.minutes >= @Tier1Minutes
);
GO

CREATE OR ALTER PROCEDURE dbo.Initialize_PERMS_SMS
    @StartAfterID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @LockResult INT;

    IF @@TRANCOUNT <> 0
        THROW 51204, 'Initialize outside an existing transaction, with source ingestion briefly paused.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'PERMS_SMS_159_Pipeline', @LockMode = 'Exclusive',
            @LockOwner = 'Transaction', @LockTimeout = 0;
        IF @LockResult < 0 THROW 51205, 'Another SMS cycle is running.', 1;

        IF EXISTS (SELECT 1 FROM dbo.PERMS_SMS_Control WHERE start_after_id IS NOT NULL)
            THROW 51206, 'Already initialized. The cutover is not automatically advanced or reset.', 1;

        IF @StartAfterID IS NULL
            SELECT @StartAfterID = ISNULL(MAX(id), 0)
            FROM [PERMS].[dbo].[PERMS_logs] WITH (READCOMMITTEDLOCK);

        IF @StartAfterID < 0 THROW 51207, 'The starting reading ID cannot be negative.', 1;

        UPDATE dbo.PERMS_SMS_Control
           SET start_after_id = @StartAfterID,
               initialized_dtm = SYSDATETIME(),
               sending_enabled = 0
        WHERE control_id = 1;

        COMMIT TRANSACTION;
        SELECT start_after_id, sending_enabled, initialized_dtm FROM dbo.PERMS_SMS_Control;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.Import_PERMS_Readings
    @BatchSize INT = 1000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @StartAfterID INT = (SELECT start_after_id FROM dbo.PERMS_SMS_Control WHERE control_id = 1);
    DECLARE @ReadingID INT;
    DECLARE @MasterID INT;
    DECLARE @Previous INT;
    DECLARE @Next INT;
    DECLARE @Temperature NVARCHAR(50);
    DECLARE @Humidity NVARCHAR(50);
    DECLARE @ReadingDate DATETIME;
    DECLARE @Status VARCHAR(30);

    IF @@TRANCOUNT <> 0 THROW 51208, 'Run the importer outside an existing transaction.', 1;
    IF APPLOCK_MODE(N'public', N'PERMS_SMS_159_Pipeline', N'Session') <> N'Exclusive'
        THROW 51213, 'Use Run_PERMS_SMS_Cycle so concurrent imports cannot overlap.', 1;
    IF @StartAfterID IS NULL THROW 51209, 'Run Initialize_PERMS_SMS before importing readings.', 1;
    IF @BatchSize < 1 OR @BatchSize > 10000 THROW 51210, 'BatchSize must be between 1 and 10000.', 1;
    IF ISNULL((SELECT MAX(id) FROM [PERMS].[dbo].[PERMS_logs]), 0)
       < ISNULL((SELECT MAX(reading_id) FROM dbo.PERMS_SMS_ImportedReading), @StartAfterID)
        THROW 51223, 'Source reading IDs have moved backwards or the log was emptied. Reconcile the cutover before proceeding.', 1;

    DECLARE @Readings TABLE
    (
        reading_id INT NOT NULL PRIMARY KEY,
        master_device_id INT NULL,
        temperature NVARCHAR(50) NULL,
        humidity NVARCHAR(50) NULL,
        date_time DATETIME NULL
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO dbo.PERMS_logs_SMS (id, device_name, is_activated)
        SELECT master.id, ISNULL(master.device_name, N''), ISNULL(master.is_activated, 0)
        FROM [PERMS].[dbo].[PERMS_master] AS master
        WHERE NOT EXISTS (SELECT 1 FROM dbo.PERMS_logs_SMS AS target WHERE target.id = master.id);

        UPDATE target
           SET target.device_name = ISNULL(master.device_name, N''),
               target.is_activated = ISNULL(master.is_activated, 0),
               target.val = CASE
                   WHEN ISNULL(master.is_activated, 0) = 0
                     OR target.device_name <> ISNULL(master.device_name, N'') COLLATE DATABASE_DEFAULT
                       THEN 0 ELSE target.val END,
               target.is_sms_sent = CASE
                   WHEN ISNULL(master.is_activated, 0) = 0
                     OR target.device_name <> ISNULL(master.device_name, N'') COLLATE DATABASE_DEFAULT
                       THEN 0 ELSE target.is_sms_sent END,
               target.abnormal_started_dtm = CASE
                   WHEN ISNULL(master.is_activated, 0) = 0
                     OR target.device_name <> ISNULL(master.device_name, N'') COLLATE DATABASE_DEFAULT
                       THEN NULL ELSE target.abnormal_started_dtm END,
               target.last_queued_hour = CASE
                   WHEN ISNULL(master.is_activated, 0) = 0
                     OR target.device_name <> ISNULL(master.device_name, N'') COLLATE DATABASE_DEFAULT
                       THEN 0 ELSE target.last_queued_hour END
        FROM dbo.PERMS_logs_SMS AS target
        INNER JOIN [PERMS].[dbo].[PERMS_master] AS master ON master.id = target.id;

        UPDATE target
           SET target.is_activated = 0, target.val = 0, target.is_sms_sent = 0,
               target.abnormal_started_dtm = NULL, target.last_queued_hour = 0
        FROM dbo.PERMS_logs_SMS AS target
        WHERE NOT EXISTS
        (
            SELECT 1 FROM [PERMS].[dbo].[PERMS_master] AS master WHERE master.id = target.id
        );

        INSERT INTO @Readings (reading_id, master_device_id, temperature, humidity, date_time)
        SELECT TOP (@BatchSize)
            reading.id, master.id, reading.temperature, reading.humidity, reading.date_time
        FROM [PERMS].[dbo].[PERMS_logs] AS reading WITH (READCOMMITTEDLOCK)
        LEFT JOIN [PERMS].[dbo].[PERMS_master] AS master
            ON master.id = TRY_CONVERT(INT, reading.device_name)
        WHERE reading.id > @StartAfterID
          AND NOT EXISTS
          (
              SELECT 1 FROM dbo.PERMS_SMS_ImportedReading AS imported
              WHERE imported.reading_id = reading.id
          )
        ORDER BY reading.id;

        DECLARE reading_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT reading_id, master_device_id, temperature, humidity, date_time
            FROM @Readings ORDER BY reading_id;

        OPEN reading_cursor;
        FETCH NEXT FROM reading_cursor INTO @ReadingID, @MasterID, @Temperature, @Humidity, @ReadingDate;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Status = 'Missing master';

            IF @MasterID IS NOT NULL
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM dbo.PERMS_logs_SMS WHERE id = @MasterID)
                    THROW 51211, 'Source master changed during import. Retry the cycle.', 1;

                SELECT @Previous = target.val,
                       @Next = counter.new_val,
                       @Status = CASE
                           WHEN device_rule.device_name IS NULL THEN 'No device rule'
                           WHEN device_rule.alerts_enabled = 0 OR target.is_activated = 0 THEN 'Disabled'
                           WHEN TRY_CONVERT(DECIMAL(10, 2), @Temperature) IS NULL THEN 'Invalid temperature'
                           ELSE 'Processed'
                       END
                FROM dbo.PERMS_logs_SMS AS target
                LEFT JOIN dbo.PERMS_SMS_DeviceRule AS device_rule ON device_rule.device_name = target.device_name
                CROSS APPLY dbo.PERMS_SMS_Counter
                    (target.val, @Temperature, device_rule.min_temp, device_rule.max_temp,
                     target.is_activated, ISNULL(device_rule.alerts_enabled, 0)) AS counter
                WHERE target.id = @MasterID;

                UPDATE dbo.PERMS_logs_SMS
                   SET temperature = @Temperature,
                       humidity = @Humidity,
                       date_time = @ReadingDate,
                       val = @Next,
                       alarm_sequence = alarm_sequence + CASE WHEN @Previous = 0 AND @Next > 0 THEN 1 ELSE 0 END,
                       abnormal_started_dtm = CASE
                           WHEN @Next = 0 THEN NULL
                           WHEN @Previous = 0 THEN @ReadingDate
                           ELSE abnormal_started_dtm END,
                       last_queued_hour = CASE WHEN @Next = 0 THEN 0 ELSE last_queued_hour END,
                       is_sms_sent = CASE WHEN @Next = 0 THEN 0 ELSE is_sms_sent END,
                       last_reading_id = @ReadingID
                WHERE id = @MasterID
                  AND (last_reading_id IS NULL OR @ReadingID > last_reading_id);

                IF @@ROWCOUNT = 0 SET @Status = 'Older source ID';
            END;

            INSERT INTO dbo.PERMS_SMS_ImportedReading (reading_id, master_device_id, import_status)
            VALUES (@ReadingID, @MasterID, @Status);

            FETCH NEXT FROM reading_cursor INTO @ReadingID, @MasterID, @Temperature, @Humidity, @ReadingDate;
        END;

        CLOSE reading_cursor;
        DEALLOCATE reading_cursor;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'reading_cursor') >= 0 CLOSE reading_cursor;
        IF CURSOR_STATUS('local', 'reading_cursor') >= -1 DEALLOCATE reading_cursor;
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.Queue_PERMS_Notifications
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF APPLOCK_MODE(N'public', N'PERMS_SMS_159_Pipeline', N'Session') <> N'Exclusive'
        THROW 51214, 'Use Run_PERMS_SMS_Cycle so queueing is serialized with import and delivery.', 1;
    DECLARE @Now DATETIME = GETDATE();
    DECLARE @Due TABLE
    (
        source_id INT NOT NULL PRIMARY KEY,
        alarm_sequence BIGINT NOT NULL,
        notification_hour INT NOT NULL,
        Location VARCHAR(10) NOT NULL,
        pm_user_group INT NOT NULL,
        maximum_tier INT NOT NULL,
        msg_content VARCHAR(MAX) NOT NULL
    );
    DECLARE @Recipients TABLE
    (
        source_id INT NOT NULL,
        mobile_numb VARCHAR(50) NOT NULL,
        PRIMARY KEY (source_id, mobile_numb)
    );
    DECLARE @Queues TABLE (queue_id INT NOT NULL PRIMARY KEY, source_id INT NOT NULL UNIQUE);

    BEGIN TRY
        BEGIN TRANSACTION;

        IF EXISTS
        (
            SELECT Location FROM dbo.PMContactGroup WHERE App = 'PERMS'
            GROUP BY Location HAVING COUNT(*) > 1
        )
            THROW 51212, 'Duplicate PERMS contact groups exist for a location.', 1;

        INSERT INTO @Due
            (source_id, alarm_sequence, notification_hour, Location, pm_user_group, maximum_tier, msg_content)
        SELECT
            target.id, target.alarm_sequence, notification.notification_hour,
            device_rule.Location, contact_group.ID, notification.maximum_tier,
            'PERMS INFORMATION' + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10)
            + 'Location: ' + device_rule.Location + CHAR(13) + CHAR(10)
            + 'Area: ' + CONVERT(VARCHAR(100), device_rule.AreaName) + CHAR(13) + CHAR(10)
            + 'Device Name: ' + CONVERT(VARCHAR(50), target.device_name) + CHAR(13) + CHAR(10)
            + 'Machine: ' + CONVERT(VARCHAR(50), device_rule.MachineName) + CHAR(13) + CHAR(10)
            + 'Temperature: ' + ISNULL(CONVERT(VARCHAR(50), target.temperature), '') + CHAR(13) + CHAR(10)
            + 'Date: ' + CONVERT(VARCHAR(19), target.date_time, 120) + CHAR(13) + CHAR(10)
            + 'Abnormal readings: ' + CONVERT(VARCHAR(12), target.val) + CHAR(13) + CHAR(10)
            + '[This is an automated message please do not reply]'
        FROM dbo.PERMS_logs_SMS AS target WITH (UPDLOCK, HOLDLOCK)
        INNER JOIN dbo.PERMS_SMS_DeviceRule AS device_rule ON device_rule.device_name = target.device_name
        INNER JOIN dbo.PMContactGroup AS contact_group
            ON LTRIM(RTRIM(contact_group.Location)) = device_rule.Location
           AND LTRIM(RTRIM(contact_group.App)) = 'PERMS'
        LEFT JOIN dbo.PERMS_SMS_EscalationPolicy AS policy
            ON policy.Location = device_rule.Location AND policy.enabled = 1
        CROSS APPLY dbo.PERMS_SMS_Tier(target.val) AS tier
        OUTER APPLY dbo.PERMS_SMS_TimedTier
            (target.abnormal_started_dtm, @Now, policy.tier1_minutes,
             policy.tier2_minutes, policy.tier3_minutes, policy.repeat_minutes) AS timed
        CROSS APPLY
        (
            SELECT CASE WHEN device_rule.Location = 'MCR' THEN tier.notification_hour
                        WHEN policy.Location IS NOT NULL THEN timed.notification_hour
                        ELSE 0 END AS notification_hour,
                   CASE WHEN policy.Location IS NOT NULL THEN timed.maximum_tier
                        ELSE tier.maximum_tier END AS maximum_tier
        ) AS notification
                WHERE target.is_activated = 1 AND device_rule.alerts_enabled = 1
                    AND TRY_CONVERT(DECIMAL(10, 2), target.temperature) NOT BETWEEN device_rule.min_temp AND device_rule.max_temp
          AND target.date_time <= @Now
                    AND @Now <= DATEADD(MINUTE, device_rule.max_reading_age_minutes, target.date_time)
          AND target.last_reading_id IS NOT NULL
                    AND ((device_rule.Location = 'MCR' AND target.val >= 30)
                        OR (device_rule.Location <> 'MCR' AND policy.Location IS NULL AND target.val >= 10)
                        OR (policy.Location IS NOT NULL AND target.val > 0 AND timed.notification_hour IS NOT NULL))
          AND NOT EXISTS
          (
              SELECT 1 FROM dbo.PERMS_SMS_Notification AS existing
              WHERE existing.source_id = target.id
                AND existing.alarm_sequence = target.alarm_sequence
                AND existing.notification_hour = notification.notification_hour
          );

        INSERT INTO @Recipients (source_id, mobile_numb)
        SELECT DISTINCT due.source_id, LTRIM(RTRIM(contact.CellNumber))
        FROM @Due AS due
        INNER JOIN dbo.PMUserGroup AS membership ON membership.PMContactGroup = due.pm_user_group
        INNER JOIN dbo.PMContacts AS contact ON contact.ID = membership.PmContactID
        LEFT JOIN dbo.PERMS_MCR_ContactTier AS tier ON tier.PmContactID = contact.ID
                LEFT JOIN dbo.PERMS_SMS_EscalationPolicy AS policy
                        ON policy.Location = due.Location AND policy.enabled = 1
                LEFT JOIN dbo.PERMS_SMS_ContactTier AS timed_tier
                        ON timed_tier.Location = due.Location AND timed_tier.PmContactID = contact.ID
        WHERE NULLIF(LTRIM(RTRIM(contact.CellNumber)), '') IS NOT NULL
                    AND (due.Location <> 'MCR' OR tier.Tier <= due.maximum_tier)
                    AND (policy.Location IS NULL OR timed_tier.Tier <= due.maximum_tier);

        DELETE due FROM @Due AS due
        WHERE NOT EXISTS (SELECT 1 FROM @Recipients AS recipient WHERE recipient.source_id = due.source_id);

        INSERT INTO dbo.SMS_Queue (source_id, pm_user_group, msg_from, msg_content)
        OUTPUT inserted.queue_id, inserted.source_id INTO @Queues (queue_id, source_id)
        SELECT source_id, pm_user_group, 'PostgreSQL', msg_content FROM @Due;

        INSERT INTO dbo.PERMS_SMS_Notification
            (queue_id, source_id, alarm_sequence, notification_hour, Location)
        SELECT queue.queue_id, due.source_id, due.alarm_sequence, due.notification_hour, due.Location
        FROM @Queues AS queue INNER JOIN @Due AS due ON due.source_id = queue.source_id;

        INSERT INTO dbo.PERMS_SMS_Recipient (queue_id, mobile_numb)
        SELECT queue.queue_id, recipient.mobile_numb
        FROM @Queues AS queue INNER JOIN @Recipients AS recipient ON recipient.source_id = queue.source_id;

        UPDATE target
           SET target.is_sms_sent = 1, target.last_queued_hour = due.notification_hour
        FROM dbo.PERMS_logs_SMS AS target INNER JOIN @Due AS due ON due.source_id = target.id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
SET NOEXEC OFF;
GO