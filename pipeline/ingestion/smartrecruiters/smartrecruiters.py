"""
SmartRecruiters Posting API — raw data collection script
========================================================

SmartRecruiters gives every company that uses it a PUBLIC postings API, no API key needed:

    GET https://api.smartrecruiters.com/v1/companies/<company>/postings?country=sa
    GET https://api.smartrecruiters.com/v1/companies/<company>/postings/<id>   (detail)

This script:
  1. Pages through each company's Saudi postings (country=sa is filtered by the API)
  2. Fetches each posting's detail and adds its "jobAd" (the description sections)
  3. Writes ONE JSON file per company into the shared raw landing zone:

    <raw>/smartrecruiters/ingest_date=<YYYY-MM-DD>/<company>_jobs.json

<raw> is the folder set in pipeline/common/config.py (raw/ next to the repo), the same
landing zone every other source uses. A file is written even when a company has no Saudi
postings. A company whose listing request fails is skipped and gets no file, so dbt treats
it as "not pulled" rather than "all postings closed".

Run from the repo root:  python pipeline/ingestion/smartrecruiters/smartrecruiters.py
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # pipeline/
from common import config

COMPANIES = (
    "JobsForHumanity",
    "QualityEducationCompany",
    "AccorHotel",
    "Workhint",
    "Boskalis",
    "FacilInternationalCompanyForHotelsFood",
    "ASSYSTEM",
    "EthosInteractive",
    "EICO",
    "SwissHospitality",
    "CREALOGIX",
    "RolandBerger",
    "BoschGroup",
    "bTRanz",
)

BASE_URL = "https://api.smartrecruiters.com/v1/companies"
BASE_DIR = config.raw_dir_for("smartrecruiters")   # <raw>/smartrecruiters/


def fetch_job_detail(company: str, job_id: str) -> dict:
    """Fetches full posting detail (includes the description) for one job."""
    response = requests.get(f"{BASE_URL}/{company}/postings/{job_id}", timeout=60)
    response.raise_for_status()
    return response.json()


def fetch_company_postings(company: str) -> list:
    """All Saudi postings of one company, following offset pagination."""
    offset = 0
    postings = []
    while True:
        response = requests.get(
            f"{BASE_URL}/{company}/postings",
            params={"offset": offset, "country": "sa"},
            timeout=60,
        )
        response.raise_for_status()
        jobs = response.json().get("content", [])
        print(f"  {len(jobs)} jobs | offset {offset}")
        if len(jobs) == 0:
            break
        postings.extend(jobs)
        offset += len(jobs)
        time.sleep(0.5)
    return postings


def main():
    ingest_date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    out_dir = os.path.join(BASE_DIR, f"ingest_date={ingest_date}")
    os.makedirs(out_dir, exist_ok=True)
    total_saved = 0

    for company in COMPANIES:
        print(f"Fetching {company}...")
        try:
            saudi_jobs = fetch_company_postings(company)
        except requests.exceptions.RequestException as e:
            print(f"  [skip] {company}: listing failed ({type(e).__name__}), no file written")
            continue

        print(f"  Fetching descriptions for {len(saudi_jobs)} jobs...")
        for job in saudi_jobs:
            try:
                detail = fetch_job_detail(company, job["id"])
                job["jobAd"] = detail.get("jobAd")
            except requests.exceptions.RequestException as e:
                print(f"    [skip] job {job['id']} - {type(e).__name__}")
                job["jobAd"] = None
            time.sleep(0.3)

        file_path = os.path.join(out_dir, f"{company}_jobs.json")
        with open(file_path, "w", encoding="utf-8") as f:
            json.dump(saudi_jobs, f, ensure_ascii=False, indent=2)

        print(f"  Saved: {file_path} ({len(saudi_jobs)} Saudi jobs)")
        total_saved += len(saudi_jobs)

    print(f"\nDone. {total_saved} Saudi postings saved across {len(COMPANIES)} companies "
          f"({datetime.now(timezone.utc).isoformat()}).")


if __name__ == "__main__":
    main()