//
//  iTermTextExtractor.m
//  iTerm
//
//  Created by George Nachman on 2/17/14.
//
//

#import "iTermTextExtractor.h"
#import "DebugLogging.h"
#import "NSStringITerm.h"
#import "NSMutableAttributedString+iTerm.h"
#import "RegexKitLite.h"
#import "PreferencePanel.h"
#import "SmartMatch.h"
#import "SmartSelectionController.h"

// Must find at least this many divider chars in a row for it to count as a divider.
static const int kNumCharsToSearchForDivider = 8;

@implementation iTermTextExtractor {
    id<PTYTextViewDataSource> _dataSource;
    VT100GridRange _logicalWindow;
}

+ (instancetype)textExtractorWithDataSource:(id<PTYTextViewDataSource>)dataSource {
    return [[[self alloc] initWithDataSource:dataSource] autorelease];
}

- (id)initWithDataSource:(id<PTYTextViewDataSource>)dataSource {
    self = [super init];
    if (self) {
        _dataSource = dataSource;
        _logicalWindow = VT100GridRangeMake(0, [dataSource width]);
    }
    return self;
}

- (BOOL)hasLogicalWindow {
    return _logicalWindow.location == 0 && [self xLimit] == [_dataSource width];
}

- (void)restrictToLogicalWindowIncludingCoord:(VT100GridCoord)coord {
    NSIndexSet *possibleDividers = [self possibleColumnDividerIndexesAround:coord];
    __block int dividerBefore = 0;
    __block int dividerAfter = -1;
    [possibleDividers enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if ([self coordContainsColumnDivider:VT100GridCoordMake(idx, coord.y)]) {
            if (idx < coord.x && idx > dividerBefore) {
                dividerBefore = (int)idx + 1;
            } else if (idx > coord.x) {
                dividerAfter = (int)idx;
                *stop = YES;
            }
        }
    }];
    if (dividerAfter == -1) {
        dividerAfter = [_dataSource width];
    }
    _logicalWindow.location = dividerBefore;
    _logicalWindow.length = dividerAfter - dividerBefore;
}

- (VT100GridWindowedRange)rangeForWordAt:(VT100GridCoord)location {
    iTermTextExtractorClass theClass =
        [self classForCharacterString:[self stringForCharacterAt:location]];

    __block VT100GridCoord end = location;
    [self searchFrom:location forward:YES forCharacterMatchingFilter:^BOOL (screen_char_t theChar,
                                                                            VT100GridCoord coord) {
        NSString *string = [self stringForCharacter:theChar];
        BOOL isInWord = ([self classForCharacterString:string] == theClass);
        if (isInWord) {
            end = coord;
        }
        return !isInWord;
    }];
    
    VT100GridCoord predecessor = [self predecessorOfCoord:location];
    __block VT100GridCoord start = location;
    [self searchFrom:location forward:NO forCharacterMatchingFilter:^BOOL (screen_char_t theChar,
                                                                           VT100GridCoord coord) {
        NSString *string = [self stringForCharacter:theChar];
        BOOL isInWord = ([self classForCharacterString:string] == theClass);
        if (isInWord) {
            start = coord;
        }
        return !isInWord;
    }];
    
    return [self windowedRangeWithRange:VT100GridCoordRangeMake(start.x,
                                                                start.y,
                                                                end.x + 1,
                                                                end.y)];
}

- (NSString *)stringForCharacter:(screen_char_t)theChar {
    unichar temp[kMaxParts];
    int length = ExpandScreenChar(&theChar, temp);
    return [NSString stringWithCharacters:temp length:length];
}

- (NSString *)stringForCharacterAt:(VT100GridCoord)location {
    screen_char_t *theLine = [_dataSource getLineAtIndex:location.y];
    unichar temp[kMaxParts];
    int length = ExpandScreenChar(theLine + location.x, temp);
    return [NSString stringWithCharacters:temp length:length];
}

- (NSDictionary *)smartSelectionAt:(VT100GridCoord)location
                         withRules:(NSArray *)rules
                    actionRequired:(BOOL)actionRequired
                             range:(VT100GridWindowedRange *)range
                  ignoringNewlines:(BOOL)ignoringNewlines {
    int targetOffset;
    const int numLines = 2;
    NSMutableArray* coords = [NSMutableArray arrayWithCapacity:numLines * _logicalWindow.length];
    NSString *textWindow = [self textAround:location
                                     radius:2
                               targetOffset:&targetOffset
                                     coords:coords
                           ignoringNewlines:ignoringNewlines];
    
    NSArray* rulesArray = rules ?: [SmartSelectionController defaultRules];
    const int numRules = [rulesArray count];
    
    NSMutableDictionary* matches = [NSMutableDictionary dictionaryWithCapacity:13];
    int numCoords = [coords count];
    
    BOOL debug = [SmartSelectionController logDebugInfo];
    if (debug) {
        NSLog(@"Perform smart selection on text: %@", textWindow);
    }
    for (int j = 0; j < numRules; j++) {
        NSDictionary *rule = [rulesArray objectAtIndex:j];
        if (actionRequired && [[SmartSelectionController actionsInRule:rule] count] == 0) {
            DLog(@"Ignore smart selection rule because it has no action: %@", rule);
            continue;
        }
        NSString *regex = [SmartSelectionController regexInRule:rule];
        double precision = [SmartSelectionController precisionInRule:rule];
        if (debug) {
            NSLog(@"Try regex %@", regex);
        }
        for (int i = 0; i <= targetOffset; i++) {
            NSString* substring = [textWindow substringWithRange:NSMakeRange(i, [textWindow length] - i)];
            NSError* regexError = nil;
            NSRange temp = [substring rangeOfRegex:regex
                                           options:0
                                           inRange:NSMakeRange(0, [substring length])
                                           capture:0
                                             error:&regexError];
            if (temp.location != NSNotFound) {
                if (i + temp.location <= targetOffset && i + temp.location + temp.length > targetOffset) {
                    NSString* result = [substring substringWithRange:temp];
                    double score = precision * (double) temp.length;
                    SmartMatch* oldMatch = [matches objectForKey:result];
                    if (!oldMatch || score > oldMatch.score) {
                        SmartMatch* match = [[[SmartMatch alloc] init] autorelease];
                        match.score = score;
                        VT100GridCoord startCoord = [[coords objectAtIndex:i + temp.location] gridCoordValue];
                        VT100GridCoord endCoord = [[coords objectAtIndex:MIN(numCoords - 1, i + temp.location + temp.length)] gridCoordValue];
                        match.startX = startCoord.x;
                        match.absStartY = startCoord.y + [_dataSource totalScrollbackOverflow];
                        match.endX = endCoord.x;
                        match.absEndY = endCoord.y + [_dataSource totalScrollbackOverflow];
                        match.rule = rule;
                        [matches setObject:match forKey:result];
                        
                        if (debug) {
                            NSLog(@"Add result %@ at %d,%lld -> %d,%lld with score %lf", result,
                                  match.startX, match.absStartY, match.endX, match.absEndY,
                                  match.score);
                        }
                    }
                    i += temp.location + temp.length - 1;
                } else {
                    i += temp.location;
                }
            } else {
                break;
            }
        }
    }
    
    if ([matches count]) {
        NSArray* sortedMatches = [[matches allValues] sortedArrayUsingSelector:@selector(compare:)];
        SmartMatch* bestMatch = [sortedMatches lastObject];
        if (debug) {
            NSLog(@"Select match with score %lf", bestMatch.score);
        }
        VT100GridCoordRange theRange =
            VT100GridCoordRangeMake(bestMatch.startX,
                                    bestMatch.absStartY - [_dataSource totalScrollbackOverflow],
                                    bestMatch.endX,
                                    bestMatch.absEndY - [_dataSource totalScrollbackOverflow]);
        *range = [self windowedRangeWithRange:theRange];
        return bestMatch.rule;
    } else {
        if (debug) {
            NSLog(@"No matches. Fall back on word selection.");
        }
        // Fall back on word selection
        *range = [self rangeForWordAt:location];
        return nil;
    }
}

// Returns the class for a character.
- (iTermTextExtractorClass)classForCharacterString:(NSString *)character {
    NSRange range;

    if (character.length == 1 && [character characterAtIndex:0] == TAB_FILLER) {
        return kTextExtractorClassWhitespace;
    }
    range = [character rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
    if (range.length == character.length) {
        return kTextExtractorClassWhitespace;
    }
    
    range = [character rangeOfCharacterFromSet:[NSCharacterSet alphanumericCharacterSet]];
    if (range.length == character.length) {
        return kTextExtractorClassWord;
    }
    
    range = [[[PreferencePanel sharedInstance] wordChars] rangeOfString:character];
    if (range.length == character.length) {
        return kTextExtractorClassWord;
    }
    
    return kTextExtractorClassOther;
}

- (VT100GridWindowedRange)rangeOfParentheticalSubstringAtLocation:(VT100GridCoord)location {
    NSString *paren = [self stringForCharacterAt:location];
    NSDictionary *forwardMatches = @{ @"(": @")",
                                      @"[": @"]",
                                      @"{": @"}" };
    NSString *match = nil;
    BOOL forward;
    for (NSString *open in forwardMatches) {
        NSString *close = forwardMatches[open];
        if ([paren isEqualToString:open]) {
            match = close;
            forward = YES;
            break;
        }
        if ([paren isEqualToString:close]) {
            match = open;
            forward = NO;
            break;
        }
    }
    if (!match) {
        return [self windowedRangeWithRange:VT100GridCoordRangeMake(-1, -1, -1, -1)];
    }
    
    __block int level = 0;
    __block int left = 10000;
    VT100GridCoord end = [self searchFrom:location
                                  forward:forward
                             forCharacterMatchingFilter:^BOOL (screen_char_t theChar,
                                                               VT100GridCoord coord) {
                                 if (--left == 0) {
                                     return YES;
                                 }
                                 NSString *string = [self stringForCharacter:theChar];
                                 if ([string isEqualToString:match]) {
                                     level--;
                                 } else if ([string isEqualToString:paren]) {
                                     level++;
                                 }
                                 return level == 0;
                             }];
    if (left == 0) {
        return [self windowedRangeWithRange:VT100GridCoordRangeMake(-1, -1, -1, -1)];
    } else if (forward) {
        return [self windowedRangeWithRange:VT100GridCoordRangeMake(location.x,
                                                                    location.y,
                                                                    end.x + 1,
                                                                    end.y)];
    } else {
        return [self windowedRangeWithRange:VT100GridCoordRangeMake(end.x,
                                                                    end.y,
                                                                    location.x + 1,
                                                                    location.y)];
    }
}

- (VT100GridCoord)successorOfCoord:(VT100GridCoord)coord {
    coord.x++;
    int xLimit = [self xLimit];
    if (coord.x >= xLimit) {
        coord.x = _logicalWindow.location;
        coord.y++;
        if (coord.y >= [_dataSource numberOfLines]) {
            return VT100GridCoordMake(xLimit - 1, [_dataSource numberOfLines] - 1);
        }
    }
    return coord;
}

- (VT100GridCoord)predecessorOfCoord:(VT100GridCoord)coord {
    coord.x--;
    if (coord.x < _logicalWindow.location) {
        coord.x = [self xLimit] - 1;
        coord.y--;
        if (coord.y < 0) {
            return VT100GridCoordMake(_logicalWindow.location, 0);
        }
    }
    return coord;
}

- (VT100GridCoord)searchFrom:(VT100GridCoord)start
                     forward:(BOOL)forward
  forCharacterMatchingFilter:(BOOL (^)(screen_char_t, VT100GridCoord))block {
    VT100GridCoord coord = start;
    screen_char_t *theLine;
    int y = -1;
    while (1) {
        if (y != coord.y) {
            theLine = [_dataSource getLineAtIndex:coord.y];
            y = coord.y;
        }
        BOOL stop = block(theLine[coord.x], coord);
        if (stop) {
            return coord;
        }
        VT100GridCoord prev = coord;
        if (forward) {
            coord = [self successorOfCoord:coord];
        } else {
            coord = [self predecessorOfCoord:coord];
        }
        if (VT100GridCoordEquals(coord, prev)) {
            return VT100GridCoordMake(-1, -1);
        }
    }
}

- (NSString *)textAround:(VT100GridCoord)coord
                  radius:(int)radius
            targetOffset:(int *)targetOffset
                  coords:(NSMutableArray *)coords
        ignoringNewlines:(BOOL)ignoringNewlines {
    int trueWidth = [_dataSource width];
    NSMutableString* joinedLines =
        [NSMutableString stringWithCapacity:radius * _logicalWindow.length];
    
    *targetOffset = -1;
    
    // If rejectAtHardEol is true, then stop when you hit a hard EOL.
    // If false, stop when you hit a hard EOL that has an unused cell before it,
    // otherwise keep going.
    BOOL rejectAtHardEol = !ignoringNewlines;
    int xMin, xMax;
    xMin = _logicalWindow.location;
    xMax = [self xLimit];
    
    // Any text preceding a hard line break on a line before |y| should not be considered.
    int firstLine = coord.y - radius;
    for (int i = coord.y - radius; i < coord.y; i++) {
        if (i < 0 || i >= [_dataSource numberOfLines]) {
            continue;
        }
        screen_char_t* theLine = [_dataSource getLineAtIndex:i];
        if (xMax == trueWidth && i < coord.y && theLine[trueWidth].code == EOL_HARD) {
            if (rejectAtHardEol || theLine[trueWidth - 1].code == 0) {
                firstLine = i + 1;
            }
        }
    }
    
    for (int i = MAX(0, firstLine); i <= coord.y + radius && i < [_dataSource numberOfLines]; i++) {
        screen_char_t* theLine = [_dataSource getLineAtIndex:i];
        if (i < coord.y && theLine[trueWidth].code == EOL_HARD) {
            if (rejectAtHardEol || theLine[trueWidth - 1].code == 0) {
                continue;
            }
        }
        unichar* backingStore;
        int* deltas;
        NSString* string = ScreenCharArrayToString(theLine,
                                                   xMin,
                                                   MIN(EffectiveLineLength(theLine, trueWidth),
                                                       xMax),
                                                   &backingStore,
                                                   &deltas);
        int o = 0;
        for (int k = 0; k < [string length]; k++) {
            o = k + deltas[k];
            VT100GridCoord cellCoord = VT100GridCoordMake(o + xMin, i);
            if (*targetOffset == -1 && cellCoord.y == coord.y && cellCoord.x >= coord.x) {
                *targetOffset = k + [joinedLines length];
            }
            [coords addObject:[NSValue valueWithGridCoord:VT100GridCoordMake(o + xMin, i)]];
        }
        [joinedLines appendString:string];
        free(deltas);
        free(backingStore);
        
        o++;
        if (xMax == trueWidth && i >= coord.y && theLine[trueWidth].code == EOL_HARD) {
            if (rejectAtHardEol || theLine[trueWidth - 1].code == 0) {
                [coords addObject:[NSValue valueWithGridCoord:VT100GridCoordMake(o, i)]];
                break;
            }
        }
    }
    // TODO: What if it's multiple lines ending in a soft eol and the selection goes to the end?
    return joinedLines;
}

- (VT100GridWindowedRange)rangeForWrappedLineEncompassing:(VT100GridCoord)coord
                                     respectContinuations:(BOOL)respectContinuations {
    int start = [self lineNumberWithStartOfWholeLineIncludingLine:coord.y
                                             respectContinuations:respectContinuations];
    int end = [self lineNumberWithEndOfWholeLineIncludingLine:coord.y
                                             respectContinuations:respectContinuations];
    return [self windowedRangeWithRange:VT100GridCoordRangeMake(_logicalWindow.location,
                                                                start,
                                                                [self xLimit],
                                                                end)];
}

- (NSString *)contentInRange:(VT100GridWindowedRange)windowedRange
                         pad:(BOOL)pad
          includeLastNewline:(BOOL)includeLastNewline
      trimTrailingWhitespace:(BOOL)trimSelectionTrailingSpaces
                cappedAtSize:(int)maxBytes
{
    DLog(@"Find selected text in range %@ pad=%d, includeLastNewline=%d, trim=%d",
         VT100GridWindowedRangeDescription(windowedRange), (int)pad, (int)includeLastNewline,
         (int)trimSelectionTrailingSpaces);
    NSMutableString* result = [NSMutableString string];
    if (maxBytes < 0) {
        maxBytes = INT_MAX;
    }
    [self enumerateCharsInRange:windowedRange
                      charBlock:^(screen_char_t theChar, VT100GridCoord coord) {
                          if (theChar.code == TAB_FILLER) {
                              // Convert orphan tab fillers (those without a subsequent
                              // tab character) into spaces.
                              if ([self isTabFillerOrphanAt:coord]) {
                                  [result appendString:@" "];
                              }
                          } else if (theChar.code == 0 && !theChar.complexChar) {
                              [result appendString:@" "];
                          } else if (theChar.code != DWC_RIGHT &&
                                     theChar.code != DWC_SKIP) {
                              // Normal character
                              [result appendString:ScreenCharToStr(&theChar)];
                          }
                      }
                       eolBlock:^(unichar code, int numPreceedingNulls, int line) {
                               // If there is no text after this, insert a hard line break.
                               if (pad) {
                                   for (int i = 0; i < numPreceedingNulls; i++) {
                                       [result appendString:@" "];
                                   }
                               }
                               if (code == EOL_HARD &&
                                   (includeLastNewline || line < windowedRange.coordRange.end.y)) {
                                   if (trimSelectionTrailingSpaces) {
                                       [result trimTrailingWhitespace];
                                   }
                                   if (includeLastNewline) {
                                       [result appendString:@"\n"];
                                   }
                               }
                           }];
    
    if (trimSelectionTrailingSpaces) {
        [result stringByTrimmingTrailingWhitespace];
    }
    return result;
}


- (NSAttributedString *)attributedContentInRange:(VT100GridWindowedRange)range
                                             pad:(BOOL)pad
                               attributeProvider:(NSDictionary *(^)(screen_char_t))attributeProvider
{
    int width = [_dataSource width];
    NSMutableAttributedString* result = [[[NSMutableAttributedString alloc] init] autorelease];
    [self enumerateCharsInRange:range
                      charBlock:^(screen_char_t theChar, VT100GridCoord coord) {
                          if (theChar.code == 0 && !theChar.complexChar) {
                              [result iterm_appendString:@" "];
                          } else if (theChar.code == TAB_FILLER) {
                              // Convert orphan tab fillers (those without a subsequent
                              // tab character) into spaces.
                              if ([self isTabFillerOrphanAt:coord]) {
                                  [result iterm_appendString:@" "
                                              withAttributes:attributeProvider(theChar)];
                              }
                          } else if (theChar.code != DWC_RIGHT &&
                                     theChar.code != DWC_SKIP) {
                              // Normal character
                              [result iterm_appendString:ScreenCharToStr(&theChar)
                                          withAttributes:attributeProvider(theChar)];
                          }
                      }
                       eolBlock:^(unichar code, int numPreceedingNulls, int line) {
                           if (pad) {
                               for (int i = 0; i < numPreceedingNulls; i++) {
                                   [result iterm_appendString:@" "
                                               withAttributes:attributeProvider([self defaultChar])];
                               }
                           }
                           [result iterm_appendString:@"\n"
                                       withAttributes:attributeProvider([self defaultChar])];
                       }];
    
    return result;
}

#pragma mark - Private

- (VT100GridCoord)canonicalizedLocation:(VT100GridCoord)location {
    int xLimit = [self xLimit];
    if (location.x >= xLimit) {
        location.x = xLimit - 1;
    }
    return location;
}

- (int)lineNumberWithStartOfWholeLineIncludingLine:(int)y
                              respectContinuations:(BOOL)respectContinuations
{
    int i = y;
    while (i > 0 && [self lineHasSoftEol:i - 1 respectContinuations:respectContinuations]) {
        i--;
    }
    return i;
}

- (int)lineNumberWithEndOfWholeLineIncludingLine:(int)y
                            respectContinuations:(BOOL)respectContinuations
{
    int i = y + 1;
    int maxY = [_dataSource numberOfLines];
    while (i < maxY && [self lineHasSoftEol:i - 1 respectContinuations:respectContinuations]) {
        i++;
    }
    return i - 1;
}

- (BOOL)lineHasSoftEol:(int)y respectContinuations:(BOOL)respectContinuations
{
    screen_char_t *theLine = [_dataSource getLineAtIndex:y];
    int width = [_dataSource width];
    if ([self xLimit] != width) {
        return YES;
    }
    if (respectContinuations) {
        return (theLine[width].code == EOL_SOFT ||
                (theLine[width - 1].code == '\\' && !theLine[width - 1].complexChar));
    } else {
        return theLine[width].code == EOL_SOFT;
    }
}

- (BOOL)isTabFillerOrphanAt:(VT100GridCoord)start {
    __block BOOL result = YES;
    [self searchFrom:start
             forward:YES
        forCharacterMatchingFilter:^BOOL (screen_char_t theChar, VT100GridCoord coord) {
            if (coord.y != start.y) {
                result = YES;
                return YES;
            }
            if (theChar.code != TAB_FILLER) {
                result = (theChar.code != '\t');
                return YES;
            }
            return NO;
        }];
    return result;
}

- (int)lengthOfLine:(int)line {
    screen_char_t *theLine = [_dataSource getLineAtIndex:line];
    int x;
    for (x = [_dataSource width] - 1; x >= 0; x--) {
        if (theLine[x].code || theLine[x].complexChar) {
            break;
        }
    }
    return x + 1;
}

- (NSString *)wrappedStringAt:(VT100GridCoord)coord
                      forward:(BOOL)forward
          respectHardNewlines:(BOOL)respectHardNewlines
{
    if ([self xLimit] != [_dataSource width]) {
        respectHardNewlines = NO;
    }
    VT100GridWindowedRange range;
    if (respectHardNewlines) {
        range = [self rangeForWrappedLineEncompassing:coord respectContinuations:YES];
    } else {
        VT100GridCoordRange coordRange =
            VT100GridCoordRangeMake(_logicalWindow.location,
                                    MAX(0, coord.y - 10),
                                    [self xLimit],
                                    MIN([_dataSource numberOfLines] - 1, coord.y + 10));
        range = VT100GridWindowedRangeMake(coordRange, 0, 0);
    }
    if (forward) {
        range.coordRange.start = coord;
        if (VT100GridCoordOrder(range.coordRange.start,
                                range.coordRange.end) != NSOrderedAscending) {
            return @"";
        }
    } else {
        // This doesn't include the boundary character when returning a prefix because we don't
        // want it twice when getting the prefix and suffix at the same coord.
        range.coordRange.end = coord;
        if (VT100GridCoordOrder(range.coordRange.start,
                                range.coordRange.end) != NSOrderedAscending) {
            return @"";
        }
    }
    NSString *content =
            [self contentInRange:range
                             pad:NO
              includeLastNewline:NO
          trimTrailingWhitespace:NO
                    cappedAtSize:-1];
    return [content stringByReplacingOccurrencesOfString:@"\n" withString:@""];
}

- (void)enumerateCharsInRange:(VT100GridWindowedRange)range
                    charBlock:(void (^)(screen_char_t theChar, VT100GridCoord coord))charBlock
                     eolBlock:(void (^)(unichar code, int numPreceedingNulls, int line))eolBlock {
    int width = [_dataSource width];
    int startx = VT100GridWindowedRangeStart(range).x;
    int endx = range.columnWindow.length ? range.columnWindow.location + range.columnWindow.length
                                         : [_dataSource width];
    int bound = [_dataSource numberOfLines] - 1;
    BOOL sendEOL = (range.columnWindow.length == 0);
    int left = range.columnWindow.length ? range.columnWindow.location : 0;
    for (int y = MAX(0, range.coordRange.start.y); y <= MIN(bound, range.coordRange.end.y); y++) {
        if (y == range.coordRange.end.y) {
            endx = range.columnWindow.length ? VT100GridWindowedRangeEnd(range).x
                                             : range.coordRange.end.x;
        }
        int length = [self lengthOfLine:y];
        screen_char_t *theLine = [_dataSource getLineAtIndex:y];
        const int lineLimit = MIN(endx, length);
        for (int i = MAX(range.columnWindow.location, startx); i < lineLimit; i++) {
            if (charBlock) {
                charBlock(theLine[i], VT100GridCoordMake(i, y));
            }
        }
        if (sendEOL &&
            (y < range.coordRange.end.y || VT100GridWindowedRangeEnd(range).x == width)) {
            if (eolBlock) {
                eolBlock(theLine[width].code, width - length, y);
            }
        }
        startx = left;
    }
}

- (NSIndexSet *)possibleColumnDividerIndexesAround:(VT100GridCoord)coord {
    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
    VT100GridCoordRange theRange =
        VT100GridCoordRangeMake(0, coord.y, [_dataSource width], coord.y);
    [self enumerateCharsInRange:VT100GridWindowedRangeMake(theRange, 0, 0)
                      charBlock:^(screen_char_t theChar, VT100GridCoord theCoord) {
                          if (!theChar.complexChar && theChar.code == '|') {
                              [indexes addIndex:theCoord.x];
                          }
                      }
                       eolBlock:NULL];
    return indexes;
}

- (BOOL)coordContainsColumnDivider:(VT100GridCoord)coord {
    int n = 1;
    for (int y = coord.y - 1; y >= 0 && y > coord.y - kNumCharsToSearchForDivider; y--) {
        if ([[self stringForCharacterAt:VT100GridCoordMake(coord.x, y)] isEqualToString:@"|"]) {
            n++;
        } else {
            break;
        }
    }
    int limit = [_dataSource numberOfLines];
    for (int y = coord.y + 1; y < limit && y < coord.y + kNumCharsToSearchForDivider; y++) {
        if ([[self stringForCharacterAt:VT100GridCoordMake(coord.x, y)] isEqualToString:@"|"]) {
            n++;
        } else {
            break;
        }
    }
    return n >= kNumCharsToSearchForDivider;
}

- (int)xLimit {
    return _logicalWindow.location + _logicalWindow.length;
}

- (screen_char_t)defaultChar {
    screen_char_t defaultChar = { 0 };
    defaultChar.foregroundColorMode = ColorModeAlternate;
    defaultChar.foregroundColor = ALTSEM_FG_DEFAULT;
    defaultChar.backgroundColorMode = ColorModeAlternate;
    defaultChar.backgroundColor = ALTSEM_BG_DEFAULT;
    return defaultChar;
}

- (VT100GridWindowedRange)windowedRangeWithRange:(VT100GridCoordRange)range {
    VT100GridWindowedRange windowedRange;
    windowedRange.coordRange = range;
    windowedRange.columnWindow = _logicalWindow;
    return windowedRange;
}

@end
