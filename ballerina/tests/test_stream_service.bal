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

import ballerina/http;
import ballerina/io;
import ballerina/test;

// A mock of Ollama's /api/chat endpoint in streaming mode. Ollama replies with
// newline-delimited JSON, one object per line, terminated by an object with
// `done` set to true.
service /streaming on new http:Listener(8081) {
    resource function post api/chat(map<json> payload) returns http:Response|error {
        test:assertEquals(payload.'stream, true, "Streaming requests must set 'stream' to true");
        json[] messages = check payload.messages.ensureType();
        string content = check messages[messages.length() - 1].content.ensureType();
        string ndjson = content.includes(WEATHER_PROMPT) ? TOOL_CALL_NDJSON : TEXT_NDJSON;
        // Deliberately split the payload at boundaries that fall inside JSON
        // objects and inside multi-byte characters, so that the client's line
        // buffering is exercised rather than handed one line per read.
        stream<byte[], io:Error?> byteStream = new (new ChunkedByteIterator(ndjson.toBytes(), 7));
        http:Response response = new;
        response.setByteStream(byteStream, "application/x-ndjson");
        return response;
    }
}

# Emits a byte array in fixed-size slices, regardless of where the line and
# character boundaries of the payload fall.
class ChunkedByteIterator {
    private final byte[] data;
    private final int size;
    private int position = 0;

    isolated function init(byte[] data, int size) {
        self.data = data;
        self.size = size;
    }

    public isolated function next() returns record {|byte[] value;|}|io:Error? {
        if self.position >= self.data.length() {
            return ();
        }
        int end = int:min(self.position + self.size, self.data.length());
        byte[] slice = self.data.slice(self.position, end);
        self.position = end;
        return {value: slice};
    }
}
