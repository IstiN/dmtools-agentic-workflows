#!/usr/bin/env node

/**
 * OpenAI GPT-4 Proxy for Gemini CLI
 * 
 * This proxy intercepts Gemini API calls and redirects them to OpenAI's GPT-4 API.
 * It translates between Gemini's API format and OpenAI's format.
 * 
 * Usage: node openai-gpt4-proxy.js --port 8080
 * 
 * Environment Variables:
 * - OPENAI_API_KEY: Your OpenAI API key
 * - OPENAI_MODEL: Model to use (default: gpt-4o)
 * - OPENAI_BASE_URL: Custom OpenAI-compatible endpoint (optional)
 */

const http = require('http');
const https = require('https');
const url = require('url');
const crypto = require('crypto');

// Configuration
const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
const OPENAI_MODEL = process.env.OPENAI_MODEL || 'gpt-4o';
const OPENAI_BASE_URL = process.env.OPENAI_BASE_URL || 'https://api.openai.com';

if (!OPENAI_API_KEY) {
    console.error('❌ ERROR: OPENAI_API_KEY environment variable is required');
    process.exit(1);
}

// Parse command line arguments
const args = process.argv.slice(2);
const portIndex = args.indexOf('--port');
const PORT = portIndex !== -1 ? parseInt(args[portIndex + 1]) : 8080;

console.log(`🟨 OpenAI GPT-4 Proxy starting on port ${PORT}`);
console.log(`📡 Target: ${OPENAI_BASE_URL} (${OPENAI_MODEL})`);

/**
 * Convert Gemini request format to OpenAI format
 */
function convertGeminiToOpenAI(geminiRequest) {
    try {
        const { contents, tools, generationConfig } = geminiRequest;
        
        const messages = [];
        
        // Convert Gemini contents to OpenAI messages
        if (contents && Array.isArray(contents)) {
            for (const content of contents) {
                if (content.role === 'user' || content.role === 'model') {
                    const role = content.role === 'model' ? 'assistant' : content.role;
                    
                    if (content.parts && Array.isArray(content.parts)) {
                        let messageContent = '';
                        for (const part of content.parts) {
                            if (part.text) {
                                messageContent += part.text;
                            }
                            // Handle function calls and other part types
                            if (part.functionCall) {
                                messageContent += `\n[Function Call: ${part.functionCall.name}]`;
                            }
                        }
                        
                        if (messageContent.trim()) {
                            messages.push({
                                role: role,
                                content: messageContent.trim()
                            });
                        }
                    }
                }
            }
        }
        
        const openaiRequest = {
            model: OPENAI_MODEL,
            messages: messages,
            stream: false,
            temperature: generationConfig?.temperature || 0.1,
            max_tokens: generationConfig?.maxOutputTokens || 4000,
        };
        
        // Add tools if present
        if (tools && Array.isArray(tools) && tools.length > 0) {
            const openaiTools = tools.map(tool => ({
                type: "function",
                function: {
                    name: tool.functionDeclarations?.[0]?.name || 'unknown',
                    description: tool.functionDeclarations?.[0]?.description || '',
                    parameters: tool.functionDeclarations?.[0]?.parameters || {}
                }
            }));
            
            if (openaiTools.length > 0) {
                openaiRequest.tools = openaiTools;
                openaiRequest.tool_choice = "auto";
            }
        }
        
        return openaiRequest;
    } catch (error) {
        console.error('❌ Error converting Gemini to OpenAI format:', error);
        throw error;
    }
}

/**
 * Convert OpenAI response format to Gemini format
 */
function convertOpenAIToGemini(openaiResponse) {
    try {
        const choice = openaiResponse.choices?.[0];
        if (!choice) {
            throw new Error('No choices in OpenAI response');
        }
        
        const geminiResponse = {
            candidates: [{
                content: {
                    parts: [{
                        text: choice.message?.content || ''
                    }],
                    role: 'model'
                },
                finishReason: choice.finish_reason === 'stop' ? 'STOP' : 'OTHER',
                index: 0,
                safetyRatings: []
            }],
            usageMetadata: {
                promptTokenCount: openaiResponse.usage?.prompt_tokens || 0,
                candidatesTokenCount: openaiResponse.usage?.completion_tokens || 0,
                totalTokenCount: openaiResponse.usage?.total_tokens || 0
            }
        };
        
        // Handle function calls
        if (choice.message?.tool_calls) {
            geminiResponse.candidates[0].content.parts = choice.message.tool_calls.map(call => ({
                functionCall: {
                    name: call.function.name,
                    args: JSON.parse(call.function.arguments || '{}')
                }
            }));
        }
        
        return geminiResponse;
    } catch (error) {
        console.error('❌ Error converting OpenAI to Gemini format:', error);
        throw error;
    }
}

/**
 * Make request to OpenAI API
 */
function makeOpenAIRequest(openaiRequest) {
    return new Promise((resolve, reject) => {
        const requestData = JSON.stringify(openaiRequest);
        const parsedUrl = new URL(`${OPENAI_BASE_URL}/v1/chat/completions`);
        
        const options = {
            hostname: parsedUrl.hostname,
            port: parsedUrl.port || (parsedUrl.protocol === 'https:' ? 443 : 80),
            path: parsedUrl.pathname,
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${OPENAI_API_KEY}`,
                'Content-Length': Buffer.byteLength(requestData),
                'User-Agent': 'DMTools-LLM-Proxy/1.0'
            }
        };
        
        const client = parsedUrl.protocol === 'https:' ? https : http;
        const req = client.request(options, (res) => {
            let data = '';
            
            res.on('data', (chunk) => {
                data += chunk;
            });
            
            res.on('end', () => {
                try {
                    const response = JSON.parse(data);
                    if (res.statusCode >= 200 && res.statusCode < 300) {
                        resolve(response);
                    } else {
                        reject(new Error(`OpenAI API error: ${res.statusCode} - ${response.error?.message || data}`));
                    }
                } catch (error) {
                    reject(new Error(`Failed to parse OpenAI response: ${error.message}`));
                }
            });
        });
        
        req.on('error', (error) => {
            reject(new Error(`OpenAI request failed: ${error.message}`));
        });
        
        req.write(requestData);
        req.end();
    });
}

/**
 * HTTP Proxy Server
 */
const server = http.createServer(async (req, res) => {
    // Enable CORS
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    
    // Health check endpoint
    if (req.method === 'GET' && req.url === '/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ 
            status: 'healthy', 
            proxy: 'openai-gpt4',
            model: OPENAI_MODEL,
            timestamp: new Date().toISOString()
        }));
        return;
    }
    
    // Handle OPTIONS requests
    if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
    }
    
    // Only handle POST requests to Gemini API endpoints
    if (req.method !== 'POST') {
        res.writeHead(405, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Method not allowed' }));
        return;
    }
    
    // Check if this is a Gemini API request
    const urlPath = url.parse(req.url).pathname;
    if (!urlPath.includes('generateContent') && !urlPath.includes('/v1/models/') && !urlPath.includes('/v1beta/')) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Not a Gemini API endpoint' }));
        return;
    }
    
    // Collect request body
    let body = '';
    req.on('data', chunk => {
        body += chunk.toString();
    });
    
    req.on('end', async () => {
        try {
            console.log(`🔄 Intercepting Gemini API call: ${urlPath}`);
            
            const geminiRequest = JSON.parse(body);
            const openaiRequest = convertGeminiToOpenAI(geminiRequest);
            
            console.log(`📤 Forwarding to OpenAI (${OPENAI_MODEL})`);
            const openaiResponse = await makeOpenAIRequest(openaiRequest);
            
            const geminiResponse = convertOpenAIToGemini(openaiResponse);
            
            console.log(`✅ Request completed successfully`);
            
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(geminiResponse));
            
        } catch (error) {
            console.error('❌ Proxy error:', error.message);
            
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
                error: {
                    code: 500,
                    message: `Proxy error: ${error.message}`,
                    status: 'INTERNAL_ERROR'
                }
            }));
        }
    });
});

// Start server
server.listen(PORT, () => {
    console.log(`✅ OpenAI GPT-4 Proxy running on http://localhost:${PORT}`);
    console.log(`💡 Health check: http://localhost:${PORT}/health`);
});

// Graceful shutdown
process.on('SIGINT', () => {
    console.log('\n🛑 Shutting down proxy server...');
    server.close(() => {
        console.log('✅ Proxy server stopped');
        process.exit(0);
    });
});

process.on('SIGTERM', () => {
    console.log('\n🛑 Shutting down proxy server...');
    server.close(() => {
        console.log('✅ Proxy server stopped');
        process.exit(0);
    });
});
