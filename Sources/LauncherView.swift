import SwiftUI
import AppKit

struct LauncherView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var c: LauncherController
    @AppStorage("columns") private var columns = 7
    @AppStorage("rows") private var rows = 5
    @AppStorage("iconSize") private var iconSize = 88.0
    @FocusState private var searchFocused: Bool

    private var perPage: Int { max(1, columns * rows) }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { c.hide() }
                .contextMenu { Button("Settings…") { c.openSettings() } }

            VStack(spacing: 18) {
                searchField
                    .padding(.top, 34)
                if c.query.isEmpty { pager } else { results }
                pageDots
                    .padding(.bottom, 26)
            }
            .padding(.horizontal, 70)
        }
        .scaleEffect(c.shown ? 1 : 1.06)
        .opacity(c.shown ? 1 : 0)
        .onChange(of: c.focusTick) { _, _ in searchFocused = true }
    }

    // MARK: search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.7))
            TextField("", text: $c.query, prompt: Text("Search").foregroundColor(.white.opacity(0.55)))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .focused($searchFocused)
                .onChange(of: c.query) { _, _ in c.selection = c.query.isEmpty ? nil : 0 }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(width: 240, height: 28)
        .background(Capsule().fill(.white.opacity(0.16)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
    }

    // MARK: pages

    private var pages: [[AppItem]] {
        stride(from: 0, to: store.apps.count, by: perPage).map {
            Array(store.apps[$0..<min($0 + perPage, store.apps.count)])
        }
    }

    private var pager: some View {
        let p = pages
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(p.indices, id: \.self) { i in
                    PageGrid(items: p[i], base: i * perPage, columns: columns, rows: rows,
                             iconSize: iconSize, store: store, c: c)
                        .containerRelativeFrame(.horizontal)
                        .id(i)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $c.page)
        .scrollIndicators(.never)
        .onAppear { c.pageCount = p.count }
        .onChange(of: p.count) { _, n in c.pageCount = n }
    }

    private var results: some View {
        let found = Array(c.results.prefix(perPage))
        return Group {
            if found.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    Text("No apps match “\(c.query)”").foregroundStyle(.white.opacity(0.8))
                    Button { c.searchSpotlight() } label: {
                        Label("Search in Spotlight", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    Text("⌘↩").font(.caption).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PageGrid(items: found, base: 0, columns: columns, rows: rows,
                         iconSize: iconSize, store: store, c: c)
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 9) {
            if c.query.isEmpty && c.pageCount > 1 {
                ForEach(0..<c.pageCount, id: \.self) { i in
                    Circle()
                        .fill(.white.opacity((c.page ?? 0) == i ? 0.95 : 0.35))
                        .frame(width: 7, height: 7)
                        .onTapGesture { withAnimation(.easeOut(duration: 0.25)) { c.page = i } }
                }
            }
        }
        .frame(height: 10)
    }
}

struct PageGrid: View {
    let items: [AppItem]
    let base: Int
    let columns: Int
    let rows: Int
    let iconSize: Double
    @ObservedObject var store: AppStore
    @ObservedObject var c: LauncherController

    var body: some View {
        GeometryReader { g in
            let cw = g.size.width / CGFloat(max(columns, 1))
            let ch = g.size.height / CGFloat(max(rows, 1))
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<columns, id: \.self) { col in
                            let idx = r * columns + col
                            if idx < items.count {
                                AppCell(item: items[idx], selected: c.selection == base + idx,
                                        iconSize: min(iconSize, Double(ch) * 0.62), width: cw, store: store, c: c)
                                    .frame(width: cw, height: ch)
                            } else {
                                Color.clear.contentShape(Rectangle())
                                    .frame(width: cw, height: ch)
                                    .onTapGesture { c.hide() }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AppCell: View {
    let item: AppItem
    let selected: Bool
    let iconSize: Double
    let width: CGFloat
    @ObservedObject var store: AppStore
    @ObservedObject var c: LauncherController

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: store.icon(for: item))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
            Text(item.name)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: width - 16)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(selected ? 0.2 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { c.launch(item) }
        .contextMenu {
            Button("Open") { c.launch(item) }
            Button("Show in Finder") { c.hideThen { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
            Divider()
            Button("Hide from Launcher") { var h = store.hidden; h.insert(item.id); store.hidden = h }
            Divider()
            Button("Settings…") { c.openSettings() }
        }
    }
}
