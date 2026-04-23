#import "AudioTapInstaller.h"

static NSString * const AudioTapInstallerErrorDomain = @"com.definerun.tincan.AudioTapInstaller";

@implementation AudioTapInstaller

+ (BOOL)installTapOnNode:(AVAudioNode *)node
                    bus:(AVAudioNodeBus)bus
             bufferSize:(AVAudioFrameCount)bufferSize
                 format:(AVAudioFormat * _Nullable)format
                  block:(AVAudioNodeTapBlock)block
                  error:(NSError * _Nullable * _Nullable)error {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: @"Unknown AVAudioNode tap installation failure.";
            NSString *description = [NSString stringWithFormat:
                @"AVAudioNode tap installation raised %@: %@",
                exception.name,
                reason
            ];
            *error = [NSError errorWithDomain:AudioTapInstallerErrorDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: description,
                                         @"exceptionName": exception.name,
                                         @"exceptionReason": reason,
                                     }];
        }
        return NO;
    }
}

+ (BOOL)removeTapOnNode:(AVAudioNode *)node
                    bus:(AVAudioNodeBus)bus
                  error:(NSError * _Nullable * _Nullable)error {
    @try {
        [node removeTapOnBus:bus];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: @"Unknown AVAudioNode tap removal failure.";
            NSString *description = [NSString stringWithFormat:
                @"AVAudioNode tap removal raised %@: %@",
                exception.name,
                reason
            ];
            *error = [NSError errorWithDomain:AudioTapInstallerErrorDomain
                                         code:2
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: description,
                                         @"exceptionName": exception.name,
                                         @"exceptionReason": reason,
                                     }];
        }
        return NO;
    }
}

@end
