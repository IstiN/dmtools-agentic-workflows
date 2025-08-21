const fs = require('fs');
const path = require('path');

function logToFile(message) {
    const timestamp = new Date().toISOString();
    const logMessage = `[${timestamp}] ${message}\n`;
    
    try {
        const logFile = path.join(__dirname, 'debug-proxy.log');
        fs.appendFileSync(logFile, logMessage);
        console.log(logMessage.trim());
    } catch (error) {
        console.error('Failed to write to log file:', error.message);
    }
}

// Store the original fetch
const originalFetch = global.fetch;

// Patch global fetch
global.fetch = async function(url, options = {}) {
    // Log ALL requests from Gemini CLI
    if (typeof url === 'string') {
        logToFile(`🌐 GEMINI CLI REQUEST: ${url}`);
        logToFile(`📋 Method: ${options.method || 'GET'}`);
        
        if (options.headers) {
            logToFile(`📋 Headers: ${JSON.stringify(options.headers, null, 2)}`);
        }
        
        if (options.body) {
            logToFile(`📋 Request Body: ${options.body}`);
        }
        
        logToFile(`==========================================`);
        
        // Handle countTokens requests with proper Gemini API response format
        if (url.includes('countTokens')) {
            logToFile(`🔢 INTERCEPTED countTokens request - returning fake response`);
            
            // Return proper Gemini countTokens response format according to documentation
            const countTokensResponse = {
                totalTokens: 100,
                cachedContentTokenCount: 0,
                promptTokensDetails: [],
                cacheTokensDetails: []
            };
            
            const headers = new Headers();
            headers.set('Content-Type', 'application/json');
            
            return new Response(JSON.stringify(countTokensResponse), {
                status: 200,
                statusText: 'OK',
                headers: headers
            });
        }
        
        // For generateContent requests - return fake response
        if (url.includes('generateContent')) {
            logToFile(`🎯 INTERCEPTED generateContent request - returning fake response`);
            
            // Parse request body to get some context for fake response
            let requestPrompt = "Unknown request";
            try {
                if (options.body) {
                    const requestData = JSON.parse(options.body);
                    if (requestData.contents && requestData.contents.length > 0) {
                        const lastContent = requestData.contents[requestData.contents.length - 1];
                        if (lastContent.parts && lastContent.parts.length > 0) {
                            requestPrompt = lastContent.parts[0].text.substring(0, 100) + "...";
                        }
                    }
                }
            } catch (e) {
                logToFile(`❌ Error parsing request body: ${e.message}`);
            }
            
            logToFile(`📝 Request prompt preview: ${requestPrompt}`);
            
            // Check if this is a streaming request
            if (url.includes('streamGenerateContent')) {
                logToFile(`🌊 Returning fake streaming response`);
                
                // Return fake streaming response (SSE format)
                const streamingResponse = `data: {"candidates":[{"content":{"parts":[{"text":"This is a **fake streaming response** from the debug proxy.\\n\\n"}],"role":"model"},"finishReason":"STOP","index":0,"safetyRatings":[],"tokenCount":15}],"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":15,"totalTokenCount":115},"modelVersion":"debug-proxy-fake-stream"}

data: {"candidates":[{"content":{"parts":[{"text":"I can see your request was: ${requestPrompt.substring(0, 50)}...\\n\\n"}],"role":"model"},"finishReason":"STOP","index":0,"safetyRatings":[],"tokenCount":20}],"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":35,"totalTokenCount":135},"modelVersion":"debug-proxy-fake-stream"}

data: {"candidates":[{"content":{"parts":[{"text":"This debug proxy is working correctly! 🎉"}],"role":"model"},"finishReason":"STOP","index":0,"safetyRatings":[],"tokenCount":8}],"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":43,"totalTokenCount":143},"modelVersion":"debug-proxy-fake-stream"}

`;
                
                const headers = new Headers();
                headers.set('Content-Type', 'text/plain; charset=utf-8');
                headers.set('Cache-Control', 'no-cache');
                headers.set('Connection', 'keep-alive');
                headers.set('Access-Control-Allow-Origin', '*');
                
                return new Response(streamingResponse, {
                    status: 200,
                    statusText: 'OK',
                    headers: headers
                });
            } else {
                logToFile(`📄 Returning fake non-streaming response`);
                
                // Return fake non-streaming GenerateContentResponse according to Gemini API docs
                const fakeResponse = {
                    candidates: [
                        {
                            content: {
                                parts: [
                                    {
                                        text: `This is a **fake response** from the debug proxy! 🎉\n\nI can see your request was:\n${requestPrompt}\n\nThe debug proxy is working correctly and intercepting all generateContent requests.`
                                    }
                                ],
                                role: "model"
                            },
                            finishReason: "STOP",
                            index: 0,
                            safetyRatings: [],
                            tokenCount: 25
                        }
                    ],
                    promptFeedback: {
                        safetyRatings: []
                    },
                    usageMetadata: {
                        promptTokenCount: 100,
                        candidatesTokenCount: 25,
                        totalTokenCount: 125,
                        promptTokensDetails: [],
                        candidatesTokensDetails: []
                    },
                    modelVersion: "debug-proxy-fake-v1.0"
                };
                
                logToFile(`✅ Fake response generated: ${JSON.stringify(fakeResponse).substring(0, 200)}...`);
                
                const headers = new Headers();
                headers.set('Content-Type', 'application/json');
                headers.set('Access-Control-Allow-Origin', '*');
                
                return new Response(JSON.stringify(fakeResponse), {
                    status: 200,
                    statusText: 'OK',
                    headers: headers
                });
            }
        }
    }
    
    // Pass through all other requests to original fetch
    return originalFetch(url, options);
};

logToFile('✅ Simple debug proxy initialized - will log all Gemini CLI requests');
