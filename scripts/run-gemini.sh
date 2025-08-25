#!/bin/bash

# run-gemini.sh - Execute Gemini CLI with specified parameters
# Features:
# - Prompt preparation and execution
# - Real-time quota exhaustion detection (stops retry loops immediately)
# - Enhanced tool call visibility with emoji indicators
# - Configurable execution timeout (default: 30 minutes)
# - Smart output filtering (debug vs thinking mode)

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

# Set timeout for Gemini CLI execution (30 minutes max)
GEMINI_TIMEOUT=${GEMINI_TIMEOUT:-1800}  # 30 minutes default
echo "⏰ Setting execution timeout: ${GEMINI_TIMEOUT} seconds"

# Set Node.js options to handle event listener limits and force unbuffered output
export NODE_OPTIONS="--max-old-space-size=4096 --max-http-header-size=8192"

# Force unbuffered output for real-time thinking process display
export PYTHONUNBUFFERED=1

# Configure debug modes based on environment variable from workflow
# By default, disable debug to show thinking process clearly
if [ "${GEMINI_DEBUG_ENABLED:-false}" = "true" ]; then
  GEMINI_DEBUG_FLAG="--debug"
  echo "🔍 DEBUG mode ENABLED - Technical debug information will be shown"
else
  GEMINI_DEBUG_FLAG=""
  echo "💭 THINKING mode ENABLED - Showing Gemini thinking process"
fi

# Don't export DEBUG variables as they pollute output with technical logs
# We want to see thinking process, not internal debug information
unset DEBUG
unset DEBUG_MODE

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
    
    # Execute with timeout, real-time quota monitoring and tool visibility
    (
      timeout "$GEMINI_TIMEOUT" stdbuf -oL -eL node --require "$CUSTOM_LLM_PROXY" $(which gemini) $GEMINI_DEBUG_FLAG $APPROVAL_MODE $GEMINI_TELEMETRY_FLAGS --prompt "$COMBINED_PROMPT_CONTENT" 2>&1 | \
      while IFS= read -r line; do
        # Real-time quota exhaustion detection - TERMINATE IMMEDIATELY
        if echo "$line" | grep -q "status 429\|RESOURCE_EXHAUSTED\|quota.*exceeded\|Retrying with backoff"; then
          echo ""
          echo "🚨 QUOTA LIMIT DETECTED IN REAL-TIME - TERMINATING PROCESS"
          echo "💳 QUOTA EXHAUSTED: API quota limit reached"
          echo "❌ Error: Gemini API quota has been exceeded"
          echo "📋 Details: Please check your billing and quota limits"
          echo "⏰ Try again later when quota resets or upgrade your plan"
          
          # Kill the gemini process to stop retry loops
          pkill -f "gemini.*--prompt" 2>/dev/null || true
          exit 429
        fi
        
        # Show line with smart filtering
        if [ "${GEMINI_DEBUG_ENABLED:-false}" = "true" ]; then
          # Debug mode: show everything
          echo "$line"
        else
          # Filter noise but keep tool calls and thinking process visible
          if echo "$line" | grep -v -E '^\[DEBUG\]|MaxListenersExceededWarning|Use.*node.*trace-warnings|Possible EventTarget memory leak' >/dev/null; then
            # Highlight different types of operations for better visibility
            if echo "$line" | grep -q "Error executing tool"; then
              echo "❌ TOOL ERROR: $line"
            elif echo "$line" | grep -q "executing tool.*read_file\|reading file"; then
              echo "📖 READ: $line"
            elif echo "$line" | grep -q "executing tool.*write\|executing tool.*edit\|writing file\|editing file"; then
              echo "✏️ WRITE: $line"
            elif echo "$line" | grep -q "executing tool.*run_terminal_cmd\|running command"; then
              echo "💻 CMD: $line"
            elif echo "$line" | grep -q "executing tool"; then
              echo "🔧 TOOL: $line"
            elif echo "$line" | grep -q "✅\|❌\|SUCCESS\|FAILED"; then
              echo "📋 STATUS: $line"
            else
              echo "$line"
            fi
          fi
        fi
        
        # Always save to log file
        echo "$line" >> "$TEMP_LOG_FILE"
      done
    )
    GEMINI_EXIT_CODE=$?
    
    # Check for quota exhausted errors in the output
    if [ -f "$TEMP_LOG_FILE" ] && grep -q "RESOURCE_EXHAUSTED\|quota.*exceeded\|status.*429" "$TEMP_LOG_FILE"; then
      echo ""
      echo "💳 QUOTA EXHAUSTED: API quota limit reached"
      echo "❌ Error: Gemini API quota has been exceeded"
      echo "📋 Details: Please check your billing and quota limits at:"
      echo "    https://ai.google.dev/gemini-api/docs/rate-limits"
      echo "⏰ Try again later when quota resets or upgrade your plan"
      GEMINI_EXIT_CODE=429  # Set specific exit code for quota issues
    fi
    USE_RUNTIME_PROXY=true
    
    echo "---"
    
    if [ $GEMINI_EXIT_CODE -ne 0 ]; then
        if [ $GEMINI_EXIT_CODE -eq 429 ]; then
            echo "💳 Quota exhausted - stopping execution to prevent infinite retry loop"
            exit 429
        elif [ $GEMINI_EXIT_CODE -eq 124 ]; then
            echo "⏰ TIMEOUT: Gemini CLI execution exceeded ${GEMINI_TIMEOUT} seconds"
            echo "🔄 Recommendation: Reduce prompt complexity or increase timeout"
            exit 124
        else
            echo "❌ Runtime proxy failed with exit code: $GEMINI_EXIT_CODE"
            if [ -f "$TEMP_LOG_FILE" ]; then
                echo "❌ Error output from log:"
                tail -20 "$TEMP_LOG_FILE"
            fi
            exit 1
        fi
    fi
else
    echo "🔄 Using standard Gemini CLI..."
    if [ "$USE_VISUAL" = "true" ]; then
        echo "🎨 Using visual interface mode"
    fi
    echo "💭 Showing thinking process in real-time..."
    echo "---"
    
    # Execute with timeout, real-time quota monitoring and tool visibility
    (
      timeout "$GEMINI_TIMEOUT" stdbuf -oL -eL gemini $GEMINI_DEBUG_FLAG $APPROVAL_MODE $GEMINI_TELEMETRY_FLAGS --prompt "$COMBINED_PROMPT_CONTENT" 2>&1 | \
      while IFS= read -r line; do
        # Real-time quota exhaustion detection - TERMINATE IMMEDIATELY
        if echo "$line" | grep -q "status 429\|RESOURCE_EXHAUSTED\|quota.*exceeded\|Retrying with backoff"; then
          echo ""
          echo "🚨 QUOTA LIMIT DETECTED IN REAL-TIME - TERMINATING PROCESS"
          echo "💳 QUOTA EXHAUSTED: API quota limit reached"
          echo "❌ Error: Gemini API quota has been exceeded"
          echo "📋 Details: Please check your billing and quota limits"
          echo "⏰ Try again later when quota resets or upgrade your plan"
          
          # Kill the gemini process to stop retry loops
          pkill -f "gemini.*--prompt" 2>/dev/null || true
          exit 429
        fi
        
        # Show line with smart filtering
        if [ "${GEMINI_DEBUG_ENABLED:-false}" = "true" ]; then
          # Debug mode: show everything
          echo "$line"
        else
          # Filter noise but keep tool calls and thinking process visible
          if echo "$line" | grep -v -E '^\[DEBUG\]|MaxListenersExceededWarning|Use.*node.*trace-warnings|Possible EventTarget memory leak' >/dev/null; then
            # Highlight different types of operations for better visibility
            if echo "$line" | grep -q "Error executing tool"; then
              echo "❌ TOOL ERROR: $line"
            elif echo "$line" | grep -q "executing tool.*read_file\|reading file"; then
              echo "📖 READ: $line"
            elif echo "$line" | grep -q "executing tool.*write\|executing tool.*edit\|writing file\|editing file"; then
              echo "✏️ WRITE: $line"
            elif echo "$line" | grep -q "executing tool.*run_terminal_cmd\|running command"; then
              echo "💻 CMD: $line"
            elif echo "$line" | grep -q "executing tool"; then
              echo "🔧 TOOL: $line"
            elif echo "$line" | grep -q "✅\|❌\|SUCCESS\|FAILED"; then
              echo "📋 STATUS: $line"
            else
              echo "$line"
            fi
          fi
        fi
        
        # Always save to log file
        echo "$line" >> "$TEMP_LOG_FILE"
      done
    )
    GEMINI_EXIT_CODE=$?
    
    # Check for quota exhausted errors in the output
    if [ -f "$TEMP_LOG_FILE" ] && grep -q "RESOURCE_EXHAUSTED\|quota.*exceeded\|status.*429" "$TEMP_LOG_FILE"; then
      echo ""
      echo "💳 QUOTA EXHAUSTED: API quota limit reached"
      echo "❌ Error: Gemini API quota has been exceeded"
      echo "📋 Details: Please check your billing and quota limits at:"
      echo "    https://ai.google.dev/gemini-api/docs/rate-limits"
      echo "⏰ Try again later when quota resets or upgrade your plan"
      GEMINI_EXIT_CODE=429  # Set specific exit code for quota issues
    fi
    USE_RUNTIME_PROXY=false
    
    echo "---"
    
    if [ $GEMINI_EXIT_CODE -ne 0 ]; then
        if [ $GEMINI_EXIT_CODE -eq 429 ]; then
            echo "💳 Quota exhausted - stopping execution to prevent infinite retry loop"
            exit 429
        elif [ $GEMINI_EXIT_CODE -eq 124 ]; then
            echo "⏰ TIMEOUT: Gemini CLI execution exceeded ${GEMINI_TIMEOUT} seconds"
            echo "🔄 Recommendation: Reduce prompt complexity or increase timeout"
            exit 124
        else
            echo "❌ Gemini CLI failed with exit code: $GEMINI_EXIT_CODE"
            if [ -f "$TEMP_LOG_FILE" ]; then
                echo "❌ Error output from log:"
                tail -20 "$TEMP_LOG_FILE"
            fi
            exit 1
        fi
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
