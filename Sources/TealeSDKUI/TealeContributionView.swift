import SwiftUI
import TealeSDK

// MARK: - Teale Contribution View

/// The main pre-built view for developers to drop into their app.
/// Automatically shows the consent prompt if the user hasn't opted in,
/// or the earnings dashboard if they have.
public struct TealeContributionView: View {
    @Bindable var contributor: TealeContributor

    public init(contributor: TealeContributor) {
        self.contributor = contributor
    }

    public var body: some View {
        Group {
            if contributor.hasUserConsent {
                EarningsDashboardView(contributor: contributor)
            } else {
                ConsentPromptView(contributor: contributor)
            }
        }
    }
}
