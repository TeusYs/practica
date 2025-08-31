CREATE SCHEMA scheduler;

CREATE TYPE scheduler.schedule_type AS ENUM ('ONCE', 'INTERVAL', 'CRON');

CREATE TABLE scheduler.schedules (
    schedule_id SERIAL PRIMARY KEY,
    schedule_name TEXT NOT NULL,
    schedule_type scheduler.schedule_type NOT NULL,
    schedule_details JSONB NOT NULL,
    timezone TEXT DEFAULT 'UTC',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    next_run TIMESTAMPTZ
);

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
    username TEXT,   -- DEFAULT removed
    database TEXT    -- DEFAULT removed
);

CREATE TABLE scheduler.job_history (
    history_id BIGSERIAL PRIMARY KEY,
    job_id INTEGER NOT NULL REFERENCES scheduler.jobs(job_id) ON DELETE CASCADE,
    run_at TIMESTAMPTZ DEFAULT NOW(),
    finished_at TIMESTAMPTZ,
    success BOOLEAN,
    output TEXT,
    pid INTEGER
);

CREATE OR REPLACE FUNCTION scheduler.calculate_next_run(p_schedule_id INTEGER)
RETURNS TIMESTAMPTZ AS $$
DECLARE
    sched RECORD;
    next_run TIMESTAMPTZ;
BEGIN
    SELECT * INTO sched FROM scheduler.schedules WHERE schedule_id = p_schedule_id;
    
    CASE sched.schedule_type
        WHEN 'ONCE' THEN
            next_run := (sched.schedule_details->>'run_at')::TIMESTAMPTZ;
        WHEN 'INTERVAL' THEN
            next_run := NOW() + (sched.schedule_details->>'interval')::INTERVAL;
        WHEN 'CRON' THEN
            next_run := NOW() + INTERVAL '1 minute';
        ELSE
            RAISE EXCEPTION 'Unknown schedule type: %', sched.schedule_type;
    END CASE;
    
    RETURN next_run;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION scheduler.add_job(
    job_name TEXT,
    command TEXT,
    schedule_type scheduler.schedule_type,
    schedule_details JSONB,
    enabled BOOLEAN DEFAULT TRUE
) RETURNS INTEGER AS $$
DECLARE
    schedule_id INTEGER;
    job_id INTEGER;
    v_next_run TIMESTAMPTZ;
BEGIN
    INSERT INTO scheduler.schedules (schedule_name, schedule_type, schedule_details)
    VALUES (job_name || '_schedule', schedule_type, schedule_details)
    RETURNING schedule_id INTO schedule_id;
    
    v_next_run := scheduler.calculate_next_run(schedule_id);
    
    INSERT INTO scheduler.jobs (
        job_name,
        command,
        schedule_id,
        enabled,
        next_run_at,
        username,
        database
    ) VALUES (
        job_name,
        command,
        schedule_id,
        enabled,
        v_next_run,
        CURRENT_USER,
        CURRENT_DATABASE()
    ) RETURNING job_id INTO job_id;
    
    RETURN job_id;
END;
$$ LANGUAGE plpgsql;

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
BEGIN
    SELECT * INTO job FROM scheduler.jobs WHERE job_id = job_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Job % not found', job_id;
    END IF;
    
    start_time := clock_timestamp();
    
    BEGIN
        IF job.command LIKE 'SQL:%' THEN
            EXECUTE substring(job.command FROM 5) INTO command_result;
            success := TRUE;
            output_text := 'SQL executed: ' || command_result;
        ELSE
            IF NOT pg_has_role(session_user, 'superuser', 'MEMBER') THEN
                RAISE EXCEPTION 'Shell commands require superuser privileges';
            END IF;
            
            pid := pg_backend_pid();
            EXECUTE format('COPY (SELECT pg_catalog.pg_sleep(0)) TO PROGRAM %L', job.command);
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

CREATE OR REPLACE FUNCTION scheduler.start_worker()
RETURNS VOID AS $$
BEGIN
    RAISE NOTICE 'Worker is managed by background worker process';
END;
$$ LANGUAGE plpgsql;
