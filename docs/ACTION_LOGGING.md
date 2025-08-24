# Gemini Action Logging

This document describes how to enable and use detailed action logging for Gemini CLI in autonomous mode, allowing you to track exactly what Gemini does during code implementation.

## Overview

The action logging feature uses Gemini CLI's built-in telemetry system to capture detailed information about all operations performed by the AI, including file operations, shell commands, and API interactions.

## Features

### 🎯 **What Gets Logged**

- **File Operations**: Every `write_file`, `read_file`, `edit` operation with file paths and success status
- **Shell Commands**: All `run_terminal_cmd` executions with command details and results
- **API Requests**: Gemini API interactions with token usage and response times
- **Tool Calls**: All function calls with parameters, duration, and outcomes
- **Error Handling**: Failed operations with detailed error information

### 📊 **Output Files**

When logging is enabled, the following files are generated:

1. **Raw Telemetry Log**: `gemini-telemetry_TIMESTAMP.json`
   - Complete OpenTelemetry data in JSON format
   - Contains all API calls, tool executions, and metrics

2. **Actions Summary**: `gemini-actions-summary_TIMESTAMP.md`
   - Human-readable summary of key operations
   - Organized by operation type (file operations, commands, etc.)
   - Success/failure status for each operation

3. **Enhanced Response Log**: `response-log_TIMESTAMP.txt`
   - Includes telemetry file paths in execution log

## Usage

### 🔧 **Enable in Reusable Workflow**

Add `enable_action_logging: true` to your workflow call:

```yaml
uses: IstiN/dmtools-agentic-workflows/.github/workflows/reusable-gemini-implementation.yml@main
with:
  user_request: ${{ inputs.user_request }}
  model: ${{ inputs.model }}
  enable_action_logging: true  # ← Enable detailed logging
secrets:
  GEMINI_API_KEY: ${{ secrets.GEMINI_API_KEY }}
  PAT_TOKEN: ${{ secrets.PAT_TOKEN }}
```

### 🚀 **Direct Script Usage**

Use the `run-gemini.sh` script with the logging parameter:

```bash
# Enable logging (10th parameter = true)
./scripts/run-gemini.sh "implementation" "user-request.txt" ".cursor/rules" "gemini-2.5-flash-preview-05-20" false false "outputs" "" false true

# Parameters:
# 1. Phase: "implementation" or "discovery"  
# 2. User request file
# 3. Rules folder path
# 4. Model name
# 5. Use Vertex AI (false/true)
# 6. Use GCA (false/true)
# 7. Output directory
# 8. Custom LLM proxy (empty for standard)
# 9. Use visual mode (false/true)
# 10. Enable logging (false/true) ← NEW PARAMETER
```

### 📝 **Example: DMTools Auto-Fix with Logging**

```yaml
# In dmtools auto-fix workflow
uses: IstiN/dmtools-agentic-workflows/.github/workflows/reusable-gemini-implementation.yml@main
with:
  user_request: ${{ needs.prepare-auto-fix-request.outputs.enhanced_request }}
  custom_implementation_prompt: 'auto-fix-test-failures-prompt.md'
  skip_pr_creation: true
  pr_base_branch: ${{ inputs.branch_name }}
  additional_context_files: '.cursor/rules/testing-context.mdc,.cursor/rules/java-coding-style.mdc'
  enable_action_logging: true  # ← Track what auto-fix does
```

## Log Analysis

### 🔍 **Reading Actions Summary**

The actions summary file provides a clean overview:

```markdown
# Gemini Actions Summary

**Execution Time:** 2025-01-24 10:30:00
**Phase:** implementation
**Model:** gemini-2.5-flash-preview-05-20

## File Operations

- **WRITE**: /path/to/modified/file.java (✅ SUCCESS)
- **READ**: /path/to/source/file.java (✅ SUCCESS)
- **COMMAND**: ./gradlew test --tests ClassName (❌ FAILED)

## Raw Telemetry Data
Full telemetry log: `outputs/gemini-telemetry_20250124_103000.json`
```

### 🧪 **Processing Raw Telemetry**

Extract specific information using `jq`:

```bash
# Get all file write operations
jq '.[] | select(.name == "gemini_cli.tool_call" and .attributes.function_name == "write_file")' telemetry.json

# Get command executions with exit codes
jq '.[] | select(.name == "gemini_cli.tool_call" and .attributes.function_name == "run_terminal_cmd") | {command: .attributes.function_args.command, success: .attributes.success}' telemetry.json

# Get API token usage
jq '.[] | select(.name == "gemini_cli.token.usage") | .attributes' telemetry.json
```

## Integration Examples

### 🤖 **Auto-Fix with Action Tracking**

```yaml
- name: Apply auto-fix with detailed tracking
  uses: IstiN/dmtools-agentic-workflows/.github/workflows/reusable-auto-fix-test-failures.yml@main
  with:
    failure_context: ${{ steps.extract-failure.outputs.failure_details }}
    branch_name: ${{ steps.extract-pr.outputs.branch_name }}
    workflow_run_url: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.event.workflow_run.id }}
    pr_number: ${{ steps.extract-pr.outputs.pr_number }}
    enable_action_logging: true
    additional_context_files: '.cursor/rules/testing-context.mdc,.cursor/rules/java-coding-style.mdc'
```

### 📊 **Post-Process Logs for PR Comments**

```bash
# Create summary for PR comment
echo "## 🤖 Auto-Fix Actions Summary" > pr-comment.md
echo "" >> pr-comment.md
if [ -f "outputs/gemini-actions-summary_*.md" ]; then
  cat outputs/gemini-actions-summary_*.md >> pr-comment.md
fi
```

## Performance Considerations

### 📈 **Impact**

- **Minimal Performance Impact**: Telemetry adds ~2-5% overhead
- **Storage**: Telemetry files are typically 50-500KB per execution
- **Retention**: Logs are kept for 7 days by default in CI artifacts

### ⚡ **When to Enable**

**Enable logging for:**
- ✅ Auto-fix workflows (track what got fixed)
- ✅ Complex implementations (understand decision flow)
- ✅ Debugging failed workflows
- ✅ Production deployments (audit trail)

**Disable logging for:**
- ❌ Simple, repetitive tasks
- ❌ Development/testing (unless debugging)
- ❌ Resource-constrained environments

## Troubleshooting

### 🔧 **Common Issues**

**Q: Telemetry file is empty**
A: Check that `jq` is available in the environment. Raw telemetry is still saved even if summary generation fails.

**Q: No telemetry files generated**
A: Verify `enable_action_logging: true` is set and Gemini CLI version supports telemetry (requires latest versions).

**Q: Permission denied writing telemetry**
A: Ensure the output directory has write permissions and sufficient disk space.

### 🐛 **Debug Mode**

Combine with debug logging for maximum visibility:

```yaml
with:
  enable_debug_logging: true     # Console debug output
  enable_action_logging: true    # Detailed action tracking
```

## Security Notes

### 🔒 **Sensitive Data**

- Telemetry logs may contain file paths and command arguments
- User prompts are logged if `logPrompts: true` (default)
- API keys and secrets are **NOT** logged
- Review logs before sharing publicly

### 🛡️ **Data Retention**

- CI artifacts are automatically cleaned up after 7 days
- Local logs must be manually cleaned up
- Consider log rotation for long-running processes

## Advanced Usage

### 🎛️ **Custom Telemetry Processing**

Create custom analysis scripts:

```bash
#!/bin/bash
# analyze-gemini-actions.sh

TELEMETRY_FILE="$1"

echo "📊 Gemini Actions Analysis"
echo "=========================="

# Count operations by type
echo "File Operations:"
jq -r '.[] | select(.name == "gemini_cli.tool_call") | .attributes.function_name' "$TELEMETRY_FILE" | sort | uniq -c

# Calculate total execution time
echo "Total Execution Time:"
jq -r '.[] | select(.name == "gemini_cli.tool_call") | .attributes.duration_ms' "$TELEMETRY_FILE" | awk '{sum+=$1} END {print sum/1000 "s"}'

# Show failed operations
echo "Failed Operations:"
jq -r '.[] | select(.name == "gemini_cli.tool_call" and .attributes.success == false) | .attributes' "$TELEMETRY_FILE"
```

This comprehensive logging system provides complete visibility into Gemini's autonomous operations, enabling better debugging, auditing, and understanding of AI-driven code changes.
