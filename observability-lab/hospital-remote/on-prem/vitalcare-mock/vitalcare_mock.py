"""
VitalCare Mock — hospital on-prem service simulator.

Simulates a service that receives patient vital signs every ~5 seconds
and exposes ONLY aggregated operational metrics (no PHI) via /metrics.

This is a lab. It does NOT process real patient data. It exists to
demonstrate how an on-prem clinical service can expose operational
metrics that are safe to forward to a remote observability backend.

Design constraints (see docs/phi-protection.md):
- Metric labels are limited to: hospital_id, ward_id, service_version.
- No patient_id, patient_name, mrn, or vital values as labels.
- No high-cardinality labels.
- No PHI in exception messages that reach /metrics.
"""

from __future__ import annotations

import os
import random
import threading
import time
from typing import Iterable

from flask import Flask, jsonify
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

HOSPITAL_ID = os.getenv("HOSPITAL_ID", "hospital-demo")
WARD_ID = os.getenv("WARD_ID", "icu-a")
SERVICE_VERSION = os.getenv("SERVICE_VERSION", "1.0.0")

# Allowed label set. Any new label must be added here consciously.
COMMON_LABELS = ["hospital_id", "ward_id", "service_version"]

vitals_received = Counter(
    "vitalcare_vitals_received_total",
    "Total number of vital-sign submissions received",
    COMMON_LABELS,
)

vitals_processed_ok = Counter(
    "vitalcare_vitals_processed_ok_total",
    "Total number of vital-sign submissions processed successfully",
    COMMON_LABELS,
)

vitals_processing_errors = Counter(
    "vitalcare_vitals_processing_errors_total",
    "Total number of vital-sign processing errors",
    COMMON_LABELS + ["error_class"],
)

vitals_processing_duration = Histogram(
    "vitalcare_vitals_processing_duration_seconds",
    "Time spent processing one vital submission",
    COMMON_LABELS,
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5),
)

active_patient_count = Gauge(
    "vitalcare_active_patient_count",
    "Number of patients currently monitored (aggregated count, no IDs)",
    COMMON_LABELS,
)

service_up = Gauge(
    "vitalcare_service_up",
    "1 if the service is up and healthy, 0 otherwise",
    COMMON_LABELS,
)


def _labels() -> dict:
    return {
        "hospital_id": HOSPITAL_ID,
        "ward_id": WARD_ID,
        "service_version": SERVICE_VERSION,
    }


# Initialize gauges so Prometheus sees them from t=0.
service_up.labels(**_labels()).set(1)
active_patient_count.labels(**_labels()).set(0)


def simulate_traffic() -> None:
    """Background loop that pretends to receive vitals every ~5s.

    Deliberately never touches actual patient data. Only counters and
    latencies. Occasional error to make the error metric non-zero so a
    dashboard/alert can exercise it.
    """
    labels = _labels()
    while True:
        # Between 3 and 12 vitals per 5-second window (multi-bed ward).
        n = random.randint(3, 12)
        active_patient_count.labels(**labels).set(random.randint(5, 20))
        for _ in range(n):
            vitals_received.labels(**labels).inc()
            with vitals_processing_duration.labels(**labels).time():
                # Simulate processing time between 5ms and 200ms.
                time.sleep(random.uniform(0.005, 0.2))
                # 1% synthetic error rate — bounded, non-PHI class name.
                if random.random() < 0.01:
                    vitals_processing_errors.labels(
                        **labels,
                        error_class="ProcessingError",
                    ).inc()
                    continue
                vitals_processed_ok.labels(**labels).inc()
        time.sleep(5)


app = Flask(__name__)


@app.get("/health")
def health() -> tuple[str, int]:
    return jsonify({"status": "ok", "hospital": HOSPITAL_ID, "ward": WARD_ID}), 200


@app.get("/metrics")
def metrics() -> tuple[bytes, int, dict]:
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


@app.get("/")
def index() -> tuple[str, int]:
    return (
        "VitalCare Mock — this is a lab. No real patient data is processed here.\n"
        "GET /health   — liveness\n"
        "GET /metrics  — Prometheus metrics (aggregated, PHI-free)\n"
    ), 200


def main() -> None:
    t = threading.Thread(target=simulate_traffic, daemon=True)
    t.start()
    port = int(os.getenv("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
