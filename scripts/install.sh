#!/bin/bash

PROJECT_DIR="/Users/thomas/Documents/randomcode/anicat"
APP_NAME="Anicat.app"
INSTALL_DIR="$HOME/Applications"

echo "🚀 Installing Anicat Desktop App..."

# 1. Save current project path
echo "$PROJECT_DIR" > "$HOME/.anicat_path"
echo "✅ Project path saved to $HOME/.anicat_path"

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
