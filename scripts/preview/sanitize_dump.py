"""Streaming PostgreSQL dump sanitizer.

Reads a plain-format pg_dump from stdin, rewrites PII columns in target tables,
and writes the sanitized dump to stdout. Operates COPY-block by COPY-block;
passes non-target tables and all DDL/comments through unchanged.

Contract: docs/preview/sanitize-contract.md
"""

from __future__ import annotations

import re
import sys
from typing import IO, Callable

COPY_START_RE = re.compile(
    r"^COPY public\.(?P<table>\w+) \((?P<cols>[^)]+)\) FROM stdin;\s*$"
)

Rewriter = Callable[[list[str], dict[str, int]], list[str]]

PREVIEW_BCRYPT = "$2b$12$aqLqsRzRYZlLYxlEFO6cJOEW9s84eiA/4IRSuQkw0ufC//2p.cTmi"


def _rewrite_res_partner(row: list[str], col_idx: dict[str, int]) -> list[str]:
    partner_id = row[col_idx["id"]]
    out = list(row)
    if "email" in col_idx:
        out[col_idx["email"]] = f"pii-{partner_id}@preview.local"
    if "name" in col_idx:
        out[col_idx["name"]] = f"Customer {partner_id}"
    for nullable in ("phone", "mobile", "vat", "street2"):
        if nullable in col_idx:
            out[col_idx[nullable]] = r"\N"
    if "street" in col_idx:
        out[col_idx["street"]] = "123 Preview Lane"
    if "zip" in col_idx:
        out[col_idx["zip"]] = "00000"
    return out


def _rewrite_res_users(row: list[str], col_idx: dict[str, int]) -> list[str]:
    user_id = row[col_idx["id"]]
    out = list(row)
    if "login" in col_idx:
        out[col_idx["login"]] = f"user{user_id}@preview.local"
    if "password" in col_idx:
        out[col_idx["password"]] = PREVIEW_BCRYPT
    if "signature" in col_idx:
        out[col_idx["signature"]] = r"\N"
    return out


def _rewrite_mail_message(row: list[str], col_idx: dict[str, int]) -> list[str]:
    out = list(row)
    author = row[col_idx["author_id"]] if "author_id" in col_idx else r"\N"
    if author != r"\N":
        if "body" in col_idx:
            out[col_idx["body"]] = "[REDACTED preview content]"
        if "subject" in col_idx:
            out[col_idx["subject"]] = "[REDACTED]"
    return out


def _null_columns(*columns: str) -> Rewriter:
    def _rw(row: list[str], col_idx: dict[str, int]) -> list[str]:
        out = list(row)
        for col in columns:
            if col in col_idx:
                out[col_idx[col]] = r"\N"
        return out

    return _rw


REWRITERS: dict[str, Rewriter] = {
    "res_partner": _rewrite_res_partner,
    "res_users": _rewrite_res_users,
    "mail_message": _rewrite_mail_message,
    "mail_tracking_value": _null_columns("old_value_text", "new_value_text"),
    "audittrail_log_line": _null_columns("old_value", "new_value"),
    "payment_transaction": _null_columns("provider_reference", "acquirer_reference"),
}


def sanitize_stream(src: IO[str], dst: IO[str]) -> None:
    """Stream-rewrite a pg_dump from src to dst."""
    current_table: str | None = None
    col_idx: dict[str, int] = {}

    for line in src:
        if current_table is None:
            match = COPY_START_RE.match(line)
            if match and match.group("table") in REWRITERS:
                current_table = match.group("table")
                cols = [c.strip() for c in match.group("cols").split(",")]
                col_idx = {name: i for i, name in enumerate(cols)}
            dst.write(line)
            continue

        if line.rstrip("\n") == r"\.":
            dst.write(line)
            current_table = None
            col_idx = {}
            continue

        row = line.rstrip("\n").split("\t")
        rewritten = REWRITERS[current_table](row, col_idx)
        dst.write("\t".join(rewritten) + "\n")


if __name__ == "__main__":
    sanitize_stream(sys.stdin, sys.stdout)
