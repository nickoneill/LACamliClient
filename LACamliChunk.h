//
//  LACamliChunk.h
//
//  Created by Nick O'Neill on 1/13/13.
//  Copyright (c) 2013 Nick O'Neill. All rights reserved.
//

#import <Foundation/Foundation.h>

@class ALAsset;

@interface LACamliChunk : NSObject

@property ALAsset *asset;
@property NSData *fileData;

@property NSString *blobRef;
@property NSUInteger size;
@property NSDate *creation;

- (id)initWithAsset:(ALAsset *)asset;

@end
