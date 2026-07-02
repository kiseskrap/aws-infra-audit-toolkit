FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY vitalcare_mock.py .

ENV PORT=8080
EXPOSE 8080

# unbuffered stdout so container logs are useful
ENV PYTHONUNBUFFERED=1

CMD ["python", "vitalcare_mock.py"]
