-- dbt/models/intermediate/int_job_listings.sql
--
-- Grain: one row per listing (one posting on one source; for Workable, one posting in one city).
-- Same grain as the six staging models combined. Input to int_jobs_matched.
--
-- Steps (data_model.md, Sections 8.2 and 10):
--   1. unioned       the six staging models on one shared column list. Each source's own
--                    columns are mapped by hand (Greenhouse brand, Workable telecommuting and
--                    experience, SmartRecruiters experience_level, JSearch publisher and
--                    is_remote, Jooble underlying_source and salary).
--   2. standardized  source metadata from seed_sources, publisher, company through
--                    seed_company_aliases, experience through seed_experience_levels,
--                    remote_status, plain-text description, matching keys.
--   3. city_hits     seed_city_mapping lookup: city field first, then location text.
--   4. category_hits seed_job_categories lookup with a deterministic tie-break.
--   5. final select  company_norm, location_level, job_category, is_active.
--
-- is_active: known for ATS listings only (a board file lists every open job, so a posting missing
-- from the latest pull of its own board was taken down). Aggregator listings get null (unknown):
-- a query returns a ranked slice of the market, not a full list, so a listing that a later run did
-- not return may still be open. The earlier 7-day rule marked 9,851 of 11,032 aggregator listings
-- inactive after the 26 Sep re-run repeated only the general query (data_model.md, Section 7.2).

with unioned as (

    select source_record_sk, source_name, source_job_id,
           company_raw, title_raw, location_raw, city_raw, region_raw, country_raw,
           workplace_type_raw, employment_type,
           is_remote                          as is_remote,
           null::string                       as experience_raw,
           null::string                       as industry_raw,
           {{ board_from_path('file_name') }} as publisher_raw,
           null::string                       as salary_raw,
           description_plain, job_url, apply_url,
           posting_date_raw::timestamp_tz     as posting_date_raw,
           first_seen_at::timestamp_tz        as first_seen_at,
           last_seen_at::timestamp_tz         as last_seen_at,
           copies_landed,
           is_active
    from {{ ref('stg_ashby_jobs') }}

    union all
    select source_record_sk, source_name, source_job_id,
           company_raw, title_raw, location_raw, city_raw, region_raw, country_raw,
           workplace_type_raw, employment_type,
           telecommuting,                     -- Workable's remote flag
           experience,
           industry,
           {{ board_from_path('file_name') }},
           null::string,
           description_plain, job_url, apply_url,
           posting_date_raw::timestamp_tz,
           first_seen_at::timestamp_tz,
           last_seen_at::timestamp_tz,
           copies_landed,
           is_active
    from {{ ref('stg_workable_jobs') }}

    union all
    select source_record_sk, source_name, source_job_id,
           coalesce(brand_raw, company_raw),  -- umbrella boards list the jobs of their brands
           title_raw, location_raw, city_raw, region_raw, country_raw,
           workplace_type_raw, employment_type,
           null::boolean,
           null::string,
           null::string,
           {{ board_from_path('file_name') }},
           null::string,
           description_plain, job_url, apply_url,
           posting_date_raw::timestamp_tz,
           first_seen_at::timestamp_tz,
           last_seen_at::timestamp_tz,
           copies_landed,
           is_active
    from {{ ref('stg_greenhouse_jobs') }}

    union all
    select source_record_sk, source_name, source_job_id,
           company_raw, title_raw, location_raw, city_raw, region_raw, country_raw,
           workplace_type_raw, employment_type,
           null::boolean,                     -- remote and hybrid are already in workplace_type_raw
           experience_level,
           industry_label,
           {{ board_from_path('file_name') }},
           null::string,
           description_plain, job_url, apply_url,
           posting_date_raw::timestamp_tz,
           first_seen_at::timestamp_tz,
           last_seen_at::timestamp_tz,
           copies_landed,
           is_active
    from {{ ref('stg_smartrecruiters_jobs') }}

    union all
    select source_record_sk, source_name, source_job_id,
           company_raw, title_raw, location_raw, city_raw, region_raw, country_raw,
           workplace_type_raw, employment_type,
           is_remote,
           null::string,
           null::string,
           job_publisher,
           salary_raw,
           description_plain, job_url, apply_url,
           posting_date_raw::timestamp_tz,
           first_seen_at::timestamp_tz,
           last_seen_at::timestamp_tz,
           copies_landed,
           null::boolean                      -- aggregator status is derived in the final select
    from {{ ref('stg_jsearch_jobs') }}

    union all
    select source_record_sk, source_name, source_job_id,
           company_raw, title_raw, location_raw, city_raw, region_raw, country_raw,
           workplace_type_raw, employment_type,
           null::boolean,
           null::string,
           null::string,
           underlying_source,
           salary_raw,
           description_plain, job_url, apply_url,
           posting_date_raw::timestamp_tz,
           first_seen_at::timestamp_tz,
           last_seen_at::timestamp_tz,
           copies_landed,
           null::boolean
    from {{ ref('stg_jooble_jobs') }}
),

standardized as (
    select
        u.source_record_sk,
        u.source_name,
        src.source_type,
        src.source_priority,
        u.source_job_id,

        -- One posting across its cities: Workable repeats the shortcode for every city, so the
        -- city is left out. For every other source this equals source_record_sk.
        {{ dbt_utils.generate_surrogate_key(['u.source_name', 'u.source_job_id']) }}   as posting_sk,

        -- Publisher (Section 8.1). ATS: the employer's own board. Aggregators: the site the
        -- listing came through, normalized so "Jobrapido" and "Jobrapido.com" are one publisher.
        case
            when src.source_type = 'ATS'
                then u.source_name || ':' || coalesce(u.publisher_raw, 'unknown')
            else coalesce(
                nullif(regexp_replace(
                    regexp_replace(lower(trim(u.publisher_raw)), '^www\\.|\\.(com|net|org|io|co|sa)$', ''),
                    '[[:space:][:punct:]]', ''), ''),
                u.source_name || ':unknown')
        end                                                                          as publisher,

        -- company: placeholders (Private Company, Confidential) and missing names become Unknown
        case
            when co.company_std = 'Unknown' or {{ normalize_company('u.company_raw') }} is null then 'Unknown'
            else coalesce(co.company_std, trim(u.company_raw))
        end                                                                          as company_name,
        coalesce(co.is_recruitment_agency, false)                                    as is_recruitment_agency,
        co.alias is not null                                                         as company_in_seed,
        u.company_raw,

        trim(u.title_raw)                                                            as job_title,
        {{ normalize_title('u.title_raw') }}                                         as title_norm,

        u.location_raw,
        u.city_raw,
        u.region_raw,
        u.country_raw,
        {{ normalize_text('u.city_raw') }}                                           as city_norm,
        {{ normalize_text("array_to_string(array_construct_compact(u.location_raw, u.region_raw), ' , ')") }}
                                                                                     as location_norm,

        coalesce(u.employment_type, 'Unknown')                                       as employment_type,
        coalesce(u.workplace_type_raw, 'Unknown')                                    as workplace_type,
        -- Section 10: workplace_type first, so Ashby's Hybrid jobs (sent with isRemote = true)
        -- are Not remote, as on SmartRecruiters; the true / false flags only when it is unknown
        case
            when u.workplace_type_raw = 'Remote'              then 'Remote'
            when u.workplace_type_raw in ('Hybrid', 'OnSite') then 'Not remote'
            when u.is_remote = true                           then 'Remote'
            when u.is_remote = false                          then 'Not remote'
            else 'Unknown'
        end                                                                          as remote_status,

        -- unmapped values pass through unchanged, so the accepted_values test catches them
        case
            when nullif(trim(u.experience_raw), '') is null then 'Unknown'
            else coalesce(ex.experience_level, trim(u.experience_raw))
        end                                                                          as experience_level,
        nullif(trim(u.industry_raw), '')                                             as industry,

        {{ strip_html('u.description_plain') }}                                      as description_text,
        u.job_url,
        u.apply_url,
        nullif(trim(u.salary_raw), '')                                               as salary_text,

        u.posting_date_raw::date                                                     as posting_date,
        u.first_seen_at,
        u.last_seen_at,
        u.copies_landed,
        u.is_active                                                                  as is_active_staging

    from unioned u
    left join {{ ref('seed_sources') }} src
        on u.source_name = src.source_name
    left join {{ ref('seed_company_aliases') }} co
        on {{ normalize_company('u.company_raw') }} = co.alias
    left join {{ ref('seed_experience_levels') }} ex
        on lower(trim(u.experience_raw)) = ex.raw_value
),

city_hits as (
    -- A listing can mention several places ("Jeddah, Makkah Province"). The city field wins;
    -- otherwise the earliest mention in the location text; ties go to the longer alias, so
    -- "makkah province" (a region) beats "makkah" (a city) at the same position.
    -- Aliases are matched as whole words by padding both sides with spaces.
    select
        s.source_record_sk,
        m.city_std,
        m.region_std
    from standardized s
    join {{ ref('seed_city_mapping') }} m
        on ' ' || s.city_norm || ' '     like '% ' || m.alias || ' %'
        or ' ' || s.location_norm || ' ' like '% ' || m.alias || ' %'
    qualify row_number() over (
        partition by s.source_record_sk
        order by
            case when ' ' || s.city_norm || ' ' like '% ' || m.alias || ' %' then 1 else 2 end,
            position(' ' || m.alias || ' ' in ' ' || coalesce(s.location_norm, '') || ' '),
            length(m.alias) desc,
            m.alias
    ) = 1
),

category_hits as (
    -- lowest priority wins; ties go to the longer keyword, then to the category name,
    -- so a title always gets the same category (e.g. "Planning Engineer")
    select
        s.source_record_sk,
        c.job_category
    from standardized s
    join {{ ref('seed_job_categories') }} c
        on ' ' || s.title_norm || ' ' like '% ' || c.keyword || ' %'
    qualify row_number() over (
        partition by s.source_record_sk
        order by c.priority, length(c.keyword) desc, c.job_category
    ) = 1
)

select
    s.* exclude (city_norm, location_norm, is_active_staging),

    -- Matching key for the company: the standard name, normalized, so every alias of a company
    -- gives the same key. Null for Unknown, so such listings are never matched.
    case
        when s.company_name = 'Unknown' then null
        else {{ normalize_company('s.company_name') }}
    end                                                                              as company_norm,

    ch.city_std,
    ch.region_std,
    case
        when ch.city_std is not null   then 'city'
        when ch.region_std is not null then 'region'
        else 'country'
    end                                                                              as location_level,
    'SA'                                                                             as country_std,

    case
        when s.title_norm is null then 'Unknown'
        else coalesce(cat.job_category, 'Other')
    end                                                                              as job_category,

    -- ATS: from staging (absent from the latest pull of its own board = taken down).
    -- Aggregators: null = unknown; staging passes null::boolean for Jooble and JSearch.
    s.is_active_staging                                                              as is_active

from standardized s
left join city_hits ch
    on s.source_record_sk = ch.source_record_sk
left join category_hits cat
    on s.source_record_sk = cat.source_record_sk