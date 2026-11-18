FROM python:3.12-alpine

WORKDIR /app

COPY app.py .

ENV PYTHONUNBUFFERED=1 \
    PORT=8000 \
    ARTIFICIAL_DELAY_MS=500

EXPOSE 8000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"

CMD ["python", "app.py"]
