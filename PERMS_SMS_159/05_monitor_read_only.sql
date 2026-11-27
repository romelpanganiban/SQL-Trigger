USE [PERMS_SMS]
GO
SET NOCOUNT ON;

SELECT @@SERVERNAME AS connected_server, DB_NAME() AS target_database;
SELECT * FROM dbo.PERMS_SMS_Control;
SELECT * FROM dbo.PERMS_SMS_EscalationPolicy ORDER BY Location;

SELECT
    target.id AS master_device_id,
    target.device_name,
    device_rule.Location,
    target.is_activated,
    device_rule.alerts_enabled,
    target.val,
    target.last_reading_id,
    target.date_time,
        target.abnormal_started_dtm,
        DATEDIFF_BIG(SECOND, target.abnormal_started_dtm, GETDATE()) / 60 AS abnormal_elapsed_minutes,
        CASE WHEN policy.enabled = 1 THEN 'Timed contact tiers'
            WHEN device_rule.Location = 'MCR' THEN 'MCR reading-count tiers'
            ELSE 'Legacy val 10' END AS escalation_mode,
        timed.maximum_tier AS current_timed_tier,
    DATEDIFF(MINUTE, target.date_time, GETDATE()) AS source_reading_age_minutes,
    CASE
        WHEN device_rule.device_name IS NULL THEN 'No approved rule: no alerts'
        WHEN target.is_activated = 0 THEN 'Source master inactive'
        WHEN device_rule.alerts_enabled = 0 THEN 'Configuration disabled'
        WHEN target.last_reading_id IS NULL THEN 'Awaiting first post-cutover reading'
        ELSE 'Review counter and queue'
    END AS device_status
FROM dbo.PERMS_logs_SMS AS target
LEFT JOIN dbo.PERMS_SMS_DeviceRule AS device_rule ON device_rule.device_name = target.device_name
LEFT JOIN dbo.PERMS_SMS_EscalationPolicy AS policy ON policy.Location = device_rule.Location
OUTER APPLY dbo.PERMS_SMS_TimedTier
    (target.abnormal_started_dtm, GETDATE(),
     CASE WHEN policy.enabled = 1 THEN policy.tier1_minutes END,
     policy.tier2_minutes, policy.tier3_minutes, policy.repeat_minutes) AS timed
ORDER BY device_rule.Location, target.device_name, target.id;

SELECT TOP (30) reading_id, master_device_id, import_status, imported_dtm
FROM dbo.PERMS_SMS_ImportedReading
WHERE import_status <> 'Processed'
ORDER BY reading_id DESC;

SELECT TOP (30)
    queue.queue_id,
    queue.source_id,
    target.device_name,
    queue.pm_user_group,
    notification.notification_hour,
    CASE WHEN notification.notification_hour < 0 THEN -1 - notification.notification_hour END AS timed_slot_minutes,
    queue.created_dtm,
    queue.is_processed,
    queue.processed_dtm,
    queue.error_message,
    (SELECT COUNT(*) FROM dbo.PERMS_SMS_Recipient AS recipient
     WHERE recipient.queue_id = queue.queue_id) AS snapshot_recipient_count
FROM dbo.SMS_Queue AS queue
LEFT JOIN dbo.PERMS_logs_SMS AS target ON target.id = queue.source_id
LEFT JOIN dbo.PERMS_SMS_Notification AS notification ON notification.queue_id = queue.queue_id
ORDER BY queue.queue_id DESC;

SELECT contact.ID, contact.Name, contact.CellNumber,
    contact_group.Location, contact_group.App,
    CASE WHEN contact_group.Location = 'MCR' THEN tier.Tier ELSE timed_tier.Tier END AS Tier
FROM dbo.PMContacts AS contact
LEFT JOIN dbo.PMUserGroup AS membership ON membership.PmContactID = contact.ID
LEFT JOIN dbo.PMContactGroup AS contact_group ON contact_group.ID = membership.PMContactGroup
LEFT JOIN dbo.PERMS_MCR_ContactTier AS tier ON tier.PmContactID = contact.ID
LEFT JOIN dbo.PERMS_SMS_ContactTier AS timed_tier
    ON timed_tier.Location = contact_group.Location AND timed_tier.PmContactID = contact.ID
ORDER BY contact_group.Location, Tier, contact.ID;

SELECT COUNT_BIG(*) AS pending_source_readings
FROM [PERMS].[dbo].[PERMS_logs] AS reading
CROSS JOIN dbo.PERMS_SMS_Control AS control
WHERE control.control_id = 1 AND reading.id > control.start_after_id
  AND NOT EXISTS
  (
      SELECT 1 FROM dbo.PERMS_SMS_ImportedReading AS imported
      WHERE imported.reading_id = reading.id
  );
GO