# Glossary

Key terms and concepts used throughout Teale documentation.

## Network

| Term | Definition |
|------|-----------|
| **TealeNet** | The overall Teale network, encompassing all nodes, relays, and protocols. |
| **PTN** | Private TealeNet. An invite-only subnet with certificate-based membership and fixed-rate pricing. |
| **WWTN** | World Wide TealeNet. The public, open network where anyone can participate. Uses reverse auction pricing. |
| **Node** | A device participating in the network. Identified by its Ed25519 public key. |
| **Peer** | Another node that the current node is aware of or connected to. |
| **Relay** | A server that facilitates peer discovery, signaling, and fallback data transport for nodes that cannot connect directly. |
| **Tier** | A classification of node capability from 1 (backbone servers) to 4 (phones/leaf nodes). |

## Protocols

| Term | Definition |
|------|-----------|
| **Ed25519** | An elliptic curve digital signature algorithm used for node identity. Each node's public key is its network ID. |
| **Noise Protocol** | A framework for building encrypted channels. Teale uses `Noise_IK_25519_ChaChaPoly_BLAKE2s` for optional end-to-end encryption. |
| **STUN** | Session Traversal Utilities for NAT (RFC 5389). Used to discover a node's public IP address and NAT type. |
| **NAT** | Network Address Translation. The mechanism that maps private IP addresses to public ones, which can prevent inbound connections. |
| **ICE** | Interactive Connectivity Establishment. A framework for finding the best path to connect two peers through NAT. |
| **WFQ** | Weighted Fair Queuing. The scheduling algorithm that prioritizes PTN traffic (70%) over WWTN traffic (30%). |
| **Hole-punching** | A NAT traversal technique where two peers simultaneously send packets to create NAT mappings that allow bidirectional communication. |

## Inference

| Term | Definition |
|------|-----------|
| **InferenceProvider** | The core protocol abstraction in Teale. Any inference backend (MLX, llama.cpp, etc.) conforms to this protocol. |
| **MLX** | Apple's machine learning framework optimized for Apple Silicon. Used for on-device inference on macOS and iOS. |
| **GGUF** | A binary format for storing quantized language models. Used by llama.cpp for cross-platform inference. |
| **llama.cpp** | A C/C++ inference engine for running LLMs. Used on non-Apple platforms via the GGUF format. |
| **Quantization** | Reducing model precision (e.g., from fp16 to q4) to decrease memory usage and increase speed, with some quality tradeoff. |

## Architecture

| Term | Definition |
|------|-----------|
| **CompilerKit** | Teale module that compiles inference requests across multiple models (Mixture of Models). |
| **AgentKit** | Teale module that implements multi-step agent workflows with tool use. |
| **ChatKit** | Teale module that provides end-to-end encrypted group chat with CRDT-based sync. |
| **ClusterKit** | Teale module that manages LAN cluster formation, peer connections, and message routing. |
| **WANKit** | Teale module that manages WAN relay connections, Noise encryption, and NAT traversal. |
| **TealeNetKit** | Teale module that manages PTN membership, certificates, and invite flows. |
| **CreditKit** | Teale module that manages USDC wallet, transactions, and pricing calculations. |

## Payments

| Term | Definition |
|------|-----------|
| **USDC** | USD Coin, a stablecoin pegged to the US dollar. The currency used for Teale network payments. |
| **Solana** | A high-throughput blockchain used for on-chain USDC settlement of Teale earnings. |
| **Electricity floor** | The minimum price a provider should charge to cover their electricity cost plus a 20% margin. |
| **Reverse auction** | WWTN pricing mechanism where providers bid to serve requests, and the lowest bid wins. |

## Models

| Term | Definition |
|------|-----------|
| **Mixture of Models (MoM)** | A technique where multiple models collaborate on a single request. A compiler model breaks down the task and routes sub-tasks to specialist models. |
| **Model family** | A group of related models from the same provider (e.g., Llama, Qwen, Gemma). |
| **Parameter count** | The number of trainable parameters in a model (e.g., 8B = 8 billion). Larger models are generally more capable but require more resources. |

## Security

| Term | Definition |
|------|-----------|
| **CA** | Certificate Authority. In the PTN context, the Ed25519 keypair that signs membership certificates. |
| **Certificate** | A signed statement that a node belongs to a PTN with a specific role (admin, provider, consumer). |
| **Canonical JSON** | JSON encoded with sorted keys for deterministic output. Required for reproducible certificate signatures. |
| **Channel binding** | Verifying that both sides of an encrypted connection computed the same handshake hash, preventing MITM attacks. |
| **Replay protection** | A mechanism (sliding window bitmap) that prevents reuse of encrypted messages. |
