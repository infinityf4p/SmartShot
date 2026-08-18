import CoreGraphics
import Foundation

public enum CandidateFilter {
    public static func normalized(
        _ candidates: [CaptureCandidate],
        within desktopBounds: CGRect,
        minimumSize: CGSize = CGSize(width: 24, height: 18)
    ) -> [CaptureCandidate] {
        var seen = Set<QuantizedRect>()

        return candidates
            .map { candidate in
                CaptureCandidate(
                    id: candidate.id,
                    rect: candidate.rect.intersection(desktopBounds),
                    source: candidate.source,
                    label: candidate.label,
                    level: candidate.level
                )
            }
            .filter { !$0.rect.isNull && $0.rect.width >= minimumSize.width && $0.rect.height >= minimumSize.height }
            .filter { candidate in
                let key = QuantizedRect(candidate.rect)
                return seen.insert(key).inserted
            }
            .sorted { lhs, rhs in
                lhs.rect.width * lhs.rect.height < rhs.rect.width * rhs.rect.height
            }
    }
}

private struct QuantizedRect: Hashable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ rect: CGRect) {
        x = Int(rect.minX.rounded())
        y = Int(rect.minY.rounded())
        width = Int(rect.width.rounded())
        height = Int(rect.height.rounded())
    }
}
