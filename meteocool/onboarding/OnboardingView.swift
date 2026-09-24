import SwiftUI
import UIKit

typealias OnboardingAction = @MainActor (@escaping @MainActor (Bool, Error?) -> Void) -> Void

struct OnboardingFeature: Identifiable {
    let symbol: String
    let title: String
    let detail: String
    var id: String { symbol }
}

@MainActor struct OnboardingPage {
    enum Artwork {
        case illustration(String)
        case symbol(String)
    }

    let artwork: Artwork
    let title: String
    var message: String? = nil
    var features: [OnboardingFeature] = []
    var footnote: String? = nil
    var primaryTitle: String = NSLocalizedString("Continue", comment: "")
    var secondaryTitle: String? = nil
    /// Runs on the primary button. The page advances once it calls back, whatever
    /// the outcome: declining a permission is a valid way through onboarding.
    var action: OnboardingAction? = nil
}

@MainActor @Observable final class OnboardingModel {
    let pages: [OnboardingPage]
    private(set) var index = 0
    private(set) var busy = false
    var finish: @MainActor () -> Void = {}

    init(pages: [OnboardingPage]) {
        self.pages = pages
    }

    var page: OnboardingPage { pages[index] }

    func primary() {
        guard !busy else { return }
        guard let action = page.action else { return advance() }
        busy = true
        action { [weak self] _, _ in
            self?.busy = false
            self?.advance()
        }
    }

    func advance() {
        guard index + 1 < pages.count else { return finish() }
        withAnimation(.smooth) { index += 1 }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
}

/// Presents the SwiftUI flow as a non-dismissable sheet from the UIKit map screen.
@MainActor final class OnboardingViewController: UIHostingController<OnboardingView> {
    init(pages: [OnboardingPage], completion: @escaping () -> Void) {
        let model = OnboardingModel(pages: pages)
        super.init(rootView: OnboardingView(model: model))
        model.finish = { [weak self] in self?.dismiss(animated: true, completion: completion) }
        modalPresentationStyle = .formSheet
        isModalInPresentation = true
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("Use init(pages:completion:)") }
}

struct OnboardingView: View {
    let model: OnboardingModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let readableWidth: CGFloat = 540

    var body: some View {
        // At accessibility sizes the buttons would cover most of the screen if
        // pinned, so they scroll with the page instead.
        if typeSize.isAccessibilitySize {
            pages(includingButtons: true)
        } else {
            pages(includingButtons: false).onboardingBottomBar { buttons }
        }
    }

    private func pages(includingButtons: Bool) -> some View {
        ZStack {
            ScrollView {
                VStack(spacing: 40) {
                    OnboardingPageContent(page: model.page)
                    if includingButtons { buttons }
                }
                .frame(maxWidth: Self.readableWidth)
                .padding(.horizontal, 24)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Short permission pages sit in the middle rather than under a void.
            .defaultScrollAnchor(.center, for: .alignment)
            .id(model.index)
            .transition(reduceMotion ? .opacity : .push(from: .trailing))
        }
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            Button(action: model.primary) {
                Text(model.page.primaryTitle)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .onboardingProminentButton()

            if let secondary = model.page.secondaryTitle {
                Button(action: model.advance) {
                    Text(secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderless)
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .disabled(model.busy)
        .frame(maxWidth: Self.readableWidth)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingPageContent: View {
    let page: OnboardingPage
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 56
    @ScaledMetric(relativeTo: .largeTitle) private var illustrationHeight: CGFloat = 140
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 32) {
            artwork.accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(page.title)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                if let message = page.message {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            if !page.features.isEmpty {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(page.features) { OnboardingFeatureRow(feature: $0) }
                }
            }

            if let footnote = page.footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { appeared = true }
    }

    @ViewBuilder private var artwork: some View {
        switch page.artwork {
        case .illustration(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(height: min(illustrationHeight, 220))
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: min(symbolSize, 96), weight: .medium))
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: appeared)
                .frame(width: min(symbolSize, 96) * 2, height: min(symbolSize, 96) * 2)
                .background(.tint.opacity(0.12), in: .circle)
        }
    }
}

private struct OnboardingFeatureRow: View {
    let feature: OnboardingFeature
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var iconWidth: CGFloat = 40

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            Image(systemName: feature.symbol)
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title).font(.headline)
                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// Glass on iOS 26 and later; the filled system style before that.
    @ViewBuilder func onboardingProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// A bar the page scrolls under. iOS 26 fades content out beneath it with the
    /// scroll edge effect; earlier versions get the classic bar material.
    @ViewBuilder func onboardingBottomBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom) { content() }
        } else {
            safeAreaInset(edge: .bottom) { content().background(.bar) }
        }
    }
}
