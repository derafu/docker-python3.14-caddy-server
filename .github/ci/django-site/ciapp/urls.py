"""Routes of the CI test site: one per Procfile process ("web" and "api")."""
from django.http import HttpRequest, HttpResponse
from django.urls import path


def web(request: HttpRequest) -> HttpResponse:
    return HttpResponse("ci-test web ok")


def api_ping(request: HttpRequest) -> HttpResponse:
    return HttpResponse("ci-test api ok")


urlpatterns = [
    path("", web),
    path("api/ping", api_ping),
]
