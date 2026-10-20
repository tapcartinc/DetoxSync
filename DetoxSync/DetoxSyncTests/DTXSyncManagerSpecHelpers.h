//
//  DTXSyncManagerSpecHelpers.h
//  DetoxSyncTests
//
//  Created by asaf korem on 18/11/2021.
//  Copyright © 2021 wix. All rights reserved.
//

@class DTXSyncResource;

NS_ASSUME_NONNULL_BEGIN

/// Category provides mapped timer dictionary for a timer resource representation.
@interface NSDictionary (RoundedTimer)

/// Maps the timer by replacing the \c time_until_fire value with a rounded value.
- (NSDictionary<NSString *,id> *)roundedTimerValue;

@end

/// Category provides utils for sync-status dictionary.
@interface NSDictionary (SyncStatus)

/// Return all busy resources with given \c name.
- (DTXBusyResources *)busyResourcesWithName:(NSString *)name;

@end

/// Await for synchronization status and return the fetched status.
DTXSyncStatus *DTXAwaitStatus(void);

/// Format date to Detox date-format.
NSDateFormatter *DTXDateFormatter(void);

/// Maps timers to a new list of timers with rounded float values.
NSArray<NSDictionary<NSString *,id> *> *DTXMapTimers(NSArray<NSDictionary<NSString *,id> *> *timers);

/// Connects \c DTXSyncManager with JS-timers sync resource.
void DTXConnectWithJSTimerSyncResource(void);

/// Create fake JS timer with given params.
void DTXCreateFakeJSTimer(double callbackID, NSTimeInterval duration, double schedulingTime,
                          BOOL repeats);

/// Connects \c DTXSyncManager with the new-architecture JS-timers sync resource (the shared
/// \c DTXJSTimerSyncResource) and returns it.
DTXSyncResource *DTXConnectWithNewArchJSTimerSyncResource(void);

/// Create a fake new-architecture JS timer (via \c createTimerForNextFrame:) with given params.
void DTXCreateFakeNewArchJSTimer(NSNumber *callbackID, NSTimeInterval duration, BOOL repeats);

/// All \c timer_id values reported by every busy resource named \c js_timers in \c status
/// (both the old-arch and the new-arch JS timer resources report under that name).
NSArray<NSNumber *> *DTXJSTimerIDsInStatus(DTXSyncStatus *status);

/// Fetches the sync status repeatedly (spinning the main run loop in between) until the JS timer
/// \c timerID is reported busy or \c attempts statuses were fetched. Returns the last status.
DTXSyncStatus *DTXAwaitJSTimerBusy(NSNumber *timerID, NSUInteger attempts);

/// Register a new single (one-time) event.
void DTXRegisterSingleEvent(NSString *event, NSString * _Nullable object);

/// Perform arbitrary selector after arbitrary \c delay.
void DTXPerformSelectorAfterDelay(void);

/// Dispatch \c block synchronically on arbitrary queue with label "foo" and queue name "bar".
void DTXDispatcSyncOnArbitraryQueue(void (^block)(void));

/// Schedule an arbitrary timer with repeats if required, returns the fire date of the timer.
NSString *DTXScheduleTimer(BOOL shouldRepeat, NSTimeInterval interval);

/// Excute \c block on arbitrary thread and track its run-loop with name "foo". Returns the
/// \c CFRunLoopRef of the thread's run-loop.
CFRunLoopRef DTXExecuteOnArbitraryThread(void (^block)(void));

/// Creates a partially mocked view controller.
UIViewController *DTXCreateDummyViewController(void);

NS_ASSUME_NONNULL_END
