import HushCore
import SwiftUI

enum MainPage: Hashable {
    case home, history, dictionary, styles, settings

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .styles: "Styles"
        case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"
        case .history: "clock"
        case .dictionary: "character.book.closed"
        case .styles: "textformat"
        case .settings: "gearshape"
        }
    }
}

/// Page selection lives outside the view so `MainWindowController` (and the
/// side panel's "Settings…" menu item) can navigate an existing window.
@MainActor
final class PageNavigator: ObservableObject {
    @Published var page: MainPage
    init(_ page: MainPage = .home) { self.page = page }
}

/// Window shell (DESIGN.md): 216pt sidebar on `bg.window` with a trailing
/// 1px hairline; content with 32pt padding.
struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: PageNavigator
    /// Snapshot-only: pre-expand this history row.
    var initialExpandedID: String? = nil
    @HushReducedMotion private var reduceMotion
    @Namespace private var selectionMotion

    init(model: AppModel, nav: PageNavigator? = nil, initialPage: MainPage = .home,
         initialExpandedID: String? = nil) {
        self.model = model
        self.nav = nav ?? PageNavigator(initialPage)
        self.initialExpandedID = initialExpandedID
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 216)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Theme.Color.hairline)
                        .frame(width: 1)
                }
            ZStack {
                content
                    .id(nav.page)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 14)),
                        removal: .opacity.combined(with: .offset(x: -8))))
            }
            .animation(Theme.Motion.navigation(reduceMotion), value: nav.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Color.window)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.window)
    }

    // MARK: - sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Hush")
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, 40)   // clears the traffic lights
            .padding(.bottom, Theme.Space.l)

            navItem(.home)
            navItem(.history)
            navItem(.dictionary)
            navItem(.styles)

            Spacer()

            navItem(.settings)
                .padding(.bottom, Theme.Space.l)
        }
    }

    @ViewBuilder
    private func navItem(_ item: MainPage) -> some View {
        let selected = nav.page == item
        Button {
            withAnimation(Theme.Motion.navigation(reduceMotion)) { nav.page = item }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(selected ? Theme.Color.signal : Theme.Color.textSecondary)
                    .frame(width: 20)
                    .symbolEffect(.bounce, value: selected && !reduceMotion)
                Text(item.title)
                    .font(Theme.Font.body)
                    .foregroundStyle(selected ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 32)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Color.raised)
                        .matchedGeometryEffect(id: "selection", in: selectionMotion, properties: reduceMotion ? [] : .frame)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarItemStyle())
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 1)
    }

    // MARK: - content

    @ViewBuilder
    private var content: some View {
        switch nav.page {
        case .home:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader("Home")
                    HomeView(model: model, goToHistory: { nav.page = .history })
                }
                .padding(Theme.Space.contentPadding)
            }
            .scrollIndicators(.hidden)
        case .history:
            HistoryView(model: model, initialExpandedID: initialExpandedID)
        case .dictionary:
            PlaceholderPage(
                title: "Dictionary",
                text: "Your personal terms and text replacements will live here — Hush will learn how you spell names and jargon."
            )
        case .styles:
            StylesView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }
}

/// Hover white 4% for sidebar items.
private struct SidebarItemStyle: ButtonStyle {
    @State private var hovering = false
    @HushReducedMotion private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(hovering ? 0.04 : 0),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .onHover { hovering = $0 }
            .animation(Theme.Motion.hover, value: hovering)
            .animation(Theme.Motion.response(reduceMotion), value: configuration.isPressed)
    }
}

/// Dictionary/Styles: title + one honest tile (DESIGN.md — no fake controls).
struct PlaceholderPage: View {
    var title: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title)
            Tile("COMING SOON") {
                Text(text)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(Theme.Space.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Page `title` at top-left.
struct PageHeader: View {
    var title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(Theme.Font.title)
            .tracking(-0.01 * 22)
            .foregroundStyle(Theme.Color.textPrimary)
            .padding(.bottom, Theme.Space.xl)
    }
}
