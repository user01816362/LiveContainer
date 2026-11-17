//
//  IDFV.m
//  LiveContainer
//
//  Created by s s on 2026/4/25.
//
@import Foundation;
@import ObjectiveC;

#pragma clang diagnostic ignored "-Wundeclared-selector"

static NSUUID* lcLegacyIdForVendorUUID = nil;

NSUUID* getIDFV_hook(NSObject* cur) {
    return lcLegacyIdForVendorUUID;
}

void IDFVHookInit(NSUUID* uuid) {
    lcLegacyIdForVendorUUID = uuid;
    Method getIDFVOrig = class_getInstanceMethod(objc_getClass("LSApplicationWorkspace"), @selector(deviceIdentifierForVendor));
    method_setImplementation(getIDFVOrig, (IMP)getIDFV_hook);
}
