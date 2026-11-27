import Foundation

public extension SolveCaseContent {
    var staticQuestion: String {
        let instructions = fields.map { field in
            var lines = [field.prompt]
            if let input = field.input, !input.instructions.isEmpty { lines.append(input.instructions) }
            if let choice = field.choice {
                lines.append(choice.multiple ? "Select all that apply." : "Select one.")
                lines.append(contentsOf: choice.options.map { "• " + $0.label })
                if choice.noneReason != nil { lines.append("• None of these") }
            }
            if let order = field.order {
                lines.append(contentsOf: order.items.sorted().map { "• " + $0 })
            }
            if let grid = field.grid {
                lines.append(grid.columns.joined(separator: " | "))
                if let labels = grid.rowLabels { lines.append(contentsOf: labels) }
                else { lines.append("Fill \(grid.rows.count) rows.") }
                if !grid.options.isEmpty { lines.append(grid.options.sorted().joined(separator: " / ")) }
            }
            return lines.joined(separator: "\n")
        }
        return ([prompt] + instructions).joined(separator: "\n\n")
    }

    var staticAnswer: String {
        let key = fields.map { field in
            var lines = [field.prompt]
            if let input = field.input { lines.append(input.answers.joined(separator: " / ")) }
            if let choice = field.choice {
                lines.append(choice.correct.isEmpty ? "None of these" : choice.correct.joined(separator: ", "))
                lines.append(contentsOf: choice.options.map { "\($0.label) — \($0.reason)" })
                if let reason = choice.noneReason { lines.append("None of these — \(reason)") }
            }
            if let order = field.order {
                lines.append(contentsOf: order.sequences.map { $0.joined(separator: " → ") })
            }
            if let grid = field.grid {
                for (index, row) in grid.rows.enumerated() {
                    let values = row.map { $0.answers.joined(separator: " / ") }
                    let label = grid.rowLabels.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                    lines.append(([label].compactMap { $0 } + values).joined(separator: " | "))
                }
            }
            return lines.joined(separator: "\n")
        }
        return (key + [explanation]).joined(separator: "\n\n")
    }
}
