//
//  SciEditorView.h
//  ScintillaEngine
//
//  Pure Objective-C public surface for the Scintilla + Lexilla editing engine.
//
//  IMPORTANT: This header is the SwiftPM `publicHeadersPath` for the target and
//  is therefore imported directly by Swift. It MUST remain pure Objective-C and
//  must NOT include any C++ or Scintilla headers — all of that lives in the
//  implementation (SciEditorView.mm) so the generated Clang module stays clean.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The syntax categories the host app themes. These map onto the app's
/// `SyntaxToken` cases; the bridge translates each into the concrete Scintilla
/// style numbers that the active Lexilla lexer uses.
typedef NS_ENUM(NSInteger, SciTokenKind) {
    SciTokenKeyword = 0,
    SciTokenType,
    SciTokenString,
    SciTokenComment,
    SciTokenNumber,
    SciTokenConstant,
    SciTokenAttribute,
    SciTokenTag,
    SciTokenKindCount
};

/// A self-contained AppKit view that embeds a Scintilla editor and drives it
/// with the Lexilla lexers. Drop it into an `NSViewRepresentable` to use from
/// SwiftUI. All interaction happens through this thin, Swift-friendly surface.
@interface SciEditorView : NSView

#pragma mark - Content

/// The full text of the editor. Setting this replaces the document and resets
/// the undo history / dirty state.
@property (nonatomic, copy) NSString *text;

/// Called on the main thread whenever the user edits the text (insert/delete).
@property (nonatomic, copy, nullable) void (^onTextChanged)(void);

/// Whether the document is editable by the user. Defaults to `YES`.
@property (nonatomic, assign, getter=isEditable) BOOL editable;

#pragma mark - Language / lexing

/// Selects a Lexilla lexer by its canonical name (e.g. `json`, `xml`, `cpp`,
/// `python`, `yaml`, `markdown`). Pass `nil` or an empty string for plain text.
/// Enabling a lexer also turns on code folding for that language.
- (void)setLexerLanguage:(nullable NSString *)lexerName;

#pragma mark - Appearance

/// Sets the base editor font (applied to the default style and propagated).
- (void)setFontName:(NSString *)name size:(CGFloat)size;

/// Enables or disables soft word wrapping.
- (void)setWordWrap:(BOOL)wrap;

/// Shows or hides the line-number margin.
- (void)setShowLineNumbers:(BOOL)show;

/// Sets the default foreground/background colors for the text area.
- (void)setEditorForeground:(NSColor *)foreground background:(NSColor *)background;

/// Sets the selection highlight background color.
- (void)setSelectionBackground:(NSColor *)color;

/// Sets the line-number margin (gutter) foreground/background colors.
- (void)setGutterForeground:(NSColor *)foreground background:(NSColor *)background;

/// Stores the color for a syntax-token category. Call `applyTokenColors` after
/// setting the categories you care about (and after any lexer change) to push
/// them onto the current language's Scintilla styles.
- (void)setTokenColor:(SciTokenKind)kind color:(NSColor *)color;

/// Maps the stored token colors onto the active lexer's style numbers.
- (void)applyTokenColors;

/// Reports caret line/column (1-based) and selection length whenever the
/// selection or content changes. Fired on the main thread.
@property (nonatomic, copy, nullable) void (^onSelectionChanged)(NSInteger line, NSInteger column, NSInteger selectionLength);

#pragma mark - Folding

/// Enables or disables the fold margin and automatic folding behavior.
- (void)setFoldingEnabled:(BOOL)enabled;

/// Themes the fold margin: `background` blends the margin with the editor while
/// `marker` colors the +/- fold boxes and connector lines.
- (void)setFoldColorsWithBackground:(NSColor *)background marker:(NSColor *)marker;

/// Collapses every foldable region in the document.
- (void)foldAll;

/// Expands every folded region in the document.
- (void)unfoldAll;

#pragma mark - Find & Replace

/// Moves the selection to the next/previous match, wrapping around. Returns the
/// 1-based ordinal of the match landed on, or 0 if there are no matches.
- (NSInteger)findText:(NSString *)query
        caseSensitive:(BOOL)caseSensitive
                regex:(BOOL)regex
            wholeWord:(BOOL)wholeWord
              forward:(BOOL)forward;

/// Total number of matches for the query without moving the selection.
- (NSInteger)matchCountFor:(NSString *)query
             caseSensitive:(BOOL)caseSensitive
                     regex:(BOOL)regex
                 wholeWord:(BOOL)wholeWord;

/// Replaces the current selection if it is exactly a match, then advances to
/// the next match. Returns whether a replacement was made. `regex` enables
/// backreferences (\1, \2 …) in the replacement.
- (BOOL)replaceCurrent:(NSString *)query
                  with:(NSString *)replacement
         caseSensitive:(BOOL)caseSensitive
                 regex:(BOOL)regex
             wholeWord:(BOOL)wholeWord;

/// Replaces every match in one undoable step. Returns the number replaced.
- (NSInteger)replaceAllOf:(NSString *)query
                     with:(NSString *)replacement
            caseSensitive:(BOOL)caseSensitive
                    regex:(BOOL)regex
                wholeWord:(BOOL)wholeWord;

#pragma mark - Document map

/// Shows or hides a Notepad++‑style document map (minimap): a zoomed‑out,
/// read‑only second view of the *same* document docked on the right edge, with
/// a translucent viewport slider you can click or drag to scroll the editor.
- (void)setDocumentMapVisible:(BOOL)visible;

/// Sets the fill color of the document map's viewport slider — typically a
/// translucent version of the theme's selection color. Call after theme changes.
- (void)setDocumentMapViewportColor:(NSColor *)color;

#pragma mark - Compare (side-by-side diff)

/// Sets the four line-background tints used by compare mode. The bridge draws
/// them translucently so syntax colors remain readable underneath.
- (void)setCompareColorsAdded:(NSColor *)added
                      deleted:(NSColor *)deleted
                      changed:(NSColor *)changed
                       filler:(NSColor *)filler;

/// Enters side-by-side compare mode. The caller supplies two already-aligned
/// sides (equal row counts; filler rows are blank). Every array has one entry
/// per row: `status` is 0=equal, 1=added, 2=deleted, 3=changed, 4=filler;
/// `numbers` is the original 1-based line number (0 for filler); `spanStart` /
/// `spanLength` mark an intra-line change range in UTF-8 bytes (0 length = none).
/// `lexer` colors both sides with the same language as the editor.
- (void)showCompareLeftText:(NSString *)leftText
                  rightText:(NSString *)rightText
                 leftStatus:(NSArray<NSNumber *> *)leftStatus
                rightStatus:(NSArray<NSNumber *> *)rightStatus
                leftNumbers:(NSArray<NSNumber *> *)leftNumbers
               rightNumbers:(NSArray<NSNumber *> *)rightNumbers
              leftSpanStart:(NSArray<NSNumber *> *)leftSpanStart
             leftSpanLength:(NSArray<NSNumber *> *)leftSpanLength
             rightSpanStart:(NSArray<NSNumber *> *)rightSpanStart
            rightSpanLength:(NSArray<NSNumber *> *)rightSpanLength
                      lexer:(nullable NSString *)lexer;

/// Leaves compare mode and restores the normal editor.
- (void)endCompare;

/// Whether compare mode is currently on screen.
@property (nonatomic, readonly, getter=isComparing) BOOL comparing;

/// Scrolls both panes to the next (`direction >= 0`) or previous change block,
/// wrapping around at the ends.
- (void)compareStep:(NSInteger)direction;

#pragma mark - View options

/// Highlights the line containing the caret with a translucent tint.
- (void)setCurrentLineHighlight:(BOOL)visible color:(NSColor *)color;

/// Shows faint vertical guides at each indentation level.
- (void)setIndentationGuidesVisible:(BOOL)visible;

/// Renders spaces as dots and tabs as arrows in the given color.
- (void)setWhitespaceVisible:(BOOL)visible color:(NSColor *)color;

/// Draws a vertical ruler line at `column`, in the given color.
- (void)setRulerColumn:(NSInteger)column visible:(BOOL)visible color:(NSColor *)color;

/// Shows a Git-style change-history gutter: a colored bar in the margin marking
/// lines that are modified (unsaved), saved, or reverted since the file opened.
- (void)setChangeHistoryVisible:(BOOL)visible;

/// Sets the tint used to highlight every occurrence of the selected word.
- (void)setOccurrenceHighlightColor:(NSColor *)color;

/// Sets the colors used to flag the matching (or unmatched) bracket at the caret.
- (void)setBraceColorsMatch:(NSColor *)match mismatch:(NSColor *)mismatch;

/// Sets the color of the bookmark markers in the margin.
- (void)setBookmarkColor:(NSColor *)color;

#pragma mark - Editing commands

/// Moves the selected line(s) up or down by one line.
- (void)moveSelectedLinesUp;
- (void)moveSelectedLinesDown;

/// Duplicates the current line (or selection).
- (void)duplicateSelection;

/// Deletes the line containing the caret.
- (void)deleteCurrentLine;

/// Toggles commenting on the selected lines using `linePrefix` (e.g. "//", "#"),
/// or wraps/unwraps the selection with `blockStart`/`blockEnd` when no line
/// prefix exists for the language. Pass nil for unavailable styles.
- (void)toggleCommentLinePrefix:(nullable NSString *)linePrefix
                     blockStart:(nullable NSString *)blockStart
                       blockEnd:(nullable NSString *)blockEnd;

/// Supplies the comment delimiters for the active language so the editor's
/// built-in right-click "Toggle Comment" item works. The host pushes these
/// whenever the language changes; same argument semantics as above.
- (void)setCommentLinePrefix:(nullable NSString *)linePrefix
                  blockStart:(nullable NSString *)blockStart
                    blockEnd:(nullable NSString *)blockEnd;

/// Multi-cursor: selects the word at the caret, or if a word is already
/// selected, adds the next occurrence as an additional selection (like ⌘D).
- (void)selectNextOccurrence;

/// Shows a word-completion popup built from the other words already in the file.
- (void)completeWord;

#pragma mark - Bookmarks

/// Toggles a bookmark on the caret's line.
- (void)toggleBookmark;

/// Jumps to the next / previous bookmarked line, wrapping around.
- (void)nextBookmark;
- (void)previousBookmark;

#pragma mark - Introspection

/// Returns the Scintilla version string the engine was built against, e.g. "5.6.3".
+ (NSString *)engineVersion;

@end

NS_ASSUME_NONNULL_END
