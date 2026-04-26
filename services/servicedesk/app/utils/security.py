from __future__ import annotations

import hmac
import ipaddress
import re
import socket
import unicodedata
from urllib.parse import urljoin, urlparse



class WebhookConfigError(ValueError):
    pass


def _host_is_private(hostname: str) -> bool:
    lowered = hostname.strip().lower().rstrip(".")
    if lowered in {"localhost", "0", "0.0.0.0"} or lowered.endswith(".localhost"):
        return True
    try:
        ip = ipaddress.ip_address(lowered)
    except ValueError:
        try:
            infos = socket.getaddrinfo(lowered, None, proto=socket.IPPROTO_TCP)
        except socket.gaierror:
            return False
        for info in infos:
            address = info[4][0]
            try:
                ip = ipaddress.ip_address(address)
            except ValueError:
                continue
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved:
                return True
        return False
    return ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved

def validate_webhook_base(raw: str) -> str:
    if not raw or not isinstance(raw, str):
        raise WebhookConfigError("Base URL is required")
    stripped = raw.strip()
    if len(stripped) > 512:
        raise WebhookConfigError("Base URL too long")

    parsed = urlparse(stripped)
    if parsed.scheme not in ("http", "https"):
        if "://" not in stripped:
            raise WebhookConfigError("Base URL must start with http:// or https://")
        raise WebhookConfigError("Unsupported scheme for base URL")
    if not parsed.hostname:
        raise WebhookConfigError("Base URL must include a host")
    if _host_is_private(parsed.hostname):
        raise WebhookConfigError("Private or local webhook hosts are not allowed")
    if parsed.username or parsed.password:
        raise WebhookConfigError("Credentials are not allowed in base URL")

    return stripped


def validate_endpoint_path(raw: str) -> str:
    if raw is None:
        return ""
    if not isinstance(raw, str):
        raise WebhookConfigError("Endpoint path must be a string")
    path = raw.strip()
    if len(path) > 1024:
        raise WebhookConfigError("Endpoint path too long")
    lowered = path.lower()
    if lowered.startswith("http://") or lowered.startswith("https://"):
        raise WebhookConfigError("Endpoint path must be relative")
    if lowered.startswith("//") or "\\" in path:
        raise WebhookConfigError("Endpoint path must stay on the configured host")
    return path


def resolve_webhook_target(base: str, path: str) -> str:
    target = urljoin(base, path)
    parsed_base = urlparse(base)
    parsed_target = urlparse(target)
    if parsed_base.hostname != parsed_target.hostname or parsed_base.scheme != parsed_target.scheme:
        raise WebhookConfigError("Endpoint path must stay on the configured host")
    return target


def normalise_filename_fragment(fragment: str) -> str:
    if fragment is None:
        return "attachment.bin"
    normalised = unicodedata.normalize("NFC", fragment)
    safe = re.compile(r"[^A-Za-z0-9._-]+").sub("_", normalised).strip("._")
    return safe or "attachment.bin"


def constant_time_equal(a: str, b: str) -> bool:
    if a is None or b is None:
        return False
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))
