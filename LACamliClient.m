//
//  LACamliClient.m
//
//  Created by Nick O'Neill on 1/10/13.
//  Copyright (c) 2013 Nick O'Neill. All rights reserved.
//

#import "LACamliClient.h"
#import "LACamliChunk.h"
#import <AssetsLibrary/AssetsLibrary.h>
#import <CommonCrypto/CommonDigest.h>

@interface LACamliClient ()

@property NSString *blobRoot;
@property NSString *uploadUrl;

@property NSMutableArray *chunks;

@property BOOL isAuthorized;

@end

static NSString* const CamliServiceName = @"camliupload";

@implementation LACamliClient

- (id)initWithBaseURL:(NSURL *)url
{    
    if (self = [super initWithBaseURL:url]) {
        self.chunks = [NSMutableArray array];
        self.isAuthorized = false;
        
        [self registerHTTPOperationClass:[AFJSONRequestOperation class]];
        [self setDefaultHeader:@"Accept" value:@"application/json"];
    }
    
    return self;
}

// if we don't have blobroot with which to make these requests, we need to find it first
// 
- (void)discoveryWithUsername:(NSString *)user andPassword:(NSString *)pass
{
    // authorization required if this isn't connecting to localhost
    [self setAuthorizationHeaderWithUsername:user password:pass];
    
    [self setDefaultHeader:@"Accept" value:@"text/x-camli-configuration"];
    
    [self getPath:@"/" parameters:nil success:^(AFHTTPRequestOperation *operation, id responseObject) {
        if ([responseObject isKindOfClass:[NSData class]]) {
            NSError *error;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:responseObject options:NSJSONReadingAllowFragments error:&error];

            self.blobRoot = [json valueForKeyPath:@"blobRoot"];
            self.isAuthorized = YES;
            NSLog(@"discovery worked");
            
            // switch the default header so afnetworking automatically parses json, will be fixed when we no longer use afnetworking
            [self setDefaultHeader:@"Accept" value:@"application/json"];
        } else {
            NSLog(@"returned object was not NSData!");
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        NSLog(@"root fail: %@",error);
    }];
}

// convenience for starting uploads of ALAsset objects
// 
- (void)uploadAssets:(NSArray *)assets
{
    if (![self isAuthorized]) {
        NSLog(@"No authorization stored, you may have forgotten discovery");
        return;
    }
    
    // async, so lets protect ourselves against the user messing with this array later
    for (ALAsset *asset in assets) {
        LACamliChunk *chunk = [[LACamliChunk alloc] initWithAsset:asset];
        [self.chunks addObject:chunk];
    }
    
    // check for assets we've already uploaded with local cache here
    // TODO
    
    // we calculate sha1s in stat, so we should get off the main thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [self statChunks];
    });
}

// request stats for each chunk, making sure the server doesn't already have the chunk
//
- (void)statChunks
{    
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    [params setObject:@"1" forKey:@"camliversion"];
    
    int i = 1;
    for (LACamliChunk *chunk in self.chunks) {
        [params setObject:chunk.blobRef forKey:[NSString stringWithFormat:@"blob%d",i]];
    }
    
    [self postPath:[NSString stringWithFormat:@"%@camli/stat",self.blobRoot] parameters:params success:^(AFHTTPRequestOperation *operation, id responseObject) {
        
        // we can remove any chunks that the server claims it already has
        // TODO: (though we have to keep track of them as parts of a greater file when small chunking)
        NSMutableArray *chunksToRemove = [NSMutableArray array];
        
        NSMutableDictionary *resObj; // removing afnetworking will fix this
        if ([responseObject isKindOfClass:[NSDictionary class]]) {
            resObj = responseObject;
        } else {
            NSError *err;
            resObj = [NSJSONSerialization JSONObjectWithData:responseObject options:0 error:&err];
        }
        
        for (NSDictionary *stat in [resObj objectForKey:@"stat"]) {
            for (LACamliChunk *chunk in self.chunks) {
                if ([[stat objectForKey:@"blobRef"] isEqualToString:chunk.blobRef]) {
                    [chunksToRemove addObject:chunk];
                }
            }
        }
        
        // upload urls are full urls, we just need a path
        self.uploadUrl = [[NSURL URLWithString:[resObj objectForKey:@"uploadUrl"]] path];

        
        [self.chunks removeObjectsInArray:chunksToRemove];
        NSLog(@"stat end");
        
        [self uploadChunks];
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        NSLog(@"failed stat: %@",error);
    }];
}

// post the chunks in a multipart request
//
- (void)uploadChunks
{
    if ([self.chunks count]) {
        NSMutableURLRequest *uploadReq = [self multipartFormRequestWithMethod:@"POST" path:self.uploadUrl parameters:@{} constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
            
            for (LACamliChunk *chunk in self.chunks) {
                [formData appendPartWithFileData:chunk.fileData name:chunk.blobRef fileName:@"name" mimeType:@"image/jpeg"];
            }
        }];
        
        AFHTTPRequestOperation *uploadOp = [self HTTPRequestOperationWithRequest:uploadReq success:^(AFHTTPRequestOperation *operation, id responseObject) {
            if ([responseObject isKindOfClass:[NSDictionary class]]) {
                NSLog(@"upload response: %@",(NSDictionary *)responseObject);
            }
            
            [self vivifyChunks];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
            NSLog(@"chunk upload failed: %@",error);
        }];
        
        [uploadOp start];
    } else {
        NSLog(@"no chunks to upload after stat");
    }
}

// ask the server to vivify these blobrefs itself
//
// this only makes sense since our chunks are entire files at the moment,
// when chunks are actual chunk-sized (64k), we just want to vivify the ref to the file
- (void)vivifyChunks
{
    NSMutableURLRequest *schemaReq = [self multipartFormRequestWithMethod:@"POST" path:self.uploadUrl parameters:@{} constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
        
        for (LACamliChunk *chunk in self.chunks) {
            NSDictionary *schemaBlob = @{@"camliVersion":@1, @"camliType":@"file", @"parts":@[@{@"blobRef":chunk.blobRef,@"size":[NSNumber numberWithInteger:chunk.size]}],@"unixMTime":[self rfc3339date:chunk.creation]};
            
            NSData *schemaData = [NSJSONSerialization dataWithJSONObject:schemaBlob options:0 error:nil];
            
            [formData appendPartWithFileData:schemaData name:[LACamliClient blobRef:schemaData] fileName:@"json" mimeType:@"application/json"];
        }
    }];
    
    [schemaReq addValue:@"1" forHTTPHeaderField:@"X-Camlistore-Vivify"];
    
    AFHTTPRequestOperation *schemaOp = [self HTTPRequestOperationWithRequest:schemaReq success:^(AFHTTPRequestOperation *operation, id responseObject) {
        NSLog(@"schema blob and vivify success");
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        NSLog(@"schema blob and vivify failure");
    }];
    
    [schemaOp start];
}

#pragma mark - general utilities

+ (NSString *)blobRef:(NSData *)fileData
{
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    
    CC_SHA1(fileData.bytes, fileData.length, digest);
    
    NSMutableString* output = [NSMutableString stringWithCapacity:(CC_SHA1_DIGEST_LENGTH * 2) + 5];
    [output appendString:@"sha1-"];
    
    for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    
    return output;
}

- (NSString *)rfc3339date:(NSDate *)date
{
    NSDateFormatter *rfc3339DateFormatter = [[NSDateFormatter alloc] init];
    
    NSLocale *enUSPOSIXLocale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];

    [rfc3339DateFormatter setLocale:enUSPOSIXLocale];
    [rfc3339DateFormatter setDateFormat:@"yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'"];
    [rfc3339DateFormatter setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
    
    return [rfc3339DateFormatter stringFromDate:date];
}

@end
