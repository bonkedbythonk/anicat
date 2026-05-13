#!/bin/bash

# Find the project root dynamically (scripts/ parent directory)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Anicat.app"
INSTALL_DIR="$HOME/Applications"

echo "🚀 Installing Anicat Desktop App..."

# 1. Check for uv (Python manager)
if ! command -v uv &> /dev/null; then
    echo "📦 Installing 'uv' (Python manager)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    
    # Try to add to current path for the rest of the script
    export PATH="$HOME/.local/bin:$PATH"
fi

# 2. Sync dependencies
echo "📦 Setting up the environment and dependencies..."
echo "   (This may take a minute on the first install)"
if ! uv sync --quiet; then
    echo "❌ Error: Failed to install dependencies. Check your internet connection."
    exit 1
fi

# 3. Save current project path
echo "$PROJECT_DIR" > "$HOME/.anicat_path"
echo "✅ Environment ready."

# 2. Recreate the App bundle to ensure portability
cd "$PROJECT_DIR"
rm -rf "$APP_NAME"
osacompile -o "$APP_NAME" -e "do shell script \"$PROJECT_DIR/scripts/launch_anicat.sh > /dev/null 2>&1 &\""
echo "✅ App bundle created."

# 3. Copy to Applications
mkdir -p "$INSTALL_DIR"
cp -R "$APP_NAME" "$INSTALL_DIR/"
echo "✅ $APP_NAME copied to $INSTALL_DIR"

# 4. Success message
echo ""
echo "✨ Installation Complete! ✨"
echo "You can now find 'Anicat' in your Launchpad or Applications folder."
echo "Go ahead and drag it to your Dock for easy access!"
