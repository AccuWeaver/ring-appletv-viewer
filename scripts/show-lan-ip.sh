#!/usr/bin/env bash
# Print the Mac's LAN IP address for use in AppConfiguration.swift on physical
# Apple TV devices. The simulator can use localhost; real devices need the LAN IP.

set -euo pipefail

# Try en0 (usually Wi-Fi or Ethernet), fall back to en1
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)

if [[ -z "${IP}" ]]; then
    echo "Could not determine LAN IP. Are you connected to a network?" >&2
    exit 1
fi

echo "Your Mac's LAN IP: ${IP}"
echo
echo "To test on a physical Apple TV, update AppConfiguration.swift:"
echo "    authBackendBaseURL: String = \"http://${IP}:8000\""
echo
echo "Verify services are reachable:"
echo "    curl -s -o /dev/null -w \"backend: %{http_code}\\n\" http://${IP}:8000/health"
echo "    curl -s -o /dev/null -w \"devices: %{http_code}\\n\" http://${IP}:8000/mock/devices"
