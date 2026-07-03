//
//  SciEditorView.mm
//  ScintillaEngine
//
//  Objective-C++ bridge that wraps Scintilla's Cocoa view and the Lexilla
//  lexers behind the pure-Objective-C `SciEditorView` surface declared in
//  SciEditorView.h. All C++ / Scintilla details are confined to this file.
//

#import "SciEditorView.h"

// Scintilla Cocoa view (also pulls in <Cocoa/Cocoa.h> and the C API Scintilla.h).
#import "ScintillaView.h"

// Lexilla static lexer factory. ILexer.h must be included before Lexilla.h so
// that `Scintilla::ILexer5` is defined for its `using` declaration.
#import "ILexer.h"
#import "Lexilla.h"

// Per-language style numbers (SCE_*) used for syntax colouring.
#import "SciLexer.h"

#pragma mark - Helpers

/// Converts an NSColor to Scintilla's 0xBBGGRR packed integer format.
static sptr_t SciColourFromNSColor(NSColor *color) {
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (rgb == nil) {
        rgb = color;
    }
    const int r = (int)lround(rgb.redComponent * 255.0);
    const int g = (int)lround(rgb.greenComponent * 255.0);
    const int b = (int)lround(rgb.blueComponent * 255.0);
    return (sptr_t)(r | (g << 8) | (b << 16));
}

/// A top-left-origin container so document-map line math reads naturally
/// (y increases downward, matching Scintilla's line ordering).
@interface SciFlippedView : NSView
@end

@implementation SciFlippedView
- (BOOL)isFlipped { return YES; }
@end

// Compare-mode marker slots (used only on the dedicated compare panes) and the
// intra-line change indicator number.
enum {
    kCmpMarkAdded = 0,
    kCmpMarkDeleted = 1,
    kCmpMarkChanged = 2,
    kCmpMarkFiller = 3
};
static const int kCmpIndic = 8;

@class SciEditorView;

/// A tiny notification delegate for a secondary Scintilla view (a compare pane)
/// so the owning SciEditorView can tell which pane sent a scroll event.
@interface SciViewObserver : NSObject <ScintillaNotificationProtocol>
@property (nonatomic, weak) SciEditorView *owner;
@property (nonatomic, assign) NSInteger tag;
@end

#pragma mark - SciEditorView

@interface SciEditorView () <ScintillaNotificationProtocol>
// Private document-map helpers (implemented in the "Document map" section).
- (void)sci_setupMap;
- (void)syncMapStyling;
- (void)applyTokenColorsBody;
- (void)sci_layoutSubviews;
- (void)refreshMapViewport;
// Private compare helper (implemented in the "Compare" section).
- (void)sci_compareNotification:(SCNotification *)notification fromTag:(NSInteger)tag;
@end

@implementation SciEditorView {
    ScintillaView *_scintilla;
    BOOL _foldingEnabled;
    BOOL _loading;
    NSString *_currentLexer;
    sptr_t _tokenColor[SciTokenKindCount];
    BOOL _hasTokenColor[SciTokenKindCount];

    // Document map (minimap): a second view sharing _scintilla's document.
    ScintillaView *_styleTarget;      // receiver for token-colour styling
    ScintillaView *_map;              // minimap view; nil until first shown
    SciFlippedView *_mapContainer;    // docks the map on the right edge
    SciFlippedView *_mapOverlay;      // transparent; hosts gestures + slider
    NSView *_mapHighlight;            // the "you are here" viewport slider
    NSColor *_mapViewportColor;
    BOOL _documentMapVisible;
    CGFloat _mapWidth;

    // Cached appearance so the map can mirror the editor's styling.
    NSString *_baseFontName;
    CGFloat _baseFontSize;
    sptr_t _editorFore;
    sptr_t _editorBack;
    BOOL _hasEditorColors;

    // Gutter colours cached so the compare panes match the editor.
    sptr_t _gutterFore;
    sptr_t _gutterBack;
    BOOL _hasGutterColors;

    // Compare (side-by-side diff) mode.
    BOOL _comparing;
    ScintillaView *_cmpLeft;
    ScintillaView *_cmpRight;
    SciFlippedView *_cmpContainer;
    NSView *_cmpDivider;
    SciViewObserver *_cmpLeftObs;
    SciViewObserver *_cmpRightObs;
    BOOL _syncingCompare;
    NSArray<NSNumber *> *_cmpBlockStarts;
    sptr_t _cmpAdded, _cmpDeleted, _cmpChanged, _cmpFiller;
    BOOL _hasCompareColors;
}

#pragma mark Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self sci_setup];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self sci_setup];
    }
    return self;
}

- (void)sci_setup {
    _scintilla = [[ScintillaView alloc] initWithFrame:self.bounds];
    _scintilla.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scintilla.delegate = self;
    [self addSubview:_scintilla];

    // UTF-8 documents.
    [self sci_message:SCI_SETCODEPAGE wparam:SC_CP_UTF8 lparam:0];

    // Sensible editing defaults.
    [self sci_message:SCI_SETTABWIDTH wparam:4 lparam:0];
    [self sci_message:SCI_SETUSETABS wparam:0 lparam:0];

    // Default margins: line numbers on, folding on.
    [self setShowLineNumbers:YES];
    [self setFoldingEnabled:YES];

    _scintilla.editable = YES;

    // Document-map defaults (the map view itself is created lazily on show).
    _mapWidth = 128.0;
    _baseFontName = @"Menlo";
    _baseFontSize = 12.0;
}

#pragma mark Raw message plumbing

- (sptr_t)sci_message:(unsigned int)message wparam:(uptr_t)wparam lparam:(sptr_t)lparam {
    return [_scintilla message:message wParam:wparam lParam:lparam];
}

- (void)sci_setProperty:(const char *)key value:(const char *)value {
    [_scintilla message:SCI_SETPROPERTY wParam:(uptr_t)key lParam:(sptr_t)value];
}

#pragma mark Content

- (NSString *)text {
    return [_scintilla string] ?: @"";
}

- (void)setText:(NSString *)text {
    _loading = YES;
    [_scintilla setString:(text ?: @"")];
    // A freshly loaded document is clean with no undo history.
    [self sci_message:SCI_EMPTYUNDOBUFFER wparam:0 lparam:0];
    [self sci_message:SCI_SETSAVEPOINT wparam:0 lparam:0];
    if (_foldingEnabled) {
        [self sci_message:SCI_COLOURISE wparam:0 lparam:-1];
    }
    _loading = NO;
    if (_documentMapVisible) {
        [self refreshMapViewport];
    }
}

- (BOOL)isEditable {
    return [_scintilla isEditable];
}

- (void)setEditable:(BOOL)editable {
    [_scintilla setEditable:editable];
}

#pragma mark Language / lexing

- (void)setLexerLanguage:(NSString *)lexerName {
    _currentLexer = lexerName.length ? [lexerName copy] : nil;

    if (lexerName.length == 0) {
        [self sci_message:SCI_SETILEXER wparam:0 lparam:0];
        return;
    }

    void *lexer = (void *)CreateLexer([lexerName UTF8String]);
    [self sci_message:SCI_SETILEXER wparam:0 lparam:(sptr_t)lexer];

    // Turn on folding for languages that support it.
    [self sci_setProperty:"fold" value:"1"];
    [self sci_setProperty:"fold.compact" value:"0"];
    [self sci_setProperty:"fold.comment" value:"1"];
    [self sci_setProperty:"fold.html" value:"1"];
    [self sci_setProperty:"fold.hypertext.comment" value:"1"];

    // Re-apply syntax colours for the new language, then re-lex the document.
    [self applyTokenColors];
    [self sci_message:SCI_COLOURISE wparam:0 lparam:-1];
}

#pragma mark Appearance

- (void)setFontName:(NSString *)name size:(CGFloat)size {
    _baseFontName = [name copy];
    _baseFontSize = size;
    [_scintilla message:SCI_STYLESETFONT wParam:STYLE_DEFAULT lParam:(sptr_t)[name UTF8String]];
    [self sci_message:SCI_STYLESETSIZE wparam:STYLE_DEFAULT lparam:(sptr_t)lround(size)];
    // Propagate the default style to every style slot.
    [self sci_message:SCI_STYLECLEARALL wparam:0 lparam:0];
    [self syncMapStyling];
}

- (void)setWordWrap:(BOOL)wrap {
    [self sci_message:SCI_SETWRAPMODE wparam:(uptr_t)(wrap ? SC_WRAP_WORD : SC_WRAP_NONE) lparam:0];
}

- (void)setShowLineNumbers:(BOOL)show {
    const int lineNumberMargin = 0;
    [self sci_message:SCI_SETMARGINTYPEN wparam:lineNumberMargin lparam:SC_MARGIN_NUMBER];
    [self sci_message:SCI_SETMARGINWIDTHN wparam:lineNumberMargin lparam:(show ? 48 : 0)];
}

- (void)setEditorForeground:(NSColor *)foreground background:(NSColor *)background {
    const sptr_t fore = SciColourFromNSColor(foreground);
    const sptr_t back = SciColourFromNSColor(background);
    _editorFore = fore;
    _editorBack = back;
    _hasEditorColors = YES;
    [self sci_message:SCI_STYLESETFORE wparam:STYLE_DEFAULT lparam:fore];
    [self sci_message:SCI_STYLESETBACK wparam:STYLE_DEFAULT lparam:back];
    [self sci_message:SCI_STYLECLEARALL wparam:0 lparam:0];
    // Keep the caret readable against the chosen background.
    [self sci_message:SCI_SETCARETFORE wparam:(uptr_t)fore lparam:0];
    [self syncMapStyling];
}

- (void)setSelectionBackground:(NSColor *)color {
    [self sci_message:SCI_SETSELBACK wparam:1 lparam:SciColourFromNSColor(color)];
}

- (void)setGutterForeground:(NSColor *)foreground background:(NSColor *)background {
    _gutterFore = SciColourFromNSColor(foreground);
    _gutterBack = SciColourFromNSColor(background);
    _hasGutterColors = YES;
    [self sci_message:SCI_STYLESETFORE wparam:STYLE_LINENUMBER lparam:_gutterFore];
    [self sci_message:SCI_STYLESETBACK wparam:STYLE_LINENUMBER lparam:_gutterBack];
}

#pragma mark Syntax colouring

- (void)setTokenColor:(SciTokenKind)kind color:(NSColor *)color {
    if (kind < 0 || kind >= SciTokenKindCount) {
        return;
    }
    _tokenColor[kind] = SciColourFromNSColor(color);
    _hasTokenColor[kind] = YES;
}

/// Colours a single Scintilla style number with the stored colour for `kind`,
/// on whichever view is the current style target (the editor or the map).
- (void)sci_style:(int)style kind:(SciTokenKind)kind {
    if (kind < 0 || kind >= SciTokenKindCount || !_hasTokenColor[kind]) {
        return;
    }
    ScintillaView *target = _styleTarget ?: _scintilla;
    [target message:SCI_STYLESETFORE wParam:(uptr_t)style lParam:_tokenColor[kind]];
}

- (void)applyTokenColors {
    _styleTarget = _scintilla;
    [self applyTokenColorsBody];
    if (_map != nil) {
        _styleTarget = _map;
        [self applyTokenColorsBody];
    }
    _styleTarget = nil;
}

/// Applies the per-language SCE_* -> token-colour mapping to `_styleTarget`.
- (void)applyTokenColorsBody {
    NSString *lex = _currentLexer;
    if (lex.length == 0) {
        return;
    }

    if ([lex isEqualToString:@"json"]) {
        [self sci_style:SCE_JSON_NUMBER kind:SciTokenNumber];
        [self sci_style:SCE_JSON_STRING kind:SciTokenString];
        [self sci_style:SCE_JSON_STRINGEOL kind:SciTokenString];
        [self sci_style:SCE_JSON_PROPERTYNAME kind:SciTokenAttribute];
        [self sci_style:SCE_JSON_ESCAPESEQUENCE kind:SciTokenConstant];
        [self sci_style:SCE_JSON_LINECOMMENT kind:SciTokenComment];
        [self sci_style:SCE_JSON_BLOCKCOMMENT kind:SciTokenComment];
        [self sci_style:SCE_JSON_KEYWORD kind:SciTokenKeyword];
        [self sci_style:SCE_JSON_LDKEYWORD kind:SciTokenKeyword];
        [self sci_style:SCE_JSON_URI kind:SciTokenConstant];
    } else if ([lex isEqualToString:@"xml"] || [lex isEqualToString:@"hypertext"]) {
        [self sci_style:SCE_H_TAG kind:SciTokenTag];
        [self sci_style:SCE_H_TAGUNKNOWN kind:SciTokenTag];
        [self sci_style:SCE_H_TAGEND kind:SciTokenTag];
        [self sci_style:SCE_H_XMLSTART kind:SciTokenKeyword];
        [self sci_style:SCE_H_XMLEND kind:SciTokenKeyword];
        [self sci_style:SCE_H_QUESTION kind:SciTokenKeyword];
        [self sci_style:SCE_H_ATTRIBUTE kind:SciTokenAttribute];
        [self sci_style:SCE_H_ATTRIBUTEUNKNOWN kind:SciTokenAttribute];
        [self sci_style:SCE_H_NUMBER kind:SciTokenNumber];
        [self sci_style:SCE_H_DOUBLESTRING kind:SciTokenString];
        [self sci_style:SCE_H_SINGLESTRING kind:SciTokenString];
        [self sci_style:SCE_H_VALUE kind:SciTokenString];
        [self sci_style:SCE_H_COMMENT kind:SciTokenComment];
        [self sci_style:SCE_H_ENTITY kind:SciTokenConstant];
        [self sci_style:SCE_H_CDATA kind:SciTokenConstant];
        [self sci_style:SCE_H_SGML_DEFAULT kind:SciTokenKeyword];
        [self sci_style:SCE_H_SGML_COMMAND kind:SciTokenKeyword];
        [self sci_style:SCE_H_SGML_DOUBLESTRING kind:SciTokenString];
        [self sci_style:SCE_H_SGML_SIMPLESTRING kind:SciTokenString];
        [self sci_style:SCE_H_SGML_COMMENT kind:SciTokenComment];
    } else if ([lex isEqualToString:@"cpp"]) {
        [self sci_style:SCE_C_WORD kind:SciTokenKeyword];
        [self sci_style:SCE_C_WORD2 kind:SciTokenType];
        [self sci_style:SCE_C_GLOBALCLASS kind:SciTokenType];
        [self sci_style:SCE_C_NUMBER kind:SciTokenNumber];
        [self sci_style:SCE_C_STRING kind:SciTokenString];
        [self sci_style:SCE_C_CHARACTER kind:SciTokenString];
        [self sci_style:SCE_C_VERBATIM kind:SciTokenString];
        [self sci_style:SCE_C_STRINGRAW kind:SciTokenString];
        [self sci_style:SCE_C_TRIPLEVERBATIM kind:SciTokenString];
        [self sci_style:SCE_C_HASHQUOTEDSTRING kind:SciTokenString];
        [self sci_style:SCE_C_REGEX kind:SciTokenString];
        [self sci_style:SCE_C_COMMENT kind:SciTokenComment];
        [self sci_style:SCE_C_COMMENTLINE kind:SciTokenComment];
        [self sci_style:SCE_C_COMMENTDOC kind:SciTokenComment];
        [self sci_style:SCE_C_COMMENTLINEDOC kind:SciTokenComment];
        [self sci_style:SCE_C_COMMENTDOCKEYWORD kind:SciTokenComment];
        [self sci_style:SCE_C_PREPROCESSOR kind:SciTokenConstant];
        [self sci_style:SCE_C_ESCAPESEQUENCE kind:SciTokenConstant];
    } else if ([lex isEqualToString:@"python"]) {
        [self sci_style:SCE_P_WORD kind:SciTokenKeyword];
        [self sci_style:SCE_P_WORD2 kind:SciTokenType];
        [self sci_style:SCE_P_CLASSNAME kind:SciTokenType];
        [self sci_style:SCE_P_DEFNAME kind:SciTokenType];
        [self sci_style:SCE_P_NUMBER kind:SciTokenNumber];
        [self sci_style:SCE_P_STRING kind:SciTokenString];
        [self sci_style:SCE_P_CHARACTER kind:SciTokenString];
        [self sci_style:SCE_P_TRIPLE kind:SciTokenString];
        [self sci_style:SCE_P_TRIPLEDOUBLE kind:SciTokenString];
        [self sci_style:SCE_P_FSTRING kind:SciTokenString];
        [self sci_style:SCE_P_FCHARACTER kind:SciTokenString];
        [self sci_style:SCE_P_FTRIPLE kind:SciTokenString];
        [self sci_style:SCE_P_FTRIPLEDOUBLE kind:SciTokenString];
        [self sci_style:SCE_P_COMMENTLINE kind:SciTokenComment];
        [self sci_style:SCE_P_COMMENTBLOCK kind:SciTokenComment];
        [self sci_style:SCE_P_DECORATOR kind:SciTokenAttribute];
    } else if ([lex isEqualToString:@"yaml"]) {
        [self sci_style:SCE_YAML_KEYWORD kind:SciTokenKeyword];
        [self sci_style:SCE_YAML_DOCUMENT kind:SciTokenKeyword];
        [self sci_style:SCE_YAML_IDENTIFIER kind:SciTokenAttribute];
        [self sci_style:SCE_YAML_NUMBER kind:SciTokenNumber];
        [self sci_style:SCE_YAML_REFERENCE kind:SciTokenConstant];
        [self sci_style:SCE_YAML_COMMENT kind:SciTokenComment];
        [self sci_style:SCE_YAML_TEXT kind:SciTokenString];
    } else if ([lex isEqualToString:@"css"]) {
        [self sci_style:SCE_CSS_TAG kind:SciTokenTag];
        [self sci_style:SCE_CSS_CLASS kind:SciTokenType];
        [self sci_style:SCE_CSS_ID kind:SciTokenType];
        [self sci_style:SCE_CSS_PSEUDOCLASS kind:SciTokenConstant];
        [self sci_style:SCE_CSS_PSEUDOELEMENT kind:SciTokenConstant];
        [self sci_style:SCE_CSS_IDENTIFIER kind:SciTokenAttribute];
        [self sci_style:SCE_CSS_IDENTIFIER2 kind:SciTokenAttribute];
        [self sci_style:SCE_CSS_IDENTIFIER3 kind:SciTokenAttribute];
        [self sci_style:SCE_CSS_ATTRIBUTE kind:SciTokenAttribute];
        [self sci_style:SCE_CSS_VALUE kind:SciTokenString];
        [self sci_style:SCE_CSS_DOUBLESTRING kind:SciTokenString];
        [self sci_style:SCE_CSS_SINGLESTRING kind:SciTokenString];
        [self sci_style:SCE_CSS_COMMENT kind:SciTokenComment];
        [self sci_style:SCE_CSS_IMPORTANT kind:SciTokenKeyword];
        [self sci_style:SCE_CSS_DIRECTIVE kind:SciTokenKeyword];
        [self sci_style:SCE_CSS_VARIABLE kind:SciTokenConstant];
    } else if ([lex isEqualToString:@"markdown"]) {
        [self sci_style:SCE_MARKDOWN_HEADER1 kind:SciTokenTag];
        [self sci_style:SCE_MARKDOWN_HEADER2 kind:SciTokenTag];
        [self sci_style:SCE_MARKDOWN_HEADER3 kind:SciTokenTag];
        [self sci_style:SCE_MARKDOWN_HEADER4 kind:SciTokenTag];
        [self sci_style:SCE_MARKDOWN_HEADER5 kind:SciTokenTag];
        [self sci_style:SCE_MARKDOWN_HEADER6 kind:SciTokenTag];
        [self sci_style:SCE_MARKDOWN_STRONG1 kind:SciTokenKeyword];
        [self sci_style:SCE_MARKDOWN_STRONG2 kind:SciTokenKeyword];
        [self sci_style:SCE_MARKDOWN_EM1 kind:SciTokenType];
        [self sci_style:SCE_MARKDOWN_EM2 kind:SciTokenType];
        [self sci_style:SCE_MARKDOWN_CODE kind:SciTokenString];
        [self sci_style:SCE_MARKDOWN_CODE2 kind:SciTokenString];
        [self sci_style:SCE_MARKDOWN_CODEBK kind:SciTokenString];
        [self sci_style:SCE_MARKDOWN_LINK kind:SciTokenConstant];
        [self sci_style:SCE_MARKDOWN_ULIST_ITEM kind:SciTokenAttribute];
        [self sci_style:SCE_MARKDOWN_OLIST_ITEM kind:SciTokenAttribute];
        [self sci_style:SCE_MARKDOWN_BLOCKQUOTE kind:SciTokenComment];
        [self sci_style:SCE_MARKDOWN_HRULE kind:SciTokenComment];
    } else if ([lex isEqualToString:@"bash"]) {
        [self sci_style:SCE_SH_WORD kind:SciTokenKeyword];
        [self sci_style:SCE_SH_NUMBER kind:SciTokenNumber];
        [self sci_style:SCE_SH_STRING kind:SciTokenString];
        [self sci_style:SCE_SH_CHARACTER kind:SciTokenString];
        [self sci_style:SCE_SH_BACKTICKS kind:SciTokenString];
        [self sci_style:SCE_SH_COMMENTLINE kind:SciTokenComment];
        [self sci_style:SCE_SH_SCALAR kind:SciTokenConstant];
        [self sci_style:SCE_SH_PARAM kind:SciTokenConstant];
    } else if ([lex isEqualToString:@"sql"]) {
        [self sci_style:SCE_SQL_WORD kind:SciTokenKeyword];
        [self sci_style:SCE_SQL_WORD2 kind:SciTokenType];
        [self sci_style:SCE_SQL_NUMBER kind:SciTokenNumber];
        [self sci_style:SCE_SQL_STRING kind:SciTokenString];
        [self sci_style:SCE_SQL_CHARACTER kind:SciTokenString];
        [self sci_style:SCE_SQL_QUOTEDIDENTIFIER kind:SciTokenAttribute];
        [self sci_style:SCE_SQL_COMMENT kind:SciTokenComment];
        [self sci_style:SCE_SQL_COMMENTLINE kind:SciTokenComment];
        [self sci_style:SCE_SQL_COMMENTDOC kind:SciTokenComment];
        [self sci_style:SCE_SQL_COMMENTLINEDOC kind:SciTokenComment];
    } else if ([lex isEqualToString:@"ruby"]) {
        [self sci_style:SCE_RB_WORD kind:SciTokenKeyword];
        [self sci_style:SCE_RB_WORD_DEMOTED kind:SciTokenKeyword];
        [self sci_style:SCE_RB_CLASSNAME kind:SciTokenType];
        [self sci_style:SCE_RB_DEFNAME kind:SciTokenType];
        [self sci_style:SCE_RB_MODULE_NAME kind:SciTokenType];
        [self sci_style:SCE_RB_NUMBER kind:SciTokenNumber];
        [self sci_style:SCE_RB_STRING kind:SciTokenString];
        [self sci_style:SCE_RB_CHARACTER kind:SciTokenString];
        [self sci_style:SCE_RB_STRING_Q kind:SciTokenString];
        [self sci_style:SCE_RB_STRING_QQ kind:SciTokenString];
        [self sci_style:SCE_RB_BACKTICKS kind:SciTokenString];
        [self sci_style:SCE_RB_REGEX kind:SciTokenString];
        [self sci_style:SCE_RB_COMMENTLINE kind:SciTokenComment];
        [self sci_style:SCE_RB_POD kind:SciTokenComment];
        [self sci_style:SCE_RB_SYMBOL kind:SciTokenConstant];
        [self sci_style:SCE_RB_GLOBAL kind:SciTokenConstant];
        [self sci_style:SCE_RB_INSTANCE_VAR kind:SciTokenAttribute];
        [self sci_style:SCE_RB_CLASS_VAR kind:SciTokenAttribute];
    } else if ([lex isEqualToString:@"rust"]) {
        [self sci_style:SCE_RUST_WORD kind:SciTokenKeyword];
        [self sci_style:SCE_RUST_WORD2 kind:SciTokenKeyword];
        [self sci_style:SCE_RUST_WORD3 kind:SciTokenType];
        [self sci_style:SCE_RUST_WORD4 kind:SciTokenType];
        [self sci_style:SCE_RUST_NUMBER kind:SciTokenNumber];
        [self sci_style:SCE_RUST_STRING kind:SciTokenString];
        [self sci_style:SCE_RUST_STRINGR kind:SciTokenString];
        [self sci_style:SCE_RUST_CHARACTER kind:SciTokenString];
        [self sci_style:SCE_RUST_COMMENTBLOCK kind:SciTokenComment];
        [self sci_style:SCE_RUST_COMMENTLINE kind:SciTokenComment];
        [self sci_style:SCE_RUST_COMMENTBLOCKDOC kind:SciTokenComment];
        [self sci_style:SCE_RUST_COMMENTLINEDOC kind:SciTokenComment];
        [self sci_style:SCE_RUST_MACRO kind:SciTokenConstant];
        [self sci_style:SCE_RUST_LIFETIME kind:SciTokenAttribute];
    } else if ([lex isEqualToString:@"props"]) {
        [self sci_style:SCE_PROPS_SECTION kind:SciTokenTag];
        [self sci_style:SCE_PROPS_KEY kind:SciTokenAttribute];
        [self sci_style:SCE_PROPS_ASSIGNMENT kind:SciTokenConstant];
        [self sci_style:SCE_PROPS_DEFVAL kind:SciTokenString];
        [self sci_style:SCE_PROPS_COMMENT kind:SciTokenComment];
    } else if ([lex isEqualToString:@"toml"]) {
        [self sci_style:SCE_TOML_KEYWORD kind:SciTokenKeyword];
        [self sci_style:SCE_TOML_TABLE kind:SciTokenTag];
        [self sci_style:SCE_TOML_KEY kind:SciTokenAttribute];
        [self sci_style:SCE_TOML_IDENTIFIER kind:SciTokenAttribute];
        [self sci_style:SCE_TOML_NUMBER kind:SciTokenNumber];
        [self sci_style:SCE_TOML_STRING_SQ kind:SciTokenString];
        [self sci_style:SCE_TOML_STRING_DQ kind:SciTokenString];
        [self sci_style:SCE_TOML_TRIPLE_STRING_SQ kind:SciTokenString];
        [self sci_style:SCE_TOML_TRIPLE_STRING_DQ kind:SciTokenString];
        [self sci_style:SCE_TOML_DATETIME kind:SciTokenConstant];
        [self sci_style:SCE_TOML_ESCAPECHAR kind:SciTokenConstant];
        [self sci_style:SCE_TOML_COMMENT kind:SciTokenComment];
    }
}

#pragma mark Folding

- (void)setFoldingEnabled:(BOOL)enabled {
    _foldingEnabled = enabled;
    const int foldMargin = 2;

    if (!enabled) {
        [self sci_message:SCI_SETMARGINWIDTHN wparam:foldMargin lparam:0];
        [self sci_setProperty:"fold" value:"0"];
        return;
    }

    // Box-tree fold markers.
    [self sci_defineFoldMarker:SC_MARKNUM_FOLDEROPEN symbol:SC_MARK_BOXMINUS];
    [self sci_defineFoldMarker:SC_MARKNUM_FOLDER symbol:SC_MARK_BOXPLUS];
    [self sci_defineFoldMarker:SC_MARKNUM_FOLDERSUB symbol:SC_MARK_VLINE];
    [self sci_defineFoldMarker:SC_MARKNUM_FOLDERTAIL symbol:SC_MARK_LCORNER];
    [self sci_defineFoldMarker:SC_MARKNUM_FOLDEREND symbol:SC_MARK_BOXPLUSCONNECTED];
    [self sci_defineFoldMarker:SC_MARKNUM_FOLDEROPENMID symbol:SC_MARK_BOXMINUSCONNECTED];
    [self sci_defineFoldMarker:SC_MARKNUM_FOLDERMIDTAIL symbol:SC_MARK_TCORNER];

    // Configure the fold margin as a clickable symbol margin.
    [self sci_message:SCI_SETMARGINTYPEN wparam:foldMargin lparam:SC_MARGIN_SYMBOL];
    [self sci_message:SCI_SETMARGINMASKN wparam:foldMargin lparam:(sptr_t)SC_MASK_FOLDERS];
    [self sci_message:SCI_SETMARGINWIDTHN wparam:foldMargin lparam:16];
    [self sci_message:SCI_SETMARGINSENSITIVEN wparam:foldMargin lparam:1];

    // Let Scintilla show/hide fold markers and act on margin clicks itself.
    [self sci_message:SCI_SETAUTOMATICFOLD
                wparam:(uptr_t)(SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE)
                lparam:0];
    [self sci_message:SCI_SETFOLDFLAGS wparam:SC_FOLDFLAG_LINEAFTER_CONTRACTED lparam:0];

    [self sci_setProperty:"fold" value:"1"];
}

- (void)sci_defineFoldMarker:(int)markerNumber symbol:(int)symbol {
    [self sci_message:SCI_MARKERDEFINE wparam:(uptr_t)markerNumber lparam:symbol];
}

/// The seven marker slots Scintilla uses for the fold margin.
static const int kFoldMarkers[] = {
    SC_MARKNUM_FOLDEROPEN, SC_MARKNUM_FOLDER, SC_MARKNUM_FOLDERSUB,
    SC_MARKNUM_FOLDERTAIL, SC_MARKNUM_FOLDEREND, SC_MARKNUM_FOLDEROPENMID,
    SC_MARKNUM_FOLDERMIDTAIL
};

- (void)setFoldColorsWithBackground:(NSColor *)background marker:(NSColor *)marker {
    const sptr_t bg = SciColourFromNSColor(background);
    const sptr_t mk = SciColourFromNSColor(marker);

    // Blend the fold margin stripe with the editor background.
    [self sci_message:SCI_SETFOLDMARGINCOLOUR wparam:1 lparam:bg];
    [self sci_message:SCI_SETFOLDMARGINHICOLOUR wparam:1 lparam:bg];

    // Draw each fold box with a background-coloured interior and a muted,
    // theme-derived outline so the +/- glyphs read cleanly in light and dark.
    for (size_t i = 0; i < sizeof(kFoldMarkers) / sizeof(kFoldMarkers[0]); i++) {
        const int m = kFoldMarkers[i];
        [self sci_message:SCI_MARKERSETFORE wparam:(uptr_t)m lparam:bg];
        [self sci_message:SCI_MARKERSETBACK wparam:(uptr_t)m lparam:mk];
        [self sci_message:SCI_MARKERSETBACKSELECTED wparam:(uptr_t)m lparam:mk];
    }
}

- (void)foldAll {
    // SC_FOLDACTION_CONTRACT == 0
    [self sci_message:SCI_FOLDALL wparam:0 lparam:0];
}

- (void)unfoldAll {
    // SC_FOLDACTION_EXPAND == 1
    [self sci_message:SCI_FOLDALL wparam:1 lparam:0];
}

#pragma mark Find & Replace

- (int)sci_searchFlagsCaseSensitive:(BOOL)caseSensitive regex:(BOOL)regex wholeWord:(BOOL)wholeWord {
    int flags = 0;
    if (caseSensitive) flags |= SCFIND_MATCHCASE;
    if (wholeWord)     flags |= SCFIND_WHOLEWORD;
    if (regex)         flags |= (SCFIND_REGEXP | SCFIND_CXX11REGEX);
    return flags;
}

/// Searches the current target range, returning the match start position or -1.
- (sptr_t)sci_searchInTarget:(const char *)needle length:(size_t)length {
    return [self sci_message:SCI_SEARCHINTARGET wparam:(uptr_t)length lparam:(sptr_t)needle];
}

/// Counts matches whose start is at or before `limit` (search flags preset).
- (NSInteger)sci_ordinalUpTo:(sptr_t)limit needle:(const char *)needle
                      length:(size_t)length docLength:(sptr_t)docLength {
    NSInteger n = 0;
    sptr_t pos = 0;
    while (pos <= docLength) {
        [self sci_message:SCI_SETTARGETSTART wparam:(uptr_t)pos lparam:0];
        [self sci_message:SCI_SETTARGETEND wparam:(uptr_t)docLength lparam:0];
        if ([self sci_searchInTarget:needle length:length] < 0) break;
        const sptr_t s = [self sci_message:SCI_GETTARGETSTART wparam:0 lparam:0];
        const sptr_t e = [self sci_message:SCI_GETTARGETEND wparam:0 lparam:0];
        if (s > limit) break;
        n++;
        pos = (e > s) ? e : s + 1;
    }
    return n;
}

- (NSInteger)findText:(NSString *)query
        caseSensitive:(BOOL)caseSensitive
                regex:(BOOL)regex
            wholeWord:(BOOL)wholeWord
              forward:(BOOL)forward {
    if (query.length == 0) return 0;

    [self sci_message:SCI_SETSEARCHFLAGS
                wparam:(uptr_t)[self sci_searchFlagsCaseSensitive:caseSensitive regex:regex wholeWord:wholeWord]
                lparam:0];

    const char *needle = [query UTF8String];
    const size_t nlen = strlen(needle);
    const sptr_t docLen = [self sci_message:SCI_GETLENGTH wparam:0 lparam:0];
    const sptr_t selStart = [self sci_message:SCI_GETSELECTIONSTART wparam:0 lparam:0];
    const sptr_t selEnd = [self sci_message:SCI_GETSELECTIONEND wparam:0 lparam:0];

    sptr_t mStart = -1, mEnd = -1;
    // Two passes: from the caret to the document edge, then wrap around.
    const sptr_t firstStart = forward ? selEnd : selStart;
    const sptr_t firstEnd   = forward ? docLen : 0;
    const sptr_t wrapStart   = forward ? 0 : docLen;
    const sptr_t wrapEnd     = forward ? docLen : 0;

    [self sci_message:SCI_SETTARGETSTART wparam:(uptr_t)firstStart lparam:0];
    [self sci_message:SCI_SETTARGETEND wparam:(uptr_t)firstEnd lparam:0];
    if ([self sci_searchInTarget:needle length:nlen] >= 0) {
        mStart = [self sci_message:SCI_GETTARGETSTART wparam:0 lparam:0];
        mEnd = [self sci_message:SCI_GETTARGETEND wparam:0 lparam:0];
    } else {
        [self sci_message:SCI_SETTARGETSTART wparam:(uptr_t)wrapStart lparam:0];
        [self sci_message:SCI_SETTARGETEND wparam:(uptr_t)wrapEnd lparam:0];
        if ([self sci_searchInTarget:needle length:nlen] >= 0) {
            mStart = [self sci_message:SCI_GETTARGETSTART wparam:0 lparam:0];
            mEnd = [self sci_message:SCI_GETTARGETEND wparam:0 lparam:0];
        }
    }

    if (mStart < 0) return 0;

    [self sci_message:SCI_SETSEL wparam:(uptr_t)mStart lparam:(sptr_t)mEnd];
    [self sci_message:SCI_SCROLLCARET wparam:0 lparam:0];
    return [self sci_ordinalUpTo:mStart needle:needle length:nlen docLength:docLen];
}

- (NSInteger)matchCountFor:(NSString *)query
             caseSensitive:(BOOL)caseSensitive
                     regex:(BOOL)regex
                 wholeWord:(BOOL)wholeWord {
    if (query.length == 0) return 0;

    [self sci_message:SCI_SETSEARCHFLAGS
                wparam:(uptr_t)[self sci_searchFlagsCaseSensitive:caseSensitive regex:regex wholeWord:wholeWord]
                lparam:0];

    const char *needle = [query UTF8String];
    const size_t nlen = strlen(needle);
    const sptr_t docLen = [self sci_message:SCI_GETLENGTH wparam:0 lparam:0];

    NSInteger n = 0;
    sptr_t pos = 0;
    while (pos <= docLen) {
        [self sci_message:SCI_SETTARGETSTART wparam:(uptr_t)pos lparam:0];
        [self sci_message:SCI_SETTARGETEND wparam:(uptr_t)docLen lparam:0];
        if ([self sci_searchInTarget:needle length:nlen] < 0) break;
        const sptr_t s = [self sci_message:SCI_GETTARGETSTART wparam:0 lparam:0];
        const sptr_t e = [self sci_message:SCI_GETTARGETEND wparam:0 lparam:0];
        n++;
        pos = (e > s) ? e : s + 1;
    }
    return n;
}

- (BOOL)replaceCurrent:(NSString *)query
                  with:(NSString *)replacement
         caseSensitive:(BOOL)caseSensitive
                 regex:(BOOL)regex
             wholeWord:(BOOL)wholeWord {
    if (query.length == 0) return NO;

    [self sci_message:SCI_SETSEARCHFLAGS
                wparam:(uptr_t)[self sci_searchFlagsCaseSensitive:caseSensitive regex:regex wholeWord:wholeWord]
                lparam:0];

    const char *needle = [query UTF8String];
    const size_t nlen = strlen(needle);
    const sptr_t selStart = [self sci_message:SCI_GETSELECTIONSTART wparam:0 lparam:0];
    const sptr_t selEnd = [self sci_message:SCI_GETSELECTIONEND wparam:0 lparam:0];

    BOOL replaced = NO;
    if (selEnd > selStart) {
        // Only replace when the current selection is itself an exact match.
        [self sci_message:SCI_SETTARGETSTART wparam:(uptr_t)selStart lparam:0];
        [self sci_message:SCI_SETTARGETEND wparam:(uptr_t)selEnd lparam:0];
        if ([self sci_searchInTarget:needle length:nlen] >= 0 &&
            [self sci_message:SCI_GETTARGETSTART wparam:0 lparam:0] == selStart &&
            [self sci_message:SCI_GETTARGETEND wparam:0 lparam:0] == selEnd) {
            const char *repC = [replacement UTF8String];
            const size_t repLen = strlen(repC);
            const sptr_t written = regex
                ? [self sci_message:SCI_REPLACETARGETRE wparam:(uptr_t)repLen lparam:(sptr_t)repC]
                : [self sci_message:SCI_REPLACETARGET wparam:(uptr_t)repLen lparam:(sptr_t)repC];
            const sptr_t newCaret = selStart + written;
            [self sci_message:SCI_SETSEL wparam:(uptr_t)newCaret lparam:(sptr_t)newCaret];
            replaced = YES;
        }
    }

    // Advance to the following match regardless.
    [self findText:query caseSensitive:caseSensitive regex:regex wholeWord:wholeWord forward:YES];
    return replaced;
}

- (NSInteger)replaceAllOf:(NSString *)query
                     with:(NSString *)replacement
            caseSensitive:(BOOL)caseSensitive
                    regex:(BOOL)regex
                wholeWord:(BOOL)wholeWord {
    if (query.length == 0) return 0;

    [self sci_message:SCI_SETSEARCHFLAGS
                wparam:(uptr_t)[self sci_searchFlagsCaseSensitive:caseSensitive regex:regex wholeWord:wholeWord]
                lparam:0];

    const char *needle = [query UTF8String];
    const size_t nlen = strlen(needle);
    const char *repC = [replacement UTF8String];
    const size_t repLen = strlen(repC);

    sptr_t docLen = [self sci_message:SCI_GETLENGTH wparam:0 lparam:0];

    [self sci_message:SCI_BEGINUNDOACTION wparam:0 lparam:0];
    NSInteger n = 0;
    sptr_t pos = 0;
    while (pos <= docLen) {
        [self sci_message:SCI_SETTARGETSTART wparam:(uptr_t)pos lparam:0];
        [self sci_message:SCI_SETTARGETEND wparam:(uptr_t)docLen lparam:0];
        if ([self sci_searchInTarget:needle length:nlen] < 0) break;
        const sptr_t s = [self sci_message:SCI_GETTARGETSTART wparam:0 lparam:0];
        const sptr_t written = regex
            ? [self sci_message:SCI_REPLACETARGETRE wparam:(uptr_t)repLen lparam:(sptr_t)repC]
            : [self sci_message:SCI_REPLACETARGET wparam:(uptr_t)repLen lparam:(sptr_t)repC];
        const sptr_t e = s + written;
        docLen = [self sci_message:SCI_GETLENGTH wparam:0 lparam:0];
        pos = (e > s) ? e : s + 1;
        n++;
    }
    [self sci_message:SCI_ENDUNDOACTION wparam:0 lparam:0];

    if (n > 0 && _foldingEnabled) {
        [self sci_message:SCI_COLOURISE wparam:0 lparam:-1];
    }
    return n;
}

#pragma mark Document map

- (void)setDocumentMapViewportColor:(NSColor *)color {
    if (color == nil) {
        return;
    }
    _mapViewportColor = color;
    if (_mapHighlight != nil) {
        _mapHighlight.layer.backgroundColor = [[color colorWithAlphaComponent:0.26] CGColor];
        _mapHighlight.layer.borderColor = [[color colorWithAlphaComponent:0.85] CGColor];
    }
}

- (void)setDocumentMapVisible:(BOOL)visible {
    if (visible) {
        if (_map == nil) {
            [self sci_setupMap];
        }
        _documentMapVisible = YES;
        _mapContainer.hidden = NO;
        [self syncMapStyling];
        [self sci_layoutSubviews];
        [self refreshMapViewport];
    } else {
        _documentMapVisible = NO;
        _mapContainer.hidden = YES;
        [self sci_layoutSubviews];
    }
}

/// Lazily builds the minimap: a second ScintillaView that shares the editor's
/// document (zero copy, always in sync), plus a transparent overlay that hosts
/// the viewport slider and swallows clicks so the map stays passive.
- (void)sci_setupMap {
    _mapContainer = [[SciFlippedView alloc]
        initWithFrame:NSMakeRect(0, 0, _mapWidth, self.bounds.size.height)];
    _mapContainer.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
    [self addSubview:_mapContainer];

    _map = [[ScintillaView alloc] initWithFrame:_mapContainer.bounds];
    _map.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_mapContainer addSubview:_map];

    // Share the editor's document. IMPORTANT: read-only is a *document* property
    // in Scintilla, so we must NOT call SCI_SETREADONLY on the map -- it would
    // freeze the real editor too. The overlay below keeps the map passive.
    const sptr_t doc = [_scintilla message:SCI_GETDOCPOINTER wParam:0 lParam:0];
    [_map message:SCI_SETDOCPOINTER wParam:0 lParam:doc];

    // Tiny, chrome-free overview. These are all per-view (safe on a shared doc).
    [_map message:SCI_SETCODEPAGE wParam:SC_CP_UTF8 lParam:0];
    [_map message:SCI_SETZOOM wParam:(uptr_t)(-8) lParam:0];
    [_map message:SCI_SETMARGINS wParam:0 lParam:0];
    [_map message:SCI_SETWRAPMODE wParam:SC_WRAP_NONE lParam:0];
    [_map message:SCI_SETHSCROLLBAR wParam:0 lParam:0];
    [_map message:SCI_SETVSCROLLBAR wParam:0 lParam:0];
    [_map message:SCI_SETCARETSTYLE wParam:CARETSTYLE_INVISIBLE lParam:0];

    // Transparent overlay: catches clicks/drags and holds the viewport slider.
    _mapOverlay = [[SciFlippedView alloc] initWithFrame:_mapContainer.bounds];
    _mapOverlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_mapContainer addSubview:_mapOverlay];

    _mapHighlight = [[NSView alloc] initWithFrame:NSZeroRect];
    _mapHighlight.wantsLayer = YES;
    _mapHighlight.layer.borderWidth = 1.0;
    _mapHighlight.layer.cornerRadius = 1.0;
    NSColor *vp = _mapViewportColor ?: [NSColor selectedContentBackgroundColor];
    _mapHighlight.layer.backgroundColor = [[vp colorWithAlphaComponent:0.26] CGColor];
    _mapHighlight.layer.borderColor = [[vp colorWithAlphaComponent:0.85] CGColor];
    [_mapOverlay addSubview:_mapHighlight];

    NSClickGestureRecognizer *click =
        [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(sci_mapClick:)];
    [_mapOverlay addGestureRecognizer:click];
    NSPanGestureRecognizer *pan =
        [[NSPanGestureRecognizer alloc] initWithTarget:self action:@selector(sci_mapPan:)];
    [_mapOverlay addGestureRecognizer:pan];
}

/// Mirrors the editor's font + colours onto the map so the shared style bytes
/// render with the same theme. The map runs no lexer of its own -- the shared
/// document already carries the style bytes the editor's lexer produced.
- (void)syncMapStyling {
    if (_map == nil) {
        return;
    }
    [_map message:SCI_STYLESETFONT wParam:STYLE_DEFAULT lParam:(sptr_t)[_baseFontName UTF8String]];
    [_map message:SCI_STYLESETSIZE wParam:STYLE_DEFAULT lParam:(sptr_t)lround(_baseFontSize)];
    if (_hasEditorColors) {
        [_map message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:_editorFore];
        [_map message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:_editorBack];
    }
    [_map message:SCI_STYLECLEARALL wParam:0 lParam:0];

    ScintillaView *prev = _styleTarget;
    _styleTarget = _map;
    [self applyTokenColorsBody];
    _styleTarget = prev;

    [_map message:SCI_SETZOOM wParam:(uptr_t)(-8) lParam:0];
}

/// Positions the editor and, depending on mode, the docked map or the compare
/// split. Compare mode takes priority and hides both the editor and the map.
- (void)sci_layoutSubviews {
    const NSSize size = self.bounds.size;

    if (_comparing && _cmpContainer != nil) {
        _scintilla.hidden = YES;
        if (_mapContainer) { _mapContainer.hidden = YES; }
        _cmpContainer.hidden = NO;
        _cmpContainer.frame = NSMakeRect(0, 0, size.width, size.height);
        const CGFloat dividerW = 1.0;
        CGFloat half = floor((size.width - dividerW) / 2.0);
        if (half < 0) { half = 0; }
        _cmpLeft.frame = NSMakeRect(0, 0, half, size.height);
        _cmpDivider.frame = NSMakeRect(half, 0, dividerW, size.height);
        _cmpRight.frame = NSMakeRect(half + dividerW, 0, size.width - half - dividerW, size.height);
        return;
    }

    _scintilla.hidden = NO;
    if (_cmpContainer) { _cmpContainer.hidden = YES; }

    if (_documentMapVisible && _map != nil) {
        if (_mapContainer) { _mapContainer.hidden = NO; }
        CGFloat mw = _mapWidth;
        const CGFloat cap = floor(size.width * 0.5);
        if (mw > cap) { mw = cap; }
        _scintilla.frame = NSMakeRect(0, 0, MAX(0.0, size.width - mw), size.height);
        _mapContainer.frame = NSMakeRect(size.width - mw, 0, mw, size.height);
    } else {
        if (_mapContainer) { _mapContainer.hidden = YES; }
        _scintilla.frame = NSMakeRect(0, 0, size.width, size.height);
    }
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self sci_layoutSubviews];
}

- (void)layout {
    [super layout];
    [self sci_layoutSubviews];
}

/// Repositions the "you are here" slider and scrolls the map so the editor's
/// visible range is always shown, even for long documents.
- (void)refreshMapViewport {
    if (_map == nil || _mapContainer.hidden) {
        return;
    }
    const sptr_t total = [_scintilla message:SCI_GETLINECOUNT wParam:0 lParam:0];
    const sptr_t firstVis = [_scintilla message:SCI_GETFIRSTVISIBLELINE wParam:0 lParam:0];
    const sptr_t onScreen = [_scintilla message:SCI_LINESONSCREEN wParam:0 lParam:0];

    // Convert the editor's (possibly wrapped) visible display lines to document
    // lines so the slider lines up with the map, which never wraps.
    const sptr_t firstDoc = [_scintilla message:SCI_DOCLINEFROMVISIBLE wParam:(uptr_t)firstVis lParam:0];
    const sptr_t lastDoc = [_scintilla message:SCI_DOCLINEFROMVISIBLE wParam:(uptr_t)(firstVis + onScreen) lParam:0];
    sptr_t spanDoc = lastDoc - firstDoc;
    if (spanDoc < 1) spanDoc = 1;

    const sptr_t mapOnScreen = [_map message:SCI_LINESONSCREEN wParam:0 lParam:0];
    sptr_t mapFirst = 0;
    if (total > mapOnScreen && total > spanDoc) {
        const double denom = (double)(total - spanDoc);
        const double frac = denom > 0.0 ? (double)firstDoc / denom : 0.0;
        mapFirst = (sptr_t)llround(frac * (double)(total - mapOnScreen));
        if (mapFirst < 0) mapFirst = 0;
    }
    [_map message:SCI_SETFIRSTVISIBLELINE wParam:(uptr_t)mapFirst lParam:0];

    CGFloat lineH = (CGFloat)[_map message:SCI_TEXTHEIGHT wParam:0 lParam:0];
    if (lineH < 1.0) lineH = 1.0;

    const CGFloat y = (CGFloat)(firstDoc - mapFirst) * lineH;
    CGFloat h = (CGFloat)spanDoc * lineH;
    if (h < 4.0) h = 4.0;
    _mapHighlight.frame = NSMakeRect(0, y, _mapOverlay.bounds.size.width, h);
}

- (void)sci_mapClick:(NSClickGestureRecognizer *)g {
    [self sci_scrollEditorToMapY:[g locationInView:_mapOverlay].y];
}

- (void)sci_mapPan:(NSPanGestureRecognizer *)g {
    [self sci_scrollEditorToMapY:[g locationInView:_mapOverlay].y];
}

/// Scrolls the editor so the document line under map point `y` is centered.
- (void)sci_scrollEditorToMapY:(CGFloat)y {
    if (_map == nil) {
        return;
    }
    CGFloat lineH = (CGFloat)[_map message:SCI_TEXTHEIGHT wParam:0 lParam:0];
    if (lineH < 1.0) lineH = 1.0;
    const sptr_t mapFirst = [_map message:SCI_GETFIRSTVISIBLELINE wParam:0 lParam:0];
    sptr_t docLine = mapFirst + (sptr_t)floor(y / lineH);
    if (docLine < 0) docLine = 0;

    const sptr_t onScreen = [_scintilla message:SCI_LINESONSCREEN wParam:0 lParam:0];
    // Map the doc line to a display line, then back off half a screen to centre.
    const sptr_t targetVis = [_scintilla message:SCI_VISIBLEFROMDOCLINE wParam:(uptr_t)docLine lParam:0];
    sptr_t first = targetVis - onScreen / 2;
    if (first < 0) first = 0;
    [_scintilla message:SCI_SETFIRSTVISIBLELINE wParam:(uptr_t)first lParam:0];
    [self refreshMapViewport];
}

#pragma mark Compare (side-by-side diff)

- (BOOL)isComparing {
    return _comparing;
}

- (void)setCompareColorsAdded:(NSColor *)added
                      deleted:(NSColor *)deleted
                      changed:(NSColor *)changed
                       filler:(NSColor *)filler {
    _cmpAdded = SciColourFromNSColor(added);
    _cmpDeleted = SciColourFromNSColor(deleted);
    _cmpChanged = SciColourFromNSColor(changed);
    _cmpFiller = SciColourFromNSColor(filler);
    _hasCompareColors = YES;
    if (_cmpLeft) { [self sci_applyCompareMarkerColors:_cmpLeft]; }
    if (_cmpRight) { [self sci_applyCompareMarkerColors:_cmpRight]; }
}

/// Defines the four line-background markers (drawn translucently) and the
/// intra-line change indicator colour on one compare pane.
- (void)sci_applyCompareMarkerColors:(ScintillaView *)v {
    if (!_hasCompareColors) { return; }
    [v message:SCI_MARKERDEFINE wParam:kCmpMarkAdded lParam:SC_MARK_BACKGROUND];
    [v message:SCI_MARKERSETBACK wParam:kCmpMarkAdded lParam:_cmpAdded];
    [v message:SCI_MARKERSETALPHA wParam:kCmpMarkAdded lParam:55];
    [v message:SCI_MARKERDEFINE wParam:kCmpMarkDeleted lParam:SC_MARK_BACKGROUND];
    [v message:SCI_MARKERSETBACK wParam:kCmpMarkDeleted lParam:_cmpDeleted];
    [v message:SCI_MARKERSETALPHA wParam:kCmpMarkDeleted lParam:55];
    [v message:SCI_MARKERDEFINE wParam:kCmpMarkChanged lParam:SC_MARK_BACKGROUND];
    [v message:SCI_MARKERSETBACK wParam:kCmpMarkChanged lParam:_cmpChanged];
    [v message:SCI_MARKERSETALPHA wParam:kCmpMarkChanged lParam:50];
    [v message:SCI_MARKERDEFINE wParam:kCmpMarkFiller lParam:SC_MARK_BACKGROUND];
    [v message:SCI_MARKERSETBACK wParam:kCmpMarkFiller lParam:_cmpFiller];
    [v message:SCI_MARKERSETALPHA wParam:kCmpMarkFiller lParam:70];
    [v message:SCI_INDICSETFORE wParam:(uptr_t)kCmpIndic lParam:_cmpChanged];
}

/// One-time per-pane configuration: UTF-8, no wrap, invisible caret, an original
/// line-number text margin, and the intra-line change indicator.
- (void)sci_configureCompareView:(ScintillaView *)v {
    [v message:SCI_SETCODEPAGE wParam:SC_CP_UTF8 lParam:0];
    [v message:SCI_SETWRAPMODE wParam:SC_WRAP_NONE lParam:0];
    [v message:SCI_SETHSCROLLBAR wParam:0 lParam:0];
    [v message:SCI_SETCARETSTYLE wParam:CARETSTYLE_INVISIBLE lParam:0];
    // Margin 0 shows the original line numbers as text; hide the other margins.
    [v message:SCI_SETMARGINTYPEN wParam:0 lParam:SC_MARGIN_TEXT];
    [v message:SCI_SETMARGINWIDTHN wParam:1 lParam:0];
    [v message:SCI_SETMARGINWIDTHN wParam:2 lParam:0];
    // Intra-line change indicator: a translucent rounded box.
    [v message:SCI_INDICSETSTYLE wParam:(uptr_t)kCmpIndic lParam:INDIC_ROUNDBOX];
    [v message:SCI_INDICSETALPHA wParam:(uptr_t)kCmpIndic lParam:70];
    [v message:SCI_INDICSETOUTLINEALPHA wParam:(uptr_t)kCmpIndic lParam:160];
    [self sci_applyCompareMarkerColors:v];
}

/// Lazily builds the two compare panes and the divider between them.
- (void)sci_ensureCompareViews {
    if (_cmpContainer != nil) { return; }

    _cmpContainer = [[SciFlippedView alloc] initWithFrame:self.bounds];
    _cmpContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_cmpContainer];

    _cmpLeft = [[ScintillaView alloc] initWithFrame:NSZeroRect];
    _cmpRight = [[ScintillaView alloc] initWithFrame:NSZeroRect];

    _cmpDivider = [[NSView alloc] initWithFrame:NSZeroRect];
    _cmpDivider.wantsLayer = YES;
    _cmpDivider.layer.backgroundColor = [[NSColor separatorColor] CGColor];

    _cmpLeftObs = [SciViewObserver new];
    _cmpLeftObs.owner = self;
    _cmpLeftObs.tag = 0;
    _cmpRightObs = [SciViewObserver new];
    _cmpRightObs.owner = self;
    _cmpRightObs.tag = 1;
    _cmpLeft.delegate = _cmpLeftObs;
    _cmpRight.delegate = _cmpRightObs;

    [_cmpContainer addSubview:_cmpLeft];
    [_cmpContainer addSubview:_cmpDivider];
    [_cmpContainer addSubview:_cmpRight];

    [self sci_configureCompareView:_cmpLeft];
    [self sci_configureCompareView:_cmpRight];
}

/// Loads one side's text, then applies its line numbers, diff markers, and
/// intra-line indicators, and finally locks the pane read-only.
- (void)sci_loadCompareSide:(ScintillaView *)v
                       text:(NSString *)text
                     status:(NSArray<NSNumber *> *)status
                    numbers:(NSArray<NSNumber *> *)numbers
                  spanStart:(NSArray<NSNumber *> *)spanStart
                 spanLength:(NSArray<NSNumber *> *)spanLength
                      lexer:(NSString *)lexer {
    // Writable while we load + decorate; locked at the end.
    [v message:SCI_SETREADONLY wParam:0 lParam:0];
    [v setString:(text ?: @"")];

    // Base font + colours, mirrored from the editor's cached appearance.
    [v message:SCI_STYLESETFONT wParam:STYLE_DEFAULT lParam:(sptr_t)[_baseFontName UTF8String]];
    [v message:SCI_STYLESETSIZE wParam:STYLE_DEFAULT lParam:(sptr_t)lround(_baseFontSize)];
    if (_hasEditorColors) {
        [v message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:_editorFore];
        [v message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:_editorBack];
    }
    [v message:SCI_STYLECLEARALL wParam:0 lParam:0];
    if (_hasGutterColors) {
        [v message:SCI_STYLESETFORE wParam:STYLE_LINENUMBER lParam:_gutterFore];
        [v message:SCI_STYLESETBACK wParam:STYLE_LINENUMBER lParam:_gutterBack];
    }

    // Syntax colouring with the same lexer as the editor.
    if (lexer.length > 0) {
        void *lx = (void *)CreateLexer([lexer UTF8String]);
        [v message:SCI_SETILEXER wParam:0 lParam:(sptr_t)lx];
        ScintillaView *prev = _styleTarget;
        _styleTarget = v;
        [self applyTokenColorsBody];
        _styleTarget = prev;
        [v message:SCI_COLOURISE wParam:0 lParam:-1];
    } else {
        [v message:SCI_SETILEXER wParam:0 lParam:0];
    }

    const NSInteger rows = (NSInteger)status.count;

    // Original line-number text margin (blank on filler rows).
    NSInteger maxNum = 0;
    for (NSNumber *n in numbers) {
        if (n.integerValue > maxNum) { maxNum = n.integerValue; }
    }
    int digits = 1;
    for (NSInteger t = maxNum; t >= 10; t /= 10) { digits++; }
    for (NSInteger row = 0; row < rows; row++) {
        const NSInteger num = (row < (NSInteger)numbers.count) ? numbers[row].integerValue : 0;
        const char *txt = (num > 0)
            ? [[NSString stringWithFormat:@"%ld ", (long)num] UTF8String] : "";
        [v message:SCI_MARGINSETTEXT wParam:(uptr_t)row lParam:(sptr_t)txt];
        [v message:SCI_MARGINSETSTYLE wParam:(uptr_t)row lParam:STYLE_LINENUMBER];
    }
    [v message:SCI_SETMARGINWIDTHN wParam:0 lParam:(sptr_t)(16 + digits * 9)];

    // Line-background diff markers.
    for (NSInteger row = 0; row < rows; row++) {
        int marker = -1;
        switch (status[row].integerValue) {
            case 1: marker = kCmpMarkAdded; break;
            case 2: marker = kCmpMarkDeleted; break;
            case 3: marker = kCmpMarkChanged; break;
            case 4: marker = kCmpMarkFiller; break;
            default: break;
        }
        if (marker >= 0) {
            [v message:SCI_MARKERADD wParam:(uptr_t)row lParam:marker];
        }
    }

    // Intra-line change indicators (byte ranges within each changed row).
    [v message:SCI_SETINDICATORCURRENT wParam:(uptr_t)kCmpIndic lParam:0];
    for (NSInteger row = 0; row < rows && row < (NSInteger)spanLength.count; row++) {
        const NSInteger len = spanLength[row].integerValue;
        if (len <= 0) { continue; }
        const NSInteger startByte = spanStart[row].integerValue;
        const sptr_t linePos = [v message:SCI_POSITIONFROMLINE wParam:(uptr_t)row lParam:0];
        [v message:SCI_INDICATORFILLRANGE wParam:(uptr_t)(linePos + startByte) lParam:(sptr_t)len];
    }

    // Lock the pane so the snapshot can't be edited.
    [v message:SCI_SETREADONLY wParam:1 lParam:0];
}

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
                      lexer:(NSString *)lexer {
    [self sci_ensureCompareViews];
    _comparing = YES;

    [self sci_loadCompareSide:_cmpLeft text:leftText status:leftStatus numbers:leftNumbers
                    spanStart:leftSpanStart spanLength:leftSpanLength lexer:lexer];
    [self sci_loadCompareSide:_cmpRight text:rightText status:rightStatus numbers:rightNumbers
                    spanStart:rightSpanStart spanLength:rightSpanLength lexer:lexer];

    // Record the row indices where a change block starts (for next/prev nav).
    // Every non-equal row is non-zero on the left, so the left status suffices.
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSInteger prev = 0;
    for (NSUInteger i = 0; i < leftStatus.count; i++) {
        const NSInteger s = leftStatus[i].integerValue;
        if (s != 0 && prev == 0) { [starts addObject:@((NSInteger)i)]; }
        prev = s;
    }
    _cmpBlockStarts = starts;

    // Start both panes at the top, aligned.
    _syncingCompare = YES;
    [_cmpLeft message:SCI_SETFIRSTVISIBLELINE wParam:0 lParam:0];
    [_cmpRight message:SCI_SETFIRSTVISIBLELINE wParam:0 lParam:0];
    _syncingCompare = NO;

    [self sci_layoutSubviews];
}

- (void)endCompare {
    if (!_comparing) { return; }
    _comparing = NO;
    _cmpContainer.hidden = YES;
    // Release the (possibly large) diff snapshots.
    if (_cmpLeft) {
        [_cmpLeft message:SCI_SETREADONLY wParam:0 lParam:0];
        [_cmpLeft setString:@""];
    }
    if (_cmpRight) {
        [_cmpRight message:SCI_SETREADONLY wParam:0 lParam:0];
        [_cmpRight setString:@""];
    }
    _cmpBlockStarts = nil;
    [self sci_layoutSubviews];
}

- (void)compareStep:(NSInteger)direction {
    if (!_comparing || _cmpBlockStarts.count == 0) { return; }

    const sptr_t firstVis = [_cmpLeft message:SCI_GETFIRSTVISIBLELINE wParam:0 lParam:0];
    const sptr_t onScreen = [_cmpLeft message:SCI_LINESONSCREEN wParam:0 lParam:0];
    const NSInteger center = (NSInteger)(firstVis + onScreen / 2);

    NSInteger target = -1;
    if (direction >= 0) {
        for (NSNumber *n in _cmpBlockStarts) {
            if (n.integerValue > center) { target = n.integerValue; break; }
        }
        if (target < 0) { target = _cmpBlockStarts.firstObject.integerValue; }
    } else {
        for (NSInteger i = (NSInteger)_cmpBlockStarts.count - 1; i >= 0; i--) {
            const NSInteger v = _cmpBlockStarts[i].integerValue;
            if (v < center) { target = v; break; }
        }
        if (target < 0) { target = _cmpBlockStarts.lastObject.integerValue; }
    }

    NSInteger first = target - (NSInteger)(onScreen / 4);
    if (first < 0) { first = 0; }
    _syncingCompare = YES;
    [_cmpLeft message:SCI_SETFIRSTVISIBLELINE wParam:(uptr_t)first lParam:0];
    [_cmpRight message:SCI_SETFIRSTVISIBLELINE wParam:(uptr_t)first lParam:0];
    _syncingCompare = NO;
}

/// Forwarded by the per-pane observers: mirror one pane's scroll to the other.
- (void)sci_compareNotification:(SCNotification *)notification fromTag:(NSInteger)tag {
    if (!_comparing || notification == NULL) { return; }
    if (notification->nmhdr.code != SCN_UPDATEUI) { return; }
    if ((notification->updated & (SC_UPDATE_V_SCROLL | SC_UPDATE_H_SCROLL)) == 0) { return; }
    if (_syncingCompare) { return; }

    _syncingCompare = YES;
    ScintillaView *src = (tag == 0) ? _cmpLeft : _cmpRight;
    ScintillaView *dst = (tag == 0) ? _cmpRight : _cmpLeft;
    const sptr_t fv = [src message:SCI_GETFIRSTVISIBLELINE wParam:0 lParam:0];
    [dst message:SCI_SETFIRSTVISIBLELINE wParam:(uptr_t)fv lParam:0];
    _syncingCompare = NO;
}

#pragma mark Introspection

+ (NSString *)engineVersion {
    return @"Scintilla 5.6.3 / Lexilla 5.5.0";
}

#pragma mark ScintillaNotificationProtocol

- (void)notification:(SCNotification *)notification {
    if (notification == NULL) {
        return;
    }

    const unsigned int code = notification->nmhdr.code;

    if (code == SCN_MODIFIED && !_loading) {
        const int mods = notification->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT);
        if (mods != 0) {
            if (self.onTextChanged) {
                self.onTextChanged();
            }
            if (_documentMapVisible) {
                [self refreshMapViewport];
            }
        }
        return;
    }

    if (code == SCN_UPDATEUI) {
        if (self.onSelectionChanged) {
            const sptr_t pos = [self sci_message:SCI_GETCURRENTPOS wparam:0 lparam:0];
            const sptr_t line = [self sci_message:SCI_LINEFROMPOSITION wparam:(uptr_t)pos lparam:0];
            const sptr_t col = [self sci_message:SCI_GETCOLUMN wparam:(uptr_t)pos lparam:0];
            const sptr_t selStart = [self sci_message:SCI_GETSELECTIONSTART wparam:0 lparam:0];
            const sptr_t selEnd = [self sci_message:SCI_GETSELECTIONEND wparam:0 lparam:0];
            self.onSelectionChanged((NSInteger)line + 1, (NSInteger)col + 1, (NSInteger)(selEnd - selStart));
        }
        if (_documentMapVisible &&
            (notification->updated & (SC_UPDATE_V_SCROLL | SC_UPDATE_H_SCROLL | SC_UPDATE_SELECTION))) {
            [self refreshMapViewport];
        }
    }
}

@end

#pragma mark - SciViewObserver

@implementation SciViewObserver
- (void)notification:(SCNotification *)notification {
    [self.owner sci_compareNotification:notification fromTag:self.tag];
}
@end
