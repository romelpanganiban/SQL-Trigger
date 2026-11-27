USE [msdb]
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

SELECT @@SERVERNAME AS connected_server,
       CONNECTIONPROPERTY('local_net_address') AS connected_server_ip;

IF DB_ID(N'PERMS_SMS') IS NULL OR DB_ID(N'PERMS') IS NULL
    THROW 51600, 'Connect to the SQL Server instance containing both PERMS and PERMS_SMS.', 1;
IF OBJECT_ID(N'PERMS_SMS.dbo.Run_PERMS_SMS_Cycle', N'P') IS NULL
    THROW 51601, 'Install polling scripts 01, 02, and 03 in PERMS_SMS first.', 1;
IF @@TRANCOUNT <> 0
    THROW 51602, 'Run the job installer outside an existing transaction.', 1;

DECLARE @JobName SYSNAME = N'Process PERMS SMS Queue';
DECLARE @JobID UNIQUEIDENTIFIER;
DECLARE @ReturnCode INT;
DECLARE @StartDate INT = CONVERT(INT, CONVERT(CHAR(8), GETDATE(), 112));

IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = @JobName)
    THROW 51603, 'The SMS job already exists. Review it in SQL Server Agent instead of creating another sender.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    EXEC @ReturnCode = dbo.sp_add_job
        @job_name = @JobName,
        @enabled = 0,
        @notify_level_eventlog = 2,
        @description = N'Reads PERMS, updates local PERMS_SMS counters and queues, then forwards eligible SMS. Created disabled for controlled cutover.',
        @job_id = @JobID OUTPUT;
    IF @ReturnCode <> 0
        THROW 51604, 'Could not create the disabled SMS job.', 1;

    EXEC @ReturnCode = dbo.sp_add_jobstep
        @job_id = @JobID,
        @step_id = 1,
        @step_name = N'Import, queue, and forward PERMS SMS',
        @subsystem = N'TSQL',
        @database_name = N'PERMS_SMS',
        @command = N'EXEC dbo.Run_PERMS_SMS_Cycle @Send = 1, @BatchSize = 1000;',
        @on_success_action = 1,
        @on_fail_action = 2,
        @retry_attempts = 0;
    IF @ReturnCode <> 0
        THROW 51605, 'Could not create the SMS cycle job step.', 1;

    EXEC @ReturnCode = dbo.sp_update_job
        @job_id = @JobID, @start_step_id = 1;
    IF @ReturnCode <> 0
        THROW 51606, 'Could not set the SMS job starting step.', 1;

    EXEC @ReturnCode = dbo.sp_add_jobschedule
        @job_id = @JobID,
        @name = N'Every 1 Minute - PERMS SMS Queue',
        @enabled = 1,
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 4,
        @freq_subday_interval = 1,
        @active_start_date = @StartDate,
        @active_start_time = 0,
        @active_end_time = 235959;
    IF @ReturnCode <> 0
        THROW 51607, 'Could not create the one-minute SMS schedule.', 1;

    EXEC @ReturnCode = dbo.sp_add_jobserver
        @job_id = @JobID, @server_name = N'(local)';
    IF @ReturnCode <> 0
        THROW 51608, 'Could not attach the SMS job to this instance.', 1;

    COMMIT TRANSACTION;

    SELECT job.name, job.enabled, SUSER_SNAME(job.owner_sid) AS job_owner,
           step.database_name, step.command, step.retry_attempts
    FROM dbo.sysjobs AS job
    INNER JOIN dbo.sysjobsteps AS step ON step.job_id = job.job_id
    WHERE job.job_id = @JobID;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO