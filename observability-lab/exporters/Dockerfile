FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY cloudwatch_log_metrics.py .

EXPOSE 9108

CMD ["python", "cloudwatch_log_metrics.py"]
