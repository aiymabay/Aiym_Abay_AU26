/*
   DIFFERENCES FROM THE LOGICAL MODEL (also shown in the updated diagram)
     1. record_ts DATE NOT NULL DEFAULT CURRENT_DATE is added to every table (task requirement).
     2. person.full_name is added as a GENERATED ALWAYS AS ... STORED column (task requirement).
        It is calculated only from first_name and last_name of the same row and cannot be
        written directly, so it cannot become inconsistent and creates no update anomaly.
     3. CHECK "later than 2000-01-01" is added to six operational dates (task requirement):
        candidate.registered_at, service_usage.requested_at, job_posting.posted_at,
        application.applied_at, interview.scheduled_at, placement.start_date.
        It is not added to person.date_of_birth and work_experience.start_date, because people
        are born and start working before 2000.
     4. CHECK on the format of currency_code (three capital letters, ISO 4217).
     No tables or relationships were added or removed. All data types are the same as in the
     logical model.
*/


/* STEP 0. DATABASE - run once
   PostgreSQL has no CREATE DATABASE IF NOT EXISTS and CREATE DATABASE cannot run inside a
   transaction block, so it is the only statement that cannot be made rerunnable in plain SQL.
   That is why I kept here as a one-time step.

   CREATE DATABASE recruitment_agency_db;
*/

/*
   STEP 1. SCHEMA
   A separate schema keeps the agency objects apart from "public" and lets every object be
   referenced with an explicit schema name.
*/

CREATE SCHEMA IF NOT EXISTS recruitment_agency;


/*
   STEP 2. TABLES
   WHY THE ORDER OF DDL MATTERS:
     A FOREIGN KEY can only reference a table that already exists. So parent tables are created
     first and child tables after them:
       	level 0 (no FKs): person, company, city, skill
       	level 1: candidate, company_representative
       	level 2: candidate_preferred_location, work_experience, service_usage, job_posting
       	level 3: service_usage_status_history, candidate_skill, application
       	level 4: application_status_history, interview, placement
     
     If the order is wrong, e.g. candidate is created before person, PostgreSQL stops with
       ERROR: relation "recruitment_agency.person" does not exist  (SQLSTATE 42P01)
     and the child table is not created at all. 
     
     The same rule works backwards for DROP:
     a parent cannot be dropped while a child references it (SQLSTATE 2BP01).

   DATA TYPES AND THE RISK OF CHOOSING A WRONG ONE:
     INTEGER identity keys   -2.1 billion values is enough for an agency. SMALLINT could overflow
                              (32 767 rows); a text key would be slow to join and allow '01' vs '1'.
     VARCHAR(n)              -names, titles, codes with a known maximum length. Too short a length rejects or cuts valid values; 
                              storing numbers or dates as text would
                              allow '31-02-2026' or 'abc' and break sorting and arithmetic.
     TEXT - descriptions and comments with no natural limit; VARCHAR(n) there would reject long but valid text.
     CHAR(2) / CHAR(3)       -ISO country and currency codes always have a fixed length.
     DATE                    -facts where only the day matters (birth, start and end of a period).
                              TIMESTAMP here would add a meaningless time part and make
                              comparisons like end_date >= start_date depend on hours.
     TIMESTAMPTZ             -moments of events (applied, changed, scheduled). TIMESTAMP without
                              time zone would shift the moment for users in another time zone
                              and could reorder a status history.
     NUMERIC(12,2)/(10,2)    -money. REAL / DOUBLE PRECISION are approximate: sums would get
                              rounding errors (0.1 + 0.2 <> 0.3). INTEGER would lose the tiyn part.
     SMALLINT                -small counters (level 1-5, round number, minutes); saves space and
                              documents that the value is small.
     BOOLEAN                 -yes/no flags. A 'Y'/'N' or 0/1 column would allow a third value.

   WHAT HAPPENS IF A FOREIGN KEY IS MISSING:
     Without an FK the database does not check that the parent row exists. It would be possible to 
     insert an application for candidate_id = 999 that does not exist, or to delete a candidate
     and leave his applications, skills and interviews behind as "orphan" rows. JOINs would then
     silently lose such rows, counts in reports would not match, and nobody would get an error.
    
     With the FK the wrong INSERT/DELETE is rejected (SQLSTATE 23503). All FKs below use the default
     ON DELETE NO ACTION: the model keeps history, so a parent with children must not disappear.

   names:
     pk_<table>_<columns>, fk_<table>_<columns>, uq_<table>_<columns>, chk_<table>_<column or rule>.
*/

--person: a human the agency knows, independent of role. Level 0, no FKs.
--generated column: always equal to first_name + last_name, cannot be inserted or updated by hand.
CREATE TABLE IF NOT EXISTS recruitment_agency.person (
	person_id INTEGER GENERATED ALWAYS AS IDENTITY,
	first_name VARCHAR(50) NOT NULL,
	last_name VARCHAR(50) NOT NULL,
	full_name       VARCHAR(101)    GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED,
	email           VARCHAR(150)    NOT NULL,
	phone           VARCHAR(20),
	date_of_birth   DATE,
	created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
	CONSTRAINT pk_person_person_id PRIMARY KEY (person_id),
	--UNIQUE: prevents the same human being registered twice. Without it one person could get two rows and his applications and roles would be split between them.
	CONSTRAINT uq_person_email UNIQUE (email),
	-- CHECK: prevents a birth date in the future (typing mistake like 2099). Without it the age of a candidate could be negative.
	CONSTRAINT chk_person_date_of_birth CHECK (date_of_birth < CURRENT_DATE)
);
--NOT NULL on first_name, last_name, email: prevents "empty" persons that cannot be identified or contacted. Without it a row with only an id could exist and be linked to applications.

-- company: a client company that posts jobs. Level 0, no FKs.
CREATE TABLE IF NOT EXISTS recruitment_agency.company (
	company_id              INTEGER         GENERATED ALWAYS AS IDENTITY,
	company_name            VARCHAR(200)    NOT NULL,
	registration_number     VARCHAR(30),
	industry                VARCHAR(100)    NOT NULL,
	website_url             VARCHAR(255),
	is_active               BOOLEAN         NOT NULL DEFAULT TRUE,
	created_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),
	CONSTRAINT pk_company_company_id PRIMARY KEY (company_id),
	-- UNIQUE: the BIN identifies one legal entity. Without it the same company could be entered twice and its postings and fees would be split between two rows.
	-- VARCHAR, not a number: a BIN can start with 0 ('050240009876') and a numeric type would drop it.
	CONSTRAINT uq_company_registration_number UNIQUE (registration_number)
);

-- city: a city in a country, shared by preferred locations and job postings. Level 0, no FKs.
CREATE TABLE IF NOT EXISTS recruitment_agency.city (
	city_id         INTEGER         GENERATED ALWAYS AS IDENTITY,
	city_name       VARCHAR(100)    NOT NULL,
	country_code    CHAR(2)         NOT NULL,
	CONSTRAINT pk_city_city_id PRIMARY KEY (city_id),
	-- UNIQUE: one row per city in a country. Without it 'Almaty, KZ' could exist several times and candidates and postings for the same city would not match each other.
	CONSTRAINT uq_city_city_name_country_code UNIQUE (city_name, country_code),
	--CHECK: only two capital letters (ISO 3166-1 alpha-2). Prevents 'kz', 'K1' or 'K '.
	--without it the same country could be written in several ways.
	CONSTRAINT chk_city_country_code CHECK (country_code ~ '^[A-Z]{2}$')
);

-- skill: catalogue of skills. Level 0, no FKs.
CREATE TABLE IF NOT EXISTS recruitment_agency.skill (
	skill_id        INTEGER         GENERATED ALWAYS AS IDENTITY,
	skill_name      VARCHAR(100)    NOT NULL,
	skill_category  VARCHAR(20)     NOT NULL,
	CONSTRAINT pk_skill_skill_id PRIMARY KEY (skill_id),
	-- UNIQUE: prevents the same skill appearing twice in the catalogue. Without it "candidates
	-- who know SQL" would have to be searched under several skill_id values.
	CONSTRAINT uq_skill_skill_name UNIQUE (skill_name),
	-- CHECK (specific values): prevents misspelled or invented categories ('tech', 'Technical').
	-- Without it grouping skills by category would give several groups for the same thing.
	CONSTRAINT chk_skill_skill_category CHECK (skill_category IN ('technical', 'language', 'soft'))
);

--candidate: the job-seeker role of a person. Level 1, parent: person.
CREATE TABLE IF NOT EXISTS recruitment_agency.candidate (
	candidate_id    INTEGER         GENERATED ALWAYS AS IDENTITY,
	person_id       INTEGER         NOT NULL,
	cv_url          VARCHAR(255),
	source          VARCHAR(20)     NOT NULL,
	registered_at   TIMESTAMPTZ     NOT NULL DEFAULT now(),
	CONSTRAINT pk_candidate_candidate_id PRIMARY KEY (candidate_id),
	CONSTRAINT fk_candidate_person_id FOREIGN KEY (person_id)
		REFERENCES recruitment_agency.person (person_id),
	--UNIQUE: one person has at most one candidate profile (1 : 0..1). Without it a person could have two profiles with different CVs and applications.
	CONSTRAINT uq_candidate_person_id UNIQUE (person_id),
	-- CHECK (specific values): only the four known channels. Without it 'web', 'Website' and 'website' would be counted as different sources in marketing reports.
	CONSTRAINT chk_candidate_source CHECK (source IN ('website', 'referral', 'job_board', 'social_media')),
	--CHECK (date > 2000-01-01): prevents placeholder or mistyped dates like 1900-01-01 or 0026-03-02.
	--without it "candidates registered per year" would show impossible years.
	CONSTRAINT chk_candidate_registered_at CHECK (registered_at > TIMESTAMPTZ '2000-01-01 00:00:00+00')
);

-- company_representative: a person acting for a company during a period. Level 1, parents: person, company.
CREATE TABLE IF NOT EXISTS recruitment_agency.company_representative (
	company_representative_id   INTEGER         GENERATED ALWAYS AS IDENTITY,
	person_id                   INTEGER         NOT NULL,
	company_id                  INTEGER         NOT NULL,
	job_title                   VARCHAR(100)    NOT NULL,
	start_date                  DATE            NOT NULL DEFAULT CURRENT_DATE,
	end_date                    DATE,
	CONSTRAINT pk_company_representative_company_representative_id PRIMARY KEY (company_representative_id),
	CONSTRAINT fk_company_representative_person_id FOREIGN KEY (person_id)
		REFERENCES recruitment_agency.person (person_id),
	CONSTRAINT fk_company_representative_company_id FOREIGN KEY (company_id)
		REFERENCES recruitment_agency.company (company_id),
	--UNIQUE: the same person cannot start representing the same company twice on one day.
	CONSTRAINT uq_company_representative_person_id_company_id_start_date UNIQUE (person_id, company_id, start_date),
	--CHECK: a period cannot end before it starts. Without it the length of a period would be negative and "who represented the company on date X" would give wrong answers.
	CONSTRAINT chk_company_representative_end_date CHECK (end_date >= start_date)
);

-- candidate_preferred_location: a city where a candidate wants to work, for a period. Level 2, parents: candidate, city.
CREATE TABLE IF NOT EXISTS recruitment_agency.candidate_preferred_location (
	candidate_id    INTEGER     NOT NULL,
	city_id         INTEGER     NOT NULL,
	valid_from      DATE        NOT NULL DEFAULT CURRENT_DATE,
	valid_to        DATE,
	is_remote_ok    BOOLEAN     NOT NULL DEFAULT FALSE,
	-- Composite PK: the same city can be preferred again later, so the start date is part of the key.
	CONSTRAINT pk_candidate_preferred_location_candidate_id_city_id_valid_from PRIMARY KEY (candidate_id, city_id, valid_from),
	CONSTRAINT fk_candidate_preferred_location_candidate_id FOREIGN KEY (candidate_id)
		REFERENCES recruitment_agency.candidate (candidate_id),
	CONSTRAINT fk_candidate_preferred_location_city_id FOREIGN KEY (city_id)
		REFERENCES recruitment_agency.city (city_id),
	CONSTRAINT chk_candidate_preferred_location_valid_to CHECK (valid_to >= valid_from)
);

-- work_experience: one past or current job of a candidate. Level 2, parent: candidate.
CREATE TABLE IF NOT EXISTS recruitment_agency.work_experience (
	work_experience_id  INTEGER         GENERATED ALWAYS AS IDENTITY,
	candidate_id        INTEGER         NOT NULL,
	employer_name       VARCHAR(200)    NOT NULL,
	job_title           VARCHAR(150)    NOT NULL,
	start_date          DATE            NOT NULL,
	end_date            DATE,
	description         TEXT,
	CONSTRAINT pk_work_experience_work_experience_id PRIMARY KEY (work_experience_id),
	CONSTRAINT fk_work_experience_candidate_id FOREIGN KEY (candidate_id)
		REFERENCES recruitment_agency.candidate (candidate_id),
	--CHECK: a job cannot end before it starts; otherwise years of experience would be negative.
	CONSTRAINT chk_work_experience_end_date CHECK (end_date >= start_date)
);

-- service_usage: one resume advice, coaching or skills testing service for a candidate. Level 2, parent: candidate. Created before candidate_skill, which references it.
CREATE TABLE IF NOT EXISTS recruitment_agency.service_usage (
	service_usage_id    INTEGER         GENERATED ALWAYS AS IDENTITY,
	candidate_id        INTEGER         NOT NULL,
	service_type        VARCHAR(20)     NOT NULL,
	requested_at        TIMESTAMPTZ     NOT NULL DEFAULT now(),
	price_charged       NUMERIC(10,2)   NOT NULL DEFAULT 0,
	currency_code       CHAR(3)         NOT NULL DEFAULT 'KZT',
	CONSTRAINT pk_service_usage_service_usage_id PRIMARY KEY (service_usage_id),
	CONSTRAINT fk_service_usage_candidate_id FOREIGN KEY (candidate_id)
		REFERENCES recruitment_agency.candidate (candidate_id),
	--CHECK (specific values): the agency offers exactly three services.
	CONSTRAINT chk_service_usage_service_type CHECK (service_type IN ('resume_advice', 'coaching', 'skills_testing')),
	--CHECK (date > 2000-01-01): same reason as candidate.registered_at.
	CONSTRAINT chk_service_usage_requested_at CHECK (requested_at > TIMESTAMPTZ '2000-01-01 00:00:00+00'),
	--CHECK (measured value not negative): a price of -15000 would reduce the revenue total instead of increasing it. 0 is allowed and means a free service.
	CONSTRAINT chk_service_usage_price_charged CHECK (price_charged >= 0),
	--CHECK: three capital letters (ISO 4217). Prevents 'kzt', 'KZ', 'tg'; without it sums per currency would be split between several spellings.
	CONSTRAINT chk_service_usage_currency_code CHECK (currency_code ~ '^[A-Z]{3}$')
);

-- service_usage_status_history: every status change of a service usage (insert-only). Level 3, parent: service_usage.
CREATE TABLE IF NOT EXISTS recruitment_agency.service_usage_status_history (
	service_usage_status_history_id     INTEGER         GENERATED ALWAYS AS IDENTITY,
	service_usage_id                    INTEGER         NOT NULL,
	status                              VARCHAR(20)     NOT NULL,
	changed_at                          TIMESTAMPTZ     NOT NULL DEFAULT now(),
	note                                TEXT,
	CONSTRAINT pk_service_usage_status_history_id PRIMARY KEY (service_usage_status_history_id),
	CONSTRAINT fk_service_usage_status_history_service_usage_id FOREIGN KEY (service_usage_id)
		REFERENCES recruitment_agency.service_usage (service_usage_id),
	--UNIQUE: one service cannot have two statuses at the same moment; otherwise the "latest row is the current status" rule would be ambiguous.
	CONSTRAINT uq_service_usage_status_history_service_usage_id_changed_at UNIQUE (service_usage_id, changed_at),
	CONSTRAINT chk_service_usage_status_history_status CHECK (status IN ('requested', 'scheduled', 'in_progress', 'completed', 'cancelled'))
);

-- candidate_skill: a dated level of one skill for one candidate (M:N candidate - skill). Level 3, parents: candidate, skill, service_usage.
CREATE TABLE IF NOT EXISTS recruitment_agency.candidate_skill (
	candidate_id        INTEGER         NOT NULL,
	skill_id            INTEGER         NOT NULL,
	assessed_on         DATE            NOT NULL DEFAULT CURRENT_DATE,
	proficiency_level   SMALLINT        NOT NULL,
	assessment_source   VARCHAR(20)     NOT NULL,
	service_usage_id    INTEGER,
	CONSTRAINT pk_candidate_skill_candidate_id_skill_id_assessed_on PRIMARY KEY (candidate_id, skill_id, assessed_on),
	CONSTRAINT fk_candidate_skill_candidate_id FOREIGN KEY (candidate_id)
		REFERENCES recruitment_agency.candidate (candidate_id),
	CONSTRAINT fk_candidate_skill_skill_id FOREIGN KEY (skill_id)
		REFERENCES recruitment_agency.skill (skill_id),
	CONSTRAINT fk_candidate_skill_service_usage_id FOREIGN KEY (service_usage_id)
		REFERENCES recruitment_agency.service_usage (service_usage_id),
	--CHECK: the scale is 1 (beginner) to 5 (expert). Prevents 0, -1 or 50; without it the average level and "level >= 4" filters would be meaningless.
	CONSTRAINT chk_candidate_skill_proficiency_level CHECK (proficiency_level BETWEEN 1 AND 5),
	CONSTRAINT chk_candidate_skill_assessment_source CHECK (assessment_source IN ('self_reported', 'skills_test')),
	--CHECK: a level from a skills test must point to that test, and a self-reported level must not.
	--without it a "tested" level could exist with no test behind it.
	CONSTRAINT chk_candidate_skill_source_matches_service CHECK ((assessment_source = 'skills_test') = (service_usage_id IS NOT NULL))
);

-- job_posting: a job a company asks the agency to fill. Level 2, parents: company, city and itself (previous version of the posting).
CREATE TABLE IF NOT EXISTS recruitment_agency.job_posting (
	job_posting_id              INTEGER         GENERATED ALWAYS AS IDENTITY,
	company_id                  INTEGER         NOT NULL,
	previous_job_posting_id     INTEGER,
	city_id                     INTEGER         NOT NULL,
	job_title                   VARCHAR(150)    NOT NULL,
	description                 TEXT,
	employment_type             VARCHAR(20)     NOT NULL,
	salary_min                  NUMERIC(12,2),
	salary_max                  NUMERIC(12,2),
	currency_code               CHAR(3)         NOT NULL DEFAULT 'KZT',
	posted_at                   TIMESTAMPTZ     NOT NULL DEFAULT now(),
	closes_on                   DATE,
	CONSTRAINT pk_job_posting_job_posting_id PRIMARY KEY (job_posting_id),
	CONSTRAINT fk_job_posting_company_id FOREIGN KEY (company_id)
		REFERENCES recruitment_agency.company (company_id),
	--Self-reference: the parent row is in the same table, so the table already exists when
	--the FK is checked. The old posting must be inserted before the one that replaces it.
	CONSTRAINT fk_job_posting_previous_job_posting_id FOREIGN KEY (previous_job_posting_id)
		REFERENCES recruitment_agency.job_posting (job_posting_id),
	CONSTRAINT fk_job_posting_city_id FOREIGN KEY (city_id)
		REFERENCES recruitment_agency.city (city_id),
	--UNIQUE: a posting can be replaced by only one new posting, so versions form a chain, not a tree.
	CONSTRAINT uq_job_posting_previous_job_posting_id UNIQUE (previous_job_posting_id),
	--CHECK: a posting cannot replace itself.
	CONSTRAINT chk_job_posting_previous_job_posting_id CHECK (previous_job_posting_id <> job_posting_id),
	CONSTRAINT chk_job_posting_employment_type CHECK (employment_type IN ('full_time', 'part_time', 'contract', 'internship')),
	--CHECK (measured value not negative): a negative salary is impossible.
	CONSTRAINT chk_job_posting_salary_min CHECK (salary_min >= 0),
	--CHECK: the upper bound cannot be below the lower bound; otherwise no expected salary could ever fall inside the range.
	CONSTRAINT chk_job_posting_salary_max CHECK (salary_max >= salary_min),
	CONSTRAINT chk_job_posting_currency_code CHECK (currency_code ~ '^[A-Z]{3}$'),
	--CHECK (date > 2000-01-01): same reason as candidate.registered_at.
	CONSTRAINT chk_job_posting_posted_at CHECK (posted_at > TIMESTAMPTZ '2000-01-01 00:00:00+00')
);

-- application: a candidate applying to one posting (M:N candidate - job_posting). Level 3, parents: candidate, job_posting.
CREATE TABLE IF NOT EXISTS recruitment_agency.application (
	application_id      INTEGER         GENERATED ALWAYS AS IDENTITY,
	candidate_id        INTEGER         NOT NULL,
	job_posting_id      INTEGER         NOT NULL,
	applied_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),
	expected_salary     NUMERIC(12,2),
	cover_note          TEXT,
	CONSTRAINT pk_application_application_id PRIMARY KEY (application_id),
	CONSTRAINT fk_application_candidate_id FOREIGN KEY (candidate_id)
		REFERENCES recruitment_agency.candidate (candidate_id),
	CONSTRAINT fk_application_job_posting_id FOREIGN KEY (job_posting_id)
		REFERENCES recruitment_agency.job_posting (job_posting_id),
	--UNIQUE: a candidate applies to a posting only once. Without it a double click would create
	--two applications with two separate status histories.
	CONSTRAINT uq_application_candidate_id_job_posting_id UNIQUE (candidate_id, job_posting_id),
	CONSTRAINT chk_application_applied_at CHECK (applied_at > TIMESTAMPTZ '2000-01-01 00:00:00+00'),
	CONSTRAINT chk_application_expected_salary CHECK (expected_salary >= 0)
);

-- application_status_history: every status change of an application. Level 4, parent: application.
CREATE TABLE IF NOT EXISTS recruitment_agency.application_status_history (
	application_status_history_id   INTEGER         GENERATED ALWAYS AS IDENTITY,
	application_id                  INTEGER         NOT NULL,
	status                          VARCHAR(20)     NOT NULL,
	changed_at                      TIMESTAMPTZ     NOT NULL DEFAULT now(),
	comment                         TEXT,
	CONSTRAINT pk_application_status_history_id PRIMARY KEY (application_status_history_id),
	CONSTRAINT fk_application_status_history_application_id FOREIGN KEY (application_id)
		REFERENCES recruitment_agency.application (application_id),
	CONSTRAINT uq_application_status_history_application_id_changed_at UNIQUE (application_id, changed_at),
	-- CHECK (specific values): only the six steps of the process. Without it 'Approved', 'ok'
	-- or 'hired' could appear and the funnel report would miss those applications.
	CONSTRAINT chk_application_status_history_status CHECK (status IN ('submitted', 'under_review', 'interview', 'approved', 'rejected', 'withdrawn'))
);

-- interview: one interview round between a candidate and a company representative. Level 4, parents: application, company_representative.
CREATE TABLE IF NOT EXISTS recruitment_agency.interview (
	interview_id                INTEGER         GENERATED ALWAYS AS IDENTITY,
	application_id              INTEGER         NOT NULL,
	company_representative_id   INTEGER         NOT NULL,
	round_number                SMALLINT        NOT NULL,
	interview_type              VARCHAR(20)     NOT NULL,
	scheduled_at                TIMESTAMPTZ     NOT NULL,
	duration_minutes            SMALLINT,
	outcome                     VARCHAR(20)     NOT NULL DEFAULT 'pending',
	feedback                    TEXT,
	CONSTRAINT pk_interview_interview_id PRIMARY KEY (interview_id),
	CONSTRAINT fk_interview_application_id FOREIGN KEY (application_id)
		REFERENCES recruitment_agency.application (application_id),
	CONSTRAINT fk_interview_company_representative_id FOREIGN KEY (company_representative_id)
		REFERENCES recruitment_agency.company_representative (company_representative_id),
	-- UNIQUE: an application has only one round number 1, one round number 2 and so on.
	CONSTRAINT uq_interview_application_id_round_number UNIQUE (application_id, round_number),
	CONSTRAINT chk_interview_round_number CHECK (round_number > 0),
	CONSTRAINT chk_interview_interview_type CHECK (interview_type IN ('phone', 'video', 'onsite', 'technical')),
	CONSTRAINT chk_interview_scheduled_at CHECK (scheduled_at > TIMESTAMPTZ '2000-01-01 00:00:00+00'),
	-- CHECK (measured value): an interview cannot last 0 or -30 minutes.
	CONSTRAINT chk_interview_duration_minutes CHECK (duration_minutes > 0),
	CONSTRAINT chk_interview_outcome CHECK (outcome IN ('pending', 'passed', 'failed', 'no_show', 'cancelled'))
);

-- placement: hiring outcome of a successful application (1 : 0..1). Level 4, parent: application.
CREATE TABLE IF NOT EXISTS recruitment_agency.placement (
	placement_id    INTEGER         GENERATED ALWAYS AS IDENTITY,
	application_id  INTEGER         NOT NULL,
	start_date      DATE            NOT NULL,
	agreed_salary   NUMERIC(12,2)   NOT NULL,
	currency_code   CHAR(3)         NOT NULL DEFAULT 'KZT',
	fee_amount      NUMERIC(12,2)   NOT NULL,
	end_date        DATE,
	end_reason      VARCHAR(100),
	CONSTRAINT pk_placement_placement_id PRIMARY KEY (placement_id),
	CONSTRAINT fk_placement_application_id FOREIGN KEY (application_id)
		REFERENCES recruitment_agency.application (application_id),
	--UNIQUE: one application gives at most one hire. Without it the same hire could be entered twice and the agency fee would be counted twice.
	CONSTRAINT uq_placement_application_id UNIQUE (application_id),
	--CHECK (date > 2000-01-01): prevents mistyped years (1026, 0001) in the first working day.
	CONSTRAINT chk_placement_start_date CHECK (start_date > DATE '2000-01-01'),
	CONSTRAINT chk_placement_agreed_salary CHECK (agreed_salary > 0),
	CONSTRAINT chk_placement_currency_code CHECK (currency_code ~ '^[A-Z]{3}$'),
	--CHECK (measured value not negative): a negative fee would mean the agency pays the client.
	CONSTRAINT chk_placement_fee_amount CHECK (fee_amount >= 0),
	CONSTRAINT chk_placement_end_date CHECK (end_date >= start_date)
);


/*
   STEP 3. INDEXES
   
   PostgreSQL creates an index for every PRIMARY KEY and UNIQUE constraint, but not for a
   FOREIGN KEY. The FK columns below are not the first column of any PK/UNIQUE index, so joins
   to the parent and FK checks on parent DELETE would scan the whole child table without them.
*/

CREATE INDEX IF NOT EXISTS idx_company_representative_company_id
	ON recruitment_agency.company_representative (company_id);

CREATE INDEX IF NOT EXISTS idx_candidate_preferred_location_city_id
	ON recruitment_agency.candidate_preferred_location (city_id);

CREATE INDEX IF NOT EXISTS idx_work_experience_candidate_id
	ON recruitment_agency.work_experience (candidate_id);

CREATE INDEX IF NOT EXISTS idx_service_usage_candidate_id
	ON recruitment_agency.service_usage (candidate_id);

CREATE INDEX IF NOT EXISTS idx_candidate_skill_skill_id
	ON recruitment_agency.candidate_skill (skill_id);

CREATE INDEX IF NOT EXISTS idx_candidate_skill_service_usage_id
	ON recruitment_agency.candidate_skill (service_usage_id);

CREATE INDEX IF NOT EXISTS idx_job_posting_company_id
	ON recruitment_agency.job_posting (company_id);

CREATE INDEX IF NOT EXISTS idx_job_posting_city_id
	ON recruitment_agency.job_posting (city_id);

CREATE INDEX IF NOT EXISTS idx_application_job_posting_id
	ON recruitment_agency.application (job_posting_id);

CREATE INDEX IF NOT EXISTS idx_interview_company_representative_id
	ON recruitment_agency.interview (company_representative_id);


/*   STEP 4. SAMPLE DATA

   HOW CONSISTENCY IS ENSURED AND RELATIONSHIPS ARE PRESERVED
     1. Same order as the DDL: parents are inserted before children, so every FK value exists.
     2. Identity values are generated by the database and can differ between
        runs and environments, so a child row never contains a literal like candidate_id = 1.
        Each INSERT finds the parent id by its natural key (person.email, company.registration_number,
        city name + country, skill_name, ...) with an INNER JOIN. If a parent is missing, the join
        returns no row and nothing is inserted, instead of inserting a wrong or orphan row.
     3. No duplicates on rerun:
          -tables with a UNIQUE / PK natural key use ON CONFLICT DO NOTHING;
          -tables without one (work_experience, service_usage, job_posting) use WHERE NOT EXISTS.
        For the same reason event times are written explicitly instead of using DEFAULT now():
        with now() every rerun would produce a "new" row that the UNIQUE key cannot recognise.
        Time zone (+05, Almaty) is written explicitly, so the result does not depend on the session.
     4. Columns with DEFAULT (is_active, currency_code, is_remote_ok, price_charged) are left out of
        the column list where the default is the wanted value, so the defaults are really used.
     5. The interviewer is found through the company of the posting and the dates of his
        representation period, so an interview cannot be linked to a representative of another company.
     6. All inserts run in one transaction: either the whole consistent data set is loaded or nothing.
*/

BEGIN;

-- person (4 rows)
INSERT INTO recruitment_agency.person (first_name, last_name, email, phone, date_of_birth, created_at)
SELECT  src.first_name,
		src.last_name,
		src.email,
		src.phone,
		src.date_of_birth,
		src.created_at
FROM (
	VALUES  ('Aigerim',   'Tulegen',   'aigerim.t@mail.kz',     '+77071234567', DATE '1999-05-12', TIMESTAMPTZ '2026-03-02 09:00:00+05'),
			('Nursultan', 'Ermekov',   'n.ermekov@gmail.com',   '+77077654321', DATE '1996-11-30', TIMESTAMPTZ '2026-04-18 09:00:00+05'),
			('Aruzhan',   'Seitkali',  'aruzhan.s@gmail.com',   '+77011112233', DATE '1990-02-07', TIMESTAMPTZ '2024-02-01 09:00:00+05'),
			('Dauren',    'Akhmetov',  'd.akhmetov@tengri.kz',  '+77015556677', DATE '1988-07-19', TIMESTAMPTZ '2025-11-01 09:00:00+05')
) AS src (first_name, last_name, email, phone, date_of_birth, created_at)
ON CONFLICT (email) DO NOTHING;

-- company (2 rows); is_active uses its DEFAULT TRUE
INSERT INTO recruitment_agency.company (company_name, registration_number, industry, website_url, created_at)
SELECT  src.company_name,
		src.registration_number,
		src.industry,
		src.website_url,
		src.created_at
FROM (
	VALUES  ('Kaspi Tech',       '990140001234', 'FinTech',   'kaspi.kz',  TIMESTAMPTZ '2026-01-10 09:00:00+05'),
			('Tengri Logistics', '050240009876', 'Logistics', 'tengri.kz', TIMESTAMPTZ '2024-01-15 09:00:00+05')
) AS src (company_name, registration_number, industry, website_url, created_at)
ON CONFLICT (registration_number) DO NOTHING;

-- city (3 rows)
INSERT INTO recruitment_agency.city (city_name, country_code)
SELECT  src.city_name,
		src.country_code
FROM (
	VALUES  ('Astana',   'KZ'),
			('Almaty',   'KZ'),
			('Tashkent', 'UZ')
) AS src (city_name, country_code)
ON CONFLICT (city_name, country_code) DO NOTHING;

-- skill (3 rows)
INSERT INTO recruitment_agency.skill (skill_name, skill_category)
SELECT  src.skill_name,
		src.skill_category
FROM (
	VALUES  ('SQL',     'technical'),
			('Python',  'technical'),
			('English', 'language')
) AS src (skill_name, skill_category)
ON CONFLICT (skill_name) DO NOTHING;

-- candidate (2 rows); person_id is found by email
INSERT INTO recruitment_agency.candidate (person_id, cv_url, source, registered_at)
SELECT  per.person_id,
		src.cv_url,
		src.source,
		src.registered_at
FROM (
	VALUES  ('aigerim.t@mail.kz',   'cv/aigerim_tulegen.pdf',   'job_board', TIMESTAMPTZ '2026-03-02 09:00:00+05'),
			('n.ermekov@gmail.com', 'cv/nursultan_ermekov.pdf', 'referral',  TIMESTAMPTZ '2026-04-18 09:00:00+05')
) AS src (email, cv_url, source, registered_at)
INNER JOIN recruitment_agency.person per ON per.email = src.email
ON CONFLICT (person_id) DO NOTHING;

-- company_representative (3 rows); the same person (Aruzhan) represents two companies in different periods
INSERT INTO recruitment_agency.company_representative (person_id, company_id, job_title, start_date, end_date)
SELECT  per.person_id,
		com.company_id,
		src.job_title,
		src.start_date,
		src.end_date
FROM (
	VALUES  ('aruzhan.s@gmail.com',  '050240009876', 'HR Manager',          DATE '2024-02-01', DATE '2025-12-31'),
			('aruzhan.s@gmail.com',  '990140001234', 'Head of Engineering', DATE '2026-01-10', CAST(NULL AS DATE)),
			('d.akhmetov@tengri.kz', '050240009876', 'Recruitment Lead',    DATE '2025-11-01', CAST(NULL AS DATE))
) AS src (email, registration_number, job_title, start_date, end_date)
INNER JOIN recruitment_agency.person  per ON per.email               = src.email
INNER JOIN recruitment_agency.company com ON com.registration_number = src.registration_number
ON CONFLICT (person_id, company_id, start_date) DO NOTHING;

-- candidate_preferred_location (3 rows)
INSERT INTO recruitment_agency.candidate_preferred_location (candidate_id, city_id, valid_from, valid_to, is_remote_ok)
SELECT  can.candidate_id,
		cit.city_id,
		src.valid_from,
		src.valid_to,
		src.is_remote_ok
FROM (
	VALUES  ('aigerim.t@mail.kz',   'Astana', 'KZ', DATE '2026-03-02', DATE '2026-08-31',  FALSE),
			('aigerim.t@mail.kz',   'Almaty', 'KZ', DATE '2026-09-01', CAST(NULL AS DATE), TRUE),
			('n.ermekov@gmail.com', 'Almaty', 'KZ', DATE '2026-04-18', CAST(NULL AS DATE), FALSE)
) AS src (email, city_name, country_code, valid_from, valid_to, is_remote_ok)
INNER JOIN recruitment_agency.person    per ON per.email        = src.email
INNER JOIN recruitment_agency.candidate can ON can.person_id    = per.person_id
INNER JOIN recruitment_agency.city      cit ON cit.city_name    = src.city_name AND
											   cit.country_code = src.country_code
ON CONFLICT (candidate_id, city_id, valid_from) DO NOTHING;

-- work_experience (2 rows); no UNIQUE key in the model, so duplicates are prevented with WHERE NOT EXISTS
INSERT INTO recruitment_agency.work_experience (candidate_id, employer_name, job_title, start_date, end_date, description)
SELECT  can.candidate_id,
		src.employer_name,
		src.job_title,
		src.start_date,
		src.end_date,
		src.description
FROM (
	VALUES  ('aigerim.t@mail.kz',   'Halyk Bank', 'Data Intern', DATE '2024-06-01', DATE '2025-08-31',  'Reporting in SQL'),
			('n.ermekov@gmail.com', 'Air Astana', 'BI Analyst',  DATE '2021-02-01', CAST(NULL AS DATE), 'Power BI dashboards')
) AS src (email, employer_name, job_title, start_date, end_date, description)
INNER JOIN recruitment_agency.person    per ON per.email     = src.email
INNER JOIN recruitment_agency.candidate can ON can.person_id = per.person_id
WHERE NOT EXISTS (
	SELECT 1
	FROM recruitment_agency.work_experience wex
	WHERE wex.candidate_id  = can.candidate_id AND
		  wex.employer_name = src.employer_name AND
		  wex.start_date    = src.start_date
);

-- service_usage (2 rows); currency_code uses its DEFAULT 'KZT'
INSERT INTO recruitment_agency.service_usage (candidate_id, service_type, requested_at, price_charged)
SELECT  can.candidate_id,
		src.service_type,
		src.requested_at,
		src.price_charged
FROM (
	VALUES  ('aigerim.t@mail.kz', 'resume_advice',  TIMESTAMPTZ '2026-03-05 10:00:00+05', 15000.00),
			('aigerim.t@mail.kz', 'skills_testing', TIMESTAMPTZ '2026-09-04 09:00:00+05', 0.00)
) AS src (email, service_type, requested_at, price_charged)
INNER JOIN recruitment_agency.person    per ON per.email     = src.email
INNER JOIN recruitment_agency.candidate can ON can.person_id = per.person_id
WHERE NOT EXISTS (
	SELECT 1
	FROM recruitment_agency.service_usage sus
	WHERE sus.candidate_id = can.candidate_id AND
		  sus.service_type = src.service_type AND
		  sus.requested_at = src.requested_at
);

-- service_usage_status_history (5 rows); the service is found by candidate + type + request time
INSERT INTO recruitment_agency.service_usage_status_history (service_usage_id, status, changed_at, note)
SELECT  sus.service_usage_id,
		src.status,
		src.changed_at,
		src.note
FROM (
	VALUES  ('aigerim.t@mail.kz', 'resume_advice',  TIMESTAMPTZ '2026-03-05 10:00:00+05', 'requested', TIMESTAMPTZ '2026-03-05 10:00:00+05', CAST(NULL AS TEXT)),
			('aigerim.t@mail.kz', 'resume_advice',  TIMESTAMPTZ '2026-03-05 10:00:00+05', 'completed', TIMESTAMPTZ '2026-03-06 16:00:00+05', 'CV rewritten'),
			('aigerim.t@mail.kz', 'skills_testing', TIMESTAMPTZ '2026-09-04 09:00:00+05', 'requested', TIMESTAMPTZ '2026-09-04 09:00:00+05', CAST(NULL AS TEXT)),
			('aigerim.t@mail.kz', 'skills_testing', TIMESTAMPTZ '2026-09-04 09:00:00+05', 'scheduled', TIMESTAMPTZ '2026-09-04 12:00:00+05', 'Test on 6 Sep'),
			('aigerim.t@mail.kz', 'skills_testing', TIMESTAMPTZ '2026-09-04 09:00:00+05', 'completed', TIMESTAMPTZ '2026-09-06 13:00:00+05', 'Score 82%')
) AS src (email, service_type, requested_at, status, changed_at, note)
INNER JOIN recruitment_agency.person        per ON per.email        = src.email
INNER JOIN recruitment_agency.candidate     can ON can.person_id    = per.person_id
INNER JOIN recruitment_agency.service_usage sus ON sus.candidate_id = can.candidate_id AND
												   sus.service_type = src.service_type AND
												   sus.requested_at = src.requested_at
ON CONFLICT (service_usage_id, changed_at) DO NOTHING;

-- candidate_skill (3 rows); a self-reported level has no service, a tested level points to the skills test.
-- LEFT JOIN is used because the service is optional for a self-reported level.
INSERT INTO recruitment_agency.candidate_skill (candidate_id, skill_id, assessed_on, proficiency_level, assessment_source, service_usage_id)
SELECT  can.candidate_id,
		ski.skill_id,
		src.assessed_on,
		src.proficiency_level,
		src.assessment_source,
		sus.service_usage_id
FROM (
	VALUES  ('aigerim.t@mail.kz',   'SQL',    DATE '2026-03-02', 3, 'self_reported', CAST(NULL AS TIMESTAMPTZ)),
			('aigerim.t@mail.kz',   'SQL',    DATE '2026-09-06', 4, 'skills_test',   TIMESTAMPTZ '2026-09-04 09:00:00+05'),
			('n.ermekov@gmail.com', 'Python', DATE '2026-04-18', 5, 'self_reported', CAST(NULL AS TIMESTAMPTZ))
) AS src (email, skill_name, assessed_on, proficiency_level, assessment_source, test_requested_at)
INNER JOIN recruitment_agency.person             per ON per.email        = src.email
INNER JOIN recruitment_agency.candidate          can ON can.person_id    = per.person_id
INNER JOIN recruitment_agency.skill              ski ON ski.skill_name   = src.skill_name
LEFT OUTER JOIN recruitment_agency.service_usage sus ON sus.candidate_id = can.candidate_id AND
														sus.service_type = 'skills_testing' AND
														sus.requested_at = src.test_requested_at
ON CONFLICT (candidate_id, skill_id, assessed_on) DO NOTHING;

-- job_posting, original postings (2 rows); currency_code uses its DEFAULT 'KZT'.
-- A posting is recognised by company + title + publication time.
INSERT INTO recruitment_agency.job_posting (company_id, city_id, job_title, description, employment_type, salary_min, salary_max, posted_at, closes_on)
SELECT  com.company_id,
		cit.city_id,
		src.job_title,
		src.description,
		src.employment_type,
		src.salary_min,
		src.salary_max,
		src.posted_at,
		src.closes_on
FROM (
	VALUES  ('990140001234', 'Almaty', 'KZ', 'Data Analyst',      'Product analytics for the payments team', 'full_time', 600000.00, 900000.00, TIMESTAMPTZ '2026-08-20 09:00:00+05', DATE '2026-08-31'),
			('050240009876', 'Astana', 'KZ', 'Logistics Analyst', 'Route and warehouse cost analysis',       'full_time', 500000.00, 700000.00, TIMESTAMPTZ '2026-09-10 09:00:00+05', DATE '2026-10-10')
) AS src (registration_number, city_name, country_code, job_title, description, employment_type, salary_min, salary_max, posted_at, closes_on)
INNER JOIN recruitment_agency.company com ON com.registration_number = src.registration_number
INNER JOIN recruitment_agency.city    cit ON cit.city_name           = src.city_name AND
											 cit.country_code        = src.country_code
WHERE NOT EXISTS (
	SELECT 1
	FROM recruitment_agency.job_posting jpo
	WHERE jpo.company_id = com.company_id AND
		  jpo.job_title  = src.job_title AND
		  jpo.posted_at  = src.posted_at
);

-- job_posting, changed posting (1 row). The salary range was raised, so a new posting is created and linked to the old one. It is a separate statement because the old posting must already exist.
INSERT INTO recruitment_agency.job_posting (company_id, previous_job_posting_id, city_id, job_title, description, employment_type, salary_min, salary_max, posted_at, closes_on)
SELECT  com.company_id,
		prv.job_posting_id,
		cit.city_id,
		src.job_title,
		src.description,
		src.employment_type,
		src.salary_min,
		src.salary_max,
		src.posted_at,
		src.closes_on
FROM (
	VALUES  ('990140001234', 'Almaty', 'KZ', 'Data Analyst', 'Product analytics for the payments team, raised salary range', 'full_time', 700000.00, 1000000.00, TIMESTAMPTZ '2026-09-01 09:00:00+05', DATE '2026-09-30', TIMESTAMPTZ '2026-08-20 09:00:00+05')
) AS src (registration_number, city_name, country_code, job_title, description, employment_type, salary_min, salary_max, posted_at, closes_on, previous_posted_at)
INNER JOIN recruitment_agency.company     com ON com.registration_number = src.registration_number
INNER JOIN recruitment_agency.city        cit ON cit.city_name           = src.city_name AND
												 cit.country_code        = src.country_code
INNER JOIN recruitment_agency.job_posting prv ON prv.company_id          = com.company_id AND
												 prv.job_title           = src.job_title AND
												 prv.posted_at           = src.previous_posted_at
WHERE NOT EXISTS (
	SELECT 1
	FROM recruitment_agency.job_posting jpo
	WHERE jpo.company_id = com.company_id AND
		  jpo.job_title  = src.job_title AND
		  jpo.posted_at  = src.posted_at
);

-- application (3 rows)
INSERT INTO recruitment_agency.application (candidate_id, job_posting_id, applied_at, expected_salary, cover_note)
SELECT  can.candidate_id,
		jpo.job_posting_id,
		src.applied_at,
		src.expected_salary,
		src.cover_note
FROM (
	VALUES  ('aigerim.t@mail.kz',   '990140001234', 'Data Analyst',      TIMESTAMPTZ '2026-09-01 09:00:00+05', TIMESTAMPTZ '2026-09-03 11:00:00+05', 750000.00, 'Interested in fintech analytics'),
			('n.ermekov@gmail.com', '990140001234', 'Data Analyst',      TIMESTAMPTZ '2026-09-01 09:00:00+05', TIMESTAMPTZ '2026-09-04 12:00:00+05', 850000.00, CAST(NULL AS TEXT)),
			('n.ermekov@gmail.com', '050240009876', 'Logistics Analyst', TIMESTAMPTZ '2026-09-10 09:00:00+05', TIMESTAMPTZ '2026-09-11 10:00:00+05', 650000.00, 'Five years of BI experience in transport')
) AS src (email, registration_number, job_title, posted_at, applied_at, expected_salary, cover_note)
INNER JOIN recruitment_agency.person      per ON per.email               = src.email
INNER JOIN recruitment_agency.candidate   can ON can.person_id           = per.person_id
INNER JOIN recruitment_agency.company     com ON com.registration_number = src.registration_number
INNER JOIN recruitment_agency.job_posting jpo ON jpo.company_id          = com.company_id AND
												 jpo.job_title           = src.job_title AND
												 jpo.posted_at           = src.posted_at
ON CONFLICT (candidate_id, job_posting_id) DO NOTHING;

-- application_status_history (9 rows); the application is found by candidate + posting
INSERT INTO recruitment_agency.application_status_history (application_id, status, changed_at, comment)
SELECT  app.application_id,
		src.status,
		src.changed_at,
		src.comment
FROM (
	VALUES  ('aigerim.t@mail.kz',   '990140001234', 'Data Analyst',      TIMESTAMPTZ '2026-09-01 09:00:00+05', 'submitted',    TIMESTAMPTZ '2026-09-03 11:00:00+05', CAST(NULL AS TEXT)),
			('n.ermekov@gmail.com', '990140001234', 'Data Analyst',      TIMESTAMPTZ '2026-09-01 09:00:00+05', 'submitted',    TIMESTAMPTZ '2026-09-04 12:00:00+05', CAST(NULL AS TEXT)),
			('aigerim.t@mail.kz',   '990140001234', 'Data Analyst',      TIMESTAMPTZ '2026-09-01 09:00:00+05', 'under_review', TIMESTAMPTZ '2026-09-05 14:00:00+05', 'CV matches'),
			('n.ermekov@gmail.com', '990140001234', 'Data Analyst',      TIMESTAMPTZ '2026-09-01 09:00:00+05', 'rejected',     TIMESTAMPTZ '2026-09-06 10:00:00+05', 'Below required SQL level'),
			('aigerim.t@mail.kz',   '990140001234', 'Data Analyst',      TIMESTAMPTZ '2026-09-01 09:00:00+05', 'interview',    TIMESTAMPTZ '2026-09-07 10:00:00+05', CAST(NULL AS TEXT)),
			('aigerim.t@mail.kz',   '990140001234', 'Data Analyst',      TIMESTAMPTZ '2026-09-01 09:00:00+05', 'approved',     TIMESTAMPTZ '2026-09-15 17:00:00+05', 'Offer accepted'),
			('n.ermekov@gmail.com', '050240009876', 'Logistics Analyst', TIMESTAMPTZ '2026-09-10 09:00:00+05', 'submitted',    TIMESTAMPTZ '2026-09-11 10:00:00+05', CAST(NULL AS TEXT)),
			('n.ermekov@gmail.com', '050240009876', 'Logistics Analyst', TIMESTAMPTZ '2026-09-10 09:00:00+05', 'interview',    TIMESTAMPTZ '2026-09-14 09:00:00+05', CAST(NULL AS TEXT)),
			('n.ermekov@gmail.com', '050240009876', 'Logistics Analyst', TIMESTAMPTZ '2026-09-10 09:00:00+05', 'approved',     TIMESTAMPTZ '2026-09-20 16:00:00+05', 'Offer accepted')
) AS src (email, registration_number, job_title, posted_at, status, changed_at, comment)
INNER JOIN recruitment_agency.person      per ON per.email               = src.email
INNER JOIN recruitment_agency.candidate   can ON can.person_id           = per.person_id
INNER JOIN recruitment_agency.company     com ON com.registration_number = src.registration_number
INNER JOIN recruitment_agency.job_posting jpo ON jpo.company_id          = com.company_id AND
												 jpo.job_title           = src.job_title AND
												 jpo.posted_at           = src.posted_at
INNER JOIN recruitment_agency.application app ON app.candidate_id        = can.candidate_id AND
												 app.job_posting_id      = jpo.job_posting_id
ON CONFLICT (application_id, changed_at) DO NOTHING;

-- interview (3 rows). The interviewer must represent the company of the posting on the interview day:
-- this is checked by the join to company_representative (same company_id, date inside the period).
INSERT INTO recruitment_agency.interview (application_id, company_representative_id, round_number, interview_type, scheduled_at, duration_minutes, outcome, feedback)
SELECT  app.application_id,
		rep.company_representative_id,
		src.round_number,
		src.interview_type,
		src.scheduled_at,
		src.duration_minutes,
		src.outcome,
		src.feedback
FROM (
	VALUES  ('aigerim.t@mail.kz',   '990140001234', 'Data Analyst',      TIMESTAMPTZ '2026-09-01 09:00:00+05', 'aruzhan.s@gmail.com',  1, 'video',     TIMESTAMPTZ '2026-09-08 10:00:00+05', 30, 'passed', CAST(NULL AS TEXT)),
			('aigerim.t@mail.kz',   '990140001234', 'Data Analyst',      TIMESTAMPTZ '2026-09-01 09:00:00+05', 'aruzhan.s@gmail.com',  2, 'technical', TIMESTAMPTZ '2026-09-12 15:00:00+05', 60, 'passed', 'Strong SQL'),
			('n.ermekov@gmail.com', '050240009876', 'Logistics Analyst', TIMESTAMPTZ '2026-09-10 09:00:00+05', 'd.akhmetov@tengri.kz', 1, 'onsite',    TIMESTAMPTZ '2026-09-16 11:00:00+05', 45, 'passed', 'Good knowledge of the transport domain')
) AS src (email, registration_number, job_title, posted_at, interviewer_email, round_number, interview_type, scheduled_at, duration_minutes, outcome, feedback)
INNER JOIN recruitment_agency.person                 per ON per.email               = src.email
INNER JOIN recruitment_agency.candidate              can ON can.person_id           = per.person_id
INNER JOIN recruitment_agency.company                com ON com.registration_number = src.registration_number
INNER JOIN recruitment_agency.job_posting            jpo ON jpo.company_id          = com.company_id AND
															jpo.job_title           = src.job_title AND
															jpo.posted_at           = src.posted_at
INNER JOIN recruitment_agency.application            app ON app.candidate_id        = can.candidate_id AND
															app.job_posting_id      = jpo.job_posting_id
INNER JOIN recruitment_agency.person                 ivr ON ivr.email               = src.interviewer_email
INNER JOIN recruitment_agency.company_representative rep ON rep.person_id           = ivr.person_id AND
															rep.company_id          = jpo.company_id
WHERE rep.start_date <= CAST(src.scheduled_at AS DATE) AND
	  (rep.end_date  >= CAST(src.scheduled_at AS DATE) OR rep.end_date IS NULL)
ON CONFLICT (application_id, round_number) DO NOTHING;

-- placement (2 rows); currency_code uses its DEFAULT 'KZT', end_date and end_reason stay NULL (active).
-- Only an application whose history contains the status 'approved' can become a placement.
INSERT INTO recruitment_agency.placement (application_id, start_date, agreed_salary, fee_amount)
SELECT  app.application_id,
		src.start_date,
		src.agreed_salary,
		src.fee_amount
FROM (
	VALUES  ('aigerim.t@mail.kz',   '990140001234', 'Data Analyst',      TIMESTAMPTZ '2026-09-01 09:00:00+05', DATE '2026-10-01', 800000.00, 1600000.00),
			('n.ermekov@gmail.com', '050240009876', 'Logistics Analyst', TIMESTAMPTZ '2026-09-10 09:00:00+05', DATE '2026-10-15', 650000.00, 1300000.00)
) AS src (email, registration_number, job_title, posted_at, start_date, agreed_salary, fee_amount)
INNER JOIN recruitment_agency.person      per ON per.email               = src.email
INNER JOIN recruitment_agency.candidate   can ON can.person_id           = per.person_id
INNER JOIN recruitment_agency.company     com ON com.registration_number = src.registration_number
INNER JOIN recruitment_agency.job_posting jpo ON jpo.company_id          = com.company_id AND
												 jpo.job_title           = src.job_title AND
												 jpo.posted_at           = src.posted_at
INNER JOIN recruitment_agency.application app ON app.candidate_id        = can.candidate_id AND
												 app.job_posting_id      = jpo.job_posting_id
WHERE EXISTS (
	SELECT 1
	FROM recruitment_agency.application_status_history ash
	WHERE ash.application_id = app.application_id AND
		  ash.status         = 'approved'
)
ON CONFLICT (application_id) DO NOTHING;

COMMIT;


/*
   STEP 5. record_ts

   A NOT NULL column is added to tables that already contain rows. This works only because the
   column has a DEFAULT: PostgreSQL writes the default value into all existing rows. 
   
   Without the DEFAULT the statement would fail with
   ERROR: column "record_ts" of relation "person" contains null values  (SQLSTATE 23502).
   ADD COLUMN IF NOT EXISTS keeps the statement rerunnable and does not overwrite the dates
   of rows loaded on an earlier day.
   */

ALTER TABLE recruitment_agency.person
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.company
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.city
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.skill
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.candidate
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.company_representative
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.candidate_preferred_location
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.work_experience
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.service_usage
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.service_usage_status_history
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.candidate_skill
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.job_posting
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.application
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.application_status_history
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.interview
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;

ALTER TABLE recruitment_agency.placement
	ADD COLUMN IF NOT EXISTS record_ts DATE NOT NULL DEFAULT CURRENT_DATE;


/*
   STEP 6. CHECK THAT record_ts IS SET FOR THE EXISTING ROWS
   
   For every table: row_count must be equal to record_ts_filled_count (COUNT(column) skips NULLs),
   every table must have at least 2 rows, and the total is 52 rows.
   No WHERE clause: the check must cover all rows of every table.
*/

SELECT  'person'                        AS table_name,
		COUNT(*)                        AS row_count,
		COUNT(per.record_ts)            AS record_ts_filled_count,
		MIN(per.record_ts)              AS record_ts_min
FROM recruitment_agency.person per
UNION ALL
SELECT  'company',
		COUNT(*),
		COUNT(com.record_ts),
		MIN(com.record_ts)
FROM recruitment_agency.company com
UNION ALL
SELECT  'city',
		COUNT(*),
		COUNT(cit.record_ts),
		MIN(cit.record_ts)
FROM recruitment_agency.city cit
UNION ALL
SELECT  'skill',
		COUNT(*),
		COUNT(ski.record_ts),
		MIN(ski.record_ts)
FROM recruitment_agency.skill ski
UNION ALL
SELECT  'candidate',
		COUNT(*),
		COUNT(can.record_ts),
		MIN(can.record_ts)
FROM recruitment_agency.candidate can
UNION ALL
SELECT  'company_representative',
		COUNT(*),
		COUNT(rep.record_ts),
		MIN(rep.record_ts)
FROM recruitment_agency.company_representative rep
UNION ALL
SELECT  'candidate_preferred_location',
		COUNT(*),
		COUNT(cpl.record_ts),
		MIN(cpl.record_ts)
FROM recruitment_agency.candidate_preferred_location cpl
UNION ALL
SELECT  'work_experience',
		COUNT(*),
		COUNT(wex.record_ts),
		MIN(wex.record_ts)
FROM recruitment_agency.work_experience wex
UNION ALL
SELECT  'service_usage',
		COUNT(*),
		COUNT(sus.record_ts),
		MIN(sus.record_ts)
FROM recruitment_agency.service_usage sus
UNION ALL
SELECT  'service_usage_status_history',
		COUNT(*),
		COUNT(ssh.record_ts),
		MIN(ssh.record_ts)
FROM recruitment_agency.service_usage_status_history ssh
UNION ALL
SELECT  'candidate_skill',
		COUNT(*),
		COUNT(csk.record_ts),
		MIN(csk.record_ts)
FROM recruitment_agency.candidate_skill csk
UNION ALL
SELECT  'job_posting',
		COUNT(*),
		COUNT(jpo.record_ts),
		MIN(jpo.record_ts)
FROM recruitment_agency.job_posting jpo
UNION ALL
SELECT  'application',
		COUNT(*),
		COUNT(app.record_ts),
		MIN(app.record_ts)
FROM recruitment_agency.application app
UNION ALL
SELECT  'application_status_history',
		COUNT(*),
		COUNT(ash.record_ts),
		MIN(ash.record_ts)
FROM recruitment_agency.application_status_history ash
UNION ALL
SELECT  'interview',
		COUNT(*),
		COUNT(itw.record_ts),
		MIN(itw.record_ts)
FROM recruitment_agency.interview itw
UNION ALL
SELECT  'placement',
		COUNT(*),
		COUNT(plc.record_ts),
		MIN(plc.record_ts)
FROM recruitment_agency.placement plc;
