#!/usr/bin/env python3
"""
CLI wrapper for twitter-api-client library.

Usage:
    # Fetch tweets by user ID
    TWITTER_CT0=xxx TWITTER_AUTH_TOKEN=xxx python3 bin/twitter_fetch.py <user_id> [--limit N]

    # Look up user ID by screen name (username)
    TWITTER_CT0=xxx TWITTER_AUTH_TOKEN=xxx python3 bin/twitter_fetch.py --lookup <screen_name>

Environment variables:
    TWITTER_CT0         - ct0 cookie (required)
    TWITTER_AUTH_TOKEN  - auth_token cookie (required)

Output: JSON to stdout.
"""

import sys
import os
import json
import argparse
from datetime import datetime, timezone

# Clear proxy env vars — the twitter-api-client doesn't need them and
# httpx chokes on SOCKS proxies without the socksio package.
for var in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
    os.environ.pop(var, None)

# Add twitter-api-client to path
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
TWITTER_CLIENT_DIR = os.path.join(PROJECT_ROOT, "twitter-api-client")
sys.path.insert(0, TWITTER_CLIENT_DIR)

from twitter.scraper import Scraper
from twitter.util import find_key


def parse_tweets(data):
    """Extract normalized tweet dicts from raw GraphQL response."""
    tweets = []
    for tweet_result in find_key(data, "tweet_results"):
        # find_key returns each tweet_results dict directly (not a list)
        if isinstance(tweet_result, dict):
            tweet_obj = tweet_result.get("result", {})
        elif isinstance(tweet_result, list):
            for r in tweet_result:
                tweet_obj = r.get("result", {}) if isinstance(r, dict) else {}
                if tweet_obj.get("legacy"):
                    break
        else:
            continue
        # Some tweets are wrapped in a "tweet" key (promoted content, etc.)
        if "tweet" in tweet_obj:
            tweet_obj = tweet_obj["tweet"]

        legacy = tweet_obj.get("legacy", {})
        if not legacy or not legacy.get("id_str"):
            continue

        # Parse created_at: "Wed Apr 19 16:34:37 +0000 2023"
        created_at = legacy.get("created_at", "")
        published_at = None
        if created_at:
            try:
                published_at = datetime.strptime(
                    created_at, "%a %b %d %H:%M:%S %z %Y"
                ).isoformat()
            except ValueError:
                published_at = created_at

        # Extract user info
        user_info = (
            tweet_obj.get("core", {})
            .get("user_results", {})
            .get("result", {})
            .get("legacy", {})
        )

        # Extract media URLs
        media_urls = []
        entities = legacy.get("entities", {})
        extended = legacy.get("extended_entities", {})
        for media in extended.get("media", []) + entities.get("media", []):
            media_url = media.get("media_url_https") or media.get("media_url")
            if media_url:
                media_urls.append(media_url)

        # Extract view count
        views = tweet_obj.get("views", {})
        view_count = int(views.get("count", 0)) if views.get("state") == "EnabledWithCount" else None

        tweets.append({
            "id_str": legacy.get("id_str"),
            "user_id_str": legacy.get("user_id_str"),
            "full_text": legacy.get("full_text"),
            "created_at": published_at,
            "favorite_count": legacy.get("favorite_count", 0),
            "retweet_count": legacy.get("retweet_count", 0),
            "reply_count": legacy.get("reply_count", 0),
            "quote_count": legacy.get("quote_count", 0),
            "lang": legacy.get("lang"),
            "source": tweet_obj.get("source"),
            "view_count": view_count,
            "screen_name": user_info.get("screen_name"),
            "user_name": user_info.get("name"),
            "media_urls": media_urls,
            "hashtags": [h.get("text") for h in entities.get("hashtags", []) if h.get("text")],
            "urls": [u.get("expanded_url") for u in entities.get("urls", []) if u.get("expanded_url")],
            "raw": tweet_obj,
        })
    return tweets


def lookup_user(scraper, screen_name):
    """Look up a user by screen name and return their info."""
    data = scraper.users([screen_name])
    results = []
    for entry in data:
        # users() returns: [{"data": {"user": {"result": {...}}}}]
        user = entry.get("data", {}).get("user", {}).get("result", {})
        if not user:
            # Try alternative path for different response shapes
            for ur in find_key(entry, "user_results"):
                for r in ur:
                    user = r.get("result", {})
                    if user.get("rest_id"):
                        break
                    user = {}
        legacy = user.get("legacy", {})
        if not legacy or not user.get("rest_id"):
            continue
        results.append({
            "rest_id": user.get("rest_id"),
            "screen_name": legacy.get("screen_name"),
            "name": legacy.get("name"),
            "description": legacy.get("description"),
            "followers_count": legacy.get("followers_count"),
            "friends_count": legacy.get("friends_count"),
            "statuses_count": legacy.get("statuses_count"),
            "profile_image_url_https": legacy.get("profile_image_url_https"),
        })
    return results


def main():
    parser = argparse.ArgumentParser(description="Fetch tweets or look up users on Twitter")
    parser.add_argument("user_id", nargs="?", type=int, help="Twitter user ID (numeric)")
    parser.add_argument("--limit", type=int, default=0, help="Max tweets to fetch (0 = all available)")
    parser.add_argument("--lookup", type=str, metavar="SCREEN_NAME",
                        help="Look up user ID by screen name (username)")
    args = parser.parse_args()

    if not args.user_id and not args.lookup:
        parser.error("Either provide a user_id or use --lookup <screen_name>")

    ct0 = os.environ.get("TWITTER_CT0")
    auth_token = os.environ.get("TWITTER_AUTH_TOKEN")

    if not ct0 or not auth_token:
        print("Error: TWITTER_CT0 and TWITTER_AUTH_TOKEN environment variables are required", file=sys.stderr)
        sys.exit(1)

    cookies = {"ct0": ct0, "auth_token": auth_token}

    try:
        scraper = Scraper(cookies=cookies, save=False)

        # Redirect stdout to stderr during scraper calls to suppress library
        # debug/progress output (tqdm, error prints, etc.)
        saved_stdout = sys.stdout
        sys.stdout = sys.stderr

        if args.lookup:
            users = lookup_user(scraper, args.lookup)
            sys.stdout = saved_stdout
            json.dump(users, sys.stdout, ensure_ascii=False, default=str)
        else:
            kwargs = {}
            if args.limit > 0:
                kwargs["limit"] = args.limit
            raw_data = scraper.tweets([args.user_id], **kwargs)
            tweets = parse_tweets(raw_data)
            sys.stdout = saved_stdout
            json.dump(tweets, sys.stdout, ensure_ascii=False, default=str)
    except Exception as e:
        sys.stdout = sys.__stdout__
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
