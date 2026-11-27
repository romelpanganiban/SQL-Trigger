# MCR Counter-Based SMS Escalation

## Behavior

| val threshold | Equivalent time at 2 minutes per count | Recipients |
| --- | --- | --- |
| Below 30 | Less than 1 hour | None |
| 30 | 1 hour | Tier 1 |
| 60 | 2 hours | Tiers 1 and 2 |
| 90 | 3 hours | Tiers 1 and 2 |
| 120, 150, 180, and every further 30 counts | 4 hours onward | Tiers 1, 2, and 3 |

The completed notification hour is FLOOR(val / 30). A value between thresholds
does not queue another reminder: 30 through 59 belong to notification hour 1.
If a run misses an exact threshold, it can queue that hour at a later count.
val is authoritative; timestamps do not advance the escalation tier. These times
assume exactly one increment every two minutes. Missing or duplicate readings
make the counter-derived duration differ from actual elapsed time.

All recipients must belong to the MCR / PERMS contact group through PMUserGroup.
Phone numbers are deduplicated within each device's hourly notification.
LSI and TR retain their counter-based behavior, including their sender resets.
MCR no longer resets its counter or escalation episode when a message is forwarded.

The 14 real MCR devices use the supplied limits. PERMS-MCR is also configured
as a test device with its existing -38 to -17 range. Min and Max are inclusive.

## Before Deployment

Test on a staging database first. Save the currently installed trigger and sender
definitions so they can be restored together if needed. These files are not
automatically applied to SQL Server.

Pause the existing SMS SQL Agent job and briefly pause reading ingestion while
deploying. The login needs permission to create tables/functions/procedures and
alter the existing triggers and sender. Keep nested triggers enabled: inserts
into the reading tables must fire the PERMS_logs_SMS update trigger.

Do not run the old combined PERMS_triggers.sql or enable trg_PERMS_SendSMS.
They represent the earlier direct-send implementation and can cause duplicate
alerts or overwrite the revised behavior.

## Deployment Order

1. Execute [01_MCR_escalation_setup.sql](01_MCR_escalation_setup.sql).
2. Execute [05_TR_device_setup.sql](05_TR_device_setup.sql), then configure the contacts, tiers, and freshness limit described below.
3. Execute [02_Queue_PERMS_MCR_Escalations.sql](02_Queue_PERMS_MCR_Escalations.sql).
4. Execute [trg_PERMS_logs.sql](trg_PERMS_logs.sql) and [trg_PERMS_logs_V2.sql](trg_PERMS_logs_V2.sql).
5. Disable the old direct sender, then execute [trg_PERMS_logs_SMS_on_sent.sql](trg_PERMS_logs_SMS_on_sent.sql).
6. Execute [03_Process_PERMS_SMS_Queue.sql](03_Process_PERMS_SMS_Queue.sql).
7. In staging, with the sender job paused, execute [04_MCR_escalation_tests.sql](04_MCR_escalation_tests.sql).
8. After staging passes, repeat deployment in production and resume ingestion
   and the existing sender job. Do not run the staging test on live production.

The current shared triggers and sender require both the MCR and TR configuration
tables, even if only one site's devices currently report readings.

Each source device needs its own existing PERMS_logs_SMS row with is_activated = 1.
The staging test requires a dedicated PERMS-MCR row. It changes that row and
queues test notifications inside a transaction, then rolls back. It never calls
Process_PERMS_SMS_Queue. Identity values consumed during rollback are not reused.

Disable the earlier direct sender in AIM_DB before activating this deployment:

```sql
USE [AIM_DB];
IF OBJECT_ID(N'dbo.trg_PERMS_SendSMS', N'TR') IS NOT NULL
    DISABLE TRIGGER dbo.trg_PERMS_SendSMS ON dbo.PERMS_logs_SMS;
```

## TR Device Mapping

TR does not use MCR's tier escalation. It keeps the existing alert when val crosses
from below 10 to 10 or above (20 minutes at two minutes per count). After forwarding,
the sender resets TR's val and is_sms_sent as before. A later abnormal count cycle
can therefore send another TR alert.

| Device | Area | Equipment | Normal range | Initial alerts |
| --- | --- | --- | --- | --- |
| PERMS-0067 | 1F RESIN ROOM 1 | CHILLER | 0 to 5 | Disabled: for installation |
| PERMS-0068 | 1F RESIN ROOM 2 | CHILLER | 0 to 5 | Disabled: for installation |
| PERMS-0069 | 1F WAREHOUSE | FREEZER 1 | -25 to -15 | Enabled |
| PERMS-0070 | 1F WAREHOUSE | FREEZER 2 | -25 to -15 | Enabled |
| PERMS-0071 | PD 2 PASTE STORAGE AREA | FREEZER 1 | -25 to -15 | Enabled |
| PERMS-0072 | PD 2 PASTE STORAGE AREA | FREEZER 2 | -25 to -15 | Disabled: temperature setting not yet set |
| PERMS-0073 | PD 3 PASTE STORAGE AREA | FREEZER | -25 to -15 | Disabled: installed but not yet active |

Limits are inclusive. All seven devices route to Location = TR, App = PERMS,
currently contact group 4. The queue processor resolves that group's PMUserGroup
memberships and PMContacts phone numbers. Messages include the mapped area and
equipment name. PERMS-TR remains the existing test device with its earlier range.

Each device needs an existing PERMS_logs_SMS row. The setup's final SELECT reports
missing source rows without inserting or replacing reading history. An enabled
device also requires is_activated = 1 on that row. Disabled devices still update
their temperature/humidity/date fields on new readings, but their val is held at
zero. Neither the trigger nor the sender will send their alerts. Pending alerts
are cancelled if the device is later disabled or deactivated.

To add TR to an already deployed MCR installation, pause the job and ingestion,
run [05_TR_device_setup.sql](05_TR_device_setup.sql) first, then reapply both logging
triggers, the SMS trigger, and [03_Process_PERMS_SMS_Queue.sql](03_Process_PERMS_SMS_Queue.sql).
Run [06_TR_mapping_tests.sql](06_TR_mapping_tests.sql) in staging before resuming
production. This rollback-only test needs existing PERMS-0069 and PERMS-0072
source rows plus a valid TR group contact. It never calls the sender, and does
not require MCR contact-tier assignments. It tests routing by updating source
rows directly, not by inserting live telemetry through either ingestion table.

After commissioning a held device and confirming its temperature settings, update
its InstallationStatus and alerts_enabled in PERMS_TR_Device. Start its counter
at zero so a previous value cannot skip the new crossing. For example, only after
PERMS-0072 is ready, run this deliberately in SSMS:

```sql
BEGIN TRANSACTION;
UPDATE dbo.PERMS_logs_SMS SET val = 0, is_sms_sent = 0
WHERE device_name = 'PERMS-0072';
UPDATE dbo.PERMS_TR_Device SET InstallationStatus = 'ACTIVE', alerts_enabled = 1
WHERE device_name = 'PERMS-0072';
COMMIT TRANSACTION;
```

Also confirm is_activated = 1 on its source row when commissioning is complete.
Rerunning the TR setup preserves existing configuration and does not automatically
reenable held devices or overwrite commissioning changes.

## Contact Assignment

No recipient tiers or phone numbers are inferred from the screenshot or inserted
automatically. First ensure every intended recipient exists in PMContacts and
has a PMUserGroup row whose PMContactGroup is the MCR / PERMS group's ID
(currently 3). Do not assign them to the LSI or F-ACTOR groups by mistake.

Then enter one row per person in dbo.PERMS_MCR_ContactTier using SSMS's table
editor: PmContactID is their PMContacts.ID; Tier is 1, 2, or 3 according to the list.
Assign only their earliest tier. A Tier 1 recipient automatically participates
at all later hours. The scripts deliberately leave this table empty until the
actual IDs are confirmed. MCR will not queue notifications without eligible tiers.

Use this query to review assignments and group membership:

```sql
SELECT contact.ID, contact.Name, contact.CellNumber,
       membership.PMContactGroup, tier.Tier
FROM dbo.PMContacts AS contact
LEFT JOIN dbo.PMUserGroup AS membership ON membership.PmContactID = contact.ID
LEFT JOIN dbo.PERMS_MCR_ContactTier AS tier ON tier.PmContactID = contact.ID
ORDER BY contact.ID;
```

There must be exactly one PMContactGroup row for Location = MCR and App = PERMS.
Configure at least one valid, nonblank phone number in each tier before testing.
PMContacts.CellNumber currently allows only 11 characters. Verify the sender's
accepted phone format before importing the international-format list; do not
truncate numbers to fit the column.

## Reading Freshness And Timing

PERMS_MCR_Device is the shared source for MCR areas, equipment names, and limits.
Its max_reading_age_minutes defaults to 15. Set this above the actual expected
reading interval, with suitable allowance for normal delays, before enabling
alerts. An overly short value prevents escalation for slower-reporting devices.

The first new abnormal update after deployment establishes the episode metadata.
The current val determines the eligible notification hour, even if the device
already has a high counter. abnormal_started_dtm records the observed episode
start for audit only; it is not used to calculate the escalation tier.

Normal or invalid temperatures, val = 0, deactivation, or a counter decrease
clear or restart the episode. A reading gap pauses reminders while stale, but
does not restart the counter-based episode or add any counts. A fresh abnormal
reading resumes evaluation at its current val. Invalid temperatures do not mean
recovery; the logging triggers currently reset their counter to zero for them.

The existing sender job should execute this once per minute:

```sql
EXEC [AIM_DB].[dbo].[Process_PERMS_SMS_Queue];
```

The revised sender calls the MCR scheduler itself; no second sender job is needed.
After an outage, only the latest due hour is queued, not every missed hour.
Pending reminders for ended episodes, stale readings, or older hourly slots are
cancelled. Pending legacy MCR messages without tier metadata are also cancelled
on migration, rather than sent to the entire expanded MCR group.

## Monitoring And Delivery Limits

PERMS_MCR_AlarmState holds the episode metadata and last queued counter-hour. PERMS_MCR_Notification
and PERMS_MCR_NotificationRecipient record MCR notification history and recipient
snapshots. The existing PERMS_logs_SMS_history remains the legacy LSI/TR history.
SMS_Queue.error_message records sender failures and cancellations. Cancelled rows
have is_processed = 1 but a cancellation explanation, not a successful handoff.

is_sms_sent = 1 means queued. is_processed = 1 with no error means forwarded to
PostgreSQL; neither proves receipt on the phone. Verify the modem/provider logs
and perform a controlled end-to-end delivery test before production use.

The application lock prevents concurrent runs of this revised sender, and the
notification key prevents requeuing the same MCR episode/hour. However, SQL Server
and the remote spool do not share an atomic commit here. If a remote insert
succeeds but its acknowledgement or subsequent local update fails, retrying can
duplicate texts. Exactly-once forwarding needs remote idempotency support or a
verified distributed transaction design; it is not claimed by these scripts.

To roll back, pause the job and ingestion, restore the saved sender and trigger
definitions as a set, and review pending MCR queues before resuming. Keep the new
tables for audit until their data and pending work have been reconciled.