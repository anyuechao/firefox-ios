/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import XCTest

private let LabelPrompt = "Turn on search suggestions?"
private let SuggestedSite = "foobar2000.org"

class SearchTests: BaseTestCase {
    var navigator: Navigator!
    var app: XCUIApplication!
    
    override func setUp() {
        super.setUp()
        app = XCUIApplication()
        navigator = createScreenGraph(app).navigator(self)
        dismissFirstRunUI()
    }
    
    override func tearDown() {
        super.tearDown()
    }
    
    private func suggestionsOnOff() {
        navigator.goto(SearchSettings)
        app.tables.switches["Show Search Suggestions"].tap()
        app.navigationBars["Search"].buttons["Settings"].tap()
        app.navigationBars["Settings"].buttons["AppSettingsTableViewController.navigationItem.leftBarButtonItem"].tap()
    }
    
    private func typeOnSearchBar(text: String) {
        app.textFields["url"].tap()
        app.textFields["address"].typeText(text)
    }
    
    func testPromptPresence() {
        // Suggestion is off by default, so the prompt should appear
        typeOnSearchBar(text: "foobar")
        waitforExistence(app.staticTexts[LabelPrompt])
        
        // No suggestions should be shown
        waitforNoExistence(app.tables["SiteTable"].buttons[SuggestedSite])
        
        // Enable Search suggestion
        app.buttons["Yes"].tap()
        
        // Suggestions should be shown
        waitforExistence(app.tables["SiteTable"].buttons[SuggestedSite])
        
        // Verify that previous choice is remembered
        app.buttons["Cancel"].tap()
        typeOnSearchBar(text: "foobar")
        waitforExistence(app.tables["SiteTable"].buttons[SuggestedSite])
        
        // Reset suggestion button, set it to off
        app.buttons["Cancel"].tap()
        suggestionsOnOff()
        typeOnSearchBar(text: "foobar")
        
        // Suggestions prompt should not appear
        waitforNoExistence(app.tables["SiteTable"].buttons[SuggestedSite])
    }
    
    func testDismissPromptPresence() {
        typeOnSearchBar(text: "foobar")
        waitforExistence(app.staticTexts[LabelPrompt])
        
        app.buttons["No"].tap()
        waitforNoExistence(app.tables["SiteTable"].buttons[SuggestedSite])
        
        // Verify that it is possible to enable suggestions after selecting No
        app.buttons["Cancel"].tap()
        suggestionsOnOff()
        typeOnSearchBar(text: "foobar")
        waitforExistence(app.tables["SiteTable"].buttons[SuggestedSite])
    }
    
    func testDoNotShowSuggestionsWhenEnteringURL() {
        // According to bug 1192155 if a string contains /, do not show suggestions, if there a space an a string, the suggestions are shown again
        typeOnSearchBar(text: "foobar")
        waitforExistence(app.staticTexts[LabelPrompt])
        
        // No suggestions should be shown
        waitforNoExistence(app.tables["SiteTable"].buttons[SuggestedSite])
        
        // Enable Search suggestion
        app.buttons["Yes"].tap()
        
        // Suggestions should be shown
        waitforExistence(app.tables["SiteTable"].buttons[SuggestedSite])
        
        // Typing / should stop showing suggestions
        app.textFields["address"].typeText("/")
        waitforNoExistence(app.tables["SiteTable"].buttons[SuggestedSite])
        
        // Typing space and char after / should show suggestions again
        app.textFields["address"].typeText(" b")
        waitforExistence(app.tables["SiteTable"].buttons["foobar burn cd"])
    }
    
    func testCopyPasteComplete() {
        // Copy, Paste and Go to url
        typeOnSearchBar(text: "www.mozilla.org")
        app.textFields["address"].press(forDuration: 5)
        app.menuItems["Select All"].tap()
        app.menuItems["Copy"].tap()
        
        app.buttons["Cancel"].tap()
        
        app.textFields["url"].tap()
        app.textFields["address"].tap()
        app.menuItems["Paste"].tap()
        
        // Verify that the Paste shows the search controller with prompt
        waitforExistence(app.staticTexts[LabelPrompt])
        app.typeText("\r")
        
        // Check that the website is loaded
        waitForValueContains(app.textFields["url"], value: "https://www.mozilla.org/")
        
        // Go back, write part of moz, check the autocompletion
        app.buttons["TabToolbar.backButton"].tap()
        typeOnSearchBar(text: "moz")
        
        waitForValueContains(app.textFields["address"], value: "mozilla.org")
        let value = app.textFields["address"].value
        XCTAssertEqual(value as? String, "mozilla.org/")
    }
    
    private func changeSearchEngine(searchEngine: String) {
        let tablesQuery2 = app.tables
        tablesQuery2.staticTexts[searchEngine].tap()
        
        app.navigationBars["Search"].buttons["Settings"].tap()
        app.navigationBars["Settings"].buttons["AppSettingsTableViewController.navigationItem.leftBarButtonItem"].tap()
        typeOnSearchBar(text: "foo\n")
        
        waitForValueContains(app.textFields["url"], value: searchEngine.lowercased())
        
        app.buttons["TabToolbar.backButton"].tap()
        app.buttons["TabToolbar.menuButton"].tap()
        app.collectionViews.cells["SettingsMenuItem"].tap()
        
        // Open menu to change the search engine
        app.tables["AppSettingsTableViewController.tableView"].staticTexts["Search"].tap()
        app.tables.staticTexts[searchEngine].tap()
    }
    
    func testSearchEngine() {
        // First time the menu to change the search engine is open
        navigator.goto(SearchSettings)

        // Check that the default search engine is yahoo
        XCTAssert(app.tables.staticTexts["Yahoo"].exists)
        app.tables.staticTexts["Yahoo"].tap()
        
        // Change to the each search engine and verify the search uses it
        changeSearchEngine(searchEngine: "Bing")
        changeSearchEngine(searchEngine: "DuckDuckGo")
        changeSearchEngine(searchEngine: "Google")
        changeSearchEngine(searchEngine: "Twitter")
        changeSearchEngine(searchEngine: "Wikipedia")
        changeSearchEngine(searchEngine: "Amazon.com")
        changeSearchEngine(searchEngine: "Yahoo")
    }
}
