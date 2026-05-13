#!/bin/bash

# Configuration
PORT=8000
URL="http://localhost:$PORT"

# 1. Determine Project Directory
# First check if we have a saved path
CONFIG_FILE="$HOME/.anicat_path"
if [ -f "$CONFIG_FILE" ]; then
    PROJECT_DIR=$(cat "$CONFIG_FILE")
else
    # Fallback to relative path if no config
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
    PROJECT_DIR="$( dirname "$SCRIPT_DIR" )"
fi

# Validate directory
if [ ! -d "$PROJECT_DIR/anicat_media" ]; then
    echo "Error: Project directory not found at $PROJECT_DIR"
    exit 1
fi

cd "$PROJECT_DIR"

# 2. Start Backend
if ! lsof -i :$PORT > /dev/null; then
    echo "Starting Anicat Backend..."
    uv run python -m anicat_media.api.main > backend.log 2>&1 &
    
    # Wait for startup
    MAX_RETRIES=10
    RETRY_COUNT=0
    while ! lsof -i :$PORT > /dev/null && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        sleep 1
        RETRY_COUNT=$((RETRY_COUNT + 1))
    done
fi

# 3. Open Browser
open "$URL"
