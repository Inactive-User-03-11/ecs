import json
import logging
import os
import sys
import time
from contextlib import closing
from datetime import datetime, timedelta, time as dtime
from zoneinfo import ZoneInfo

import boto3
import psycopg2
import requests
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

# ---------- config ----------
REGION = os.getenv("AWS_REGION", "ap-south-1")
DB_HOST = os.getenv("DB_HOST")          # Aurora cluster endpoint
DB_NAME = os.getenv("DB_NAME", "calls")
DB_USER = os.getenv("DB_USER", "app_user")
DB_PORT = 5432
CRM_URL = os.getenv("CRM_URL")

IST = ZoneInfo("Asia/Kolkata")
RETRY_GAPS_MIN = [30, 120, 240]                         # gap before retry 1, 2, 3
WINDOW_START, WINDOW_END = dtime(8, 0), dtime(19, 0)    # calling hours IST
RETRY_DISPOSITIONS = {"NO_ANSWER", "BUSY"}

# ---------- JSON logging ----------
logging.basicConfig(stream=sys.stdout, format="%(message)s", level=logging.INFO)
logger = logging.getLogger("calls")


def log(level, event, **fields):
    logger.log(level, json.dumps({
        "ts": datetime.now(IST).isoformat(),
        "level": logging.getLevelName(level),
        "event": event,
        **fields,
    }))


# ---------- DB: new connection with a fresh IAM token each time ----------
rds = boto3.client("rds", region_name=REGION)


def get_conn():
    # IAM tokens expire after 15 min, so generate one per connection
    token = rds.generate_db_auth_token(
        DBHostname=DB_HOST, Port=DB_PORT, DBUsername=DB_USER, Region=REGION
    )
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER,
        password=token, sslmode="require", connect_timeout=5,
    )


# ---------- retry logic ----------
def schedule_retry(attempt, now=None):
    """Return next call time (IST) or None if retries are exhausted."""
    if attempt >= len(RETRY_GAPS_MIN):
        return None
    now = now or datetime.now(IST)
    t = now + timedelta(minutes=RETRY_GAPS_MIN[attempt])
    if t.time() > WINDOW_END:        # too late -> tomorrow 08:00
        t = (t + timedelta(days=1)).replace(hour=8, minute=0, second=0, microsecond=0)
    elif t.time() < WINDOW_START:    # too early -> today 08:00
        t = t.replace(hour=8, minute=0, second=0, microsecond=0)
    return t


def notify_crm(account_id, attempt, nxt):
    if not CRM_URL:
        raise RuntimeError("CRM_URL not set")
    payload = {
        "account_id": account_id,
        "next_call": nxt.isoformat(),
        "idempotency_key": f"{account_id}-{attempt}",
    }
    for i in range(3):
        try:
            r = requests.post(CRM_URL, json=payload, timeout=5)
            r.raise_for_status()
            return True
        except requests.RequestException as e:
            log(logging.WARNING, "crm_failed", account_id=account_id, try_no=i + 1, error=str(e))
            time.sleep(0.5 * 2 ** i)
    return False


# ---------- API ----------
app = FastAPI()


class CallCompleted(BaseModel):
    account_id: str
    disposition: str | None = None
    attempt: int = Field(0, ge=0)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/webhook/call-completed")
def call_completed(body: CallCompleted):  # plain def -> runs in threadpool
    with closing(get_conn()) as conn, conn, conn.cursor() as cur:  # `with conn` commits
        cur.execute(
            "INSERT INTO calls (account_id, disposition, attempt) VALUES (%s, %s, %s) "
            "ON CONFLICT (account_id, attempt) DO NOTHING",
            (body.account_id, body.disposition, body.attempt),
        )
    log(logging.INFO, "call_stored", account_id=body.account_id,
        disposition=body.disposition, attempt=body.attempt)

    if body.disposition in RETRY_DISPOSITIONS:
        nxt = schedule_retry(body.attempt)
        if nxt is None:
            log(logging.INFO, "retries_exhausted", account_id=body.account_id)
        elif not notify_crm(body.account_id, body.attempt, nxt):
            # 502 makes the voice platform redeliver; the insert above is idempotent
            raise HTTPException(status_code=502, detail="CRM unavailable")
        else:
            log(logging.INFO, "retry_scheduled", account_id=body.account_id,
                next_call=nxt.isoformat())
    return {"status": "ok"}