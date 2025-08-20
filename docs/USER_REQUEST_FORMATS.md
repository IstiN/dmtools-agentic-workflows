# User Request Formats Guide

This guide explains the different formats supported for user requests in DMTools Agentic Workflows and when to use each one.

## Overview

The agentic workflows support multiple user request formats to accommodate different use cases, from simple one-line requests to complex multi-page specifications. The system automatically detects and processes the appropriate format.

## Supported Formats

### 1. Plain Text (Recommended for Simple Requests)

**Use Case**: Simple, straightforward requests that fit on one line

**Example**:
```yaml
user_request: "Add logging to the authentication service"
```

**Characteristics**:
- Direct text input
- No encoding required
- Best for quick fixes and simple features
- Automatically processed as-is

### 2. Multi-line YAML Literal Block

**Use Case**: Complex requests with multiple requirements, structured specifications

**Example**:
```yaml
user_request: |
  Implement a complete user authentication system with these requirements:
  
  ## Core Features
  1. JWT token-based authentication
  2. Password hashing with bcrypt (minimum 12 rounds)
  3. Role-based access control (user, admin, moderator)
  4. Session management with configurable timeout
  5. Password reset functionality via email
  
  ## Technical Requirements
  - Use TypeScript for type safety
  - Implement proper error handling
  - Add comprehensive logging
  - Follow OWASP security guidelines
  
  ## Testing Requirements
  - Unit tests for all authentication logic
  - Integration tests for API endpoints
  - Security testing for common vulnerabilities
  
  ## Documentation
  - API documentation with examples
  - Setup and configuration guide
  - Security considerations document
  
  Ticket: DMC-419
```

**Characteristics**:
- Uses YAML literal block scalar (`|`)
- Preserves line breaks and formatting
- Supports Markdown formatting
- Ideal for detailed specifications

### 3. Base64 Encoded

**Use Case**: Automated systems, API integrations, requests with special characters

**Detection**: Automatically detected based on:
- Valid base64 character pattern (`[A-Za-z0-9+/]*={0,2}`)
- Minimum length of 20 characters
- Successful base64 decode operation

**Example**:
```yaml
user_request: "SW1wbGVtZW50IGEgY29tcGxldGUgdXNlciBhdXRoZW50aWNhdGlvbiBzeXN0ZW0gd2l0aCBKV1QgdG9rZW5z"
```

**Creating Base64 Requests**:
```bash
# Encode a simple request
echo "Implement user authentication with JWT tokens" | base64 -w 0

# Encode a multi-line request
cat << 'EOF' | base64 -w 0
Implement a complete authentication system:
1. JWT tokens
2. Password hashing
3. Role-based access
EOF
```

**Characteristics**:
- Automatically detected and decoded
- Handles special characters safely
- Good for API integrations
- Fallback to plain text if decode fails

### 4. GZIP Compressed + Base64 (For Very Large Requests)

**Use Case**: Extremely large requests, webhook payloads, massive requirement documents

**Format**: `GZIP_COMPRESSED:` prefix followed by base64-encoded compressed data

**Example**:
```yaml
user_request: "GZIP_COMPRESSED:H4sIAAAAAAAAA3WQwQ6CMAyG7+U1JG0ZY7yZEA8mHkw8mXgx8WLiycSLiRcTLyZeTLyY..."
```

**Creating GZIP Compressed Requests**:
```bash
# Compress a file
cat large_requirements.md | gzip | base64 -w 0 | sed 's/^/GZIP_COMPRESSED:/'

# Compress a multi-line string
cat << 'EOF' | gzip | base64 -w 0 | sed 's/^/GZIP_COMPRESSED:/'
[Your very large request content here]
This can be multiple pages long...
EOF

# One-liner for quick testing
echo "Your large request" | gzip | base64 -w 0 | sed 's/^/GZIP_COMPRESSED:/'
```

**Characteristics**:
- Handles requests of any size
- Significantly reduces payload size
- Automatic decompression
- Compression ratio logging
- Fallback to plain text on failure

## Format Detection Logic

The system processes requests in this order:

1. **GZIP Detection**: Checks for `GZIP_COMPRESSED:` prefix
2. **Base64 Detection**: Validates base64 pattern and length
3. **Plain Text**: Default fallback for all other inputs

```bash
# Detection pseudo-code
if [[ request starts with "GZIP_COMPRESSED:" ]]; then
    decompress_gzip(base64_decode(request))
elif [[ request matches base64 pattern AND length > 20 ]]; then
    base64_decode(request)
else
    treat_as_plain_text(request)
fi
```

## Best Practices

### Request Structure

Always include these elements in your requests:

1. **Ticket Reference**: Include DMC-XXX ticket number
2. **Clear Requirements**: Specific, actionable requirements
3. **Technical Context**: Technology stack, constraints
4. **Acceptance Criteria**: How to validate completion

### Example Well-Structured Request

```yaml
user_request: |
  DMC-419: Implement OAuth2 Social Login Integration
  
  ## Requirements
  - Add Google OAuth2 login option
  - Add GitHub OAuth2 login option  
  - Integrate with existing user management system
  - Handle account linking for existing users
  
  ## Technical Context
  - React frontend with TypeScript
  - Node.js backend with Express
  - PostgreSQL database
  - Existing JWT authentication system
  
  ## Acceptance Criteria
  - Users can login with Google/GitHub accounts
  - New users are automatically registered
  - Existing users can link social accounts
  - Security headers and CSRF protection
  - Comprehensive error handling
  
  ## Out of Scope
  - Other social providers (Facebook, Twitter)
  - Account deletion functionality
  - Admin panel modifications
```

### Format Selection Guide

| Request Size | Complexity | Recommended Format | Example Use Case |
|--------------|------------|-------------------|------------------|
| < 100 chars | Simple | Plain Text | "Fix login bug" |
| 100-1000 chars | Medium | Multi-line YAML | Feature with requirements |
| 1000-8000 chars | Complex | Multi-line YAML | Detailed specifications |
| > 8KB | Very Large | GZIP Compressed | Full API documentation |
| Automated | Any | Base64 | API/webhook integration |

## Validation and Error Handling

### Automatic Validation

The system automatically validates:
- ✅ DMC ticket number format (DMC-XXX)
- ✅ Successful decompression/decoding
- ✅ Non-empty content after processing
- ✅ Reasonable content length

### Error Handling

If processing fails:
1. **GZIP**: Falls back to treating as plain text
2. **Base64**: Falls back to treating as plain text  
3. **Warnings**: Logged for missing ticket numbers
4. **Logs**: Detailed processing information available

### Debug Information

Enable debug logging to see:
- Format detection results
- Compression ratios
- Processing times
- Content validation results

## Integration Examples

### GitHub Actions Workflow

```yaml
# Simple text request
- name: Simple Implementation
  uses: IstiN/dmtools-agentic-workflows/.github/workflows/reusable-gemini-implementation.yml@main
  with:
    user_request: "DMC-123: Add user logout functionality"

# Complex multi-line request
- name: Complex Implementation
  uses: IstiN/dmtools-agentic-workflows/.github/workflows/reusable-gemini-implementation.yml@main
  with:
    user_request: |
      DMC-456: Implement comprehensive user authentication system
      
      See attached requirements document for full specification.
      Key features: JWT tokens, RBAC, password reset, 2FA support.

# Base64 encoded (for API integration)
- name: API-Generated Request
  uses: IstiN/dmtools-agentic-workflows/.github/workflows/reusable-gemini-implementation.yml@main
  with:
    user_request: ${{ steps.generate_request.outputs.encoded_request }}
```

### Webhook Integration

```javascript
// Express webhook handler
app.post('/webhook/implementation', (req, res) => {
  const largeRequirement = req.body.requirement;
  
  // Compress large requirements
  const compressed = zlib.gzipSync(largeRequirement);
  const encoded = Buffer.from(compressed).toString('base64');
  const gzipRequest = `GZIP_COMPRESSED:${encoded}`;
  
  // Trigger GitHub workflow
  triggerWorkflow({
    user_request: gzipRequest,
    // ... other parameters
  });
});
```

## Troubleshooting

### Common Issues

1. **"No DMC ticket number found"**
   - Solution: Include DMC-XXX format in your request

2. **"Base64 decode failed"**
   - Check base64 encoding is valid
   - Ensure no line breaks in encoded string
   - Try plain text format instead

3. **"GZIP decompression failed"**
   - Verify compression was done correctly
   - Check the `GZIP_COMPRESSED:` prefix
   - Fallback will use as plain text

4. **Request too large**
   - Use GZIP compression for requests > 8KB
   - Split into multiple smaller requests
   - Use additional context files instead

### Debugging

Enable comprehensive logging in workflows:
```yaml
with:
  enable_debug_logging: true
```

This provides detailed information about:
- Format detection process
- Compression/decompression results
- Content validation
- Processing times

## Advanced Usage

### Custom Preprocessing

You can preprocess requests before sending:

```bash
#!/bin/bash
# preprocess-request.sh

REQUEST_FILE="$1"
OUTPUT_FORMAT="${2:-auto}"

case "$OUTPUT_FORMAT" in
  "base64")
    cat "$REQUEST_FILE" | base64 -w 0
    ;;
  "gzip")
    cat "$REQUEST_FILE" | gzip | base64 -w 0 | sed 's/^/GZIP_COMPRESSED:/'
    ;;
  "auto")
    SIZE=$(wc -c < "$REQUEST_FILE")
    if [ "$SIZE" -gt 8192 ]; then
      cat "$REQUEST_FILE" | gzip | base64 -w 0 | sed 's/^/GZIP_COMPRESSED:/'
    else
      cat "$REQUEST_FILE"
    fi
    ;;
esac
```

### Template System

Create reusable request templates:

```yaml
# templates/feature-request.yml
user_request: |
  DMC-${TICKET_NUMBER}: ${FEATURE_NAME}
  
  ## Requirements
  ${REQUIREMENTS}
  
  ## Technical Context
  - Technology: ${TECH_STACK}
  - Database: ${DATABASE}
  - Framework: ${FRAMEWORK}
  
  ## Acceptance Criteria
  ${ACCEPTANCE_CRITERIA}
  
  ## Out of Scope
  ${OUT_OF_SCOPE}
```

This comprehensive guide should help users understand and effectively use all the supported user request formats in the agentic workflows system.
