"""Integration test: post-restore purge against ephemeral Postgres.

Spins up a postgres:17 container, seeds the delete-rows tables with one row
each, runs the purge SQL, asserts all empty. Skipped when Docker is not
available so the suite remains runnable in environments without a daemon.
"""

import shutil
import subprocess
import time
import uuid
from pathlib import Path

import pytest

PURGE_SQL = Path(__file__).resolve().parent.parent / "post-restore-purge.sql"


def _docker_available() -> bool:
    if not shutil.which("docker"):
        return False
    return subprocess.run(["docker", "info"], capture_output=True).returncode == 0


pytestmark = pytest.mark.skipif(
    not _docker_available(),
    reason="docker not available; post-restore purge requires a real Postgres",
)


@pytest.fixture
def pg_container():
    name = f"grove-preview-test-{uuid.uuid4().hex[:8]}"
    subprocess.run(
        [
            "docker", "run", "-d", "--rm",
            "--name", name,
            "-e", "POSTGRES_PASSWORD=test",
            "-p", "0:5432",
            "postgres:17",
        ],
        check=True,
        capture_output=True,
    )
    try:
        for _ in range(30):
            ready = subprocess.run(
                ["docker", "exec", name, "pg_isready", "-U", "postgres"],
                capture_output=True,
            )
            if ready.returncode == 0:
                break
            time.sleep(1)
        else:
            pytest.fail("postgres container never became ready")
        yield name
    finally:
        subprocess.run(["docker", "stop", name], capture_output=True)


def _psql(container: str, sql: str) -> str:
    result = subprocess.run(
        ["docker", "exec", "-i", container, "psql", "-U", "postgres", "-t", "-A"],
        check=True,
        capture_output=True,
        text=True,
        input=sql,
    )
    return result.stdout


def test_post_restore_purge_empties_delete_rows_tables(pg_container):
    _psql(
        pg_container,
        """
        CREATE TABLE payment_token (id int);
        CREATE TABLE res_partner_bank (id int);
        CREATE TABLE mail_notification (id int);
        CREATE TABLE bus_bus (id int);
        INSERT INTO payment_token VALUES (1);
        INSERT INTO res_partner_bank VALUES (1);
        INSERT INTO mail_notification VALUES (1);
        INSERT INTO bus_bus VALUES (1);
        """,
    )

    _psql(pg_container, PURGE_SQL.read_text())

    counts = _psql(
        pg_container,
        """
        SELECT COUNT(*) FROM payment_token
        UNION ALL SELECT COUNT(*) FROM res_partner_bank
        UNION ALL SELECT COUNT(*) FROM mail_notification
        UNION ALL SELECT COUNT(*) FROM bus_bus;
        """,
    ).strip().split("\n")

    assert counts == ["0", "0", "0", "0"]
