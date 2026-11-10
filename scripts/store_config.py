#!/usr/bin/env python3
"""This store's settings: its name and publisher, the Stackbar it builds
against, the plugin ids it accepts, the plugins it leaves out and where its
prebuilt helpers are downloaded from.

store.json holds navbytes' values. An organization's private copy adds
store.override.json with only the keys it changes and edits nothing else, so
merging upstream never conflicts (stackbar's docs/self-hosting.md).

    scripts/store_config.py get <key>       a value; a list prints one per line, null prints nothing
    scripts/store_config.py excluded <dir>  exit 0 when <Category>/<Name> is left out of the store
    scripts/store_config.py show
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = ROOT / "store.json"
OVERRIDE = ROOT / "store.override.json"

# key: (type, required)
SCHEMA = {
    "name": ("str", True),
    "publisher": ("str", True),
    "homepage": ("url", True),
    "website": ("url", False),
    "stackbar": ("url", True),
    "idPrefixes": ("prefixes", True),
    "exclude": ("paths", True),
    "helpersURL": ("str", False),
}


def fail(message):
    sys.exit(f"store config: {message}")


def check(value):
    for key in value:
        if key not in SCHEMA:
            fail(f"unknown key {key}")
    for key, (kind, required) in SCHEMA.items():
        item = value.get(key)
        if item is None:
            if required:
                fail(f"{key} is required")
            continue
        if kind in ("prefixes", "paths"):
            if not isinstance(item, list) or not all(isinstance(entry, str) and entry for entry in item):
                fail(f"{key} must be a list of strings")
            if kind == "prefixes" and not all(re.fullmatch(r"[a-z0-9-]+(\.[a-z0-9-]+)+\.", entry) for entry in item):
                fail(f"{key}: each prefix is a reverse-DNS id ending in a dot, like com.example.stackbar.")
            if kind == "paths" and not all(re.fullmatch(r"[A-Za-z0-9]+(/[A-Za-z0-9-]+)+", entry) for entry in item):
                fail(f"{key}: each entry is a plugin folder like Productivity/AskAI")
        elif not isinstance(item, str) or not item.strip():
            fail(f"{key} must be a non-empty string")
        elif kind == "url" and not re.match(r"^https://[^\s/]+", item):
            fail(f"{key} must be an https URL: {item}")


def load(include_override=True):
    value = json.loads(BASE.read_text())
    if include_override and OVERRIDE.exists():
        try:
            override = json.loads(OVERRIDE.read_text())
        except json.JSONDecodeError as error:
            fail(f"{OVERRIDE.name}: {error}")
        if not isinstance(override, dict):
            fail(f"{OVERRIDE.name} must be an object")
        value.update(override)
    check(value)
    return value


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    value = load()
    command, rest = argv[1], argv[2:]
    if command == "get" and len(rest) == 1 and rest[0] in SCHEMA:
        item = value.get(rest[0])
        if isinstance(item, list):
            for entry in item:
                print(entry)
        elif item is not None:
            print(item)
    elif command == "excluded" and len(rest) == 1:
        sys.exit(0 if rest[0].strip("/") in value["exclude"] else 1)
    elif command == "show":
        print(json.dumps(value, indent=2))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
