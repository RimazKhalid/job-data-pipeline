-- Parsed salaries: amounts positive, minimum not above maximum, and a monthly SAR value exactly
-- when the period converts (month, week, year). Every returned row breaks a rule.
select source_record_sk, salary_text, salary_min_amount, salary_max_amount, salary_period, salary_min_sar_month
from {{ ref('int_job_listings') }}
where salary_is_parsed
  and (   salary_min_amount <= 0
       or salary_min_amount > salary_max_amount
       or (salary_period in ('month', 'week', 'year')) <> (salary_min_sar_month is not null))
