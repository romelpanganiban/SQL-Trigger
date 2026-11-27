# PERMS_SMS On 10.27.35.159

## Architecture

Both databases are on the same SQL Server instance on .159. The source remains
PERMS.dbo.PERMS_logs and PERMS.dbo.PERMS_master. Only PERMS_SMS is written to.
No linked server is required between these databases, and no trigger, procedure,
table, source counter, or source activation flag is changed in PERMS.

The confirmed join is TRY_CONVERT(INT, PERMS_logs.device_name) = PERMS_master.id.
PERMS_SMS.dbo.PERMS_logs_SMS.id is the source master ID, not an identity generated
in the SMS database. Duplicate device names are therefore not merged.

The pipeline is:

```text
PERMS logs + master (read only)
    -> ordered import + local processed-reading ledger
    -> local status/counters -> recipient snapshots -> local SMS_Queue
    -> POSTGRESQL30 SMS spool
```

This is the separate-database polling version. Do not mix it with the older
AIM_DB trigger scripts in the parent folder. It deliberately does not install
trg_PERMS_logs or trg_PERMS_logs_SMS_on_sent anywhere. Do not enable the old
trg_PERMS_SendSMS in the new SMS database.

## Install In SSMS

1. Connect explicitly to 10.27.35.159 and confirm the server shown by SSMS.
   Back up any existing PERMS_SMS data. Test against a staging copy first.
2. Confirm the already-created PERMS_SMS database exists on this instance.
   The scripts do not create or replace a database. Stop if setup reports an
   incompatible legacy local status table; do not drop it to bypass the check.
3. Execute the entire [01_local_setup.sql](01_local_setup.sql).
4. Execute the entire [02_import_and_queue.sql](02_import_and_queue.sql).
5. Execute the entire [03_sender_and_job_entry.sql](03_sender_and_job_entry.sql).
6. With sending still disabled, run [04_local_tests.sql](04_local_tests.sql) in
   staging. Expect PASS. The test only changes local fixtures within a rollback
   transaction and never imports source readings or calls the sender. Identity
   numbers consumed by the rolled-back test contacts/queues are not reused.
7. Configure contacts, memberships, tiers, device rules, and the sender connection
   as described below, then initialize the cutover and try an import-only cycle.

Scripts 02 and 03 suppress execution of later batches if their initial database
or dependency guard fails. Execute each entire file so its final SET NOEXEC OFF
also runs. If a partial selection left the SSMS session in no-execution mode,
run SET NOEXEC OFF in that session before retrying the complete file.

No tests or database deployment have been performed by the assistant. Editor
diagnostics alone do not prove that the SQL compiles or that delivery works.

## Device Rules And Existing Data

PERMS_SMS_DeviceRule contains the confirmed LSI devices, 14 MCR devices, seven
TR devices, and existing named test devices. It preserves supplied ranges and
TR readiness flags. Only TR 0069, 0070, and 0071 start enabled; 0067, 0068, 0072,
and 0073 remain disabled. Edit the local rule after commissioning, not PERMS.

PERMS-DEMO, PERMS-0041, PERMS-0043 through PERMS-0046, and any other unconfigured
name do not receive guessed rules or recipients. The monitor reports them.
Confirm location, equipment, and limits before adding their local rule.

The importer creates local status rows automatically from master IDs. Do not
copy old PERMS_logs_SMS IDs, SMS_Queue records, notification history, or counter
values from .211: those IDs describe a different database's devices. Do not copy
raw source reading history into PERMS_SMS. The local ledger stores reading IDs
and import status, while the status table holds only each device's current state.

Master activation is authoritative. The importer mirrors is_activated into local
status and clears counters for deactivated or renamed master records. A local
rule's alerts_enabled flag provides an additional independent suppression switch.
The master table's val and is_sms_sent are not read as alarm state or changed.

## Contacts And MCR Tiers

Contacts are not copied automatically from .211. Import PMContacts and its matching
PMUserGroup memberships into the local database, preserving contact IDs or mapping
the memberships to the newly assigned local IDs. The new PMContacts table allows
50-character phone numbers; verify the format required by the actual SMS service.
Use one consistent format: trimming spaces does not equate +63 and local-format
representations of the same phone number.

Default groups are LSI / PERMS = 1, MCR / PERMS = 3, and TR / PERMS = 4. Membership,
not the contacts' Location text alone, determines recipients. Check IDs if existing
contact groups were retained. No F-ACTOR group is used by this pipeline.

For MCR, each intended contact also needs PERMS_MCR_ContactTier(PmContactID, Tier).
Tier 1 is included from val 30, Tier 2 from val 60, and Tier 3 from val 120. Tier 1
is retained at all later steps; Tier 2 is retained from hour 2 onward.

Your all-Tier-1 choice is supported. After copying the contacts and memberships,
this local-only transaction sets all current MCR group contacts to Tier 1:

```sql
USE [PERMS_SMS];
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;
    UPDATE tier SET Tier = 1
    FROM dbo.PERMS_MCR_ContactTier AS tier
    WHERE EXISTS
    (
        SELECT 1 FROM dbo.PMUserGroup AS membership
        INNER JOIN dbo.PMContactGroup AS contact_group ON contact_group.ID = membership.PMContactGroup
        WHERE membership.PmContactID = tier.PmContactID
          AND contact_group.Location = 'MCR' AND contact_group.App = 'PERMS'
    );
    INSERT INTO dbo.PERMS_MCR_ContactTier (PmContactID, Tier)
    SELECT DISTINCT contact.ID, 1
    FROM dbo.PMContacts AS contact
    INNER JOIN dbo.PMUserGroup AS membership ON membership.PmContactID = contact.ID
    INNER JOIN dbo.PMContactGroup AS contact_group ON contact_group.ID = membership.PMContactGroup
    WHERE contact_group.Location = 'MCR' AND contact_group.App = 'PERMS'
      AND NOT EXISTS
      (
          SELECT 1 FROM dbo.PERMS_MCR_ContactTier AS tier WITH (UPDLOCK, HOLDLOCK)
          WHERE tier.PmContactID = contact.ID
      );
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
```

Unlike the old MCR staging test, the new local tests create their own temporary
three-tier fixtures and do not require your real contacts to populate every tier.

## Configurable LSI And TR Timed Escalation

LSI and TR can independently use elapsed-time escalation with cumulative contact
tiers. MCR keeps its existing reading-count behavior and PERMS_MCR_ContactTier.
The new policies start disabled, preserving the existing LSI/TR val-10 behavior.
No contacts are assigned automatically, and no source PERMS tables are changed.

### Upgrade And Test

1. Pause the PERMS SMS Agent job. Record the current sending_enabled value and
   set it to zero in PERMS_SMS_Control. Do not initialize the cutover again.
2. Run the entire updated [01_local_setup.sql](01_local_setup.sql), then
   [02_import_and_queue.sql](02_import_and_queue.sql), then
   [03_sender_and_job_entry.sql](03_sender_and_job_entry.sql). Rerunning setup
   preserves existing policies, contacts, device rules, counters, and queues.
3. Run [04_local_tests.sql](04_local_tests.sql) in staging with sending disabled.
   Expect PASS. It tests both locations, exact boundaries, custom delays, repeats,
   cumulative recipients, deduplication, stale readings, recovery, new episodes,
   and disabled-policy compatibility. It rolls back all fixtures and never calls
   the source importer or sender. Sender handoff still needs a controlled staging
   delivery test; these rollback-only checks do not prove remote delivery.
4. Configure contacts and enable a location using the examples below. Review
   [05_monitor_read_only.sql](05_monitor_read_only.sql) and an import-only cycle
   before restoring the sending flag and resuming the job. Pending legacy alerts
   for an enabled timed location are cancelled rather than sent under old rules.

### Assign Contact Tiers

List current group members first. Use local contact IDs, not IDs from .211:

```sql
USE [PERMS_SMS];
SELECT contact_group.Location, contact.ID, contact.Name, contact.CellNumber, tier.Tier
FROM dbo.PMContactGroup AS contact_group
INNER JOIN dbo.PMUserGroup AS membership ON membership.PMContactGroup = contact_group.ID
INNER JOIN dbo.PMContacts AS contact ON contact.ID = membership.PmContactID
LEFT JOIN dbo.PERMS_SMS_ContactTier AS tier
    ON tier.Location = contact_group.Location AND tier.PmContactID = contact.ID
WHERE contact_group.App = 'PERMS' AND contact_group.Location IN ('LSI', 'TR')
ORDER BY contact_group.Location, contact.ID;
```

Run this complete block once per contact, choosing its location, ID, and tier.
A contact in both locations may have a different tier in each location. Group
membership is still required; an unmapped contact is excluded when timed mode is on.

```sql
USE [PERMS_SMS];
SET XACT_ABORT ON;
DECLARE @Location VARCHAR(10) = 'LSI';
DECLARE @ContactID INT = NULL;
DECLARE @Tier TINYINT = 1;

IF @ContactID IS NULL OR @Tier IS NULL OR @Tier NOT BETWEEN 1 AND 3
    THROW 51800, 'Set a local contact ID and tier 1, 2, or 3.', 1;
IF @Location IS NULL OR @Location NOT IN ('LSI', 'TR')
    THROW 51801, 'Choose LSI or TR.', 1;
IF NOT EXISTS
(
    SELECT 1 FROM dbo.PMUserGroup AS membership
    INNER JOIN dbo.PMContacts AS contact ON contact.ID = membership.PmContactID
    INNER JOIN dbo.PMContactGroup AS contact_group ON contact_group.ID = membership.PMContactGroup
    WHERE contact.ID = @ContactID AND contact_group.Location = @Location AND contact_group.App = 'PERMS'
)
    THROW 51802, 'The contact must belong to this local PERMS group.', 1;

BEGIN TRY
    BEGIN TRANSACTION;
    UPDATE dbo.PERMS_SMS_ContactTier WITH (UPDLOCK, HOLDLOCK)
    SET Tier = @Tier WHERE Location = @Location AND PmContactID = @ContactID;
    IF @@ROWCOUNT = 0
        INSERT INTO dbo.PERMS_SMS_ContactTier (Location, PmContactID, Tier)
        VALUES (@Location, @ContactID, @Tier);
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
```

### Set The Minutes And Enable

The example below enables LSI with these settings. Repeat for TR, changing the
location and times as needed; the two policies are independent.

| Elapsed abnormal time | Recipients |
| --- | --- |
| Before 20 minutes | None |
| 20 minutes | Tier 1 |
| 40 minutes | Tiers 1 and 2 |
| 60 minutes | Tiers 1 and 2 again |
| 80 minutes onward | Tiers 1, 2, and 3, repeating every 20 minutes |

```sql
USE [PERMS_SMS];
GO
DECLARE @Location VARCHAR(10) = 'LSI';

IF NOT EXISTS
(
    SELECT 1 FROM dbo.PMContactGroup AS contact_group
    INNER JOIN dbo.PMUserGroup AS membership ON membership.PMContactGroup = contact_group.ID
    INNER JOIN dbo.PMContacts AS contact ON contact.ID = membership.PmContactID
    INNER JOIN dbo.PERMS_SMS_ContactTier AS tier
        ON tier.Location = contact_group.Location AND tier.PmContactID = contact.ID
    WHERE contact_group.Location = @Location AND contact_group.App = 'PERMS'
      AND tier.Tier = 1 AND NULLIF(LTRIM(RTRIM(contact.CellNumber)), '') IS NOT NULL
)
    THROW 51803, 'Configure at least one Tier 1 group member with a phone number first.', 1;

UPDATE dbo.PERMS_SMS_EscalationPolicy
SET tier1_minutes = 20,
    tier2_minutes = 40,
    tier3_minutes = 80,
    repeat_minutes = 20,
    enabled = 1
WHERE Location = @Location;
IF @@ROWCOUNT <> 1 THROW 51804, 'Install the policy tables first.', 1;

SELECT * FROM dbo.PERMS_SMS_EscalationPolicy WHERE Location = @Location;
GO
```

Delays must be positive and strictly increasing; repeat_minutes must be positive.
Tier 3 and repeat intervals are limited to 525600 minutes. Set enabled = 0 to
return that location to legacy val-10 alerts, not to stop all SMS. To suppress
all sending, use PERMS_SMS_Control.sending_enabled = 0 instead.

The clock starts at abnormal_started_dtm, the timestamp of the first abnormal
reading in the current episode. It uses actual elapsed seconds, not val times
two minutes. A valid abnormal temperature, active/enabled device, val > 0, and a
fresh non-future reading are still required. Normal/invalid readings reset the
episode; successful timed handoff does not reset it. A data gap does not restart
the clock, so a fresh abnormal reading after a gap may immediately escalate.

Each new tier starts immediately at its threshold; reminders then repeat from
that threshold. For example, 7/13/19 minute delays with a 5-minute repeat yield
slots at 7, 12, 13, 18, 19, 24, and so on. Only the current slot is queued after
a backlog; missed slots are not replayed. Execution occurs on the next job cycle,
not at an exact real-time deadline. Changing times affects active episodes on the
next cycle and may make an alert immediately due. Pause the job to reconfigure.

For compatibility, notification_hour and last_queued_hour retain their existing
names: MCR uses positive count-hour keys, legacy LSI/TR uses zero, and timed
LSI/TR uses -(scheduled_elapsed_minutes + 1). The monitor decodes negative keys
as timed_slot_minutes. These keys suppress duplicate queueing within one episode
and do not change the documented remote-delivery retry limitations.

[08_TR_live_sms_test.sql](08_TR_live_sms_test.sql) automatically simulates the
current TR Tier 1 delay in timed mode and requires an eligible Tier 1 recipient.
It sends real test SMS; do not use it as a non-sending configuration check.

## Cutover And First Import

Pause the old .211 sender job before enabling the new sender to avoid overlapping
delivery. Plan for counters to restart at zero; existing abnormal durations and
pending alerts are not automatically transferred between different master IDs.

Briefly pause source ingestion during cutover so no in-flight old reading is
mistaken for a post-cutover reading. This requires no source schema or code edit.
Then run the following ONCE, before enabling the job:

```sql
USE [PERMS_SMS];
EXEC dbo.Initialize_PERMS_SMS;
```

By default this captures the current maximum source reading ID. Only IDs above
that explicit baseline are eligible; old history is not replayed or texted.
Initialization leaves sending disabled. Rerunning initialization raises an error
rather than discarding work or advancing the cutover. Explicit historical replay
with @StartAfterID = 0 is possible only at first initialization, but should not be
used for normal cutover or without understanding its alarm-count consequences.

Resume ingestion, allow new readings to arrive, and run:

```sql
USE [PERMS_SMS];
EXEC dbo.Run_PERMS_SMS_Cycle @Send = 0, @BatchSize = 1000;
```

This reads the source, imports into local state, and may queue local alerts, but
does not contact PostgreSQL. Run [05_monitor_read_only.sql](05_monitor_read_only.sql)
to inspect mappings, counters, skipped readings, queues, recipients, and backlog.
With source ingestion paused in staging, running the cycle twice must not process
the same reading ID or increment the counter twice. The import ledger's primary
key and its atomic transaction with local status enforce local deduplication.

## Enable The Sender And Schedule The Job

The SQL Server instance on .159 must have the POSTGRESQL30 linked server, provider,
and login mapping configured for the account that executes the job. A definition
on .211 is not automatically available on .159. Have the DBA verify that connection;
do not place credentials in these scripts or share them in chat.

After the import-only checks pass and a controlled delivery test is approved:

```sql
USE [PERMS_SMS];
UPDATE dbo.PERMS_SMS_Control SET sending_enabled = 1 WHERE control_id = 1;
EXEC dbo.Run_PERMS_SMS_Cycle @Send = 1;
```

Create or update one SQL Agent job ON .159, database PERMS_SMS, scheduled every
minute, using this step command:

```sql
EXEC [PERMS_SMS].[dbo].[Run_PERMS_SMS_Cycle] @Send = 1, @BatchSize = 1000;
```

Alternatively, execute [07_create_agent_job.sql](07_create_agent_job.sql) on .159.
It creates `Process PERMS SMS Queue` disabled, with a one-minute
schedule and the creating login as owner. It does not change the .211 job or
enable sending. Have the DBA verify the owner's source and linked-server access.
After initialization and delivery checks, pause the .211 sender, set the local
sending flag to one, and enable the new job. SQL Server Agent must be running.
Immediate step retries are disabled; later scheduled cycles can still retry
pending queues, including the documented ambiguous remote-acceptance case.

Do not schedule Import_PERMS_Readings or Process_PERMS_SMS_Queue directly. The
entry point serializes import, queuing, and sending with one application lock.
Calling without @Send = 1 is import-only; setting sending_enabled = 0 also prevents
delivery. To stop delivery, disable the job and set that local flag to zero.

Use a dedicated execution account with SELECT on the two PERMS source tables and
appropriate local procedure/table permissions. Do not enable TRUSTWORTHY or broad
cross-database ownership chaining to bypass missing permissions. The DBA must also
configure that execution account's remote spool access.

## Counters, Freshness, And Failure Handling

Each processed abnormal reading increments val once; normal or invalid readings
reset it. Disabled or unconfigured devices have val zero. The two-minute convention
means MCR reminders are due at 30, 60, 90, 120, 150, and every further 30 counts.
With timed policies disabled, LSI/TR queue at val 10 or above, once per abnormal
counter cycle, and reset their local counter after successful remote handoff.
With a timed policy enabled they use configured elapsed-minute tiers instead,
without resetting the episode after handoff. MCR does not reset after handoff.
One raw reading is assumed to represent two minutes; gaps or duplicate readings
with distinct IDs change the relationship between counts and real elapsed time.

Notifications require a recent, non-future source date_time, with a default
15-minute maximum age in PERMS_SMS_DeviceRule. Confirm source timestamps use the
same local time basis as SQL Server before enabling. A stale/null/future timestamp
can advance a reading counter but cannot produce a current alert until fresh data
is available. A gap does not add counts or automatically restart the counter.

Only the latest eligible MCR hour or LSI/TR timed slot is queued after a backlog.
Ended episodes, disabled devices, stale readings, and superseded slots have pending notifications
cancelled before forwarding. Cancelled queues have is_processed = 1 and an explicit
error_message; they were not delivered. Recipient snapshots are deduplicated by
trimmed phone number per notification, and current membership/tier is checked again
before forwarding. A blank phone or missing membership/tier never implies delivery.

The source is assumed append-only with stable IDs. The importer uses a baseline
and a processed-ID anti-join, not a moving maximum-only watermark. An unseen reading
ID that appears later is still examined. If its ID is older than its device's
already-applied reading, it is recorded as Older source ID and is not allowed to
overwrite newer state. Review these cases: strict replay of arbitrary late commits
would require an additional reconciliation/commit-order design. Updates to already
processed source IDs are not automatically replayed. A source identity reset or
log emptying that moves the maximum behind the local position raises an error.

The anti-join scans post-cutover source IDs using the existing source PK and local
ledger PK. Monitor cost as the ledger grows. Do not purge ledger rows or advance
the baseline casually: that can replay or lose readings. Source retention must
leave enough history for the importer to catch up; deleted source readings cannot
be recovered by this polling design.

is_sms_sent means queued, and is_processed with no error means forwarded to the
remote spool, not confirmed receipt on a phone. Source rows are never marked sent.
The remote insert and local acknowledgement do not share an atomic commit. A lost
acknowledgement or crash after remote acceptance can duplicate SMS on retry. Remote
idempotency or a separately verified distributed-transaction design is required
for a stronger delivery guarantee; these scripts do not claim exactly-once SMS.

Rollback: stop the new job and sending flag first, retain the new database for
audit, and review its pending queues before restoring the old sender service.
Do not run both senders at once or discard pending records without reconciliation.