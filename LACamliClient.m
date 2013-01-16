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

static NSString* const CamliRootKey = @"camliBlobRoot";

@implementation LACamliClient

- (id)initWithBaseURL:(NSURL *)url
{    
    if (self = [super initWithBaseURL:url]) {
        self.chunks = [NSMutableArray array];
        
        [self registerHTTPOperationClass:[AFJSONRequestOperation class]];
        [self setDefaultHeader:@"Accept" value:@"application/json"];
        
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (![defaults stringForKey:CamliRootKey]) {
            [self discovery];
        } else {
            self.blobRoot = [defaults stringForKey:CamliRootKey];
        }
    }
    
    return self;
}

- (void)discovery
{
    // authorization required if this isn't connecting to localhost
//    [self setAuthorizationHeaderWithUsername:@"nickoneill" password:@"password"];
    
    [self setDefaultHeader:@"Accept" value:@"text/x-camli-configuration"];
    
    [self getPath:@"/" parameters:nil success:^(AFHTTPRequestOperation *operation, id responseObject) {
        if ([responseObject isKindOfClass:[NSData class]]) {
            NSError *error;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:responseObject options:NSJSONReadingAllowFragments error:&error];

            self.blobRoot = [json valueForKeyPath:@"blobRoot"];
            
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            [defaults setObject:self.blobRoot forKey:@"camliBlobRoot"];
            [defaults synchronize];
        } else {
            NSLog(@"returned object was not NSData!");
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        NSLog(@"root fail: %@",[error localizedDescription]);
    }];
}

// convenience for starting uploads of ALAsset objects
// 
- (void)uploadAssets:(NSArray *)assets
{
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
        
        if ([responseObject isKindOfClass:[NSDictionary class]]) {
            for (NSDictionary *stat in [responseObject objectForKey:@"stat"]) {
                for (LACamliChunk *chunk in self.chunks) {
                    if ([[stat objectForKey:@"blobRef"] isEqualToString:chunk.blobRef]) {
                        [chunksToRemove addObject:chunk];
                    }
                }
            }
            
            // upload urls are full urls, we just need a path
            self.uploadUrl = [[NSURL URLWithString:[responseObject objectForKey:@"uploadUrl"]] path];
        }
        
        [self.chunks removeObjectsInArray:chunksToRemove];
        
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

//- (void)uploadLibrary
//{
//    [self introStat];
//    
//    NSLog(@"auth: %d",[ALAssetsLibrary authorizationStatus]);
//    NSMutableArray *assets = [NSMutableArray array];
//    
//    if ([ALAssetsLibrary authorizationStatus] != ALAuthorizationStatusDenied) {
//        [self.library enumerateGroupsWithTypes:ALAssetsGroupAll usingBlock:^(ALAssetsGroup *group, BOOL *stop) {
//            if (group) {
//                NSLog(@"group: %@ with assets: %d",group,[group numberOfAssets]);
//
//                [group enumerateAssetsUsingBlock:^(ALAsset *result, NSUInteger index, BOOL *stop) {
//                    if (result) {
//                        NSLog(@"looking at asset: %d %@",index,result);
//                        [assets addObject:result];
//                    } else {
//                        [self performSelector:@selector(sendAssets:) onThread:[NSThread mainThread] withObject:assets waitUntilDone:NO];
//                    }
//                }];
//                NSLog(@"done asset enum");
//            }
//        } failureBlock:^(NSError *error) {
//            NSLog(@"failed getting group: %@",[error localizedDescription]);
//        }];
//        NSLog(@"done enum");
//    } else {
//        NSLog(@"denied :(");
//    }
//}

- (void)sendAssets:(NSArray *)assets
{
    [self setDefaultHeader:@"Accept" value:@"application/json"];
    
    NSMutableArray *sha1s = [NSMutableArray array];
    NSMutableArray *dates = [NSMutableArray array];
    NSMutableArray *sizes = [NSMutableArray array];
    
    NSMutableURLRequest *uploadReq;
    NSLog(@"assets: %@",assets);
    for (ALAsset *asset in assets) {
        uploadReq = [self multipartFormRequestWithMethod:@"POST" path:self.uploadUrl parameters:@{} constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
            
            ALAssetRepresentation *rep = [asset defaultRepresentation];
            
            Byte *buf = (Byte*)malloc(rep.size);
            NSUInteger bufferLength = [rep getBytes:buf fromOffset:0.0 length:rep.size error:nil];
            NSData *imageData = [NSData dataWithBytesNoCopy:buf length:bufferLength freeWhenDone:YES];
            
            NSString *sha1 = [LACamliClient blobRef:imageData];
            [sha1s addObject:[NSString stringWithFormat:@"sha1-%@",sha1]];
            [dates addObject:[asset valueForProperty:ALAssetPropertyDate]];
            [sizes addObject:[NSNumber numberWithInt:rep.size]];
            
//            NSLog(@"attaching image with sha1: %@",sha1);
            [formData appendPartWithFileData:imageData name:[NSString stringWithFormat:@"sha1-%@",sha1] fileName:@"name" mimeType:@"image/jpeg"];
        }];
    }
    [uploadReq setTimeoutInterval:240];
    
    AFHTTPRequestOperation *uploadOp = [self HTTPRequestOperationWithRequest:uploadReq success:^(AFHTTPRequestOperation *operation, id responseObject) {
        
        NSLog(@"win");
        if ([responseObject isKindOfClass:[NSDictionary class]]) {
            NSLog(@"json: %@",(NSDictionary *)responseObject);
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        NSLog(@"fail: %@",[error localizedDescription]);
    }];
    
    [uploadOp start];
    
    NSMutableURLRequest *schemaReq = [self multipartFormRequestWithMethod:@"POST" path:self.uploadUrl parameters:@{} constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
        NSDictionary *schemaBlob = @{@"camliVersion":@1, @"camliType":@"file", @"parts":@[@{@"blobRef":sha1s[0],@"size":sizes[0]}],@"unixMTime":[self rfc3339date:dates[0]]};
        
        NSData *schemaData = [NSJSONSerialization dataWithJSONObject:schemaBlob options:0 error:nil];
        
        NSLog(@"blob: %@",schemaData);

        NSString *sha1 = [LACamliClient blobRef:schemaData];
        
        [formData appendPartWithFileData:schemaData name:[NSString stringWithFormat:@"sha1-%@",sha1] fileName:@"json" mimeType:@"application/json"];
    }];
    
    [schemaReq addValue:@"1" forHTTPHeaderField:@"X-Camlistore-Vivify"];
    
    AFHTTPRequestOperation *schemaOp = [self HTTPRequestOperationWithRequest:schemaReq success:^(AFHTTPRequestOperation *operation, id responseObject) {
        NSLog(@"schema up win");
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        NSLog(@"schema up fail");
    }];
    
    [schemaOp start];
}

- (void)introStat
{
    NSString *path = [NSString stringWithFormat:@"%@camli/stat",self.blobRoot];
    
    [self getPath:path parameters:@{@"camliversion": @1} success:^(AFHTTPRequestOperation *operation, id responseObject) {
        if ([responseObject isKindOfClass:[NSData class]]) {
            NSError *error;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:responseObject options:NSJSONReadingAllowFragments error:&error];
            
            NSURL *fullUpUrl = [NSURL URLWithString:[json valueForKeyPath:@"uploadUrl"]];
            self.uploadUrl = fullUpUrl.path;
        } else {
            NSLog(@"returned object was not NSData!");
        }
        
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        NSLog(@"stat fail: %@",[error localizedDescription]);
    }];
}

- (void)findFiles
{
    NSString *path = [NSString stringWithFormat:@"%@camli/stat",self.blobRoot];
    
    NSLog(@"requesting: %@",path);
    [self getPath:path parameters:@{@"camliversion": @1} success:^(AFHTTPRequestOperation *operation, id responseObject) {
        NSLog(@"object: %@",[responseObject class]);
        
        if ([responseObject isKindOfClass:[NSData class]]) {
            NSError *error;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:responseObject options:NSJSONReadingAllowFragments error:&error];
            
            NSLog(@"json: %@",json);
        } else {
            NSLog(@"returned object was not NSData!");
        }

    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        NSLog(@"stat fail: %@",[error localizedDescription]);
    }];
}

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
