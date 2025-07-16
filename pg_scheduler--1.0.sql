CREATE SCHEMA scheduler;

-- Типы расписаний
CREATE TYPE scheduler.schedule_type AS ENUM ('ONCE', 'INTERVAL', 'CRON');

-- Таблица расписаний
CREATE TABLE scheduler.schedules (
    schedule_id SERIAL PRIMARY KEY,
    schedule_name TEXT NOT NULL,
    schedule_type scheduler.schedule_type NOT NULL,
    schedule_details JSONB NOT NULL,
    timezone TEXT DEFAULT 'UTC',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    next_run TIMESTAMPTZ
);

-- Таблица заданий
CREATE TABLE scheduler.jobs (
    job_id SERIAL PRIMARY KEY,
    job_name TEXT NOT NULL UNIQUE,
    command TEXT NOT NULL,
    schedule_id INTEGER NOT NULL REFERENCES scheduler.schedules(schedule_id) ON DELETE CASCADE,
    enabled BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_run_at TIMESTAMPTZ,
    next_run_at TIMESTAMPTZ,
    max_runtime INTERVAL,
    retry_on_failure BOOLEAN DEFAULT FALSE,
    retry_interval INTERVAL DEFAULT '5 minutes',
    max_retries INTEGER DEFAULT 3,
    username TEXT DEFAULT CURRENT_USER,
    database TEXT DEFAULT CURRENT_DATABASE
);

-- История выполнения
CREATE TABLE scheduler.job_history (
    history_id BIGSERIAL PRIMARY KEY,
    job_id INTEGER NOT NULL REFERENCES scheduler.jobs(job_id) ON DELETE CASCADE,
    run_at TIMESTAMPTZ DEFAULT NOW(),
    finished_at TIMESTAMPTZ,
    success BOOLEAN,
    output TEXT,
    pid INTEGER
);

-- Функция вычисления следующего времени выполнения (без изменений)
CREATE OR REPLACE FUNCTION scheduler.calculate_next_run(p_schedule_id INTEGER)
RETURNS TIMESTAMPTZ AS $$
-- ... (код из предыдущей версии) ...
$$ LANGUAGE plpgsql;

-- Функция добавления задания (без изменений)
CREATE OR REPLACE FUNCTION scheduler.add_job(
    job_name TEXT,
    command TEXT,
    schedule_type scheduler.schedule_type,
    schedule_details JSONB,
    enabled BOOLEAN DEFAULT TRUE
) RETURNS INTEGER AS $$
-- ... (код из предыдущей версии) ...
$$ LANGUAGE plpgsql;

-- АДАПТИРОВАННАЯ Функция выполнения задания для Windows
CREATE OR REPLACE FUNCTION scheduler.execute_job(job_id INTEGER)
RETURNS BOOLEAN AS $$
DECLARE
    job RECORD;
    start_time TIMESTAMPTZ;
    end_time TIMESTAMPTZ;
    success BOOLEAN;
    output_text TEXT;
    command_result TEXT;
    pid INT;
    shell_cmd TEXT;
BEGIN
    SELECT * INTO job FROM scheduler.jobs WHERE job_id = job_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Job % not found', job_id;
    END IF;
    
    start_time := clock_timestamp();
    
    BEGIN
        IF job.command LIKE 'SQL:%' THEN
            -- Выполнение SQL команды
            EXECUTE substring(job.command FROM 5) INTO command_result;
            success := TRUE;
            output_text := 'SQL executed: ' || command_result;
        ELSE
            -- Проверка прав для выполнения shell-команд
            IF NOT pg_has_role(session_user, 'superuser', 'MEMBER') THEN
                RAISE EXCEPTION 'Shell commands require superuser privileges';
            END IF;
            
            pid := pg_backend_pid();
            
            -- Адаптация для Windows: использование cmd.exe
            -- Экранирование специальных символов для Windows
            shell_cmd := REPLACE(job.command, '"', '""');
            shell_cmd := 'cmd /c "' || shell_cmd || '"';
            
            -- Выполнение команды через shell
            EXECUTE format('COPY (SELECT 1) TO PROGRAM %L', shell_cmd);
            success := TRUE;
            output_text := 'Shell command executed';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        success := FALSE;
        output_text := SQLERRM;
    END;
    
    end_time := clock_timestamp();
    
    UPDATE scheduler.jobs SET
        last_run_at = start_time,
        next_run_at = scheduler.calculate_next_run(job.schedule_id)
    WHERE job_id = job_id;
    
    INSERT INTO scheduler.job_history (
        job_id,
        run_at,
        finished_at,
        success,
        output,
        pid
    ) VALUES (
        job_id,
        start_time,
        end_time,
        success,
        output_text,
        pid
    );
    
    RETURN success;
END;
$$ LANGUAGE plpgsql;

-- Функция запуска worker (без изменений)
CREATE OR REPLACE FUNCTION scheduler.start_worker()
RETURNS VOID AS $$
BEGIN
    RAISE NOTICE 'Worker is managed by background worker process';
END;
$$ LANGUAGE plpgsql;