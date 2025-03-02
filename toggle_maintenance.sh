#!/bin/bash

# Nginx Proxy Manager URL
NPM_URL="http://10.0.0.5:81"

# Get a fresh token
TOKEN_RESPONSE=$(curl -s "$NPM_URL/api/tokens" \
  -H 'Content-Type: application/json; charset=UTF-8' \
  --data-raw '{"identity":"","secret":""}' \
  --compressed)

# Extract token from response
API_KEY=$(echo $TOKEN_RESPONSE | grep -o '"token":"[^"]*' | cut -d'"' -f4)

# Enable or disable maintenance mode
if [[ "$1" == "enable" ]]; then
  ADVANCED_CONFIG="error_page 503 /maintenance.html;\n\nlocation = /maintenance.html {\n  alias /data/web/maintenance.html;\n  internal;\n}\n\nlocation / {\n  return 503;\n}"
elif [[ "$1" == "disable" ]]; then
  ADVANCED_CONFIG=""
else
  echo "Usage: $0 [enable|disable]"
  exit 1
fi

# Update proxy hosts 29 and 31
# To-Do: Make this a var (CBA right now)
for PROXY_ID in 29 31; do
  curl -q -s -X PUT "$NPM_URL/api/nginx/proxy-hosts/$PROXY_ID" \
       -H "Authorization: Bearer $API_KEY" \
       -H "Content-Type: application/json" \
       -d '{
         "advanced_config": "'"$ADVANCED_CONFIG"'"
       }'
  echo "Proxy $PROXY_ID updated."
done