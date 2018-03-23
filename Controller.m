//
//  Controller.m
//  MiddleClick
//
//  Created by Alex Galonsky on 11/9/09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import "Controller.h"
#import <Cocoa/Cocoa.h>
#include <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <unistd.h>
#import "TrayMenu.h"

#pragma mark Multitouch API

typedef struct {
  float x, y;
} mtPoint;
typedef struct {
  mtPoint pos, vel;
} mtReadout;

typedef struct {
  int frame;
  double timestamp;
  int identifier, state, foo3, foo4;
  mtReadout normalized;
  float size;
  int zero1;
  float angle, majorAxis, minorAxis;  // ellipsoid
  mtReadout mm;
  int zero2[2];
  float unk2;
} Finger;

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(int, Finger *, int, double, int);

MTDeviceRef MTDeviceCreateDefault();
CFMutableArrayRef MTDeviceCreateList(void);
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStart(MTDeviceRef, int);  // thanks comex
void MTDeviceStop(MTDeviceRef);

#pragma mark Globals

NSDate *touchStartTime;
float middleclickX, middleclickY;
float middleclickX2, middleclickY2;

BOOL needToClick;
BOOL maybeMiddleClick;
BOOL pressed;

#pragma mark Implementation

@implementation Controller {
  NSTimer *_restartTimer;
}

- (void)start {
  pressed = NO;
  needToClick = NO;
  @autoreleasepool {
    // Get list of all multi touch devices
    NSMutableArray *deviceList = (NSMutableArray *)MTDeviceCreateList();  // grab our device list

    // Iterate and register callbacks for multitouch devices.
    for (int i = 0; i < [deviceList count]; i++)  // iterate available devices
    {
      MTRegisterContactFrameCallback(
          (MTDeviceRef)[deviceList objectAtIndex:i],
          callback);  // assign callback for device
      MTDeviceStart((MTDeviceRef)[deviceList objectAtIndex:i],
                    0);  // start sending events
    }

    // register a callback to know when osx come back from sleep
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(receiveWakeNote:)
                                                               name:NSWorkspaceDidWakeNotification
                                                             object:NULL];

    // Register IOService notifications for added devices.
    IONotificationPortRef port = IONotificationPortCreate(kIOMasterPortDefault);
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);
    io_iterator_t handle;
    kern_return_t err = IOServiceAddMatchingNotification(
        port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"),
        multitouchDeviceAddedCallback, self, &handle);
    if (err) {
      NSLog(
          @"Failed to register notification for touchpad attach: %xd, will not handle newly "
          @"attached devices",
          err);
      IONotificationPortDestroy(port);
    } else {
      /// Iterate through all the existing entries to arm the notification.
      io_object_t item;
      while ((item = IOIteratorNext(handle))) {
        CFRelease(item);
      }
    }
  }
}

/// Schedule app to be restarted, if a restart is pending, delay it.
- (void)scheduleRestart:(NSTimeInterval)delay {
  [_restartTimer invalidate];  // Invalidate any existing timer.

  _restartTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                  repeats:NO
                                                    block:^(NSTimer *timer) {
                                                      restartApp();
                                                    }];
}

/// Callback for system wake up. This restarts the app to initialize callbacks.
- (void)receiveWakeNote:(NSNotification *)note {
  [self scheduleRestart:10];
}

- (BOOL)getClickMode {
  return needToClick;
}

- (void)setMode:(BOOL)click {
  needToClick = click;
}

/// Relaunch the app when devices are connected/invalidated.
static void restartApp() {
  NSString *relaunch =
      [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"relaunch"];
  int procid = [[NSProcessInfo processInfo] processIdentifier];
  [NSTask launchedTaskWithLaunchPath:relaunch
                           arguments:[NSArray
                                         arrayWithObjects:[[NSBundle mainBundle] bundlePath],
                                                          [NSString stringWithFormat:@"%d", procid],
                                                          nil]];
  [NSApp terminate:NULL];
}

/// Callback when a multitouch device is added.
static void multitouchDeviceAddedCallback(void *_controller, io_iterator_t iterator) {
  /// Loop through all the returned items.
  io_object_t item;
  while ((item = IOIteratorNext(iterator))) {
    CFRelease(item);
  }

  NSLog(@"Multitouch device added, restarting...");
  Controller *controller = (Controller *)_controller;
  [controller scheduleRestart:2];
}

int callback(int device, Finger *data, int nFingers, double timestamp, int frame) {
  @autoreleasepool {
    if (needToClick) {
      if (nFingers == 3) {
        if (!pressed) {
          NSLog(@"Pressed");
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 1060
          CGEventCreateKeyboardEvent(NULL, (CGKeyCode)55, true);
#else
          CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)55, true);
#endif
          pressed = YES;
        }
      }

      if (nFingers == 0) {
        if (pressed) {
          NSLog(@"Released");
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 1060
          CGEventCreateKeyboardEvent(NULL, (CGKeyCode)55, false);
#else
          CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)55, false);
#endif

          pressed = NO;
        }
      }
    } else {
      if (nFingers == 0) {
        touchStartTime = NULL;
        if (middleclickX + middleclickY) {
          float delta = ABS(middleclickX - middleclickX2) + ABS(middleclickY - middleclickY2);
          if (delta < 0.4f) {
            // Emulate a middle click

            // get the current pointer location
            CGEventRef ourEvent = CGEventCreate(NULL);
            CGPoint ourLoc = CGEventGetLocation(ourEvent);

/*
 // CMD+Click code
 CGPostKeyboardEvent( (CGCharCode)0, (CGKeyCode)55, true );
 CGPostMouseEvent( ourLoc, 1, 1, 1);
 CGPostMouseEvent( ourLoc, 1, 1, 0);
 CGPostKeyboardEvent( (CGCharCode)0, (CGKeyCode)55, false );
 */

// Real middle click
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 1060
            CGEventPost(
                kCGHIDEventTap, CGEventCreateMouseEvent(
                                    NULL, kCGEventOtherMouseDown, ourLoc, kCGMouseButtonCenter));
            CGEventPost(
                kCGHIDEventTap,
                CGEventCreateMouseEvent(NULL, kCGEventOtherMouseUp, ourLoc, kCGMouseButtonCenter));
#else
            CGPostMouseEvent(ourLoc, 1, 3, 0, 0, 1);
            CGPostMouseEvent(ourLoc, 1, 3, 0, 0, 0);
#endif
          }
        }

      } else if (nFingers > 0 && touchStartTime == NULL) {
        NSDate *now = [[NSDate alloc] init];
        touchStartTime = [now retain];
        [now release];

        maybeMiddleClick = YES;
        middleclickX = 0.0f;
        middleclickY = 0.0f;
      } else {
        if (maybeMiddleClick == YES) {
          NSTimeInterval elapsedTime = -[touchStartTime timeIntervalSinceNow];
          if (elapsedTime > 0.5f) maybeMiddleClick = NO;
        }
      }

      if (nFingers > 3) {
        maybeMiddleClick = NO;
        middleclickX = 0.0f;
        middleclickY = 0.0f;
      }

      if (nFingers == 3) {
        Finger *f1 = &data[0];
        Finger *f2 = &data[1];
        Finger *f3 = &data[2];

        if (maybeMiddleClick == YES) {
          middleclickX = (f1->normalized.pos.x + f2->normalized.pos.x + f3->normalized.pos.x);
          middleclickY = (f1->normalized.pos.y + f2->normalized.pos.y + f3->normalized.pos.y);
          middleclickX2 = middleclickX;
          middleclickY2 = middleclickY;
          maybeMiddleClick = NO;
        } else {
          middleclickX2 = (f1->normalized.pos.x + f2->normalized.pos.x + f3->normalized.pos.x);
          middleclickY2 = (f1->normalized.pos.y + f2->normalized.pos.y + f3->normalized.pos.y);
        }
      }
    }
  }
  return 0;
}

@end
