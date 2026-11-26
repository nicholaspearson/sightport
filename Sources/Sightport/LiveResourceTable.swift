import AppKit
import SwiftUI
import SightportCore

enum LiveCell {
    case text(String, color: NSColor = .labelColor, bold: Bool = false, help: String? = nil)
    case link(String, help: String? = nil, action: () -> Void)
    case check(Bool, help: String, action: () -> Void)
    case symbol(String, color: NSColor, help: String)
    case indicators([NSColor], extra: Int, help: String)
    case menu(help: String)
    case age(Date?)
    case empty
}

struct LiveColumn<Item> {
    let id: String
    let title: String
    let width: CGFloat
    let minWidth: CGFloat
    var sort: KeyPathComparator<Item>? = nil
    let cell: (Item) -> LiveCell
}

// SwiftUI owns filtering and ordering. AppKit asks for only the cells on screen.
struct LiveResourceTable<Item: Identifiable & Equatable>: NSViewRepresentable where Item.ID == String {
    let items: [Item]
    let dataID: AnyHashable
    var visualID: AnyHashable = 0
    var scrollID: AnyHashable = 0
    let columns: [LiveColumn<Item>]
    @Binding var selection: String?
    @Binding var sortOrder: [KeyPathComparator<Item>]
    var onInteraction: () -> Void = {}
    let menu: (Item) -> NSMenu?
    let doubleClick: (Item) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = ResourceNSTableView()
        table.style = .fullWidth
        table.usesAutomaticRowHeights = false
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = NSColor(Palette.line)
        table.backgroundColor = NSColor(Palette.canvas)
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = table
        table.doubleAction = #selector(ResourceNSTableView.activateRow)
        table.rowMenu = { [weak coordinator = context.coordinator] row in coordinator?.menu(at: row) }
        table.rowClicked = { [weak coordinator = context.coordinator] in coordinator?.model.onInteraction() }
        table.activate = { [weak coordinator = context.coordinator] row in coordinator?.activate(row) }
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.ageTimer?.invalidate()
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        fileprivate var model: LiveResourceTable
        fileprivate weak var table: ResourceNSTableView?
        fileprivate var ageTimer: Timer?
        private var dataID: AnyHashable?
        private var visualID: AnyHashable?
        private var positions: [String: Int] = [:]
        private var updating = false

        init(_ model: LiveResourceTable) { self.model = model }

        func update(_ next: LiveResourceTable) {
            guard let table else { return }
            updating = true
            defer { updating = false }
            let newData = dataID != next.dataID
            let newStyle = visualID != next.visualID
            let resetScroll = model.scrollID != next.scrollID
            let previousItems = model.items
            let rebuild = table.tableColumns.count != next.columns.count || zip(table.tableColumns, next.columns).contains {
                $0.identifier.rawValue != $1.id || $0.title != $1.title
            }
            let viewport = table.visibleRect
            // AppKit can overlay the column header on the clip view. Its inset is
            // part of visibleRect even though rows under the header are obscured.
            let headerInset = table.enclosingScrollView?.contentView.contentInsets.top ?? 0
            let visibleTop = viewport.minY + headerInset
            let first = table.row(at: NSPoint(x: viewport.midX, y: visibleTop + 0.5))
            let anchor = newData && !resetScroll && model.items.indices.contains(first) ? model.items[first].id : nil
            let offset = anchor == nil ? 0 : visibleTop - table.rect(ofRow: first).minY
            model = next
            dataID = next.dataID
            visualID = next.visualID
            if rebuild {
                for column in table.tableColumns { table.removeTableColumn(column) }
                for spec in next.columns {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
                    column.title = spec.title
                    column.minWidth = spec.minWidth
                    column.width = spec.width
                    if spec.width == spec.minWidth {
                        column.maxWidth = spec.width
                        column.resizingMask = []
                    }
                    if let sort = spec.sort {
                        column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: sort.order == .forward)
                    }
                    table.addTableColumn(column)
                }
            }
            if newData {
                positions = Dictionary(next.items.indices.lazy.map { (next.items[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
                if previousItems.count != next.items.count { table.noteNumberOfRowsChanged() }
                if let anchor, let index = positions[anchor], index != first, let clip = table.enclosingScrollView?.contentView {
                    let point = NSPoint(x: viewport.minX, y: table.rect(ofRow: index).minY + offset - headerInset)
                    let constrained = clip.constrainBoundsRect(NSRect(origin: point, size: clip.bounds.size))
                    clip.scroll(to: constrained.origin)
                    table.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            }
            if resetScroll, !next.items.isEmpty { table.scrollRowToVisible(0) }
            if rebuild { table.reloadData() }
            else if newData || newStyle {
                table.enumerateAvailableRowViews { rowView, row in
                    guard self.model.items.indices.contains(row) else { return }
                    if !newStyle, previousItems.indices.contains(row), previousItems[row] == self.model.items[row] {
                        return
                    }
                    for index in self.model.columns.indices {
                        if let cell = rowView.view(atColumn: index) as? ResourceTableCell {
                            self.configure(cell, at: row, column: index)
                        }
                    }
                }
            }
            let selected = next.selection.flatMap { positions[$0] } ?? -1
            if table.selectedRow != selected {
                if selected >= 0 { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
                else { table.deselectAll(nil) }
            }
            let descriptors = next.sortOrder.compactMap { order -> NSSortDescriptor? in
                guard let column = next.columns.first(where: {
                    var comparator = $0.sort
                    comparator?.order = order.order
                    return comparator == order
                }) else { return nil }
                return NSSortDescriptor(key: column.id, ascending: order.order == .forward)
            }
            if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { model.items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, model.items.indices.contains(row) else { return nil }
            let index = tableView.column(withIdentifier: tableColumn.identifier)
            guard model.columns.indices.contains(index) else { return nil }
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? ResourceTableCell ?? ResourceTableCell()
            cell.identifier = tableColumn.identifier
            configure(cell, at: row, column: index)
            return cell
        }

        private func configure(_ view: ResourceTableCell, at row: Int, column: Int) {
            let item = model.items[row]
            let content = model.columns[column].cell(item)
            view.set(content)
            if case .menu = content {
                view.action = { [weak self, weak view] in
                    guard let self, let view, let table else { return }
                    let index = table.row(for: view)
                    menu(at: index)?.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
                }
            }
            if let next = view.updateAge(at: Date()) { scheduleAges(at: next) }
        }

        private func scheduleAges(at date: Date) {
            if let timer = ageTimer, timer.isValid, timer.fireDate <= date { return }
            ageTimer?.invalidate()
            let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAges() }
            }
            timer.tolerance = 0.1
            ageTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        private func refreshAges() {
            ageTimer = nil
            guard let table else { return }
            let now = Date()
            var next: Date?
            table.enumerateAvailableRowViews { rowView, _ in
                for cell in rowView.subviews.compactMap({ $0 as? ResourceTableCell }) {
                    if let update = cell.updateAge(at: now) { next = min(next ?? update, update) }
                }
            }
            if let next { scheduleAges(at: next) }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("resource-row")
            let view = tableView.makeView(withIdentifier: id, owner: nil) as? HoverResourceRow ?? HoverResourceRow()
            view.identifier = id
            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let row = table?.selectedRow else { return }
            let id = model.items.indices.contains(row) ? model.items[row].id : nil
            if model.selection != id {
                if id != nil { model.onInteraction() }
                model.selection = id
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating else { return }
            let sort = tableView.sortDescriptors.compactMap { descriptor -> KeyPathComparator<Item>? in
                var comparator = model.columns.first(where: { $0.id == descriptor.key })?.sort
                comparator?.order = descriptor.ascending ? .forward : .reverse
                return comparator
            }
            if model.sortOrder != sort {
                model.onInteraction()
                model.sortOrder = sort
            }
        }

        fileprivate func menu(at row: Int) -> NSMenu? {
            guard model.items.indices.contains(row) else { return nil }
            let menu = model.menu(model.items[row])
            if menu != nil { model.onInteraction() }
            return menu
        }

        fileprivate func activate(_ row: Int) {
            guard model.items.indices.contains(row) else { return }
            model.doubleClick(model.items[row])
        }
    }
}

private final class ResourceNSTableView: NSTableView {
    var rowMenu: ((Int) -> NSMenu?)?
    var activate: ((Int) -> Void)?
    var rowClicked: (() -> Void)?

    override func drawGrid(inClipRect clipRect: NSRect) {
        // AppKit normally continues the grid below the last data row.
        guard numberOfRows > 0 else { return }
        let lastRow = rect(ofRow: numberOfRows - 1)
        let rows = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: lastRow.maxY - bounds.minY)
        let visibleGrid = clipRect.intersection(rows)
        if !visibleGrid.isEmpty { super.drawGrid(inClipRect: visibleGrid) }
    }

    override func mouseDown(with event: NSEvent) {
        if row(at: convert(event.locationInWindow, from: nil)) >= 0 { rowClicked?() }
        super.mouseDown(with: event)
    }
    @objc func activateRow() { activate?(clickedRow) }
    override func menu(for event: NSEvent) -> NSMenu? {
        rowMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

private final class HoverResourceRow: NSTableRowView {
    private var area: NSTrackingArea?
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if area == nil {
            let area = NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited], owner: self)
            self.area = area
            addTrackingArea(area)
        }
        if let window { hovering = visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func drawBackground(in dirtyRect: NSRect) {
        if hovering && !isSelected {
            NSColor(Palette.rowHover).setFill()
            dirtyRect.fill()
        } else { super.drawBackground(in: dirtyRect) }
    }
}

private final class ResourceTableCell: NSTableCellView {
    private enum Control { case label, check, link, menu, symbol, indicators }
    private var control: Control?
    private var content: NSView?
    private var createdAt: Date?
    var action: (() -> Void)?

    func set(_ value: LiveCell) {
        createdAt = nil
        action = nil
        toolTip = nil
        switch value {
        case let .text(string, color, bold, help):
            label(string, color: color, bold: bold)
            toolTip = help ?? string
        case let .age(date):
            label("—", color: NSColor(Palette.muted))
            createdAt = date
            toolTip = date?.formatted(date: .abbreviated, time: .standard)
        case let .link(string, help, callback):
            let button = button(.link)
            button.attributedTitle = NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor(Palette.forest),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ])
            button.setAccessibilityLabel(string)
            toolTip = help ?? string
            action = callback
        case let .check(enabled, help, callback):
            let button = button(.check)
            button.state = enabled ? .on : .off
            button.setAccessibilityLabel(help)
            toolTip = help
            action = callback
        case let .menu(help):
            let button = button(.menu)
            button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
            button.contentTintColor = NSColor(Palette.forest)
            button.setAccessibilityLabel(help)
            toolTip = help
        case let .symbol(symbol, color, help):
            let image: NSImageView = install(.symbol) { NSImageView() }
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
            image.contentTintColor = color
            image.imageScaling = .scaleProportionallyDown
            image.setAccessibilityLabel(help)
            toolTip = help
        case let .indicators(colors, extra, help):
            let dots: ContainerDots = install(.indicators) { ContainerDots() }
            dots.colors = colors
            dots.extra = extra
            dots.needsDisplay = true
            dots.setAccessibilityElement(true)
            dots.setAccessibilityRole(.image)
            dots.setAccessibilityLabel(help)
            toolTip = help
        case .empty: label("", color: .clear)
        }
    }

    @discardableResult
    private func install<V: NSView>(_ kind: Control, _ make: () -> V) -> V {
        if control == kind, let view = content as? V { return view }
        content?.removeFromSuperview()
        let view = make()
        addSubview(view)
        content = view
        control = kind
        needsLayout = true
        return view
    }

    private func label(_ string: String, color: NSColor, bold: Bool = false) {
        let field: NSTextField = install(.label) {
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            return field
        }
        field.font = .systemFont(ofSize: 11.5, weight: bold ? .semibold : .regular)
        field.textColor = color
        field.stringValue = string
    }

    private func button(_ style: Control) -> NSButton {
        install(style) {
            let button = NSButton(title: "", target: self, action: #selector(performAction))
            button.isBordered = false
            button.controlSize = .small
            button.alignment = .left
            button.lineBreakMode = .byTruncatingMiddle
            if style == .check { button.setButtonType(.switch) }
            if style == .menu { button.imagePosition = .imageOnly }
            return button
        }
    }

    @objc private func performAction() { action?() }

    func updateAge(at now: Date) -> Date? {
        guard let date = createdAt, let label = content as? NSTextField else { return nil }
        let age = ResourceAge(createdAt: date, now: now)
        if label.stringValue != age.text { label.stringValue = age.text }
        return age.nextChange
    }

    override func layout() {
        super.layout()
        guard let content else { return }
        let compact = control == .check || control == .menu || control == .symbol
        let width = compact ? min(20, bounds.width) : max(0, bounds.width - 14)
        content.frame = NSRect(x: compact ? (bounds.width - width) / 2 : 7, y: floor((bounds.height - 17) / 2), width: width, height: 17)
    }
}

private final class ContainerDots: NSView {
    var colors: [NSColor] = []
    var extra = 0
    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for color in colors {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 5, width: 7, height: 7), xRadius: 1, yRadius: 1).fill()
            x += 10
        }
        if extra > 0 {
            ("+" + String(extra) as NSString).draw(at: NSPoint(x: x, y: 2), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(Palette.muted)
            ])
        }
    }
}
