/**
 * OpenAI GPT-4 Runtime Proxy for Gemini CLI
 * 
 * This script patches global fetch to redirect Gemini API calls to OpenAI's GPT-4 API.
 * Usage: node --require ./openai-gpt4-runtime-proxy.js gemini --approval-mode yolo "prompt"
 * 
 * Environment Variables:
 * - OPENAI_API_KEY: Your OpenAI API key (required)
 * - OPENAI_MODEL: Model to use (default: gpt-4o)
 * - OPENAI_BASE_URL: Custom OpenAI-compatible endpoint (optional)
 */

const fs = require('fs');

// Configuration from environment
const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
const OPENAI_MODEL = process.env.OPENAI_MODEL || 'gpt-4o';
const OPENAI_BASE_URL = process.env.OPENAI_BASE_URL || 'https://api.openai.com';

if (!OPENAI_API_KEY) {
    console.error('❌ ERROR: OPENAI_API_KEY environment variable is required');
    process.exit(1);
}

console.log('🔧 OpenAI Runtime Proxy: Patching global fetch...');
console.log(`📡 Target: ${OPENAI_BASE_URL}`);
console.log(`🤖 Model: ${OPENAI_MODEL}`);

// Store original fetch
const originalFetch = global.fetch;

// Log to file for debugging
const logFile = 'openai-runtime-proxy.log';
function logToFile(message) {
    const timestamp = new Date().toISOString();
    const logMessage = `[${timestamp}] ${message}\n`;
    try {
        fs.appendFileSync(logFile, logMessage);
    } catch (e) {
        // If file write fails, just use console
    }
    console.log(`🟨 PROXY: ${message}`);
}

/**
 * Convert Gemini request format to OpenAI format
 */
function convertGeminiToOpenAI(geminiRequest) {
    const messages = [];
    
    if (geminiRequest.contents) {
        for (const content of geminiRequest.contents) {
            const role = content.role || 'user';
            let text = '';
            
            if (content.parts) {
                for (const part of content.parts) {
                    if (part.text) {
                        text += part.text;
                    }
                }
            }
            
            messages.push({
                role: role === 'model' ? 'assistant' : role,
                content: text
            });
        }
    }
    
    return {
        model: OPENAI_MODEL,
        messages: messages,
        temperature: geminiRequest.generationConfig?.temperature || 0.1,
        max_tokens: geminiRequest.generationConfig?.maxOutputTokens || 4096,
        top_p: geminiRequest.generationConfig?.topP || 1.0
    };
}

/**
 * Convert OpenAI response back to Gemini format
 */
function convertOpenAIToGemini(openaiResponse) {
    if (openaiResponse.choices && openaiResponse.choices.length > 0) {
        const choice = openaiResponse.choices[0];
        return {
            candidates: [{
                content: {
                    parts: [{
                        text: choice.message.content
                    }],
                    role: 'model'
                },
                finishReason: choice.finish_reason === 'stop' ? 'STOP' : 'OTHER',
                index: 0
            }],
            usageMetadata: {
                promptTokenCount: openaiResponse.usage?.prompt_tokens || 0,
                candidatesTokenCount: openaiResponse.usage?.completion_tokens || 0,
                totalTokenCount: openaiResponse.usage?.total_tokens || 0
            }
        };
    }
    
    return {
        candidates: [{
            content: {
                parts: [{ text: "Sorry, I couldn't process your request." }],
                role: 'model'
            },
            finishReason: 'OTHER',
            index: 0
        }]
    };
}

// Patch global fetch
global.fetch = async function(url, options = {}) {
    if (typeof url === 'string' && url.includes('generativelanguage.googleapis.com')) {
        logToFile(`🎯 INTERCEPTED Gemini API call: ${url}`);
        
        try {
            const geminiRequest = JSON.parse(options.body || '{}');
            const userText = geminiRequest.contents?.[0]?.parts?.[0]?.text || 'unknown';
            logToFile(`📥 Gemini request: ${userText.substring(0, 100)}...`);
            
            const openaiRequest = convertGeminiToOpenAI(geminiRequest);
            logToFile(`🔄 Converted to OpenAI format for model: ${openaiRequest.model}`);
            
            const openaiUrl = `${OPENAI_BASE_URL}/v1/chat/completions`;
            const response = await originalFetch(openaiUrl, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${OPENAI_API_KEY}`,
                    'User-Agent': 'GeminiCLI-OpenAI-Proxy/1.0'
                },
                body: JSON.stringify(openaiRequest)
            });
            
            if (!response.ok) {
                const errorText = await response.text();
                logToFile(`❌ OpenAI API error: ${response.status} - ${errorText}`);
                throw new Error(`OpenAI API error: ${response.status}`);
            }
            
            const openaiResponse = await response.json();
            const geminiResponse = convertOpenAIToGemini(openaiResponse);
            
            const responseText = openaiResponse.choices?.[0]?.message?.content || 'no response';
            logToFile(`📤 OpenAI response: ${responseText.substring(0, 100)}...`);
            logToFile(`✅ Successfully converted back to Gemini format`);
            
            return {
                ok: true,
                status: 200,
                headers: {
                    get: (key) => key === 'content-type' ? 'application/json' : null
                },
                json: async () => geminiResponse,
                text: async () => JSON.stringify(geminiResponse),
                clone: function() { return this; }
            };
            
        } catch (error) {
            logToFile(`❌ OpenAI Proxy error: ${error.message}`);
            return {
                ok: false,
                status: 500,
                json: async () => ({ error: { message: error.message } }),
                text: async () => JSON.stringify({ error: { message: error.message } })
            };
        }
    } else {
        // Pass through non-Gemini requests
        if (typeof url === 'string') {
            logToFile(`🔍 Pass-through for: ${url}`);
        }
        return originalFetch(url, options);
    }
};

logToFile('✅ Global fetch patched successfully for OpenAI GPT-4');
