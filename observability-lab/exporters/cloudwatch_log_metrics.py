#!/usr/bin/env python3
"""Export CloudWatch Logs filter matches as OpenMetrics text.

This exporter is deliberately small and read-only. It polls configured
CloudWatch Logs groups with FilterLogEvents and exposes cumulative counters that
Prometheus can scrape.
"""

from __future__ import annotations

import json
import os
import signal
import sys
import threading
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError


CONFIG_PATH = os.getenv("EXPORTER_CONFIG", "config.json")
PORT = int(os.getenv("EXPORTER_PORT", "9108"))


@dataclass(frozen=True)
class PatternConfig:
    name: str
    log_group: str
    filter_pattern: str
    labels: dict[str, str] = field(default_factory=dict)

    @property
    def metric_labels(self) -> dict[str, str]:
        return {
            "log_group": self.log_group,
            "pattern": self.name,
            **self.labels,
        }


@dataclass
class PatternState:
    next_start_ms: int
    matched_total: int = 0
    poll_errors_total: int = 0
    last_poll_end_ms: int = 0
    last_error: str = ""


class Collector:
    def __init__(self, config: dict[str, Any]) -> None:
        self.poll_interval = int(config.get("poll_interval_seconds", 30))
        self.lookback_seconds = int(config.get("lookback_seconds", 300))
        self.patterns = [PatternConfig(**item) for item in config.get("patterns", [])]
        self.client = boto3.client("logs")
        self.lock = threading.Lock()
        start_ms = int((time.time() - self.lookback_seconds) * 1000)
        self.state = {self.key(pattern): PatternState(next_start_ms=start_ms) for pattern in self.patterns}
        self.stop_event = threading.Event()

    @staticmethod
    def key(pattern: PatternConfig) -> str:
        return f"{pattern.log_group}:{pattern.name}"

    def run(self) -> None:
        while not self.stop_event.is_set():
            self.poll_once()
            self.stop_event.wait(self.poll_interval)

    def stop(self) -> None:
        self.stop_event.set()

    def poll_once(self) -> None:
        for pattern in self.patterns:
            self.poll_pattern(pattern)

    def poll_pattern(self, pattern: PatternConfig) -> None:
        key = self.key(pattern)
        now_ms = int(time.time() * 1000)

        with self.lock:
            start_ms = self.state[key].next_start_ms

        if start_ms >= now_ms:
            return

        matched = 0
        token = None

        try:
            while True:
                params = {
                    "logGroupName": pattern.log_group,
                    "startTime": start_ms,
                    "endTime": now_ms,
                    "filterPattern": pattern.filter_pattern,
                    "limit": 10000,
                }
                if token:
                    params["nextToken"] = token

                response = self.client.filter_log_events(**params)
                matched += len(response.get("events", []))
                token = response.get("nextToken")
                if not token:
                    break

            with self.lock:
                state = self.state[key]
                state.matched_total += matched
                state.last_poll_end_ms = now_ms
                state.next_start_ms = now_ms + 1
                state.last_error = ""

        except (BotoCoreError, ClientError) as exc:
            with self.lock:
                state = self.state[key]
                state.poll_errors_total += 1
                state.last_error = exc.__class__.__name__

    def render_metrics(self) -> str:
        lines = [
            "# HELP aws_log_events_matched_total CloudWatch Logs events matched by the configured filter.",
            "# TYPE aws_log_events_matched_total counter",
        ]

        now_ms = int(time.time() * 1000)

        with self.lock:
            snapshots = [(pattern, self.state[self.key(pattern)]) for pattern in self.patterns]

        for pattern, state in snapshots:
            labels = render_labels(pattern.metric_labels)
            lines.append(f"aws_log_events_matched_total{labels} {state.matched_total}")

        lines.extend(
            [
                "# HELP aws_log_poll_errors_total CloudWatch Logs polling errors by configured filter.",
                "# TYPE aws_log_poll_errors_total counter",
            ]
        )
        for pattern, state in snapshots:
            labels = render_labels({**pattern.metric_labels, "last_error": state.last_error or "none"})
            lines.append(f"aws_log_poll_errors_total{labels} {state.poll_errors_total}")

        lines.extend(
            [
                "# HELP aws_log_poll_lag_seconds Seconds since the exporter last completed a poll for this filter.",
                "# TYPE aws_log_poll_lag_seconds gauge",
            ]
        )
        for pattern, state in snapshots:
            lag_seconds = 0 if state.last_poll_end_ms == 0 else max(0, (now_ms - state.last_poll_end_ms) / 1000)
            lines.append(f"aws_log_poll_lag_seconds{render_labels(pattern.metric_labels)} {lag_seconds:.3f}")

        lines.append("# EOF")
        return "\n".join(lines) + "\n"


class MetricsHandler(BaseHTTPRequestHandler):
    collector: Collector

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
            return

        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"not found\n")
            return

        body = self.collector.render_metrics().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/openmetrics-text; version=1.0.0; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: Any) -> None:
        return


def render_labels(labels: dict[str, str]) -> str:
    if not labels:
        return ""
    rendered = ",".join(f'{key}="{escape_label(value)}"' for key, value in sorted(labels.items()))
    return "{" + rendered + "}"


def escape_label(value: str) -> str:
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def load_config(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as config_file:
        config = json.load(config_file)

    if not config.get("patterns"):
        raise ValueError("config must contain at least one pattern")

    return config


def main() -> int:
    try:
        config = load_config(CONFIG_PATH)
        collector = Collector(config)
    except Exception as exc:
        print(f"failed to start exporter: {exc}", file=sys.stderr)
        return 1

    MetricsHandler.collector = collector
    server = ThreadingHTTPServer(("0.0.0.0", PORT), MetricsHandler)
    thread = threading.Thread(target=collector.run, daemon=True)

    def shutdown(_signum: int, _frame: Any) -> None:
        collector.stop()
        server.shutdown()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    thread.start()
    print(f"cloudwatch-log-metrics exporter listening on :{PORT}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

