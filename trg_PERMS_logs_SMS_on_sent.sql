USE [AIM_DB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER TRIGGER [dbo].[trg_PERMS_logs_SMS_on_sent]
ON [dbo].[PERMS_logs_SMS]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF TRIGGER_NESTLEVEL(
        OBJECT_ID(N'dbo.trg_PERMS_logs_SMS_on_sent'),
        'AFTER',
        'DML'
    ) > 1
        RETURN;

    IF UPDATE(temperature) OR UPDATE(date_time) OR UPDATE(val)
    BEGIN
        DECLARE @ObservedAt DATETIME2(0) = SYSDATETIME();
        DECLARE @Observations TABLE
        (
            source_id INT NOT NULL PRIMARY KEY,
            is_abnormal BIT NOT NULL,
            counter_restarted BIT NOT NULL
        );

        INSERT INTO @Observations (source_id, is_abnormal, counter_restarted)
        SELECT
            current_row.id,
            CASE
                WHEN ISNULL(current_row.is_activated, 0) = 1
                 AND ISNULL(current_row.val, 0) > 0
                 AND TRY_CONVERT(DECIMAL(10, 2), current_row.temperature)
                     NOT BETWEEN device.min_temp AND device.max_temp
                    THEN 1
                ELSE 0
            END,
            CASE WHEN ISNULL(current_row.val, 0) < ISNULL(previous_row.val, 0) THEN 1 ELSE 0 END
        FROM inserted AS current_row
        INNER JOIN deleted AS previous_row
            ON previous_row.id = current_row.id
        INNER JOIN dbo.PERMS_MCR_Device AS device
            ON device.device_name = current_row.device_name;

        INSERT INTO dbo.PERMS_MCR_AlarmState
            (source_id, alarm_sequence, abnormal_started_dtm, last_observed_dtm, last_queued_hour)
        SELECT
            observation.source_id,
            CONVERT(BIGINT, observation.is_abnormal),
            CASE WHEN observation.is_abnormal = 1 THEN @ObservedAt ELSE NULL END,
            @ObservedAt,
            0
        FROM @Observations AS observation
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dbo.PERMS_MCR_AlarmState AS existing WITH (UPDLOCK, HOLDLOCK)
            WHERE existing.source_id = observation.source_id
        );

        UPDATE state
           SET state.abnormal_started_dtm =
                   CASE
                       WHEN observation.is_abnormal = 0 THEN NULL
                       WHEN restart.is_new_episode = 1 THEN @ObservedAt
                       ELSE state.abnormal_started_dtm
                   END,
               state.alarm_sequence = state.alarm_sequence
                   + CASE WHEN restart.is_new_episode = 1 THEN 1 ELSE 0 END,
               state.last_queued_hour =
                   CASE
                       WHEN observation.is_abnormal = 0 OR restart.is_new_episode = 1 THEN 0
                       ELSE state.last_queued_hour
                   END,
               state.last_observed_dtm = @ObservedAt
        FROM dbo.PERMS_MCR_AlarmState AS state
        INNER JOIN @Observations AS observation
            ON observation.source_id = state.source_id
        CROSS APPLY
        (
            SELECT CASE
                WHEN observation.is_abnormal = 1
                 AND
                 (
                     state.abnormal_started_dtm IS NULL
                     OR observation.counter_restarted = 1
                 ) THEN 1
                ELSE 0
            END AS is_new_episode
        ) AS restart;
    END;

    IF UPDATE(is_activated)
    BEGIN
        UPDATE state
           SET state.abnormal_started_dtm = NULL,
               state.last_queued_hour = 0
        FROM dbo.PERMS_MCR_AlarmState AS state
        INNER JOIN inserted AS current_row ON current_row.id = state.source_id
        WHERE ISNULL(current_row.is_activated, 0) <> 1;
    END;

    UPDATE target
       SET target.is_sms_sent = 0
    FROM dbo.PERMS_logs_SMS AS target
    INNER JOIN inserted AS current_row
        ON current_row.id = target.id
    WHERE current_row.val = 0
      AND ISNULL(current_row.is_sms_sent, 0) <> 0;

    DECLARE @Changed TABLE
    (
        id INT NOT NULL PRIMARY KEY,
        pm_user_group INT NOT NULL,
        AlarmLocation VARCHAR(10) NOT NULL,
        AreaName VARCHAR(100) NULL,
        MachineName VARCHAR(50) NULL
    );

    INSERT INTO @Changed (id, pm_user_group, AlarmLocation, AreaName, MachineName)
    SELECT DISTINCT
        current_row.id,
        contact_group.ID,
        location.AlarmLocation,
        COALESCE(mcr_device.AreaName, tr_device.AreaName),
        COALESCE(mcr_device.MachineName, tr_device.MachineName)
    FROM inserted AS current_row
    INNER JOIN deleted AS previous_row
        ON previous_row.id = current_row.id
    LEFT JOIN dbo.PERMS_MCR_Device AS mcr_device
        ON mcr_device.device_name = current_row.device_name
    LEFT JOIN dbo.PERMS_TR_Device AS tr_device
        ON tr_device.device_name = current_row.device_name
    CROSS APPLY
    (
        SELECT
            CASE
                WHEN mcr_device.device_name IS NOT NULL THEN 'MCR'
                WHEN tr_device.device_name IS NOT NULL THEN 'TR'
                WHEN current_row.device_name IN
                (
                    'PERMS-0034',
                    'PERMS-0033',
                    'PERMS-0036',
                    'PERMS-0040',
                    'PERMS-0037',
                    'PERMS-0030',
                    'PERMS-0031',
                    'PERMS-0032',
                    'PERMS-0039',
                    'PERMS-0038',
                    'PERMS-TEST'
                ) THEN 'LSI'
                WHEN current_row.device_name = 'PERMS-TR' THEN 'TR'
                WHEN current_row.device_name = 'PERMS-MCR' THEN 'MCR'
                ELSE NULL
            END AS AlarmLocation
    ) AS location
    INNER JOIN dbo.PMContactGroup AS contact_group
        ON LTRIM(RTRIM(contact_group.Location)) = location.AlarmLocation
       AND LTRIM(RTRIM(contact_group.App)) = 'PERMS'
    WHERE current_row.val >= 10
            AND mcr_device.device_name IS NULL
        AND ISNULL(tr_device.alerts_enabled, 1) = 1
      AND ISNULL(previous_row.val, 0) < 10
      AND ISNULL(current_row.is_activated, 0) = 1
      AND EXISTS
      (
          SELECT 1
          FROM dbo.PMUserGroup AS membership
          WHERE membership.PMContactGroup = contact_group.ID
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.SMS_Queue AS queue WITH (UPDLOCK, HOLDLOCK)
          WHERE queue.source_id = current_row.id
            AND ISNULL(queue.is_processed, 0) = 0
      );

    IF NOT EXISTS (SELECT 1 FROM @Changed)
        RETURN;

    INSERT INTO dbo.SMS_Queue
    (
        source_id,
        pm_user_group,
        msg_from,
        msg_content
    )
    SELECT
        current_row.id,
        changed.pm_user_group,
        'PostgreSQL',
        'PERMS INFORMATION'
        + CHAR(13) + CHAR(10)
        + CHAR(13) + CHAR(10)

        + 'Location: '
        + changed.AlarmLocation
        + CHAR(13) + CHAR(10)

        + CASE
              WHEN changed.AreaName IS NOT NULL
                  THEN 'Area: ' + changed.AreaName + CHAR(13) + CHAR(10)
              ELSE ''
          END

        + 'Device Name: '
        + ISNULL(current_row.device_name, '')
        + CHAR(13) + CHAR(10)

                + COALESCE('Machine: ' + changed.MachineName,
                    CASE current_row.device_name
              WHEN 'PERMS-0034' THEN 'Machine: Freezer 1'
              WHEN 'PERMS-0033' THEN 'Machine: Freezer 2'
              WHEN 'PERMS-0036' THEN 'Machine: Freezer 3'
              WHEN 'PERMS-0040' THEN 'Machine: Freezer 4'
              WHEN 'PERMS-0037' THEN 'Machine: Freezer 5'
              WHEN 'PERMS-0030' THEN 'Machine: Freezer 6'
              WHEN 'PERMS-0031' THEN 'Machine: Freezer 7'
              WHEN 'PERMS-0032' THEN 'Machine: Freezer 8'
              WHEN 'PERMS-0039' THEN 'Machine: Freezer 10'
              WHEN 'PERMS-0038' THEN 'Machine: Freezer 11'
              WHEN 'PERMS-TEST' THEN 'Machine: Freezer TEST'
              WHEN 'PERMS-TR'   THEN 'Machine: Test TR'
              WHEN 'PERMS-MCR'  THEN 'Machine: Test MCR'
              ELSE 'Machine: Unknown'
          END)
        + CHAR(13) + CHAR(10)

        + 'Temperature: '
        + ISNULL(CONVERT(VARCHAR(50), current_row.temperature), '')
        + CHAR(13) + CHAR(10)

        + 'Date: '
        + ISNULL(CONVERT(VARCHAR(19), current_row.date_time, 120), '')
        + CHAR(13) + CHAR(10)
        + CHAR(13) + CHAR(10)

        + '[This is an automated message please do not reply]'
    FROM inserted AS current_row
    INNER JOIN @Changed AS changed
        ON changed.id = current_row.id;

    INSERT INTO dbo.PERMS_logs_SMS_history
    (
        id,
        device_name,
        temperature,
        humidity,
        date_time,
        is_sms_sent,
        val
    )
    SELECT
        current_row.id,
        current_row.device_name,
        current_row.temperature,
        current_row.humidity,
        current_row.date_time,
        1,
        current_row.val
    FROM inserted AS current_row
    INNER JOIN @Changed AS changed
        ON changed.id = current_row.id;

    UPDATE target
       SET target.is_sms_sent = 1
    FROM dbo.PERMS_logs_SMS AS target
    INNER JOIN @Changed AS changed
        ON changed.id = target.id;
END;
GO