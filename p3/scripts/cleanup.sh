#!/usr/bin/env bash
# Removes the Part 3 cluster (needed before running the bonus: both use port 8888).
set -euo pipefail
k3d cluster delete iot-p3
