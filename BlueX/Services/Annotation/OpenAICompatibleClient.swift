// BlueX/Services/Annotation/OpenAICompatibleClient.swift
import Foundation

// Why: LM Studio, Jan, and other local runners all implement the OpenAI /v1/chat/completions API.
// MLXClient already implements that contract — a typealias avoids code duplication.
typealias OpenAICompatibleClient = MLXClient
