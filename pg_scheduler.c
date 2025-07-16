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
    worker.bgw_main = scheduler_main;
    worker.bgw_name = "pg_scheduler_worker";
    worker.bgw_notify_pid = 0;
    snprintf(worker.bgw_library_name, BGW_MAXLEN, "pg_scheduler");
    snprintf(worker.bgw_function_name, BGW_MAXLEN, "scheduler_main");
    
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

void
scheduler_main(Datum arg)
{
    /* Устанавливаем обработчики сигналов */
    pqsignal(SIGTERM, scheduler_sigterm);
    BackgroundWorkerUnblockSignals();

    /* Инициализируем соединение с БД */
    BackgroundWorkerInitializeConnection("postgres", NULL, 0);

    elog(LOG, "pg_scheduler worker started");

    while (!got_sigterm)
    {
        int rc;
        bool connected = false;
        int ret;
        TimestampTz current_time;
        int spi_connect;

        /* Подключаемся к SPI */
        spi_connect = SPI_connect();
        if (spi_connect != SPI_OK_CONNECT)
        {
            elog(LOG, "pg_scheduler: SPI_connect failed");
            goto sleep;
        }
        connected = true;

        /* Получаем текущее время */
        current_time = GetCurrentTimestamp();

        /* Ищем задания для выполнения */
        ret = SPI_execute(
            "SELECT job_id, command "
            "FROM scheduler.jobs "
            "WHERE enabled AND next_run_at <= now() "
            "ORDER BY next_run_at",
            true, 0
        );

        if (ret != SPI_OK_SELECT)
        {
            elog(LOG, "pg_scheduler: failed to select jobs");
            SPI_finish();
            connected = false;
            goto sleep;
        }

        /* Обрабатываем найденные задания */
        if (SPI_processed > 0)
        {
            for (uint64 i = 0; i < SPI_processed; i++)
            {
                bool isnull;
                int job_id = DatumGetInt32(SPI_getbinval(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 1, &isnull));
                char *command = SPI_getvalue(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 2);

                elog(LOG, "pg_scheduler: executing job %d: %s", job_id, command);

                /* Выполняем задание */
                char sql[256];
                snprintf(sql, sizeof(sql), "SELECT scheduler.execute_job(%d)", job_id);
                
                int ret_exec = SPI_execute(sql, false, 0);
                if (ret_exec != SPI_OK_SELECT && ret_exec != SPI_OK_INSERT)
                {
                    elog(LOG, "pg_scheduler: failed to execute job %d: %s", job_id, sql);
                }
            }
        }

        SPI_finish();
        connected = false;

sleep:
        /* Ждем 60 секунд или до получения сигнала */
        rc = WaitLatch(&MyProc->procLatch,
                      WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
                      60000L /* 60 seconds */,
                      WAIT_EXTENSION);

        ResetLatch(&MyProc->procLatch);

        /* Проверяем сигнал завершения */
        if (rc & WL_POSTMASTER_DEATH)
            break;
    }

    elog(LOG, "pg_scheduler worker stopped");
}