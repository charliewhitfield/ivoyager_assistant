#!/usr/bin/env bash
# assistant_client.sh - Send JSON-RPC commands to the I, Voyager AssistantServer
#
# Usage:
#   ./assistant_client.sh <method> [params_json]
#
# Examples:
#   ./assistant_client.sh get_project_info
#   ./assistant_client.sh describe '{"widgets":false}'
#   ./assistant_client.sh get '{"object":"IVStateManager","properties":["started","paused_by_user"]}'
#   ./assistant_client.sh call '{"object":"SelectionManager","method":"select_by_name","args":{"name":"PLANET_MARS"}}'
#   ./assistant_client.sh call '{"object":"IVStateManager","method":"set_user_paused","args":{"pause":true}}'
#   ./assistant_client.sh quit '{"force":true}'
#
# Environment variables:
#   ASSISTANT_HOST  - default: 127.0.0.1
#   ASSISTANT_PORT  - default: 29071

set -euo pipefail

HOST="${ASSISTANT_HOST:-127.0.0.1}"
PORT="${ASSISTANT_PORT:-29071}"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <method> [params_json]" >&2
    echo "  e.g. $0 get_project_info" >&2
    echo "  e.g. $0 get '{\"object\":\"IVStateManager\",\"properties\":\"started\"}'" >&2
    exit 1
fi

METHOD="$1"
DEFAULT_PARAMS='{}'
PARAMS="${2:-$DEFAULT_PARAMS}"

# Build JSON request
REQUEST="{\"id\":1,\"method\":\"${METHOD}\",\"params\":${PARAMS}}"

# Send via bash /dev/tcp (works in bash on Windows/Git Bash, Linux, macOS)
exec 3<>/dev/tcp/"$HOST"/"$PORT"
echo "$REQUEST" >&3

# Read response (single line)
read -r -t 5 RESPONSE <&3 || true
exec 3<&-

if [ -z "${RESPONSE:-}" ]; then
    echo "Error: no response from $HOST:$PORT (is the application running?)" >&2
    exit 1
fi

echo "$RESPONSE"
