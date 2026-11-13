"""
Settings of the minimal Django site used only by the image CI test
(.github/ci/test-image.sh). Not a real application: the SECRET_KEY below is
a fixed placeholder that only lets Django start inside the test container.
"""
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
SECRET_KEY = "ci-test-only-not-a-secret"
DEBUG = False
ALLOWED_HOSTS = ["ci-test.example"]
INSTALLED_APPS: list[str] = []
ROOT_URLCONF = "ciapp.urls"
WSGI_APPLICATION = "ciapp.wsgi.application"
DATABASES: dict[str, dict[str, str]] = {}
STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "static"
