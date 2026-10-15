# UASS SCADA — Database

Database layer for **UASS SCADA (Upper Air Sounding System)**, a real-time telemetry
monitoring dashboard for upper air atmospheric sounding ground stations, developed as
part of a DRDO internship project.

This repository contains my contribution to the project: the complete SQL database
design, seed data, and every query used by the application.

## Tech

- **Database:** H2 (embedded SQL database)
- **Access layer:** Spring Data JPA / Hibernate
- **Backend:** Spring Boot 4.1, Java 17

## Contents

[`database/uass_database.sql`](database/uass_database.sql)

| Section | What it contains |
|---|---|
| 1. Schema | 6 tables with primary keys, foreign keys, unique and CHECK constraints, indexes |
| 2. Seed data | Station config, default alarm rules, default 22-byte telemetry frame with 10 sensor parameters |
| 3. Application queries | SQL for every repository method used by the backend (auth, frames, parameters, alarms, station config) |
| 4. Monitoring & maintenance | Alarm statistics, operator response time, frame validation checks, user audit, cleanup |

## Schema

| Table | Purpose |
|---|---|
| `app_user` | Operator accounts (ADMIN / OPERATOR), BCrypt passwords, last login |
| `frame_definition` | Layout of the incoming binary telemetry frame (one active at a time) |
| `parameter_definition` | Fields inside a frame: byte offset, data type, scale, offset, display mode |
| `alarm_rule` | Threshold rules (ABOVE / BELOW) with severity INFO / WARNING / CRITICAL |
| `alarm_event` | Log of triggered alarms and operator acknowledgements |
| `station_config` | Ground station site details (single row) |

```
frame_definition 1 ──── N parameter_definition
alarm_rule  ──(evaluated on each reading)──▶  alarm_event
```

Live sensor readings are streamed over WebSocket and kept in memory; the database stores
configuration, users and the alarm history.

## How to run

1. Start the backend; the H2 console is available at `http://localhost:9093/h2-console`
   (JDBC URL `jdbc:h2:mem:uassdb`, user `sa`).
2. Run sections 1 and 2 of `uass_database.sql` to create the schema and seed data.
3. Queries in sections 3 and 4 use named parameters (`:username`, `:id`, ...) —
   replace them with values when running manually.

The script has been tested on H2 2.4. Sections 1–3 are standard SQL; a few date functions
in section 4 (`DATEDIFF`, `FORMATDATETIME`, `DATEADD`) are H2-specific.
