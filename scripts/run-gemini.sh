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
USE_VISUAL="${9:-false}"     # use visual interface instead of yolo mode
ENABLE_LOGGING="${10:-false}" # enable detailed gemini action logging

LOGGING_INFO=""
if [ "$ENABLE_LOGGING" = "true" ]; then
  LOGGING_INFO=" 📋 LOGGING ENABLED"
fi

if [ ! -z "$CUSTOM_LLM_PROXY" ]; then
  echo "🚀 Starting Gemini CLI $PHASE with CUSTOM LLM via proxy: $(basename "$CUSTOM_LLM_PROXY")$LOGGING_INFO"
else
  if [ "$USE_VISUAL" = "true" ]; then
    echo "🚀 Starting Gemini CLI $PHASE with model $MODEL (VISUAL INTERFACE)$LOGGING_INFO"
  else
    echo "🚀 Starting Gemini CLI $PHASE with model $MODEL (auto-approve tools)$LOGGING_INFO"
  fi
fi

# Clean up previous files  
rm -f "$OUTPUT_DIR/response.md"
rm -f "$OUTPUT_DIR"/response-log_*.txt
rm -f "$OUTPUT_DIR"/*-prompt-combined.md
rm -f "$OUTPUT_DIR"/gemini-actions*.log
rm -f "$OUTPUT_DIR"/gemini-telemetry*.json
rm -f temp/*.log
rm -f temp/gemini-realtime-*.log

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

# Set autoAccept based on visual mode
if [ "$USE_VISUAL" = "true" ]; then
    AUTO_ACCEPT="false"
else
    AUTO_ACCEPT="true"
fi

cat > ~/.gemini/settings.json << EOF
{
  "maxSessionTurns": -1,
  "autoAccept": $AUTO_ACCEPT,
  "hideTips": true,
  "hideBanner": true,
  "showLineNumbers": true,
  "chatCompression": {
    "contextPercentageThreshold": 0.8
  },
  "usageStatisticsEnabled": false,
  "telemetry": {
    "enabled": $([ "$ENABLE_LOGGING" = "true" ] && echo "true" || echo "false"),
    "target": "local",
    "logPrompts": true
  }
}
EOF

# Validate custom LLM proxy if provided
if [ ! -z "$CUSTOM_LLM_PROXY" ]; then
    if [ ! -f "$CUSTOM_LLM_PROXY" ]; then
        echo "❌ ERROR: Custom LLM proxy script not found: $CUSTOM_LLM_PROXY"
        exit 1
    fi
    
    echo "🔗 Runtime proxy script found: $(basename "$CUSTOM_LLM_PROXY")"
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
    RULES_SCRIPT="../agentic-workflows/scripts/aggregate-rules.sh"
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

# Set up logging files if enabled
TELEMETRY_LOG_FILE=""
GEMINI_TELEMETRY_FLAGS=""
if [ "$ENABLE_LOGGING" = "true" ]; then
    TELEMETRY_LOG_FILE="$OUTPUT_DIR/gemini-telemetry_${TIMESTAMP}.json"
    GEMINI_TELEMETRY_FLAGS="--telemetry --telemetry-target=local --telemetry-otlp-endpoint=\"\" --telemetry-outfile=\"$TELEMETRY_LOG_FILE\""
    echo "📋 Telemetry logging enabled - will write to: $TELEMETRY_LOG_FILE"
fi

echo "🚀 Executing Gemini CLI with auto-approval..."

# Set Node.js options to handle event listener limits
export NODE_OPTIONS="--max-old-space-size=4096 --max-http-header-size=8192"

# Configure debug modes based on environment variable from workflow
if [ "${GEMINI_DEBUG_ENABLED:-false}" = "true" ]; then
  export DEBUG=1
  export DEBUG_MODE=1
  GEMINI_DEBUG_FLAG="--debug"
  echo "🔍 DEBUG mode ENABLED - Gemini CLI will output debug information"
else
  GEMINI_DEBUG_FLAG=""
  echo "🔇 DEBUG mode DISABLED - Clean output mode"
fi

# Set approval mode based on visual flag
if [ "$USE_VISUAL" = "true" ]; then
    APPROVAL_MODE=""  # No approval mode for visual interface
else
    APPROVAL_MODE="--approval-mode yolo"
fi

# Create temporary log file for capturing output while showing real-time
TEMP_LOG_FILE="temp/gemini-realtime-${TIMESTAMP}.log"
mkdir -p temp

# Execute Gemini CLI with or without runtime proxy
if [ ! -z "$CUSTOM_LLM_PROXY" ] && [ -f "$CUSTOM_LLM_PROXY" ]; then
    echo "🔄 Using runtime proxy with fetch patching..."
    echo "🎯 Proxy file: $CUSTOM_LLM_PROXY"
    if [ "$USE_VISUAL" = "true" ]; then
        echo "🎨 Using visual interface mode"
    fi
    echo "💭 Showing thinking process in real-time..."
    echo "---"
    
    # Use tee to both display and capture output
    node --require "$CUSTOM_LLM_PROXY" $(which gemini) $GEMINI_DEBUG_FLAG $APPROVAL_MODE $GEMINI_TELEMETRY_FLAGS --prompt "$COMBINED_PROMPT_CONTENT" 2>&1 | tee "$TEMP_LOG_FILE"
    GEMINI_EXIT_CODE=${PIPESTATUS[0]}
    USE_RUNTIME_PROXY=true
    
    echo "---"
    
    if [ $GEMINI_EXIT_CODE -ne 0 ]; then
        echo "❌ Runtime proxy failed with exit code: $GEMINI_EXIT_CODE"
        if [ -f "$TEMP_LOG_FILE" ]; then
            echo "❌ Error output from log:"
            tail -20 "$TEMP_LOG_FILE"
        fi
        exit 1
    fi
else
    echo "🔄 Using standard Gemini CLI..."
    if [ "$USE_VISUAL" = "true" ]; then
        echo "🎨 Using visual interface mode"
    fi
    echo "💭 Showing thinking process in real-time..."
    echo "---"
    
    # Use tee to both display and capture output
    gemini $GEMINI_DEBUG_FLAG $APPROVAL_MODE $GEMINI_TELEMETRY_FLAGS --prompt "$COMBINED_PROMPT_CONTENT" 2>&1 | tee "$TEMP_LOG_FILE"
    GEMINI_EXIT_CODE=${PIPESTATUS[0]}
    USE_RUNTIME_PROXY=false
    
    echo "---"
    
    if [ $GEMINI_EXIT_CODE -ne 0 ]; then
        echo "❌ Gemini CLI failed with exit code: $GEMINI_EXIT_CODE"
        if [ -f "$TEMP_LOG_FILE" ]; then
            echo "❌ Error output from log:"
            tail -20 "$TEMP_LOG_FILE"
        fi
        exit 1
    fi
fi

# Read the captured output for logging purposes
if [ -f "$TEMP_LOG_FILE" ]; then
    GEMINI_RESPONSE=$(cat "$TEMP_LOG_FILE")
else
    GEMINI_RESPONSE="No output captured"
fi

echo "✅ Gemini CLI execution successful"
    
# Check if Gemini CLI created the response.md file
if [ ! -f "$RESPONSE_FILE" ]; then
    echo "⚠️ Warning: Gemini CLI did not create response.md file"
    echo "📝 Creating empty response.md as placeholder"
    touch "$RESPONSE_FILE"
else
    echo "✅ Found response.md created by Gemini CLI ($(wc -c < "$RESPONSE_FILE") bytes)"
fi

# Create detailed log file for debugging
{
    echo "=== GEMINI CLI EXECUTION LOG ==="
    echo "Phase: $PHASE"
    echo "Model: $MODEL"
    echo "Use Vertex AI: $USE_VERTEX_AI"
    echo "Use Gemini Code Assist: $USE_GCA"
    echo "Logging Enabled: $ENABLE_LOGGING"
    echo "Timestamp: $TIMESTAMP"
    if [ ! -z "$TELEMETRY_LOG_FILE" ]; then
        echo "Telemetry Log: $TELEMETRY_LOG_FILE"
    fi
    echo "=== USER REQUEST CONTENT ==="
    cat "$USER_REQUEST_FILE"
    echo "=== END USER REQUEST ==="
    echo "=== GEMINI CLI RESPONSE ==="
    echo "$GEMINI_RESPONSE"
    echo "=== GEMINI EXIT CODE: $GEMINI_EXIT_CODE ==="
    echo "=== EXECUTION END ==="
} > "$RESPONSE_LOG_FILE"

# Process telemetry log if enabled and file exists
if [ "$ENABLE_LOGGING" = "true" ] && [ -f "$TELEMETRY_LOG_FILE" ]; then
    echo "📋 Processing telemetry data..."
    
    # Create summary of actions from telemetry log
    ACTIONS_SUMMARY_FILE="$OUTPUT_DIR/gemini-actions-summary_${TIMESTAMP}.md"
    {
        echo "# Gemini Actions Summary"
        echo ""
        echo "**Execution Time:** $(date)"
        echo "**Phase:** $PHASE"
        echo "**Model:** $MODEL"
        echo ""
        echo "## File Operations"
        echo ""
        # Extract file operations using jq if available
        if command -v jq >/dev/null 2>&1; then
            jq -r '
            select(.name == "gemini_cli.tool_call" and .attributes.function_name == "write_file") |
            "- **WRITE**: \(.attributes.function_args.file_path // "unknown") (\(.attributes.success // false | if . then "✅ SUCCESS" else "❌ FAILED" end))"
            ' "$TELEMETRY_LOG_FILE" 2>/dev/null || echo "No write operations detected"
            
            jq -r '
            select(.name == "gemini_cli.tool_call" and .attributes.function_name == "read_file") |
            "- **READ**: \(.attributes.function_args.target_file // .attributes.function_args.file_path // "unknown") (\(.attributes.success // false | if . then "✅ SUCCESS" else "❌ FAILED" end))"
            ' "$TELEMETRY_LOG_FILE" 2>/dev/null || echo "No read operations detected"
            
            jq -r '
            select(.name == "gemini_cli.tool_call" and .attributes.function_name == "run_terminal_cmd") |
            "- **COMMAND**: \(.attributes.function_args.command // "unknown") (\(.attributes.success // false | if . then "✅ SUCCESS" else "❌ FAILED" end))"
            ' "$TELEMETRY_LOG_FILE" 2>/dev/null || echo "No command operations detected"
        else
            echo "jq not available - raw telemetry data saved to $TELEMETRY_LOG_FILE"
        fi
        echo ""
        echo "## Raw Telemetry Data"
        echo "Full telemetry log: \`$TELEMETRY_LOG_FILE\`"
    } > "$ACTIONS_SUMMARY_FILE"
    
    echo "✅ Actions summary created: $ACTIONS_SUMMARY_FILE"
    echo "📄 Full telemetry log: $TELEMETRY_LOG_FILE"
    
    # Output summary to console
    if [ -f "$ACTIONS_SUMMARY_FILE" ]; then
        echo ""
        echo "=== GEMINI ACTIONS SUMMARY ==="
        cat "$ACTIONS_SUMMARY_FILE"
        echo "=== END ACTIONS SUMMARY ==="
    fi
fi

# Output the response file path and exit code for use by calling script
echo "$RESPONSE_FILE"
exit $GEMINI_EXIT_CODE
