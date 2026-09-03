#!/usr/bin/env bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Common configuration
# ---------------------------------------------------------------------------

PROJECT_DIR="$(realpath "$(pwd)")"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

# Resolve the repo location from this script, so it works from any checkout.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd)"
CONTAINERFILE_DIR="$SCRIPT_DIR"

BASE_CONTAINERFILE="$CONTAINERFILE_DIR/Containerfile-agent-base"
BASE_IMAGE_NAME="agent-base:latest"

# These must be supplied by the caller:
#   AGENT_NAME
#   AGENT_CONTAINERFILE
#   AGENT_IMAGE_NAME
#   CONTAINER_NAME
#
# The caller may also define:
#   prepare_persistent_state()
#   run_new_container()

CONTAINER_PROJECT_DIR="/workspace/${PROJECT_NAME}"


# ---------------------------------------------------------------------------
# Remove all containers and images
# ---------------------------------------------------------------------------

remove_all() {
    echo "============================================================"
    echo "Removing ${AGENT_NAME} containers and images"
    echo "============================================================"
    echo

    # Find all containers for this agent.
    mapfile -t AGENT_CONTAINERS < <(
        podman ps -a \
            --format '{{.Names}}' \
            | grep "^${AGENT_NAME,,}-" \
            || true
    )

    if ((${#AGENT_CONTAINERS[@]} == 0)); then
        echo "No ${AGENT_NAME} containers found."
    else
        echo "${AGENT_NAME} containers to remove:"

        for container in "${AGENT_CONTAINERS[@]}"; do
            echo "  $container"
        done

        echo

        # Remove both running and stopped containers.
        for container in "${AGENT_CONTAINERS[@]}"; do
            echo "Removing container: $container"
            podman rm -f "$container"
        done
    fi

    echo

    # -----------------------------------------------------------------------
    # Remove agent image.
    # -----------------------------------------------------------------------

    if podman image exists "$AGENT_IMAGE_NAME"; then
        echo "Removing ${AGENT_NAME} image: $AGENT_IMAGE_NAME"

        if ! podman rmi "$AGENT_IMAGE_NAME"; then
            echo
            echo "ERROR: Could not remove ${AGENT_NAME} image '$AGENT_IMAGE_NAME'."
            echo "The image is still referenced by one or more containers."
            echo
            echo "Containers referencing this image:"

            podman ps -a \
                --filter "ancestor=$AGENT_IMAGE_NAME" \
                --format '  {{.Names}}'

            exit 1
        fi
    else
        echo "${AGENT_NAME} image '$AGENT_IMAGE_NAME' does not exist."
    fi

    echo

    # -----------------------------------------------------------------------
    # Remove base image.
    # -----------------------------------------------------------------------

    if podman image exists "$BASE_IMAGE_NAME"; then
        echo "Removing base image: $BASE_IMAGE_NAME"

        # Do NOT use --force here.
        if ! podman rmi "$BASE_IMAGE_NAME"; then
            echo
            echo "ERROR: Could not remove base image '$BASE_IMAGE_NAME'."
            echo
            echo "The base image is still referenced by existing containers."
            echo "This may include other agent containers."
            echo
            echo "Containers referencing '$BASE_IMAGE_NAME':"

            BLOCKING_CONTAINERS="$(
                podman ps -a \
                    --filter "ancestor=$BASE_IMAGE_NAME" \
                    --format '  {{.Names}}' \
                    || true
            )"

            if [[ -n "$BLOCKING_CONTAINERS" ]]; then
                echo "$BLOCKING_CONTAINERS"
            else
                echo "  Unable to determine the referencing containers."
                echo "  Use:"
                echo "    podman ps -a"
            fi

            echo
            echo "Base image was NOT forcibly removed."
            echo "Remove those containers first, then run:"
            echo "  $0 rm"
            echo

            exit 1
        fi
    else
        echo "Base image '$BASE_IMAGE_NAME' does not exist."
    fi

    echo
    echo "============================================================"
    echo "${AGENT_NAME} cleanup complete"
    echo "============================================================"
}


# ---------------------------------------------------------------------------
# Common startup checks
# ---------------------------------------------------------------------------

check_environment() {
    echo "Starting ${AGENT_NAME} for project: $PROJECT_DIR"
    echo "Container project path: $CONTAINER_PROJECT_DIR"

    # -----------------------------------------------------------------------
    # Wayland
    # -----------------------------------------------------------------------

    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        WAYLAND_SOCKET="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"

        if [[ ! -S "$WAYLAND_SOCKET" ]]; then
            echo "Warning: Wayland socket not found: $WAYLAND_SOCKET"
        fi
    fi

    # -----------------------------------------------------------------------
    # Safety checks
    # -----------------------------------------------------------------------

    # Don't allow the project itself to be HOME or a parent of HOME.
    if [[ "$PROJECT_DIR" == "$HOME" || "$HOME/" == "$PROJECT_DIR/"* ]]; then
        echo "Refusing to run: project directory is HOME or contains HOME."
        exit 1
    fi

    # -----------------------------------------------------------------------
    # Verify Containerfiles exist.
    # -----------------------------------------------------------------------

    if [[ ! -f "$BASE_CONTAINERFILE" ]]; then
        echo "Base Containerfile not found: $BASE_CONTAINERFILE"
        exit 1
    fi

    if [[ ! -f "$AGENT_CONTAINERFILE" ]]; then
        echo "${AGENT_NAME} Containerfile not found: $AGENT_CONTAINERFILE"
        exit 1
    fi
}


# ---------------------------------------------------------------------------
# Build images
# ---------------------------------------------------------------------------

build_images() {
    # -----------------------------------------------------------------------
    # Build base image
    # -----------------------------------------------------------------------

    if ! podman image exists "$BASE_IMAGE_NAME"; then
        echo
        echo "Podman image '$BASE_IMAGE_NAME' does not exist."
        echo "Building base image from:"
        echo "  $BASE_CONTAINERFILE"
        echo

        podman build \
            --file "$BASE_CONTAINERFILE" \
            --tag "$BASE_IMAGE_NAME" \
            "$CONTAINERFILE_DIR"
    else
        echo "Base image '$BASE_IMAGE_NAME' already exists."
    fi

    # -----------------------------------------------------------------------
    # Build agent image
    # -----------------------------------------------------------------------

    if ! podman image exists "$AGENT_IMAGE_NAME"; then
        echo
        echo "Podman image '$AGENT_IMAGE_NAME' does not exist."
        echo "Building ${AGENT_NAME} image from:"
        echo "  $AGENT_CONTAINERFILE"
        echo

        podman build \
            --file "$AGENT_CONTAINERFILE" \
            --tag "$AGENT_IMAGE_NAME" \
            "$CONTAINERFILE_DIR"
    else
        echo "${AGENT_NAME} image '$AGENT_IMAGE_NAME' already exists."
    fi
}


# ---------------------------------------------------------------------------
# Shell mode
# ---------------------------------------------------------------------------

shell_mode() {
    # "sh" means: open a shell in the EXISTING project container.
    # Never create a container in this mode.

    if ! podman container exists "$CONTAINER_NAME"; then
        echo "Container '$CONTAINER_NAME' does not exist."
        echo "Start ${AGENT_NAME} normally first to create it."
        exit 1
    fi

    # Start the container if it isn't running.
    if [[ "$(podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]]; then
        echo "Starting stopped container '$CONTAINER_NAME'."
        podman start "$CONTAINER_NAME" >/dev/null
    fi

    echo "Opening shell in '$CONTAINER_NAME'."

    exec podman exec -it \
        --workdir "$CONTAINER_PROJECT_DIR" \
        "$CONTAINER_NAME" \
        bash
}


# ---------------------------------------------------------------------------
# Reuse existing container
# ---------------------------------------------------------------------------

reuse_existing_container() {
    if podman container exists "$CONTAINER_NAME"; then
        echo "Reusing existing container '$CONTAINER_NAME'."
        exec podman start -ai "$CONTAINER_NAME"
    fi
}


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

run_agent() {
    case "${1:-}" in
        rm)
            remove_all
            exit 0
            ;;
        sh)
            check_environment
            build_images
            shell_mode
            ;;
    esac

    check_environment
    build_images

    # Reuse existing container for THIS project.
    reuse_existing_container

    # Agent-specific persistent state.
    prepare_persistent_state

    # Create container for the first time.
    echo
    echo "Creating container '$CONTAINER_NAME'."
    echo

    run_new_container
}

