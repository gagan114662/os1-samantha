import SwiftUI

enum HermesPageWidth {
    case standard
    case dashboard
    case analytics

    var maxWidth: CGFloat {
        switch self {
        case .standard:
            return 1360
        case .dashboard:
            return 1480
        case .analytics:
            return 1560
        }
    }
}

struct HermesPageContainer<Content: View>: View {
    @Environment(\.os1Theme) private var theme

    let width: HermesPageWidth
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let content: Content

    init(
        width: HermesPageWidth = .standard,
        horizontalPadding: CGFloat = 28,
        verticalPadding: CGFloat = 26,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: width.maxWidth, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .safeAreaPadding(.top, 12)
        .background(theme.palette.coral)
    }
}

struct HermesPageHeader<Accessory: View>: View {
    @Environment(\.os1Theme) private var theme

    let title: String
    let subtitle: String
    let accessory: Accessory

    init(
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    init(title: String, subtitle: String) where Accessory == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.accessory = EmptyView()
    }

    var body: some View {
        HermesAdaptivePairLayout(
            horizontalSpacing: 20,
            verticalSpacing: 12,
            minimumPrimaryWidth: 260
        ) {
            titleBlock
            accessory
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string(title))
                .os1(theme.typography.titleSection)
                .foregroundStyle(theme.palette.onCoralPrimary)
                // Supported app widths render page titles in full; narrower
                // widths wrap to a second line before any clipping can occur.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(L10n.string(title))

            Text(L10n.string(subtitle))
                .os1(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HermesAdaptivePairLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    var minimumPrimaryWidth: CGFloat?

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        guard subviews.count >= 2 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }

        let availableWidth = proposal.width ?? .greatestFiniteMagnitude
        let primaryIdealSize = subviews[0].sizeThatFits(.unspecified)
        let secondarySize = subviews[1].sizeThatFits(.unspecified)

        if usesHorizontalLayout(
            availableWidth: availableWidth,
            primaryIdealWidth: primaryIdealSize.width,
            secondaryWidth: secondarySize.width
        ) {
            let primaryWidth = horizontalPrimaryWidth(
                availableWidth: availableWidth,
                primaryIdealWidth: primaryIdealSize.width,
                secondaryWidth: secondarySize.width
            )
            let primarySize = subviews[0].sizeThatFits(ProposedViewSize(width: primaryWidth, height: nil))
            let width = proposal.width ?? primarySize.width + horizontalSpacing + secondarySize.width

            return CGSize(
                width: width,
                height: max(primarySize.height, secondarySize.height)
            )
        }

        let primarySize = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let secondaryConstrainedSize = subviews[1].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let width = proposal.width ?? max(primarySize.width, secondaryConstrainedSize.width)

        return CGSize(
            width: width,
            height: primarySize.height + verticalSpacing + secondaryConstrainedSize.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        guard subviews.count >= 2 else {
            subviews.first?.place(
                at: bounds.origin,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
            )
            return
        }

        let primaryIdealSize = subviews[0].sizeThatFits(.unspecified)
        let secondarySize = subviews[1].sizeThatFits(.unspecified)

        if usesHorizontalLayout(
            availableWidth: bounds.width,
            primaryIdealWidth: primaryIdealSize.width,
            secondaryWidth: secondarySize.width
        ) {
            let primaryWidth = horizontalPrimaryWidth(
                availableWidth: bounds.width,
                primaryIdealWidth: primaryIdealSize.width,
                secondaryWidth: secondarySize.width
            )
            let primarySize = subviews[0].sizeThatFits(ProposedViewSize(width: primaryWidth, height: nil))

            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                proposal: ProposedViewSize(width: primaryWidth, height: primarySize.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX - secondarySize.width, y: bounds.minY),
                proposal: ProposedViewSize(width: secondarySize.width, height: secondarySize.height)
            )
        } else {
            let primarySize = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let secondarySize = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))

            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                proposal: ProposedViewSize(width: bounds.width, height: primarySize.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + primarySize.height + verticalSpacing),
                proposal: ProposedViewSize(width: bounds.width, height: secondarySize.height)
            )
        }
    }

    private func usesHorizontalLayout(
        availableWidth: CGFloat,
        primaryIdealWidth: CGFloat,
        secondaryWidth: CGFloat
    ) -> Bool {
        guard availableWidth.isFinite else { return true }

        let requiredPrimaryWidth = minimumPrimaryWidth ?? primaryIdealWidth
        return availableWidth >= requiredPrimaryWidth + horizontalSpacing + secondaryWidth
    }

    private func horizontalPrimaryWidth(
        availableWidth: CGFloat,
        primaryIdealWidth: CGFloat,
        secondaryWidth: CGFloat
    ) -> CGFloat {
        guard availableWidth.isFinite else { return primaryIdealWidth }
        return max(0, availableWidth - horizontalSpacing - secondaryWidth)
    }
}

struct HermesSurfacePanel<Content: View>: View {
    @Environment(\.os1Theme) private var theme

    let title: String?
    let subtitle: String?
    let content: Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let title {
                        Text(L10n.string(title))
                            .os1(theme.typography.titlePanel)
                            .foregroundStyle(theme.palette.onCoralPrimary)
                    }

                    if let subtitle {
                        Text(L10n.string(subtitle))
                            .os1(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.palette.glassFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        }
    }
}

struct HermesInsetSurface<Content: View>: View {
    @Environment(\.os1Theme) private var theme

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.palette.darkOverlay)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.palette.glassBorder.opacity(0.6), lineWidth: 1)
            }
    }
}

struct HermesLoadingState: View {
    @Environment(\.os1Theme) private var theme

    let label: String
    var minHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
                .tint(theme.palette.onCoralPrimary)

            Text(L10n.string(label))
                .os1Style(theme.typography.smallCaps)
                .foregroundStyle(theme.palette.onCoralSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
    }
}

struct HermesLoadingOverlay: View {
    @Environment(\.os1Theme) private var theme

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(theme.palette.onCoralPrimary)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.palette.glassFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
            }
    }
}

struct HermesValidationMessage: View {
    @Environment(\.os1Theme) private var theme

    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(theme.palette.onCoralPrimary)

            Text(L10n.string(text))
                .os1(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct HermesRefreshButton: View {
    @Environment(\.os1Theme) private var theme

    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.palette.onCoralPrimary)
                    Text(L10n.string("Refreshing…"))
                        .os1Style(theme.typography.smallCaps)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text(L10n.string("Refresh"))
                        .os1Style(theme.typography.smallCaps)
                }
            }
            .foregroundStyle(theme.palette.onCoralPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(theme.palette.glassFill)
            )
            .overlay {
                Capsule().strokeBorder(theme.palette.glassBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .opacity(isRefreshing ? 0.85 : 1)
    }
}

struct HermesCreateActionButton: View {
    @Environment(\.os1Theme) private var theme

    let title: String
    let help: String?
    let action: () -> Void

    init(_ title: String, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text(L10n.string(title))
                    .os1Style(theme.typography.smallCaps)
            }
            .foregroundStyle(theme.palette.onCoralPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(theme.palette.glassFill)
            )
            .overlay {
                Capsule().strokeBorder(theme.palette.glassBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help(help.map { L10n.string($0) } ?? L10n.string(title))
    }
}

struct HermesBadge: View {
    @Environment(\.os1Theme) private var theme

    let text: String
    let tint: Color
    var systemImage: String?
    var prominence: BadgeProminence = .subtle
    var isMonospaced = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
            }

            Text(L10n.string(text))
                .font(isMonospaced ? .system(.caption, design: .monospaced).weight(.semibold) : .caption.weight(.semibold))
        }
        .foregroundStyle(theme.palette.onCoralPrimary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(backgroundStyle, in: Capsule())
        .overlay {
            Capsule().strokeBorder(borderStyle, lineWidth: 1)
        }
    }

    enum BadgeProminence {
        case subtle
        case strong

        var borderWidth: CGFloat {
            switch self {
            case .subtle:
                return 1
            case .strong:
                return 1
            }
        }
    }

    /// All badges render in the OS1 monochrome warm palette regardless of
    /// the legacy `tint` argument the caller passed. The `prominence`
    /// argument toggles between subtle (low-fill glass) and strong
    /// (saturated glass). Status differentiation comes from the
    /// `systemImage` icon and surrounding layout, not color — OS1 is a
    /// monochrome warm system, no green/orange/red status pills.
    private var backgroundStyle: Color {
        switch prominence {
        case .subtle:
            return theme.palette.glassFill
        case .strong:
            return theme.palette.glassFillHover
        }
    }

    private var borderStyle: Color {
        switch prominence {
        case .subtle:
            return theme.palette.glassBorder
        case .strong:
            return theme.palette.glassBorderHover
        }
    }
}

struct HermesLabeledValue: View {
    @Environment(\.os1Theme) private var theme

    let label: String
    let value: String
    var isMonospaced = false
    var emphasizeValue = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(label))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)

            Text(value)
                .font(valueFont)
                .foregroundStyle(emphasizeValue ? theme.palette.onCoralPrimary : theme.palette.onCoralSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var valueFont: Font {
        if isMonospaced {
            return .system(.subheadline, design: .monospaced)
        }
        return emphasizeValue ? theme.typography.bodyEmphasis.font : theme.typography.body.font
    }
}

struct HermesExpandableSearchField: View {
    @Environment(\.os1Theme) private var theme

    @Binding var text: String

    var prompt = "Search"
    var collapsedWidth: CGFloat = 34
    var expandedWidth: CGFloat = 240

    @FocusState private var isFocused: Bool
    @State private var isExpanded = false

    private var localizedPrompt: String {
        L10n.string(prompt)
    }

    private var shouldShowExpandedField: Bool {
        isExpanded || !text.isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                    isExpanded = true
                }
                DispatchQueue.main.async {
                    isFocused = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(shouldShowExpandedField ? theme.palette.onCoralMuted : theme.palette.onCoralPrimary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localizedPrompt)

            if shouldShowExpandedField {
                TextField(localizedPrompt, text: $text)
                    .textFieldStyle(.plain)
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    text = ""
                    isFocused = false
                    isExpanded = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onCoralMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Close search"))
            }
        }
        .padding(.horizontal, 10)
        .frame(width: shouldShowExpandedField ? expandedWidth : collapsedWidth, height: 30, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.palette.glassFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(shouldShowExpandedField ? theme.palette.glassBorderHover : theme.palette.glassBorder, lineWidth: 1)
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: shouldShowExpandedField)
        .onAppear {
            isExpanded = !text.isEmpty
        }
        .onChange(of: isFocused) { _, focused in
            if !focused && text.isEmpty {
                isExpanded = false
            }
        }
    }
}

struct HermesSearchActionBar<LeadingContent: View>: View {
    @Binding var text: String

    var prompt = "Search"
    var collapsedWidth: CGFloat = 34
    var expandedWidth: CGFloat = 240
    let leadingContent: LeadingContent

    init(
        text: Binding<String>,
        prompt: String = "Search",
        collapsedWidth: CGFloat = 34,
        expandedWidth: CGFloat = 240,
        @ViewBuilder leadingContent: () -> LeadingContent
    ) {
        self._text = text
        self.prompt = prompt
        self.collapsedWidth = collapsedWidth
        self.expandedWidth = expandedWidth
        self.leadingContent = leadingContent()
    }

    var body: some View {
        HermesAdaptivePairLayout(
            horizontalSpacing: 12,
            verticalSpacing: 10
        ) {
            leadingContent
            searchField
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchField: some View {
        HermesExpandableSearchField(
            text: $text,
            prompt: prompt,
            collapsedWidth: collapsedWidth,
            expandedWidth: expandedWidth
        )
    }
}

struct HermesSplitLayout: Equatable {
    let minPrimaryWidth: CGFloat
    let defaultPrimaryWidth: CGFloat
    let maxPrimaryWidth: CGFloat
    var primaryWidth: CGFloat?

    init(
        minPrimaryWidth: CGFloat,
        defaultPrimaryWidth: CGFloat,
        maxPrimaryWidth: CGFloat = 760
    ) {
        self.minPrimaryWidth = minPrimaryWidth
        self.defaultPrimaryWidth = defaultPrimaryWidth
        self.maxPrimaryWidth = max(maxPrimaryWidth, minPrimaryWidth)
    }

    var preferredPrimaryWidth: CGFloat {
        clamped(primaryWidth ?? defaultPrimaryWidth)
    }

    mutating func rememberPrimaryWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0 else { return }

        let clampedWidth = clamped(width)
        if let primaryWidth, abs(primaryWidth - clampedWidth) < 1 {
            return
        }

        primaryWidth = clampedWidth
    }

    private func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, minPrimaryWidth), maxPrimaryWidth)
    }
}

extension View {
    func hermesSplitDetailColumn(minWidth: CGFloat, idealWidth: CGFloat) -> some View {
        frame(
            minWidth: minWidth,
            idealWidth: idealWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

struct HermesPersistentHSplitView<Primary: View, Detail: View>: NSViewRepresentable {
    @Binding var layout: HermesSplitLayout
    let detailMinWidth: CGFloat
    let primary: Primary
    let detail: Detail

    init(
        layout: Binding<HermesSplitLayout>,
        detailMinWidth: CGFloat,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder detail: () -> Detail
    ) {
        self._layout = layout
        self.detailMinWidth = detailMinWidth
        self.primary = primary()
        self.detail = detail()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = OS1WarmDividerSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        let primaryHost = NSHostingView(rootView: primary)
        primaryHost.translatesAutoresizingMaskIntoConstraints = false
        primaryHost.clipsToBounds = true

        let detailHost = NSHostingView(rootView: detail)
        detailHost.translatesAutoresizingMaskIntoConstraints = false
        detailHost.clipsToBounds = true

        splitView.addArrangedSubview(primaryHost)
        splitView.addArrangedSubview(detailHost)

        context.coordinator.primaryHost = primaryHost
        context.coordinator.detailHost = detailHost
        context.coordinator.layout = $layout
        context.coordinator.detailMinWidth = detailMinWidth

        context.coordinator.restoreDividerPosition(in: splitView)
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.primaryHost?.rootView = primary
        context.coordinator.detailHost?.rootView = detail
        context.coordinator.layout = $layout
        context.coordinator.detailMinWidth = detailMinWidth
        context.coordinator.restoreDividerPosition(in: splitView)
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var primaryHost: NSHostingView<Primary>?
        var detailHost: NSHostingView<Detail>?
        var layout: Binding<HermesSplitLayout>?
        var detailMinWidth: CGFloat = 420
        private var isRestoringDivider = false
        private var hasRestoredDivider = false
        private var autoConstrainedPrimaryWidth: CGFloat?

        func restoreDividerPosition(in splitView: NSSplitView) {
            guard splitView.subviews.count > 1, let layout else { return }

            if splitView.bounds.width <= 0 {
                DispatchQueue.main.async { [weak self, weak splitView] in
                    guard let self, let splitView else { return }
                    self.restoreDividerPosition(in: splitView)
                }
                return
            }

            let restoredWidth = constrainedPrimaryWidth(
                layout.wrappedValue.preferredPrimaryWidth,
                in: splitView
            )
            let currentWidth = splitView.subviews[0].frame.width
            guard abs(currentWidth - restoredWidth) > 1 else {
                hasRestoredDivider = true
                return
            }

            isRestoringDivider = true
            splitView.setPosition(restoredWidth, ofDividerAt: 0)
            splitView.adjustSubviews()
            isRestoringDivider = false
            hasRestoredDivider = true
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !isRestoringDivider,
                  hasRestoredDivider,
                  let splitView = notification.object as? NSSplitView,
                  let layout,
                  !splitView.subviews.isEmpty else {
                return
            }

            if reconcilePrimaryWidthForAvailableSpace(in: splitView) {
                return
            }

            let width = splitView.subviews[0].frame.width
            guard width.isFinite, width > 0 else { return }

            var updatedLayout = layout.wrappedValue
            updatedLayout.rememberPrimaryWidth(width)
            if updatedLayout != layout.wrappedValue {
                layout.wrappedValue = updatedLayout
            }
            autoConstrainedPrimaryWidth = nil
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            effectivePrimaryMinimum(in: splitView) ?? proposedMinimumPosition
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            guard let upperBound = primaryUpperBound(in: splitView) else {
                return proposedMaximumPosition
            }
            let lowerBound = effectivePrimaryMinimum(in: splitView) ?? 0
            return max(lowerBound, upperBound)
        }

        func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
            view === detailHost
        }

        private func constrainedPrimaryWidth(_ width: CGFloat, in splitView: NSSplitView) -> CGFloat {
            guard let lowerBound = effectivePrimaryMinimum(in: splitView),
                  let upperBound = primaryUpperBound(in: splitView) else {
                return width
            }

            let maxWidth = max(lowerBound, upperBound)
            return min(max(width, lowerBound), maxWidth)
        }

        private func reconcilePrimaryWidthForAvailableSpace(in splitView: NSSplitView) -> Bool {
            guard splitView.subviews.count > 1, let layout else { return false }

            let currentPrimaryWidth = splitView.subviews[0].frame.width
            let currentDetailWidth = splitView.subviews[1].frame.width
            let shouldProtectDetail = currentDetailWidth + 1 < detailMinWidth
            let minimumPrimaryWidth = layout.wrappedValue.minPrimaryWidth

            if let autoConstrainedPrimaryWidth,
               !shouldProtectDetail,
               abs(currentPrimaryWidth - autoConstrainedPrimaryWidth) > 2 {
                self.autoConstrainedPrimaryWidth = nil
                return false
            }

            let preferredPrimaryWidth = constrainedPrimaryWidth(
                layout.wrappedValue.preferredPrimaryWidth,
                in: splitView
            )

            let shouldRestorePrimary = autoConstrainedPrimaryWidth != nil &&
                currentPrimaryWidth + 1 < preferredPrimaryWidth

            guard shouldProtectDetail || shouldRestorePrimary else {
                return false
            }

            let targetPrimaryWidth = shouldProtectDetail
                ? max(minimumPrimaryWidth, min(currentPrimaryWidth, preferredPrimaryWidth))
                : preferredPrimaryWidth

            guard abs(currentPrimaryWidth - targetPrimaryWidth) > 1 else {
                if shouldProtectDetail {
                    autoConstrainedPrimaryWidth = currentPrimaryWidth
                    return true
                }
                return false
            }

            isRestoringDivider = true
            splitView.setPosition(targetPrimaryWidth, ofDividerAt: 0)
            splitView.adjustSubviews()
            isRestoringDivider = false

            if abs(targetPrimaryWidth - layout.wrappedValue.preferredPrimaryWidth) < 1 {
                autoConstrainedPrimaryWidth = nil
            } else {
                autoConstrainedPrimaryWidth = targetPrimaryWidth
            }

            return true
        }

        private func effectivePrimaryMinimum(in splitView: NSSplitView) -> CGFloat? {
            guard let layout else { return nil }
            return layout.wrappedValue.minPrimaryWidth
        }

        private func primaryUpperBound(in splitView: NSSplitView) -> CGFloat? {
            guard let layout else { return nil }
            let availableBeforeDetail = splitView.bounds.width - detailMinWidth - splitView.dividerThickness
            let hardLowerBound = layout.wrappedValue.minPrimaryWidth
            return min(layout.wrappedValue.maxPrimaryWidth, max(hardLowerBound, availableBeforeDetail))
        }
    }
}

struct HermesWrappingFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 8, verticalSpacing: CGFloat = 8) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = computeLines(for: sizes, maxWidth: proposal.width)
        let height = lines.reduce(CGFloat.zero) { partial, line in
            partial + line.height
        } + verticalSpacing * CGFloat(max(0, lines.count - 1))
        let width = proposal.width ?? lines.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = computeLines(for: sizes, maxWidth: bounds.width)
        var currentY = bounds.minY

        for line in lines {
            var currentX = bounds.minX
            for item in line.items {
                let size = sizes[item.index]
                subviews[item.index].place(
                    at: CGPoint(x: currentX, y: currentY),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                currentX += size.width + horizontalSpacing
            }
            currentY += line.height + verticalSpacing
        }
    }

    private func computeLines(for sizes: [CGSize], maxWidth: CGFloat?) -> [HermesFlowLine] {
        let availableWidth = maxWidth ?? .greatestFiniteMagnitude
        guard !sizes.isEmpty else { return [] }

        var lines: [HermesFlowLine] = []
        var currentItems: [HermesFlowLineItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for (index, size) in sizes.enumerated() {
            let proposedWidth = currentItems.isEmpty ? size.width : currentWidth + horizontalSpacing + size.width

            if !currentItems.isEmpty && proposedWidth > availableWidth {
                lines.append(
                    HermesFlowLine(
                        items: currentItems,
                        width: currentWidth,
                        height: currentHeight
                    )
                )
                currentItems = [HermesFlowLineItem(index: index)]
                currentWidth = size.width
                currentHeight = size.height
            } else {
                currentItems.append(HermesFlowLineItem(index: index))
                currentWidth = proposedWidth
                currentHeight = max(currentHeight, size.height)
            }
        }

        if !currentItems.isEmpty {
            lines.append(
                HermesFlowLine(
                    items: currentItems,
                    width: currentWidth,
                    height: currentHeight
                )
            )
        }

        return lines
    }
}

private struct HermesFlowLine {
    let items: [HermesFlowLineItem]
    let width: CGFloat
    let height: CGFloat
}

private struct HermesFlowLineItem {
    let index: Int
}

// MARK: - OS1 brand lockup

/// The "ElementSoftware® / OS¹ · COMPUTER USE" lockup from OS-1's StartScene.
/// Use top-left of shell windows. Renders inline with no fixed positioning.
struct OS1BrandLockup: View {
    @Environment(\.os1Theme) private var theme

    /// `.onCoral` for placement on the coral OS1 surface (the default,
    /// since the app window IS coral), `.onCream` for the rare cases
    /// where the lockup sits on the cream/beige off-app desk.
    enum Surface {
        case onCream
        case onCoral
    }

    var surface: Surface = .onCoral

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            wordmark
            descriptor
        }
    }

    private var wordmark: some View {
        HStack(spacing: 0) {
            Text("Element")
                .font(.custom("Helvetica-BoldOblique", size: 18))
            Text("Software")
                .font(.custom("Helvetica-Oblique", size: 18))
            Text("®")
                .font(.custom("Helvetica-Bold", size: 7))
                .baselineOffset(8)
                .padding(.leading, 1)
        }
        .foregroundStyle(primaryColor)
    }

    private var descriptor: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                Text("OS")
                Text("1")
                    .font(.custom("Helvetica-Bold", size: 5))
                    .baselineOffset(4)
            }
            Rectangle()
                .fill(secondaryColor)
                .frame(width: 1, height: 9)
            Text("COMPUTER USE")
        }
        .font(.custom("Helvetica-Bold", size: 8))
        .tracking(0.6)
        .foregroundStyle(secondaryColor)
    }

    private var primaryColor: Color {
        switch surface {
        case .onCream: theme.palette.onCreamPrimary
        case .onCoral: theme.palette.onCoralPrimary
        }
    }

    private var secondaryColor: Color {
        switch surface {
        case .onCream: theme.palette.onCreamSecondary.opacity(0.7)
        case .onCoral: theme.palette.onCoralSecondary
        }
    }
}
