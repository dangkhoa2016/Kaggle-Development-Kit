#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
import json
import os
import tempfile
from pathlib import Path

root = Path.cwd()
defaults = (root / "config/defaults.env").read_text()
example = (root / ".kaggle-dev.env.example").read_text()
required = {
    "INSTALL_QDRANT=1",
    'QDRANT_VERSIONS="1.18.3"',
    'QDRANT_DEFAULT_VERSION="1.18.3"',
    "QDRANT_PORT_1_18_3=6333",
    "QDRANT_GRPC_PORT_1_18_3=6334",
    "QDRANT_ENABLE_GRPC=0",
    'QDRANT_AUTO_START_VERSIONS="1.18.3"',
    "QNP_RELEASE=1.0.0",
    "QNP_SOURCE_COMMIT=066084be23d23a5be11ca8e5df28d5da9eef1cc4",
}
for needle in required:
    assert needle in defaults, f"defaults missing: {needle}"
    assert needle in example, f"example env missing: {needle}"

nb = json.loads((root / "notebooks/kaggle-dev-bootstrap.ipynb").read_text())
cell = "".join(nb["cells"][1]["source"])
assert '"qdrant"' in cell, "Cell 2 must expose a qdrant CONFIG section"
assert '"INSTALL_QDRANT"' in cell, "Cell 2 must write INSTALL_QDRANT"
assert '"QNP_SOURCE_COMMIT"' in cell, "Cell 2 must write the QNP source pin"

marker = "def env_key(version: str) -> str:"
assert marker in cell
prefix, suffix = cell.split(marker, 1)
suffix = marker + suffix

def run_cell(mutator=None):
    with tempfile.TemporaryDirectory() as td:
        ns = {"PROJECT_DIR": Path(td)}
        exec(prefix, ns, ns)
        if mutator:
            mutator(ns["CONFIG"])
        exec(suffix, ns, ns)
        env_path = Path(td) / ".kaggle-dev.env"
        assert env_path.exists()
        assert oct(env_path.stat().st_mode & 0o777) == "0o600"
        values = {}
        for raw in env_path.read_text().splitlines():
            if not raw or raw.startswith("#"):
                continue
            k, v = raw.split("=", 1)
            values[k] = v.strip("'")
        return values, ns["CONFIG"]

values, cfg = run_cell()
assert values["INSTALL_QDRANT"] == "1"
assert values["QDRANT_VERSIONS"] == "1.18.3"
assert values["QDRANT_DEFAULT_VERSION"] == "1.18.3"
assert values["QDRANT_PORT_1_18_3"] == "6333"
assert values["QDRANT_GRPC_PORT_1_18_3"] == "6334"
assert values["QDRANT_ENABLE_GRPC"] == "0"
assert values["QDRANT_AUTO_START_VERSIONS"] == "1.18.3"
assert values["QNP_RELEASE"] == "1.0.0"
assert values["QNP_SOURCE_COMMIT"] == "066084be23d23a5be11ca8e5df28d5da9eef1cc4"

# Missing ports are assigned deterministically, avoiding all ports already used
# by PostgreSQL/Redis/Elastic and the pinned Qdrant default.
def add_qdrant_version(c):
    c["qdrant"]["versions"] = ["1.18.2", "1.18.3"]
    c["qdrant"]["default"] = "1.18.3"
    c["qdrant"]["auto_start"] = ["1.18.3"]
    c["qdrant"]["ports"] = {"1.18.3": 6333}
    c["qdrant"]["grpc_ports"] = {"1.18.3": 6334}

values, cfg = run_cell(add_qdrant_version)
assert cfg["qdrant"]["ports"]["1.18.2"] == 6335, cfg["qdrant"]["ports"]
assert cfg["qdrant"]["grpc_ports"]["1.18.2"] == 6336, cfg["qdrant"]["grpc_ports"]
assert values["QDRANT_PORT_1_18_2"] == "6335"
assert values["QDRANT_GRPC_PORT_1_18_2"] == "6336"

# Invalid default must be rejected.
def bad_default(c):
    c["qdrant"]["default"] = "1.18.2"
try:
    run_cell(bad_default)
except ValueError as exc:
    assert "default" in str(exc)
else:
    raise AssertionError("invalid Qdrant default was accepted")

# Qdrant requires exact X.Y.Z versions.
def bad_version(c):
    c["qdrant"]["versions"] = ["1.18"]
    c["qdrant"]["default"] = "1.18"
    c["qdrant"]["auto_start"] = []
    c["qdrant"]["ports"] = {"1.18": 6333}
    c["qdrant"]["grpc_ports"] = {"1.18": 6334}
try:
    run_cell(bad_version)
except ValueError as exc:
    assert "Exact X.Y.Z" in str(exc)
else:
    raise AssertionError("non-exact Qdrant version was accepted")

# Global collision: Qdrant REST cannot reuse PostgreSQL's port.
def collide(c):
    c["qdrant"]["ports"]["1.18.3"] = c["postgres"]["ports"]["18"]
try:
    run_cell(collide)
except ValueError as exc:
    assert "Port collisions" in str(exc)
else:
    raise AssertionError("Qdrant/PostgreSQL port collision was accepted")

# Reserve configured gRPC ports even while gRPC is disabled. This keeps Cell 2
# consistent with install-qdrant.sh and avoids a future enable creating a clash.
def collide_disabled_grpc(c):
    c["qdrant"]["enable_grpc"] = False
    c["qdrant"]["grpc_ports"]["1.18.3"] = c["redis"]["ports"]["8.10.0"]
try:
    run_cell(collide_disabled_grpc)
except ValueError as exc:
    assert "Port collisions" in str(exc)
else:
    raise AssertionError("disabled Qdrant gRPC port collision was accepted")

print("PASS: qdrant config contract")
PY
