// Copyright (c) 2025 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/data.jsondata;
import ballerina/http;

# Configurations for controlling the behaviours when communicating with a remote HTTP endpoint.
@display {label: "Connection Configuration"}
public type ConnectionConfig record {|

    # The HTTP version understood by the client
    @display {label: "HTTP Version"}
    http:HttpVersion httpVersion = http:HTTP_2_0;

    # Configurations related to HTTP/1.x protocol
    @display {label: "HTTP1 Settings"}
    http:ClientHttp1Settings http1Settings?;

    # Configurations related to HTTP/2 protocol
    @display {label: "HTTP2 Settings"}
    http:ClientHttp2Settings http2Settings?;

    # The maximum time to wait (in seconds) for a response before closing the connection
    @display {label: "Timeout"}
    decimal timeout = 60;

    # The choice of setting `forwarded`/`x-forwarded` header
    @display {label: "Forwarded"}
    string forwarded = "disable";

    # Configurations associated with request pooling
    @display {label: "Pool Configuration"}
    http:PoolConfiguration poolConfig?;

    # HTTP caching related configurations
    @display {label: "Cache Configuration"}
    http:CacheConfig cache?;

    # Specifies the way of handling compression (`accept-encoding`) header
    @display {label: "Compression"}
    http:Compression compression = http:COMPRESSION_AUTO;

    # Configurations associated with the behaviour of the Circuit Breaker
    @display {label: "Circuit Breaker Configuration"}
    http:CircuitBreakerConfig circuitBreaker?;

    # Configurations associated with retrying
    @display {label: "Retry Configuration"}
    http:RetryConfig retryConfig?;

    # Configurations associated with inbound response size limits
    @display {label: "Response Limit Configuration"}
    http:ResponseLimitConfigs responseLimits?;

    # SSL/TLS-related options
    @display {label: "Secure Socket Configuration"}
    http:ClientSecureSocket secureSocket?;

    # Proxy server related options
    @display {label: "Proxy Configuration"}
    http:ProxyConfig proxy?;

    # Enables the inbound payload validation functionality which provided by the constraint package. Enabled by default
    @display {label: "Payload Validation"}
    boolean validation = true;
|};

// Configs obtained from: https://github.com/ollama/ollama/blob/main/docs/modelfile.md#parameter
# Represents the model parameters for Ollama text generation.
# These parameters control the behavior and output of the model.
@display {label: "Ollama Model Parameters"}
public type OllamaModelParameters record {|
    # Enable Mirostat sampling for controlling perplexity.  
    # - `0` = disabled  
    # - `1` = Mirostat  
    # - `2` = Mirostat 2.0  
    @display {label: "Mirostat Sampling"}
    0|1|2 mirostat = 0;

    # Influences how quickly the algorithm responds to feedback from the generated text.  
    # A lower value results in slower adjustments, while a higher value makes the model more responsive.  
    @jsondata:Name {value: "mirostat_eta"}
    @display {label: "Mirostat eta"}
    float mirostatEta = 0.1;

    # Controls the balance between coherence and diversity of the output.  
    # A lower value results in more focused and coherent text.  
    @jsondata:Name {value: "mirostat_tau"}
    @display {label: "Mirostat tau"}
    float mirostatTau = 5.0;

    # Sets the size of the context window used to generate the next token.  
    @jsondata:Name {value: "num_ctx"}
    @display {label: "Context Window Size"}
    int numCtx = 2048;

    # Sets how far back the model should look to prevent repetition.  
    # - `0` = disabled  
    # - `-1` = num_ctx  
    @jsondata:Name {value: "repeat_last_n"}
    @display {label: "Repeat Last N"}
    int repeatLastN = 64;

    # Sets how strongly to penalize repetitions.  
    # A higher value (e.g., `1.5`) will penalize repetitions more strongly,  
    # while a lower value (e.g., `0.9`) will be more lenient.  
    @jsondata:Name {value: "repeat_penalty"}
    @display {label: "Repeat Penalty"}
    float repeatPenalty = 1.1;

    # Controls the creativity of the model's responses.  
    # A higher value makes the output more diverse, while a lower value makes it more focused.  
    @display {label: "Temperature"}
    float temperature = 0.8;

    # Sets the random number seed for deterministic text generation.  
    # A specific value ensures the same output for identical prompts.  
    @display {label: "Seed"}
    int seed = 0;

    # Maximum number of tokens to generate.  
    # `-1` allows infinite generation.  
    @jsondata:Name {value: "num_predict"}
    @display {label: "Number of Tokens to Predict"}
    int numPredict = -1;

    # Controls randomness by selecting the top-k most likely next words.  
    # A higher value (e.g., `100`) increases diversity,  
    # while a lower value (e.g., `10`) makes responses more conservative.  
    @jsondata:Name {value: "top_k"}
    @display {label: "Top K"}
    int topK = 40;

    # Controls randomness by considering the cumulative probability of choices.  
    # A higher value (e.g., `0.95`) increases diversity,  
    # while a lower value (e.g., `0.5`) makes responses more conservative.  
    @jsondata:Name {value: "top_p"}
    @display {label: "Top P"}
    float topP = 0.9;

    # Ensures a balance between quality and variety.  
    # Filters out low-probability tokens relative to the highest probability token.  
    @jsondata:Name {value: "min_p"}
    @display {label: "Min P"}
    float minP = 0.0;
|};

// https://github.com/ollama/ollama/blob/main/docs/api.md#response-36
type OllamaResponse record {
    string model;
    OllamaMessage message;
    string done_reason?;
    int prompt_eval_count?;
    int eval_count?;
};

type OllamaMessage record {
    string role;
    string content;
    // Present when `think` is enabled and the model supports reasoning. Streamed
    // chunks accumulate it the same way they accumulate `content`.
    string thinking?;
    OllamaToolCall[] tool_calls?;
};

type OllamaToolCall record {
    OllamaFunction 'function;
};

type OllamaFunction record {
    string name;
    map<json> arguments;
};

const FUNCTION = "function";

// ── Ollama streamed chat response ───────────────────────────────
// Models the chunks the /api/chat endpoint emits when `stream` is true. The
// message shape is shared with the non-streamed `OllamaResponse` above, so the
// two cannot drift apart.
// Reference: https://docs.ollama.com/api/chat

# A single streamed chunk from the /api/chat endpoint when `stream` is true.
# Intermediate chunks carry a partial `message` with `done` set to false; the
# terminal chunk sets `done` to true and includes the timing and token counts.
type OllamaChatStreamResponse record {
    # The model generating the response
    string model;
    # ISO 8601 timestamp of when this chunk was created
    string created_at;
    # The incremental message fragment for this chunk; its `content` and
    # `thinking` fields accumulate across chunks
    OllamaMessage message;
    # Whether this is the final chunk of the stream
    boolean done;
    # The reason generation stopped; present only on the final chunk
    string done_reason?;
    # Total time spent generating the response, in nanoseconds; present on the
    # final chunk
    int total_duration?;
    # Time spent loading the model, in nanoseconds; present on the final chunk
    int load_duration?;
    # Number of tokens in the prompt; present on the final chunk
    int prompt_eval_count?;
    # Time spent evaluating the prompt, in nanoseconds; present on the final chunk
    int prompt_eval_duration?;
    # Number of tokens in the generated response; present on the final chunk
    int eval_count?;
    # Time spent generating the response, in nanoseconds; present on the final chunk
    int eval_duration?;
};

// ── Wire → normalized mapping ──────────────────────────────────────────────
// Projects an Ollama streamed chunk (the wire types above) onto the normalized
// `ai:ChatCompletionChunk` that `chatStream` must return. Only the subset the
// `ai` type can hold is mapped; timings and log probabilities are ignored.

# The `done_reason` Ollama reports when generation ended at a natural stop point
# or a provided stop sequence.
const DONE_REASON_STOP = "stop";

# The `done_reason` Ollama reports when generation hit the token limit.
const DONE_REASON_LENGTH = "length";

# Maps an Ollama streamed chunk onto the normalized `ai:ChatCompletionChunk`.
#
# Ollama differs from the OpenAI wire format in three ways that this mapping
# smooths over:
# - There is no `id`, so the normalized chunk carries only the model name.
# - Tool calls arrive fully formed (name plus a complete arguments object) rather
#   than as argument fragments, and carry no index. The caller supplies a running
#   `toolCallIndexOffset` so that fragments stay addressable by `index` in the
#   same way as for providers that do split them, and the arguments object is
#   serialized to the JSON string the normalized type expects.
# - Ollama repeats the role on every chunk and reports `done_reason` "stop" even
#   when the turn ended in tool calls, so the caller supplies the stream-level
#   context needed to correct both.
#
# + chunk - The parsed Ollama chunk
# + toolCallIndexOffset - Index to assign to the first tool call in this chunk
# + sawToolCalls - Whether any tool call has been seen so far in this stream
# + emitRole - Whether this is the first delta of the stream, which is the only
#              one the normalized type carries a role on
# + return - The normalized chunk consumed by the `ai` module
isolated function toAiChunk(OllamaChatStreamResponse chunk, int toolCallIndexOffset, boolean sawToolCalls,
        boolean emitRole) returns ai:ChatCompletionChunk {
    OllamaMessage message = chunk.message;
    ai:ChatCompletionChunkDelta delta = {};
    // The normalized type reserves `()` for a delta that carries no answer text;
    // Ollama sends an empty string on tool-call and terminal chunks instead.
    string content = message.content;
    if content.length() > 0 {
        delta.content = content;
    }
    ai:ROLE? role = mapRole(message.role);
    if emitRole && role is ai:ROLE {
        delta.role = role;
    }
    string? thinking = message?.thinking;
    if thinking is string {
        delta.reasoning = thinking;
    }
    OllamaToolCall[]? wireToolCalls = message?.tool_calls;
    if wireToolCalls is OllamaToolCall[] {
        ai:ToolCallChunk[] toolCalls = [];
        foreach int i in 0 ..< wireToolCalls.length() {
            OllamaFunction 'function = wireToolCalls[i].'function;
            toolCalls.push({
                index: toolCallIndexOffset + i,
                'function: {
                    name: 'function.name,
                    arguments: 'function.arguments.toJsonString()
                }
            });
        }
        delta.toolCalls = toolCalls;
    }

    ai:FinishReason? finishReason = ();
    if chunk.done {
        string? doneReason = chunk?.done_reason;
        // Only Ollama's "stop" is corrected to `tool_calls`. A turn that really ran
        // into the token limit keeps `length`, because reporting `tool_calls` there
        // would hide the truncation from the caller.
        finishReason = sawToolCalls && doneReason == DONE_REASON_STOP ? ai:TOOL_CALLS
            : mapFinishReason(doneReason);
    }

    ai:ChatCompletionChunk aiChunk = {
        model: chunk.model,
        choices: [{index: 0, delta, finishReason}]
    };

    // Token counts arrive only on the terminal chunk; Ollama reports the prompt
    // and completion counts separately and no total, so the total is derived.
    int? promptTokens = chunk?.prompt_eval_count;
    int? completionTokens = chunk?.eval_count;
    if promptTokens is int || completionTokens is int {
        ai:CompletionTokenUsage usage = {};
        if promptTokens is int {
            usage.promptTokens = promptTokens;
        }
        if completionTokens is int {
            usage.completionTokens = completionTokens;
        }
        if promptTokens is int && completionTokens is int {
            usage.totalTokens = promptTokens + completionTokens;
        }
        aiChunk.usage = usage;
    }
    return aiChunk;
}

# Safely maps an Ollama message role onto the `ai:ROLE` enum; returns `()` for
# roles the `ai` enum cannot represent rather than panicking on a cast.
#
# + role - The role from the wire message
# + return - The mapped `ai:ROLE`, or `()` when unrepresentable
isolated function mapRole(string role) returns ai:ROLE? {
    // Streamed response messages only ever carry the "assistant" role;
    // "system"/"user" are handled for completeness. Ollama's "tool" role has no
    // counterpart in the `ai` enum, so it maps to `()`.
    match role {
        "system" => {
            return ai:SYSTEM;
        }
        "user" => {
            return ai:USER;
        }
        "assistant" => {
            return ai:ASSISTANT;
        }
    }
    return ();
}

# Safely maps an Ollama `done_reason` onto the `ai:FinishReason` enum. Ollama
# also reports lifecycle reasons such as "load" and "unload", which have no
# counterpart in the `ai` enum and map to `()`.
#
# + doneReason - The `done_reason` from the terminal chunk
# + return - The mapped `ai:FinishReason`, or `()` when absent/unrepresentable
isolated function mapFinishReason(string? doneReason) returns ai:FinishReason? {
    if doneReason == DONE_REASON_STOP {
        return ai:STOP;
    }
    if doneReason == DONE_REASON_LENGTH {
        return ai:LENGTH;
    }
    return ();
}
