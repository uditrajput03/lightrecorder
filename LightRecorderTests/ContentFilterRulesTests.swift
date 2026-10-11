//
//  ContentFilterRulesTests.swift
//  LightRecorderTests
//
//  Created by Joshua Sattler on 30.08.26.
//

import XCTest
import CoreGraphics
@testable import LightRecorder

/// Tests for the pure window classification rules behind the content filters.
final class ContentFilterRulesTests: XCTestCase {

    // MARK: - Fixtures

    private static let ownBundleID = "com.lightrecorder.LightRecorder"

    private func visibility(
        wallpaper: Bool = true,
        dock: Bool = true,
        lightRecorder: Bool = true
    ) -> ContentVisibility {
        ContentVisibility(
            showWallpaper: wallpaper,
            showDock: dock,
            showLightRecorder: lightRecorder,
            ownBundleID: Self.ownBundleID
        )
    }

    private let wallpaper = CapturableWindow(id: 1, bundleID: "com.apple.dock", title: "Wallpaper-1")
    private let dock = CapturableWindow(id: 2, bundleID: "com.apple.dock", title: "Dock")
    private let backstop = CapturableWindow(id: 3, bundleID: "com.apple.WindowManager", title: "Backstop Window")
    private let ownWindow = CapturableWindow(id: 4, bundleID: ContentFilterRulesTests.ownBundleID, title: "LightRecorder")
    private let otherApp = CapturableWindow(id: 5, bundleID: "com.apple.Safari", title: "Safari")

    private var allWindows: [CapturableWindow] {
        [wallpaper, dock, backstop, ownWindow, otherApp]
    }

    private func excluded(_ visibility: ContentVisibility) -> Set<CGWindowID> {
        Set(ContentFilterRules.excludedWindowIDs(from: allWindows, visibility: visibility))
    }

    private func excepted(_ visibility: ContentVisibility) -> Set<CGWindowID> {
        Set(ContentFilterRules.dockExceptionWindowIDs(from: allWindows, visibility: visibility))
    }

    // MARK: - requiresRebuild

    func testRequiresNoRebuildWhenEverythingIsShown() {
        XCTAssertFalse(ContentFilterRules.requiresRebuild(visibility: visibility()))
    }

    func testRequiresRebuildWhenAnythingIsHidden() {
        let combinations = [
            (false, true, true),
            (true, false, true),
            (true, true, false),
            (false, false, false)
        ]
        for (wallpaper, dock, lightRecorder) in combinations {
            let hidden = visibility(wallpaper: wallpaper, dock: dock, lightRecorder: lightRecorder)
            XCTAssertTrue(ContentFilterRules.requiresRebuild(visibility: hidden))
        }
    }

    // MARK: - Display Capture

    func testDisplayExcludesNothingWhenEverythingIsShown() {
        XCTAssertTrue(excluded(visibility()).isEmpty)
    }

    func testDisplayExcludesWallpaperAndBackstopWhenWallpaperIsHidden() {
        XCTAssertEqual(excluded(visibility(wallpaper: false)), [wallpaper.id, backstop.id])
    }

    func testDisplayExcludesDockOnlyWhenDockIsHidden() {
        XCTAssertEqual(excluded(visibility(dock: false)), [dock.id])
    }

    func testDisplayExcludesOwnWindowsWhenLightRecorderIsHidden() {
        XCTAssertEqual(excluded(visibility(lightRecorder: false)), [ownWindow.id])
    }

    func testDisplayExcludesWallpaperAndDockTogether() {
        XCTAssertEqual(excluded(visibility(wallpaper: false, dock: false)), [wallpaper.id, dock.id, backstop.id])
    }

    func testDisplayExcludesWallpaperAndOwnWindows() {
        XCTAssertEqual(excluded(visibility(wallpaper: false, lightRecorder: false)), [wallpaper.id, backstop.id, ownWindow.id])
    }

    func testDisplayExcludesDockAndOwnWindows() {
        XCTAssertEqual(excluded(visibility(dock: false, lightRecorder: false)), [dock.id, ownWindow.id])
    }

    func testDisplayExcludesEverythingHidden() {
        let ids = excluded(visibility(wallpaper: false, dock: false, lightRecorder: false))
        XCTAssertEqual(ids, [wallpaper.id, dock.id, backstop.id, ownWindow.id])
    }

    func testDisplayNeverExcludesOtherApplications() {
        let ids = excluded(visibility(wallpaper: false, dock: false, lightRecorder: false))
        XCTAssertFalse(ids.contains(otherApp.id))
    }

    // MARK: - Backstop

    func testBackstopIsExcludedRegardlessOfOwner() {
        let windows = [
            CapturableWindow(id: 10, bundleID: "com.apple.dock", title: "Backstop"),
            CapturableWindow(id: 11, bundleID: "com.apple.WindowServer", title: "Backstop"),
            CapturableWindow(id: 12, bundleID: "", title: "Some Backstop Layer")
        ]

        let ids = ContentFilterRules.excludedWindowIDs(from: windows, visibility: visibility(wallpaper: false))
        XCTAssertEqual(Set(ids), [10, 11, 12])
    }

    func testBackstopIsKeptWhenWallpaperIsShown() {
        let ids = ContentFilterRules.excludedWindowIDs(from: [backstop], visibility: visibility(dock: false))
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - Wallpaper vs. Dock Split

    func testDockOwnedWindowsAreSplitByTitlePrefix() {
        let windows = [
            CapturableWindow(id: 20, bundleID: "com.apple.dock", title: "Wallpaper-2"),
            CapturableWindow(id: 21, bundleID: "com.apple.dock", title: "Dock")
        ]

        XCTAssertEqual(ContentFilterRules.excludedWindowIDs(from: windows, visibility: visibility(wallpaper: false)), [20])
        XCTAssertEqual(ContentFilterRules.excludedWindowIDs(from: windows, visibility: visibility(dock: false)), [21])
    }

    // MARK: - Application Capture

    func testApplicationIncludesDockWhenAnySurfaceIsShown() {
        XCTAssertTrue(ContentFilterRules.includesDockApplication(visibility: visibility()))
        XCTAssertTrue(ContentFilterRules.includesDockApplication(visibility: visibility(wallpaper: false)))
        XCTAssertTrue(ContentFilterRules.includesDockApplication(visibility: visibility(dock: false)))
    }

    func testApplicationOmitsDockWhenBothSurfacesAreHidden() {
        let onBlack = visibility(wallpaper: false, dock: false)
        XCTAssertFalse(ContentFilterRules.includesDockApplication(visibility: onBlack))
        XCTAssertTrue(excepted(onBlack).isEmpty)
    }

    func testApplicationExceptsNothingWhenEverythingIsShown() {
        XCTAssertTrue(excepted(visibility()).isEmpty)
    }

    func testApplicationExceptsWallpaperAndBackstopWhenWallpaperIsHidden() {
        XCTAssertEqual(excepted(visibility(wallpaper: false)), [wallpaper.id, backstop.id])
    }

    func testApplicationExceptsDockOnlyWhenDockIsHidden() {
        XCTAssertEqual(excepted(visibility(dock: false)), [dock.id])
    }

    /// `showLightRecorder` is a display-capture concern: the picker excludes LightRecorder
    /// from application selections, so it never reaches the exception list.
    func testApplicationIgnoresLightRecorderVisibility() {
        XCTAssertTrue(excepted(visibility(lightRecorder: false)).isEmpty)
        XCTAssertEqual(excepted(visibility(wallpaper: false, lightRecorder: false)), [wallpaper.id, backstop.id])
        XCTAssertEqual(excepted(visibility(dock: false, lightRecorder: false)), [dock.id])
    }

    func testApplicationNeverExceptsTheCapturedApplication() {
        let ids = excepted(visibility(wallpaper: false))
        XCTAssertFalse(ids.contains(otherApp.id))
    }
}
