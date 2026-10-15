import Foundation

/// Rearranging list items: Ctrl-Cmd-Up/Down and dragging an item by its
/// marker (issue #12 item 6).
///
/// Kept free of AppKit like `Checklist` and `OrderedList`, so the rules live
/// in one place the tests can reach. The text view only turns the edit this
/// returns into one undoable replacement.
///
/// The rules, stated once:
///   - an item is a checkbox (`- [ ] `), a bullet (`- `) or an ordered line
///     (`1. `, `a. `, `iv. `);
///   - an item owns the lines below it that are indented deeper, so nested
///     children travel with their parent;
///   - an item moves among its siblings: the items at the same indent under
///     the same parent, up to a blank line, a shallower line, or a line at
///     the same indent that is not an item;
///   - when every sibling is an ordered item numbered in sequence, the
///     siblings are renumbered from the first one's value after the move.
///     A list typed out of sequence (`1. 1. 1.`) keeps exactly what was typed;
///   - a selection moves every sibling it touches, as one block.
enum ListMove {

    enum Direction: Equatable {
        case up, down
    }

    /// One text replacement plus where the selection goes afterwards.
    struct Edit: Equatable {
        var range: NSRange
        var replacement: String
        var selection: NSRange
    }

    /// What a keyboard move resolved to.
    enum Outcome: Equatable {
        /// The caret is not in a list item: the chord means something else.
        case notInList
        /// In a list, but already first (or last) among its siblings.
        case atBoundary
        case moved(Edit)
    }

    /// The siblings a dragged item can be dropped between.
    struct DragContext: Equatable {
        /// Index of the dragged item among `itemRanges`.
        var itemIndex: Int
        /// Each sibling's whole block, children included, newline excluded.
        var itemRanges: [NSRange]

        /// Character locations of the drop slots: before each sibling, then
        /// after the last. Slot `i` inserts before sibling `i`.
        var slotLocations: [Int] {
            itemRanges.map(\.location) + [NSMaxRange(itemRanges.last ?? NSRange(location: 0, length: 0))]
        }

        /// Dropping into either slot touching the item itself changes nothing.
        func isNoOp(slot: Int) -> Bool { slot == itemIndex || slot == itemIndex + 1 }
    }

    // MARK: - Public entry points

    static func move(_ direction: Direction, in text: String, selection: NSRange) -> Outcome {
        let doc = Document(text)
        guard let (group, moved) = doc.selectedUnits(selection) else { return .notInList }
        let slot: Int
        switch direction {
        case .up:
            guard moved.lowerBound > 0 else { return .atBoundary }
            slot = moved.lowerBound - 1
        case .down:
            guard moved.upperBound < group.units.count - 1 else { return .atBoundary }
            slot = moved.upperBound + 2
        }
        guard let edit = doc.edit(group: group, moving: moved, toSlot: slot, selection: selection) else {
            return .atBoundary
        }
        return .moved(edit)
    }

    /// The drag context for the item whose line contains `location`, or nil
    /// when that line is not a list item.
    static func dragContext(in text: String, itemAt location: Int) -> DragContext? {
        let doc = Document(text)
        let line = doc.lineIndex(containing: location)
        guard doc.lines.indices.contains(line), doc.lines[line].isItem,
              let group = doc.group(containing: line),
              let index = group.units.firstIndex(where: { $0.head == line })
        else { return nil }
        return DragContext(
            itemIndex: index,
            itemRanges: group.units.map { doc.range(ofLines: $0.head...$0.last) }
        )
    }

    /// Moves the item whose line contains `location` into drop slot `slot`
    /// (see `DragContext.slotLocations`). nil when the drop changes nothing.
    static func move(in text: String, itemAt location: Int, toSlot slot: Int, selection: NSRange) -> Edit? {
        let doc = Document(text)
        let line = doc.lineIndex(containing: location)
        guard doc.lines.indices.contains(line), doc.lines[line].isItem,
              let group = doc.group(containing: line),
              let index = group.units.firstIndex(where: { $0.head == line }),
              (0...group.units.count).contains(slot)
        else { return nil }
        return doc.edit(group: group, moving: index...index, toSlot: slot, selection: selection)
    }

    /// Which slot a drop at `location` (a character index under the
    /// pointer) lands in: the slot boundary nearest the pointer's line,
    /// halves decided by `fraction` — how far down that sibling's block the
    /// pointer sits, 0 at its top and 1 at its bottom.
    static func slot(forSibling sibling: Int, fraction: Double) -> Int {
        fraction < 0.5 ? sibling : sibling + 1
    }

    // MARK: - Model

    fileprivate struct Line {
        var text: String
        /// Location of the line's first character in the whole text.
        var start: Int
        /// Leading whitespace width, a tab counting as one indent unit.
        var indent: Int
        var isBlank: Bool
        var isItem: Bool
        var ordered: OrderedListItem?
    }

    /// An item and the deeper lines it owns, as inclusive line indices.
    fileprivate struct Unit: Equatable {
        var head: Int
        var last: Int
    }

    /// The siblings at one indent under one parent, top to bottom.
    fileprivate struct Group {
        var depth: Int
        var units: [Unit]
    }

    fileprivate struct Document {
        let text: NSString
        let lines: [Line]

        init(_ string: String) {
            text = string as NSString
            var lines: [Line] = []
            var start = 0
            for piece in string.components(separatedBy: "\n") {
                let length = (piece as NSString).length
                let isBlank = piece.trimmingCharacters(in: .whitespaces).isEmpty
                let ordered = OrderedList.item(in: piece)
                let isItem = !isBlank && (Checklist.item(in: piece) != nil
                    || ordered != nil
                    || Bullet.item(in: piece) != nil)
                lines.append(Line(
                    text: piece, start: start, indent: Self.indentWidth(of: piece),
                    isBlank: isBlank, isItem: isItem, ordered: ordered
                ))
                start += length + 1
            }
            self.lines = lines
        }

        static func indentWidth(of line: String) -> Int {
            var width = 0
            for char in line {
                if char == " " { width += 1 } else if char == "\t" { width += Checklist.indentUnit.count } else { break }
            }
            return width
        }

        func lineIndex(containing location: Int) -> Int {
            var index = 0
            for (i, line) in lines.enumerated() where line.start <= location { index = i }
            return index
        }

        func range(ofLines lines: ClosedRange<Int>) -> NSRange {
            let start = self.lines[lines.lowerBound].start
            let lastLine = self.lines[lines.upperBound]
            let end = lastLine.start + (lastLine.text as NSString).length
            return NSRange(location: start, length: end - start)
        }

        /// The last line `head` owns: everything below it indented deeper,
        /// up to a blank line.
        func unit(at head: Int) -> Unit {
            let depth = lines[head].indent
            var last = head
            while last + 1 < lines.count, !lines[last + 1].isBlank, lines[last + 1].indent > depth {
                last += 1
            }
            return Unit(head: head, last: last)
        }

        /// The sibling group of the item on line `head`.
        func group(containing head: Int) -> Group? {
            guard lines[head].isItem else { return nil }
            let depth = lines[head].indent
            // Walk up past deeper lines (earlier siblings' children) to the
            // topmost sibling.
            var top = head
            var k = head - 1
            while k >= 0 {
                let line = lines[k]
                if line.isBlank || line.indent < depth { break }
                if line.indent > depth { k -= 1; continue }
                guard line.isItem else { break }
                top = k
                k -= 1
            }
            var units: [Unit] = []
            var next = top
            while next < lines.count, lines[next].isItem, lines[next].indent == depth, !lines[next].isBlank {
                let unit = unit(at: next)
                units.append(unit)
                next = unit.last + 1
            }
            guard units.contains(where: { $0.head == head }) else { return nil }
            return Group(depth: depth, units: units)
        }

        /// The group and the contiguous run of its units the selection
        /// touches, or nil when the selection is not wholly inside one list.
        func selectedUnits(_ selection: NSRange) -> (Group, ClosedRange<Int>)? {
            guard !lines.isEmpty else { return nil }
            let first = lineIndex(containing: selection.location)
            let endLocation = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
            let lastLine = lineIndex(containing: endLocation)
            let touched = first...max(first, lastLine)
            guard touched.allSatisfy({ !lines[$0].isBlank }) else { return nil }
            let depth = touched.map { lines[$0].indent }.min() ?? 0

            // The first touched line at the shallowest indent, or the item a
            // deeper first line belongs to.
            var head = first
            while lines[head].indent > depth {
                guard head > 0, !lines[head - 1].isBlank else { return nil }
                head -= 1
            }
            // A continuation line (indented prose under an item) belongs to
            // the item above it.
            if !lines[head].isItem {
                var owner = head - 1
                while owner >= 0, !lines[owner].isBlank, lines[owner].indent >= lines[head].indent { owner -= 1 }
                guard owner >= 0, !lines[owner].isBlank, lines[owner].isItem else { return nil }
                head = owner
            }
            guard lines[head].isItem, let group = group(containing: head)
            else { return nil }

            let hits = group.units.indices.filter { i in
                let unit = group.units[i]
                return unit.last >= touched.lowerBound && unit.head <= touched.upperBound
            }
            guard let lo = hits.first, let hi = hits.last,
                  group.units[lo].head <= touched.lowerBound,
                  group.units[hi].last >= touched.upperBound
            else { return nil }
            return (group, lo...hi)
        }

        /// Whether every sibling is an ordered item numbered in sequence,
        /// and if so the first one's marker.
        func sequentialStart(of group: Group) -> OrderedMarkerKind? {
            var kinds: [OrderedMarkerKind] = []
            for unit in group.units {
                guard let ordered = lines[unit.head].ordered else { return nil }
                kinds.append(ordered.kind)
            }
            guard let first = kinds.first else { return nil }
            var expected: OrderedMarkerKind? = first
            for kind in kinds {
                guard kind == expected else { return nil }
                expected = kind.successor
            }
            return first
        }

        func edit(group: Group, moving moved: ClosedRange<Int>, toSlot slot: Int, selection: NSRange) -> Edit? {
            let count = group.units.count
            guard slot >= 0, slot <= count, slot < moved.lowerBound || slot > moved.upperBound + 1 else { return nil }

            // The new order of unit indices.
            var order = Array(0..<count).filter { !moved.contains($0) }
            let insertAt = slot < moved.lowerBound ? slot : slot - moved.count
            order.insert(contentsOf: Array(moved), at: insertAt)

            // Only units whose position changed need rewriting.
            let changed = order.indices.filter { order[$0] != $0 }
            guard let lo = changed.first, let hi = changed.last else { return nil }

            // Renumbered markers, by new position.
            var markers: [Int: String] = [:]
            if var kind = sequentialStart(of: group) {
                for position in 0..<count {
                    markers[position] = kind.text + "."
                    guard let next = kind.successor else { break }
                    kind = next
                }
            }

            // Build the replacement for units lo...hi in their new order,
            // remembering where every old line lands.
            let regionStart = lines[group.units[lo].head].start
            var newLines: [String] = []
            /// Old line index → (new start relative to region, marker delta,
            /// marker end in the old line).
            var placement: [Int: (start: Int, delta: Int, markerEnd: Int)] = [:]
            var offset = 0
            for position in lo...hi {
                let unit = group.units[order[position]]
                for index in unit.head...unit.last {
                    var text = lines[index].text
                    var delta = 0
                    var markerEnd = 0
                    if index == unit.head, let ordered = lines[index].ordered, let marker = markers[position] {
                        let ns = text as NSString
                        let oldMarker = ns.substring(with: ordered.markerRange)
                        if oldMarker != marker {
                            text = ns.replacingCharacters(in: ordered.markerRange, with: marker)
                            delta = (marker as NSString).length - ordered.markerRange.length
                        }
                        markerEnd = NSMaxRange(ordered.markerRange)
                    }
                    placement[index] = (offset, delta, markerEnd)
                    newLines.append(text)
                    offset += (text as NSString).length + 1
                }
            }
            let replacement = newLines.joined(separator: "\n")
            let oldRange = range(ofLines: group.units[lo].head...group.units[hi].last)
            let lengthDelta = (replacement as NSString).length - oldRange.length

            func map(_ location: Int) -> Int {
                if location < oldRange.location { return location }
                if location > NSMaxRange(oldRange) { return location + lengthDelta }
                let index = lineIndex(containing: location)
                guard let place = placement[index] else { return location }
                let column = location - lines[index].start
                let shifted = column > place.markerEnd ? column + place.delta : column
                return regionStart + place.start + shifted
            }
            let newLength = text.length + lengthDelta
            let start = min(map(selection.location), newLength)
            // The end maps with the character before it, so a selection that
            // takes in a line's newline keeps it rather than stretching to
            // whatever now follows.
            let mappedEnd = selection.length > 0 ? map(NSMaxRange(selection) - 1) + 1 : start
            let end = min(max(start, mappedEnd), newLength)
            return Edit(
                range: oldRange,
                replacement: replacement,
                selection: NSRange(location: start, length: end - start)
            )
        }
    }
}
