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

@property NSString *blobRoot;
@property NSString *uploadUrl;

@property NSMutableArray *chunks;

- (void)uploadAssets:(NSArray *)assets;
+ (NSString *)blobRef:(NSData *)fileData;

@end
