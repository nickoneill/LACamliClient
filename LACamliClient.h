//
//  LACamliClient.h
//
//  Created by Nick O'Neill on 1/10/13.
//  Copyright (c) 2013 Nick O'Neill. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AFNetworking.h"

@class ALAssetsLibrary;

@interface LACamliClient : AFHTTPClient

@property (readonly) BOOL isAuthorized;

- (void)discoveryWithUsername:(NSString *)user andPassword:(NSString *)pass;
- (void)uploadAssets:(NSArray *)assets;

+ (NSString *)blobRef:(NSData *)fileData;

@end
