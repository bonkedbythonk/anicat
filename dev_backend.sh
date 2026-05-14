#!/bin/bash
# Shortcut to start the Anicat backend with auto-reload enabled
echo "Starting Anicat Backend with Auto-Reload..."
uv run uvicorn anicat_media.api.main:create_app --factory --reload --port 8000
