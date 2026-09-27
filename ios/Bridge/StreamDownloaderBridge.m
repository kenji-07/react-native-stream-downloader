#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_MODULE(StreamDownloader, RCTEventEmitter)
RCT_EXTERN_METHOD(execute:(NSDictionary *)command resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(setProgressEnabled:(NSString *)runtimeId enabled:(BOOL)enabled)
RCT_EXTERN_METHOD(completeLicenseRequest:(NSDictionary *)response resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
@end
