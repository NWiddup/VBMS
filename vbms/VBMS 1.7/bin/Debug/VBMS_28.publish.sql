﻿/*
Deployment script for VBMS

This code was generated by a tool.
Changes to this file may cause incorrect behavior and will be lost if
the code is regenerated.
*/

GO
SET ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS, ARITHABORT, CONCAT_NULL_YIELDS_NULL, QUOTED_IDENTIFIER ON;

SET NUMERIC_ROUNDABORT OFF;


GO
:setvar DatabaseName "VBMS"
:setvar DefaultFilePrefix "VBMS"
:setvar DefaultDataPath "C:\SQL\MSSQL13.MSSQLSERVER\MSSQL\DATA\"
:setvar DefaultLogPath "C:\SQL\MSSQL13.MSSQLSERVER\MSSQL\DATA\"

GO
:on error exit
GO
/*
Detect SQLCMD mode and disable script execution if SQLCMD mode is not supported.
To re-enable the script after enabling SQLCMD mode, execute the following:
SET NOEXEC OFF; 
*/
:setvar __IsSqlCmdEnabled "True"
GO
IF N'$(__IsSqlCmdEnabled)' NOT LIKE N'True'
    BEGIN
        PRINT N'SQLCMD mode must be enabled to successfully execute this script.';
        SET NOEXEC ON;
    END


GO
USE [$(DatabaseName)];


GO
IF fulltextserviceproperty(N'IsFulltextInstalled') = 1
    EXECUTE sp_fulltext_database 'disable';


GO
PRINT N'Altering [dbo].[CollectIndexData]...';


GO
/*

-- THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE PROVIDED "AS IS" WITHOUT
--WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT
--LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS
--FOR A PARTICULAR PURPOSE.

Author: 
Oleg Trutnev otrutnev@microsoft.com



Russian:



English:
  

 
*/

ALTER PROCEDURE [dbo].[CollectIndexData] 
	 @db INT
	,@batch UNIQUEIDENTIFIER = NULL
	
AS
SET NOCOUNT ON
DECLARE
	@SQL nvarchar(max),
	@index_minsize bigint,
	@locktimeout bigint

	IF @batch is null
		SET @batch = NEWID()

--Удаляем устаревшие невыполненные задания / Old tasks cleanup
DELETE FROM dbo.FragmentationData
	WHERE database_id = @db
	AND analysis_started is null
	
	

--Считываем параметры / Loading parameters

SELECT @index_minsize = int_value
FROM dbo.Parameters
WHERE parameter = 'IndexMinimumSizeMB'

SELECT @locktimeout = int_value
FROM dbo.Parameters
WHERE parameter = 'LockTimeoutMs'



--Get list of all partitions and some stats on them
--This statement should be executed in different database context, so we have to use dynamic T-SQL
--The statement itself is static, it's relatively easy to unquote it
SET @SQL = 
'USE '+QUOTENAME(DB_NAME(@db))+';

DECLARE @worker_name nvarchar(255)
SELECT @worker_name = worker_name
FROM VBMS.dbo.WorkerSessions
WHERE session_id = @@SPID

SET LOCK_TIMEOUT '+CAST(@locktimeout as nvarchar(10))+';

INSERT INTO VBMS.[dbo].[FragmentationData]
           ([batch_id]
           ,[collection_date]
           ,[database_id]
           ,[schema_id]
           ,[object_id]
           ,[object_name]
           ,[index_id]
           ,[index_name]
           ,[allow_page_locks]
           ,[legacy_col_count]
           ,[xml_col_count]
           ,[user_scans]
           ,[partition_count]
           ,[partition_number]
           ,[row_count]
           ,[size_mb]
           ,[avg_fragmentation_in_percent]
		   ,[analysis_status]
		   ,[volume_mount_point])
     
SELECT '''+CAST(@batch as nvarchar(50))+''',
GETDATE() as collection_date,
	DB_ID() as database_id, 
	t.schema_id, 
	t.object_id, 
	QUOTENAME(SCHEMA_NAME(t.schema_id))+''.''+QUOTENAME(OBJECT_NAME(t.object_id)) as object_name,
	--per index data:
	i.index_id,
	i.name as index_name,
	i.allow_page_locks,
	c.legacy_col_count,
	c.xml_col_count,
	ISNULL(ius.user_scans,0) as user_scans,
	count(*) OVER (PARTITION BY t.object_id, i.index_id) as partition_count,
	--per partition data:
	p.partition_number,
	p.rows as row_count,
	CAST(ps.used_page_count * 8 / 1024.00 AS DECIMAL(10,3)) as size_mb,
	NULL as avg_fragmentation_in_percent,
	0 as analysis_status,
	vs.volume_mount_point
	
FROM 
	sys.tables t
	INNER JOIN sys.indexes i on t.object_id = i.object_id 
	INNER JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id = i.index_id
	INNER JOIN sys.allocation_units au on p.partition_id = au.container_id and au.type =1
	INNER JOIN sys.data_spaces ds on au.data_space_id = ds.data_space_id
	INNER JOIN sys.database_files dbf on dbf.data_space_id = ds.data_space_id
	CROSS APPLY sys.dm_os_volume_stats(DB_ID(),dbf.file_id) vs
	LEFT OUTER JOIN sys.dm_db_partition_stats ps on ps.object_id = t.object_id AND ps.index_id = i.index_id AND ps.partition_number = p.partition_number
	LEFT OUTER JOIN sys.dm_db_index_usage_stats ius ON ius.database_id = DB_ID() AND ius.index_id = i.index_id AND ius.object_id = i.object_id
	LEFT OUTER JOIN
	(  --number of legacy and xml columns is needed to decide if online rebuild is possible
	   --If the index is clustered, consider all columns
		SELECT 
			c.object_id, 
			i.index_id,
			ISNULL(SUM(CASE WHEN TYPE_NAME(c.system_type_id) IN (''image'',''text'',''ntext'') THEN 1 ELSE 0 END),0) as legacy_col_count,
			ISNULL(SUM(CASE WHEN TYPE_NAME(c.system_type_id) = ''xml''  THEN 1 ELSE 0 END),0) as xml_col_count
		FROM 
			sys.columns c
			INNER JOIN sys.indexes i ON i.object_id = c.object_id
			LEFT OUTER JOIN	sys.index_columns ic ON ic.object_id = c.object_id	AND ic.column_id = c.column_id AND ic.index_id = i.index_id
		WHERE
			(i.index_id = 1               -- index is clustered (count all columns)
			OR ic.index_id is not null)   -- OR nonclustered    (count only index columns)
			GROUP BY 
			c.object_id, i.index_id	
	) c ON c.index_id = i.index_id AND c.object_id = i.object_id
WHERE
	i.index_id > 0 -- we cant rebuild heap
	AND NOT EXISTS	(
		SELECT 1 
		FROM VBMS.dbo.Blacklist bl
		WHERE 
			bl.[database_id] = DB_ID()
			AND (bl.table_id = t.object_id or bl.table_id is null)
			AND (bl.index_id = i.index_id or bl.index_id is null) 
			AND (bl.subsystem_id = 1 or bl.subsystem_id is null)
			AND (bl.partition_n = p.partition_number or bl.partition_n is null)
			AND (bl.worker_name = @worker_name or worker_name is null)
			AND bl.enabled = 1)
	and ps.used_page_count > '+ CAST(@index_minsize /8*1024 as nvarchar(20)) 
EXEC(@SQL)
GO
PRINT N'Altering [dbo].[FillQueueStat]...';


GO
/*

-- THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE PROVIDED "AS IS" WITHOUT
--WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT
--LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS
--FOR A PARTICULAR PURPOSE.
Author: Oleg Trutnev otrutnev@microsoft.com


Russian:
Процедура добавления заданий пересчёта статистики в таблицу dbo.Tasks
При оценке актуальности статистики используется динамический порог,
работающий аналогично флагу трассировки 2371. Автор формулы Juergen Thomas.
Для приоретизации используется процент превышения порога перерасчёта статистики (поле rowmod_factor)

English:

Stored procedure creates tasks for statistics update in table dbo.Tasks.
Each task is a T-SQL Statement UPDATE STATISTICS(<Table name>) WITH FULLSCAN.
Dynamic threshold formula like in traceflag 2371 is used.
Formula is created by Juergen Thomas.
Tasks are sorted by rowmod_factor that is computed like a percent of threshold deviation.
Greater is worse.

*/
ALTER PROCEDURE [dbo].[FillQueueStat] @db INT ,@batch UNIQUEIDENTIFIER = null, @sample nvarchar(50) = 'FULLSCAN'
AS
DECLARE	@SQL NVARCHAR(MAX)
	,@tableid INT
	,@indexid INT
	,@partitionnum INT
	,@subsystem_id INT
	,@actiontype INT
	,@entryid BIGINT

IF @batch is null
SET @batch = newid()

IF @sample not like N'SAMPLE % ROWS' AND @sample not like N'FULLSCAN' AND @sample not like N'RESAMPLE' AND @sample not like N'SAMPLE % PERCENT'
BEGIN SET @sample = N'RESAMPLE' --@sample parameter control. 
PRINT N'Warning! Incorrect sample selected! Using RESAMPLE!'
END



DELETE --delete old tasks, because they are now useless.
FROM dbo.Tasks
WHERE subsystem_id = 2 --Подсистема обслуживания статистики / Statistics management subsystem_id tasks
	AND date_completed IS NULL
	AND [database_id] = @db
	AND [worker_name] IS NULL

SET @SQL = '
DECLARE @worker_name nvarchar(255)
SELECT @worker_name = worker_name
FROM VBMS.dbo.WorkerSessions
WHERE session_id = @@SPID

USE [' + db_name(@db) + '];
 INSERT VBMS.dbo.Tasks (
 batch_id
 ,subsystem_id
 ,action_type_id
 ,command
 ,date_added
 ,database_id
 ,table_id
 ,index_id
 ,size_mb
 ,rowcnt
 ,rowmod_factor)
 (
SELECT DISTINCT
''' + CAST(@batch AS NVARCHAR(50)) + '''
	,2
	,1
	,''USE [' + DB_NAME(@db) + 
	']
	UPDATE STATISTICS ['' + SCHEMA_NAME(so.schema_id) + ''].['' + OBJECT_NAME(so.object_id) +''] [''+ISNULL(s.name, '''') + ''] WITH '+@sample+''' AS command
	,getdate()
	,db_id()
	,so.object_id
	,s.stats_id
	,SUM(CAST(ps.used_page_count * 8 / 1024.00 AS DECIMAL(10, 3))) AS size_mb
	,ssi2.rows
	,CASE 
		WHEN ssi2.rows < 25000
			THEN (((ssi.rowmodctr + 0.0001) / (ssi2.rows + 0.000001)) * 100.00 - (ssi2.rows * 0.2 + 500) / (ssi2.rows +0.000001) * 100)
		ELSE (((ssi.rowmodctr + 0.0001) / (ssi2.rows + 0.000001)) * 100.00 - sqrt((ssi2.rows) * 1000.00) / (ssi2.rows + 0.000001) * 100.00)
		END as rowmod_factor
FROM sys.stats  s (NOLOCK)
join sys.dm_db_partition_stats ps (NOLOCK)  on s.object_id = ps.object_id and ps.index_id < 2
join sys.sysindexes ssi (NOLOCK)  on s.object_id = ssi.id and ssi.indid = s.stats_id
join sys.objects so (NOLOCK)  on so.object_id = s.object_id
AND so.type IN (
		N''U''
		,N''V''
		)
join sys.sysindexes ssi2 on s.object_id = ssi2.id and ssi2.indid < 2
WHERE so.is_ms_shipped = 0
	AND
	(ssi2.rows > 500)
		AND ssi.rowmodctr > (
			CASE 
				WHEN (ssi2.rows < 25000)
					THEN (sqrt((ssi2.rows) * 1000))
				WHEN ((ssi2.rows) > 25000)
					THEN ((ssi2.rows) * 0.2 + 500)
				END
			)
--Blacklisting
AND not exists
(SELECT 1 
FROM VBMS.dbo.Blacklist bl
WHERE 
 (bl.database_id = db_id() 
 and (bl.table_id = so.object_id or bl.table_id is null))
 and (bl.index_id = s.stats_id or bl.index_id is null) 
and (bl.subsystem_id = 2 or bl.subsystem_id is null)
AND (bl.worker_name = @worker_name or worker_name is null)
and bl.enabled = 1
)
--Blacklisting
GROUP BY so.schema_id
	,so.object_id
	,s.stats_id
	,s.name
	,ssi.rowmodctr 
	,ssi2.rows
	
	
)'

EXEC(@SQL)


DECLARE TASKS CURSOR
FOR SELECT entry_id, [database_id], table_id,index_id,partition_n,subsystem_id, action_type_id
FROM dbo.Tasks WHERE time_prognosis_s is null
and database_id = @db
and batch_id = @batch


OPEN TASKS

FETCH NEXT FROM TASKS
INTO @entryid,@tableid,@indexid,@partitionnum,@subsystem_id,@actiontype

WHILE @@FETCH_STATUS = 0 
BEGIN 

UPDATE dbo.Tasks
SET time_prognosis_s = ISNULL(dbo.GetTimeFactor(@db,1,@tableid,@indexid,@partitionnum,@subsystem_id, @actiontype,60,1),0) * size_mb
WHERE entry_id = @entryid
FETCH NEXT FROM TASKS
INTO @entryid,@tableid,@indexid,@partitionnum,@subsystem_id,@actiontype


END

CLOSE TASKS
DEALLOCATE TASKS
GO
PRINT N'Refreshing [dbo].[ProcessQueueAll]...';


GO
EXECUTE sp_refreshsqlmodule N'[dbo].[ProcessQueueAll]';


GO
PRINT N'Refreshing [dbo].[StartWorker]...';


GO
EXECUTE sp_refreshsqlmodule N'[dbo].[StartWorker]';


GO
PRINT N'Refreshing [dbo].[FillQueueAll]...';


GO
EXECUTE sp_refreshsqlmodule N'[dbo].[FillQueueAll]';


GO
DECLARE @Ops TABLE ([subsystem_id] int, [action_type_id]int, [subsystem_name] nvarchar(255), [action_type_name] nvarchar(255))
DECLARE @Params TABLE ([parameter] nvarchar(50), [string_value] nvarchar(150), [int_value] BIGINT, [float_value] FLOAT (53), [description] NVARCHAR (MAX) )

INSERT @Ops ([subsystem_id], [action_type_id], [subsystem_name], [action_type_name]) VALUES (0, 1, N'Queue Generation', N'Generation of tasks for further execution')

INSERT @Ops ([subsystem_id], [action_type_id], [subsystem_name], [action_type_name]) VALUES (1, 1, N'Index Maintenance\Обслуживание индексов', N'Offline rebuild\Перестройка индекса оффлайн')

INSERT @Ops ([subsystem_id], [action_type_id], [subsystem_name], [action_type_name]) VALUES (1, 2, N'Index Maintenance\Обслуживание индексов', N'Online rebuild\Перестройка индекса онлайн')

INSERT @Ops ([subsystem_id], [action_type_id], [subsystem_name], [action_type_name]) VALUES (1, 3, N'Index Maintenance\Обслуживание индексов', N'Reorganize\Реорганизация индекса')

INSERT @Ops ([subsystem_id], [action_type_id], [subsystem_name], [action_type_name]) VALUES (2, 1, N'Statistics maintenance\Обслуживание статистики', N'Update statistics\Пересчёт статистки')

INSERT @Ops ([subsystem_id], [action_type_id], [subsystem_name], [action_type_name]) VALUES (3, 1, N'Integrity check\Проверка целостности', N'CHECKCATALOG\Проверка целостности системного каталога')

INSERT @Ops ([subsystem_id], [action_type_id], [subsystem_name], [action_type_name]) VALUES (3, 2, N'Integrity check\Проверка целостности', N'CHECKALLOC\Проверка целостности в части размещения (DBCC CHECKALLOC)')

INSERT @Ops ([subsystem_id], [action_type_id], [subsystem_name], [action_type_name]) VALUES (3, 3, N'Integrity check\Проверка целостности', N'CHECKTABLE\Проверка целостности отдельной таблицы')


INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'CheckTableIntervalDays', NULL, 7, NULL, N'Days between CHECKTABLE\Периодичность проверки целостности отдельно взятой таблицы')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'MaxDop', NULL, 2, NULL, N'Max Degree of parallelism for index operations\Количество ядер, которые могут быть использованы для операций с индексами')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'CheckCatalogIntervalDays', NULL, 7, NULL, N'Days between CHECKCATALOG\Периодичность проверки целостности системных таблиц БД')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'HistoryRetentionDays', NULL, 90, NULL, N'Old tasks will be removed after this number of days\Продолжительность хранения журнала заданий')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'IndexReorgThresholdPercent', NULL, 30, NULL, N'Maximum index fragmentation when reorganize is prefered instead of rebuild\Максимальное значение фрагментации индекса для использования REORGANIZE')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'IndexOnlineRebuild', NULL, 1, NULL, N'Use or not ONLINE where possible. Online operations are slower\Флаг использования ONLINE при перестройке индексов. Его использование увеличивает продолжительность операции, но сохраняет индекс доступным по время обслуживания')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'TotalMaintenanceWindowMm', NULL, 60, NULL, N'Total amount of time (minutes) for maintenance\Общая продолжительность технологического окна в минутах')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'IndexMaintenanceWindowPercent', NULL, 30, NULL, N'Percent of time to spend on index maintenance\Процент времени, отведённого под обслуживание индексов')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'StatMaintenanceWindowPercent', NULL, 30, NULL, N'Percent of time to spend on statistics maintenance\ Процент времени, отведённого под обслуживание статистики')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'CheckWindowPercent', NULL, 30, NULL, N'Percent of time to spend on integrity checks\Процент времени, отведённого под проверку целостности')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'CheckAllocIntervalDays', NULL, 7, NULL, N'Days between CHECKALLOC\Периодичность проверки целостноси в части аллокации экстентов')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'LockTimeoutMs', NULL,20000 , NULL, N'How long (ms) should index operation wait being locked\Максимальное время в заблокированном состоянии. При превышении задание будет остановлено.')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'SortInTempdb', NULL,0 , NULL, N'Should indexes be sorted in tempdb during index rebuild?\Использование tempdb для сортировки индекса во время перестройки')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'IndexFragLowerThreshold', NULL,10 , NULL, N'Index fragmentation lower limit. Index with fragmentation lower than this wont be maintaintes \ Нижняя граница фрагментации. Индекс с меньшей фрагментацией обслуживаться не будет')
INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'TranLogSpaceThresholdMb', NULL,500 , NULL, N'Transaction log space left threshold(mountpoints not supported yet)/Минимальный размер свободного места под лог транзакций для операций обслуживания индексов (mountpoint не поддерживается пока)')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'IndexMinimumSizeMB', NULL,10 , NULL, N'Minimum size of index that can be rebuilt or reorganized/Минимальный размер индекса, подлежащего обслуживанию')

INSERT @Params ([parameter], [string_value], [int_value], [float_value], [description]) VALUES (N'FragCollectionTimeLimitS', NULL,3600 , NULL, N'Maximum duration of index fragmentation analysis phase/Максимальная продолжительность фазы анализа фрагментации индексов')

MERGE dbo.Parameters as TARGET
USING (SELECT * FROM @Params) as SOURCE ([parameter], [string_value], [int_value], [float_value], [description])
ON (TARGET.parameter COLLATE DATABASE_DEFAULT = SOURCE.parameter COLLATE DATABASE_DEFAULT)
WHEN MATCHED THEN UPDATE SET description = SOURCE.description
WHEN NOT MATCHED THEN INSERT ([parameter], [string_value], [int_value], [float_value], [description])
VALUES (SOURCE.[parameter], SOURCE.[string_value], SOURCE.[int_value], SOURCE.[float_value], SOURCE.[description]);



MERGE dbo.OperationTypes as TARGET
USING (SELECT * FROM @Ops) as SOURCE ([subsystem_id], [action_type_id], [subsystem_name], [action_type_name])
ON (TARGET.subsystem_id = SOURCE.subsystem_id and TARGET.action_type_id = SOURCE.action_type_id)

WHEN MATCHED THEN UPDATE SET subsystem_name = SOURCE.subsystem_name, action_type_name = SOURCE.action_type_name
WHEN NOT MATCHED THEN INSERT ([subsystem_id], [action_type_id], [subsystem_name], [action_type_name])
VALUES (SOURCE.[subsystem_id], SOURCE.[action_type_id], SOURCE.[subsystem_name], SOURCE.[action_type_name]);



INSERT dbo.DbVersion (Version,DateInstalled) VALUES ('2.0.2.4 Beta',getdate())
GO

UPDATE VBMS.dbo.Tasks 
SET exit_code = -1
WHERE result = 'Skipped. Not enough time left'
and exit_code is null


/*

changelog:
2.0.2.5a
	- FIX: 3 entries for a non-partitioned clustered index
	- FIX: Clustered columnstore index statistics update tasks where generated which are not possible to execute.
	- FIX: Statistics update tasks are generated with no regard to personal blacklist entries (worker_name field is ignored)
	- FIX: Stats that were added during execution loop has unrealisticly prescise time prognosis du to post-execution evaluation

2.0.2.4b
	- Added volume_mount_point to collection to improve future prediction model
	- FillQueueAll - added @debug parameter. If @debug = 1 procedure returns the list of frag analysis results and tasks generated
2.0.2.3b
	- FIX - afterparty does not work. at all. Old stupid typo.
	- dbo.StartWorker - added NOCOUNT ON.

2.0.2.2b
	- Added view dbo.FragAnalysisStatus to view statistics of framentation analysis tasks
	- Added support of creating blacklist items for a specific workers.
	- FIX - apriori timefactors too high 
	- FIX - time_prognosis_s column type changed to bigint to avoid overflow 
	- Tables with 0 records are excluded from checks
	- FillQueue is now managed as a worker
	- FillQueue - frag collection tasks now support LOCK_TIMEOUT feature to avoid hanging on frag collection
	- FIllQueue - frag collection now supports blacklists

*/
GO

GO
PRINT N'Update complete.';


GO