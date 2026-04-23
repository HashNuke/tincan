#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioTapInstaller : NSObject

+ (BOOL)installTapOnNode:(AVAudioNode *)node
                    bus:(AVAudioNodeBus)bus
             bufferSize:(AVAudioFrameCount)bufferSize
                 format:(nullable AVAudioFormat *)format
                  block:(AVAudioNodeTapBlock)block
                  error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(install(on:bus:bufferSize:format:block:error:));

+ (BOOL)removeTapOnNode:(AVAudioNode *)node
                    bus:(AVAudioNodeBus)bus
                  error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(removeTap(on:bus:error:));

@end

NS_ASSUME_NONNULL_END
