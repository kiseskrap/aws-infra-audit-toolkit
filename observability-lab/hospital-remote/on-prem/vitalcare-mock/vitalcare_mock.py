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
CONTRACT_TIER = os.getenv("CONTRACT_TIER", "standard")  # standard | enterprise

# Red-team mode intentionally exposes PHI-shaped metrics to verify that
# the OTel Collector's PHI defenses actually drop them. Never enable in
# any real deployment. Default OFF. Toggled by env only.
RED_TEAM_MODE = os.getenv("RED_TEAM_MODE", "false").lower() in ("1", "true", "yes")

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

# ---------------------------------------------------------------------------
# PRODUCT METRICS — for executive and product-analytics dashboards.
# All labels are role/severity/outcome/feature/contract_tier: bounded,
# non-PHI, non-patient-identifying by construction.
# ---------------------------------------------------------------------------

active_users = Gauge(
    "vitalcare_active_users",
    "Users active in the last 15 minutes",
    COMMON_LABELS + ["role"],  # role: attending / resident / nurse
)

alerts_generated = Counter(
    "vitalcare_alerts_generated_total",
    "Total alerts fired by the system",
    COMMON_LABELS + ["severity"],  # severity: critical / high / medium / low
)

alert_outcomes = Counter(
    "vitalcare_alert_outcome_total",
    "How alerts were resolved. This is the product-accuracy signal.",
    COMMON_LABELS + ["severity", "outcome"],
    # outcome: true_positive / false_positive / timeout
)

alert_ack_seconds = Histogram(
    "vitalcare_alert_ack_seconds",
    "Time from alert generation to first user acknowledgement",
    COMMON_LABELS + ["severity"],
    buckets=(1, 5, 15, 30, 60, 120, 300, 600, 1800),
)

session_duration = Histogram(
    "vitalcare_session_duration_seconds",
    "User session length distribution",
    COMMON_LABELS + ["role"],
    buckets=(30, 60, 300, 900, 1800, 3600, 7200, 14400),
)

feature_active = Gauge(
    "vitalcare_feature_active",
    "1 if this feature is enabled at this hospital, 0 otherwise",
    COMMON_LABELS + ["feature", "contract_tier"],
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

# Advertise which features are enabled at this hospital.
# Standard tier gets the basics; enterprise gets everything.
FEATURES = {
    "basic_vitals": True,       # all tiers
    "smart_alerting": True,     # all tiers
    "advanced_analytics": CONTRACT_TIER == "enterprise",
    "ml_early_warning": CONTRACT_TIER == "enterprise",
    "custom_dashboards": CONTRACT_TIER == "enterprise",
}
for feature, on in FEATURES.items():
    feature_active.labels(**_labels(), feature=feature, contract_tier=CONTRACT_TIER).set(
        1 if on else 0
    )


# ---------------------------------------------------------------------------
# RED-TEAM MODE — intentional PHI leakage, disabled by default
# ---------------------------------------------------------------------------
#
# When RED_TEAM_MODE is enabled, the service emits three deliberately
# non-compliant metrics. The whole point is to confirm the OTel Collector's
# defense layers 1 and 2 (transform allow-list + filter drop-by-name) drop
# these before they can reach the cloud backend.
#
#   Attack 1 — metric NAME contains "patient_id"
#              Should be dropped by filter/drop_phi_metrics.
#   Attack 2 — metric NAME contains "mrn"
#              Should be dropped by filter/drop_phi_metrics.
#   Attack 3 — metric name is INNOCENT but label contains patient_id
#              Should be scrubbed by transform/allowlist
#              (patient_id is not in the keep_keys list).
#
# In production this endpoint and these metrics would not exist at all.
# They exist here so that a compliance auditor can watch them get blocked.

red_team_patient_id_leaked: Counter | None = None
red_team_mrn_lookups: Counter | None = None
red_team_vitals_by_patient: Counter | None = None

if RED_TEAM_MODE:
    # Attacks 1–3: purpose-built PHI-shaped metrics.
    red_team_patient_id_leaked = Counter(
        "vitalcare_patient_id_leaked_total",
        "RED-TEAM: metric NAME contains patient_id. Must be dropped by filter.",
        COMMON_LABELS,
    )
    red_team_mrn_lookups = Counter(
        "vitalcare_mrn_lookups_total",
        "RED-TEAM: metric NAME contains mrn. Must be dropped by filter.",
        COMMON_LABELS,
    )
    red_team_vitals_by_patient = Counter(
        "vitalcare_vitals_by_patient_total",
        "RED-TEAM: innocent name, but the label carries patient_id (PHI).",
        COMMON_LABELS + ["patient_id"],
    )
    # Attacks 4–5 target the real product-metric names added in Phase 2.
    # A prometheus_client Counter/Gauge can't be registered twice under the
    # same name, so we unregister the well-behaved versions and re-register
    # them with an extra PHI label. This exactly mirrors the "engineer added
    # patient_id to help debugging" real-world regression we want to catch.
    from prometheus_client import REGISTRY as _REGISTRY  # noqa: E402

    _REGISTRY.unregister(alerts_generated)
    _REGISTRY.unregister(active_users)
    alerts_generated = Counter(
        "vitalcare_alerts_generated_total",
        "RED-TEAM: real product metric name, label leaks patient_id.",
        COMMON_LABELS + ["severity", "patient_id"],
    )
    active_users = Gauge(
        "vitalcare_active_users",
        "RED-TEAM: real product metric name, label leaks user_name.",
        COMMON_LABELS + ["role", "user_name"],
    )


def red_team_traffic() -> None:
    """Background loop that increments PHI-shaped metrics."""
    labels = _labels()
    tick = 0
    while True:
        tick += 1
        if red_team_patient_id_leaked is not None:
            red_team_patient_id_leaked.labels(**labels).inc()
        if red_team_mrn_lookups is not None:
            red_team_mrn_lookups.labels(**labels).inc()
        if red_team_vitals_by_patient is not None:
            for pid in (f"P{1000 + tick % 5:04d}",):
                red_team_vitals_by_patient.labels(**labels, patient_id=pid).inc()
        # Attacks 4–5: legit product metric names, PHI labels.
        alerts_generated.labels(
            **labels,
            severity="critical",
            patient_id=f"P{2000 + tick % 5:04d}",
        ).inc()
        active_users.labels(
            **labels,
            role="attending",
            user_name=f"dr_kim_{tick % 3}",
        ).set(1)
        time.sleep(2)


def simulate_traffic() -> None:
    """Background loop that pretends to receive vitals every ~5s.

    Deliberately never touches actual patient data. Only counters and
    latencies. Occasional error to make the error metric non-zero so a
    dashboard/alert can exercise it.
    """
    labels = _labels()
    tick = 0
    while True:
        tick += 1

        # ---- Vitals workload (original) ----
        n = random.randint(3, 12)
        active_patient_count.labels(**labels).set(random.randint(5, 20))
        for _ in range(n):
            vitals_received.labels(**labels).inc()
            with vitals_processing_duration.labels(**labels).time():
                time.sleep(random.uniform(0.005, 0.2))
                if random.random() < 0.01:
                    vitals_processing_errors.labels(
                        **labels,
                        error_class="ProcessingError",
                    ).inc()
                    continue
                vitals_processed_ok.labels(**labels).inc()

        # ---- Product-metric simulation ----
        # Active users: a small realistic staff population per ward.
        active_users.labels(**labels, role="attending").set(random.randint(1, 3))
        active_users.labels(**labels, role="resident").set(random.randint(2, 6))
        active_users.labels(**labels, role="nurse").set(random.randint(4, 12))

        # Alerts: 0–3 per 5-second window, weighted toward lower severity.
        alerts_this_cycle = random.choices([0, 1, 2, 3], weights=[65, 22, 10, 3])[0]
        for _ in range(alerts_this_cycle):
            severity = random.choices(
                ["critical", "high", "medium", "low"],
                weights=[5, 15, 40, 40],
            )[0]
            alerts_generated.labels(**labels, severity=severity).inc()

            # Outcome: enterprise tier gets better precision (fewer FPs).
            base_fp_rate = 0.35 if CONTRACT_TIER == "standard" else 0.18
            outcome = random.choices(
                ["true_positive", "false_positive", "timeout"],
                weights=[
                    int((1 - base_fp_rate - 0.03) * 100),
                    int(base_fp_rate * 100),
                    3,
                ],
            )[0]
            alert_outcomes.labels(**labels, severity=severity, outcome=outcome).inc()

            # Ack latency: attending is fast, timeouts are slow by definition.
            if outcome == "timeout":
                ack = random.uniform(300, 1800)
            elif severity == "critical":
                ack = random.uniform(2, 30)
            else:
                ack = random.uniform(10, 180)
            alert_ack_seconds.labels(**labels, severity=severity).observe(ack)

        # Session length: only observe every 60 ticks (~5min) to avoid
        # over-counting; simulate a small number of ended sessions per window.
        if tick % 12 == 0:
            for role, base in [("attending", 3600), ("resident", 5400), ("nurse", 1800)]:
                duration = random.expovariate(1 / base)
                session_duration.labels(**labels, role=role).observe(duration)

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
    if RED_TEAM_MODE:
        # In red-team mode alerts_generated / active_users have an extra
        # PHI label, so simulate_traffic's call sites would raise. Run the
        # PHI-emitting loop only; the compliance check needs nothing else.
        print("[VitalCare mock] RED_TEAM_MODE is ON — emitting PHI-shaped metrics.")
        print("                 These must be dropped by the OTel Collector.")
        threading.Thread(target=red_team_traffic, daemon=True).start()
    else:
        threading.Thread(target=simulate_traffic, daemon=True).start()
    port = int(os.getenv("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
