//
//  SUPlainInstaller.m
//  Sparkle
//
//  Created by Andy Matuschak on 4/10/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUPlainInstaller.h"
#import "SUFileManager.h"
#import "SUCodeSigningVerifier.h"
#import "SUConstants.h"
#import "SUHost.h"
#import "SULog.h"

@implementation SUPlainInstaller

// Returns the bundle version from the specified host that is appropriate to use as a filename, or nil if we're unable to retrieve one
+ (NSString *)bundleVersionAppropriateForFilenameFromHost:(SUHost *)host
{
    NSString *bundleVersion = [host objectForInfoDictionaryKey:(__bridge NSString *)kCFBundleVersionKey];
    NSString *trimmedVersion = @"";
    
    if (bundleVersion != nil) {
        NSMutableCharacterSet *validCharacters = [NSMutableCharacterSet alphanumericCharacterSet];
        [validCharacters formUnionWithCharacterSet:[NSCharacterSet characterSetWithCharactersInString:@".-()"]];
        
        trimmedVersion = [bundleVersion stringByTrimmingCharactersInSet:[validCharacters invertedSet]];
    }
    
    return trimmedVersion.length > 0 ? trimmedVersion : nil;
}

+ (BOOL)performInstallationToURL:(NSURL *)installationURL fromUpdateAtURL:(NSURL *)newURL withHost:(SUHost *)host error:(NSError * __autoreleasing *)error
{
    if (installationURL == nil || newURL == nil) {
        // this really shouldn't happen but just in case
        SULog(@"Failed to perform installation because either installation URL (%@) or new URL (%@) is nil", installationURL, newURL);
        if (error != NULL) {
            *error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUInstallationError userInfo:@{ NSLocalizedDescriptionKey: @"Failed to perform installation because the paths to install at and from are not valid" }];
        }
        return NO;
    }
    
    SUFileManager *fileManager = [SUFileManager fileManagerAllowingAuthorization:YES];
    
    // Create a temporary directory for our new app that resides on our destination's volume
    NSURL *tempNewDirectoryURL = [fileManager makeTemporaryDirectoryWithPreferredName:[installationURL.lastPathComponent.stringByDeletingPathExtension stringByAppendingString:@" (Incomplete Update)"] appropriateForDirectoryURL:installationURL.URLByDeletingLastPathComponent error:error];
    if (tempNewDirectoryURL == nil) {
        SULog(@"Failed to make new temp directory");
        return NO;
    }
    
    // Move the new app to our temporary directory
    NSString *newURLLastPathComponent = newURL.lastPathComponent;
    NSURL *newTempURL = [tempNewDirectoryURL URLByAppendingPathComponent:newURLLastPathComponent];
    if (![fileManager moveItemAtURL:newURL toURL:newTempURL error:error]) {
        SULog(@"Failed to move the new app from %@ to its temp directory at %@", newURL.path, newTempURL.path);
        [fileManager removeItemAtURL:tempNewDirectoryURL error:NULL];
        return NO;
    }
    
    // Release our new app from quarantine, fix its owner and group IDs, and update its modification time while it's at our temporary destination
    // We must leave moving the app to its destination as the final step in installing it, so that
    // it's not possible our new app can be left in an incomplete state at the final destination
    
    NSError *quarantineError = nil;
    if (![fileManager releaseItemFromQuarantineAtRootURL:newTempURL error:&quarantineError]) {
        // Not big enough of a deal to fail the entire installation
        SULog(@"Failed to release quarantine at %@ with error %@", newTempURL.path, quarantineError);
    }
    
    NSURL *oldURL = [NSURL fileURLWithPath:host.bundlePath];
    if (oldURL == nil) {
        // this really shouldn't happen but just in case
        SULog(@"Failed to construct URL from bundle path: %@", host.bundlePath);
        if (error != NULL) {
            *error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUInstallationError userInfo:@{ NSLocalizedDescriptionKey: @"Failed to perform installation because a path could not be constructed for the old installation" }];
        }
        return NO;
    }
    
    if (![fileManager changeOwnerAndGroupOfItemAtRootURL:newTempURL toMatchURL:oldURL error:error]) {
        // But this is big enough of a deal to fail
        SULog(@"Failed to change owner and group of new app at %@ to match old app at %@", newTempURL.path, oldURL.path);
        [fileManager removeItemAtURL:tempNewDirectoryURL error:NULL];
        return NO;
    }
    
    if (![fileManager updateModificationAndAccessTimeOfItemAtURL:newTempURL error:error]) {
        // Not a fatal error, but a pretty unfortunate one
        SULog(@"Failed to update modification and access time of new app at %@", newTempURL.path);
    }
    
    // Swap in new temp file over old file atomically
    BOOL success = [[NSFileManager defaultManager] replaceItemAtURL:oldURL
                                                      withItemAtURL:newTempURL
                                                     backupItemName:nil
                                                            options:NSFileManagerItemReplacementUsingNewMetadataOnly
                                                   resultingItemURL:NULL
                                                              error:NULL];

    if (!success) {
        SULog(@"Failed to move new app at %@ to final destination %@", newTempURL.path, installationURL.path);
    }
    
    //Rename new file if installation URL differs from old URL (eg 'MyApp 1.2.app' -> 'MyApp 1.3.app')
    if (![oldURL isEqual:installationURL]) {
        [fileManager moveItemAtURL:oldURL toURL:installationURL error:NULL];
    }
    
    [fileManager removeItemAtURL:tempNewDirectoryURL error:NULL];
    
    return YES;
}

+ (void)performInstallationToPath:(NSString *)installationPath fromPath:(NSString *)path host:(SUHost *)host versionComparator:(id<SUVersionComparison>)comparator completionHandler:(void (^)(NSError *))completionHandler
{
    SUParameterAssert(host);

    BOOL allowDowngrades = SPARKLE_AUTOMATED_DOWNGRADES;

    // Prevent malicious downgrades
    if (!allowDowngrades) {
        if ([comparator compareVersion:[host version] toVersion:[[NSBundle bundleWithPath:path] objectForInfoDictionaryKey:(__bridge NSString *)kCFBundleVersionKey]] == NSOrderedDescending) {
            NSString *errorMessage = [NSString stringWithFormat:@"Sparkle Updater: Possible attack in progress! Attempting to \"upgrade\" from %@ to %@. Aborting update.", [host version], [[NSBundle bundleWithPath:path] objectForInfoDictionaryKey:(__bridge NSString *)kCFBundleVersionKey]];
            NSError *error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUDowngradeError userInfo:@{ NSLocalizedDescriptionKey: errorMessage }];
            [self finishInstallationToPath:installationPath withResult:NO error:error completionHandler:completionHandler];
            return;
        }
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        BOOL result = [self performInstallationToURL:[NSURL fileURLWithPath:installationPath] fromUpdateAtURL:[NSURL fileURLWithPath:path] withHost:host error:&error];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishInstallationToPath:installationPath withResult:result error:error completionHandler:completionHandler];
        });
    });
}

@end
