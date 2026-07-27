// Copyright (c) 2025 WSO2 LLC. (http://www.wso2.org).
//
// WSO2 Inc. licenses this file to you under the Apache License,
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
import ballerina/test;

const STREAM_SERVICE_URL = "http://localhost:8081/streaming";
const WEATHER_PROMPT = "weather in Colombo";
const CREATED_AT = "2025-01-01T00:00:00.000000Z";

final ModelProvider ollamaStreamProvider = check new ("llama2", STREAM_SERVICE_URL, {seed: 11});

// The content fragment carries a multi-byte character on purpose: the mock
// service slices the payload every 7 bytes, so the emoji straddles two reads.
final string TEXT_NDJSON = toNdjson([
    {model: "llama2", created_at: CREATED_AT, message: {role: "assistant", content: "Hello"}, done: false},
    {
        model: "llama2",
        created_at: CREATED_AT,
        message: {role: "assistant", content: ", 🌍 ", thinking: "pondering"},
        done: false
    },
    {model: "llama2", created_at: CREATED_AT, message: {role: "assistant", content: "world!"}, done: false},
    {
        model: "llama2",
        created_at: CREATED_AT,
        message: {role: "assistant", content: ""},
        done: true,
        done_reason: "stop",
        prompt_eval_count: 10,
        eval_count: 3
    }
]);

// Ollama emits each tool call fully formed and without an index, and reports
// `done_reason` "stop" even when the turn ended in tool calls.
final string TOOL_CALL_NDJSON = toNdjson([
    {
        model: "llama2",
        created_at: CREATED_AT,
        message: {
            role: "assistant",
            content: "",
            tool_calls: [{'function: {name: "getWeather", arguments: {city: "Colombo"}}}]
        },
        done: false
    },
    {
        model: "llama2",
        created_at: CREATED_AT,
        message: {
            role: "assistant",
            content: "",
            tool_calls: [{'function: {name: "getTime", arguments: {zone: "IST"}}}]
        },
        done: false
    },
    {
        model: "llama2",
        created_at: CREATED_AT,
        message: {role: "assistant", content: ""},
        done: true,
        done_reason: "stop",
        prompt_eval_count: 20,
        eval_count: 8
    }
]);

isolated function toNdjson(json[] chunks) returns string {
    string[] lines = from json chunk in chunks
        select chunk.toJsonString();
    return string:'join("\n", ...lines) + "\n";
}

isolated function collectChunks(stream<ai:ChatCompletionChunk, ai:Error?> chunks)
        returns ai:ChatCompletionChunk[]|ai:Error {
    ai:ChatCompletionChunk[] collected = [];
    record {|ai:ChatCompletionChunk value;|}|ai:Error? next = chunks.next();
    while next !is ai:Error? {
        collected.push(next.value);
        next = chunks.next();
    }
    if next is ai:Error {
        return next;
    }
    return collected;
}

@test:Config
function testChatStreamTextDeltas() returns error? {
    stream<ai:ChatCompletionChunk, ai:Error?> chunkStream = check ollamaStreamProvider->chatStream(
        [{role: ai:USER, content: "Say hello"}]);
    ai:ChatCompletionChunk[] chunks = check collectChunks(chunkStream);

    test:assertEquals(chunks.length(), 4);
    test:assertEquals(chunks[0].model, "llama2");
    test:assertEquals(chunks[0].choices[0].delta.role, ai:ASSISTANT);

    string content = "";
    string reasoning = "";
    foreach ai:ChatCompletionChunk chunk in chunks {
        content += chunk.choices[0].delta.content ?: "";
        reasoning += chunk.choices[0].delta.reasoning ?: "";
    }
    test:assertEquals(content, "Hello, 🌍 world!");
    test:assertEquals(reasoning, "pondering");

    // Only the terminal chunk carries a finish reason and the token counts.
    test:assertEquals(chunks[0].choices[0].finishReason, ());
    ai:ChatCompletionChunk last = chunks[3];
    test:assertEquals(last.choices[0].finishReason, ai:STOP);
    test:assertEquals(last.usage?.promptTokens, 10);
    test:assertEquals(last.usage?.completionTokens, 3);
    test:assertEquals(last.usage?.totalTokens, 13);
}

@test:Config
function testChatStreamToolCalls() returns error? {
    stream<ai:ChatCompletionChunk, ai:Error?> chunkStream = check ollamaStreamProvider->chatStream(
        [{role: ai:USER, content: string `What is the ${WEATHER_PROMPT}?`}]);
    ai:ChatCompletionChunk[] chunks = check collectChunks(chunkStream);

    test:assertEquals(chunks.length(), 3);

    // Tool calls arrive on separate chunks and must be numbered by a running
    // index, so a consumer can accumulate fragments the same way it would for a
    // provider that splits the arguments across chunks.
    ai:ToolCallChunk[] first = check chunks[0].choices[0].delta.toolCalls.ensureType();
    test:assertEquals(first.length(), 1);
    test:assertEquals(first[0].index, 0);
    test:assertEquals(first[0].'function?.name, "getWeather");
    test:assertEquals(first[0].'function?.arguments, "{\"city\":\"Colombo\"}");

    ai:ToolCallChunk[] second = check chunks[1].choices[0].delta.toolCalls.ensureType();
    test:assertEquals(second.length(), 1);
    test:assertEquals(second[0].index, 1);
    test:assertEquals(second[0].'function?.name, "getTime");
    test:assertEquals(second[0].'function?.arguments, "{\"zone\":\"IST\"}");

    // Ollama reports "stop" here; the normalized chunk must say `tool_calls`.
    test:assertEquals(chunks[2].choices[0].delta.toolCalls, ());
    test:assertEquals(chunks[2].choices[0].finishReason, ai:TOOL_CALLS);
}

@test:Config
function testGenerateStreamWithStringType() returns error? {
    stream<string, ai:Error?> textStream = check ollamaStreamProvider->generateStream(`Say hello`);
    string content = "";
    record {|string value;|}|ai:Error? next = textStream.next();
    while next !is ai:Error? {
        content += next.value;
        next = textStream.next();
    }
    if next is ai:Error {
        test:assertFail(next.message());
    }
    test:assertEquals(content, "Hello, 🌍 world!");
}

@test:Config
function testGenerateStreamWithUnsupportedType() {
    stream<int, ai:Error?>|ai:Error result = ollamaStreamProvider->generateStream(`Say hello`);
    if result !is ai:Error {
        test:assertFail("Expected an error for a non-string expected type");
    }
    test:assertEquals(result.message(), "This data type is not supported for streaming. " +
            "'generateStream' supports only 'string'; use 'generate' for structured types.");
}
