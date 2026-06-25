#!/usr/bin/env python3
import argparse
import json
import os
import plistlib
import socket
import sys
from pathlib import Path
from urllib.parse import urlparse


PLACEHOLDERS = ("YOUR_PROJECT_ID", "YOUR_ANON_KEY_HERE")


def clean(value):
    if value is None:
        return ""
    return str(value).strip()


def valid_value(value):
    value = clean(value)
    return bool(value) and not any(marker in value for marker in PLACEHOLDERS)


def load_plist(path):
    with open(path, "rb") as handle:
        raw = plistlib.load(handle)
    return {
        "url": clean(raw.get("SUPABASE_URL")),
        "anon_key": clean(raw.get("SUPABASE_ANON_KEY")),
        "redirect_url": clean(raw.get("SUPABASE_REDIRECT_URL") or "teale://auth/callback"),
    }


def load_json(path):
    with open(path, "r", encoding="utf-8-sig") as handle:
        raw = json.load(handle)
    return {
        "url": clean(raw.get("supabase_url")),
        "anon_key": clean(raw.get("supabase_anon_key")),
        "redirect_url": clean(raw.get("supabase_redirect_url") or "teale://auth/callback"),
    }


def apply_env(config):
    url = clean(os.environ.get("TEALE_SUPABASE_URL"))
    anon_key = clean(os.environ.get("TEALE_SUPABASE_ANON_KEY"))
    redirect_url = clean(os.environ.get("TEALE_SUPABASE_REDIRECT_URL"))
    if url:
        config["url"] = url
    if anon_key:
        config["anon_key"] = anon_key
    if redirect_url:
        config["redirect_url"] = redirect_url
    return config


def write_plist(path, config):
    payload = {
        "SUPABASE_URL": config["url"],
        "SUPABASE_ANON_KEY": config["anon_key"],
        "SUPABASE_REDIRECT_URL": config["redirect_url"],
    }
    with open(path, "wb") as handle:
        plistlib.dump(payload, handle, sort_keys=False)


def write_json(path, config):
    payload = {
        "supabase_url": config["url"],
        "supabase_anon_key": config["anon_key"],
        "supabase_redirect_url": config["redirect_url"],
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, separators=(",", ":"))
        handle.write("\n")


def validate(config):
    if not valid_value(config["url"]):
        raise SystemExit("Supabase URL is missing or still templated")
    if not valid_value(config["anon_key"]):
        raise SystemExit("Supabase anon key is missing or still templated")

    parsed = urlparse(config["url"])
    if parsed.scheme != "https" or not parsed.netloc:
        raise SystemExit("Supabase URL must be an https URL")

    try:
        socket.getaddrinfo(parsed.hostname, 443)
    except OSError as error:
        raise SystemExit(f"Supabase host does not resolve: {parsed.hostname} ({error})")

    if not valid_value(config["redirect_url"]):
        raise SystemExit("Supabase redirect URL is missing or still templated")

    print(f"Supabase auth config OK: {parsed.hostname}")


def main():
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--plist")
    source.add_argument("--json")
    parser.add_argument("--apply-env", action="store_true")
    parser.add_argument("--write-plist")
    parser.add_argument("--write-json")
    args = parser.parse_args()

    config = load_plist(args.plist) if args.plist else load_json(args.json)
    if args.apply_env:
        config = apply_env(config)

    validate(config)

    if args.write_plist:
        write_plist(Path(args.write_plist), config)
    if args.write_json:
        write_json(Path(args.write_json), config)


if __name__ == "__main__":
    main()
