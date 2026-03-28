# Multi-stage build for Minecraft TurfWars server with plugins
FROM alpine:3.19 AS builder

WORKDIR /build

ARG AWS_ACCESS_KEY_ID=""
ARG AWS_SECRET_ACCESS_KEY=""
ARG AWS_REGION="us-east-1"
ARG PUBLIC_PLUGINS_BUCKET="pharogames-plugins"
ARG CACHE_BUST=""

RUN apk add --no-cache jq python3 py3-pip && \
    pip3 install --break-system-packages awscli

COPY plugins.json /tmp/plugins.json

RUN echo "cache_bust=$CACHE_BUST" && mkdir -p plugins && \
    for row in $(cat /tmp/plugins.json | jq -r '.[] | @base64'); do \
        S3_KEY=$(echo "$row" | base64 -d | jq -r '.s3_key') && \
        OUTPUT=$(echo "$row" | base64 -d | jq -r '.output') && \
        echo "Downloading s3://${PUBLIC_PLUGINS_BUCKET}/${S3_KEY} -> plugins/${OUTPUT}" && \
        AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
        AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
        aws s3 cp "s3://${PUBLIC_PLUGINS_BUCKET}/${S3_KEY}" "plugins/${OUTPUT}" \
            --region "${AWS_REGION}"; \
    done && \
    echo "=== Downloaded plugins ===" && ls -la plugins/

# Runtime stage
FROM eclipse-temurin:21-jre-alpine

ARG CACHE_BUST=""
LABEL com.pharogames.build-cache-bust="${CACHE_BUST}"

# Install required packages
RUN apk add --no-cache curl ca-certificates coreutils

# Create server directory
WORKDIR /server

# Download Purpur server jar
ARG PURPUR_VERSION=1.21.11
RUN echo "Downloading Purpur ${PURPUR_VERSION}..." && \
    curl -o server.jar "https://api.purpurmc.org/v2/purpur/${PURPUR_VERSION}/latest/download" && \
    echo "Purpur ${PURPUR_VERSION} downloaded successfully"

# Pre-populate Purpur cache so pods skip the mojang jar download + patching at runtime
RUN echo "eula=true" > eula.txt && \
    timeout 120 java -Xmx512M -jar server.jar nogui 2>&1 || true && \
    ls -la cache/ && \
    rm -rf world world_nether world_the_end logs *.json *.yml *.properties 2>/dev/null || true

# Copy plugins from builder stage (dynamic plugins from ServerType registry)
COPY --from=builder /build/plugins ./plugins/

# Copy static plugins and plugin configurations from repository plugins/ directory
COPY plugins ./plugins-temp/
RUN if [ -d ./plugins-temp ]; then \
        if [ "$(ls -A ./plugins-temp/*.jar 2>/dev/null)" ]; then \
            echo "Copying static plugins..." && \
            cp ./plugins-temp/*.jar ./plugins/ && \
            echo "Static plugins copied successfully"; \
        fi && \
        for dir in ./plugins-temp/*/; do \
            if [ -d "$dir" ]; then \
                plugin_name=$(basename "$dir") && \
                echo "Copying config for plugin: $plugin_name" && \
                mkdir -p "./plugins/$plugin_name" && \
                cp -r "$dir"* "./plugins/$plugin_name/" 2>/dev/null || true; \
            fi; \
        done && \
        echo "Plugin configurations copied successfully"; \
    else \
        echo "No plugins directory found, skipping..."; \
    fi && \
    rm -rf ./plugins-temp

# Copy server configuration
COPY server.properties ./server.properties
COPY eula.txt ./eula.txt

# Copy config manifest for configloader
COPY config-manifest.json ./config-manifest.json

# Copy default Purpur configuration files
COPY bukkit.yml ./bukkit.yml
COPY spigot.yml ./spigot.yml
COPY purpur.yml ./purpur.yml

# Copy Paper-generated config files (pre-baked to avoid two-phase boot)
COPY config/ ./config/

# Create necessary directories and cache-bust marker
RUN mkdir -p /data/world /data/config logs

# Expose Minecraft port
EXPOSE 25565

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
    CMD nc -z localhost 25565 || exit 1

# Create startup script
RUN echo '#!/bin/sh' > /server/start.sh && \
    echo 'set -e' >> /server/start.sh && \
    echo '' >> /server/start.sh && \
    echo '# Startup timing: logs wall-clock epoch ms so orchestrator logs can be correlated.' >> /server/start.sh && \
    echo 'T0=$(date +%s%3N)' >> /server/start.sh && \
    echo 'ts() { NOW=$(date +%s%3N); echo "[STARTUP] $1 epoch=${NOW} elapsed=$((NOW - T0))ms"; }' >> /server/start.sh && \
    echo '' >> /server/start.sh && \
    echo 'ts "start_sh_begin"' >> /server/start.sh && \
    echo '' >> /server/start.sh && \
    echo 'if [ ! -f /server/server.jar ]; then' >> /server/start.sh && \
    echo '  echo "Error: server.jar not found!"' >> /server/start.sh && \
    echo '  exit 1' >> /server/start.sh && \
    echo 'fi' >> /server/start.sh && \
    echo '' >> /server/start.sh && \
    echo 'if [ -d /data/world ] && [ "$(ls -A /data/world)" ]; then' >> /server/start.sh && \
    echo '  if [ ! -e world ]; then' >> /server/start.sh && \
    echo '    ln -s /data/world world' >> /server/start.sh && \
    echo '  fi' >> /server/start.sh && \
    echo '  ts "world_symlinked"' >> /server/start.sh && \ 
    echo 'else' >> /server/start.sh && \
    echo '  echo "Warning: No map loaded in /data/world, server will generate default world"' >> /server/start.sh && \
    echo 'fi' >> /server/start.sh && \
    echo '' >> /server/start.sh && \
    echo '# region agent log' >> /server/start.sh && \
    echo 'mkdir -p /data/config' >> /server/start.sh && \
    echo 'if [ -n "${MAP_METADATA:-}" ]; then' >> /server/start.sh && \
    echo '  printf "%s\n" "$MAP_METADATA" > /data/config/map-metadata.json' >> /server/start.sh && \
    echo '  ts "map_metadata_written_from_env"' >> /server/start.sh && \
    echo 'elif [ -f /data/config/map-metadata.json ]; then' >> /server/start.sh && \
    echo '  ts "map_metadata_file_present"' >> /server/start.sh && \
    echo 'else' >> /server/start.sh && \
    echo '  echo "[STARTUP] map_metadata_missing env_and_file"' >> /server/start.sh && \
    echo 'fi' >> /server/start.sh && \
    echo '# endregion' >> /server/start.sh && \
    echo '' >> /server/start.sh && \
    echo 'echo "========================================"' >> /server/start.sh && \
    echo 'echo "Starting TurfWars Server"' >> /server/start.sh && \
    echo 'echo "Server Type: turfwars"' >> /server/start.sh && \
    echo 'echo "Plugins: $(ls -1 /server/plugins/*.jar 2>/dev/null | wc -l)"' >> /server/start.sh && \
    echo 'if [ -d /data/config ]; then' >> /server/start.sh && \
    echo '  echo "Config files: $(ls -1 /data/config/*.json /data/config/*.yml 2>/dev/null | wc -l)"' >> /server/start.sh && \
    echo 'fi' >> /server/start.sh && \
    echo 'echo "Memory: ${MEMORY:-2G}"' >> /server/start.sh && \
    echo 'echo "========================================"' >> /server/start.sh && \
    echo '' >> /server/start.sh && \
    echo 'ts "jvm_launch"' >> /server/start.sh && \
    echo 'exec java -Xmx${MEMORY:-2G} -Xms512M \' >> /server/start.sh && \
    echo '  -XX:+UseG1GC \' >> /server/start.sh && \
    echo '  -XX:+ParallelRefProcEnabled \' >> /server/start.sh && \
    echo '  -XX:MaxGCPauseMillis=200 \' >> /server/start.sh && \
    echo '  -XX:+UnlockExperimentalVMOptions \' >> /server/start.sh && \
    echo '  -XX:+DisableExplicitGC \' >> /server/start.sh && \
    echo '  -XX:G1NewSizePercent=30 \' >> /server/start.sh && \
    echo '  -XX:G1MaxNewSizePercent=40 \' >> /server/start.sh && \
    echo '  -XX:G1HeapRegionSize=8M \' >> /server/start.sh && \
    echo '  -XX:G1ReservePercent=20 \' >> /server/start.sh && \
    echo '  -XX:G1HeapWastePercent=5 \' >> /server/start.sh && \
    echo '  -XX:G1MixedGCCountTarget=4 \' >> /server/start.sh && \
    echo '  -XX:InitiatingHeapOccupancyPercent=15 \' >> /server/start.sh && \
    echo '  -XX:G1MixedGCLiveThresholdPercent=90 \' >> /server/start.sh && \
    echo '  -XX:G1RSetUpdatingPauseTimePercent=5 \' >> /server/start.sh && \
    echo '  -XX:SurvivorRatio=32 \' >> /server/start.sh && \
    echo '  -XX:MaxTenuringThreshold=1 \' >> /server/start.sh && \
    echo '  -Dusing.aikars.flags=https://mcflags.emc.gs \' >> /server/start.sh && \
    echo '  -Daikars.new.flags=true \' >> /server/start.sh && \
    echo '  -Xlog:gc*=info:stdout:time,uptimemillis,level,tags \' >> /server/start.sh && \
    echo '  -jar server.jar nogui' >> /server/start.sh && \
    chmod +x /server/start.sh

ENTRYPOINT ["/server/start.sh"]
