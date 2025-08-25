#!/bin/bash

# setup-cli-env.sh - Setup environment for CLI tools (Aider/Gemini)
# Used by GitHub Actions for consistent environment setup

set -e

CLI_TOOL="$1"
MODEL="${2:-gemini/gemini-2.5-flash-preview-05-20}"
API_KEY="$3"

echo "🔧 Setting up $CLI_TOOL environment..."

# Create output directories
mkdir -p outputs
mkdir -p outputs/pr-summary

# Validate API key
if [ -z "$API_KEY" ]; then
    echo "ERROR: No API key provided"
    exit 1
fi

echo "✅ API key validation passed"

# Set up environment based on CLI tool
case "$CLI_TOOL" in
    "aider")
        echo "📦 Setting up Aider environment..."
        
        # Check if aider is already cached and working
        if command -v aider >/dev/null 2>&1 && aider --version >/dev/null 2>&1; then
            echo "✅ Aider found in cache and working, skipping installation"
            aider --version
        else
            echo "📦 Aider not found in cache or not working, installing..."
            pip install --upgrade pip
            pip install aider-install
            aider-install
            
            # Verify new installation
            echo "🔍 Verifying new Aider installation..."
            aider --version
            echo "✅ Aider installation verified"
        fi
        
        # Install additional dependencies for Gemini models
        pip install google-generativeai
        ;;
        
    "gemini")
        echo "📦 Setting up Gemini CLI environment..."
        
        # Check if Gemini CLI is already available
        if command -v gemini >/dev/null 2>&1; then
            echo "✅ Gemini CLI found in cache, verifying..."
            if gemini --version >/dev/null 2>&1; then
                echo "✅ Gemini CLI is working, skipping installation"
                gemini --version
            else
                echo "⚠️ Gemini CLI found but not working, reinstalling..."
            fi
        fi
        
        # Install Gemini CLI if not available or not working
        if ! command -v gemini >/dev/null 2>&1 || ! gemini --version >/dev/null 2>&1; then
            echo "📦 Installing Gemini CLI..."
            
            # Configure npm to use user directory for global installs
            mkdir -p ~/.npm-global
            npm config set prefix '~/.npm-global'
            export PATH="$HOME/.npm-global/bin:$PATH"
            
            # Add to both bashrc and GitHub Actions PATH
            echo "export PATH=\"\$HOME/.npm-global/bin:\$PATH\"" >> ~/.bashrc
            if [ -n "$GITHUB_PATH" ]; then
                echo "$HOME/.npm-global/bin" >> $GITHUB_PATH
            fi
            
            # Set npm registry and configuration to avoid 403 errors
            npm config set registry https://registry.npmjs.org/
            npm config set fetch-retries 5
            npm config set fetch-retry-mintimeout 20000
            npm config set fetch-retry-maxtimeout 120000
            
            # Try installation with retries
            max_attempts=3
            attempt=1
            
            while [ $attempt -le $max_attempts ]; do
                echo "📦 Installation attempt $attempt of $max_attempts..."
                
                if npm install -g @google/gemini-cli@latest --verbose; then
                    echo "✅ Gemini CLI installed successfully on attempt $attempt"
                    break
                elif [ $attempt -eq $max_attempts ]; then
                    echo "❌ Failed to install Gemini CLI after $max_attempts attempts"
                    echo "🔄 Trying alternative installation method..."
                    
                    # Alternative: Install without cache and with different registry
                    npm cache clean --force
                    npm install -g @google/gemini-cli@latest --no-cache --registry https://registry.npmjs.org/ --verbose
                    
                    if [ $? -eq 0 ]; then
                        echo "✅ Gemini CLI installed successfully via alternative method"
                        break
                    else
                        echo "❌ All installation methods failed"
                        exit 1
                    fi
                else
                    echo "⚠️ Attempt $attempt failed, retrying in 10 seconds..."
                    sleep 10
                fi
                
                attempt=$((attempt + 1))
            done
        fi
        
        # Verify installation and ensure PATH is set
        echo "📋 Gemini CLI version:"
        export PATH="$HOME/.npm-global/bin:$PATH"
        
        # Ensure gemini is available
        if ! command -v gemini >/dev/null 2>&1; then
            echo "⚠️ Gemini CLI not found in PATH, trying to locate..."
            if [ -f "$HOME/.npm-global/bin/gemini" ]; then
                echo "✅ Found Gemini CLI at $HOME/.npm-global/bin/gemini"
                "$HOME/.npm-global/bin/gemini" --version
            else
                echo "❌ Gemini CLI installation verification failed"
                ls -la "$HOME/.npm-global/bin/" || echo "Directory not found"
                exit 1
            fi
        else
            gemini --version
        fi
        
        # Create settings file for Gemini CLI
        mkdir -p .gemini
        cat > .gemini/settings.json << EOF
{
  "model": "$MODEL",
  "temperature": 0.1,
  "maxOutputTokens": 8192
}
EOF
        echo "✅ Gemini CLI settings configured"
        ;;
        
    *)
        echo "ERROR: Unknown CLI tool: $CLI_TOOL"
        echo "Supported tools: aider, gemini"
        exit 1
        ;;
esac

echo "✅ $CLI_TOOL environment setup complete"
