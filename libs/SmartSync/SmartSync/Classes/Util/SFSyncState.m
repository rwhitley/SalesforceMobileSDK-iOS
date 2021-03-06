/*
 Copyright (c) 2014-present, salesforce.com, inc. All rights reserved.
 
 Redistribution and use of this software in source and binary forms, with or without modification,
 are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright notice, this list of conditions
 and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of
 conditions and the following disclaimer in the documentation and/or other materials provided
 with the distribution.
 * Neither the name of salesforce.com, inc. nor the names of its contributors may be used to
 endorse or promote products derived from this software without specific prior written
 permission of salesforce.com, inc.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY
 WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "SFSyncState.h"
#import "SFSyncDownTarget.h"
#import "SFSyncOptions.h"
#import "SFSyncUpTarget.h"
#import <SmartStore/SFSmartStore.h>
#import <SmartStore/SFSoupIndex.h>
#import <SmartStore/SFQuerySpec.h>
#import <SalesforceSDKCommon/SFJsonUtils.h>

// soups and soup fields
NSString * const kSFSyncStateSyncsSoupName = @"syncs_soup";
NSString * const kSFSyncStateSyncsSoupSyncType = @"type";
NSString * const kSFSyncStateSyncsSoupSyncName = @"name";

// Fields in dict representation
NSString * const kSFSyncStateId = @"_soupEntryId";
NSString * const kSFSyncStateName = @"name";
NSString * const kSFSyncStateType = @"type";
NSString * const kSFSyncStateTarget = @"target";
NSString * const kSFSyncStateSoupName = @"soupName";
NSString * const kSFSyncStateOptions = @"options";
NSString * const kSFSyncStateStatus = @"status";
NSString * const kSFSyncStateProgress = @"progress";
NSString * const kSFSyncStateTotalSize = @"totalSize";
NSString * const kSFSyncStateMaxTimeStamp = @"maxTimeStamp";
NSString * const kSFSyncStateStartTime = @"startTime";
NSString * const kSFSyncStateEndTime = @"endTime";
NSString * const kSFSyncStateError = @"error";

// Possible value for sync type
NSString * const kSFSyncStateTypeDown = @"syncDown";
NSString * const kSFSyncStateTypeUp = @"syncUp";

// Possible value for sync status
NSString * const kSFSyncStateStatusNew = @"NEW";
NSString * const kSFSyncStateStatusStopped = @"STOPPED";
NSString * const kSFSyncStateStatusRunning = @"RUNNING";
NSString * const kSFSyncStateStatusDone = @"DONE";
NSString * const kSFSyncStateStatusFailed = @"FAILED";

// Possible value for merge mode
NSString * const kSFSyncStateMergeModeOverwrite = @"OVERWRITE";
NSString * const kSFSyncStateMergeModeLeaveIfChanged = @"LEAVE_IF_CHANGED";

@interface SFSyncState ()

@property (nonatomic, readwrite) NSInteger syncId;
@property (nonatomic, readwrite) NSString* name;
@property (nonatomic, readwrite) SFSyncStateSyncType type;
@property (nonatomic, strong, readwrite) NSString* soupName;
@property (nonatomic, strong, readwrite) SFSyncTarget* target;
@property (nonatomic, strong, readwrite) SFSyncOptions* options;
@property (nonatomic, readwrite) NSInteger startTime;
@property (nonatomic, readwrite) NSInteger endTime;

@end

@implementation SFSyncState

@synthesize error = _error;

# pragma mark - Setup

+ (void) setupSyncsSoupIfNeeded:(SFSmartStore*)store {

    if ([store soupExists:kSFSyncStateSyncsSoupName] && [store indicesForSoup:kSFSyncStateSyncsSoupName].count == 3) {
        return;
    }
    NSArray* indexSpecs = @[
            [[SFSoupIndex alloc] initWithPath:kSFSyncStateSyncsSoupSyncType indexType:kSoupIndexTypeJSON1 columnName:nil],
            [[SFSoupIndex alloc] initWithPath:kSFSyncStateSyncsSoupSyncName indexType:kSoupIndexTypeJSON1 columnName:nil],
            [[SFSoupIndex alloc] initWithPath:kSFSyncStateStatus indexType:kSoupIndexTypeJSON1 columnName:nil]
    ];

    // Syncs soup exists but doesn't have all the required indexes
    if ([store soupExists:kSFSyncStateSyncsSoupName]) {
        [store alterSoup:kSFSyncStateSyncsSoupName withIndexSpecs:indexSpecs reIndexData:YES /* reindexing to json1 is quick*/];
    }
    // Syncs soup does not exist
    else {
        [store registerSoup:kSFSyncStateSyncsSoupName withIndexSpecs:indexSpecs error:nil];
    }
}

+ (void) cleanupSyncsSoupIfNeeded:(SFSmartStore*)store {
    NSArray<SFSyncState*>* syncs = [self getSyncsWithStatus:store status:SFSyncStateStatusRunning];
    for (SFSyncState* sync in syncs) {
        sync.status = SFSyncStateStatusStopped;
        [sync save:store];
    }
}

+ (NSArray<SFSyncState*>*)getSyncsWithStatus:(SFSmartStore*)store status:(SFSyncStateStatus)status {
    NSMutableArray<SFSyncState*>* syncs = [NSMutableArray new];
    NSString* smartSql = [NSString stringWithFormat:@"select {%1$@:%2$@} from {%1$@} where {%1$@:%3$@} = '%4$@'", kSFSyncStateSyncsSoupName, @"_soup", kSFSyncStateStatus, [SFSyncState syncStatusToString:status]];
    SFQuerySpec* query = [SFQuerySpec newSmartQuerySpec:smartSql withPageSize:INT_MAX];
    NSArray* rows = [store queryWithQuerySpec:query pageIndex:0 error:nil];
    for (NSArray* row in rows) {
        [syncs addObject:[SFSyncState newFromDict:row[0]]];
    }
    return syncs;
}


#pragma mark - Factory methods

+ (SFSyncState *)newSyncDownWithOptions:(SFSyncOptions *)options target:(SFSyncDownTarget *)target soupName:(NSString *)soupName name:(NSString *)name store:(SFSmartStore *)store {
    NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithDictionary:@{
            kSFSyncStateType: kSFSyncStateTypeDown,
            kSFSyncStateTarget: [target asDict],
            kSFSyncStateSoupName: soupName,
            kSFSyncStateOptions: [options asDict],
            kSFSyncStateStatus: kSFSyncStateStatusNew,
            kSFSyncStateMaxTimeStamp: @(-1),
            kSFSyncStateProgress: @(0),
            kSFSyncStateTotalSize: @(-1),
            kSFSyncStateStartTime: @(0),
            kSFSyncStateEndTime: @(0),
            kSFSyncStateError: @""
    }];
    if (name) dict[kSFSyncStateName] = name;
    
    if (name && [SFSyncState byName:name store:store]) {
        [SFSDKSmartSyncLogger e:[self class] format:@"Failed to create sync down: there is already a sync with name:%@", name];
        return nil;
    }
    
    NSArray* savedDicts = [store upsertEntries:@[ dict ] toSoup:kSFSyncStateSyncsSoupName];
    SFSyncState* sync = [SFSyncState newFromDict:savedDicts[0]];
    return sync;
}

+ (SFSyncState*)newSyncUpWithOptions:(SFSyncOptions *)options soupName:(NSString *)soupName store:(SFSmartStore *)store {
    SFSyncUpTarget *target = [SFSyncUpTarget newFromDict:nil];
    return [self newSyncUpWithOptions:options target:target soupName:soupName name:nil store:store];
}

+ (SFSyncState *)newSyncUpWithOptions:(SFSyncOptions *)options target:(SFSyncUpTarget *)target soupName:(NSString *)soupName name:(NSString *)name store:(SFSmartStore *)store {
    NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithDictionary:@{
            kSFSyncStateType: kSFSyncStateTypeUp,
            kSFSyncStateTarget: [target asDict],
            kSFSyncStateSoupName: soupName,
            kSFSyncStateOptions: [options asDict],
            kSFSyncStateStatus: kSFSyncStateStatusNew,
            kSFSyncStateProgress: @(0),
            kSFSyncStateTotalSize: @(-1),
            kSFSyncStateStartTime: @(0),
            kSFSyncStateEndTime: @(0),
            kSFSyncStateError: @""
    }];
    if (name) dict[kSFSyncStateName] = name;
    
    if (name && [SFSyncState byName:name store:store]) {
        [SFSDKSmartSyncLogger e:[self class] format:@"Failed to create sync up: there is already a sync with name:%@", name];
        return nil;
    }
    
    NSArray* savedDicts = [store upsertEntries:@[ dict ] toSoup:kSFSyncStateSyncsSoupName];
    if (savedDicts == nil || savedDicts.count == 0)
        return nil;
    SFSyncState* sync = [SFSyncState newFromDict:savedDicts[0]];
    return sync;
}

#pragma mark - Save/retrieve/delete to/from smartstore

+ (SFSyncState*)byId:(NSNumber *)syncId store:(SFSmartStore*)store {
    NSArray* retrievedDicts = [store retrieveEntries:@ [ syncId ] fromSoup:kSFSyncStateSyncsSoupName];
    if (retrievedDicts == nil || retrievedDicts.count == 0)
        return nil;
    SFSyncState* sync = [SFSyncState newFromDict:retrievedDicts[0]];
    return sync;
}

+ (SFSyncState*)byName:(NSString *)name store:(SFSmartStore*)store {
    NSNumber *syncId = [store lookupSoupEntryIdForSoupName:kSFSyncStateSyncsSoupName forFieldPath:kSFSyncStateSyncsSoupSyncName fieldValue:name error:nil];
    return syncId == nil ? nil : [self byId:syncId store:store];
}


- (void) save:(SFSmartStore*) store {
    [store upsertEntries:@[ [self asDict] ] toSoup:kSFSyncStateSyncsSoupName];
}

+ (void) deleteById:(NSNumber*)syncId store:(SFSmartStore*)store {
    [store removeEntries:@[syncId] fromSoup:kSFSyncStateSyncsSoupName];
}

+ (void) deleteByName:(NSString*)name store:(SFSmartStore*)store {
    NSNumber *syncId = [store lookupSoupEntryIdForSoupName:kSFSyncStateSyncsSoupName forFieldPath:kSFSyncStateSyncsSoupSyncName fieldValue:name error:nil];
    if (syncId) {
        [self deleteById:syncId store:store];
    }
}


#pragma mark - From/to dictionary

+ (SFSyncState*) newFromDict:(NSDictionary*)dict {
    SFSyncState* syncState = [[SFSyncState alloc] init];
    if (syncState) {
        [syncState fromDict:dict];
    }
    return syncState;
}

- (void) fromDict:(NSDictionary*) dict {
    self.syncId = [(NSNumber*) dict[kSFSyncStateId] integerValue];
    self.type = [SFSyncState syncTypeFromString:dict[kSFSyncStateType]];
    self.name = dict[kSFSyncStateName];
    self.target = (self.type == SFSyncStateSyncTypeDown
                   ? [SFSyncDownTarget newFromDict:dict[kSFSyncStateTarget]]
                   : [SFSyncUpTarget newFromDict:dict[kSFSyncStateTarget]]);
    self.options = (dict[kSFSyncStateOptions] == nil ? nil : [SFSyncOptions newFromDict:dict[kSFSyncStateOptions]]);
    self.soupName = dict[kSFSyncStateSoupName];
    self.status = [SFSyncState syncStatusFromString:dict[kSFSyncStateStatus]];
    self.progress = [(NSNumber*) dict[kSFSyncStateProgress] integerValue];
    self.totalSize = [(NSNumber*) dict[kSFSyncStateTotalSize] integerValue];
    self.maxTimeStamp = [(NSNumber*) dict[kSFSyncStateMaxTimeStamp] longLongValue];
    self.startTime = [(NSNumber*) dict[kSFSyncStateStartTime] integerValue];
    self.endTime = [(NSNumber*) dict[kSFSyncStateEndTime] integerValue];
    self.error = dict[kSFSyncStateError];
}

- (NSDictionary*) asDict {
    NSMutableDictionary* dict = [NSMutableDictionary new];
    dict[SOUP_ENTRY_ID] = [NSNumber numberWithInteger:self.syncId];
    dict[kSFSyncStateType] = [SFSyncState syncTypeToString:self.type];
    if (self.name) dict[kSFSyncStateName] = self.name;
    if (self.target) dict[kSFSyncStateTarget] = [self.target asDict];
    if (self.options) dict[kSFSyncStateOptions] = [self.options asDict];
    dict[kSFSyncStateSoupName] = self.soupName;
    dict[kSFSyncStateStatus] = [SFSyncState syncStatusToString:self.status];
    dict[kSFSyncStateProgress] = [NSNumber numberWithInteger:self.progress];
    dict[kSFSyncStateTotalSize] = [NSNumber numberWithInteger:self.totalSize];
    dict[kSFSyncStateMaxTimeStamp] = [NSNumber numberWithLongLong:self.maxTimeStamp];
    dict[kSFSyncStateStartTime] = [NSNumber numberWithInteger:self.startTime];
    dict[kSFSyncStateEndTime] = [NSNumber numberWithInteger:self.endTime];
    dict[kSFSyncStateError] = self.error;
    return dict;
}

#pragma mark - Easy status check
- (BOOL) isDone {
    return self.status == SFSyncStateStatusDone;
}

- (BOOL) hasFailed {
    return self.status == SFSyncStateStatusFailed;
}

- (BOOL) isRunning {
    return self.status == SFSyncStateStatusRunning;
}

- (BOOL) isStopped {
    return self.status == SFSyncStateStatusStopped;
}

#pragma mark - Setter for status
- (void) setStatus: (SFSyncStateStatus) newStatus
{
    if (_status != SFSyncStateStatusRunning && newStatus == SFSyncStateStatusRunning) {
        self.startTime = [[NSDate date] timeIntervalSince1970] * 1000; // milliseconds expecteed
    }
    if (_status == SFSyncStateStatusRunning
        && (newStatus == SFSyncStateStatusDone || newStatus == SFSyncStateStatusFailed)) {
        self.endTime = [[NSDate date] timeIntervalSince1970] * 1000; // milliseconds expected
    }
    _status = newStatus;
}

#pragma mark - Getter for merge mode
- (SFSyncStateMergeMode) mergeMode {
    return self.options.mergeMode;
}


#pragma mark - string to/from enum for sync type

+ (SFSyncStateSyncType) syncTypeFromString:(NSString*)syncType {
    if ([syncType isEqualToString:kSFSyncStateTypeDown]) {
        return SFSyncStateSyncTypeDown;
    }
    // Must be up
    return SFSyncStateSyncTypeUp;
}

+ (NSString*) syncTypeToString:(SFSyncStateSyncType)syncType {
    switch(syncType) {
        case SFSyncStateSyncTypeDown: return kSFSyncStateTypeDown;
        case SFSyncStateSyncTypeUp: return kSFSyncStateTypeUp;
    }
}

#pragma mark - string to/from enum for sync status

+ (SFSyncStateStatus) syncStatusFromString:(NSString*)syncStatus {
    if ([syncStatus isEqualToString:kSFSyncStateStatusNew]) {
        return SFSyncStateStatusNew;
    }
    if ([syncStatus isEqualToString:kSFSyncStateStatusStopped]) {
        return SFSyncStateStatusStopped;
    }
    if ([syncStatus isEqualToString:kSFSyncStateStatusRunning]) {
        return SFSyncStateStatusRunning;
    }
    if ([syncStatus isEqualToString:kSFSyncStateStatusDone]) {
        return SFSyncStateStatusDone;
    }
    return SFSyncStateStatusFailed;
}

+ (NSString*) syncStatusToString:(SFSyncStateStatus)syncStatus {
    switch (syncStatus) {
        case SFSyncStateStatusNew: return kSFSyncStateStatusNew;
        case SFSyncStateStatusStopped: return kSFSyncStateStatusStopped;
        case SFSyncStateStatusRunning: return kSFSyncStateStatusRunning;
        case SFSyncStateStatusDone: return kSFSyncStateStatusDone;
        case SFSyncStateStatusFailed: return kSFSyncStateStatusFailed;
    }
}

#pragma mark - string to/from enum for merge mode

+ (SFSyncStateMergeMode) mergeModeFromString:(NSString*)mergeMode {
    if ([mergeMode isEqualToString:kSFSyncStateMergeModeLeaveIfChanged]) {
        return SFSyncStateMergeModeLeaveIfChanged;
    }
    return SFSyncStateMergeModeOverwrite;
}

+ (NSString*) mergeModeToString:(SFSyncStateMergeMode)mergeMode {
    switch (mergeMode) {
        case SFSyncStateMergeModeLeaveIfChanged: return kSFSyncStateMergeModeLeaveIfChanged;
        case SFSyncStateMergeModeOverwrite: return kSFSyncStateMergeModeOverwrite;
    }
}

#pragma mark - description

- (NSString*)description
{
    return [SFJsonUtils JSONRepresentation:[self asDict]];
}

#pragma mark - copy

-(id)copyWithZone:(NSZone *)zone
{
    SFSyncState* clone = [SFSyncState new];
    [clone fromDict:[self asDict]];
    return clone;
}

@end
