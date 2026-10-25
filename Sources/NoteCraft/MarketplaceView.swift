import NoteCraftCore
import SwiftUI

// The marketplace in the library: the free catalog of themes, stickers, templates and planners.
// What each pack is and how it is installed is `MarketplaceStore`; this is the shop window.

struct MarketplaceView: View {
  @Bindable var vault: VaultController
  @Binding var sidebar: Bool
  // Back to the documents, after a notebook was started from a pack.
  let leave: () -> Void

  enum Tab: String, CaseIterable, Identifiable {
    case discover, saved, installed
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
  }

  @State private var search = ""
  @State private var tab = Tab.discover
  @State private var category: CatalogCategory?
  @State private var kind: PackKind?
  @State private var selected: CatalogEntry?

  private var store: MarketplaceStore { .shared }
  private var secondary: Color { Color.theme(.textSecondary) }

  private var entries: [CatalogEntry] {
    func keep(_ entry: CatalogEntry) -> Bool {
      (category == nil || entry.category == category) && (kind == nil || entry.kind == kind)
        && entry.matches(search)
    }
    let all: [CatalogEntry]
    switch tab {
    case .discover: all = store.index.packs
    case .saved: all = store.index.packs.filter { store.isSaved($0.id) }
    // What is installed is shown as the catalog has it now (an update shows), or as it was.
    case .installed: all = store.installed.map { store.entry($0.id) ?? $0.entry }
    }
    return all.filter(keep).sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      header
      tabs
      categories
      if case .failed(let message) = store.status { problem(message) }
      ScrollView {
        if entries.isEmpty {
          empty
        } else {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 28)],
            alignment: .leading, spacing: 32
          ) {
            ForEach(entries) { entry in
              PackCard(entry: entry, onOpen: { selected = entry }, onError: { vault.error = $0 })
            }
          }.padding(.top, 8).padding(.bottom, 30)
        }
      }
      footer
    }
    .sheet(item: $selected) { entry in
      PackPage(entry: entry, vault: vault) {
        selected = nil
        leave()
      }
    }
    .task { await store.refresh() }
  }

  private var header: some View {
    HStack {
      if !sidebar {
        Button {
          sidebar = true
        } label: {
          Symbol("sidebar.left")
        }.buttonStyle(.plain)
      }
      Text("Marketplace").font(.theme(32, .semibold)).lineLimit(1)
      if store.status == .loading { ProgressView().padding(.leading, 6) }
      Spacer()
      HStack(spacing: 10) {
        Symbol("magnifyingglass")
        TextField("Search packs", text: $search).frame(maxWidth: 180)
          .accessibilityLabel("Search marketplace").accessibilityIdentifier("marketplaceSearch")
        if !search.isEmpty {
          Button {
            search = ""
          } label: {
            Symbol("xmark.circle.fill")
          }.buttonStyle(.plain).accessibilityLabel("Clear search")
        }
      }.padding(12).background(Color.theme(.field), in: Capsule()).overlay(
        Capsule().stroke(Color.theme(.separator)))
    }
  }

  private var tabs: some View {
    HStack(spacing: 10) {
      ForEach(Tab.allCases) { option in
        let count = option == .saved ? store.saved.count : option == .installed ? store.installed.count : nil
        Button {
          tab = option
        } label: {
          HStack(spacing: 6) {
            Text(option.title)
            if let count, count > 0 { Text("\(count)").foregroundStyle(secondary) }
          }.font(.theme(16, tab == option ? .semibold : .regular)).padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(tab == option ? Color.theme(.surfaceRaised) : .clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("marketplaceTab-" + option.rawValue)
          .accessibilityAddTraits(tab == option ? .isSelected : [])
      }
      Spacer()
      Menu {
        Button("All kinds") { kind = nil }
        ForEach(PackKind.allCases, id: \.self) { option in
          Button(option.plural, systemImage: Icon.name(option.symbol)) { kind = option }
        }
      } label: {
        Label(kind?.plural ?? "All kinds", systemImage: Icon.name("line.3.horizontal.decrease"))
      }.foregroundStyle(secondary).accessibilityIdentifier("marketplaceKind")
    }
  }

  private var categories: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        chip("All", selected: category == nil) { category = nil }
        ForEach(CatalogCategory.allCases, id: \.self) { option in
          chip(option.title, selected: category == option) { category = option }
        }
      }
    }
  }

  private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.theme(15, .medium)).padding(.horizontal, 16).padding(.vertical, 8)
        .foregroundStyle(selected ? Color.theme(.accentText) : Color.theme(.textPrimary))
        .background(
          selected ? Color.theme(.accent) : Color.theme(.field), in: Capsule()
        ).overlay(Capsule().stroke(Color.theme(.separator), lineWidth: selected ? 0 : 1))
    }.buttonStyle(.plain).accessibilityIdentifier("marketplaceCategory-" + title)
      .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func problem(_ message: String) -> some View {
    HStack(spacing: 12) {
      Symbol("wifi.exclamationmark")
      Text(message).font(.theme(14)).lineLimit(2)
      Spacer()
      Button("Try again") { Task { await store.refresh() } }.font(.theme(14, .semibold))
    }.padding(14).background(Color.theme(.field), in: RoundedRectangle(cornerRadius: .corner(12)))
      .accessibilityIdentifier("marketplaceProblem")
  }

  @ViewBuilder private var empty: some View {
    switch tab {
    case .saved where search.isEmpty && category == nil && kind == nil:
      ContentUnavailableView(
        "Nothing saved yet", systemImage: Icon.name("heart"),
        description: Text("Tap the heart on a pack to keep it here."))
    case .installed where search.isEmpty && category == nil && kind == nil:
      ContentUnavailableView(
        "Nothing installed yet", systemImage: Icon.name("square.and.arrow.down"),
        description: Text("Packs you get show up here, with a way to take them away again."))
    default:
      ContentUnavailableView.search(text: search)
    }
  }

  private var footer: some View {
    HStack {
      Text("\(entries.count) \(entries.count == 1 ? "pack" : "packs")")
      Spacer()
      if let updated = store.updated {
        Text("Catalog updated \(updated.formatted(.relative(presentation: .named)))")
      } else {
        Text("Packs that came with the app")
      }
    }.font(.theme(12)).foregroundStyle(secondary)
  }
}

// MARK: a pack in the grid

struct PackCard: View {
  let entry: CatalogEntry
  let onOpen: () -> Void
  let onError: (String) -> Void

  var body: some View {
    let store = MarketplaceStore.shared
    VStack(alignment: .leading, spacing: 10) {
      Button(action: onOpen) {
        VStack(alignment: .leading, spacing: 10) {
          PackPreview(entry: entry).aspectRatio(1, contentMode: .fit)
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(.theme(16, .semibold)).lineLimit(1)
            Text("\(entry.kind.title) · \(entry.author)").font(.theme(13))
              .foregroundStyle(Color.theme(.textSecondary)).lineLimit(1)
          }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityIdentifier("pack-" + entry.id)
        .accessibilityLabel("\(entry.name), \(entry.kind.title)")
      HStack {
        PackGetButton(entry: entry, onError: onError).accessibilityIdentifier("get-" + entry.id)
        Spacer()
        Button {
          store.toggleSaved(entry.id)
        } label: {
          Symbol(store.isSaved(entry.id) ? "heart.fill" : "heart").font(.theme(20))
            .foregroundStyle(store.isSaved(entry.id) ? Color.theme(.favorite) : Color.theme(.textSecondary))
            .frame(width: 36, height: 36)
        }.buttonStyle(.plain).accessibilityLabel(store.isSaved(entry.id) ? "Remove from saved" : "Save")
          .accessibilityIdentifier("save-" + entry.id)
      }
    }
  }
}

// What the preview of a pack is drawn in: a picture that is fetched when it is first shown.
struct PackPreview: View {
  let entry: CatalogEntry
  @State private var image: CGImage?

  var body: some View {
    ZStack {
      Color.theme(.field)
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFit().padding(8)
      } else {
        Symbol(entry.kind.symbol).font(.theme(34, .light)).foregroundStyle(Color.theme(.textSecondary))
      }
    }.clipShape(RoundedRectangle(cornerRadius: .corner(14)))
      .overlay(RoundedRectangle(cornerRadius: .corner(14)).stroke(Color.theme(.separator), lineWidth: 1))
      .task(id: entry.sha256) { image = await MarketplaceStore.shared.preview(for: entry) }
  }
}

// Get, Update or Installed, and a wait while it downloads.
struct PackGetButton: View {
  let entry: CatalogEntry
  let onError: (String) -> Void
  var large = false

  var body: some View {
    let store = MarketplaceStore.shared
    let installed = store.isInstalled(entry.id)
    let update = store.hasUpdate(entry.id)
    let working = store.working.contains(entry.id)
    Button {
      guard !working, !installed || update else { return }
      Task {
        do { try await store.install(entry) } catch { onError(error.localizedDescription) }
      }
    } label: {
      HStack(spacing: 6) {
        if working {
          ProgressView().controlSize(.small)
        } else if installed && !update {
          Symbol("checkmark")
        }
        Text(working ? "Getting…" : update ? "Update" : installed ? "Installed" : "Get")
      }.font(.theme(large ? 17 : 15, .semibold)).padding(.horizontal, large ? 26 : 18)
        .padding(.vertical, large ? 11 : 8)
        .foregroundStyle(installed && !update ? Color.theme(.textSecondary) : Color.theme(.accentText))
        .background(
          installed && !update ? Color.theme(.field) : Color.theme(.accent), in: Capsule())
    }.buttonStyle(.plain).disabled(working)
  }
}

// MARK: the page of a pack

struct PackPage: View {
  let entry: CatalogEntry
  @Bindable var vault: VaultController
  let startedNotebook: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var message: String?
  @State private var confirmRemove = false

  private var store: MarketplaceStore { .shared }
  private var secondary: Color { Color.theme(.textSecondary) }

  var body: some View {
    let installed = store.isInstalled(entry.id)
    VStack(spacing: 0) {
      HStack {
        Spacer()
        Button("Done") { dismiss() }.accessibilityIdentifier("packClose")
      }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          PackPreview(entry: entry).frame(maxHeight: 360).aspectRatio(entry.kind == .template || entry.kind == .planner ? 1.15 : 1.5, contentMode: .fit)
            .frame(maxWidth: .infinity)
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.name).font(.theme(28, .bold)).accessibilityIdentifier("packName")
            Text("\(entry.kind.title) by \(entry.author)").font(.theme(15)).foregroundStyle(secondary)
          }
          HStack(spacing: 12) {
            PackGetButton(entry: entry, onError: { message = $0 }, large: true)
              .accessibilityIdentifier("packGet")
            if installed { useButton }
            Spacer()
            Button {
              store.toggleSaved(entry.id)
            } label: {
              Symbol(store.isSaved(entry.id) ? "heart.fill" : "heart").font(.theme(22))
                .foregroundStyle(store.isSaved(entry.id) ? Color.theme(.favorite) : secondary)
                .frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityIdentifier("packSave")
              .accessibilityLabel(store.isSaved(entry.id) ? "Remove from saved" : "Save")
            if installed {
              Button("Remove", role: .destructive) { confirmRemove = true }
                .accessibilityIdentifier("packRemove")
            }
          }
          if let message {
            Text(message).font(.theme(14)).foregroundStyle(Color.theme(.danger))
              .accessibilityIdentifier("packMessage")
          }
          if !entry.summary.isEmpty { Text(entry.summary).font(.theme(17)) }
          usage
          details
          if !entry.tags.isEmpty {
            HStack { ForEach(entry.tags, id: \.self) { tag in
              Text(tag).font(.theme(13)).padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.theme(.field), in: Capsule())
            } }
          }
        }.padding(.horizontal, 28).padding(.bottom, 32).frame(maxWidth: 640)
          .frame(maxWidth: .infinity)
      }
    }
    .themedSheet()
    .preferredColorScheme(ThemeStore.shared.preferredColorScheme)
    .confirmationDialog(
      "Remove “\(entry.name)”?", isPresented: $confirmRemove, titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) { store.uninstall(entry.id) }
    } message: {
      Text(removalNote)
    }
  }

  private var removalNote: String {
    switch entry.kind {
    case .theme: "The theme is taken away. If it is in use, the app goes back to the classic theme."
    case .sticker: "The stickers are taken out of your library. Stickers already on a page stay there."
    case .template: "The template is taken away. Pages you added from it stay in your notebooks."
    case .planner: "The planner is taken away. Notebooks you started from it stay."
    }
  }

  @ViewBuilder private var useButton: some View {
    switch entry.kind {
    case .theme:
      let inUse = ThemeStore.shared.current.id == entry.id
      Button(inUse ? "In use" : "Use theme") { ThemeStore.shared.select(entry.id) }
        .buttonStyle(.plain).font(.theme(17, .semibold)).foregroundStyle(inUse ? secondary : Color.theme(.accent))
        .disabled(inUse).accessibilityIdentifier("packUse")
    case .planner, .template:
      Button("New notebook") { Task { await startNotebook() } }
        .buttonStyle(.plain).font(.theme(17, .semibold)).foregroundStyle(Color.theme(.accent))
        .disabled(vault.busy).accessibilityIdentifier("packUse")
    case .sticker:
      EmptyView()
    }
  }

  // Where to find it, once it is installed.
  @ViewBuilder private var usage: some View {
    if store.isInstalled(entry.id) {
      switch entry.kind {
      case .theme: Text("Choose it in Settings ▸ Appearance, or use it here.")
      case .sticker: Text("Open a notebook, choose the Stickers tool and look under your elements.")
      case .template: Text("In a notebook, New page ▸ Your templates adds its pages. “New notebook” starts one from it.")
      case .planner: Text("“New notebook” starts a notebook of its own from the planner.")
      }
    }
  }

  private var details: some View {
    VStack(spacing: 0) {
      detail("Category", entry.category.title)
      if let pages = entry.pages { detail("Pages", "\(pages)") }
      detail("Version", entry.version)
      detail("Size", ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
      detail("License", entry.license)
    }.padding(.horizontal, 16).background(
      Color.theme(.field), in: RoundedRectangle(cornerRadius: .corner(12)))
  }

  private func detail(_ name: String, _ value: String) -> some View {
    HStack {
      Text(name).foregroundStyle(secondary)
      Spacer()
      Text(value)
    }.font(.theme(15)).padding(.vertical, 12).overlay(alignment: .bottom) {
      Divider().overlay(Color.theme(.separator))
    }
  }

  private func startNotebook() async {
    do {
      let package = try store.newNotebook(from: entry.id)
      await vault.create(from: package)
      if vault.error == nil { startedNotebook() }
    } catch { message = error.localizedDescription }
  }
}

// MARK: settings

struct MarketplaceSettings: View {
  @State private var address = MarketplaceStore.shared.address
  @State private var message: String?

  var body: some View {
    let store = MarketplaceStore.shared
    Form {
      Section {
        TextField("Catalog address", text: $address)
          .autocorrectionDisabled().accessibilityIdentifier("marketplaceAddress")
          #if os(iOS)
            .textInputAutocapitalization(.never).keyboardType(.URL)
          #endif
          .onSubmit(apply)
        Button("Use this address", action: apply)
        Button("Use the default address") {
          address = MarketplaceStore.defaultAddress
          apply()
        }.disabled(store.address == MarketplaceStore.defaultAddress)
        if let message { Text(message).font(.theme(13)).foregroundStyle(Color.theme(.danger)) }
      } header: {
        Text("Catalog")
      } footer: {
        Text(
          "Packs are downloaded from a folder on a web server (https only) that holds an index.json, "
            + "the packs and their previews. Every pack is checked against the size and hash in the "
            + "index before it is opened, and a pack never holds code. See docs/MARKETPLACE.md.")
      }
      Section {
        LabeledContent("Installed packs", value: "\(store.installed.count)")
        LabeledContent("Saved packs", value: "\(store.saved.count)")
        Button("Check for new packs") { Task { await store.refresh() } }
          .disabled(!store.canRefresh || store.status == .loading)
        if case .failed(let why) = store.status { Text(why).font(.theme(13)).foregroundStyle(Color.theme(.danger)) }
      }
    }.navigationTitle("Marketplace")
  }

  private func apply() {
    do {
      try MarketplaceStore.shared.setAddress(address)
      address = MarketplaceStore.shared.address
      message = nil
      Task { await MarketplaceStore.shared.refresh() }
    } catch { message = error.localizedDescription }
  }
}
