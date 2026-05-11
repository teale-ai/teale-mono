import XCTest
import Foundation
@testable import SharedTypes

final class SharedTypesTests: XCTestCase {

    func testChatCompletionRequestCodable() throws {
        let request = ChatCompletionRequest(
            model: "test-model",
            messages: [APIMessage(role: "user", content: "Hello")],
            temperature: 0.7,
            maxTokens: 100,
            stream: true
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)

        XCTAssertEqual(decoded.model, "test-model")
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.messages[0].role, "user")
        XCTAssertEqual(decoded.messages[0].content, "Hello")
        XCTAssertEqual(decoded.temperature, 0.7)
        XCTAssertEqual(decoded.maxTokens, 100)
        XCTAssertEqual(decoded.stream, true)
    }

    func testChatCompletionRequestPreservesToolsAndToolChoice() throws {
        let tool: OpenAIJSONValue = .object([
            "type": .string("function"),
            "function": .object([
                "name": .string("lookup_work_order"),
                "description": .string("Look up a property maintenance work order"),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "property_id": .object(["type": .string("string")]),
                        "issue": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("property_id"), .string("issue")])
                ])
            ])
        ])
        let request = ChatCompletionRequest(
            model: "teale-auto",
            messages: [APIMessage(role: "user", content: "Use the tool")],
            tools: [tool],
            toolChoice: .object([
                "type": .string("function"),
                "function": .object(["name": .string("lookup_work_order")])
            ])
        )

        let data = try JSONEncoder().encode(request)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(raw["tools"])
        XCTAssertNotNil(raw["tool_choice"])

        let decoded = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
        XCTAssertEqual(decoded.tools, [tool])
        XCTAssertEqual(decoded.toolChoice, request.toolChoice)
    }

    func testChatCompletionResponseCodable() throws {
        let response = ChatCompletionResponse(
            id: "test-id",
            model: "test-model",
            choices: [
                .init(index: 0, message: APIMessage(role: "assistant", content: "Hi there"), finishReason: "stop")
            ]
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)

        XCTAssertEqual(decoded.id, "test-id")
        XCTAssertEqual(decoded.object, "chat.completion")
        XCTAssertEqual(decoded.choices.count, 1)
        XCTAssertEqual(decoded.choices[0].message.content, "Hi there")
    }

    func testChatCompletionResponseDecodesToolCallsWithNullContent() throws {
        let json = """
        {
          "id": "chatcmpl-tool",
          "object": "chat.completion",
          "created": 1700000000,
          "model": "qwen3.6-35b",
          "choices": [
            {
              "index": 0,
              "message": {
                "role": "assistant",
                "content": null,
                "tool_calls": [
                  {
                    "id": "call_lookup",
                    "type": "function",
                    "function": {
                      "name": "lookup_work_order",
                      "arguments": "{\\"property_id\\":\\"APM-104\\",\\"issue\\":\\"leaking faucet\\"}"
                    }
                  }
                ]
              },
              "finish_reason": "tool_calls"
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: json)

        let message = decoded.choices[0].message
        XCTAssertEqual(message.content, "")
        XCTAssertEqual(decoded.choices[0].finishReason, "tool_calls")
        XCTAssertEqual(message.toolCalls?.first?.id, "call_lookup")
        XCTAssertEqual(message.toolCalls?.first?.function?.name, "lookup_work_order")
        XCTAssertEqual(message.toolCalls?.first?.function?.arguments, #"{"property_id":"APM-104","issue":"leaking faucet"}"#)
    }

    func testChatCompletionChunkCodable() throws {
        let chunk = ChatCompletionChunk(
            id: "chunk-1",
            model: "test-model",
            choices: [
                .init(index: 0, delta: .init(role: nil, content: "Hello"), finishReason: nil)
            ]
        )

        let data = try JSONEncoder().encode(chunk)
        let decoded = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)

        XCTAssertEqual(decoded.choices[0].delta.content, "Hello")
        XCTAssertNil(decoded.choices[0].delta.role)
    }

    func testChatCompletionChunkDecodesToolCallDelta() throws {
        let json = """
        {
          "id": "chunk-tool",
          "object": "chat.completion.chunk",
          "created": 1700000000,
          "model": "qwen3.6-35b",
          "choices": [
            {
              "index": 0,
              "delta": {
                "tool_calls": [
                  {
                    "index": 0,
                    "id": "call_lookup",
                    "type": "function",
                    "function": {
                      "name": "lookup_work_order",
                      "arguments": "{\\"property_id\\":"
                    }
                  }
                ]
              },
              "finish_reason": null
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ChatCompletionChunk.self, from: json)
        let toolCall = try XCTUnwrap(decoded.choices[0].delta.toolCalls?.first)

        XCTAssertEqual(toolCall.index, 0)
        XCTAssertEqual(toolCall.id, "call_lookup")
        XCTAssertEqual(toolCall.function?.name, "lookup_work_order")
        XCTAssertEqual(toolCall.function?.arguments, #"{"property_id":"#)
    }

    func testModelDescriptorCodable() throws {
        let model = ModelDescriptor(
            id: "test-model",
            name: "Test Model",
            huggingFaceRepo: "test/repo",
            parameterCount: "7B",
            quantization: .q4,
            estimatedSizeGB: 4.0,
            requiredRAMGB: 10.0,
            family: "Test",
            description: "A test model"
        )

        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(ModelDescriptor.self, from: data)

        XCTAssertEqual(decoded.id, "test-model")
        XCTAssertEqual(decoded.quantization, .q4)
        XCTAssertEqual(decoded.requiredRAMGB, 10.0)
    }

    func testAvailableRAM() {
        let hw = HardwareCapability(
            chipFamily: .m2Pro,
            chipName: "Apple M2 Pro",
            totalRAMGB: 32.0,
            gpuCoreCount: 19,
            memoryBandwidthGBs: 200.0,
            tier: .tier2
        )
        XCTAssertEqual(hw.availableRAMForModelsGB, 28.0)
    }

    func testEngineStatusDisplayText() {
        let idle = EngineStatus.idle
        XCTAssertEqual(idle.displayText, "Idle")

        let paused = EngineStatus.paused(reason: .thermal)
        XCTAssertEqual(paused.displayText, "Paused: Thermal throttling")
    }

    func testModelsListResponse() throws {
        let response = ModelsListResponse(data: [
            .init(id: "model-1", object: "model", created: 1000, ownedBy: "local")
        ])

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ModelsListResponse.self, from: data)

        XCTAssertEqual(decoded.object, "list")
        XCTAssertEqual(decoded.data.count, 1)
        XCTAssertEqual(decoded.data[0].id, "model-1")
    }

    func testHardwareCapabilityDecodesUnknownRelayValuesLeniently() throws {
        let json = """
        {
          "chipFamily": "gatewayVirtual",
          "chipName": "gateway.teale.com",
          "totalRAMGB": 0,
          "gpuCoreCount": 0,
          "memoryBandwidthGBs": 0,
          "tier": 0,
          "gpuBackend": "cpu",
          "platform": "gateway"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HardwareCapability.self, from: json)

        XCTAssertEqual(decoded.chipFamily, .unknown)
        XCTAssertEqual(decoded.tier, .tier4)
        XCTAssertEqual(decoded.gpuBackend, .cpu)
        XCTAssertNil(decoded.platform)
    }
}
