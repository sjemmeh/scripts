#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGE_SH_LIB_ONLY=1 source "$SCRIPT_DIR/manage.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REGISTRY_FILE="$TMP_DIR/ports"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

test_register_port_records_app_type() {
    register_port "acme" "3000" "customer"
    register_port "landing-page" "3001" "standalone"

    grep -qx "acme 3000 customer" "$REGISTRY_FILE" || fail "customer registry entry missing app type"
    grep -qx "landing-page 3001 standalone" "$REGISTRY_FILE" || fail "standalone registry entry missing app type"
}

test_update_all_customers_skips_standalone_apps() {
    mkdir -p "$TMP_DIR/home/acme/app" "$TMP_DIR/home/landing-page/app"
    HOME_ROOT="$TMP_DIR/home"
    DOCKER_USERNAME="user"
    DOCKER_PASSWORD="pass"
    DOCKER_IMAGE="example/app:latest"

    register_port "acme" "3000" "customer"
    register_port "landing-page" "3001" "standalone"

    UPDATED_CUSTOMERS=()
    start_container() {
        UPDATED_CUSTOMERS+=("$1:${2:-}")
    }

    write_compose() {
        echo "image: $DOCKER_IMAGE" > "$1/docker-compose.yml"
    }

    id() {
        return 0
    }

    systemctl() {
        return 0
    }

    mode_update_customer_images

    [ "${#UPDATED_CUSTOMERS[@]}" -eq 1 ] || fail "expected one customer update, got ${#UPDATED_CUSTOMERS[@]}"
    [ "${UPDATED_CUSTOMERS[0]}" = "acme:" ] || fail "expected acme to restart without explicit pull"
    [ ! -f "$TMP_DIR/home/landing-page/app/docker-compose.yml" ] || fail "standalone app should not be rewritten"
}

test_find_free_port_respects_typed_registry_entries() {
    REGISTRY_FILE="$TMP_DIR/ports-find-free"
    register_port "acme" "3000" "customer"

    ss() {
        return 0
    }

    local next_port
    next_port="$(find_free_port 3000)"

    [ "$next_port" = "3001" ] || fail "expected port 3001 when 3000 is registered, got $next_port"
}

test_prune_obsolete_images_prunes_registered_users() {
    REGISTRY_FILE="$TMP_DIR/ports-prune"
    register_port "acme" "3000" "customer"
    register_port "landing-page" "3001" "standalone"
    echo "missing-user 3002 customer" >> "$REGISTRY_FILE"

    PRUNED_USERS=()
    prune_user_obsolete_images() {
        PRUNED_USERS+=("$1")
    }

    id() {
        [ "$1" != "missing-user" ]
    }

    mode_prune_obsolete_images

    [ "${#PRUNED_USERS[@]}" -eq 2 ] || fail "expected two users pruned, got ${#PRUNED_USERS[@]}"
    [ "${PRUNED_USERS[0]}" = "acme" ] || fail "expected acme to be pruned first"
    [ "${PRUNED_USERS[1]}" = "landing-page" ] || fail "expected landing-page to be pruned second"
}

test_register_port_records_app_type
test_update_all_customers_skips_standalone_apps
test_find_free_port_respects_typed_registry_entries
test_prune_obsolete_images_prunes_registered_users
echo "All manage.sh tests passed"
