"""WSGI entry point of the CI test site (used by gunicorn)."""
import os

from django.core.wsgi import get_wsgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "ciapp.settings")
application = get_wsgi_application()
