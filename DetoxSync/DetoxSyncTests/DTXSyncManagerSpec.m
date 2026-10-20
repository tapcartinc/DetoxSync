//
//  DTXSyncManagerSpec.m
//  DetoxSyncTests
//
//  Created by Asaf Korem on 17/11/2021.
//  Copyright © 2021 wix. All rights reserved.
//

#import "DTXSyncManagerSpecHelpers.h"

#import "DTXSyncResource.h"

#import <DetoxSync/DTXSyncManager.h>

#import "NSString+SyncStatus.h"
#import "NSString+SyncResource.h"

SpecBegin(DTXSyncManager)

it(@"should report delayed perform selector busy resource", ^{
  DTXPerformSelectorAfterDelay();
  DTXPerformSelectorAfterDelay();

  DTXSyncStatus *status = DTXAwaitStatus();
  expect(status[NSString.dtx_appStatusKey]).to.equal(@"busy");

  NSString *resourceName = @"delayed_perform_selector";
  NSArray *resources = [status busyResourcesWithName:resourceName];
  expect(resources).to.contain((@{
    NSString.dtx_resourceNameKey: resourceName,
    NSString.dtx_resourceDescriptionKey: @{
      @"pending_selectors": @2
    }
  }));
});

it(@"should report dispatch queue busy resource", ^{
  __block DTXSyncStatus *status;
  DTXDispatcSyncOnArbitraryQueue(^{
    status = DTXAwaitStatus();
  });

  expect(status[NSString.dtx_appStatusKey]).to.equal(@"busy");

  NSString *resourceName = @"dispatch_queue";
  NSArray *resources = [status busyResourcesWithName:resourceName];
  expect(resources).to.contain((@{
    NSString.dtx_resourceNameKey: resourceName,
    NSString.dtx_resourceDescriptionKey: @{
      @"queue": @"bar (<OS_dispatch_queue_serial: foo>)",
      @"works_count": @1
    }
  }));
});

// TODO: Investigate why this test is failing on iOS 16 and above.
xit(@"should report native timers busy resource", ^{
  NSString *fireDate = DTXScheduleTimer(NO, 15);

  DTXSyncStatus *status = DTXAwaitStatus();
  expect(status[NSString.dtx_appStatusKey]).to.equal(@"busy");

  DTXBusyResource *resource = [status busyResourcesWithName:@"timers"].firstObject;
  NSArray<NSDictionary<NSString *,id> *> *timers = DTXMapTimers(resource[NSString.dtx_resourceDescriptionKey][@"timers"]);

  expect(timers).to.contain((@{
    @"fire_date": fireDate,
    @"time_until_fire": @15,
    @"is_recurring": @NO,
    @"repeat_interval": @0
  }));
});

it(@"should not report native timers with repeats as busy resource", ^{
  DTXScheduleTimer(YES, 10);

  DTXSyncStatus *status = DTXAwaitStatus();
  expect(status[NSString.dtx_appStatusKey]).to.equal(@"busy");

  DTXBusyResource * _Nullable resource = [status busyResourcesWithName:@"timers"].firstObject;
  NSArray<NSNumber *> * _Nullable timesUntilFire = 
      [DTXMapTimers(resource[NSString.dtx_resourceDescriptionKey][@"timers"])
       valueForKey:@"time_until_fire"];

  expect(timesUntilFire ?: @[]).notTo.contain((@10));
});

it(@"should report js-timers busy resource", ^{
  DTXConnectWithJSTimerSyncResource();
  DTXCreateFakeJSTimer(12, 31.123, 21, NO);
  DTXCreateFakeJSTimer(31, 13.1, 23, NO);

  DTXSyncStatus *status = DTXAwaitStatus();
  expect(status[NSString.dtx_appStatusKey]).to.equal(@"busy");

  DTXBusyResource *resource = [status busyResourcesWithName:@"js_timers"].firstObject;
  NSArray<NSDictionary<NSString *,NSNumber *> *> *timers =
      resource[NSString.dtx_resourceDescriptionKey][@"timers"];

  expect([NSSet setWithArray:timers]).to.equal([NSSet setWithObjects:
    @{
      @"timer_id": @12,
      @"duration": @31.123,
      @"is_recurring": @NO
    },
    @{
      @"timer_id": @31,
      @"duration": @13.1,
      @"is_recurring": @NO
    },
    nil
  ]);
});

it(@"should report new-arch js-timers busy resource", ^{
  DTXConnectWithNewArchJSTimerSyncResource();
  DTXCreateFakeNewArchJSTimer(@1201, 0.4, NO);

  DTXSyncStatus *status = DTXAwaitJSTimerBusy(@1201, 20);
  expect(status[NSString.dtx_appStatusKey]).to.equal(@"busy");
  expect(DTXJSTimerIDsInStatus(status)).to.contain(@1201);
});

// Regression for wix/Detox#4966: -[DTXJSTimerSyncResource jsonDescription] used to dispatch_sync
// onto the resource's private queue. The manager computes the status on its own serial queue,
// and work on the resource's queue reports updates with a dispatch_sync onto the manager's
// queue, so the two queues could wait on each other forever. Parking the resource's queue while
// a status is requested reproduces the manager side of that wait deterministically: against the
// old implementation the status request below times out.
//
// Ordering matters for robustness on a slow box: the park lands on the timer queue right after
// the observe block has run (drained with a dispatch_sync), so the 1.5 s cleanup timer, which
// also runs on that queue, cannot remove the timer before the status is taken. A failed
// expectation throws here, so the parked block releases itself after a bounded wait and later
// specs are not stuck.
it(@"should report new-arch js-timers without waiting for the timer queue", ^{
  DTXSyncResource *resource = DTXConnectWithNewArchJSTimerSyncResource();
  dispatch_queue_t timerQueue = [resource valueForKey:@"queue"];
  expect(timerQueue).notTo.beNil();

  DTXCreateFakeNewArchJSTimer(@1202, 0.4, NO);
  dispatch_sync(timerQueue, ^{});  // the observe block has run and queued its update for the main queue

  dispatch_semaphore_t release = dispatch_semaphore_create(0);
  dispatch_async(timerQueue, ^{
    dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)));
  });

  // Spins the main run loop until the queued update has reached the manager.
  DTXSyncStatus *busyStatus = DTXAwaitJSTimerBusy(@1202, 20);
  expect(DTXJSTimerIDsInStatus(busyStatus)).to.contain(@1202);

  NSTimeInterval defaultTimeout = [Expecta asynchronousTestTimeout];
  [Expecta setAsynchronousTestTimeout:5];
  __block DTXSyncStatus *status = nil;
  waitUntil(^(DoneCallback done) {
    [DTXSyncManager statusWithCompletionHandler:^(DTXSyncStatus *fetchedStatus) {
      status = fetchedStatus;
      done();
    }];
  });
  [Expecta setAsynchronousTestTimeout:defaultTimeout];
  dispatch_semaphore_signal(release);

  expect(status).notTo.beNil();
  expect(status[NSString.dtx_appStatusKey]).to.equal(@"busy");
  expect(DTXJSTimerIDsInStatus(status)).to.contain(@1202);
});

it(@"should report run-loop busy resource", ^{
  __block DTXSyncStatus *status;
  CFRunLoopRef runLoop = DTXExecuteOnArbitraryThread(^{
    status = DTXAwaitStatus();
  });

  expect(status[NSString.dtx_appStatusKey]).to.equal(@"busy");

  NSString *resourceName = @"run_loop";
  NSArray *resources = [status busyResourcesWithName:resourceName];
  expect(resources).to.contain((@{
    NSString.dtx_resourceNameKey: resourceName,
    NSString.dtx_resourceDescriptionKey: @{
      @"name": [NSString stringWithFormat:@"foo <CFRunLoop: %p>", runLoop]
    }
  }));
});

it(@"should report one-time-events busy resource", ^{
  DTXRegisterSingleEvent(@"foo", @"bar");
  DTXRegisterSingleEvent(@"baz", nil);

  DTXSyncStatus *status = DTXAwaitStatus();
  expect(status[NSString.dtx_appStatusKey]).to.equal(@"busy");

  NSString *resourceName = @"one_time_events";
  NSArray *resources = [status busyResourcesWithName:resourceName];
  expect(resources).to.contain((@{
    NSString.dtx_resourceNameKey: resourceName,
    NSString.dtx_resourceDescriptionKey: @{
      @"event": @"foo",
      @"object": @"bar"
    }
  }));

  expect(resources).to.contain((@{
    NSString.dtx_resourceNameKey: resourceName,
    NSString.dtx_resourceDescriptionKey: @{
      @"event": @"baz",
      @"object": [NSNull null]
    }
  }));
});

it(@"should report ui busy resource", ^{
  UIViewController *dummyController = DTXCreateDummyViewController();

  [dummyController viewWillAppear:YES];
  [dummyController viewWillAppear:NO];
  [dummyController viewWillDisappear:YES];

  DTXSyncStatus *status = DTXAwaitStatus();
  expect(status[NSString.dtx_appStatusKey]).to.equal(@"busy");

  NSString *resourceName = @"ui";
  NSArray *resources = [status busyResourcesWithName:resourceName];
  expect(resources).to.contain((@{
    NSString.dtx_resourceNameKey: resourceName,
    NSString.dtx_resourceDescriptionKey: @{
      @"view_controller_will_appear_count": @2,
      @"view_controller_will_disappear_count": @1,
    }
  }));
});

SpecEnd
