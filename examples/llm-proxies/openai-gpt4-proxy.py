#!/usr/bin/env python3

"""
OpenAI GPT-4 Proxy for Gemini CLI

This proxy intercepts Gemini API calls and redirects them to OpenAI's GPT-4 API.
It translates between Gemini's API format and OpenAI's format.

Usage: python3 openai-gpt4-proxy.py --port 8080

Environment Variables:
- OPENAI_API_KEY: Your OpenAI API key
- OPENAI_MODEL: Model to use (default: gpt-4o)
- OPENAI_BASE_URL: Custom OpenAI-compatible endpoint (optional)
"""

import argparse
import os
import json
import signal
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import requests
from datetime import datetime
import threading
import time

# Configuration
OPENAI_API_KEY = os.getenv('OPENAI_API_KEY')
OPENAI_MODEL = os.getenv('OPENAI_MODEL', 'gpt-4o')
OPENAI_BASE_URL = os.getenv('OPENAI_BASE_URL', 'https://api.openai.com')

if not OPENAI_API_KEY:
    print('❌ ERROR: OPENAI_API_KEY environment variable is required')
    sys.exit(1)

class LLMProxyHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the LLM proxy"""
    
    def log_message(self, format, *args):
        """Override to control logging"""
        pass  # Disable default HTTP logging
    
    def do_OPTIONS(self):
        """Handle CORS preflight requests"""
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')
        self.end_headers()
    
    def do_GET(self):
        """Handle GET requests - mainly health checks"""
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            
            health_response = {
                'status': 'healthy',
                'proxy': 'openai-gpt4',
                'model': OPENAI_MODEL,
                'timestamp': datetime.now().isoformat()
            }
            self.wfile.write(json.dumps(health_response).encode())
        else:
            self.send_response(404)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': 'Not found'}).encode())
    
    def do_POST(self):
        """Handle POST requests - proxy to OpenAI"""
        try:
            # Check if this is a Gemini API request
            if not self._is_gemini_api_request():
                self.send_response(404)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({'error': 'Not a Gemini API endpoint'}).encode())
                return
            
            # Read request body
            content_length = int(self.headers.get('Content-Length', 0))
            request_body = self.rfile.read(content_length).decode('utf-8')
            
            print(f'🔄 Intercepting Gemini API call: {self.path}')
            
            # Parse and convert request
            gemini_request = json.loads(request_body)
            openai_request = self._convert_gemini_to_openai(gemini_request)
            
            print(f'📤 Forwarding to OpenAI ({OPENAI_MODEL})')
            
            # Make request to OpenAI
            openai_response = self._make_openai_request(openai_request)
            
            # Convert response back to Gemini format
            gemini_response = self._convert_openai_to_gemini(openai_response)
            
            print('✅ Request completed successfully')
            
            # Send response
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(gemini_response).encode())
            
        except Exception as e:
            print(f'❌ Proxy error: {str(e)}')
            
            error_response = {
                'error': {
                    'code': 500,
                    'message': f'Proxy error: {str(e)}',
                    'status': 'INTERNAL_ERROR'
                }
            }
            
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(error_response).encode())
    
    def _is_gemini_api_request(self):
        """Check if the request is for a Gemini API endpoint"""
        return ('generateContent' in self.path or 
                '/v1/models/' in self.path or 
                '/v1beta/' in self.path)
    
    def _convert_gemini_to_openai(self, gemini_request):
        """Convert Gemini request format to OpenAI format"""
        try:
            contents = gemini_request.get('contents', [])
            tools = gemini_request.get('tools', [])
            generation_config = gemini_request.get('generationConfig', {})
            
            messages = []
            
            # Convert Gemini contents to OpenAI messages
            for content in contents:
                role = content.get('role')
                if role in ['user', 'model']:
                    openai_role = 'assistant' if role == 'model' else role
                    
                    parts = content.get('parts', [])
                    message_content = ''
                    
                    for part in parts:
                        if 'text' in part:
                            message_content += part['text']
                        if 'functionCall' in part:
                            message_content += f"\n[Function Call: {part['functionCall'].get('name', 'unknown')}]"
                    
                    if message_content.strip():
                        messages.append({
                            'role': openai_role,
                            'content': message_content.strip()
                        })
            
            openai_request = {
                'model': OPENAI_MODEL,
                'messages': messages,
                'stream': False,
                'temperature': generation_config.get('temperature', 0.1),
                'max_tokens': generation_config.get('maxOutputTokens', 4000),
            }
            
            # Add tools if present
            if tools:
                openai_tools = []
                for tool in tools:
                    function_declarations = tool.get('functionDeclarations', [])
                    for func_decl in function_declarations:
                        openai_tools.append({
                            'type': 'function',
                            'function': {
                                'name': func_decl.get('name', 'unknown'),
                                'description': func_decl.get('description', ''),
                                'parameters': func_decl.get('parameters', {})
                            }
                        })
                
                if openai_tools:
                    openai_request['tools'] = openai_tools
                    openai_request['tool_choice'] = 'auto'
            
            return openai_request
            
        except Exception as e:
            raise Exception(f'Error converting Gemini to OpenAI format: {str(e)}')
    
    def _convert_openai_to_gemini(self, openai_response):
        """Convert OpenAI response format to Gemini format"""
        try:
            choices = openai_response.get('choices', [])
            if not choices:
                raise Exception('No choices in OpenAI response')
            
            choice = choices[0]
            message = choice.get('message', {})
            
            parts = []
            
            # Handle regular text response
            if message.get('content'):
                parts.append({'text': message['content']})
            
            # Handle function calls
            if message.get('tool_calls'):
                for tool_call in message['tool_calls']:
                    function = tool_call.get('function', {})
                    try:
                        args = json.loads(function.get('arguments', '{}'))
                    except:
                        args = {}
                    
                    parts.append({
                        'functionCall': {
                            'name': function.get('name', 'unknown'),
                            'args': args
                        }
                    })
            
            finish_reason = choice.get('finish_reason', 'stop')
            gemini_finish_reason = 'STOP' if finish_reason == 'stop' else 'OTHER'
            
            usage = openai_response.get('usage', {})
            
            gemini_response = {
                'candidates': [{
                    'content': {
                        'parts': parts,
                        'role': 'model'
                    },
                    'finishReason': gemini_finish_reason,
                    'index': 0,
                    'safetyRatings': []
                }],
                'usageMetadata': {
                    'promptTokenCount': usage.get('prompt_tokens', 0),
                    'candidatesTokenCount': usage.get('completion_tokens', 0),
                    'totalTokenCount': usage.get('total_tokens', 0)
                }
            }
            
            return gemini_response
            
        except Exception as e:
            raise Exception(f'Error converting OpenAI to Gemini format: {str(e)}')
    
    def _make_openai_request(self, openai_request):
        """Make request to OpenAI API"""
        try:
            headers = {
                'Content-Type': 'application/json',
                'Authorization': f'Bearer {OPENAI_API_KEY}',
                'User-Agent': 'DMTools-LLM-Proxy/1.0'
            }
            
            url = f'{OPENAI_BASE_URL}/v1/chat/completions'
            
            response = requests.post(
                url,
                headers=headers,
                json=openai_request,
                timeout=60
            )
            
            if response.status_code != 200:
                error_data = response.json() if response.headers.get('content-type', '').startswith('application/json') else response.text
                raise Exception(f'OpenAI API error: {response.status_code} - {error_data}')
            
            return response.json()
            
        except requests.exceptions.RequestException as e:
            raise Exception(f'OpenAI request failed: {str(e)}')

def signal_handler(signum, frame):
    """Handle shutdown signals"""
    print('\n🛑 Shutting down proxy server...')
    sys.exit(0)

def main():
    parser = argparse.ArgumentParser(description='OpenAI GPT-4 Proxy for Gemini CLI')
    parser.add_argument('--port', type=int, default=8080, help='Port to run the proxy server on')
    args = parser.parse_args()
    
    print(f'🐍 OpenAI GPT-4 Proxy starting on port {args.port}')
    print(f'📡 Target: {OPENAI_BASE_URL} ({OPENAI_MODEL})')
    
    # Set up signal handlers for graceful shutdown
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Create and start server
    server = HTTPServer(('localhost', args.port), LLMProxyHandler)
    
    try:
        print(f'✅ OpenAI GPT-4 Proxy running on http://localhost:{args.port}')
        print(f'💡 Health check: http://localhost:{args.port}/health')
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n🛑 Shutting down proxy server...')
    finally:
        server.server_close()
        print('✅ Proxy server stopped')

if __name__ == '__main__':
    main()
