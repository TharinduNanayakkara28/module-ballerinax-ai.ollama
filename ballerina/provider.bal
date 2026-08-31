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
import ballerina/ai.observe;
import ballerina/data.jsondata;
import ballerina/http;
import ballerina/jballerina.java;
import ballerina/log;

const DEFAULT_OLLAMA_SERVICE_URL = "http://localhost:11434";
const TOOL_ROLE = "tool";

# Provider represents a client for interacting with an Ollama language models.
@display {
    label: "Ollama Model Provider"
}
public isolated client class ModelProvider {
    *ai:ModelProvider;
    private final http:Client ollamaClient;
    private final string modelType;
    private final readonly & map<json> modleParameters;
    private final float temperature;

    # Initializes the client with the given connection configuration and model configuration.
    #
    # + modelType - The Ollama model name
    # + serviceUrl - The base URL for the Ollama API endpoint
    # + modleParameters - Additional model parameters
    # + connectionConfig - Additional connection configuration
    # + return - `nil` on success, otherwise an `ai:Error`. 
    public isolated function init(@display {label: "Model Type"} string modelType,
            @display {label: "Service URL"} string serviceUrl = DEFAULT_OLLAMA_SERVICE_URL,
            @display {label: "Ollama Model Parameters"} *OllamaModelParameters modleParameters,
            @display {label: "Connection Configuration"} *ConnectionConfig connectionConfig) returns ai:Error? {
        http:ClientConfiguration clientConfig = {...connectionConfig};
        http:Client|error ollamaClient = new (serviceUrl, clientConfig);
        if ollamaClient is error {
            return error("Error while connecting to the model", ollamaClient);
        }
        self.modleParameters = check getModelParameterMap(modleParameters);
        self.temperature = modleParameters.temperature;
        self.ollamaClient = ollamaClient;
        self.modelType = modelType;
    }

    # Sends a chat request to the Ollama model with the given messages and tools.
    #
    # + messages - List of chat messages or user message
    # + tools - Tool definitions to be used for the tool call
    # + stop - Stop sequence to stop the completion
    # + return - Function to be called, chat response or an error in-case of failures
    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages, ai:ChatCompletionFunctions[] tools = [],
            string? stop = ()) returns ai:ChatAssistantMessage|ai:Error {
        observe:ChatSpan span = observe:createChatSpan(self.modelType);
        span.addProvider("ollama");
        if stop is string {
            span.addStopSequence(stop);
        }
        span.addTemperature(self.temperature);
        json|ai:Error inputMessage = convertMessageToJson(messages);
        if inputMessage is json {
            span.addInputMessages(inputMessage);
        }
        if tools.length() > 0 {
            span.addTools(tools);
        }

        // Ollama chat completion API reference: https://github.com/ollama/ollama/blob/main/docs/api.md#generate-a-chat-completion
        json|ai:Error requestPayload = self.prepareRequestPayload(messages, tools, stop);
        if requestPayload is ai:Error {
            span.close(requestPayload);
            return requestPayload;
        }
        OllamaResponse|error response = self.ollamaClient->/api/chat.post(requestPayload);
        if response is error {
            ai:Error err = error("Error while connecting to ollama", response);
            span.close(err);
            return err;
        }

        int? inputTokens = response.prompt_eval_count;
        if inputTokens is int {
            span.addInputTokenCount(inputTokens);
        }
        int? outputTokens = response.eval_count;
        if outputTokens is int {
            span.addOutputTokenCount(outputTokens);
        }
        string? finishReason = response.done_reason;
        if finishReason is string {
            span.addFinishReason(finishReason);
        }

        ai:ChatAssistantMessage|ai:Error result = self.mapOllamaResponseToAssistantMessage(response);
        if result is ai:Error {
            span.close(result);
            return result;
        }
        span.addOutputMessages(result);
        span.addOutputType(observe:TEXT);
        span.close();
        return result;
    }

    # Sends a chat request to the model and generates a value that belongs to the type
    # corresponding to the type descriptor argument.
    #
    # + prompt - The prompt to use in the chat messages
    # + td - Type descriptor specifying the expected return type format
    # + return - Generates a value that belongs to the type, or an error if generation fails
    isolated remote function generate(ai:Prompt prompt, @display {label: "Expected type"} typedesc<anydata> td = <>)
            returns td|ai:Error = @java:Method {
        'class: "io.ballerina.lib.ai.ollama.Generator"
    } external;

    # Sends a streaming chat request to the Ollama model with the given messages and tools.
    #
    # The returned stream holds the connection open for as long as the model keeps
    # producing tokens, so a long generation can outlive the client's default timeout;
    # raise `timeout` in the connection configuration when that is a risk. Close the
    # stream if iteration stops early, so the connection is released.
    #
    # + messages - List of chat messages or user message
    # + tools - Tool definitions to be used for the tool call
    # + stop - Stop sequence to stop the completion
    # + return - A stream of chat completion chunks, or an error in-case of failures
    remote function chatStream(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ())
            returns stream<ai:ChatCompletionChunk, ai:Error?>|ai:Error {
        observe:ChatSpan span = observe:createChatSpan(self.modelType);
        span.addProvider("ollama");
        if stop is string {
            span.addStopSequence(stop);
        }
        span.addTemperature(self.temperature);
        json|ai:Error inputMessage = convertMessageToJson(messages);
        if inputMessage is json {
            span.addInputMessages(inputMessage);
        }
        if tools.length() > 0 {
            span.addTools(tools);
        }

        // Ollama streams newline-delimited JSON rather than Server-Sent Events, so
        // the raw response is consumed as a byte stream and split into lines.
        json|ai:Error payload = self.prepareRequestPayload(messages, tools, stop, true);
        if payload is ai:Error {
            span.close(payload);
            return payload;
        }
        http:Response|error response = self.ollamaClient->post("/api/chat", payload);
        if response is error {
            ai:Error err = error ai:LlmConnectionError("Error while connecting to ollama for streaming", response);
            span.close(err);
            return err;
        }
        if response.statusCode != http:STATUS_OK {
            string|error body = response.getTextPayload();
            ai:Error err = error ai:LlmConnectionError(string `Ollama returned a non-OK status ` +
                    string `${response.statusCode} for the streaming request: ${body is string ? body : ""}`);
            span.close(err);
            return err;
        }
        stream<byte[], error?>|error byteStream = response.getByteStream();
        if byteStream is error {
            ai:Error err = error ai:LlmConnectionError("Failed to open the response stream from the model", byteStream);
            span.close(err);
            return err;
        }
        // The span outlives this call: it stays open for as long as the stream is
        // being consumed, and the iterator closes it once the stream ends.
        stream<ai:ChatCompletionChunk, ai:Error?> chunkStream = new (new OllamaChunkIterator(byteStream, span));
        return chunkStream;
    }

    # Sends a streaming chat request to the model using the given prompt and streams
    # back the generated answer. Only `string` is supported as the expected type.
    #
    # As with `chatStream`, a long generation can outlive the client's default timeout;
    # raise `timeout` in the connection configuration when that is a risk.
    #
    # + prompt - The prompt to use in the chat request
    # + td - The expected type of the streamed value; must be `string`
    # + return - A stream of the generated value, or an error if the type is unsupported
    remote function generateStream(ai:Prompt prompt, @display {label: "Expected type"} typedesc<anydata> td = <>)
            returns stream<td, ai:Error?>|ai:Error = @java:Method {
        'class: "io.ballerina.lib.ai.ollama.StreamGenerator"
    } external;

    private isolated function prepareRequestPayload(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools, string? stop, boolean 'stream = false) returns json|ai:Error {
        map<json> options = {...self.modleParameters};
        if stop is string {
            options["stop"] = [stop];
        }

        map<json> payload = {
            model: self.modelType,
            messages: check self.mapToOllamaRequestMessage(messages),
            'stream,
            options
        };
        if tools.length() > 0 {
            payload["tools"] = tools.'map(tool => {'type: FUNCTION, 'function: tool});
        }
        return payload;
    }

    private isolated function mapToOllamaRequestMessage(ai:ChatMessage[]|ai:ChatUserMessage messages)
    returns json[]|ai:Error {
        json[] transformedMessages = [];
        if messages is ai:ChatUserMessage {
            transformedMessages.push({
                role: ai:USER,
                content: check getChatMessageStringContent(messages?.content)
            });
            return transformedMessages;
        }
        foreach ai:ChatMessage message in messages {
            if message is ai:ChatFunctionMessage {
                transformedMessages.push({role: TOOL_ROLE, content: message?.content});

            } else if message is ai:ChatUserMessage {
                transformedMessages.push({
                    role: ai:USER,
                    content: check getChatMessageStringContent(message.content)
                });

            } else if message is ai:ChatSystemMessage {
                transformedMessages.push({
                    role: ai:SYSTEM,
                    content: check getChatMessageStringContent(message.content)
                });
            } else if message is ai:ChatAssistantMessage {
                transformedMessages.push(message);
            }
        }
        return transformedMessages;
    }

    private isolated function mapOllamaResponseToAssistantMessage(OllamaResponse response)
        returns ai:ChatAssistantMessage {
        OllamaToolCall[]? toolCalls = response.message?.tool_calls;
        if toolCalls is OllamaToolCall[] {
            return self.mapToolCallsToAssistantMessage(toolCalls);
        }
        return {role: ai:ASSISTANT, content: response.message.content};
    }

    private isolated function mapToolCallsToAssistantMessage(OllamaToolCall[] ollamaToolCalls)
        returns ai:ChatAssistantMessage {
        ai:FunctionCall[] toolCalls = from OllamaToolCall toolCall in ollamaToolCalls
            select {
                name: toolCall.'function.name,
                arguments: toolCall.'function.arguments
            };
        return {role: ai:ASSISTANT, toolCalls};
    }
}

isolated function getModelParameterMap(OllamaModelParameters modleParameters) returns readonly & map<json>|ai:Error {
    do {
        json options = jsondata:toJson(modleParameters);
        map<json> & readonly readonlyOptions = check options.cloneWithType();
        return readonlyOptions;
    } on fail error e {
        return error("Error while processing model parameters", e);
    }
}

isolated function getChatMessageStringContent(ai:Prompt|string prompt) returns string|ai:Error {
    if prompt is string {
        return prompt;
    }
    string[] & readonly strings = prompt.strings;
    anydata[] insertions = prompt.insertions;
    string promptStr = strings[0];
    foreach int i in 0 ..< insertions.length() {
        string str = strings[i + 1];
        anydata insertion = insertions[i];

        if insertion is ai:TextDocument|ai:TextChunk {
            promptStr += insertion.content + " " + str;
            continue;
        }

        if insertion is ai:TextDocument[] {
            foreach ai:TextDocument doc in insertion {
                promptStr += doc.content + " ";
            }
            promptStr += str;
            continue;
        }

        if insertion is ai:TextChunk[] {
            foreach ai:TextChunk doc in insertion {
                promptStr += doc.content + " ";
            }
            promptStr += str;
            continue;
        }

        if insertion is ai:Document {
            return error ai:Error("Only Text Documents are currently supported.");
        }

        promptStr += insertion.toString() + str;
    }
    return promptStr.trim();
}

isolated function convertMessageToJson(ai:ChatMessage[]|ai:ChatMessage messages) returns json|ai:Error {
    if messages is ai:ChatMessage[] {
        return messages.'map(msg => msg is ai:ChatUserMessage|ai:ChatSystemMessage ? check convertMessageToJson(msg) : msg);
    }
    if messages is ai:ChatUserMessage|ai:ChatSystemMessage {

    }
    return messages !is ai:ChatUserMessage|ai:ChatSystemMessage ? messages :
        {role: messages.role, content: check getChatMessageStringContent(messages.content), name: messages.name};
}

# The line-feed byte that delimits the JSON objects of an Ollama stream.
final byte NEWLINE = 10;

# Upper bound on the bytes held while waiting for a line delimiter. An Ollama
# chunk is a few hundred bytes, so crossing this means the peer is not speaking
# newline-delimited JSON; the read is failed rather than buffered without limit.
const int MAX_BUFFERED_LINE_BYTES = 10 * 1024 * 1024;

# Iterator that converts Ollama's newline-delimited JSON stream into a stream of
# normalized `ai:ChatCompletionChunk` values.
#
# Unlike the Server-Sent Event streams of OpenAI-compatible APIs, Ollama writes
# one bare JSON object per line with no framing and no end sentinel; the terminal
# chunk is the one with `done` set to true. Lines are assembled at the byte level
# so that a multi-byte character split across two network reads is not corrupted.
#
# Ollama emits each tool call fully formed and without an index, so this iterator
# keeps a running index across the whole stream and hands it to `toAiChunk`,
# giving consumers the same index-keyed accumulation model as providers that
# stream tool-call arguments in fragments.
class OllamaChunkIterator {
    private stream<byte[], error?> byteStream;
    private observe:ChatSpan span;
    private byte[] buffer = [];
    private boolean byteStreamDrained = false;
    private boolean streamComplete = false;
    private boolean byteStreamClosed = false;
    private int nextToolCallIndex = 0;
    private boolean sawToolCalls = false;
    private boolean roleEmitted = false;

    isolated function init(stream<byte[], error?> byteStream, observe:ChatSpan span) {
        self.byteStream = byteStream;
        self.span = span;
    }

    public isolated function next() returns record {|ai:ChatCompletionChunk value;|}|ai:Error? {
        if self.streamComplete {
            return ();
        }
        while true {
            string?|ai:Error line = self.nextLine();
            if line is ai:Error {
                return self.failStream(line);
            }
            if line is () {
                // A well-formed Ollama stream always ends with a `done` chunk, so
                // running out of bytes before one arrives means the response was cut
                // short. Reporting completion here would pass a partial answer off as
                // a whole one.
                return self.failStream(error ai:LlmInvalidResponseError(
                        "The model stream ended before the final chunk was received"));
            }
            string trimmedLine = line.trim();
            if trimmedLine == "" {
                continue;
            }
            json|error payload = trimmedLine.fromJsonString();
            if payload is error {
                return self.failStream(
                        error ai:LlmInvalidResponseError("Error while parsing a chunk of the model stream", payload));
            }
            // Ollama reports mid-stream failures as a bare `{"error": "..."}` object.
            if payload is map<json> {
                json errorMessage = payload["error"];
                if errorMessage is string {
                    return self.failStream(
                            error ai:LlmError(string `Ollama reported an error while streaming: ${errorMessage}`));
                }
            }
            OllamaChatStreamResponse|error chunk = payload.cloneWithType();
            if chunk is error {
                return self.failStream(
                        error ai:LlmInvalidResponseError("Error while binding a chunk of the model stream", chunk));
            }

            int toolCallIndexOffset = self.nextToolCallIndex;
            OllamaToolCall[]? toolCalls = chunk.message?.tool_calls;
            if toolCalls is OllamaToolCall[] && toolCalls.length() > 0 {
                self.nextToolCallIndex += toolCalls.length();
                self.sawToolCalls = true;
            }
            // Ollama stamps the role on every chunk; the normalized type carries it
            // on the first delta only.
            boolean emitRole = !self.roleEmitted;
            self.roleEmitted = true;

            ai:ChatCompletionChunk aiChunk = toAiChunk(chunk, toolCallIndexOffset, self.sawToolCalls, emitRole);
            if chunk.done {
                // The terminal chunk is still handed to the caller; only the span and
                // the connection behind it are released.
                self.recordCompletion(aiChunk);
                self.terminate();
            }
            return {value: aiChunk};
        }
    }

    public isolated function close() returns ai:Error? {
        self.streamComplete = true;
        if self.byteStreamClosed {
            return ();
        }
        self.byteStreamClosed = true;
        // A caller that abandons the stream early still ends the span here.
        self.span.close();
        error? result = self.byteStream.close();
        if result is error {
            return error ai:Error("Error while closing the model stream", result);
        }
        return ();
    }

    # Records the telemetry Ollama reports only on the terminal chunk, before the
    # span is closed.
    #
    # + chunk - The normalized terminal chunk
    private isolated function recordCompletion(ai:ChatCompletionChunk chunk) {
        string? responseModel = chunk.model;
        if responseModel is string {
            self.span.addResponseModel(responseModel);
        }
        ai:FinishReason? finishReason = chunk.choices[0].finishReason;
        if finishReason is ai:FinishReason {
            self.span.addFinishReason(finishReason);
        }
        ai:CompletionTokenUsage? usage = chunk.usage;
        if usage is ai:CompletionTokenUsage {
            int? promptTokens = usage.promptTokens;
            if promptTokens is int {
                self.span.addInputTokenCount(promptTokens);
            }
            int? completionTokens = usage.completionTokens;
            if completionTokens is int {
                self.span.addOutputTokenCount(completionTokens);
            }
        }
        self.span.addOutputType(observe:TEXT);
    }

    # Terminates the stream and surfaces `err`, so that a caller driving the
    # iterator by hand cannot re-enter the read loop on an already-failed stream.
    #
    # + err - The error to report to the caller
    # + return - The same error
    private isolated function failStream(ai:Error err) returns ai:Error {
        self.terminate(err);
        return err;
    }

    # Marks the stream terminated, ends the span and releases the underlying byte
    # stream. Closing the byte stream is best effort: every value the caller can
    # still observe has already been produced, so a failure to close must not
    # displace the outcome they are waiting on.
    #
    # + err - The error that ended the stream, or `()` when it ended normally
    private isolated function terminate(ai:Error? err = ()) {
        self.streamComplete = true;
        if self.byteStreamClosed {
            return;
        }
        self.byteStreamClosed = true;
        self.span.close(err);
        error? closeResult = self.byteStream.close();
        if closeResult is error {
            log:printDebug("Failed to close the model stream", closeResult);
        }
    }

    # Pulls the next newline-delimited line out of the byte stream, buffering
    # partial reads until a delimiter arrives. The trailing bytes left when the
    # byte stream ends without a final newline are returned as the last line.
    #
    # + return - The next line, `()` once the byte stream is exhausted, or an error
    private isolated function nextLine() returns string?|ai:Error {
        while true {
            int? newlineIndex = self.buffer.indexOf(NEWLINE);
            if newlineIndex is int {
                byte[] lineBytes = self.buffer.slice(0, newlineIndex);
                self.buffer = self.buffer.slice(newlineIndex + 1);
                return decodeLine(lineBytes);
            }
            if self.byteStreamDrained {
                if self.buffer.length() == 0 {
                    return ();
                }
                byte[] lineBytes = self.buffer;
                self.buffer = [];
                return decodeLine(lineBytes);
            }
            record {|byte[] value;|}|error? next = self.byteStream.next();
            if next is error {
                return error ai:LlmConnectionError("Error while reading the model stream", next);
            }
            if next is () {
                self.byteStreamDrained = true;
                continue;
            }
            self.buffer.push(...next.value);
            if self.buffer.length() > MAX_BUFFERED_LINE_BYTES {
                return error ai:LlmInvalidResponseError(string `The model stream produced more than ${
                        MAX_BUFFERED_LINE_BYTES} bytes without a line delimiter`);
            }
        }
    }
}

# Decodes the bytes of one stream line as UTF-8.
#
# + lineBytes - The bytes of a single line, excluding the delimiter
# + return - The decoded line, or an error if the bytes are not valid UTF-8
isolated function decodeLine(byte[] lineBytes) returns string|ai:Error {
    string|error line = string:fromBytes(lineBytes);
    if line is error {
        return error ai:LlmInvalidResponseError("Error while decoding a chunk of the model stream", line);
    }
    return line;
}

# Builds the string stream returned by `ModelProvider.generateStream`. The native
# `StreamGenerator` shim trampolines here so the type gating stays in Ballerina.
# Only `string` is supported; other types yield an error because a partial
# generation is a valid value only for `string`. When valid, the underlying
# `chatStream` chunks are projected onto their text fragments.
#
# + llmModel - The model provider whose `chatStream` supplies the chunks
# + prompt - The prompt to send to the model
# + td - The caller's expected type; must be `string`
# + return - A stream of text fragments, or an error if the type is unsupported
function generateLlmResponseStream(ModelProvider llmModel, ai:Prompt prompt, typedesc<anydata> td)
        returns stream<string, ai:Error?>|ai:Error {
    if td !is typedesc<string> {
        return error ai:Error("This data type is not supported for streaming. " +
            "'generateStream' supports only 'string'; use 'generate' for structured types.");
    }
    stream<ai:ChatCompletionChunk, ai:Error?> chunks = check llmModel->chatStream({role: ai:USER, content: prompt});
    stream<string, ai:Error?> textStream = new (new ChunkTextIterator(chunks));
    return textStream;
}

# Projects a normalized `ai:ChatCompletionChunk` stream onto its text content,
# yielding each non-empty `delta.content` fragment and skipping reasoning,
# tool-call, and usage-only chunks. Backs `generateLlmResponseStream`.
class ChunkTextIterator {
    private stream<ai:ChatCompletionChunk, ai:Error?> chunks;

    isolated function init(stream<ai:ChatCompletionChunk, ai:Error?> chunks) {
        self.chunks = chunks;
    }

    public isolated function next() returns record {|string value;|}|ai:Error? {
        while true {
            record {|ai:ChatCompletionChunk value;|}|ai:Error? next = self.chunks.next();
            if next is () {
                return ();
            }
            if next is ai:Error {
                return next;
            }
            ai:ChatCompletionChunkChoice[] choices = next.value.choices;
            if choices.length() == 0 {
                continue;
            }
            string? content = choices[0].delta.content;
            if content is string && content.length() > 0 {
                return {value: content};
            }
        }
    }

    public isolated function close() returns ai:Error? {
        return self.chunks.close();
    }
}
