USE [AIM_DB]
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF @@TRANCOUNT <> 0
    THROW 51002, 'Run this test outside an existing transaction.', 1;

IF OBJECT_ID(N'dbo.Queue_PERMS_MCR_Escalations', N'P') IS NULL
    THROW 51003, 'Install the MCR escalation scripts before running this test.', 1;

IF NOT EXISTS
(
    SELECT 1 FROM sys.triggers
    WHERE object_id = OBJECT_ID(N'dbo.trg_PERMS_logs_SMS_on_sent') AND is_disabled = 0
)
    THROW 51017, 'Enable the revised SMS update trigger before testing.', 1;

IF EXISTS
(
    SELECT 1 FROM sys.configurations WHERE name = 'nested triggers' AND value_in_use = 0
)
    THROW 51018, 'Nested triggers must be enabled for the reading ingestion path.', 1;

IF EXISTS
(
    SELECT 1 FROM sys.triggers
    WHERE parent_id = OBJECT_ID(N'dbo.PERMS_logs_SMS')
      AND is_disabled = 0
      AND name <> 'trg_PERMS_logs_SMS_on_sent'
)
    THROW 51016, 'Disable other PERMS_logs_SMS triggers in staging before running this test.', 1;

IF
(
    SELECT COUNT(*) FROM dbo.PMContactGroup
    WHERE LTRIM(RTRIM(Location)) = 'MCR' AND LTRIM(RTRIM(App)) = 'PERMS'
) <> 1
    THROW 51004, 'Exactly one MCR / PERMS group is required.', 1;

DECLARE @GroupID INT =
(
    SELECT ID FROM dbo.PMContactGroup
    WHERE LTRIM(RTRIM(Location)) = 'MCR' AND LTRIM(RTRIM(App)) = 'PERMS'
);

IF EXISTS
(
    SELECT expected.Tier
    FROM (VALUES (1), (2), (3)) AS expected(Tier)
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM dbo.PERMS_MCR_ContactTier AS tier
        INNER JOIN dbo.PMUserGroup AS membership
            ON membership.PmContactID = tier.PmContactID
           AND membership.PMContactGroup = @GroupID
        INNER JOIN dbo.PMContacts AS contact ON contact.ID = tier.PmContactID
        WHERE tier.Tier = expected.Tier
          AND NULLIF(LTRIM(RTRIM(contact.CellNumber)), '') IS NOT NULL
    )
)
    THROW 51005, 'Assign at least one valid MCR contact to each of tiers 1, 2, and 3.', 1;

IF
(
    SELECT COUNT(*) FROM dbo.PERMS_logs_SMS WHERE device_name = 'PERMS-MCR'
) <> 1
    THROW 51006, 'A dedicated existing PERMS-MCR test row is required in PERMS_logs_SMS.', 1;

DECLARE @SourceID INT =
(
    SELECT id FROM dbo.PERMS_logs_SMS WHERE device_name = 'PERMS-MCR'
);
DECLARE @Sequence BIGINT;
DECLARE @QueueID INT;
DECLARE @Hour INT = 1;
DECLARE @MaximumTier INT;
DECLARE @FreshnessMinutes INT =
(
    SELECT max_reading_age_minutes FROM dbo.PERMS_MCR_Device WHERE device_name = 'PERMS-MCR'
);
DECLARE @ExpectedRecipients TABLE (mobile_numb VARCHAR(50) NOT NULL PRIMARY KEY);

IF EXISTS
(
    SELECT 1
    FROM
    (
        VALUES
            ('PERMS-0023', -31.00, 1),
            ('PERMS-0023', -30.00, 0),
            ('PERMS-0023', -21.00, 0),
            ('PERMS-0023', -20.00, 0),
            ('PERMS-0023', -19.00, 1),
            ('PERMS-0052',  -0.01, 1),
            ('PERMS-0052',   0.00, 0),
            ('PERMS-0052',   4.00, 0),
            ('PERMS-0052',   4.01, 1),
            ('PERMS-0056',   4.99, 1),
            ('PERMS-0056',   5.00, 0),
            ('PERMS-0056',  30.00, 0),
            ('PERMS-0056',  30.01, 1),
            ('PERMS-0060',   0.00, 0),
            ('PERMS-0060',  10.00, 0),
            ('PERMS-0060',  10.01, 1)
    ) AS expected(device_name, temperature, is_abnormal)
    LEFT JOIN dbo.PERMS_MCR_Device AS device ON device.device_name = expected.device_name
    WHERE device.device_name IS NULL
       OR CASE WHEN expected.temperature NOT BETWEEN device.min_temp AND device.max_temp
              THEN 1 ELSE 0 END <> expected.is_abnormal
)
    THROW 51019, 'Temperature boundary checks failed: verify the configured MCR limits.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    UPDATE dbo.PERMS_logs_SMS
       SET temperature = -25, val = 0, is_activated = 1, date_time = GETDATE()
    WHERE id = @SourceID;

    UPDATE dbo.PERMS_logs_SMS
       SET temperature = -39, val = 1, date_time = GETDATE()
    WHERE id = @SourceID;

    SELECT @Sequence = alarm_sequence
    FROM dbo.PERMS_MCR_AlarmState
    WHERE source_id = @SourceID AND abnormal_started_dtm IS NOT NULL;

    IF @Sequence IS NULL
        THROW 51007, 'The SMS trigger did not start the MCR alarm timer. Check enabled/nested triggers.', 1;

    UPDATE dbo.PERMS_MCR_AlarmState
         SET abnormal_started_dtm = DATEADD(HOUR, -5, SYSDATETIME()),
           last_observed_dtm = SYSDATETIME()
    WHERE source_id = @SourceID;

     UPDATE dbo.PERMS_logs_SMS SET val = 29 WHERE id = @SourceID;

    EXEC dbo.Queue_PERMS_MCR_Escalations;

    IF EXISTS
    (
        SELECT 1 FROM dbo.PERMS_MCR_Notification
        WHERE source_id = @SourceID AND alarm_sequence = @Sequence
    )
        THROW 51008, 'A notification was queued below val 30, despite the counter being authoritative.', 1;

    WHILE @Hour <= 5
    BEGIN
          UPDATE dbo.PERMS_logs_SMS
              SET val = @Hour * 30, date_time = GETDATE()
          WHERE id = @SourceID;

        EXEC dbo.Queue_PERMS_MCR_Escalations;
        EXEC dbo.Queue_PERMS_MCR_Escalations;

        IF
        (
            SELECT COUNT(*) FROM dbo.PERMS_MCR_Notification
            WHERE source_id = @SourceID
              AND alarm_sequence = @Sequence
              AND notification_hour = @Hour
        ) <> 1
            THROW 51009, 'Expected exactly one notification for the hour, including repeated scheduler runs.', 1;

        SELECT @QueueID = queue_id
        FROM dbo.PERMS_MCR_Notification
        WHERE source_id = @SourceID AND alarm_sequence = @Sequence AND notification_hour = @Hour;

        SET @MaximumTier = CASE WHEN @Hour >= 4 THEN 3 WHEN @Hour >= 2 THEN 2 ELSE 1 END;
        DELETE FROM @ExpectedRecipients;

        INSERT INTO @ExpectedRecipients (mobile_numb)
        SELECT DISTINCT LTRIM(RTRIM(contact.CellNumber))
        FROM dbo.PERMS_MCR_ContactTier AS tier
        INNER JOIN dbo.PMUserGroup AS membership
            ON membership.PmContactID = tier.PmContactID
           AND membership.PMContactGroup = @GroupID
        INNER JOIN dbo.PMContacts AS contact ON contact.ID = tier.PmContactID
        WHERE tier.Tier <= @MaximumTier
          AND NULLIF(LTRIM(RTRIM(contact.CellNumber)), '') IS NOT NULL;

        IF EXISTS
        (
            SELECT mobile_numb FROM @ExpectedRecipients
            EXCEPT
            SELECT mobile_numb FROM dbo.PERMS_MCR_NotificationRecipient WHERE queue_id = @QueueID
        ) OR EXISTS
        (
            SELECT mobile_numb FROM dbo.PERMS_MCR_NotificationRecipient WHERE queue_id = @QueueID
            EXCEPT
            SELECT mobile_numb FROM @ExpectedRecipients
        )
            THROW 51010, 'Recipient snapshot does not match the cumulative tiers.', 1;

        UPDATE dbo.PERMS_logs_SMS
           SET val = @Hour * 30 + 29, date_time = GETDATE()
        WHERE id = @SourceID;

        EXEC dbo.Queue_PERMS_MCR_Escalations;

        IF
        (
            SELECT COUNT(*) FROM dbo.PERMS_MCR_Notification
            WHERE source_id = @SourceID AND alarm_sequence = @Sequence
        ) <> @Hour
            THROW 51020, 'An intermediate counter value queued an extra hourly notification.', 1;

        SET @Hour = @Hour + 1;
    END;

    UPDATE dbo.PERMS_logs_SMS
       SET temperature = -25, val = 0, date_time = GETDATE()
    WHERE id = @SourceID;

    IF EXISTS
    (
        SELECT 1 FROM dbo.PERMS_MCR_AlarmState
        WHERE source_id = @SourceID AND abnormal_started_dtm IS NOT NULL
    )
        THROW 51011, 'A normal temperature did not clear the MCR timer.', 1;

    UPDATE dbo.PERMS_logs_SMS
       SET temperature = -39, val = 1, date_time = GETDATE()
    WHERE id = @SourceID;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.PERMS_MCR_AlarmState
        WHERE source_id = @SourceID AND alarm_sequence > @Sequence AND last_queued_hour = 0
    )
        THROW 51012, 'A new abnormal episode did not restart escalation.', 1;

    SELECT @Sequence = alarm_sequence FROM dbo.PERMS_MCR_AlarmState WHERE source_id = @SourceID;

    UPDATE dbo.PERMS_logs_SMS SET val = 30, date_time = GETDATE() WHERE id = @SourceID;

    UPDATE dbo.PERMS_MCR_AlarmState
       SET abnormal_started_dtm = DATEADD(HOUR, -1, SYSDATETIME()),
           last_observed_dtm = DATEADD(MINUTE, -(@FreshnessMinutes + 1), SYSDATETIME())
    WHERE source_id = @SourceID;

    EXEC dbo.Queue_PERMS_MCR_Escalations;

    IF EXISTS
    (
        SELECT 1 FROM dbo.PERMS_MCR_Notification
        WHERE source_id = @SourceID AND alarm_sequence = @Sequence
    )
        THROW 51013, 'A stale reading produced an escalation.', 1;

    UPDATE dbo.PERMS_logs_SMS
       SET temperature = -39, date_time = GETDATE()
    WHERE id = @SourceID;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.PERMS_MCR_AlarmState
        WHERE source_id = @SourceID AND alarm_sequence = @Sequence AND last_queued_hour = 0
    )
        THROW 51014, 'A reading gap incorrectly restarted the counter-based episode.', 1;

    EXEC dbo.Queue_PERMS_MCR_Escalations;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.PERMS_MCR_Notification
        WHERE source_id = @SourceID AND alarm_sequence = @Sequence AND notification_hour = 1
    )
        THROW 51021, 'Counter-based escalation did not resume on a fresh reading.', 1;

    UPDATE dbo.PERMS_logs_SMS SET is_activated = 0 WHERE id = @SourceID;

    IF EXISTS
    (
        SELECT 1 FROM dbo.PERMS_MCR_AlarmState
        WHERE source_id = @SourceID AND abnormal_started_dtm IS NOT NULL
    )
        THROW 51015, 'Deactivation did not clear the MCR timer.', 1;

    ROLLBACK TRANSACTION;
    SELECT 'PASS: Counter thresholds, cumulative tiers, repeat suppression, recovery, stale readings, and deactivation. Test changes rolled back; sender was not called.' AS result;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO