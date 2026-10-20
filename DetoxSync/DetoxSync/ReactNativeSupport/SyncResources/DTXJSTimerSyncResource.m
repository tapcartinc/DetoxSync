//
//  DTXJSTimerSyncResource.m
//  DetoxSync
//

#import "DTXJSTimerSyncResource.h"
#import "DTXSyncManager-Private.h"
#import "NSString+SyncResource.h"

@import ObjectiveC;
#import <os/lock.h>

DTX_CREATE_LOG(DTXJSTimerSyncResource);

// 1500 ms total timeout from creation
static const NSTimeInterval kTimerTimeout = 1.5;

static NSString* _prettyTimerDescription(NSNumber* timerID)
{
    return [NSString stringWithFormat:@"JavaScript Timer %@ (Native Implementation)", timerID];
}

@implementation DTXJSTimerSyncResource {
    NSHashTable<id> *_observedInstances;
    NSMutableDictionary<NSNumber *, NSNumber *> *_pendingTimers;
    NSMutableDictionary<NSNumber *, NSDate *> *_entryTimes;
    NSMutableDictionary<NSNumber *, dispatch_source_t> *_cleanupTimers;
    dispatch_queue_t _queue;

    // Guards _pendingTimers and _entryTimes. They are mutated on _queue and read by
    // -jsonDescription on the sync manager's queue. The manager's queue must never
    // wait for _queue (see -jsonDescription), so the shared state is protected by a
    // lock that is only ever held for a few dictionary operations and never while
    // calling into DTXSyncManager.
    os_unfair_lock _timersLock;
}

+ (instancetype)sharedInstance {
    static DTXJSTimerSyncResource* shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[DTXJSTimerSyncResource alloc] init];
        [DTXSyncManager registerSyncResource:shared];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _observedInstances = [NSHashTable weakObjectsHashTable];
        _pendingTimers = [NSMutableDictionary new];
        _entryTimes = [NSMutableDictionary new];
        _cleanupTimers = [NSMutableDictionary new];
        _queue = dispatch_queue_create("com.detox.sync.JSTimerSync", DISPATCH_QUEUE_SERIAL);
        _timersLock = OS_UNFAIR_LOCK_INIT;
        [self setupTimerObservation];
    }
    return self;
}

- (void)setupTimerObservation {
    __weak __typeof(self) weakSelf = self;
    Class cls = NSClassFromString(@"RCTTiming");

    SEL createTimerForNextFrameSel = NSSelectorFromString(@"createTimerForNextFrame:duration:jsSchedulingTime:repeats:");
    Method createTimerForNextFrameMethod = class_getInstanceMethod(cls, createTimerForNextFrameSel);

    void (*orig_createTimerForNextFrame)(id, SEL, NSNumber*, NSTimeInterval, NSDate*, BOOL) = (void*)method_getImplementation(createTimerForNextFrameMethod);
    method_setImplementation(createTimerForNextFrameMethod, imp_implementationWithBlock(^(id _self, NSNumber* callbackID, NSTimeInterval duration, NSDate* jsSchedulingTime, BOOL repeats) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf observeTimerWithInstance:_self timerID:callbackID duration:duration repeats:repeats];
            orig_createTimerForNextFrame(_self, createTimerForNextFrameSel, callbackID, duration, jsSchedulingTime, repeats);
        } else {
            orig_createTimerForNextFrame(_self, createTimerForNextFrameSel, callbackID, duration, jsSchedulingTime, repeats);
        }
    }));

    SEL deleteTimerSel = NSSelectorFromString(@"deleteTimer:");
    Method deleteTimerMethod = class_getInstanceMethod(cls, deleteTimerSel);

    void (*orig_deleteTimer)(id, SEL, double) = (void*)method_getImplementation(deleteTimerMethod);
    method_setImplementation(deleteTimerMethod, imp_implementationWithBlock(^(id _self, double timerID) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf deleteTimer:@(timerID)];
        }
        orig_deleteTimer(_self, deleteTimerSel, timerID);
    }));
}

- (void)observeTimerWithInstance:(id)instance timerID:(NSNumber *)timerID duration:(NSTimeInterval)duration repeats:(BOOL)repeats {
    dispatch_async(_queue, ^{
        if (![_observedInstances containsObject:instance]) {
            [_observedInstances addObject:instance];
        }

        // Skip invalid or zero timer IDs
        if (timerID == nil || [timerID isEqualToNumber:@0]) {
            return;
        }

        if (!repeats &&
            duration <= DTXSyncManager.maximumTimerIntervalTrackingDuration &&
            duration >= DTXSyncManager.minimumTimerIntervalTrackingDuration) {
            dtx_log_info(@"[DTXJSTimerSyncResource] Observing timer %@ with duration %.2f ms", timerID, duration * 1000);
            os_unfair_lock_lock(&self->_timersLock);
            self->_pendingTimers[timerID] = @((NSUInteger)round(duration * 1000));
            self->_entryTimes[timerID] = [NSDate date];
            NSUInteger pendingCount = self->_pendingTimers.count;
            os_unfair_lock_unlock(&self->_timersLock);
            [self scheduleCleanupForTimer:timerID];

            @try {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self performUpdateBlock:^NSUInteger{
                        return pendingCount;
                    } eventIdentifier:_DTXStringReturningBlock([timerID stringValue])
                            eventDescription:_DTXStringReturningBlock(@"Timer Created")
                           objectDescription:_DTXStringReturningBlock(_prettyTimerDescription(timerID))
                       additionalDescription:nil];
                });
            } @catch (NSException *exception) {
                dtx_log_error(@"[DTXJSTimerSyncResource] Exception in performUpdateBlock: %@", exception);
            }
        } else {
            dtx_log_info(@"[DTXJSTimerSyncResource] Ignoring timer %@ (duration: %.2f ms, repeats: %@)", timerID, duration * 1000, repeats ? @"YES" : @"NO");
        }
    });
}

- (void)deleteTimer:(NSNumber *)timerID {
    dispatch_async(_queue, ^{
        NSTimeInterval elapsed = 0;
        NSUInteger pendingCount = 0;
        if ([self _removePendingTimer:timerID elapsed:&elapsed pendingCount:&pendingCount]) {
            dtx_log_info(@"[DTXJSTimerSyncResource] Timer %@ completed after %.2f ms", timerID, elapsed * 1000);

            dispatch_source_t cleanupTimer = self->_cleanupTimers[timerID];
            if (cleanupTimer) {
                dispatch_source_cancel(cleanupTimer);
                [self->_cleanupTimers removeObjectForKey:timerID];
            }

            @try {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self performUpdateBlock:^NSUInteger{
                        return pendingCount;
                    } eventIdentifier:_DTXStringReturningBlock([timerID stringValue])
                            eventDescription:_DTXStringReturningBlock(@"Timer Completed")
                           objectDescription:_DTXStringReturningBlock(_prettyTimerDescription(timerID))
                       additionalDescription:nil];
                });
            } @catch (NSException *exception) {
                dtx_log_error(@"[DTXJSTimerSyncResource] Exception in performUpdateBlock (delete): %@", exception);
            }
        }
    });
}

- (void)scheduleCleanupForTimer:(NSNumber *)timerID {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTimerTimeout * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (int64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        NSTimeInterval elapsed = 0;
        NSUInteger pendingCount = 0;
        if ([self _removePendingTimer:timerID elapsed:&elapsed pendingCount:&pendingCount]) {
            dtx_log_info(@"[DTXJSTimerSyncResource] Timer %@ timed out after %.2f ms", timerID, elapsed * 1000);
            [self->_cleanupTimers removeObjectForKey:timerID];

            @try {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self performUpdateBlock:^NSUInteger{
                        return pendingCount;
                    } eventIdentifier:_DTXStringReturningBlock([timerID stringValue])
                            eventDescription:_DTXStringReturningBlock(@"Timer Timed Out")
                           objectDescription:_DTXStringReturningBlock(_prettyTimerDescription(timerID))
                       additionalDescription:nil];
                });
            } @catch (NSException *exception) {
                dtx_log_error(@"[DTXJSTimerSyncResource] Exception in performUpdateBlock (timeout): %@", exception);
            }
        }
    });
    self->_cleanupTimers[timerID] = timer;
    dispatch_resume(timer);
}

/// Removes \c timerID from the pending set under the lock. Returns \c NO when the timer was
/// not pending (already completed or timed out). On \c YES, \c elapsed is the time since the
/// timer was observed and \c pendingCount the number of timers still pending afterwards.
- (BOOL)_removePendingTimer:(NSNumber *)timerID elapsed:(NSTimeInterval *)elapsed pendingCount:(NSUInteger *)pendingCount {
    os_unfair_lock_lock(&_timersLock);
    BOOL wasPending = _pendingTimers[timerID] != nil;
    if (wasPending) {
        NSDate *entryTime = _entryTimes[timerID];
        *elapsed = entryTime ? [[NSDate date] timeIntervalSinceDate:entryTime] : 0;
        [_pendingTimers removeObjectForKey:timerID];
        [_entryTimes removeObjectForKey:timerID];
        *pendingCount = _pendingTimers.count;
    }
    os_unfair_lock_unlock(&_timersLock);
    return wasPending;
}

- (DTXBusyResource *)jsonDescription {
    // Called on the sync manager's serial queue (-[DTXSyncManager busyResourcesDescriptions])
    // whenever the status is requested, and on arbitrary threads when verbose logging is on.
    //
    // This must never wait for _queue. Work on _queue reports its updates through
    // -performUpdateBlock:..., which dispatch_syncs onto the manager's queue (directly, or via
    // the spied dispatch_async onto the main queue, which the dispatch-queue sync resource
    // records with a synchronous update of its own). A dispatch_sync onto _queue from here
    // therefore closed a cycle: the manager's queue waited for _queue while _queue waited for
    // the manager's queue, and the app hung with the test runner stuck on a status request
    // (wix/Detox#4966). Snapshot the pending timers under the lock instead.
    NSDictionary<NSNumber *, NSNumber *> *pendingTimers;
    NSDictionary<NSNumber *, NSDate *> *entryTimes;
    os_unfair_lock_lock(&_timersLock);
    pendingTimers = [_pendingTimers copy];
    entryTimes = [_entryTimes copy];
    os_unfair_lock_unlock(&_timersLock);

    NSMutableArray *timerDescriptions = [NSMutableArray arrayWithCapacity:pendingTimers.count];
    NSDate *now = [NSDate date];
    for (NSNumber *timerID in pendingTimers) {
        NSNumber *duration = pendingTimers[timerID];
        NSDate *entryTime = entryTimes[timerID];
        NSTimeInterval elapsed = entryTime ? ([now timeIntervalSinceDate:entryTime] * 1000) : 0;
        [timerDescriptions addObject:@{
            @"timer_id": timerID,
            @"duration": duration,
            @"elapsed": @(elapsed)
        }];
    }

    return @{
        NSString.dtx_resourceNameKey: @"js_timers",
        NSString.dtx_resourceDescriptionKey: @{
            @"timers": timerDescriptions
        }
    };
}

- (void)dealloc {
    for (dispatch_source_t timer in _cleanupTimers.allValues) {
        dispatch_source_cancel(timer);
    }
    [_cleanupTimers removeAllObjects];
}

@end
