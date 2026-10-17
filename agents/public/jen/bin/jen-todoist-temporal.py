"""Explicit civil-date resolver. No host timezone or provider-relative dates.
CLI: phrase now_utc timezone. Exit 2 requests clarification without dispatch.
"""
import datetime as dt
import json
import re
import sys
import unicodedata
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


def _is_date_only_recurrence(raw: str) -> bool:
    # Closed grammar on raw text: never erase time/zone-bearing punctuation.
    text = ''.join(ch for ch in unicodedata.normalize('NFKD', raw.casefold()) if not unicodedata.combining(ch))
    text = re.sub(r'\s+', ' ', text).strip()
    return re.fullmatch(r'(?:every (?:(?:[1-9]\d* )?(?:days?|weeks?|months?|years?)|monday|tuesday|wednesday|thursday|friday|saturday|sunday)|cada (?:[1-9]\d* )?(?:dias?|semanas?|mes|meses|anos?)|todo dia)', text) is not None


def resolve(phrase, now_utc, timezone):
    if re.fullmatch(r'\d{4}-\d{2}-\d{2}', phrase):
        return dt.date.fromisoformat(phrase).isoformat()
    # Recurrence is kept literal. Timed recurrence requires an explicit zone.
    canonical = ''.join(ch for ch in unicodedata.normalize('NFKD',phrase.casefold()) if not unicodedata.combining(ch))
    canonical = canonical.replace('-feira','').replace(' feira','').strip()
    if not timezone:
        raise ValueError('timezone_required')
    zone = ZoneInfo(timezone)
    now = dt.datetime.fromisoformat(now_utc.replace('Z','+00:00'))
    if now.tzinfo is None or now.utcoffset()!=dt.timedelta(0):
        raise ValueError('aware_utc_required')
    today = now.astimezone(zone).date()
    offsets={'hoje':0,'today':0,'amanha':1,'tomorrow':1,'depois de amanha':2,'day after tomorrow':2}
    if canonical in offsets:
        return (today+dt.timedelta(days=offsets[canonical])).isoformat()
    weekdays={'monday':0,'segunda':0,'tuesday':1,'terca':1,'wednesday':2,'quarta':2,'thursday':3,'quinta':3,'friday':4,'sexta':4,'saturday':5,'sabado':5,'sunday':6,'domingo':6}
    if canonical in weekdays:
        delta=(weekdays[canonical]-today.weekday())%7
        if not delta: raise ValueError('weekday_ambiguous')
        return (today+dt.timedelta(days=delta)).isoformat()
    if any(canonical.startswith(prefix) for prefix in ('next ','proxima ','proximo ')):
        raise ValueError('weekday_ambiguous')
    if _is_date_only_recurrence(phrase):
        return phrase
    raise ValueError('due_requires_clarification')


if __name__=='__main__':
    try:
        value=resolve(*sys.argv[1:])
    except (ValueError,ZoneInfoNotFoundError,TypeError):
        print(json.dumps(dict(ambiguous=True,recognized=False,normalized_due=None,target_date=None)))
        raise SystemExit(2)
    print(json.dumps(dict(ambiguous=False,recognized=True,normalized_due=value,target_date=value if re.fullmatch(r'\d{4}-\d{2}-\d{2}',value) else None)))
