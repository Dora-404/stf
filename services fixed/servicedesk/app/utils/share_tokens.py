from __future__ import annotations

import base64
import hashlib
import hmac
import secrets

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from config import settings
from models import ShareToken


class ShareLinkSigner:
    def __init__(self, brand: str, revision: str) -> None:
        self._brand = brand
        self._revision = revision

    def _key(self) -> bytes:
        return hashlib.sha256(f"{self._brand}|{self._revision}".encode("utf-8")).digest()[:32]

    def _material(self, case_number: str, audience: str) -> bytes:
        parts = [self._brand, case_number, audience, self._revision]
        return "\x1f".join(parts).encode("utf-8")

    def sign(self, case_number: str, audience: str) -> str:
        mac = hmac.new(self._key(), self._material(case_number, audience), hashlib.sha256).digest()
        encoded = base64.urlsafe_b64encode(mac).decode("ascii").rstrip("=")
        return encoded[:20]


def _signer() -> ShareLinkSigner:
    return ShareLinkSigner(
        brand=settings.share_link_brand,
        revision=settings.share_link_revision,
    )


def build_share_token(case_number: str, audience: str = "external-review") -> str:
    return secrets.token_urlsafe(24)


async def ensure_share_token(
    db: AsyncSession,
    ticket_id: str,
    created_by: str,
    case_number: str,
    audience: str = "external-review",
) -> ShareToken:
    result = await db.execute(
        select(ShareToken).where(
            (ShareToken.ticket_id == ticket_id) & (ShareToken.is_active.is_(True))
        )
    )
    share = result.scalar_one_or_none()
    if share and len(share.token) >= 30:
        return share

    token = build_share_token(case_number, audience)
    share = ShareToken(
        ticket_id=ticket_id,
        created_by=created_by,
        token=token,
    )
    db.add(share)
    await db.commit()
    await db.refresh(share)
    return share
