-- =====================================================================
-- CRU (Coverage Response Unit) Review Assistant - Synthetic database (SQLite)
-- Hackathon TCS x USAA - Property & Casualty
--
-- ALL DATA IS FICTITIOUS. Names, policy numbers, VINs and calls are
-- made up. Coverage structure is based on public USAA auto info; the
-- rental reimbursement tiers and their vehicle classes are demo
-- assumptions (to be confirmed with Victoria).
--
-- Table groups:
--   1-5  Source data   : what the policy system and call recordings hold.
--   6    Ground truth  : expected_call_events. EVALUATION ONLY - the
--                        chatbot must never read it (it holds the answers).
--   7    AI output     : call_analysis, audit_findings (written by the app).
--
-- Build:  python scripts/build_db.py
--    or:  sqlite3 data/cru.db < data/schema.sql
-- =====================================================================

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------
-- 1. CATALOGS
-- ---------------------------------------------------------------------

-- Coverage types (names as they appear on a USAA auto policy)
CREATE TABLE coverage_catalog (
    code            TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    level           TEXT NOT NULL CHECK (level IN ('POLICY','VEHICLE')),
    is_optional     INTEGER NOT NULL,          -- 1 = endorsement / add-on
    requires        TEXT,                      -- prerequisite coverage codes
    alternate_name  TEXT,                      -- name used in some states
    description     TEXT
);

INSERT INTO coverage_catalog VALUES
('BI',      'Bodily Injury Liability',          'POLICY',  0, NULL, NULL, 'Injuries to others when the member is at fault'),
('PD',      'Property Damage Liability',        'POLICY',  0, NULL, NULL, 'Damage to other people''s property'),
('UMUIM',   'Uninsured/Underinsured Motorist',  'POLICY',  0, NULL, NULL, 'Injuries caused by a driver with no or insufficient insurance'),
('PIP',     'Personal Injury Protection',       'POLICY',  0, NULL, NULL, 'Medical expenses and lost wages, regardless of fault'),
('MEDPAY',  'Medical Payments',                 'POLICY',  1, NULL, NULL, 'Medical expenses for driver and passengers'),
('COMP',    'Comprehensive',                    'VEHICLE', 0, NULL, NULL, 'Theft, hail, flood, vandalism, animal strikes'),
('COLL',    'Collision',                        'VEHICLE', 0, NULL, NULL, 'Damage to the vehicle from a collision'),
('RENTAL',  'Rental Reimbursement',             'VEHICLE', 1, 'COMP,COLL', 'Transportation Expense',
            'Pays for a rental car while the vehicle is repaired after a covered loss; does not apply to maintenance'),
('ROADSIDE','Roadside Assistance',              'VEHICLE', 1, NULL, NULL, 'Towing, jump start, fuel delivery, flat tire, lockout'),
('CRA',     'Car Replacement Assistance',       'VEHICLE', 1, 'COMP,COLL', NULL, 'Pays 20% over actual cash value if the car is a total loss'),
('AF',      'Accident Forgiveness',             'POLICY',  1, NULL, NULL, 'Premium does not increase after the first at-fault accident'),
('RSG',     'Rideshare Gap Protection',         'VEHICLE', 1, NULL, NULL, 'Covers the driver while waiting for a ride request in a rideshare app');

-- Rental Reimbursement tiers (DEMO ASSUMPTION)
-- The daily limit determines which rental vehicle class is covered.
-- Answers about rental coverage use vehicle_class only (no car makes/models).
CREATE TABLE rental_tiers (
    code            TEXT PRIMARY KEY,
    daily_limit     INTEGER NOT NULL,   -- USD per day
    max_per_claim   INTEGER NOT NULL,   -- USD per claim
    max_days        INTEGER NOT NULL,
    vehicle_class   TEXT NOT NULL,      -- covered rental class
    exclusions      TEXT NOT NULL
);

INSERT INTO rental_tiers VALUES
('R30', 30,  900, 30, 'Economy / Compact',
       'Luxury, exotic, moving trucks; does not cover routine maintenance'),
('R40', 40, 1200, 30, 'Intermediate / Standard',
       'Luxury, exotic, moving trucks; does not cover routine maintenance'),
('R50', 50, 1500, 30, 'Full-size sedan / Small SUV',
       'Luxury, exotic, moving trucks; does not cover routine maintenance'),
('R60', 60, 1800, 30, 'Mid-size SUV / Minivan / Pickup',
       'Luxury, exotic, moving trucks; does not cover routine maintenance');

-- ---------------------------------------------------------------------
-- 2. POLICY
-- ---------------------------------------------------------------------

CREATE TABLE members (
    id               INTEGER PRIMARY KEY,
    member_number    TEXT UNIQUE NOT NULL,
    full_name        TEXT NOT NULL,
    eligibility      TEXT NOT NULL,       -- Active Duty, Veteran, Spouse...
    military_branch  TEXT,
    state            TEXT NOT NULL,       -- U.S. state
    city             TEXT NOT NULL
);

INSERT INTO members VALUES
(1, '00-4471-982', 'Daniel R. Ortiz', 'Active Duty', 'U.S. Army', 'TX', 'San Antonio'),
(2, '00-5528-310', 'Megan L. Brooks', 'Veteran',     'U.S. Navy', 'VA', 'Norfolk'),
(3, '123456',      'Fanny Rios',      'Veteran',     'U.S. Air Force', 'CO', 'Colorado Springs');

CREATE TABLE policies (
    id               INTEGER PRIMARY KEY,
    policy_number    TEXT UNIQUE NOT NULL,
    member_id        INTEGER NOT NULL REFERENCES members(id),
    line_of_business TEXT NOT NULL DEFAULT 'AUTO',
    issue_state      TEXT NOT NULL,
    start_date       DATE NOT NULL,
    term_months      INTEGER NOT NULL DEFAULT 6,
    status           TEXT NOT NULL DEFAULT 'ACTIVE'
);

INSERT INTO policies VALUES
(1, 'AUT-4471982-7101', 1, 'AUTO', 'TX', '2022-01-15', 6, 'ACTIVE'),
(2, 'AUT-5528310-7102', 2, 'AUTO', 'VA', '2023-06-01', 6, 'ACTIVE'),
(3, 'AUT-0123456-7103', 3, 'AUTO', 'CO', '2024-04-15', 6, 'ACTIVE');

-- Six-month policy terms (the "20+ policy terms" from the intake form)
CREATE TABLE policy_terms (
    id           INTEGER PRIMARY KEY,
    policy_id    INTEGER NOT NULL REFERENCES policies(id),
    term_number  INTEGER NOT NULL,
    start_date   DATE NOT NULL,
    end_date     DATE NOT NULL,
    UNIQUE (policy_id, term_number)
);

-- Generate six-month terms through 2027
INSERT INTO policy_terms (policy_id, term_number, start_date, end_date)
WITH RECURSIVE t(policy_id, term_number, start_date) AS (
    SELECT id, 1, start_date FROM policies
    UNION ALL
    SELECT policy_id, term_number + 1, date(start_date, '+6 months')
    FROM t WHERE date(start_date, '+6 months') < '2027-01-01'
)
SELECT policy_id, term_number, start_date, date(start_date, '+6 months') FROM t;

CREATE TABLE drivers (
    id            INTEGER PRIMARY KEY,
    policy_id     INTEGER NOT NULL REFERENCES policies(id),
    full_name     TEXT NOT NULL,
    relationship  TEXT NOT NULL,
    added_on      DATE NOT NULL,
    removed_on    DATE
);

INSERT INTO drivers VALUES
(1, 1, 'Daniel R. Ortiz', 'Named Insured', '2022-01-15', NULL),
(2, 1, 'Ana P. Ortiz',    'Spouse',        '2022-01-15', NULL),
(3, 2, 'Megan L. Brooks', 'Named Insured', '2023-06-01', NULL),
(4, 3, 'Fanny Rios',      'Named Insured', '2024-04-15', NULL);

CREATE TABLE vehicles (
    id          INTEGER PRIMARY KEY,
    policy_id   INTEGER NOT NULL REFERENCES policies(id),
    model_year  INTEGER NOT NULL,
    make        TEXT NOT NULL,
    model       TEXT NOT NULL,
    body_type   TEXT NOT NULL,          -- Sedan, SUV, Pickup, Minivan
    vin         TEXT NOT NULL,          -- fictitious VIN
    usage       TEXT NOT NULL,          -- Commute, Pleasure, Business
    lienholder  TEXT,                   -- NULL = no lienholder
    added_on    DATE NOT NULL,
    removed_on  DATE
);

INSERT INTO vehicles VALUES
(1, 1, 2019, 'Ford',     'F-150 XLT',       'Pickup',  '1FTEW1E50KFX00001', 'Commute',  NULL,                  '2022-01-15', '2024-05-02'),
(2, 1, 2021, 'Honda',    'CR-V EX',         'SUV',     '2HKRW2H59MHX00002', 'Pleasure', 'USAA Federal Savings','2022-01-15', NULL),
(3, 1, 2024, 'Toyota',   'Tacoma TRD',      'Pickup',  '3TMLB5JN1RMX00003', 'Commute',  'Toyota Financial',    '2024-05-02', NULL),
(4, 2, 2022, 'Chrysler', 'Pacifica Touring','Minivan', '2C4RC1BG8NRX00004', 'Pleasure', NULL,                  '2023-06-01', NULL),
(5, 3, 2024, 'Volvo',    'EX30',            'SUV',     'YV4EF3ERG2174639K', 'Pleasure', NULL,                  '2024-04-15', NULL);

-- ---------------------------------------------------------------------
-- 3. COVERAGES (effective state by date range)
--    Each change closes the previous row (effective_to) and opens a new one.
--    Rental limits live only in rental_tiers (single source of truth);
--    limit_text is the display limit for all other coverages.
-- ---------------------------------------------------------------------

CREATE TABLE coverages (
    id              INTEGER PRIMARY KEY,
    policy_id       INTEGER NOT NULL REFERENCES policies(id),
    vehicle_id      INTEGER REFERENCES vehicles(id),   -- NULL = policy level
    coverage_code   TEXT NOT NULL REFERENCES coverage_catalog(code),
    limit_text      TEXT,          -- e.g. '$100,000/$300,000' (not used for RENTAL)
    deductible      INTEGER,
    rental_tier     TEXT REFERENCES rental_tiers(code),
    details         TEXT,          -- JSON, only attributes not covered by other columns
    effective_from  DATE NOT NULL,
    effective_to    DATE,          -- NULL = in force today
    CHECK ((coverage_code = 'RENTAL') = (rental_tier IS NOT NULL))
);

CREATE INDEX idx_coverages_policy ON coverages (policy_id, coverage_code, effective_from);

INSERT INTO coverages (policy_id, vehicle_id, coverage_code, limit_text, deductible, rental_tier, details, effective_from, effective_to) VALUES
-- Policy 1 (TX) - policy level
(1, NULL, 'BI',    '$100,000/$300,000', NULL, NULL, NULL, '2022-01-15', NULL),
(1, NULL, 'PD',    '$100,000',          NULL, NULL, NULL, '2022-01-15', NULL),
(1, NULL, 'UMUIM', '$100,000/$300,000', NULL, NULL, NULL, '2022-01-15', NULL),
(1, NULL, 'PIP',   '$2,500',            NULL, NULL, NULL, '2022-01-15', NULL),
-- F-150 (removed 2024-05-02)
(1, 1, 'COMP',     NULL, 500,  NULL, NULL, '2022-01-15', '2024-05-02'),
(1, 1, 'COLL',     NULL, 500,  NULL, NULL, '2022-01-15', '2024-05-02'),
(1, 1, 'ROADSIDE', NULL, NULL, NULL, '{"towing_miles":15}', '2022-01-15', '2024-05-02'),
-- CR-V
(1, 2, 'COMP',     NULL, 500,  NULL, NULL, '2022-01-15', NULL),
(1, 2, 'COLL',     NULL, 500,  NULL, NULL, '2022-01-15', NULL),
(1, 2, 'ROADSIDE', NULL, NULL, NULL, '{"towing_miles":15}', '2022-01-15', NULL),
(1, 2, 'RENTAL',   NULL, NULL, 'R30', NULL, '2022-08-03', '2023-03-10'),
(1, 2, 'RENTAL',   NULL, NULL, 'R50', NULL, '2023-03-10', '2025-02-14'),
(1, 2, 'RENTAL',   NULL, NULL, 'R40', NULL, '2025-02-14', NULL),
-- Tacoma (added 2024-05-02)
(1, 3, 'COMP',     NULL, 500,  NULL, NULL, '2024-05-02', NULL),
(1, 3, 'COLL',     NULL, 500,  NULL, NULL, '2024-05-02', NULL),
(1, 3, 'RENTAL',   NULL, NULL, 'R40', NULL, '2024-05-02', NULL),
(1, 3, 'CRA',      '20% over ACV', NULL, NULL, NULL, '2024-05-02', NULL),

-- Policy 2 (VA)
(2, NULL, 'BI',    '$250,000/$500,000', NULL, NULL, NULL, '2023-06-01', NULL),
(2, NULL, 'PD',    '$100,000',          NULL, NULL, NULL, '2023-06-01', NULL),
(2, NULL, 'UMUIM', '$250,000/$500,000', NULL, NULL, NULL, '2023-06-01', NULL),
(2, NULL, 'MEDPAY','$5,000',            NULL, NULL, NULL, '2023-06-01', NULL),
(2, NULL, 'AF',    NULL,                NULL, NULL, NULL, '2024-10-12', NULL),
(2, 4, 'COMP',     NULL, 250,  NULL, NULL, '2023-06-01', NULL),
(2, 4, 'COLL',     NULL, 500,  NULL, NULL, '2023-06-01', NULL),
(2, 4, 'RENTAL',   NULL, NULL, 'R60', NULL, '2023-06-01', '2026-02-20'),

-- Policy 3 (CO) - demo call with real audio (call 7). Rental was never removed.
(3, NULL, 'BI',    '$100,000/$300,000', NULL, NULL, NULL, '2024-04-15', NULL),
(3, NULL, 'PD',    '$100,000',          NULL, NULL, NULL, '2024-04-15', NULL),
(3, NULL, 'UMUIM', '$100,000/$300,000', NULL, NULL, NULL, '2024-04-15', NULL),
(3, NULL, 'MEDPAY','$5,000',            NULL, NULL, NULL, '2024-04-15', NULL),
(3, 5, 'COMP',     NULL, 500,  NULL, NULL, '2024-04-15', NULL),
(3, 5, 'COLL',     NULL, 500,  NULL, NULL, '2024-04-15', NULL),
(3, 5, 'RENTAL',   NULL, NULL, 'R40', NULL, '2024-04-15', NULL);

-- ---------------------------------------------------------------------
-- 4. CALLS (transcripts; only call 7 has real audio)
--    transcript_source: SCRIPTED = written transcript, no audio;
--                       WHISPER  = transcribed from audio_file by local Whisper.
--    AI output (summary, highlights, sentiment) lives in call_analysis.
-- ---------------------------------------------------------------------

CREATE TABLE calls (
    id              INTEGER PRIMARY KEY,
    policy_id       INTEGER NOT NULL REFERENCES policies(id),
    call_datetime   DATETIME NOT NULL,
    duration_sec    INTEGER NOT NULL,
    agent_name      TEXT NOT NULL,
    audio_file      TEXT,          -- NULL = no recording
    transcript_source TEXT NOT NULL CHECK (transcript_source IN ('SCRIPTED','WHISPER')),
    reason          TEXT,
    CHECK ((transcript_source = 'WHISPER') = (audio_file IS NOT NULL))
);

CREATE INDEX idx_calls_policy_datetime ON calls (policy_id, call_datetime);

INSERT INTO calls VALUES
(1, 1, '2022-08-03 10:14:00',  77, 'J. Whitfield', NULL, 'SCRIPTED', 'Add rental reimbursement'),
(2, 1, '2023-03-10 16:42:00',  96, 'S. Ramirez',   NULL, 'SCRIPTED', 'Upgrade rental tier'),
(3, 1, '2023-11-20 09:05:00',  58, 'T. Morales',   NULL, 'SCRIPTED', 'Question about rental on the F-150'),
(4, 1, '2024-05-02 13:30:00', 101, 'K. Nguyen',    NULL, 'SCRIPTED', 'Vehicle replacement'),
(5, 1, '2025-02-14 11:20:00',  84, 'L. Carter',    NULL, 'SCRIPTED', 'Lower policy cost'),
(6, 2, '2026-02-20 08:55:00',  26, 'D. Patel',     NULL, 'SCRIPTED', 'Remove rental reimbursement'),
(7, 3, '2025-10-14 14:22:00', 101, 'Sarah',        'audio/call_008.mp3', 'WHISPER',  'Lower monthly premium');

CREATE TABLE call_segments (
    id          INTEGER PRIMARY KEY,
    call_id     INTEGER NOT NULL REFERENCES calls(id),
    seq         INTEGER NOT NULL,
    start_sec   REAL NOT NULL,
    end_sec     REAL NOT NULL,
    speaker     TEXT NOT NULL CHECK (speaker IN ('MEMBER','AGENT')),
    text        TEXT NOT NULL,
    UNIQUE (call_id, seq),
    CHECK (end_sec > start_sec)
);

INSERT INTO call_segments (call_id, seq, start_sec, end_sec, speaker, text) VALUES
-- Call 1: add rental R30 to the CR-V
(1,1,0,  8,  'AGENT', 'Thank you for calling USAA, this is Jordan. How can I help you today?'),
(1,2,8,  21, 'MEMBER','Hi, I want to add rental car coverage to my Honda CR-V. My wife uses it every day.'),
(1,3,21, 55, 'AGENT', 'Sure. We have rental reimbursement at 30, 40, 50 or 60 dollars a day, up to 30 days per claim.'),
(1,4,55, 70, 'MEMBER','Let''s do the 30 dollar one for now, just the basic.'),
(1,5,70, 77, 'AGENT', 'Done. Rental reimbursement at 30 dollars a day, 900 max, is added to the CR-V effective today.'),
-- Call 2: upgrade to R50
(2,1,0,  6,  'AGENT', 'USAA, this is Sofia. How can I help?'),
(2,2,6,  25, 'MEMBER','Last time I had a claim the rental they gave me was tiny. What kind of car does my coverage get me?'),
(2,3,25, 48, 'AGENT', 'With 30 dollars a day you''re in the economy or compact class.'),
(2,4,48, 60, 'MEMBER','We have two kids. What would I need for a full-size sedan or a small SUV?'),
(2,5,60, 82, 'AGENT', 'That would be the 50 dollar a day level, full-size sedan or small SUV, 1,500 max per claim.'),
(2,6,82, 90, 'MEMBER','Okay, please change it to the 50.'),
(2,7,90, 96, 'AGENT', 'Updated. Your CR-V now has rental reimbursement at 50 dollars a day, effective today.'),
-- Call 3: inquiry only, no change (trap case)
(3,1,0,  5,  'AGENT', 'Thanks for calling USAA, this is Tomas.'),
(3,2,5,  18, 'MEMBER','Quick question, does my F-150 have rental coverage too?'),
(3,3,18, 35, 'AGENT', 'No, rental reimbursement is only on the CR-V right now. I can add it to the F-150 if you''d like.'),
(3,4,35, 40, 'MEMBER','How much would that be?'),
(3,5,40, 52, 'AGENT', 'About six dollars a month for the 30 dollar level.'),
(3,6,52, 58, 'MEMBER','Let me think about it and talk to my wife. Don''t change anything for now.'),
-- Call 4: replace F-150 with Tacoma
(4,1,0,  6,  'AGENT', 'USAA, this is Kim speaking.'),
(4,2,6,  30, 'MEMBER','I traded in my F-150 and bought a 2024 Tacoma. I need to swap it on my policy.'),
(4,3,30, 48, 'AGENT', 'I''ll remove the F-150 and add the Tacoma. Do you want the same comprehensive and collision, 500 deductible?'),
(4,4,48, 62, 'MEMBER','Yes. And this time I do want rental on the truck. What gets me a pickup?'),
(4,5,62, 85, 'AGENT', 'A pickup rental is the 60 dollar level. The 40 dollar level covers an intermediate or standard car.'),
(4,6,85, 95, 'MEMBER','Go with 40, I can drive a sedan for a couple weeks.'),
(4,7,95, 101,'AGENT', 'Done. F-150 removed, Tacoma added with comprehensive, collision and rental at 40 dollars a day.'),
-- Call 5: wants to remove rental, then changes their mind (trap case)
(5,1,0,  5,  'AGENT', 'USAA, this is Lauren.'),
(5,2,5,  20, 'MEMBER','I need to lower my premium. Can you remove the rental coverage from the CR-V?'),
(5,3,20, 42, 'AGENT', 'I can. Just so you know, without it you''d pay for any rental yourself after a covered claim.'),
(5,4,42, 50, 'MEMBER','Hmm. What if I just go down a level instead of removing it?'),
(5,5,50, 70, 'AGENT', 'Going from 50 to 40 dollars a day saves a bit and you keep a standard sedan class.'),
(5,6,70, 78, 'MEMBER','Okay, don''t remove it. Lower it to 40.'),
(5,7,78, 84, 'AGENT', 'Updated, rental on the CR-V is now 40 dollars a day, effective today.'),
-- Call 6: policy 2 removes rental
(6,1,0,  5,  'AGENT', 'USAA, this is Dev.'),
(6,2,5,  20, 'MEMBER','I have a second car now I can use if the Pacifica is in the shop. Please remove the rental coverage.'),
(6,3,20, 26, 'AGENT', 'Okay, rental reimbursement at 60 dollars a day is removed from the Pacifica effective today.'),
-- Call 7: real audio (data/audio/call_008.mp3), Whisper transcript split into turns by
-- scripts/label_speakers.py. Member asks to remove rental; agent promises it; NOT applied.
(7,1,0.0,3.52,'AGENT','Thank you for calling customer service. My name is Sarah. How can I help you today?'),
(7,2,5.08,13.94,'MEMBER','Hi, Sarah. Yeah, I''m calling because my monthly auto bill just seems too high lately. I''m trying to see if there''s any way we can lower my payments on the Volvo EX30.'),
(7,3,14.54,21.44,'AGENT','I can certainly look into that for you and review your policy options. To get started, could I please have your first and last name?'),
(7,4,22.48,23.82,'MEMBER','Sure. It''s Fanny Rios.'),
(7,5,24.36,27.48,'AGENT','Thank you, Fanny. And can I get your member number, please?'),
(7,6,27.48,31.88,'MEMBER','Let me check. Yeah, it''s 123456.'),
(7,7,32.76,54.58,'AGENT','Perfect. I have your account pulled up. I see the 2024 Volvo EX30 here with VIN number ERG2174639K. Let''s take a look at your current coverages. All right. One option to lower your monthly premium without changing your deductibles is to remove the rental reimbursement coverage.'),
(7,8,55.44,57.72,'MEMBER','Okay. And how much would that save me?'),
(7,9,58.72,73.74,'AGENT','Removing that would drop your premium by about $15 a month. Just keep in mind, if we remove this and you are in an accident, the policy will no longer cover the cost of a rental car while your Volvo is in the shop. You would have to pay for a rental out of pocket.'),
(7,10,75.36,82.86,'MEMBER','Honestly, I work from home most of the week anyway, so if the car is in the shop, I can manage without a rental. Let''s go ahead and take that off.'),
(7,11,83.96,95.76,'AGENT','Completely understand. I will go ahead and process that endorsement for you right now. Your new monthly payment will be updated on your next billing cycle. Is there anything else I can adjust for you today?'),
(7,12,97.06,100.36,'MEMBER','No, that''s exactly what I needed. Thanks for your help, Sarah.');

-- ---------------------------------------------------------------------
-- 5. TRANSACTIONS (change history)
--    old_/new_rental_tier and old_/new_deductible hold the exact values
--    for comparison; old_/new_value_text are for display only.
--    source_call_id is the call recorded by the policy system, if any. It
--    may be missing or wrong - the audit finds calls by policy and date and
--    uses this only as a hint.
-- ---------------------------------------------------------------------

CREATE TABLE transactions (
    id                INTEGER PRIMARY KEY,
    policy_id         INTEGER NOT NULL REFERENCES policies(id),
    transaction_date  DATE NOT NULL,
    change_type       TEXT NOT NULL CHECK (change_type IN ('NEW_BUSINESS','ADD','REMOVE','MODIFY')),
    target            TEXT NOT NULL CHECK (target IN ('POLICY','COVERAGE','VEHICLE')),
    coverage_code     TEXT REFERENCES coverage_catalog(code),
    vehicle_id        INTEGER REFERENCES vehicles(id),
    old_rental_tier   TEXT REFERENCES rental_tiers(code),
    new_rental_tier   TEXT REFERENCES rental_tiers(code),
    old_deductible    INTEGER,
    new_deductible    INTEGER,
    old_value_text    TEXT,
    new_value_text    TEXT,
    channel           TEXT NOT NULL CHECK (channel IN ('PHONE','APP','WEB')),
    source_call_id    INTEGER REFERENCES calls(id),
    agent_name        TEXT
);

CREATE INDEX idx_transactions_policy_date ON transactions (policy_id, transaction_date);

INSERT INTO transactions VALUES
(1,  1, '2022-01-15', 'NEW_BUSINESS', 'POLICY',   NULL,      NULL, NULL,  NULL,  NULL, NULL, NULL,   'New policy: F-150 and CR-V', 'WEB',   NULL, NULL),
(2,  1, '2022-08-03', 'ADD',          'COVERAGE', 'RENTAL',  2,    NULL,  'R30', NULL, NULL, NULL,   'R30 ($30/day)',  'PHONE', 1, 'J. Whitfield'),
(3,  1, '2023-03-10', 'MODIFY',       'COVERAGE', 'RENTAL',  2,    'R30', 'R50', NULL, NULL, 'R30 ($30/day)', 'R50 ($50/day)', 'PHONE', 2, 'S. Ramirez'),
(4,  1, '2024-05-02', 'REMOVE',       'VEHICLE',  NULL,      1,    NULL,  NULL,  NULL, NULL, '2019 Ford F-150', NULL, 'PHONE', 4, 'K. Nguyen'),
(5,  1, '2024-05-02', 'ADD',          'VEHICLE',  NULL,      3,    NULL,  NULL,  NULL, NULL, NULL,   '2024 Toyota Tacoma', 'PHONE', 4, 'K. Nguyen'),
(6,  1, '2024-05-02', 'ADD',          'COVERAGE', 'RENTAL',  3,    NULL,  'R40', NULL, NULL, NULL,   'R40 ($40/day)',  'PHONE', 4, 'K. Nguyen'),
(7,  1, '2024-05-02', 'ADD',          'COVERAGE', 'CRA',     3,    NULL,  NULL,  NULL, NULL, NULL,   '20% over ACV',   'APP',   NULL, NULL),
(8,  1, '2025-02-14', 'MODIFY',       'COVERAGE', 'RENTAL',  2,    'R50', 'R40', NULL, NULL, 'R50 ($50/day)', 'R40 ($40/day)', 'PHONE', 5, 'L. Carter'),
(9,  2, '2023-06-01', 'NEW_BUSINESS', 'POLICY',   NULL,      NULL, NULL,  NULL,  NULL, NULL, NULL,   'New policy: Pacifica with RENTAL R60', 'WEB', NULL, NULL),
(10, 2, '2024-10-12', 'ADD',          'COVERAGE', 'AF',      NULL, NULL,  NULL,  NULL, NULL, NULL,   'Accident Forgiveness', 'WEB', NULL, NULL),
(11, 2, '2026-02-20', 'REMOVE',       'COVERAGE', 'RENTAL',  4,    'R60', NULL,  NULL, NULL, 'R60 ($60/day)', NULL, 'PHONE', 6, 'D. Patel'),
(12, 3, '2024-04-15', 'NEW_BUSINESS', 'POLICY',   NULL,      NULL, NULL,  NULL,  NULL, NULL, NULL,   'New policy: Volvo EX30 with RENTAL R40', 'WEB', NULL, NULL);
-- Policy 3: the rental removal promised on call 7 was never applied (no transaction).

-- ---------------------------------------------------------------------
-- 6. GROUND TRUTH - EVALUATION ONLY
--    The expected outcome of auditing each call. Used to score the AI;
--    NEVER exposed to the chatbot tools.
-- ---------------------------------------------------------------------

CREATE TABLE expected_call_events (
    id              INTEGER PRIMARY KEY,
    call_id         INTEGER NOT NULL REFERENCES calls(id),
    segment_id      INTEGER REFERENCES call_segments(id),
    event_type      TEXT NOT NULL CHECK (event_type IN
                    ('CHANGE_REQUEST','INQUIRY','CHANGE_OF_MIND','CONFIRMATION','AGENT_PROMISE')),
    description     TEXT NOT NULL,
    coverage_code   TEXT REFERENCES coverage_catalog(code),
    transaction_id  INTEGER REFERENCES transactions(id),  -- NULL = no transaction
    needs_review    INTEGER NOT NULL DEFAULT 0            -- 1 = CRU alert
);

CREATE INDEX idx_expected_call_events_call ON expected_call_events (call_id);

INSERT INTO expected_call_events (call_id, segment_id, event_type, description, coverage_code, transaction_id, needs_review)
SELECT 1, id, 'CHANGE_REQUEST', 'Member asks to add rental at $30/day to the CR-V', 'RENTAL', 2, 0 FROM call_segments WHERE call_id=1 AND seq=4 UNION ALL
SELECT 2, id, 'INQUIRY',        'Member asks what car class their rental coverage gets', 'RENTAL', NULL, 0 FROM call_segments WHERE call_id=2 AND seq=2 UNION ALL
SELECT 2, id, 'CHANGE_REQUEST', 'Member asks to upgrade rental to $50/day (full-size / small SUV)', 'RENTAL', 3, 0 FROM call_segments WHERE call_id=2 AND seq=6 UNION ALL
SELECT 3, id, 'INQUIRY',        'Asks whether the F-150 has rental; decides not to change anything', 'RENTAL', NULL, 0 FROM call_segments WHERE call_id=3 AND seq=6 UNION ALL
SELECT 4, id, 'CHANGE_REQUEST', 'Replace F-150 with 2024 Tacoma and add rental at $40/day', 'RENTAL', 6, 0 FROM call_segments WHERE call_id=4 AND seq=6 UNION ALL
SELECT 5, id, 'CHANGE_REQUEST', 'Member asks to remove rental from the CR-V', 'RENTAL', NULL, 0 FROM call_segments WHERE call_id=5 AND seq=2 UNION ALL
SELECT 5, id, 'CHANGE_OF_MIND', 'Do not remove; lower rental to $40/day', 'RENTAL', 8, 0 FROM call_segments WHERE call_id=5 AND seq=6 UNION ALL
SELECT 6, id, 'CHANGE_REQUEST', 'Member asks to remove rental from the Pacifica', 'RENTAL', 11, 0 FROM call_segments WHERE call_id=6 AND seq=2 UNION ALL
SELECT 7, id, 'INQUIRY',        'Member asks how much removing rental would save (about $15/month)', 'RENTAL', NULL, 0 FROM call_segments WHERE call_id=7 AND seq=8 UNION ALL
SELECT 7, id, 'CHANGE_REQUEST', 'Member asks to remove rental from the Volvo EX30; NO transaction exists', 'RENTAL', NULL, 1 FROM call_segments WHERE call_id=7 AND seq=10 UNION ALL
SELECT 7, id, 'AGENT_PROMISE',  'Agent says they will process the endorsement right now; NO transaction exists', 'RENTAL', NULL, 1 FROM call_segments WHERE call_id=7 AND seq=11;

-- ---------------------------------------------------------------------
-- 7. AI OUTPUT (written by the app, empty in the seed)
-- ---------------------------------------------------------------------

-- One analysis per call (cached so the demo can replay it)
CREATE TABLE call_analysis (
    call_id            INTEGER PRIMARY KEY REFERENCES calls(id),
    summary            TEXT NOT NULL,
    highlights         TEXT,          -- JSON: [{segment_id, start_sec, text}]
    sentiment          TEXT,          -- JSON: overall + over time, per speaker
    requested_changes  TEXT,          -- JSON: what the member asked for
    agent_promises     TEXT,          -- JSON: what the agent said they would do
    model              TEXT NOT NULL,
    created_at         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Audit verdicts: requested on the call vs. applied to the policy
CREATE TABLE audit_findings (
    id               INTEGER PRIMARY KEY,
    policy_id        INTEGER NOT NULL REFERENCES policies(id),
    transaction_id   INTEGER REFERENCES transactions(id),   -- NULL = nothing was applied
    call_id          INTEGER REFERENCES calls(id),          -- NULL = no call evidence
    segment_id       INTEGER REFERENCES call_segments(id),  -- quoted segment
    coverage_code    TEXT REFERENCES coverage_catalog(code),
    verdict          TEXT NOT NULL CHECK (verdict IN
                     ('MATCH','MISMATCH','NOT_APPLIED','NO_CALL_EVIDENCE')),
    requested        TEXT,          -- what was asked / promised on the call
    applied          TEXT,          -- what the policy records show
    explanation      TEXT NOT NULL,
    model            TEXT NOT NULL,
    created_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_audit_findings_policy ON audit_findings (policy_id);
CREATE INDEX idx_audit_findings_transaction ON audit_findings (transaction_id);

-- ---------------------------------------------------------------------
-- 8. VIEWS
-- ---------------------------------------------------------------------

-- [chatbot] Coverages in force today; rental limits come from rental_tiers
CREATE VIEW v_active_coverages AS
SELECT p.policy_number, m.full_name AS member_name,
       COALESCE(v.model_year||' '||v.make||' '||v.model, '(policy level)') AS vehicle,
       c.coverage_code, cc.name AS coverage_name,
       CASE WHEN rt.code IS NOT NULL
            THEN printf('$%d/day, $%,d max', rt.daily_limit, rt.max_per_claim)
            ELSE c.limit_text END AS limit_text,
       c.deductible, c.rental_tier,
       rt.vehicle_class AS rental_class,
       c.effective_from
FROM coverages c
JOIN policies p ON p.id = c.policy_id
JOIN members m ON m.id = p.member_id
JOIN coverage_catalog cc ON cc.code = c.coverage_code
LEFT JOIN vehicles v ON v.id = c.vehicle_id
LEFT JOIN rental_tiers rt ON rt.code = c.rental_tier
WHERE c.effective_to IS NULL;

-- [chatbot] Transaction history with its policy term
CREATE VIEW v_change_history AS
SELECT t.id AS transaction_id, p.policy_number, pt.term_number,
       t.transaction_date, t.change_type, t.target, t.coverage_code,
       COALESCE(v.model_year||' '||v.make||' '||v.model, '') AS vehicle,
       t.old_rental_tier, t.new_rental_tier, t.old_deductible, t.new_deductible,
       t.old_value_text, t.new_value_text, t.channel, t.source_call_id
FROM transactions t
JOIN policies p ON p.id = t.policy_id
JOIN policy_terms pt ON pt.policy_id = t.policy_id
     AND t.transaction_date >= pt.start_date AND t.transaction_date < pt.end_date
LEFT JOIN vehicles v ON v.id = t.vehicle_id;

-- [chatbot + UI] Full transcript of each call, one row per call.
-- Built from call_segments (the stored turns), so it never drifts from them.
-- full_text lines look like: "[1:15] MEMBER: Let's go ahead and take that off."
CREATE VIEW v_call_transcripts AS
SELECT ca.id AS call_id, p.policy_number, m.full_name AS member_name,
       ca.call_datetime, ca.agent_name, ca.duration_sec, ca.reason,
       ca.transcript_source, ca.audio_file,
       t.turn_count, t.full_text
FROM calls ca
JOIN policies p ON p.id = ca.policy_id
JOIN members m ON m.id = p.member_id
LEFT JOIN (
    SELECT call_id, COUNT(*) AS turn_count, group_concat(line, char(10)) AS full_text
    FROM (SELECT call_id,
                 printf('[%d:%02d] %s: %s', CAST(start_sec AS INTEGER)/60,
                        CAST(start_sec AS INTEGER)%60, speaker, text) AS line
          FROM call_segments ORDER BY call_id, seq)
    GROUP BY call_id
) t ON t.call_id = ca.id;

-- [EVALUATION ONLY] Expected evidence: said on the call vs. applied
CREATE VIEW v_expected_cru_evidence AS
SELECT ca.id AS call_id, ca.call_datetime, p.policy_number,
       e.event_type, e.description, e.coverage_code,
       printf('%d:%02d', CAST(s.start_sec AS INTEGER)/60, CAST(s.start_sec AS INTEGER)%60) AS timestamp,
       s.speaker, s.text AS quote,
       e.transaction_id,
       CASE WHEN e.needs_review = 1 THEN 'ALERT: promised on call, not applied'
            WHEN e.transaction_id IS NOT NULL THEN 'Applied'
            WHEN e.event_type = 'CHANGE_REQUEST' THEN 'Requested and withdrawn on the same call'
            ELSE 'No change (inquiry)' END AS outcome
FROM expected_call_events e
JOIN calls ca ON ca.id = e.call_id
JOIN policies p ON p.id = ca.policy_id
LEFT JOIN call_segments s ON s.id = e.segment_id;
