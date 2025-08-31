#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/proc.h"
#include "tcop/tcopprot.h"
#include "utils/elog.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"
#include "access/xact.h"
#include "executor/spi.h"
#include "libpq/pqsignal.h"
#include "utils/builtins.h"
#include <stdint.h>

PG_MODULE_MAGIC;

void _PG_init(void);
void scheduler_main(Datum arg);
static void scheduler_sigterm(SIGNAL_ARGS);

static volatile sig_atomic_t got_sigterm = false;

void
_PG_init(void)
{
    BackgroundWorker worker;
    MemSet(&worker, 0, sizeof(BackgroundWorker));
    
    worker.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
    worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
    worker.bgw_restart_time = 30;
    
    // Правильное заполнение строковых полей
    snprintf(worker.bgw_name, BGW_MAXLEN, "pg_scheduler_worker");
    snprintf(worker.bgw_function_name, BGW_MAXLEN, "scheduler_main");
    snprintf(worker.bgw_library_name, BGW_MAXLEN, "pg_scheduler");
    
    worker.bgw_notify_pid = 0;
    
    RegisterBackgroundWorker(&worker);
}

static void
scheduler_sigterm(SIGNAL_ARGS)
{
    int save_errno = errno;
    got_sigterm = true;
    if (MyProc)
        SetLatch(&MyProc->procLatch);
    errno = save_errno;
}

static const char *
spi_result_to_string(int res)
{
    switch (res)
    {
        case SPI_OK_CONNECT:     return "SPI_OK_CONNECT";
        case SPI_OK_FINISH:      return "SPI_OK_FINISH";
        case SPI_OK_FETCH:       return "SPI_OK_FETCH";
        case SPI_OK_UTILITY:     return "SPI_OK_UTILITY";
        case SPI_OK_SELECT:      return "SPI_OK_SELECT";
        case SPI_OK_SELINTO:     return "SPI_OK_SELINTO";
        case SPI_OK_INSERT:      return "SPI_OK_INSERT";
        case SPI_OK_DELETE:      return "SPI_OK_DELETE";
        case SPI_OK_UPDATE:      return "SPI_OK_UPDATE";
        case SPI_OK_CURSOR:      return "SPI_OK_CURSOR";
        case SPI_OK_INSERT_RETURNING: return "SPI_OK_INSERT_RETURNING";
        case SPI_OK_DELETE_RETURNING: return "SPI_OK_DELETE_RETURNING";
        case SPI_OK_UPDATE_RETURNING: return "SPI_OK_UPDATE_RETURNING";
        case SPI_OK_REWRITTEN:   return "SPI_OK_REWRITTEN";
        case SPI_ERROR_CONNECT:  return "SPI_ERROR_CONNECT";
        case SPI_ERROR_COPY:     return "SPI_ERROR_COPY";
        case SPI_ERROR_OPUNKNOWN:return "SPI_ERROR_OPUNKNOWN";
        case SPI_ERROR_UNCONNECTED: return "SPI_ERROR_UNCONNECTED";
        case SPI_ERROR_ARGUMENT: return "SPI_ERROR_ARGUMENT";
        case SPI_ERROR_PARAM:    return "SPI_ERROR_PARAM";
        case SPI_ERROR_TRANSACTION: return "SPI_ERROR_TRANSACTION";
        case SPI_ERROR_NOATTRIBUTE: return "SPI_ERROR_NOATTRIBUTE";
        case SPI_ERROR_NOOUTFUNC:return "SPI_ERROR_NOOUTFUNC";
        case SPI_ERROR_TYPUNKNOWN: return "SPI_ERROR_TYPUNKNOWN";
        case SPI_ERROR_REL_DUPLICATE: return "SPI_ERROR_REL_DUPLICATE";
        case SPI_ERROR_REL_NOT_FOUND: return "SPI_ERROR_REL_NOT_FOUND";
        default:                 return "UNKNOWN SPI RESULT";
    }
}

void
scheduler_main(Datum arg)
{
    pqsignal(SIGTERM, scheduler_sigterm);
    BackgroundWorkerUnblockSignals();

    BackgroundWorkerInitializeConnection("postgres", NULL, 0);

    elog(LOG, "pg_scheduler worker started");

    while (!got_sigterm)
    {
        int rc;
        int ret;
        int spi_connect;
        uint64_t i;

        spi_connect = SPI_connect();
        if (spi_connect != SPI_OK_CONNECT)
        {
            elog(LOG, "pg_scheduler: SPI_connect failed: %s", 
                 spi_result_to_string(spi_connect));
            goto sleep;
        }

        ret = SPI_execute(
            "SELECT job_id, command "
            "FROM scheduler.jobs "
            "WHERE enabled AND next_run_at <= now() "
            "ORDER BY next_run_at",
            true, 0
        );

        if (ret != SPI_OK_SELECT)
        {
            elog(LOG, "pg_scheduler: failed to select jobs: %s", 
                 spi_result_to_string(ret));
            SPI_finish();
            goto sleep;
        }

        if (SPI_processed > 0)
        {
            for (i = 0; i < SPI_processed; i++)
            {
                bool isnull;
                int job_id;
                char *command;
                char *sql;
                int ret_exec;
                bool success;

                job_id = DatumGetInt32(SPI_getbinval(SPI_tuptable->vals[i], 
                                                   SPI_tuptable->tupdesc, 
                                                   1, &isnull));
                
                command = SPI_getvalue(SPI_tuptable->vals[i], 
                                     SPI_tuptable->tupdesc, 
                                     2);

                elog(LOG, "pg_scheduler: executing job %d: %s", job_id, command);

                sql = psprintf("SELECT scheduler.execute_job(%d)", job_id);
                
                ret_exec = SPI_execute(sql, false, 0);
                
                success = (ret_exec >= 0);
                
                if (!success)
                {
                    elog(LOG, "pg_scheduler: failed to execute job %d: %s (SPI status: %s)", 
                         job_id, sql, spi_result_to_string(ret_exec));
                }
                
                pfree(sql);
            }
        }

        SPI_finish();

sleep:
        rc = WaitLatch(&MyProc->procLatch,
                      WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
                      60000L,
                      0);

        ResetLatch(&MyProc->procLatch);

        if (rc & WL_POSTMASTER_DEATH)
            break;
    }

    elog(LOG, "pg_scheduler worker stopped");
}
