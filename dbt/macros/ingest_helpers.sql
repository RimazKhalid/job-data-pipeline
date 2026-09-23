{#
    Helpers shared by the four ATS staging models (Ashby, Workable, Greenhouse, SmartRecruiters).

    ATS files carry no collection timestamp of their own (unlike the Jooble/JSearch envelopes),
    so the collection date is read from the landing path:
        ashby/ingest_date=2026-09-16/alan.json  ->  2026-09-16
#}

{% macro ingest_date_from_path(column) %}
    to_date(regexp_substr({{ column }}, 'ingest_date=([0-9]{4}-[0-9]{2}-[0-9]{2})', 1, 1, 'e', 1))
{% endmacro %}


{#
    Turns a DATE into midnight UTC as TIMESTAMP_TZ.
    Used for ingest_date and for date-only source fields (Workable published_on),
    so they never pick up the Snowflake session time zone by accident.
#}
{% macro date_to_utc_timestamp(column) %}
    timestamp_tz_from_parts(year({{ column }}), month({{ column }}), day({{ column }}), 0, 0, 0, 0, 'UTC')
{% endmacro %}