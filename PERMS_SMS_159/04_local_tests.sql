USE [PERMS_SMS]
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'PERMS_SMS' OR OBJECT_ID(N'dbo.PERMS_SMS_Control', N'U') IS NULL
    THROW 51300, 'Install the new polling schema in PERMS_SMS before testing.', 1;
IF @@TRANCOUNT <> 0 THROW 51301, 'Run tests outside an existing transaction.', 1;
IF EXISTS (SELECT 1 FROM dbo.PERMS_SMS_Control WHERE sending_enabled = 1)
    THROW 51302, 'Disable sending before running these staging tests.', 1;
IF EXISTS
(
    SELECT 1 FROM sys.triggers
    WHERE parent_id = OBJECT_ID(N'dbo.PERMS_logs_SMS') AND is_disabled = 0
)
    THROW 51303, 'This polling design must not have local status-table triggers.', 1;

IF EXISTS
(
    SELECT 1
    FROM
    (
        VALUES
            (0, N'-31', -30.00, -20.00, 1, 1, 1),
            (9, N'-19', -30.00, -20.00, 1, 1, 10),
            (29, N'-19', -30.00, -20.00, 1, 1, 30),
            (59, N'-19', -30.00, -20.00, 1, 1, 60),
            (9, N'-30', -30.00, -20.00, 1, 1, 0),
            (9, N'-20', -30.00, -20.00, 1, 1, 0),
            (9, N'-21', -30.00, -20.00, 1, 1, 0),
            (9, N'+4.01', 0.00, 4.00, 1, 1, 10),
            (9, N'0', 0.00, 4.00, 1, 1, 0),
            (9, N'4', 0.00, 4.00, 1, 1, 0),
            (9, N'bad', -30.00, -20.00, 1, 1, 0),
            (9, N'-31', -30.00, -20.00, 0, 1, 0),
            (9, N'-31', -30.00, -20.00, 1, 0, 0)
    ) AS expected(previous_val, temperature, min_temp, max_temp, activated, enabled, expected_val)
    CROSS APPLY dbo.PERMS_SMS_Counter
        (expected.previous_val, expected.temperature, expected.min_temp, expected.max_temp,
         expected.activated, expected.enabled) AS actual
    WHERE actual.new_val <> expected.expected_val
)
    THROW 51304, 'Counter increment, boundary, invalid-reading, or disabled-device test failed.', 1;

IF EXISTS
(
    SELECT 1
    FROM (VALUES (29, 0, 1), (30, 1, 1), (59, 1, 1), (60, 2, 2),
                 (90, 3, 2), (119, 3, 2), (120, 4, 3), (150, 5, 3))
        AS expected(counter_value, expected_hour, expected_tier)
    CROSS APPLY dbo.PERMS_SMS_Tier(expected.counter_value) AS actual
    WHERE actual.notification_hour <> expected.expected_hour OR actual.maximum_tier <> expected.expected_tier
)
    THROW 51305, 'Counter-hour or cumulative-tier threshold test failed.', 1;

DECLARE @TimedStart DATETIME = '20260101';
IF EXISTS
(
    SELECT 1
    FROM (VALUES (-1, 0, 0), (1199, 0, 0), (1200, -21, 1),
                 (2399, -21, 1), (2400, -41, 2), (3600, -61, 2),
                 (4799, -61, 2), (4800, -81, 3), (6000, -101, 3))
        AS expected(elapsed_seconds, expected_slot, expected_tier)
    OUTER APPLY dbo.PERMS_SMS_TimedTier
        (@TimedStart, DATEADD(SECOND, expected.elapsed_seconds, @TimedStart), 20, 40, 80, 20) AS actual
    WHERE ISNULL(actual.notification_hour, 0) <> expected.expected_slot
       OR ISNULL(actual.maximum_tier, 0) <> expected.expected_tier
)
    THROW 51316, 'Timed escalation exact boundary, repeat, or cumulative-tier test failed.', 1;

IF EXISTS
(
    SELECT 1
    FROM (VALUES (6, 0, 0), (7, -8, 1), (12, -13, 1), (13, -14, 2),
                 (18, -19, 2), (19, -20, 3), (24, -25, 3))
        AS expected(elapsed_minutes, expected_slot, expected_tier)
    OUTER APPLY dbo.PERMS_SMS_TimedTier
        (@TimedStart, DATEADD(MINUTE, expected.elapsed_minutes, @TimedStart), 7, 13, 19, 5) AS actual
    WHERE ISNULL(actual.notification_hour, 0) <> expected.expected_slot
       OR ISNULL(actual.maximum_tier, 0) <> expected.expected_tier
)
    THROW 51317, 'Custom delays or stage-relative repeat interval test failed.', 1;

DECLARE @LockResult INT;
DECLARE @SourceID INT = -2147483648;
DECLARE @GroupID INT =
(
    SELECT ID FROM dbo.PMContactGroup WHERE Location = 'MCR' AND App = 'PERMS'
);
DECLARE @ContactID INT;
DECLARE @Hour INT = 1;
DECLARE @QueueID INT;

EXEC @LockResult = sys.sp_getapplock
    @Resource = N'PERMS_SMS_159_Pipeline', @LockMode = 'Exclusive',
    @LockOwner = 'Session', @LockTimeout = 0;
IF @LockResult < 0 THROW 51306, 'Pause the job and retry; another SMS cycle is active.', 1;

BEGIN TRY
    BEGIN TRANSACTION;
    IF EXISTS (SELECT 1 FROM dbo.PERMS_logs_SMS WHERE id = @SourceID)
        THROW 51307, 'The reserved negative test source ID already exists.', 1;

    UPDATE dbo.PERMS_SMS_EscalationPolicy SET enabled = 0;
    UPDATE dbo.PERMS_SMS_DeviceRule SET alerts_enabled = 1 WHERE device_name = 'PERMS-MCR';

    INSERT INTO dbo.PMContacts (Name, Position, CellNumber, Location)
    VALUES (N'Staging Tier 1', N'Test', 'TEST-ONE', 'MCR');
    SET @ContactID = CONVERT(INT, SCOPE_IDENTITY());
    INSERT INTO dbo.PMUserGroup VALUES (@ContactID, @GroupID);
    INSERT INTO dbo.PERMS_MCR_ContactTier VALUES (@ContactID, 1);

    INSERT INTO dbo.PMContacts (Name, Position, CellNumber, Location)
    VALUES (N'Staging Tier 2', N'Test', 'TEST-TWO', 'MCR');
    SET @ContactID = CONVERT(INT, SCOPE_IDENTITY());
    INSERT INTO dbo.PMUserGroup VALUES (@ContactID, @GroupID);
    INSERT INTO dbo.PERMS_MCR_ContactTier VALUES (@ContactID, 2);

    INSERT INTO dbo.PMContacts (Name, Position, CellNumber, Location)
    VALUES (N'Staging Tier 3', N'Test', 'TEST-THREE', 'MCR');
    SET @ContactID = CONVERT(INT, SCOPE_IDENTITY());
    INSERT INTO dbo.PMUserGroup VALUES (@ContactID, @GroupID);
    INSERT INTO dbo.PERMS_MCR_ContactTier VALUES (@ContactID, 3);

    INSERT INTO dbo.PMContacts (Name, Position, CellNumber, Location)
    VALUES (N'Staging Duplicate Phone', N'Test', 'TEST-ONE', 'MCR');
    SET @ContactID = CONVERT(INT, SCOPE_IDENTITY());
    INSERT INTO dbo.PMUserGroup VALUES (@ContactID, @GroupID);
    INSERT INTO dbo.PERMS_MCR_ContactTier VALUES (@ContactID, 2);

    INSERT INTO dbo.PERMS_logs_SMS
        (id, device_name, temperature, date_time, val, is_activated,
         alarm_sequence, abnormal_started_dtm, last_reading_id)
    VALUES (@SourceID, N'PERMS-MCR', N'-39', GETDATE(), 29, 1, 1, GETDATE(), 0);

    EXEC dbo.Queue_PERMS_Notifications;
    IF EXISTS (SELECT 1 FROM dbo.PERMS_SMS_Notification WHERE source_id = @SourceID)
        THROW 51308, 'MCR queued below val 30.', 1;

    WHILE @Hour <= 5
    BEGIN
        UPDATE dbo.PERMS_logs_SMS SET val = @Hour * 30, date_time = GETDATE() WHERE id = @SourceID;
        EXEC dbo.Queue_PERMS_Notifications;
        EXEC dbo.Queue_PERMS_Notifications;

        IF (SELECT COUNT(*) FROM dbo.PERMS_SMS_Notification
            WHERE source_id = @SourceID AND notification_hour = @Hour) <> 1
            THROW 51309, 'Repeated queueing created an extra notification or missed the hour.', 1;

        SELECT @QueueID = queue_id FROM dbo.PERMS_SMS_Notification
        WHERE source_id = @SourceID AND notification_hour = @Hour;

        IF NOT EXISTS (SELECT 1 FROM dbo.PERMS_SMS_Recipient WHERE queue_id = @QueueID AND mobile_numb = 'TEST-ONE')
            THROW 51310, 'Tier 1 did not receive a later cumulative notification.', 1;
        IF @Hour >= 2 AND NOT EXISTS
            (SELECT 1 FROM dbo.PERMS_SMS_Recipient WHERE queue_id = @QueueID AND mobile_numb = 'TEST-TWO')
            THROW 51311, 'Tier 2 was missing after val 60.', 1;
        IF @Hour < 2 AND EXISTS
            (SELECT 1 FROM dbo.PERMS_SMS_Recipient WHERE queue_id = @QueueID AND mobile_numb = 'TEST-TWO')
            THROW 51312, 'Tier 2 was included before val 60.', 1;
        IF @Hour >= 4 AND NOT EXISTS
            (SELECT 1 FROM dbo.PERMS_SMS_Recipient WHERE queue_id = @QueueID AND mobile_numb = 'TEST-THREE')
            THROW 51313, 'Tier 3 was missing after val 120.', 1;
        IF @Hour < 4 AND EXISTS
            (SELECT 1 FROM dbo.PERMS_SMS_Recipient WHERE queue_id = @QueueID AND mobile_numb = 'TEST-THREE')
            THROW 51314, 'Tier 3 was included before val 120.', 1;
        IF (SELECT COUNT(*) FROM dbo.PERMS_SMS_Recipient
            WHERE queue_id = @QueueID AND mobile_numb = 'TEST-ONE') <> 1
            THROW 51315, 'A duplicate phone received more than one snapshot entry.', 1;

        SET @Hour = @Hour + 1;
    END;

    DECLARE @LocationIndex INT = 1;
    DECLARE @TimedLocation VARCHAR(10);
    DECLARE @TimedSourceID INT;
    DECLARE @TimedGroupID INT;
    DECLARE @TimedDevice NVARCHAR(50);
    DECLARE @TimedTier INT;
    DECLARE @ElapsedMinutes INT;
    DECLARE @ExpectedTier INT;
    DECLARE @TimedQueueID INT;
    DECLARE @TimedCount INT;

    WHILE @LocationIndex <= 2
    BEGIN
        SET @TimedLocation = CASE WHEN @LocationIndex = 1 THEN 'LSI' ELSE 'TR' END;
        SET @TimedSourceID = @SourceID + @LocationIndex;
        SET @TimedDevice = CASE WHEN @LocationIndex = 1 THEN N'PERMS-TEST' ELSE N'PERMS-TR' END;
        SELECT @TimedGroupID = ID FROM dbo.PMContactGroup
        WHERE Location = @TimedLocation AND App = 'PERMS';

        IF @TimedGroupID IS NULL OR EXISTS (SELECT 1 FROM dbo.PERMS_logs_SMS WHERE id = @TimedSourceID)
            THROW 51318, 'Timed test group is missing or its reserved source ID already exists.', 1;

        UPDATE dbo.PERMS_SMS_DeviceRule SET alerts_enabled = 1 WHERE device_name = @TimedDevice;
        UPDATE dbo.PERMS_SMS_EscalationPolicy
        SET enabled = 1, tier1_minutes = 20, tier2_minutes = 40,
            tier3_minutes = 80, repeat_minutes = 20
        WHERE Location = @TimedLocation;
        IF @@ROWCOUNT <> 1 THROW 51319, 'Install the timed escalation policies before testing.', 1;

        SET @TimedTier = 1;
        WHILE @TimedTier <= 5
        BEGIN
            INSERT INTO dbo.PMContacts (Name, Position, CellNumber, Location)
            VALUES (N'Staging timed tier', N'Test',
                'TEST-' + @TimedLocation + '-' + CONVERT(VARCHAR(1), CASE WHEN @TimedTier = 4 THEN 1 ELSE @TimedTier END),
                @TimedLocation);
            SET @ContactID = CONVERT(INT, SCOPE_IDENTITY());
            INSERT INTO dbo.PMUserGroup VALUES (@ContactID, @TimedGroupID);
            IF @TimedTier <= 4
                INSERT INTO dbo.PERMS_SMS_ContactTier (Location, PmContactID, Tier)
                VALUES (@TimedLocation, @ContactID, CASE WHEN @TimedTier = 4 THEN 2 ELSE @TimedTier END);
            ELSE
                INSERT INTO dbo.PERMS_SMS_ContactTier (Location, PmContactID, Tier)
                VALUES (CASE WHEN @TimedLocation = 'LSI' THEN 'TR' ELSE 'LSI' END, @ContactID, 1);
            SET @TimedTier = @TimedTier + 1;
        END;

        INSERT INTO dbo.PERMS_logs_SMS
            (id, device_name, temperature, date_time, val, is_activated,
             alarm_sequence, abnormal_started_dtm, last_reading_id)
        SELECT @TimedSourceID, device_name, CONVERT(NVARCHAR(50), min_temp - 1), GETDATE(),
               1, 1, 1, DATEADD(MINUTE, -19, GETDATE()), 0
        FROM dbo.PERMS_SMS_DeviceRule WHERE device_name = @TimedDevice;

        EXEC dbo.Queue_PERMS_Notifications;
        IF EXISTS (SELECT 1 FROM dbo.PERMS_SMS_Notification WHERE source_id = @TimedSourceID)
            THROW 51320, 'Timed escalation queued before its configured first delay.', 1;

        SET @ElapsedMinutes = 20;
        WHILE @ElapsedMinutes <= 100
        BEGIN
            UPDATE dbo.PERMS_logs_SMS
            SET abnormal_started_dtm = DATEADD(MINUTE, -@ElapsedMinutes, GETDATE()), date_time = GETDATE()
            WHERE id = @TimedSourceID;
            EXEC dbo.Queue_PERMS_Notifications;
            EXEC dbo.Queue_PERMS_Notifications;

            IF (SELECT COUNT(*) FROM dbo.PERMS_SMS_Notification
                WHERE source_id = @TimedSourceID AND notification_hour = -1 - @ElapsedMinutes) <> 1
                THROW 51321, 'Timed slot was missed or duplicate queueing occurred.', 1;
            SELECT @TimedQueueID = queue_id FROM dbo.PERMS_SMS_Notification
            WHERE source_id = @TimedSourceID AND notification_hour = -1 - @ElapsedMinutes;
            SET @ExpectedTier = CASE WHEN @ElapsedMinutes >= 80 THEN 3 WHEN @ElapsedMinutes >= 40 THEN 2 ELSE 1 END;
            SET @TimedTier = 1;
            WHILE @TimedTier <= 3
            BEGIN
                IF @TimedTier <= @ExpectedTier AND NOT EXISTS
                    (SELECT 1 FROM dbo.PERMS_SMS_Recipient WHERE queue_id = @TimedQueueID
                     AND mobile_numb = 'TEST-' + @TimedLocation + '-' + CONVERT(VARCHAR(1), @TimedTier))
                    THROW 51322, 'An eligible cumulative timed tier was omitted.', 1;
                IF @TimedTier > @ExpectedTier AND EXISTS
                    (SELECT 1 FROM dbo.PERMS_SMS_Recipient WHERE queue_id = @TimedQueueID
                     AND mobile_numb = 'TEST-' + @TimedLocation + '-' + CONVERT(VARCHAR(1), @TimedTier))
                    THROW 51323, 'A timed tier was included before its delay.', 1;
                SET @TimedTier = @TimedTier + 1;
            END;
            IF EXISTS (SELECT 1 FROM dbo.PERMS_SMS_Recipient WHERE queue_id = @TimedQueueID
                       AND mobile_numb = 'TEST-' + @TimedLocation + '-5')
                THROW 51324, 'A contact tier from another location was included.', 1;
            IF (SELECT COUNT(*) FROM dbo.PERMS_SMS_Recipient WHERE queue_id = @TimedQueueID
                AND mobile_numb = 'TEST-' + @TimedLocation + '-1') <> 1
                THROW 51325, 'Timed duplicate phone suppression failed.', 1;
            SET @ElapsedMinutes = @ElapsedMinutes + 20;
        END;

        SELECT @TimedCount = COUNT(*) FROM dbo.PERMS_SMS_Notification WHERE source_id = @TimedSourceID;
        UPDATE dbo.PERMS_logs_SMS
        SET abnormal_started_dtm = DATEADD(MINUTE, -120, GETDATE()), date_time = DATEADD(DAY, -1, GETDATE())
        WHERE id = @TimedSourceID;
        EXEC dbo.Queue_PERMS_Notifications;
        IF (SELECT COUNT(*) FROM dbo.PERMS_SMS_Notification WHERE source_id = @TimedSourceID) <> @TimedCount
            THROW 51326, 'A stale timed reading queued an alert.', 1;

        UPDATE dbo.PERMS_logs_SMS SET date_time = GETDATE(), val = 0, abnormal_started_dtm = NULL
        WHERE id = @TimedSourceID;
        EXEC dbo.Queue_PERMS_Notifications;
        IF (SELECT COUNT(*) FROM dbo.PERMS_SMS_Notification WHERE source_id = @TimedSourceID) <> @TimedCount
            THROW 51327, 'A recovered episode queued a timed alert.', 1;

        UPDATE dbo.PERMS_logs_SMS
        SET val = 1, alarm_sequence = 2, abnormal_started_dtm = DATEADD(MINUTE, -20, GETDATE())
        WHERE id = @TimedSourceID;
        EXEC dbo.Queue_PERMS_Notifications;
        IF NOT EXISTS (SELECT 1 FROM dbo.PERMS_SMS_Notification
                       WHERE source_id = @TimedSourceID AND alarm_sequence = 2 AND notification_hour = -21)
            THROW 51328, 'A new abnormal episode did not restart timed escalation.', 1;

        UPDATE dbo.PERMS_SMS_EscalationPolicy SET enabled = 0 WHERE Location = @TimedLocation;
        UPDATE dbo.PERMS_logs_SMS SET val = 9, alarm_sequence = 3 WHERE id = @TimedSourceID;
        EXEC dbo.Queue_PERMS_Notifications;
        IF EXISTS (SELECT 1 FROM dbo.PERMS_SMS_Notification WHERE source_id = @TimedSourceID AND alarm_sequence = 3)
            THROW 51329, 'Disabled timed policy changed the legacy val 10 threshold.', 1;
        UPDATE dbo.PERMS_logs_SMS SET val = 10 WHERE id = @TimedSourceID;
        EXEC dbo.Queue_PERMS_Notifications;
        IF NOT EXISTS (SELECT 1 FROM dbo.PERMS_SMS_Notification
                       WHERE source_id = @TimedSourceID AND alarm_sequence = 3 AND notification_hour = 0)
            THROW 51330, 'Disabled timed policy did not preserve legacy notification behavior.', 1;

        SET @LocationIndex = @LocationIndex + 1;
    END;

    ROLLBACK TRANSACTION;
    EXEC sys.sp_releaseapplock @Resource = N'PERMS_SMS_159_Pipeline', @LockOwner = 'Session';
    SELECT 'PASS: MCR counters; LSI/TR timed boundaries, custom delays, repeats, cumulative and location-specific tiers, duplicate phones, freshness, recovery, new episodes, and legacy fallback. Local test changes rolled back; source and sender were not modified or called.' AS result;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    EXEC sys.sp_releaseapplock @Resource = N'PERMS_SMS_159_Pipeline', @LockOwner = 'Session';
    THROW;
END CATCH;
GO