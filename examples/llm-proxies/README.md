# Custom LLM Proxy Examples

This directory contains example proxy scripts that allow you to use custom LLMs (like OpenAI GPT-4, Claude, etc.) with Gemini CLI while maintaining full backward compatibility.

## How It Works

The proxy scripts use **runtime fetch patching** to intercept API calls from Gemini CLI and redirect them to other LLM providers, translating the request/response formats as needed.

```
Gemini CLI → Runtime Patched fetch() → Custom LLM API → Response Translation → Gemini CLI
```

## Available Proxies

### OpenAI GPT-4 Proxy

- **JavaScript Runtime Proxy**: `openai-gpt4-runtime-proxy.js` ⭐ **Recommended**

Redirects Gemini CLI requests to OpenAI's GPT-4 models using runtime fetch patching.

### Debug Proxy

- **JavaScript Debug Proxy**: `debug-proxy.js` 🔧 **For Development**

Logs all Gemini CLI requests with full details and returns fake responses in proper Gemini API format. Useful for understanding Gemini CLI behavior and testing proxy setup.

## Usage

### 1. Set Environment Variables

```bash
export OPENAI_API_KEY="your-openai-api-key-here"
export OPENAI_MODEL="gpt-4o"  # or gpt-4, gpt-4-turbo, etc.
```

### 2. Use with run-gemini.sh

The proxy script is passed as the 8th parameter to `run-gemini.sh`:

```bash
# Basic usage with default Gemini
./scripts/run-gemini.sh discovery outputs/user-request.txt

# Using OpenAI GPT-4 with runtime proxy
./scripts/run-gemini.sh discovery outputs/user-request.txt "" "gpt-4o" false false outputs examples/llm-proxies/openai-gpt4-runtime-proxy.js
```

### 3. Use with GitHub Actions

Update your workflow to pass the custom proxy:

```yaml
jobs:
  ai-discovery:
    uses: IstiN/dmtools-agentic-workflows/.github/workflows/reusable-gemini-discovery.yml@main
    with:
      user_request: ${{ inputs.user_request }}
      model: "gpt-4o"  # This becomes a label, actual model is in proxy
      custom_llm_proxy: "examples/llm-proxies/openai-gpt4-proxy.js"
    secrets:
      GEMINI_API_KEY: ${{ secrets.OPENAI_API_KEY }}  # Pass OpenAI key as Gemini key
```

## Parameters Reference

The `run-gemini.sh` script accepts these parameters:

1. `PHASE` - "discovery" or "implementation"
2. `USER_REQUEST_FILE` - Path to user request file
3. `RULES_FOLDER` - Optional rules folder
4. `MODEL` - Model name (becomes a label when using proxy)
5. `USE_VERTEX_AI` - Boolean flag
6. `USE_GCA` - Boolean flag  
7. `OUTPUT_DIR` - Output directory
8. `CUSTOM_LLM_PROXY` - **NEW**: Path to proxy script (JS/Python)

## Proxy Script Requirements

Custom proxy scripts must:

1. **Accept `--port` parameter**: `node proxy.js --port 8080`
2. **Provide health check**: `GET /health` returns JSON status
3. **Handle CORS**: Set appropriate CORS headers
4. **Translate formats**: Convert between Gemini and target LLM formats
5. **Error handling**: Return proper error responses

### Expected Health Check Response

```json
{
  "status": "healthy",
  "proxy": "openai-gpt4",
  "model": "gpt-4o",
  "timestamp": "2025-08-20T20:30:45.123Z"
}
```

## Creating Custom Proxies

### JavaScript Example Template

```javascript
#!/usr/bin/env node

const http = require('http');
const args = process.argv.slice(2);
const portIndex = args.indexOf('--port');
const PORT = portIndex !== -1 ? parseInt(args[portIndex + 1]) : 8080;

const server = http.createServer(async (req, res) => {
    // Enable CORS
    res.setHeader('Access-Control-Allow-Origin', '*');
    
    // Health check
    if (req.method === 'GET' && req.url === '/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'healthy' }));
        return;
    }
    
    // Handle POST requests - convert and proxy
    if (req.method === 'POST') {
        // Your proxy logic here
    }
});

server.listen(PORT, () => {
    console.log(`✅ Custom LLM Proxy running on http://localhost:${PORT}`);
});
```

### Python Example Template

```python
#!/usr/bin/env python3

import argparse
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class CustomProxyHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'healthy'}).encode())
    
    def do_POST(self):
        # Your proxy logic here
        pass

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8080)
    args = parser.parse_args()
    
    server = HTTPServer(('localhost', args.port), CustomProxyHandler)
    print(f'✅ Custom LLM Proxy running on http://localhost:{args.port}')
    server.serve_forever()

if __name__ == '__main__':
    main()
```

## Environment Variables

### OpenAI Proxy
- `OPENAI_API_KEY` - Your OpenAI API key (required)
- `OPENAI_MODEL` - Model to use (default: gpt-4o)
- `OPENAI_BASE_URL` - Custom endpoint (default: https://api.openai.com)

### Future Proxy Examples
- `ANTHROPIC_API_KEY` - For Claude proxy
- `AZURE_OPENAI_KEY` - For Azure OpenAI proxy
- `HUGGINGFACE_TOKEN` - For Hugging Face proxy

## Debugging

The proxy includes comprehensive logging:

```
🟨 OpenAI GPT-4 Proxy starting on port 8080
📡 Target: https://api.openai.com (gpt-4o)
✅ OpenAI GPT-4 Proxy running on http://localhost:8080
🔄 Intercepting Gemini API call: /v1beta/models/gpt-4o:generateContent
📤 Forwarding to OpenAI (gpt-4o)
✅ Request completed successfully
```

## Security Notes

1. **API Keys**: Never commit API keys to repositories
2. **Local Only**: Proxies run on localhost only
3. **Process Cleanup**: Automatic cleanup on script exit
4. **Error Handling**: Graceful error handling and logging

## Limitations

1. **Feature Parity**: Not all Gemini features may be available in target LLMs
2. **Function Calling**: Tool/function calling support varies by provider
3. **Streaming**: Currently only supports non-streaming responses
4. **Rate Limits**: Subject to target LLM provider rate limits

## Contributing

To add support for new LLM providers:

1. Create a new proxy script in this directory
2. Follow the naming convention: `{provider}-{model}-proxy.{js|py}`
3. Update this README with usage instructions
4. Test with both discovery and implementation workflows

Example providers to implement:
- `anthropic-claude-proxy.js` - For Claude models
- `azure-openai-proxy.py` - For Azure OpenAI
- `huggingface-proxy.js` - For Hugging Face models
- `ollama-proxy.py` - For local Ollama models
