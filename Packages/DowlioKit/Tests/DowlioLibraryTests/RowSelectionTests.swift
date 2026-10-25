import DowlioCore
import DowlioLibrary
import Testing

/// Selecting downloads the way Finder selects files.
struct RowSelectionTests {
    private let ids = (0..<6).map { _ in DownloadID() }

    @Test func showingDownloadsSelectsExactlyThoseAndAShiftClickExtendsFromThem() {
        var selection = RowSelection()
        selection.click(ids[5], in: ids)
        selection.select([ids[1], ids[2]])
        #expect(selection.selected == [ids[1], ids[2]])
        selection.click(ids[4], in: ids, modifiers: .shift)
        #expect(selection.selected == Set(ids[2...4]))
    }

    @Test func aClickSelectsOnlyThatRow() {
        var selection = RowSelection()
        selection.click(ids[1], in: ids)
        selection.click(ids[3], in: ids)
        #expect(selection.selected == [ids[3]])
    }

    @Test func aCommandClickAddsOrRemovesOneRow() {
        var selection = RowSelection()
        selection.click(ids[1], in: ids)
        selection.click(ids[3], in: ids, modifiers: .command)
        #expect(selection.selected == [ids[1], ids[3]])
        selection.click(ids[1], in: ids, modifiers: .command)
        #expect(selection.selected == [ids[3]])
    }

    @Test func aShiftClickSelectsTheRangeFromTheLastClickedRow() {
        var selection = RowSelection()
        selection.click(ids[1], in: ids)
        selection.click(ids[4], in: ids, modifiers: .shift)
        #expect(selection.selected == Set(ids[1...4]))
        selection.click(ids[2], in: ids, modifiers: .shift)
        #expect(selection.selected == Set(ids[1...2]))
    }

    @Test func aShiftClickUpwardsWorksToo() {
        var selection = RowSelection()
        selection.click(ids[4], in: ids)
        selection.click(ids[1], in: ids, modifiers: .shift)
        #expect(selection.selected == Set(ids[1...4]))
    }

    @Test func aCommandShiftClickAddsTheRangeToWhatsSelected() {
        var selection = RowSelection()
        selection.click(ids[0], in: ids)
        selection.click(ids[3], in: ids, modifiers: .command)
        selection.click(ids[5], in: ids, modifiers: [.command, .shift])
        #expect(selection.selected == [ids[0], ids[3], ids[4], ids[5]])
    }

    @Test func selectAllTakesEveryRowShownAndClearEmptiesIt() {
        var selection = RowSelection()
        selection.selectAll(in: ids)
        #expect(selection.selected == Set(ids))
        selection.clear()
        #expect(selection.selected.isEmpty)
    }

    @Test func arrowsMoveTheSelectionAndShiftArrowsExtendIt() {
        var selection = RowSelection()
        selection.move(by: 1, in: ids)
        #expect(selection.selected == [ids[0]])
        selection.move(by: 1, in: ids)
        #expect(selection.selected == [ids[1]])
        selection.move(by: 1, in: ids, extending: true)
        selection.move(by: 1, in: ids, extending: true)
        #expect(selection.selected == Set(ids[1...3]))
        selection.move(by: -1, in: ids, extending: true)
        #expect(selection.selected == Set(ids[1...2]))
        selection.move(by: -5, in: ids)
        #expect(selection.selected == [ids[0]])
    }

    @Test func aDragRectangleSelectsTheRowsItTouches() {
        var selection = RowSelection()
        selection.click(ids[0], in: ids)
        selection.drag(over: [ids[2], ids[3]], adding: false)
        #expect(selection.selected == [ids[2], ids[3]])
        selection.drag(over: [ids[5]], adding: true, base: [ids[2], ids[3]])
        #expect(selection.selected == [ids[2], ids[3], ids[5]])
    }

    @Test func rowsThatLeaveTheListLeaveTheSelection() {
        var selection = RowSelection()
        selection.selectAll(in: ids)
        selection.keepOnly(Array(ids[2...3]))
        #expect(selection.selected == [ids[2], ids[3]])
    }

    @Test func aRightClickOnAnUnselectedRowSelectsJustThatRow() {
        var selection = RowSelection()
        selection.selectAll(in: Array(ids[0...2]))
        selection.prepareContextMenu(for: ids[1], in: ids)
        #expect(selection.selected == Set(ids[0...2]))
        selection.prepareContextMenu(for: ids[4], in: ids)
        #expect(selection.selected == [ids[4]])
    }
}
