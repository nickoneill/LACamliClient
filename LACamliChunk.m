//
//  LACamliChunk.m
//
//  Created by Nick O'Neill on 1/13/13.
//  Copyright (c) 2013 Nick O'Neill. All rights reserved.
//

#import "LACamliChunk.h"
#import "LACamliclient.h"
#import <AssetsLibrary/AssetsLibrary.h>

@implementation LACamliChunk

// original asset
//
// blobref
// offset
// length

- (id)initWithAsset:(ALAsset *)asset
{
    if (self = [super init]) {
        ALAssetRepresentation *rep = [asset defaultRepresentation];
        
        Byte *buf = (Byte*)malloc(rep.size);
        NSUInteger bufferLength = [rep getBytes:buf fromOffset:0.0 length:rep.size error:nil];
        NSData *fileData = [NSData dataWithBytesNoCopy:buf length:bufferLength freeWhenDone:YES];
        
        [self setBlobRef:[LACamliClient blobRef:fileData]];
        [self setFileData:fileData];
        [self setSize:rep.size];
        [self setCreation:[asset valueForProperty:ALAssetPropertyDate]];
    }
    
    return self;
}

- (id)initWithData:(NSData *)data
{
    if (self = [super init]) {
        [self setBlobRef:[LACamliClient blobRef:data]];
        [self setFileData:data];
        
        // set time, size and other properties here?
    }
    
    return self;
}


@end
