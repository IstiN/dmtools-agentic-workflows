#!/bin/bash

# run-gemini.sh - Execute Gemini CLI with specified parameters
# Handles prompt preparation and execution

set -e

# Parameters
PHASE="$1"              # discovery or implementation
USER_REQUEST_FILE="$2"
RULES_FOLDER="$3"       # optional folder with .mdc rules files
MODEL="${4:-gemini-2.5-flash-preview-05-20}"
USE_VERTEX_AI="${5:-false}"
USE_GCA="${6:-false}"
OUTPUT_DIR="${7:-outputs}"
CUSTOM_LLM_PROXY="${8:-}"   # optional custom LLM proxy script (JS/Python)

if [ ! -z "$CUSTOM_LLM_PROXY" ]; then
  echo "🚀 Starting Gemini CLI $PHASE with CUSTOM LLM via proxy: $(basename "$CUSTOM_LLM_PROXY")"
else
  echo "🚀 Starting Gemini CLI $PHASE with model $MODEL (auto-approve tools)"
fi

# Clean up previous files  
rm -f "$OUTPUT_DIR/response.md"
rm -f "$OUTPUT_DIR"/response-log_*.txt
rm -f "$OUTPUT_DIR"/*-prompt-combined.md

# Validate phase
case "$PHASE" in
    "discovery"|"implementation")
        ;;
    *)
        echo "ERROR: Invalid phase '$PHASE'. Must be 'discovery' or 'implementation'"
        exit 1
        ;;
esac

# Set environment variables for Gemini CLI
export GOOGLE_GENAI_USE_VERTEXAI="$USE_VERTEX_AI"
export GOOGLE_GENAI_USE_GCA="$USE_GCA"

# Configure Gemini CLI for optimal performance
mkdir -p ~/.gemini

cat > ~/.gemini/settings.json << 'EOF'
{
  "maxSessionTurns": -1,
  "autoAccept": true,
  "hideTips": true,
  "hideBanner": true,
  "showLineNumbers": true,
  "chatCompression": {
    "contextPercentageThreshold": 0.8
  },
  "usageStatisticsEnabled": false,
  "telemetry": {
    "enabled": false
  }
}
EOF

# Setup custom LLM proxy if provided
PROXY_PID=""
PROXY_PORT=""
if [ ! -z "$CUSTOM_LLM_PROXY" ]; then
    if [ ! -f "$CUSTOM_LLM_PROXY" ]; then
        echo "❌ ERROR: Custom LLM proxy script not found: $CUSTOM_LLM_PROXY"
        exit 1
    fi
    
    echo "🔗 Setting up custom LLM proxy..."
    
    # Find available port
    PROXY_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('', 0)); print(s.getsockname()[1]); s.close()")
    
    # Start proxy based on file extension
    case "$CUSTOM_LLM_PROXY" in
        *.js)
            echo "🟨 Starting JavaScript proxy on port $PROXY_PORT..."
            node "$CUSTOM_LLM_PROXY" --port "$PROXY_PORT" &
            PROXY_PID=$!
            ;;
        *.py)
            echo "🐍 Starting Python proxy on port $PROXY_PORT..."
            python3 "$CUSTOM_LLM_PROXY" --port "$PROXY_PORT" &
            PROXY_PID=$!
            ;;
        *)
            echo "❌ ERROR: Unsupported proxy script format. Use .js or .py files."
            exit 1
            ;;
    esac
    
    # Wait for proxy to start
    echo "⏳ Waiting for proxy to start..."
    sleep 2
    
    # Test proxy connectivity
    if ! curl -s --max-time 5 "http://localhost:$PROXY_PORT/health" > /dev/null 2>&1; then
        echo "⚠️ WARNING: Proxy health check failed. Continuing anyway..."
    else
        echo "✅ Proxy is ready on port $PROXY_PORT"
    fi
    
    # Set environment variable for Gemini CLI to use proxy
    export HTTP_PROXY="http://localhost:$PROXY_PORT"
    export HTTPS_PROXY="http://localhost:$PROXY_PORT"
    
    # Function to cleanup proxy on exit
    cleanup_proxy() {
        if [ ! -z "$PROXY_PID" ]; then
            echo "🧹 Cleaning up proxy (PID: $PROXY_PID)..."
            kill "$PROXY_PID" 2>/dev/null || true
            wait "$PROXY_PID" 2>/dev/null || true
        fi
    }
    
    # Register cleanup function
    trap cleanup_proxy EXIT
fi

# Prepare prompt file based on phase
PROMPTS_PATH=${PROMPTS_PATH:-"./prompts"}
PROMPT_FILE="$PROMPTS_PATH/${PHASE}-prompt.md"
COMBINED_PROMPT_FILE="$OUTPUT_DIR/${PHASE}-prompt-combined.md"

if [ ! -f "$PROMPT_FILE" ]; then
    echo "ERROR: Prompt file not found: $PROMPT_FILE"
    exit 1
fi

if [ ! -f "$USER_REQUEST_FILE" ]; then
    echo "ERROR: User request file not found: $USER_REQUEST_FILE"
    exit 1
fi

# Read the prompt content
PROMPT_CONTENT=$(cat "$PROMPT_FILE")

# Read user request content  
USER_REQUEST=$(cat "$USER_REQUEST_FILE")

# Aggregate rules if rules folder is provided
RULES_CONTENT=""
if [ ! -z "$RULES_FOLDER" ] && [ -d "$RULES_FOLDER" ]; then
    RULES_SCRIPT="cli_agents/scripts/aggregate-rules.sh"
    if [ -f "$RULES_SCRIPT" ]; then
        RULES_CONTENT=$(bash "$RULES_SCRIPT" "$RULES_FOLDER" 2>/dev/null | grep -v "📋\|📄\|⚠️" || echo "")
    fi
fi

if [ "$PHASE" = "discovery" ]; then
    # Discovery phase prompt - use the template with user request
    CURRENT_DIR=$(pwd)
    cat > "$COMBINED_PROMPT_FILE" << EOF
# User Request Analysis

**Working Directory:** $CURRENT_DIR

**User Request:**
\`\`\`
$USER_REQUEST
\`\`\`

$(if [ ! -z "$RULES_CONTENT" ]; then
echo "---"
echo ""
echo "$RULES_CONTENT"
echo ""
fi)

---

$PROMPT_CONTENT
EOF

elif [ "$PHASE" = "implementation" ]; then
    # Implementation phase prompt
    cat > "$COMBINED_PROMPT_FILE" << EOF
# Implementation Phase

**User Request:**
\`\`\`
$USER_REQUEST
\`\`\`

$(if [ ! -z "$RULES_CONTENT" ]; then
echo "---"
echo ""
echo "$RULES_CONTENT"
echo ""
fi)

---

$PROMPT_CONTENT
EOF

fi

# Read the combined prompt content
COMBINED_PROMPT_CONTENT=$(cat "$COMBINED_PROMPT_FILE")

# Create output file for response
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESPONSE_FILE="$OUTPUT_DIR/response.md"
RESPONSE_LOG_FILE="$OUTPUT_DIR/response-log_${TIMESTAMP}.txt"

echo "🚀 Executing Gemini CLI with auto-approval..."

# Set Node.js options to handle event listener limits
export NODE_OPTIONS="--max-old-space-size=4096 --max-http-header-size=8192"

# Configure debug modes based on environment variable from workflow
if [ "${GEMINI_DEBUG_ENABLED:-true}" = "true" ]; then
  export DEBUG=1
  export DEBUG_MODE=1
  GEMINI_DEBUG_FLAG="--debug"
else
  GEMINI_DEBUG_FLAG=""
fi

if GEMINI_RESPONSE=$(gemini $GEMINI_DEBUG_FLAG --approval-mode yolo --prompt "$COMBINED_PROMPT_CONTENT" 2>&1); then
    GEMINI_EXIT_CODE=0
    echo "✅ Gemini CLI execution successful"
    
    # Check if Gemini created the response.md file itself
    if [ ! -f "$RESPONSE_FILE" ]; then
        # Fallback: create response file from Gemini output (cleaned)
        echo "$GEMINI_RESPONSE" | sed '/^(node:[0-9]*)/d' | sed '/Both GOOGLE_API_KEY and GEMINI_API_KEY are set/d' > "$RESPONSE_FILE"
    fi
else
    GEMINI_EXIT_CODE=$?
    echo "❌ ERROR: Gemini CLI failed with exit code $GEMINI_EXIT_CODE"
    
    # Write error response to markdown file
    cat > "$RESPONSE_FILE" << EOF
# Error Response

**Generated:** $(date)
**Phase:** $PHASE
**Model:** $MODEL
**Exit Code:** $GEMINI_EXIT_CODE

---

## Error Output:
\`\`\`
$GEMINI_RESPONSE
\`\`\`
EOF
fi

# Create detailed log file for debugging
{
    echo "=== GEMINI CLI EXECUTION LOG ==="
    echo "Phase: $PHASE"
    echo "Model: $MODEL"
    echo "Use Vertex AI: $USE_VERTEX_AI"
    echo "Use Gemini Code Assist: $USE_GCA"
    echo "Timestamp: $TIMESTAMP"
    echo "=== USER REQUEST CONTENT ==="
    cat "$USER_REQUEST_FILE"
    echo "=== END USER REQUEST ==="
    echo "=== GEMINI CLI RESPONSE ==="
    echo "$GEMINI_RESPONSE"
    echo "=== GEMINI EXIT CODE: $GEMINI_EXIT_CODE ==="
    echo "=== EXECUTION END ==="
} > "$RESPONSE_LOG_FILE"

# Output the response file path and exit code for use by calling script
echo "$RESPONSE_FILE"
exit $GEMINI_EXIT_CODE
