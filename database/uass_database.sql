-- =====================================================================
--  UASS SCADA - Upper Air Sounding System
--  Database Script: Schema, Seed Data and Application Queries
-- =====================================================================
--  Database      : H2 (embedded, jdbc:h2:mem:uassdb) via Spring Data JPA
--  ORM           : Hibernate (spring.jpa.hibernate.ddl-auto=update)
--  Backend       : Spring Boot 4.1 / Java 17
--
--  Sections
--    1. Schema (tables, constraints, indexes)
--    2. Seed / default data
--    3. Application queries (SQL behind each JPA repository method)
--         3.1 Authentication & users      (UserRepository)
--         3.2 Frame definitions           (FrameRepository)
--         3.3 Frame parameters            (ParameterRepository)
--         3.4 Alarm rules                 (AlarmRuleRepository)
--         3.5 Alarm events                (AlarmEventRepository)
--         3.6 Station configuration       (StationConfigRepository)
--    4. Monitoring, reporting & maintenance queries
--
--  Entity -> Table mapping
--    UserEntity          -> app_user
--    FrameEntity         -> frame_definition
--    ParameterEntity     -> parameter_definition   (N : 1 frame_definition)
--    AlarmRuleEntity     -> alarm_rule
--    AlarmEventEntity    -> alarm_event
--    StationConfigEntity -> station_config         (singleton row, id = 1)
--
--  Note: live sensor readings are NOT stored in the database. They are kept
--  in an in-memory ring buffer (SensorHistoryService, last 2000 readings)
--  and streamed over WebSocket. Only configuration, users and alarms persist.
-- =====================================================================


-- =====================================================================
-- 1. SCHEMA
-- =====================================================================

-- Drop in reverse dependency order (child tables first)
DROP TABLE IF EXISTS parameter_definition;
DROP TABLE IF EXISTS frame_definition;
DROP TABLE IF EXISTS alarm_event;
DROP TABLE IF EXISTS alarm_rule;
DROP TABLE IF EXISTS station_config;
DROP TABLE IF EXISTS app_user;


-- ---------------------------------------------------------------------
-- 1.1 app_user : operator accounts (JWT login)
--     role: ADMIN (full access) | OPERATOR (monitor + acknowledge alarms)
-- ---------------------------------------------------------------------
CREATE TABLE app_user (
    id          BIGINT        AUTO_INCREMENT PRIMARY KEY,
    username    VARCHAR(255)  NOT NULL,
    password    VARCHAR(255)  NOT NULL,                 -- BCrypt hash, never plain text
    role        VARCHAR(255)  NOT NULL DEFAULT 'OPERATOR',
    full_name   VARCHAR(255)  NOT NULL DEFAULT 'Operator',
    enabled     BOOLEAN       NOT NULL DEFAULT TRUE,
    last_login  TIMESTAMP,
    created_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_app_user_username UNIQUE (username),
    CONSTRAINT ck_app_user_role     CHECK (role IN ('ADMIN', 'OPERATOR'))
);


-- ---------------------------------------------------------------------
-- 1.2 frame_definition : layout of the incoming binary telemetry frame
--     Only one frame is active at a time (used by BinaryFrameParser).
-- ---------------------------------------------------------------------
CREATE TABLE frame_definition (
    id                  BIGINT        AUTO_INCREMENT PRIMARY KEY,
    frame_name          VARCHAR(255)  NOT NULL,
    total_frame_length  INT           NOT NULL,         -- bytes
    active              BOOLEAN       NOT NULL DEFAULT FALSE,
    CONSTRAINT uk_frame_definition_name UNIQUE (frame_name),
    CONSTRAINT ck_frame_length_positive CHECK (total_frame_length > 0)
);


-- ---------------------------------------------------------------------
-- 1.3 parameter_definition : one field inside a frame
--     engineering_value = raw_value * scale_factor + offset_value
-- ---------------------------------------------------------------------
CREATE TABLE parameter_definition (
    id            BIGINT        AUTO_INCREMENT PRIMARY KEY,
    name          VARCHAR(255)  NOT NULL,
    unit          VARCHAR(255),
    byte_offset   INT           NOT NULL,
    data_type     VARCHAR(255)  NOT NULL,
    scale_factor  DOUBLE        NOT NULL DEFAULT 1.0,
    offset_value  DOUBLE        NOT NULL DEFAULT 0.0,
    display_mode  VARCHAR(255)  NOT NULL,
    param_order   INT           NOT NULL DEFAULT 0,
    frame_id      BIGINT        NOT NULL,
    CONSTRAINT fk_parameter_frame
        FOREIGN KEY (frame_id) REFERENCES frame_definition (id) ON DELETE CASCADE,
    CONSTRAINT ck_parameter_data_type
        CHECK (data_type IN ('INT8','UINT8','INT16','UINT16','INT32','UINT32','FLOAT32','FLOAT64')),
    CONSTRAINT ck_parameter_display_mode
        CHECK (display_mode IN ('DISPLAY_ONLY','PLOT_ONLY','BOTH','IGNORE')),
    CONSTRAINT ck_parameter_offset_positive
        CHECK (byte_offset >= 0)
);


-- ---------------------------------------------------------------------
-- 1.4 alarm_rule : threshold rules evaluated on every sensor reading
--     Fires when value > threshold (ABOVE) or value < threshold (BELOW)
-- ---------------------------------------------------------------------
CREATE TABLE alarm_rule (
    id              BIGINT        AUTO_INCREMENT PRIMARY KEY,
    parameter_name  VARCHAR(255)  NOT NULL,
    operator        VARCHAR(255)  NOT NULL,
    threshold       DOUBLE        NOT NULL,
    severity        VARCHAR(255)  NOT NULL,
    enabled         BOOLEAN       NOT NULL DEFAULT TRUE,
    CONSTRAINT ck_alarm_rule_operator CHECK (operator IN ('ABOVE', 'BELOW')),
    CONSTRAINT ck_alarm_rule_severity CHECK (severity IN ('INFO', 'WARNING', 'CRITICAL'))
);


-- ---------------------------------------------------------------------
-- 1.5 alarm_event : log of every triggered alarm + operator acknowledgement
-- ---------------------------------------------------------------------
CREATE TABLE alarm_event (
    id               BIGINT        AUTO_INCREMENT PRIMARY KEY,
    parameter_name   VARCHAR(255)  NOT NULL,
    measured_value   DOUBLE        NOT NULL,
    threshold        DOUBLE        NOT NULL,
    severity         VARCHAR(255)  NOT NULL,
    message          VARCHAR(255)  NOT NULL,
    timestamp        TIMESTAMP     NOT NULL,
    acknowledged     BOOLEAN       NOT NULL DEFAULT FALSE,
    acknowledged_at  TIMESTAMP,
    CONSTRAINT ck_alarm_event_severity CHECK (severity IN ('INFO', 'WARNING', 'CRITICAL'))
);


-- ---------------------------------------------------------------------
-- 1.6 station_config : ground station site metadata (single row, id = 1)
-- ---------------------------------------------------------------------
CREATE TABLE station_config (
    id               BIGINT        PRIMARY KEY,
    station_name     VARCHAR(255)  NOT NULL DEFAULT 'UASS Ground Station',
    station_id       VARCHAR(255)  NOT NULL DEFAULT 'UASS-01',
    location         VARCHAR(255)  DEFAULT 'Not Configured',
    icao_code        VARCHAR(255)  DEFAULT '',
    latitude         DOUBLE        DEFAULT 0.0,
    longitude        DOUBLE        DEFAULT 0.0,
    altitude_meters  DOUBLE        DEFAULT 0.0,            -- metres above MSL
    operator_name    VARCHAR(255)  DEFAULT 'Operator',
    description      VARCHAR(255)  DEFAULT 'Upper Air Sounding System telemetry ground station',
    CONSTRAINT ck_station_config_singleton CHECK (id = 1),
    CONSTRAINT ck_station_latitude  CHECK (latitude  BETWEEN -90  AND 90),
    CONSTRAINT ck_station_longitude CHECK (longitude BETWEEN -180 AND 180)
);


-- ---------------------------------------------------------------------
-- 1.7 Indexes (support the most frequent application queries)
-- ---------------------------------------------------------------------
CREATE INDEX idx_parameter_frame_order   ON parameter_definition (frame_id, param_order);
CREATE INDEX idx_frame_active            ON frame_definition (active);
CREATE INDEX idx_alarm_rule_enabled      ON alarm_rule (enabled);
CREATE INDEX idx_alarm_event_timestamp   ON alarm_event (timestamp DESC);
CREATE INDEX idx_alarm_event_ack         ON alarm_event (acknowledged);


-- =====================================================================
-- 2. SEED / DEFAULT DATA
--    Mirrors what the application inserts on first startup.
-- =====================================================================

-- 2.1 Station configuration (StationConfigService creates this row if missing)
INSERT INTO station_config
    (id, station_name, station_id, location, icao_code, latitude, longitude,
     altitude_meters, operator_name, description)
VALUES
    (1, 'UASS Ground Station', 'UASS-01', 'Not Configured', '', 0.0, 0.0,
     0.0, 'Operator', 'Upper Air Sounding System telemetry ground station');


-- 2.2 Default alarm rules (AlarmRuleSeeder - only when alarm_rule is empty)
INSERT INTO alarm_rule (parameter_name, operator, threshold, severity, enabled) VALUES
    ('Speed',          'ABOVE', 15.0,  'WARNING',  TRUE),
    ('Pressure (hPa)', 'BELOW', 990.0, 'CRITICAL', TRUE);


-- 2.3 Default frame "UASS_Default_Frame" (FrameService.createDefaultFrame)
--     22-byte frame, 10 parameters, all shown as value + graph (BOTH)
INSERT INTO frame_definition (frame_name, total_frame_length, active)
VALUES ('UASS_Default_Frame', 22, TRUE);

INSERT INTO parameter_definition
    (name, unit, byte_offset, data_type, scale_factor, offset_value, display_mode, param_order, frame_id)
SELECT p.name, p.unit, p.byte_offset, p.data_type, p.scale_factor, p.offset_value, 'BOTH', p.param_order, f.id
FROM (VALUES
    ('Time_Inst',            's',    0,  'UINT32', 1.0, 0.0, 0),
    ('Direction',            'deg',  4,  'UINT16', 0.1, 0.0, 1),
    ('Speed',                'm/s',  6,  'UINT16', 0.1, 0.0, 2),
    ('Dry Bulb Temperature', '°C',   8,  'INT16',  0.1, 0.0, 3),
    ('Wet Bulb Temperature', '°C',   10, 'INT16',  0.1, 0.0, 4),
    ('Relative Humidity',    '%',    12, 'UINT16', 0.1, 0.0, 5),
    ('Pressure (IMU)',       'hPa',  14, 'UINT16', 1.0, 0.0, 6),
    ('Pressure (hPa)',       'hPa',  16, 'UINT16', 0.1, 0.0, 7),
    ('Solar Radiation',      'W/m2', 18, 'UINT16', 1.0, 0.0, 8),
    ('Rainfall',             'mm',   20, 'UINT16', 0.1, 0.0, 9)
) AS p(name, unit, byte_offset, data_type, scale_factor, offset_value, param_order)
CROSS JOIN frame_definition f
WHERE f.frame_name = 'UASS_Default_Frame';


-- 2.4 Default users (UserSeeder)
--     Users are created by the application on startup with BCrypt-hashed
--     passwords, so no password hashes are stored in this script.
--     To add a user manually, generate a BCrypt hash first and insert it:
--
-- INSERT INTO app_user (username, password, role, full_name, enabled, created_at)
-- VALUES ('admin',    '<bcrypt-hash>', 'ADMIN',    'Station Administrator', TRUE, CURRENT_TIMESTAMP),
--        ('operator', '<bcrypt-hash>', 'OPERATOR', 'Station Operator',      TRUE, CURRENT_TIMESTAMP);


-- =====================================================================
-- 3. APPLICATION QUERIES
--    SQL equivalent of every Spring Data JPA repository method used by
--    the backend. Named parameters (:name) are bound by Hibernate.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 3.1 Authentication & users  (UserRepository / AuthService / UserSeeder)
-- ---------------------------------------------------------------------

-- findByUsername(username)  - login, JWT filter, /api/auth/me
SELECT id, username, password, role, full_name, enabled, last_login, created_at
FROM app_user
WHERE username = :username;

-- existsByUsername(username)  - UserSeeder, avoids duplicate default users
SELECT CASE WHEN COUNT(*) > 0 THEN TRUE ELSE FALSE END AS user_exists
FROM app_user
WHERE username = :username;

-- save(user) on successful login - record last login time
UPDATE app_user
SET last_login = CURRENT_TIMESTAMP
WHERE username = :username;

-- save(user) - create a new user (UserSeeder)
INSERT INTO app_user (username, password, role, full_name, enabled, created_at)
VALUES (:username, :bcryptPassword, :role, :fullName, TRUE, CURRENT_TIMESTAMP);


-- ---------------------------------------------------------------------
-- 3.2 Frame definitions  (FrameRepository / FrameService)
-- ---------------------------------------------------------------------

-- findByActiveTrue()  - load active frame on startup / before activating a new one
SELECT id, frame_name, total_frame_length, active
FROM frame_definition
WHERE active = TRUE;

-- Active frame together with its parameters (EAGER fetch of FrameEntity.parameters)
SELECT f.id AS frame_id, f.frame_name, f.total_frame_length,
       p.id AS parameter_id, p.name, p.unit, p.byte_offset, p.data_type,
       p.scale_factor, p.offset_value, p.display_mode, p.param_order
FROM frame_definition f
LEFT JOIN parameter_definition p ON p.frame_id = f.id
WHERE f.active = TRUE
ORDER BY p.param_order;

-- findByFrameName(frameName)  - update an existing frame instead of inserting a duplicate
SELECT id, frame_name, total_frame_length, active
FROM frame_definition
WHERE frame_name = :frameName;

-- existsByFrameName(frameName)
SELECT CASE WHEN COUNT(*) > 0 THEN TRUE ELSE FALSE END AS frame_exists
FROM frame_definition
WHERE frame_name = :frameName;

-- saveAndActivate(definition) - executed as one transaction:
--   step 1: deactivate the currently active frame (if it has a different name)
UPDATE frame_definition
SET active = FALSE
WHERE active = TRUE
  AND frame_name <> :frameName;

--   step 2a: insert the frame if it does not exist yet ...
INSERT INTO frame_definition (frame_name, total_frame_length, active)
VALUES (:frameName, :totalFrameLength, TRUE);

--   step 2b: ... or update it if it already exists
UPDATE frame_definition
SET total_frame_length = :totalFrameLength,
    active = TRUE
WHERE frame_name = :frameName;

--   step 3: replace parameters (orphanRemoval = true deletes the old rows)
DELETE FROM parameter_definition
WHERE frame_id = (SELECT id FROM frame_definition WHERE frame_name = :frameName);

--   step 4: insert each new parameter
INSERT INTO parameter_definition
    (name, unit, byte_offset, data_type, scale_factor, offset_value, display_mode, param_order, frame_id)
VALUES
    (:name, :unit, :byteOffset, :dataType, :scaleFactor, :offset, :displayMode, :order,
     (SELECT id FROM frame_definition WHERE frame_name = :frameName));


-- ---------------------------------------------------------------------
-- 3.3 Frame parameters  (ParameterRepository)
-- ---------------------------------------------------------------------

-- findByFrameIdOrderByOrderAsc(frameId)
SELECT id, name, unit, byte_offset, data_type, scale_factor, offset_value,
       display_mode, param_order, frame_id
FROM parameter_definition
WHERE frame_id = :frameId
ORDER BY param_order ASC;


-- ---------------------------------------------------------------------
-- 3.4 Alarm rules  (AlarmRuleRepository / AlarmService / AlarmRuleSeeder)
-- ---------------------------------------------------------------------

-- findByEnabledTrue()  - evaluated against every incoming sensor reading
SELECT id, parameter_name, operator, threshold, severity, enabled
FROM alarm_rule
WHERE enabled = TRUE;

-- findAll()  - GET /api/alarms/rules
SELECT id, parameter_name, operator, threshold, severity, enabled
FROM alarm_rule
ORDER BY id;

-- count()  - AlarmRuleSeeder seeds defaults only when this returns 0
SELECT COUNT(*) AS rule_count FROM alarm_rule;

-- save(rule) - create a rule
INSERT INTO alarm_rule (parameter_name, operator, threshold, severity, enabled)
VALUES (:parameterName, :operator, :threshold, :severity, :enabled);

-- save(rule) - update an existing rule
UPDATE alarm_rule
SET parameter_name = :parameterName,
    operator       = :operator,
    threshold      = :threshold,
    severity       = :severity,
    enabled        = :enabled
WHERE id = :id;

-- deleteById(id)
DELETE FROM alarm_rule WHERE id = :id;


-- ---------------------------------------------------------------------
-- 3.5 Alarm events  (AlarmEventRepository / AlarmService)
-- ---------------------------------------------------------------------

-- save(event) - log a triggered alarm (AlarmService.evaluate)
INSERT INTO alarm_event
    (parameter_name, measured_value, threshold, severity, message, timestamp, acknowledged)
VALUES
    (:parameterName, :value, :threshold, :severity, :message, CURRENT_TIMESTAMP, FALSE);

-- findTop50ByOrderByTimestampDesc()  - GET /api/alarms/events (latest 50)
SELECT id, parameter_name, measured_value, threshold, severity, message,
       timestamp, acknowledged, acknowledged_at
FROM alarm_event
ORDER BY timestamp DESC
LIMIT 50;

-- countByAcknowledgedFalse()  - unacknowledged badge in the header
SELECT COUNT(*) AS unacknowledged_count
FROM alarm_event
WHERE acknowledged = FALSE;

-- findById(id)
SELECT id, parameter_name, measured_value, threshold, severity, message,
       timestamp, acknowledged, acknowledged_at
FROM alarm_event
WHERE id = :id;

-- acknowledge(id) - operator acknowledges an alarm
UPDATE alarm_event
SET acknowledged    = TRUE,
    acknowledged_at = CURRENT_TIMESTAMP
WHERE id = :id;


-- ---------------------------------------------------------------------
-- 3.6 Station configuration  (StationConfigRepository / StationConfigService)
-- ---------------------------------------------------------------------

-- findById(1)  - GET /api/config/station
SELECT id, station_name, station_id, location, icao_code, latitude, longitude,
       altitude_meters, operator_name, description
FROM station_config
WHERE id = 1;

-- save(existing) - PUT /api/config/station
UPDATE station_config
SET station_name    = :stationName,
    station_id      = :stationId,
    location        = :location,
    icao_code       = :icaoCode,
    latitude        = :latitude,
    longitude       = :longitude,
    altitude_meters = :altitudeMeters,
    operator_name   = :operatorName,
    description     = :description
WHERE id = 1;


-- =====================================================================
-- 4. MONITORING, REPORTING & MAINTENANCE QUERIES
--    Useful for the H2 console (http://localhost:9093/h2-console),
--    debugging and reports.
-- =====================================================================

-- 4.1 Alarm summary by severity
SELECT severity,
       COUNT(*)                                          AS total_alarms,
       SUM(CASE WHEN acknowledged THEN 0 ELSE 1 END)     AS unacknowledged,
       MIN(timestamp)                                    AS first_seen,
       MAX(timestamp)                                    AS last_seen
FROM alarm_event
GROUP BY severity
ORDER BY CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END;

-- 4.2 Parameters that trigger alarms most often
SELECT parameter_name,
       COUNT(*)            AS times_triggered,
       MIN(measured_value) AS min_value,
       MAX(measured_value) AS max_value,
       AVG(measured_value) AS avg_value
FROM alarm_event
GROUP BY parameter_name
ORDER BY times_triggered DESC;

-- 4.3 Unacknowledged critical alarms (oldest first)
SELECT id, parameter_name, measured_value, threshold, message, timestamp
FROM alarm_event
WHERE acknowledged = FALSE
  AND severity = 'CRITICAL'
ORDER BY timestamp ASC;

-- 4.4 Average operator response time (seconds) per severity
SELECT severity,
       COUNT(*) AS acknowledged_alarms,
       AVG(DATEDIFF('SECOND', timestamp, acknowledged_at)) AS avg_ack_seconds
FROM alarm_event
WHERE acknowledged = TRUE
  AND acknowledged_at IS NOT NULL
GROUP BY severity;

-- 4.5 Alarms per hour (trend)
SELECT FORMATDATETIME(timestamp, 'yyyy-MM-dd HH:00') AS hour_bucket,
       COUNT(*) AS alarms
FROM alarm_event
GROUP BY FORMATDATETIME(timestamp, 'yyyy-MM-dd HH:00')
ORDER BY hour_bucket;

-- 4.6 Alarm rules with how many events each has produced
SELECT r.id, r.parameter_name, r.operator, r.threshold, r.severity, r.enabled,
       COUNT(e.id) AS events_logged
FROM alarm_rule r
LEFT JOIN alarm_event e
       ON e.parameter_name = r.parameter_name
      AND e.threshold      = r.threshold
GROUP BY r.id, r.parameter_name, r.operator, r.threshold, r.severity, r.enabled
ORDER BY events_logged DESC;

-- 4.7 Alarm rules that point to a parameter missing from the active frame
--     (such rules can never fire)
SELECT r.*
FROM alarm_rule r
WHERE NOT EXISTS (
    SELECT 1
    FROM parameter_definition p
    JOIN frame_definition f ON f.id = p.frame_id
    WHERE f.active = TRUE
      AND p.name = r.parameter_name
);

-- 4.8 Frame overview: parameter count and bytes used vs. declared length
SELECT f.id, f.frame_name, f.active, f.total_frame_length,
       COUNT(p.id) AS parameter_count,
       COALESCE(MAX(p.byte_offset + CASE p.data_type
            WHEN 'INT8'    THEN 1 WHEN 'UINT8'   THEN 1
            WHEN 'INT16'   THEN 2 WHEN 'UINT16'  THEN 2
            WHEN 'INT32'   THEN 4 WHEN 'UINT32'  THEN 4
            WHEN 'FLOAT32' THEN 4 WHEN 'FLOAT64' THEN 8 END), 0) AS last_byte_used
FROM frame_definition f
LEFT JOIN parameter_definition p ON p.frame_id = f.id
GROUP BY f.id, f.frame_name, f.active, f.total_frame_length
ORDER BY f.active DESC, f.frame_name;

-- 4.9 Frame validation: parameters that overflow the frame length
--     (same rule as FrameService.validateFrameDefinition)
SELECT f.frame_name, p.name, p.byte_offset, p.data_type, f.total_frame_length
FROM parameter_definition p
JOIN frame_definition f ON f.id = p.frame_id
WHERE p.byte_offset + CASE p.data_type
        WHEN 'INT8'    THEN 1 WHEN 'UINT8'   THEN 1
        WHEN 'INT16'   THEN 2 WHEN 'UINT16'  THEN 2
        WHEN 'INT32'   THEN 4 WHEN 'UINT32'  THEN 4
        WHEN 'FLOAT32' THEN 4 WHEN 'FLOAT64' THEN 8 END > f.total_frame_length;

-- 4.10 Frame validation: overlapping byte ranges inside the same frame
WITH ranges AS (
    SELECT frame_id, id, name, byte_offset AS start_byte,
           byte_offset + CASE data_type
                WHEN 'INT8'    THEN 1 WHEN 'UINT8'   THEN 1
                WHEN 'INT16'   THEN 2 WHEN 'UINT16'  THEN 2
                WHEN 'INT32'   THEN 4 WHEN 'UINT32'  THEN 4
                WHEN 'FLOAT32' THEN 4 WHEN 'FLOAT64' THEN 8 END AS end_byte
    FROM parameter_definition
)
SELECT a.frame_id, a.name AS parameter_a, b.name AS parameter_b,
       a.start_byte AS a_start, a.end_byte AS a_end,
       b.start_byte AS b_start, b.end_byte AS b_end
FROM ranges a
JOIN ranges b
  ON a.frame_id = b.frame_id
 AND a.id < b.id
 AND a.start_byte < b.end_byte
 AND a.end_byte   > b.start_byte;

-- 4.11 Frame validation: duplicate parameter names (case-insensitive)
SELECT frame_id, LOWER(name) AS parameter_name, COUNT(*) AS occurrences
FROM parameter_definition
GROUP BY frame_id, LOWER(name)
HAVING COUNT(*) > 1;

-- 4.12 Integrity check: more than one active frame (should return 0)
SELECT COUNT(*) AS active_frames FROM frame_definition WHERE active = TRUE;

-- 4.13 User activity audit
SELECT username, full_name, role, enabled, created_at, last_login,
       CASE WHEN last_login IS NULL THEN 'Never logged in' ELSE 'Active' END AS status
FROM app_user
ORDER BY last_login DESC NULLS LAST;

-- 4.14 Disable / enable a user account (ADMIN maintenance)
UPDATE app_user SET enabled = FALSE WHERE username = :username;
UPDATE app_user SET enabled = TRUE  WHERE username = :username;

-- 4.15 Housekeeping: purge acknowledged alarms older than 30 days
DELETE FROM alarm_event
WHERE acknowledged = TRUE
  AND timestamp < DATEADD('DAY', -30, CURRENT_TIMESTAMP);

-- =====================================================================
-- End of script
-- =====================================================================
