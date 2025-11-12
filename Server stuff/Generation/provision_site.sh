#!/usr/bin/env bash
set -euo pipefail

NVR_VERSION="v0.40.3"

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root (sudo)." >&2
  exit 1
fi

if [ $# -ne 2 ]; then
  cat <<EOF
Usage: $0 <username> <git_url>

EOF
  exit 2
fi

USERNAME="$1"
GIT_URL="$2"

command -v git >/dev/null 2>&1 || { echo "git is required. Install git and retry." >&2; exit 3; }
command -v systemctl >/dev/null 2>&1 || { echo "systemd/systemctl not found. This script targets systemd systems." >&2; exit 4; }

echo "=== Provisioning Node service for user ${USERNAME} ==="

########################
# Create / detect user #
########################
if id -u "${USERNAME}" >/dev/null 2>&1; then
  echo "User ${USERNAME} already exists."
  HOME_DIR="$(getent passwd "${USERNAME}" | cut -d: -f6)"
  if [ -z "${HOME_DIR}" ] || [ ! -d "${HOME_DIR}" ]; then
    echo "ERROR: Could not determine a valid home directory for ${USERNAME}." >&2
    exit 5
  fi
else
  HOME_DIR="/home/${USERNAME}"
  useradd -m -s /bin/bash "${USERNAME}"
  echo "Created user ${USERNAME} with home ${HOME_DIR}."
fi

########################
# SSH key preparation  #
########################
mkdir -p "${HOME_DIR}/.ssh"
chmod 700 "${HOME_DIR}/.ssh"
chown "${USERNAME}:${USERNAME}" "${HOME_DIR}/.ssh"

SSH_FROM_ROOT="/root/.ssh"
ROOT_PRIVATE_KEY="${SSH_FROM_ROOT}/id_rsa"
ROOT_PUBLIC_KEY="${SSH_FROM_ROOT}/id_rsa.pub"

if [ -f "${ROOT_PRIVATE_KEY}" ] && [ ! -f "${HOME_DIR}/.ssh/id_rsa" ]; then
  echo "Copying ${ROOT_PRIVATE_KEY} -> ${HOME_DIR}/.ssh/id_rsa"
  cp "${ROOT_PRIVATE_KEY}" "${HOME_DIR}/.ssh/id_rsa"
  chmod 600 "${HOME_DIR}/.ssh/id_rsa"
  chown "${USERNAME}:${USERNAME}" "${HOME_DIR}/.ssh/id_rsa"
else
  echo "Skipping private key copy (missing in /root or already present)."
fi

if [ -f "${ROOT_PUBLIC_KEY}" ] && [ ! -f "${HOME_DIR}/.ssh/id_rsa.pub" ]; then
  echo "Copying ${ROOT_PUBLIC_KEY} -> ${HOME_DIR}/.ssh/id_rsa.pub"
  cp "${ROOT_PUBLIC_KEY}" "${HOME_DIR}/.ssh/id_rsa.pub"
  chmod 644 "${HOME_DIR}/.ssh/id_rsa.pub"
  chown "${USERNAME}:${USERNAME}" "${HOME_DIR}/.ssh/id_rsa.pub"
else
  echo "Skipping public key copy (missing in /root or already present)."
fi

# Ensure authorized_keys contains id_rsa.pub (if exists)
if [ -f "${HOME_DIR}/.ssh/id_rsa.pub" ]; then
  PUB_CONTENT=$(cat "${HOME_DIR}/.ssh/id_rsa.pub")
  AUTH_FILE="${HOME_DIR}/.ssh/authorized_keys"
  touch "${AUTH_FILE}"
  chmod 600 "${AUTH_FILE}"
  chown "${USERNAME}:${USERNAME}" "${AUTH_FILE}"
  if ! grep -Fxq "${PUB_CONTENT}" "${AUTH_FILE}"; then
    echo "Adding public key to authorized_keys."
    echo "${PUB_CONTENT}" >> "${AUTH_FILE}"
  else
    echo "Public key already present in authorized_keys."
  fi
fi

########################
# Clone or update repo #
########################
REPO_NAME="$(basename -s .git "${GIT_URL}")"
TARGET_DIR="${HOME_DIR}/${REPO_NAME}"

if [ -d "${TARGET_DIR}/.git" ]; then
  echo "Repository exists at ${TARGET_DIR}, pulling latest changes..."
  sudo -H -u "${USERNAME}" bash -lc "cd '${TARGET_DIR}' && git pull --ff-only" || {
    echo "git pull failed; please resolve manually in ${TARGET_DIR}." >&2
  }
elif [ -d "${TARGET_DIR}" ]; then
  echo "WARNING: ${TARGET_DIR} exists but is not a git repo. Skipping clone."
else
  echo "Cloning ${GIT_URL} into ${TARGET_DIR} (as ${USERNAME})..."
  sudo -H -u "${USERNAME}" bash -lc "cd '${HOME_DIR}' && git clone '${GIT_URL}'"
  chown -R "${USERNAME}:${USERNAME}" "${TARGET_DIR}"
  echo "Cloned to ${TARGET_DIR}."
fi

########################
# Ensure NVM + Node LTS#
########################
USER_BASHRC="${HOME_DIR}/.bashrc"
USER_PROFILE="${HOME_DIR}/.profile"

# Add NVM init to .bashrc (idempotent)
if ! grep -q 'NVM_DIR=' "${USER_BASHRC}" 2>/dev/null; then
  echo 'Appending NVM_DIR config to .bashrc'
  cat >> "${USER_BASHRC}" <<'RC'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
RC
  chown "${USERNAME}:${USERNAME}" "${USER_BASHRC}"
fi

# Also add to .profile for login shells (idempotent)
if ! grep -q 'NVM_DIR=' "${USER_PROFILE}" 2>/dev/null; then
  echo 'Appending NVM_DIR config to .profile'
  cat >> "${USER_PROFILE}" <<'RC'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
RC
  chown "${USERNAME}:${USERNAME}" "${USER_PROFILE}"
fi

# Install nvm if not installed
sudo -H -u "${USERNAME}" bash -lc '
  set -e
  export NVM_DIR="$HOME/.nvm"
  if [ ! -d "$NVM_DIR" ]; then
    echo "Installing nvm..."
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVR_VERSION}/install.sh | bash
  else
    echo "nvm already installed."
  fi
'

# Install latest LTS Node and set default, capture absolute paths
readarray -t NODE_INFO < <(sudo -H -u "${USERNAME}" bash -lc '
  set -e
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install --lts >/dev/null
  nvm alias default "lts/*" >/dev/null
  NODE_PATH=$(command -v node)
  NPM_PATH=$(command -v npm)
  echo "$NODE_PATH"
  echo "$NPM_PATH"
')

NODE_EXEC="${NODE_INFO[0]:-}"
NPM_EXEC="${NODE_INFO[1]:-}"

if [ -z "${NODE_EXEC}" ] || [ -z "${NPM_EXEC}" ]; then
  echo "ERROR: Could not resolve Node/npm executables via nvm for ${USERNAME}." >&2
  exit 6
fi

echo "Using Node: ${NODE_EXEC}"
echo "Using npm:  ${NPM_EXEC}"

########################
# Determine code dir   #
########################
CODE_DIR="${TARGET_DIR}/code"
if [ ! -d "${CODE_DIR}" ]; then
  echo "WARNING: ${CODE_DIR} does not exist. Falling back to ${TARGET_DIR}."
  CODE_DIR="${TARGET_DIR}"
fi

########################
# npm install/ci       #
########################
if [ -f "${CODE_DIR}/package-lock.json" ] && [ -f "${CODE_DIR}/package.json" ]; then
  echo "Running npm ci in ${CODE_DIR} as ${USERNAME}..."
  sudo -H -u "${USERNAME}" bash -lc "cd '${CODE_DIR}' && '${NPM_EXEC}' ci"
elif [ -f "${CODE_DIR}/package.json" ]; then
  echo "Running npm install in ${CODE_DIR} as ${USERNAME}..."
  sudo -H -u "${USERNAME}" bash -lc "cd '${CODE_DIR}' && '${NPM_EXEC}' install"
else
  echo "No package.json found in ${CODE_DIR}, skipping dependency install."
fi

########################
# systemd service      #
########################
SERVICE_NAME="${REPO_NAME}.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

USER_UID=$(id -u "${USERNAME}")
USER_GID=$(id -g "${USERNAME}")

# ExecStart runs npm start under NVM env
EXEC_START="/bin/bash -lc 'export NVM_DIR=\"$HOME/.nvm\"; . \"$NVM_DIR/nvm.sh\"; npm run start:prod'"

# ExecStopPost runs your build chain AFTER the old process has exited
EXEC_STOP_POST="/bin/bash -lc 'export NVM_DIR=\"$HOME/.nvm\"; . \"$NVM_DIR/nvm.sh\"; npm run clean && npm run build && npm run build:css && npm run build:images'"

cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=${REPO_NAME} Node Service
After=network.target

[Service]
WorkingDirectory=${CODE_DIR}
Environment=NODE_ENV=production

ExecStart=${EXEC_START}
ExecReload=/bin/kill -s TERM \$MAINPID
ExecStopPost=${EXEC_STOP_POST}

Restart=always
RestartSec=3
User=${USER_UID}
Group=${USER_GID}

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "${SERVICE_PATH}"
echo "Wrote systemd service to ${SERVICE_PATH}"

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"
echo "Enabled and (re)started ${SERVICE_NAME} (status below):"
systemctl status --no-pager --full "${SERVICE_NAME}" || true

echo "=== Done. ==="
echo "Service:   ${SERVICE_NAME}"
echo "Repo dir:  ${TARGET_DIR}"
echo "Code dir:  ${CODE_DIR}"
echo "Node:      ${NODE_EXEC}"
