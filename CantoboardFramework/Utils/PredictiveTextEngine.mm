//
//  NGramTable.m
//  CantoboardFramework
//
//  Created by Alex Man on 12/20/21.
//

#import <Foundation/Foundation.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <algorithm>
#include <set>
#include <unordered_map>
#include <string>

#import <CocoaLumberjack/DDLogMacros.h>
static const DDLogLevel ddLogLevel = DDLogLevelDebug;

#include "marisa/trie.h"
#include "NGram.h"
#include "Utils.h"

static short kMaxNumberOfTerms = 30;

using namespace std;
using namespace marisa;

@interface NSString (Unicode)
@property(readonly) NSUInteger lengthOfComposedChars;
@end

@implementation NSString (Unicode)
-(size_t) lengthOfComposedChars {
    __block size_t count = 0;
    [self enumerateSubstringsInRange:NSMakeRange(0, [self length])
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString * _Nullable substring, NSRange substringRange, NSRange enclosingRange, BOOL * _Nonnull stop) {
        count++;
    }];
    return count;
}
@end

@implementation PredictiveTextEngine {
    int fd;
    size_t fileSize;
    char* data;
    const NGramHeader* header;
    const Weight* weights;
    Trie trie;
}

- (void)dealloc {
    [self close];
}

- (void)close {
    if (data != nullptr && data != MAP_FAILED) {
        header = nullptr;
        weights = nullptr;
        DDLogInfo(@"Predictive text engine unmapping ngram table from memory...");
        munmap(data, fileSize);
        data = nullptr;
        DDLogInfo(@"Predictive text engine unmapped ngram table from memory.");
    }
    if (fd != -1) {
        close(fd);
        fd = -1;
        fileSize = 0;
        DDLogInfo(@"Predictive text engine closed ngram.");
    }
}

- (id)init:(NSString*) ngramFilePath {
    self = [super init];
    
    fd = -1;
    fileSize = 0;
    data = nullptr;
    header = nullptr;
    weights = nullptr;
    
    fd = open([ngramFilePath UTF8String], O_RDONLY);
    
    DDLogInfo(@"Predictive text engine opening ngram...");
    if (fd == -1) {
        NSString *s = [NSString stringWithFormat:@"Failed to open %@ ngram file. %s", ngramFilePath, strerror(errno)];
        DDLogInfo(@"%@", s);
        return self;
    }
    
    struct stat buf;
    fstat(fd, &buf);
    fileSize = buf.st_size;
    data = (char*)mmap(nullptr, fileSize, PROT_READ, MAP_SHARED, fd, 0);
    
    DDLogInfo(@"Predictive text engine mapping ngram table into memory...");
    if (data == MAP_FAILED) {
        NSString *s = [NSString stringWithFormat:@"Predictive text engine failed to mmap ngram file. %s", strerror(errno)];
        DDLogInfo(@"%@", s);
        [self close];
        return self;
    } else {
        header = (NGramHeader*)data;
        
        if (header->version != 0) {
            DDLogInfo(@"Predictive text engine doesn't support ngram file version %d.", header->version);
            [self close];
            return self;
        }
    }
    
    const NGramSectionHeader& weightSectionHeader = header->sections[weight];
    weights = (Weight*)(data + weightSectionHeader.dataOffset);
    
    const NGramSectionHeader& trieSectionHeader = header->sections[NGramSectionId::trie];
    trie.map(data + trieSectionHeader.dataOffset, trieSectionHeader.dataSizeInBytes);
    
    DDLogInfo(@"Predictive text engine loaded.");
    return self;
}



- (NSArray*)predict:(NSString*) context {
    if (header == nullptr) {
        return [[NSArray alloc] init];
    }
    // header->maxN indicates the max length of suggested text.
    // That means we should search for suffix with length up to max length-1 of the context.
    // To start the search, move the pointer backward from the end of the string by max length-1 times.
    NSUInteger backward = header->maxN - 1;
    NSUInteger currentIndex = context.length;
    while (currentIndex > 0 && backward > 0) {
        NSRange curCharRange = [context rangeOfComposedCharacterSequenceAtIndex:currentIndex - 1];
        currentIndex = curCharRange.location;
        backward--;
    }
    
    // Now we are pointing to the beginning of the longest suffix. Search for the whole suffix.
    // Then move forward by 1 composed char then search again.
    // e.g. let context = abcdefg, max length = 6,
    // The first iteration would search for cdefg, then defg, etc. At the end it would search for g.
    NSMutableArray *results = [[NSMutableArray alloc] init];
    NSMutableSet *dedupSet = [[NSMutableSet alloc] init];
    DDLogInfo(@"PredictiveTextEngine context: %@ currentIndex: %lu", context, (unsigned long)currentIndex);
    while (currentIndex < context.length) {
        NSString *prefixToSearch = [context substringWithRange:NSMakeRange(currentIndex, context.length - currentIndex)];
        NSRange curCharRange = [context rangeOfComposedCharacterSequenceAtIndex:currentIndex];
        currentIndex += curCharRange.length;
        DDLogInfo(@"PredictiveTextEngine searching prefix: %@", prefixToSearch);
        [self search:prefixToSearch output:results dedupSet:dedupSet];
    }
    
    NSArray *finalResults = [results subarrayWithRange:NSMakeRange(0, min((NSUInteger)kMaxNumberOfTerms, [results count]))];
    return finalResults;
}

- (void)search:(NSString*) prefix output:(NSMutableArray*) output dedupSet:(NSMutableSet*) dedupSet {
    if (header == nullptr) {
        return;
    }
    auto cmp = [&](const pair<size_t, string>& key1, const pair<size_t, string>& key2) {
        return weights[key1.first] > weights[key2.first];
    };
    set<pair<size_t, string>, decltype(cmp)> orderedResults(cmp);

    Agent trieAgent;
    trieAgent.set_query([prefix UTF8String]);
    while (trie.predictive_search(trieAgent)) {
        const Key& key = trieAgent.key();
        string keyText = string(key.ptr(), key.length());
        orderedResults.insert({ key.id(), keyText });
    }
    
    for (auto it = orderedResults.begin(); it != orderedResults.end(); ++it) {
        const auto& key = it->second;
        NSString *fullText = [[NSString alloc] initWithBytes:key.c_str()
                                                      length:key.length()
                                                    encoding:NSUTF8StringEncoding];
        if (fullText.lengthOfComposedChars != prefix.lengthOfComposedChars + 1) continue;
        // DDLogInfo(@"PredictiveTextEngine fullText: %@", fullText);
        NSRange lastCharRange = [fullText rangeOfComposedCharacterSequenceAtIndex:fullText.length - 1];
        NSString *lastChar = [fullText substringWithRange:lastCharRange];
        NSString *toAdd = lastChar;
        if (![dedupSet containsObject:toAdd]) {
            [output addObject:toAdd];
            [dedupSet addObject:toAdd];
        }
    }
}

@end
