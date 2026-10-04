import hashlib
import json
import logging
import os
import re
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime

import boto3


TABLE_NAME = os.environ["TABLE_NAME"]
SLACK_SECRET_ID = os.environ["SLACK_SECRET_ID"]
MODEL_ID = os.environ["MODEL_ID"]

CONTENT_SOURCES = json.loads(os.environ.get("CONTENT_SOURCES_JSON", "[]"))
INTERESTS = os.environ.get(
    "INTERESTS",
    "cloud computing, cybersecurity, software engineering, artificial intelligence, and emerging technology",
)
TOP_N = int(os.environ.get("TOP_N", "10"))
LOOKBACK_HOURS = int(os.environ.get("LOOKBACK_HOURS", "24"))
TTL_DAYS = int(os.environ.get("TTL_DAYS", "14"))
DIGEST_TITLE = os.environ.get("DIGEST_TITLE", "Tech brief")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()

PER_SOURCE_CAP = int(os.environ.get("PER_SOURCE_CAP", "15"))
MAX_CANDIDATES = int(os.environ.get("MAX_CANDIDATES", "100"))
MAX_FETCH_WORKERS = int(os.environ.get("MAX_FETCH_WORKERS", "8"))
HTTP_TIMEOUT_SECONDS = int(os.environ.get("HTTP_TIMEOUT_SECONDS", "10"))

logger = logging.getLogger()
logger.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

ddb = boto3.client("dynamodb")
bedrock = boto3.client("bedrock-runtime")
secrets = boto3.client("secretsmanager")


def http_get(url: str) -> bytes:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme.lower() != "https":
        raise ValueError("Only HTTPS content sources are supported")

    request = urllib.request.Request(
        url,
        headers={"User-Agent": "generic-tech-news-agent/1.0"},
    )
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
        return response.read()


def parse_date(value):
    if not value:
        return None

    try:
        parsed = parsedate_to_datetime(value)
    except (TypeError, ValueError):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except (TypeError, ValueError):
            return None

    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def strip_tags(value: str) -> str:
    without_tags = re.sub(r"<[^>]+>", " ", value or "")
    return re.sub(r"\s+", " ", without_tags).strip()


def child_by_local_name(element, *names):
    for name in names:
        for child in element:
            if child.tag.split("}")[-1] == name:
                return child
    return None


def canonicalize_url(url: str) -> str:
    parsed = urllib.parse.urlsplit(url.strip())
    scheme = parsed.scheme.lower()
    hostname = (parsed.hostname or "").lower()

    if parsed.port:
        netloc = f"{hostname}:{parsed.port}"
    else:
        netloc = hostname

    path = parsed.path or "/"
    if path != "/":
        path = path.rstrip("/")

    return urllib.parse.urlunsplit((scheme, netloc, path, parsed.query, ""))


def article_id(url: str) -> str:
    canonical = canonicalize_url(url)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def normalize_source(source):
    if not isinstance(source, dict):
        raise ValueError("Each content source must be an object")

    name = str(source.get("name", "")).strip()
    url = str(source.get("url", "")).strip()
    kind = str(source.get("kind", "feed")).strip() or "feed"

    if not name:
        raise ValueError("Each content source requires a name")
    if urllib.parse.urlsplit(url).scheme.lower() != "https":
        raise ValueError("Each content source requires an HTTPS URL")

    return {"name": name, "url": url, "kind": kind}


def fetch_source(source):
    source = normalize_source(source)
    root = ET.fromstring(http_get(source["url"]))
    items = []

    for element in root.iter():
        local_name = element.tag.split("}")[-1]
        if local_name not in ("item", "entry"):
            continue

        title_element = child_by_local_name(element, "title")
        link_element = child_by_local_name(element, "link")
        date_element = child_by_local_name(element, "pubDate", "published", "updated")
        summary_element = child_by_local_name(element, "description", "summary", "content")

        if title_element is None or link_element is None:
            continue

        href = link_element.attrib.get("href") or (link_element.text or "").strip()
        title = strip_tags(title_element.text or "")
        published = parse_date(date_element.text if date_element is not None else None)
        summary = strip_tags(summary_element.text if summary_element is not None else "")[:500]

        if not href or not title:
            continue

        items.append(
            {
                "source": source["name"],
                "kind": source["kind"],
                "title": title,
                "url": href,
                "published": published,
                "summary": summary,
            }
        )

    items.sort(
        key=lambda item: item["published"] or datetime.min.replace(tzinfo=timezone.utc),
        reverse=True,
    )
    return items[:PER_SOURCE_CAP]


def fetch_source_safely(source):
    try:
        return fetch_source(source)
    except Exception as exc:
        source_name = source.get("name", "configured source") if isinstance(source, dict) else "configured source"
        logger.warning("Content source failed: %s (%s)", source_name, type(exc).__name__)
        return []


def collect_candidates():
    if not CONTENT_SOURCES:
        logger.warning("No content sources are configured")
        return []

    workers = min(max(1, MAX_FETCH_WORKERS), len(CONTENT_SOURCES))
    with ThreadPoolExecutor(max_workers=workers) as executor:
        batches = list(executor.map(fetch_source_safely, CONTENT_SOURCES))

    cutoff = datetime.now(timezone.utc) - timedelta(hours=LOOKBACK_HOURS)
    candidates = []
    seen_ids = set()

    for batch in batches:
        for item in batch:
            if not item["published"] or item["published"] < cutoff:
                continue

            fingerprint = article_id(item["url"])
            if fingerprint in seen_ids:
                continue

            seen_ids.add(fingerprint)
            item["article_id"] = fingerprint
            candidates.append(item)

    candidates.sort(key=lambda item: item["published"], reverse=True)
    return candidates[:MAX_CANDIDATES]


def filter_seen(items):
    fresh = []

    for start in range(0, len(items), 100):
        chunk = items[start : start + 100]
        pending_keys = [{"article_id": {"S": item["article_id"]}} for item in chunk]
        known_ids = set()

        for attempt in range(3):
            if not pending_keys:
                break

            response = ddb.batch_get_item(
                RequestItems={
                    TABLE_NAME: {
                        "Keys": pending_keys,
                        "ProjectionExpression": "article_id",
                    }
                }
            )

            known_ids.update(
                record["article_id"]["S"]
                for record in response.get("Responses", {}).get(TABLE_NAME, [])
            )
            pending_keys = response.get("UnprocessedKeys", {}).get(TABLE_NAME, {}).get("Keys", [])

            if pending_keys:
                time.sleep(0.1 * (2**attempt))

        fresh.extend(item for item in chunk if item["article_id"] not in known_ids)

    return fresh


def mark_seen(items):
    expires_at = int(time.time()) + (TTL_DAYS * 86400)

    for start in range(0, len(items), 25):
        pending = [
            {
                "PutRequest": {
                    "Item": {
                        "article_id": {"S": item["article_id"]},
                        "expires_at": {"N": str(expires_at)},
                    }
                }
            }
            for item in items[start : start + 25]
        ]

        for attempt in range(3):
            if not pending:
                break

            response = ddb.batch_write_item(RequestItems={TABLE_NAME: pending})
            pending = response.get("UnprocessedItems", {}).get(TABLE_NAME, [])

            if pending:
                time.sleep(0.1 * (2**attempt))

        if pending:
            raise RuntimeError("DynamoDB did not process all deduplication records")


def curate(items):
    listing = "\n".join(
        f"[{index}] ({item['source']}, {item['kind']}) {item['title']} - {item['summary']}"
        for index, item in enumerate(items)
    )

    prompt = f"""You are curating a concise technology news brief.
Interests: {INTERESTS}

Candidate stories:
{listing}

Select up to {TOP_N} of the most relevant and useful stories.
Prefer direct or official reporting when the same event appears more than once.
Treat source labels as context only and do not invent facts beyond the supplied title and summary.
Group selected stories into 2-4 short themes.
Return ONLY valid JSON in this shape:
{{"themes": [{{"name": "...", "stories": [{{"id": 0, "summary": "1-2 sentences"}}]}}]}}
Use only integer ids that appear in the candidate list."""

    response = bedrock.converse(
        modelId=MODEL_ID,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": 2000, "temperature": 0.2},
    )

    text = response["output"]["message"]["content"][0]["text"].strip()
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text, flags=re.IGNORECASE).strip()
    curated = json.loads(text)

    if not isinstance(curated, dict) or not isinstance(curated.get("themes"), list):
        raise ValueError("Model response did not match the expected JSON shape")

    return curated


def format_slack(curated, items):
    date_label = datetime.now(timezone.utc).strftime("%a %b %d")
    lines = [f"*{DIGEST_TITLE} - {date_label}*"]

    for theme in curated.get("themes", []):
        if not isinstance(theme, dict):
            continue

        theme_name = str(theme.get("name", "Highlights")).strip() or "Highlights"
        stories = theme.get("stories", [])
        if not isinstance(stories, list):
            continue

        lines.append(f"\n*{theme_name}*")

        for story in stories:
            if not isinstance(story, dict):
                continue

            index = story.get("id")
            if not isinstance(index, int) or not 0 <= index < len(items):
                continue

            item = items[index]
            summary = str(story.get("summary", "")).strip()
            source_label = item["source"]
            lines.append(
                f"- <{item['url']}|{item['title']}> ({source_label})\n  {summary}"
            )

    return "\n".join(lines)


def get_webhook_url():
    raw_secret = secrets.get_secret_value(SecretId=SLACK_SECRET_ID)["SecretString"].strip()

    try:
        parsed = json.loads(raw_secret)
    except json.JSONDecodeError:
        parsed = raw_secret

    if isinstance(parsed, dict):
        webhook_url = str(parsed.get("webhook_url", "")).strip()
    elif isinstance(parsed, str):
        webhook_url = parsed.strip()
    else:
        webhook_url = ""

    if urllib.parse.urlsplit(webhook_url).scheme.lower() != "https":
        raise ValueError("The webhook secret must contain an HTTPS URL")

    return webhook_url


def post_to_slack(text):
    request = urllib.request.Request(
        get_webhook_url(),
        data=json.dumps({"text": text}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
        response.read()


def check_sources():
    results = {}

    for source in CONTENT_SOURCES:
        try:
            normalized = normalize_source(source)
            count = len(fetch_source(normalized))
            results[normalized["name"]] = {"status": "ok", "entries": count}
        except Exception as exc:
            name = source.get("name", "configured source") if isinstance(source, dict) else "configured source"
            results[name] = {"status": "failed", "error_type": type(exc).__name__}

    return results


def lambda_handler(event, context):
    if isinstance(event, dict) and event.get("check_sources"):
        return check_sources()

    candidates = collect_candidates()
    fresh = filter_seen(candidates)
    logger.info("Found %d candidate stories and %d unseen stories", len(candidates), len(fresh))

    if not fresh:
        return {"status": "no_new_items", "candidates": len(candidates)}

    curated = curate(fresh)
    post_to_slack(format_slack(curated, fresh))

    # Mark all candidates that were supplied to the model as seen after a successful post.
    # This prevents repeatedly reconsidering yesterday's unselected candidates.
    mark_seen(fresh)

    return {
        "status": "sent",
        "candidates": len(candidates),
        "unseen": len(fresh),
    }
