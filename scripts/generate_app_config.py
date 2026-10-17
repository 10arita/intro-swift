#!/usr/bin/env python3
"""Copy only public app configuration from .env into the iOS app bundle."""

import plistlib
import sys
from pathlib import Path
from urllib.parse import urlsplit


ALLOWED_KEYS = {
    "APP_SERVER_URL", "APP_CLOUDKIT_ENABLED", "APP_OPERATOR_NAME", "APP_SUPPORT_EMAIL",
    "APP_PRIVACY_POLICY_URL", "APP_TERMS_URL", "APP_SUPPORT_URL", "APP_SUPPORT_FORM_URL",
    "APP_MONETIZATION_ENABLED", "APP_AD_REMOVAL_PRODUCT_ID",
}


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values

    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, separator, value = line.partition("=")
        key = key.strip()
        if key not in ALLOWED_KEYS:
            continue
        if not separator:
            raise ValueError(f"{path}:{number}: {key} needs an equals sign")
        value = value.strip()
        if value.startswith(("'", '"')):
            quote = value[0]
            if len(value) < 2 or not value.endswith(quote):
                raise ValueError(f"{path}:{number}: {key} has an unclosed quote")
            value = value[1:-1]
        else:
            value = value.split(" #", 1)[0].strip()
        values[key] = value
    return values


def main() -> None:
    source, destination = map(Path, sys.argv[1:3])
    values = read_env(source)
    server_url = values.get("APP_SERVER_URL", "").rstrip("/")
    if server_url:
        url = urlsplit(server_url)
        if (url.scheme != "https" or not url.hostname or url.path or url.username
                or url.password or url.query or url.fragment):
            raise ValueError("APP_SERVER_URL must be an HTTPS origin without credentials, query, or fragment")
    config = {
        "APP_SERVER_URL": server_url,
        "APP_CLOUDKIT_ENABLED": values.get("APP_CLOUDKIT_ENABLED", "false").lower(),
        "APP_MONETIZATION_ENABLED": values.get("APP_MONETIZATION_ENABLED", "false").lower(),
    }
    for key in ("APP_CLOUDKIT_ENABLED", "APP_MONETIZATION_ENABLED"):
        if config[key] not in {"true", "false"}:
            raise ValueError(f"{key} must be true or false")
    for key in sorted(ALLOWED_KEYS - config.keys()):
        config[key] = values.get(key, "")
    for key in ("APP_PRIVACY_POLICY_URL", "APP_TERMS_URL", "APP_SUPPORT_URL", "APP_SUPPORT_FORM_URL"):
        if config[key]:
            url = urlsplit(config[key])
            if url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment:
                raise ValueError(f"{key} must be an HTTPS URL without credentials or fragment")
    email = config["APP_SUPPORT_EMAIL"]
    if email and (email.count("@") != 1 or any(character.isspace() for character in email)
                  or any(character in email for character in "?&#%/\\:")):
        raise ValueError("APP_SUPPORT_EMAIL must be an email address without URL parameters")
    if config["APP_MONETIZATION_ENABLED"] == "true" and not config["APP_AD_REMOVAL_PRODUCT_ID"]:
        raise ValueError("APP_AD_REMOVAL_PRODUCT_ID is required when monetization is enabled")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as output:
        plistlib.dump(config, output)


if __name__ == "__main__":
    main()
