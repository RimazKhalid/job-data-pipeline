"""
Greenhouse Job Board API — raw data collection script (Saudi-filtered)
======================================================================

Greenhouse gives every company that uses it a PUBLIC job-board API, no API key needed:

    GET https://boards-api.greenhouse.io/v1/boards/<board_token>/jobs?content=true

This script:
  1. Calls that endpoint for every board in BOARDS
  2. Keeps only postings whose location matches SAUDI_KEYWORDS
  3. Saves the response otherwise untouched (same top-level shape, every job key kept)
  4. Writes ONE JSON file per board into the shared raw landing zone:

         <raw>/greenhouse/ingest_date=<YYYY-MM-DD>/<board_token>_jobs.json

     <raw> is the folder set in pipeline/common/config.py (raw/ next to the repo),
     the same landing zone every other source uses.

A file is written even when a board has no Saudi postings, so dbt can tell
"this board was pulled and has nothing open" from "this board was not pulled".

Run from the repo root:  python pipeline/ingestion/greenhouse/greenhouse.py
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

# ---------------------------------------------------------------------
# 1. CONFIG — every Greenhouse board token to pull. Adding a board here is
#    the only change needed; no other edit between runs.
# ---------------------------------------------------------------------
BOARDS = [
"artefact",
"brkz",
"careem",
"cssmerge",
"decimainternational",
"dmgevents",
"hala",
"jensenhughes",
"kitchenpark",
"lucidmotors",
"menaconsultant",
"minio",
"namaa",
"ogilvymena",
"pronto",
"recruitis",
"tamara",
    
]

BASE_DIR = config.raw_dir_for("greenhouse")   # <raw>/greenhouse/

SAUDI_KEYWORDS = [
    "saudi arabia", "saudi", "ksa", "riyadh", "jeddah", "dammam", "khobar", "al khobar",
    "dhahran", "jubail", "mecca", "makkah", "medina", "madinah", "jazan", "jizan", "tabuk",
    "abha", "taif", "yanbu", "al ahsa", "hofuf", "neom", "king abdullah economic city",
    "eastern province", "western province",
]

MAX_RETRIES = 3
RETRY_BACKOFF_SECONDS = 10
SLEEP_BETWEEN_BOARDS = 1


# ---------------------------------------------------------------------
# 2. FETCH — one board, retried on timeouts, connection errors and 5xx
# ---------------------------------------------------------------------
def fetch_board(board_token: str):
    url = f"https://boards-api.greenhouse.io/v1/boards/{board_token}/jobs?content=true"
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            response = requests.get(url, timeout=60)
            if response.status_code >= 500:
                raise requests.exceptions.HTTPError(f"HTTP {response.status_code}")
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            print(f"  attempt {attempt}/{MAX_RETRIES} failed: {e}")
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_BACKOFF_SECONDS)
    print(f"  [skip] {board_token}: no response after {MAX_RETRIES} attempts")
    return None


def is_saudi_location(job: dict) -> bool:
    location = (job.get("location") or {}).get("name", "").lower()
    return any(keyword in location for keyword in SAUDI_KEYWORDS)


# ---------------------------------------------------------------------
# 3. SAVE — Saudi-filtered response, otherwise untouched
# ---------------------------------------------------------------------
def save_snapshot(board_token: str, data: dict, ingest_date: str) -> None:
    out_dir = os.path.join(BASE_DIR, f"ingest_date={ingest_date}")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{board_token}_jobs.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=4)
    print(f"  [saved] {path}")


# ---------------------------------------------------------------------
# 4. MAIN
# ---------------------------------------------------------------------
def main():
    ingest_date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    total_saved = 0

    for board_token in BOARDS:
        print(f"Fetching: {board_token}")
        data = fetch_board(board_token)
        if data is None:
            continue

        jobs = data.get("jobs", [])
        saudi_jobs = [j for j in jobs if is_saudi_location(j)]
        print(f"  {len(jobs)} open jobs, {len(saudi_jobs)} Saudi-based")

        data["jobs"] = saudi_jobs
        save_snapshot(board_token, data, ingest_date)
        total_saved += len(saudi_jobs)
        time.sleep(SLEEP_BETWEEN_BOARDS)

    print(f"\nDone. {total_saved} Saudi postings saved across {len(BOARDS)} boards "
          f"({datetime.now(timezone.utc).isoformat()}).")


if __name__ == "__main__":
    main()