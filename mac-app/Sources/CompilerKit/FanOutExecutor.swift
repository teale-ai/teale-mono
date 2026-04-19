import Foundation
import SharedTypes

// MARK: - Fan-Out Executor

/// Dispatches sub-tasks to devices in parallel, respecting the dependency DAG.
/// Independent sub-tasks run simultaneously. Dependent sub-tasks wait for prerequisites.
public actor FanOutExecutor {

    public init() {}

    /// Execute sub-tasks in parallel, respecting dependencies.
    ///
    /// - Parameters:
    ///   - subTasks: The sub-tasks to execute (may have inter-dependencies).
    ///   - assignments: Mapping from sub-task ID → model to run on.
    ///   - generateFn: Closure that executes a sub-task on the assigned model.
    ///                  Receives the sub-task, assigned model, and results of completed dependencies.
    /// - Returns: Results for all sub-tasks, ordered by orderIndex.
    public func execute(
        subTasks: [SubTask],
        assignments: [UUID: ModelOnNetwork],
        generateFn: @Sendable @escaping (SubTask, ModelOnNetwork, [SubTaskResult]) async throws -> SubTaskResult
    ) async throws -> [SubTaskResult] {
        // Group sub-tasks into execution levels via topological sort
        let levels = topologicalLevels(subTasks)
        var completedResults: [UUID: SubTaskResult] = [:]

        for level in levels {
            // Execute all sub-tasks in this level in parallel
            let levelResults = try await withThrowingTaskGroup(
                of: SubTaskResult.self,
                returning: [SubTaskResult].self
            ) { group in
                for subTask in level {
                    guard let model = assignments[subTask.id] else {
                        throw CompilationError.noModelsAvailable
                    }

                    // Gather results from dependencies
                    let depResults = subTask.dependsOn.compactMap { completedResults[$0] }

                    group.addTask {
                        try await generateFn(subTask, model, depResults)
                    }
                }

                var results: [SubTaskResult] = []
                for try await result in group {
                    results.append(result)
                }
                return results
            }

            // Record completed results for downstream dependencies
            for result in levelResults {
                completedResults[result.subTaskID] = result
            }
        }

        // Return all results sorted by original order
        return subTasks.compactMap { completedResults[$0.id] }
            .sorted { lhs, rhs in
                let lhsOrder = subTasks.first { $0.id == lhs.subTaskID }?.orderIndex ?? 0
                let rhsOrder = subTasks.first { $0.id == rhs.subTaskID }?.orderIndex ?? 0
                return lhsOrder < rhsOrder
            }
    }

    // MARK: - Topological Sort

    /// Groups sub-tasks into dependency levels. Level 0 has no dependencies,
    /// level 1 depends only on level 0, etc.
    private func topologicalLevels(_ subTasks: [SubTask]) -> [[SubTask]] {
        let tasksByID = Dictionary(uniqueKeysWithValues: subTasks.map { ($0.id, $0) })
        var levels: [[SubTask]] = []
        var assigned: Set<UUID> = []

        while assigned.count < subTasks.count {
            // Find all tasks whose dependencies are fully satisfied
            let ready = subTasks.filter { task in
                !assigned.contains(task.id) &&
                task.dependsOn.allSatisfy { assigned.contains($0) }
            }

            if ready.isEmpty {
                // Circular dependency or orphaned tasks — break and include remaining
                let remaining = subTasks.filter { !assigned.contains($0.id) }
                if !remaining.isEmpty { levels.append(remaining) }
                break
            }

            levels.append(ready)
            for task in ready { assigned.insert(task.id) }
        }

        return levels
    }
}
