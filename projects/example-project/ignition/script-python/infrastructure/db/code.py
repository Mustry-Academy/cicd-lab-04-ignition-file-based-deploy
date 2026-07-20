"""infrastructure.db -- the ONLY place that talks to system.db.

Two lessons baked in here:
  1. Always parameterize. Every query below passes values as bound parameters,
     never string-concatenated into SQL. This is the SQL-injection guard rail.
  2. Name the database in ONE constant. The lab's TimescaleDB connection is
     'ignition_local_development' on the local gateway; promote-time the test/production gateways
     point their own connection at their own logical database.

The 'readings' table is assumed to exist (create it via a named query or your
DB migrations):

    CREATE TABLE readings (
        id         BIGSERIAL PRIMARY KEY,
        ts         TIMESTAMPTZ NOT NULL DEFAULT now(),
        unit_name  TEXT        NOT NULL,
        temp_c     DOUBLE PRECISION,
        status     TEXT
    );
"""

# Jython 2.7 (Ignition).

from common import log

logger = log.get("infrastructure.db")

# The Ignition database connection name (Config -> Databases -> Connections).
DB = "ignition_local_development"


def log_reading(unit_name, temp_c, status):
    """Insert one evaluated reading. Returns the new row count (1 on success)."""
    sql = ("INSERT INTO readings (unit_name, temp_c, status) "
           "VALUES (?, ?, ?)")
    try:
        return system.db.runPrepUpdate(sql, [unit_name, temp_c, status], DB)
    except Exception as e:
        # Don't let a logging-table hiccup take down the evaluation loop.
        logger.error("failed to log reading for %s: %s" % (unit_name, e))
        return 0


def recent_readings(unit_name, hours=24):
    """Return a dataset of recent readings for one unit, newest first."""
    sql = ("SELECT ts, temp_c, status FROM readings "
           "WHERE unit_name = ? AND ts >= now() - (? || ' hours')::interval "
           "ORDER BY ts DESC")
    return system.db.runPrepQuery(sql, [unit_name, hours], DB)


def units_in_alarm():
    """Return the distinct unit names whose latest status is ALARM.

    Demonstrates a named query call -- define 'Refrigeration/UnitsInAlarm' in
    the project and the binding stays in the Designer, the call stays here.
    """
    try:
        return system.db.runNamedQuery("Refrigeration/UnitsInAlarm", {})
    except Exception:
        logger.warn("named query Refrigeration/UnitsInAlarm not found; "
                    "returning empty result")
        return system.dataset.toDataSet([], [])
