/**
 * OpenAI-Compatible API Adapter
 *
 * This module provides a fetch-level adapter that translates Anthropic SDK requests
 * into OpenAI-compatible API format, and converts the responses back. This allows
 * the entire codebase to continue using the Anthropic SDK types while actually
 * hitting an OpenAI-compatible endpoint (e.g., vLLM, Ollama, LiteLLM, OpenRouter, etc.)
 *
 * Environment variables:
 * - CLAUDE_CODE_USE_OPENAI=1           — Enable OpenAI-compatible mode
 * - OPENAI_API_KEY                      — API key for the OpenAI-compatible service
 * - OPENAI_BASE_URL                     — Base URL (e.g., http://localhost:8000/v1)
 * - OPENAI_MODEL                        — Model name to use (e.g., gpt-4o, deepseek-chat)
 */

// ============================================================================
// Types — minimal subset of the OpenAI Chat Completion API
// ============================================================================

interface OpenAIMessage {
  role: 'system' | 'user' | 'assistant' | 'tool'
  content: string | OpenAIContentPart[] | null
  name?: string
  tool_calls?: OpenAIToolCall[]
  tool_call_id?: string
}

interface OpenAIContentPart {
  type: 'text' | 'image_url'
  text?: string
  image_url?: { url: string; detail?: string }
}

interface OpenAIToolCall {
  id: string
  type: 'function'
  function: { name: string; arguments: string }
}

interface OpenAITool {
  type: 'function'
  function: {
    name: string
    description?: string
    parameters?: Record<string, unknown>
  }
}

interface OpenAIStreamChunk {
  id: string
  object: string
  created: number
  model: string
  choices: Array<{
    index: number
    delta: {
      role?: string
      content?: string | null
      tool_calls?: Array<{
        index: number
        id?: string
        type?: string
        function?: { name?: string; arguments?: string }
      }>
    }
    finish_reason: string | null
  }>
  usage?: {
    prompt_tokens: number
    completion_tokens: number
    total_tokens: number
  }
}

// ============================================================================
// Anthropic → OpenAI request conversion
// ============================================================================

function convertAnthropicToolToOpenAI(tool: any): OpenAITool {
  // Anthropic tool format: { name, description, input_schema }
  // OpenAI tool format: { type: 'function', function: { name, description, parameters } }

  // Handle the beta tool union — strip `type`, `cache_control`, etc.
  const name = tool.name
  const description = tool.description || ''
  const parameters = tool.input_schema || {}

  return {
    type: 'function',
    function: { name, description, parameters },
  }
}

function convertAnthropicContentToOpenAI(
  content: any,
): string | OpenAIContentPart[] {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''

  const parts: OpenAIContentPart[] = []
  for (const block of content) {
    if (block.type === 'text') {
      parts.push({ type: 'text', text: block.text })
    } else if (block.type === 'image') {
      // Anthropic: { type: 'image', source: { type: 'base64', media_type, data } }
      const mediaType = block.source?.media_type || 'image/png'
      const data = block.source?.data || ''
      parts.push({
        type: 'image_url',
        image_url: { url: `data:${mediaType};base64,${data}` },
      })
    } else if (block.type === 'tool_use') {
      // tool_use blocks are handled separately
    } else if (block.type === 'tool_result') {
      // tool_result blocks are handled in message conversion
    }
  }

  if (parts.length === 0) return ''
  if (parts.length === 1 && parts[0]!.type === 'text') return parts[0]!.text!
  return parts
}

function convertAnthropicMessagesToOpenAI(
  messages: any[],
  system?: any,
): OpenAIMessage[] {
  const openAIMessages: OpenAIMessage[] = []

  // System prompt
  if (system) {
    let systemText = ''
    if (typeof system === 'string') {
      systemText = system
    } else if (Array.isArray(system)) {
      systemText = system
        .filter((b: any) => b.type === 'text')
        .map((b: any) => b.text)
        .join('\n\n')
    }
    if (systemText) {
      openAIMessages.push({ role: 'system', content: systemText })
    }
  }

  for (const msg of messages) {
    if (msg.role === 'user') {
      // User messages may contain text + images + tool_results
      const toolResults = Array.isArray(msg.content)
        ? msg.content.filter((b: any) => b.type === 'tool_result')
        : []

      if (toolResults.length > 0) {
        // Emit tool result messages for OpenAI
        for (const tr of toolResults) {
          let resultContent = ''
          if (typeof tr.content === 'string') {
            resultContent = tr.content
          } else if (Array.isArray(tr.content)) {
            resultContent = tr.content
              .filter((b: any) => b.type === 'text')
              .map((b: any) => b.text)
              .join('\n')
          }
          if (tr.is_error) {
            resultContent = `[ERROR] ${resultContent}`
          }
          openAIMessages.push({
            role: 'tool',
            tool_call_id: tr.tool_use_id,
            content: resultContent,
          })
        }

        // Also add any non-tool-result content as a user message
        const otherContent = Array.isArray(msg.content)
          ? msg.content.filter((b: any) => b.type !== 'tool_result')
          : []
        if (otherContent.length > 0) {
          openAIMessages.push({
            role: 'user',
            content: convertAnthropicContentToOpenAI(otherContent),
          })
        }
      } else {
        openAIMessages.push({
          role: 'user',
          content: convertAnthropicContentToOpenAI(msg.content),
        })
      }
    } else if (msg.role === 'assistant') {
      // Assistant messages may contain text + tool_use blocks
      const toolUseBlocks = Array.isArray(msg.content)
        ? msg.content.filter((b: any) => b.type === 'tool_use')
        : []

      const textContent = Array.isArray(msg.content)
        ? msg.content
            .filter((b: any) => b.type === 'text' || b.type === 'thinking')
            .map((b: any) => b.text)
            .join('')
        : typeof msg.content === 'string'
          ? msg.content
          : ''

      if (toolUseBlocks.length > 0) {
        const toolCalls: OpenAIToolCall[] = toolUseBlocks.map((tb: any) => ({
          id: tb.id,
          type: 'function' as const,
          function: {
            name: tb.name,
            arguments:
              typeof tb.input === 'string'
                ? tb.input
                : JSON.stringify(tb.input || {}),
          },
        }))
        openAIMessages.push({
          role: 'assistant',
          content: textContent || null,
          tool_calls: toolCalls,
        })
      } else {
        openAIMessages.push({
          role: 'assistant',
          content: textContent || null,
        })
      }
    }
  }

  return openAIMessages
}

function convertAnthropicRequestToOpenAI(body: any): any {
  const openAIRequest: any = {
    model: process.env.OPENAI_MODEL || body.model || 'gpt-4o',
    messages: convertAnthropicMessagesToOpenAI(body.messages, body.system),
    stream: body.stream ?? false,
    max_completion_tokens: body.max_tokens || 4096,
  }

  // Temperature
  if (body.temperature !== undefined) {
    openAIRequest.temperature = body.temperature
  }

  // Tools
  if (body.tools && body.tools.length > 0) {
    openAIRequest.tools = body.tools
      .filter((t: any) => t.name) // filter out any non-standard tool types
      .map(convertAnthropicToolToOpenAI)

    // Tool choice
    if (body.tool_choice) {
      if (body.tool_choice.type === 'auto') {
        openAIRequest.tool_choice = 'auto'
      } else if (body.tool_choice.type === 'any') {
        openAIRequest.tool_choice = 'required'
      } else if (body.tool_choice.type === 'tool') {
        openAIRequest.tool_choice = {
          type: 'function',
          function: { name: body.tool_choice.name },
        }
      }
    }
  }

  // Stream options — request usage in stream
  if (openAIRequest.stream) {
    openAIRequest.stream_options = { include_usage: true }
  }

  return openAIRequest
}

// ============================================================================
// OpenAI → Anthropic response conversion (streaming SSE)
// ============================================================================

function generateId(): string {
  return 'msg_' + Math.random().toString(36).substring(2, 15)
}

function generateToolUseId(): string {
  return 'toolu_' + Math.random().toString(36).substring(2, 15)
}

/**
 * Transforms an OpenAI-format SSE stream into an Anthropic-format SSE stream.
 *
 * Anthropic streaming events:
 * - message_start { message: { id, type, role, content: [], model, stop_reason, usage } }
 * - content_block_start { index, content_block: { type: 'text', text: '' } }
 * - content_block_delta { index, delta: { type: 'text_delta', text: '...' } }
 * - content_block_stop { index }
 * - message_delta { delta: { stop_reason, ... }, usage: { output_tokens } }
 * - message_stop
 */
function createOpenAIToAnthropicStreamTransformer(
  model: string,
): TransformStream<Uint8Array, Uint8Array> {
  const encoder = new TextEncoder()
  const decoder = new TextDecoder()

  const messageId = generateId()
  let headerSent = false
  let contentBlockIndex = 0
  let currentTextBlockOpen = false
  let currentToolCalls: Map<
    number,
    { id: string; name: string; arguments: string }
  > = new Map()
  let inputTokens = 0
  let outputTokens = 0
  let buffer = ''

  function emitSSE(event: string, data: any): Uint8Array {
    return encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`)
  }

  return new TransformStream({
    transform(chunk, controller) {
      buffer += decoder.decode(chunk, { stream: true })
      const lines = buffer.split('\n')
      // Keep the last incomplete line in the buffer
      buffer = lines.pop() || ''

      for (const line of lines) {
        if (!line.startsWith('data: ')) continue
        const data = line.slice(6).trim()
        if (data === '[DONE]') {
          // Close any open content blocks
          if (currentTextBlockOpen) {
            controller.enqueue(
              emitSSE('content_block_stop', { index: contentBlockIndex - 1 }),
            )
            currentTextBlockOpen = false
          }
          // Close any open tool call blocks
          for (const [idx] of currentToolCalls) {
            controller.enqueue(
              emitSSE('content_block_stop', { index: idx }),
            )
          }
          // message_delta with stop_reason
          controller.enqueue(
            emitSSE('message_delta', {
              type: 'message_delta',
              delta: { stop_reason: 'end_turn' },
              usage: { output_tokens: outputTokens },
            }),
          )
          controller.enqueue(emitSSE('message_stop', { type: 'message_stop' }))
          return
        }

        let parsed: OpenAIStreamChunk
        try {
          parsed = JSON.parse(data)
        } catch {
          continue
        }

        // Send message_start on the first chunk
        if (!headerSent) {
          headerSent = true
          controller.enqueue(
            emitSSE('message_start', {
              type: 'message_start',
              message: {
                id: messageId,
                type: 'message',
                role: 'assistant',
                content: [],
                model,
                stop_reason: null,
                stop_sequence: null,
                usage: {
                  input_tokens: 0,
                  output_tokens: 0,
                  cache_creation_input_tokens: 0,
                  cache_read_input_tokens: 0,
                },
              },
            }),
          )
        }

        // Track usage
        if (parsed.usage) {
          inputTokens = parsed.usage.prompt_tokens || 0
          outputTokens = parsed.usage.completion_tokens || 0
        }

        const choice = parsed.choices?.[0]
        if (!choice) continue

        const delta = choice.delta

        // Handle text content
        if (delta.content) {
          if (!currentTextBlockOpen) {
            controller.enqueue(
              emitSSE('content_block_start', {
                type: 'content_block_start',
                index: contentBlockIndex,
                content_block: { type: 'text', text: '' },
              }),
            )
            currentTextBlockOpen = true
          }
          controller.enqueue(
            emitSSE('content_block_delta', {
              type: 'content_block_delta',
              index: contentBlockIndex,
              delta: { type: 'text_delta', text: delta.content },
            }),
          )
        }

        // Handle tool calls
        if (delta.tool_calls) {
          // Close text block before tool calls
          if (currentTextBlockOpen) {
            controller.enqueue(
              emitSSE('content_block_stop', {
                type: 'content_block_stop',
                index: contentBlockIndex,
              }),
            )
            contentBlockIndex++
            currentTextBlockOpen = false
          }

          for (const tc of delta.tool_calls) {
            const tcIndex = tc.index
            let existing = currentToolCalls.get(tcIndex)

            if (tc.id && tc.function?.name && !existing) {
              // New tool call — start a content block
              const toolUseId = tc.id || generateToolUseId()
              existing = { id: toolUseId, name: tc.function.name, arguments: '' }
              currentToolCalls.set(tcIndex, existing)
              const blockIndex = contentBlockIndex + tcIndex
              controller.enqueue(
                emitSSE('content_block_start', {
                  type: 'content_block_start',
                  index: blockIndex,
                  content_block: {
                    type: 'tool_use',
                    id: toolUseId,
                    name: tc.function.name,
                    input: {},
                  },
                }),
              )
            }

            if (tc.function?.arguments && existing) {
              existing.arguments += tc.function.arguments
              const blockIndex = contentBlockIndex + tcIndex
              controller.enqueue(
                emitSSE('content_block_delta', {
                  type: 'content_block_delta',
                  index: blockIndex,
                  delta: {
                    type: 'input_json_delta',
                    partial_json: tc.function.arguments,
                  },
                }),
              )
            }
          }
        }

        // Handle finish reason
        if (choice.finish_reason) {
          // Close open text block
          if (currentTextBlockOpen) {
            controller.enqueue(
              emitSSE('content_block_stop', {
                type: 'content_block_stop',
                index: contentBlockIndex,
              }),
            )
            currentTextBlockOpen = false
          }

          // Close all tool call blocks
          for (const [tcIdx] of currentToolCalls) {
            const blockIndex = contentBlockIndex + tcIdx
            controller.enqueue(
              emitSSE('content_block_stop', {
                type: 'content_block_stop',
                index: blockIndex,
              }),
            )
          }

          // Map finish reasons
          let stopReason: string
          switch (choice.finish_reason) {
            case 'stop':
              stopReason = 'end_turn'
              break
            case 'tool_calls':
              stopReason = 'tool_use'
              break
            case 'length':
              stopReason = 'max_tokens'
              break
            default:
              stopReason = 'end_turn'
          }

          controller.enqueue(
            emitSSE('message_delta', {
              type: 'message_delta',
              delta: { stop_reason: stopReason },
              usage: { output_tokens: outputTokens },
            }),
          )
          controller.enqueue(emitSSE('message_stop', { type: 'message_stop' }))
        }
      }
    },

    flush(controller) {
      // Handle any remaining data in the buffer
      if (buffer.trim()) {
        // Try to process any remaining data
      }
    },
  })
}

// ============================================================================
// The core adapter fetch function
// ============================================================================

/**
 * Creates a fetch function that intercepts Anthropic SDK requests and
 * translates them to OpenAI-compatible API format.
 *
 * Usage in client.ts:
 *   const client = new Anthropic({
 *     apiKey: 'dummy',  // SDK requires a key, but we use OPENAI_API_KEY
 *     baseURL: process.env.OPENAI_BASE_URL,
 *     fetch: createOpenAIAdapterFetch(),
 *   })
 */
export function createOpenAIAdapterFetch(
  innerFetch?: typeof globalThis.fetch,
): typeof globalThis.fetch {
  // eslint-disable-next-line eslint-plugin-n/no-unsupported-features/node-builtins
  const baseFetch = innerFetch ?? globalThis.fetch

  return async (
    input: RequestInfo | URL,
    init?: RequestInit,
  ): Promise<Response> => {
    // Determine the URL
    // eslint-disable-next-line eslint-plugin-n/no-unsupported-features/node-builtins
    const url = input instanceof Request ? input.url : String(input)

    // Only intercept messages API calls — pass through everything else
    // The Anthropic SDK calls /v1/messages (or /v1/beta/messages)
    if (!url.includes('/messages') && !url.includes('/chat/completions')) {
      // For non-messages endpoints (e.g., /v1/models), proxy directly
      return baseFetch(input, init)
    }

    // Parse the Anthropic request body
    let anthropicBody: any
    try {
      const bodyStr =
        typeof init?.body === 'string'
          ? init.body
          : init?.body instanceof ArrayBuffer
            ? new TextDecoder().decode(init.body)
            : init?.body instanceof Uint8Array
              ? new TextDecoder().decode(init.body)
              : ''
      anthropicBody = JSON.parse(bodyStr)
    } catch {
      // If we can't parse the body, pass through
      return baseFetch(input, init)
    }

    // Convert to OpenAI format
    const openAIBody = convertAnthropicRequestToOpenAI(anthropicBody)
    const isStreaming = openAIBody.stream

    // Build the target URL — replace Anthropic's /v1/messages with OpenAI's /chat/completions
    const baseUrl = (
      process.env.OPENAI_BASE_URL || 'http://localhost:8000/v1'
    ).replace(/\/$/, '')
    const targetUrl = `${baseUrl}/chat/completions`

    // Build headers
    const apiKey = process.env.OPENAI_API_KEY || ''
    const isCnbMode = process.env.CLAUDE_CODE_USE_CNB === '1'
    // eslint-disable-next-line eslint-plugin-n/no-unsupported-features/node-builtins
    const headers = new Headers()
    headers.set('Content-Type', 'application/json')
    if (apiKey) {
      // CNB uses raw token (no Bearer prefix); standard OpenAI uses Bearer
      headers.set('Authorization', isCnbMode ? apiKey : `Bearer ${apiKey}`)
    }
    if (isCnbMode) {
      headers.set('Accept', 'application/vnd.cnb.api+json')
    }
    // Forward custom headers if any
    if (init?.headers) {
      // eslint-disable-next-line eslint-plugin-n/no-unsupported-features/node-builtins
      const initHeaders = new Headers(init.headers as HeadersInit)
      // Preserve specific headers
      for (const key of [
        'x-client-request-id',
        'x-app',
        'User-Agent',
      ]) {
        const val = initHeaders.get(key)
        if (val) headers.set(key, val)
      }
    }

    // Make the actual request to the OpenAI-compatible endpoint
    const response = await baseFetch(targetUrl, {
      method: 'POST',
      headers,
      body: JSON.stringify(openAIBody),
      signal: init?.signal,
    })

    if (!response.ok) {
      // Try to return a meaningful error in Anthropic format
      let errorBody: string
      try {
        errorBody = await response.text()
      } catch {
        errorBody = `HTTP ${response.status}`
      }

      const anthropicError = {
        type: 'error',
        error: {
          type: 'api_error',
          message: `OpenAI-compatible API error (${response.status}): ${errorBody}`,
        },
      }

      return new Response(JSON.stringify(anthropicError), {
        status: response.status,
        headers: {
          'Content-Type': 'application/json',
          // Add fake Anthropic headers so the SDK doesn't break
          'x-request-id': `openai-compat-${Date.now()}`,
        },
      })
    }

    if (!isStreaming) {
      // Non-streaming: convert OpenAI response to Anthropic format
      const openAIResponse = await response.json()
      const anthropicResponse = convertOpenAINonStreamingToAnthropic(
        openAIResponse,
        openAIBody.model,
      )
      return new Response(JSON.stringify(anthropicResponse), {
        status: 200,
        headers: {
          'Content-Type': 'application/json',
          'x-request-id': `openai-compat-${Date.now()}`,
        },
      })
    }

    // Streaming: transform the SSE stream from OpenAI format to Anthropic format
    if (!response.body) {
      return new Response('No response body', { status: 500 })
    }

    const transformedStream = response.body.pipeThrough(
      createOpenAIToAnthropicStreamTransformer(openAIBody.model),
    )

    return new Response(transformedStream, {
      status: 200,
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
        'x-request-id': `openai-compat-${Date.now()}`,
      },
    })
  }
}

// ============================================================================
// Non-streaming response conversion
// ============================================================================

function convertOpenAINonStreamingToAnthropic(
  openAIResponse: any,
  model: string,
): any {
  const choice = openAIResponse.choices?.[0]
  if (!choice) {
    return {
      id: generateId(),
      type: 'message',
      role: 'assistant',
      content: [],
      model,
      stop_reason: 'end_turn',
      stop_sequence: null,
      usage: { input_tokens: 0, output_tokens: 0 },
    }
  }

  const content: any[] = []

  // Text content
  if (choice.message?.content) {
    content.push({ type: 'text', text: choice.message.content })
  }

  // Tool calls
  if (choice.message?.tool_calls) {
    for (const tc of choice.message.tool_calls) {
      let parsedArgs: any = {}
      try {
        parsedArgs = JSON.parse(tc.function.arguments || '{}')
      } catch {
        parsedArgs = {}
      }
      content.push({
        type: 'tool_use',
        id: tc.id || generateToolUseId(),
        name: tc.function.name,
        input: parsedArgs,
      })
    }
  }

  // Map finish reason
  let stopReason: string
  switch (choice.finish_reason) {
    case 'stop':
      stopReason = 'end_turn'
      break
    case 'tool_calls':
      stopReason = 'tool_use'
      break
    case 'length':
      stopReason = 'max_tokens'
      break
    default:
      stopReason = 'end_turn'
  }

  return {
    id: openAIResponse.id || generateId(),
    type: 'message',
    role: 'assistant',
    content,
    model: openAIResponse.model || model,
    stop_reason: stopReason,
    stop_sequence: null,
    usage: {
      input_tokens: openAIResponse.usage?.prompt_tokens || 0,
      output_tokens: openAIResponse.usage?.completion_tokens || 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
    },
  }
}
