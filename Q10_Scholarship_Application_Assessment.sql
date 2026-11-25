-- =====================================================================
-- ICT371 Advanced Database | Question 10: Scholarship Application Assessment
-- Target DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Run with:  psql -d your_database -f Q10_Scholarship_Application_Assessment.sql
-- Eligible only when: age 18..25 inclusive AND monthly income <= 3000 AND average mark >= 70.
-- =====================================================================

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

CREATE TABLE students (
    student_id      SERIAL       PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id      SERIAL        PRIMARY KEY,
    student_id          INTEGER       NOT NULL REFERENCES students (student_id),
    age_at_application  INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income      NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark        NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on        DATE          NOT NULL,
    status              VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id        SERIAL      PRIMARY KEY,
    application_id  INTEGER     NOT NULL REFERENCES applications (application_id),
    old_status      VARCHAR(10) NOT NULL,
    new_status      VARCHAR(10) NOT NULL,
    changed_at      TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO students (student_number, full_name) VALUES
    ('SCH001', 'Chileshe Mutale'),
    ('SCH002', 'Namukolo Hamoonga'),
    ('SCH003', 'Peter Kasonde');

-- Six PENDING applications: qualifying, non-qualifying and boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 20, 'PENDING'),   -- 1: all boundaries met  => APPROVED
    (1, 25, 1500.00, 85.00, CURRENT_DATE - 15, 'PENDING'),   -- 2: upper age boundary  => APPROVED
    (2, 26, 1000.00, 90.00, CURRENT_DATE - 12, 'PENDING'),   -- 3: age 26              => REJECTED
    (2, 20, 3000.01, 80.00, CURRENT_DATE - 10, 'PENDING'),   -- 4: income just above   => REJECTED
    (3, 22, 2000.00, 69.99, CURRENT_DATE - 5,  'PENDING'),   -- 5: mark just below     => REJECTED
    (3, 17, 500.00,  95.00, CURRENT_DATE - 2,  'PENDING');   -- 6: age 17              => REJECTED

-- ---------------------------------------------------------------------
-- (b) Function fn_scholarship_eligible
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure pr_assess_application
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status VARCHAR(10);
    v_age    INTEGER;
    v_income NUMERIC(12,2);
    v_mark   NUMERIC(5,2);
BEGIN
    SELECT status, age_at_application, monthly_income, average_mark
    INTO v_status, v_age, v_income, v_mark
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;                                  -- lock: no double assessment

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status: %)',
                        p_application_id, v_status;
    END IF;

    UPDATE applications
    SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                      THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: audit actual status changes (AFTER UPDATE, row level)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_decision_audit ON applications;
CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- ---------------------------------------------------------------------
-- (e) View: v_approved_applicants (income is deliberately NOT exposed)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- ---------------------------------------------------------------------
-- (f) Index: status (equality) first, then submitted_on (range)
-- ---------------------------------------------------------------------
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_assess_pending
--     Only rows with status = 'PENDING' are visited, so a rerun finds nothing
--     to do for completed applications and cannot create duplicate audit rows.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every Monday at 08:00
SELECT cron.schedule(
    'scholarship_assess_pending',
    '0 8 * * 1',
    $$CALL pr_assess_pending()$$
);

-- =====================================================================
-- DEMONSTRATION / TESTING
-- =====================================================================

-- (b)
SELECT fn_scholarship_eligible(18, 3000, 70)    AS all_boundaries,   -- true
       fn_scholarship_eligible(25, 3000, 70)    AS age_25,           -- true
       fn_scholarship_eligible(26, 1000, 90)    AS age_26,           -- false
       fn_scholarship_eligible(20, 3000.01, 80) AS income_above,     -- false
       fn_scholarship_eligible(22, 2000, 69.99) AS mark_below;       -- false
-- SELECT fn_scholarship_eligible(NULL, 1000, 80);   -- ERROR
-- SELECT fn_scholarship_eligible(0, 1000, 80);      -- ERROR
-- SELECT fn_scholarship_eligible(20, -1, 80);       -- ERROR
-- SELECT fn_scholarship_eligible(20, 1000, 101);    -- ERROR

-- (c) Assess one application, then try to assess it again
CALL pr_assess_application(1);
-- CALL pr_assess_application(1);    -- ERROR: already assessed
-- CALL pr_assess_application(99);   -- ERROR: unknown application

-- (d) Updating something that is not the status writes no audit row
UPDATE applications SET submitted_on = submitted_on WHERE application_id = 2;
SELECT * FROM decision_audit ORDER BY audit_id;     -- one row (application 1)

-- (g) Process the remaining PENDING ones, then rerun
CALL pr_assess_pending();
CALL pr_assess_pending();                           -- does nothing

SELECT * FROM applications ORDER BY application_id;
SELECT * FROM decision_audit ORDER BY audit_id;     -- exactly six rows, no duplicates

-- (e)
SELECT * FROM v_approved_applicants ORDER BY student_number;   -- applications 1 and 2

-- (f) EXPLAIN (seqscan disabled only because the demo table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

SELECT jobid, jobname, schedule, command, active FROM cron.job;
