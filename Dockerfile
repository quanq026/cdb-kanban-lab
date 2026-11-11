FROM python:3.15-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN useradd --system --uid 10001 --user-group --home-dir /app app

COPY app/requirements.txt /tmp/requirements.txt
# python:3.12-slim ships ca-certificates; fail the build if the CA bundle the app
# needs for verify-full ever disappears.
RUN test -s /etc/ssl/certs/ca-certificates.crt \
    && pip install --no-cache-dir -r /tmp/requirements.txt \
    && rm -f /tmp/requirements.txt

COPY --chown=app:app app/ /app

USER 10001
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["python", "-c", "import urllib.request as u; u.urlopen('http://127.0.0.1:8000/api/health', timeout=4)"]

CMD ["gunicorn", "--workers", "2", "--bind", "0.0.0.0:8000", "--timeout", "30", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
