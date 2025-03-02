#!/bin/bash

# Script to check for Docker image updates and restart containers if needed
# Usage: ./docker_update.sh /path/to/parent/directory

PARENT_DIR="${1:-$(pwd)}"
LOG_FILE="$PARENT_DIR/docker_updates.log"

# Log function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "Starting Docker update check in: $PARENT_DIR"

# Process each subdirectory
for DIR in "$PARENT_DIR"/*/; do
  if [ -d "$DIR" ]; then
    cd "$DIR" || continue
    DIR_NAME=$(basename "$DIR")
    log "Checking directory: $DIR_NAME"

    # Check for docker compose files
    if [ -f "docker-compose.yml" ] || [ -f "compose.yml" ]; then
      COMPOSE_FILE=$([ -f "docker-compose.yml" ] && echo "docker-compose.yml" || echo "compose.yml")
      log "Found $COMPOSE_FILE in $DIR_NAME"
      
      # Check for Dockerfiles (standard and custom named)
      DOCKERFILES=(Dockerfile $(find . -maxdepth 1 -name "Dockerfile_*"))
      NEED_RESTART=false
      
      # If Dockerfiles exist, build them first
      if [ ${#DOCKERFILES[@]} -gt 0 ]; then
        for DOCKERFILE in "${DOCKERFILES[@]}"; do
          if [ -f "$DOCKERFILE" ]; then
            # Extract service name from custom Dockerfile (Dockerfile_servicename)
            if [[ "$DOCKERFILE" == *"_"* ]]; then
              SERVICE_NAME=$(echo "$DOCKERFILE" | sed 's/\.\/Dockerfile_//')
              IMAGE_NAME="${DIR_NAME,,}_${SERVICE_NAME,,}:latest"
            else
              IMAGE_NAME="${DIR_NAME,,}:latest"
            fi
            
            log "Building image from $DOCKERFILE: $IMAGE_NAME"
            
            # Build with specific Dockerfile if custom
            if [[ "$DOCKERFILE" == *"_"* ]]; then
              docker build -t "${IMAGE_NAME}_new" -f "$DOCKERFILE" .
            else
              docker build -t "${IMAGE_NAME}_new" .
            fi
            
            # Get image IDs
            OLD_IMAGE_ID=$(docker images -q "$IMAGE_NAME" 2>/dev/null)
            NEW_IMAGE_ID=$(docker images -q "${IMAGE_NAME}_new")
            
            # Tag the new image and remove temporary
            docker tag "${IMAGE_NAME}_new" "$IMAGE_NAME"
            docker rmi "${IMAGE_NAME}_new" 2>/dev/null
            
            # Check if image was updated
            if [ "$OLD_IMAGE_ID" != "$NEW_IMAGE_ID" ] || [ -z "$OLD_IMAGE_ID" ]; then
              log "Image $IMAGE_NAME was updated"
              NEED_RESTART=true
            else
              log "No changes detected for $IMAGE_NAME"
            fi
          fi
        done
        
        # Only restart if changes were detected
        if [ "$NEED_RESTART" = true ]; then
          log "Restarting docker compose services due to image updates..."
          docker compose down && docker compose up -d
        else
          log "No image changes detected, skipping service restart"
        fi
      else
        # No Dockerfiles, just check for updates to pulled images
        
        # Save image digests before pull
        BEFORE_DIGESTS=$(docker compose images -q 2>/dev/null)
        
        # Pull images to check for updates
        log "Pulling latest images..."
        docker compose pull
        
        # Save image digests after pull
        AFTER_DIGESTS=$(docker compose images -q 2>/dev/null)
        
        # Compare digests to check for updates
        if [ "$BEFORE_DIGESTS" != "$AFTER_DIGESTS" ]; then
          log "Updates found for docker compose services in $DIR_NAME"
          log "Restarting docker compose services..."
          docker compose down && docker compose up -d
        else
          log "All images are up to date in $DIR_NAME"
        fi
      fi
    else
      # No docker-compose.yml, check for standalone Dockerfiles
      DOCKERFILES=(Dockerfile $(find . -maxdepth 1 -name "Dockerfile_*"))
      
      if [ ${#DOCKERFILES[@]} -gt 0 ]; then
        for DOCKERFILE in "${DOCKERFILES[@]}"; do
          if [ -f "$DOCKERFILE" ]; then
            # Extract service name from custom Dockerfile
            if [[ "$DOCKERFILE" == *"_"* ]]; then
              SERVICE_NAME=$(echo "$DOCKERFILE" | sed 's/\.\/Dockerfile_//')
              IMAGE_NAME="${DIR_NAME,,}_${SERVICE_NAME,,}:latest"
            else
              IMAGE_NAME="${DIR_NAME,,}:latest"
            fi
            
            log "Building standalone image from $DOCKERFILE: $IMAGE_NAME"
            
            # Build with specific Dockerfile if custom
            if [[ "$DOCKERFILE" == *"_"* ]]; then
              docker build -t "${IMAGE_NAME}_new" -f "$DOCKERFILE" .
            else
              docker build -t "${IMAGE_NAME}_new" .
            fi
            
            # Get image IDs
            OLD_IMAGE_ID=$(docker images -q "$IMAGE_NAME" 2>/dev/null)
            NEW_IMAGE_ID=$(docker images -q "${IMAGE_NAME}_new")
            
            # Tag the new image and remove temporary
            docker tag "${IMAGE_NAME}_new" "$IMAGE_NAME"
            docker rmi "${IMAGE_NAME}_new" 2>/dev/null
            
            # If image IDs differ or old image doesn't exist, restart containers
            if [ "$OLD_IMAGE_ID" != "$NEW_IMAGE_ID" ] || [ -z "$OLD_IMAGE_ID" ]; then
              log "Image $IMAGE_NAME was updated. Restarting containers."
              
              # Try to find and restart containers using this image
              CONTAINERS=$(docker ps -a --filter "ancestor=$IMAGE_NAME" --format "{{.Names}}")
              if [ -n "$CONTAINERS" ]; then
                for CONTAINER in $CONTAINERS; do
                  log "Restarting container: $CONTAINER"
                  docker stop "$CONTAINER" && docker rm "$CONTAINER" && \
                  docker run -d --name "$CONTAINER" "$IMAGE_NAME"
                done
              else
                log "No running containers found for image $IMAGE_NAME"
              fi
            else
              log "No changes detected for $IMAGE_NAME. Skipping restart."
            fi
          fi
        done
      else
        log "No Docker configuration found in $DIR_NAME. Skipping."
      fi
    fi
    
    cd "$PARENT_DIR" || exit
  fi
done

log "Docker update check completed."