from pathlib import Path

import pytest

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def fixture_loader():
    """Load a fixture file by name, returning its text contents.

    Tests use this for both input dump fragments and expected sanitizer
    output, so the assertion is always 'sanitize(input) == expected'.
    """

    def _load(name: str) -> str:
        return (FIXTURES / name).read_text()

    return _load
