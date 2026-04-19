# Mixture of Models

CompilerKit decomposes complex requests across multiple models running on different devices, then synthesizes the results into a single coherent response.

## When does compilation happen

Not every request benefits from decomposition. The `RequestAnalyzer` evaluates each incoming request and decides on a plan:

- **Passthrough** --- Simple requests (single-topic questions, short completions) go directly to a single model. No overhead.
- **Compiled** --- Complex requests involving multiple skills (code + explanation, translation + analysis) are decomposed into sub-tasks and fanned out.
- **Compete** --- Ambiguous requests are sent to multiple models in parallel, and the best response is selected.

Most requests are passthrough. Compilation activates only when the analyzer detects that splitting the work would produce a better result than sending everything to one model.

## The compilation pipeline

```
User request
     |
     v
[RequestAnalyzer] --- Should we decompose?
     |
     | yes
     v
[TaskDecomposer] --- Break into sub-tasks (uses a small model)
     |
     v
[ModelSelector] --- Assign each sub-task to the best model
     |
     v
[FanOutExecutor] --- Run sub-tasks in parallel across devices
     |
     v
[ResponseSynthesizer] --- Combine results into one response
     |
     v
Final response + ContributionRecords
```

### RequestAnalyzer

Examines the request to determine whether decomposition would improve quality. Considers factors like:

- Number of distinct topics or skills involved
- Estimated token count
- Whether the request explicitly asks for multiple outputs

Returns a `CompilationPlan`: passthrough, compiled, or compete.

### TaskDecomposer

Breaks a request into `SubTask` objects. Each sub-task has:

| Field | Description |
|-------|-------------|
| `prompt` | The text prompt for this sub-task |
| `category` | One of: code, reasoning, creative, factual, summarization, translation, structured, general |
| `orderIndex` | Execution order (sub-tasks with the same index run in parallel) |
| `dependsOn` | UUIDs of sub-tasks that must complete before this one starts |
| `estimatedTokens` | Expected token count for capacity planning |

The decomposer uses a small, fast model (like a 1B parameter model) to analyze the request and produce the sub-task list. This keeps the overhead low.

### ModelSelector

Assigns each sub-task to the best available model based on `ModelAffinity` scores. Each model family has scores for each task category:

```
Qwen-Coder:  code=0.95, reasoning=0.7, creative=0.5, factual=0.6 ...
Llama:       code=0.7,  reasoning=0.85, creative=0.8, factual=0.8 ...
Mistral:     code=0.8,  reasoning=0.8,  creative=0.7, factual=0.75 ...
```

The selector considers both affinity score and current device load. A slightly less optimal model on an idle device may be chosen over the best model on a busy one.

### FanOutExecutor

Runs sub-tasks across devices in parallel, respecting the dependency graph:

1. Sub-tasks with no dependencies start immediately on their assigned devices.
2. As each sub-task completes, dependent sub-tasks are unblocked and dispatched.
3. If a sub-task fails, the executor retries on a different device if available.
4. All sub-tasks run through the standard `InferenceProvider` interface.

### ResponseSynthesizer

Combines sub-task results into a single coherent response. The synthesizer uses a model to weave the outputs together, guided by a synthesis prompt that was generated during decomposition. The synthesis prompt describes how the parts should fit together.

### ContributionRecord

After synthesis, a `ContributionRecord` is generated for each device that contributed:

| Field | Description |
|-------|-------------|
| `deviceID` | Which device ran the sub-task |
| `model` | Which model was used |
| `subTaskID` | Which sub-task was executed |
| `tokenCount` | How many tokens were generated |
| `weight` | Proportional contribution to the final response |

These records feed into the credit economy so each provider is paid for their share of the work.

## Example

**User request:** "Translate this Python code to Rust and explain the key differences between the two implementations."

**RequestAnalyzer** detects two distinct skills: code translation and technical explanation. Returns `CompilationPlan.compiled`.

**TaskDecomposer** produces two sub-tasks:

1. **Sub-task A** (category: `translation`, orderIndex: 0) --- "Translate the following Python code to idiomatic Rust: ..."
2. **Sub-task B** (category: `reasoning`, orderIndex: 1, dependsOn: [A]) --- "Compare the Python original with the Rust translation and explain the key differences in memory management, type system, and error handling."

Sub-task B depends on A because it needs the Rust translation to compare.

**ModelSelector** assigns:

- Sub-task A to Qwen-Coder-32B (highest code/translation affinity) on Device 1
- Sub-task B to Llama-3-8B (high reasoning affinity, fast) on Device 2

**FanOutExecutor** runs sub-task A on Device 1. When it completes, sub-task B starts on Device 2 with A's output included in its context.

**ResponseSynthesizer** combines both outputs into a single response: the Rust code followed by the explanation, with smooth transitions.

**ContributionRecords** credit Device 1 for the translation tokens and Device 2 for the explanation tokens. Both providers are paid proportionally.

## Task categories

CompilerKit recognizes eight task categories for routing:

| Category | Examples |
|----------|---------|
| `code` | Write, debug, translate, or review code |
| `reasoning` | Logical analysis, math, problem solving |
| `creative` | Stories, poetry, brainstorming |
| `factual` | Q&A, definitions, historical facts |
| `summarization` | Condense long text into key points |
| `translation` | Convert between natural languages |
| `structured` | JSON generation, table formatting, data extraction |
| `general` | Catch-all for tasks that do not fit a specific category |

## Related pages

- [Inference Providers](inference-providers.md) --- the provider chain that CompilerKit builds on
- [Credit Economy](credit-economy.md) --- how ContributionRecords map to payments
- [How Teale Works](how-teale-works.md) --- where the Compiler fits in the architecture
