#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTBridgeModule.h>
#import <Photos/Photos.h>

#import "VydiaRNFileUploader.h"

@implementation VydiaRNFileUploader{
    unsigned long uploadId;
    NSMutableDictionary *_responsesData;
    NSURLSession *_urlSession;
    void (^backgroundSessionCompletionHandler)(void);
}

RCT_EXPORT_MODULE();

static NSString *BACKGROUND_SESSION_ID = @"ReactNativeBackgroundUpload";
static VydiaRNFileUploader *sharedInstance;


+ (BOOL)requiresMainQueueSetup {
    return YES;
}

- (dispatch_queue_t)methodQueue
{
  return dispatch_get_main_queue();
}

- (id)initPrivate {
    if (self = [super init]) {
        uploadId = 0;
        _responsesData = [NSMutableDictionary dictionary];
        _urlSession = nil;
        backgroundSessionCompletionHandler = nil;
        self.isObserving = NO;
    }
    return self;
}

// singleton access
+ (VydiaRNFileUploader*)sharedInstance {
    @synchronized(self) {
        if (sharedInstance == nil)
            sharedInstance = [[self alloc] initPrivate];
    }
    return sharedInstance;
}

-(id) init {
    return [VydiaRNFileUploader sharedInstance];
}

- (void)_sendEventWithName:(NSString *)eventName body:(id)body {

    // add a delay to give time to event listeners to be set up
    double delayInSeconds = 0.5;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);

    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        // do not check for self->isObserving for now
        // as for some reason it is sometimes never set to YES after an app refresh
        if (self.bridge != nil) {
            [self sendEventWithName:eventName body:body];
        }
    });

}

- (NSArray<NSString *> *)supportedEvents {
    return @[
        @"RNFileUploader-progress",
        @"RNFileUploader-error",
        @"RNFileUploader-cancelled",
        @"RNFileUploader-completed",
        @"RNFileUploader-bgExpired"
    ];
}

- (void)startObserving {
    self.isObserving = YES;

    // JS side is ready to receive events; create the background url session if necessary
    // iOS will then deliver the tasks completed while the app was dead (if any)
//    double delayInSeconds = 0.5;
//    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
//    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
//        NSLog(@"RNBU startObserving: recreate urlSession if necessary");
//        [self urlSession];
//    });

    // why was the delay even needed?
    //NSLog(@"RNBU startObserving: recreate urlSession if necessary");
    [self urlSession];
}

-(void)stopObserving {
    self.isObserving = NO;
}

- (void)setBackgroundSessionCompletionHandler:(void (^)(void))handler {
    @synchronized (self) {
        backgroundSessionCompletionHandler = handler;
        //NSLog(@"RNBU setBackgroundSessionCompletionHandler");
    }
}


/*
 * Starts a file upload.
 * Options are passed in as the first argument as a js hash:
 * {
 *   url: string.  url to post to.
 *   path: string.  path to the file on the device
 *   headers: hash of name/value header pairs
 * }
 *
 * Returns a promise with the string ID of the upload.
 */
RCT_EXPORT_METHOD(startUpload:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
{
    NSString *uploadUrl = options[@"url"];
    NSString *fileURI = options[@"path"]; // No default, should be provided
    NSString *method = options[@"method"] ?: @"POST";
    NSString *customUploadId = options[@"customUploadId"];
    NSDictionary *headers = options[@"headers"];
    // NSString *uploadType = options[@"type"]; // No longer needed, assumed "raw"
    // NSString *fieldName = options[@"field"]; // Multipart specific
    // NSDictionary *parameters = options[@"parameters"]; // Multipart specific

    // Basic validation for required options
    if (!uploadUrl || [uploadUrl length] == 0) {
        reject(@"RN Uploader", @"'url' option is required.", nil);
        return;
    }
    if (!fileURI || [fileURI length] == 0) {
        reject(@"RN Uploader", @"'path' option is required for raw upload.", nil);
        return;
    }
    if ([fileURI hasPrefix:@"assets-library"]) {
        reject(@"RN Uploader", @"'assets-library' paths are not supported in this simplified version. Please provide a direct file path.", nil);
        return;
    }
    // Ensure fileURI is a valid file URL, e.g., starts with "file://"
    // Or convert it to one if it's a raw path.
    // For simplicity, assuming fileURI is already a valid file URL string as per original logic for `uploadTaskWithRequest:fromFile:`
    NSURL *localFileUrl = [NSURL URLWithString:fileURI];
    if (!localFileUrl || ![localFileUrl isFileURL]) {
         // If it's a raw path, try to create a file URL
        localFileUrl = [NSURL fileURLWithPath:fileURI isDirectory:NO];
        if (!localFileUrl) { // Still nil or not a file URL
            reject(@"RN Uploader", @"'path' option must be a valid file URI or absolute file path.", nil);
            return;
        }
    }


    NSString *thisUploadId = customUploadId;
    if(!thisUploadId){
        @synchronized(self)
        {
            thisUploadId = [NSString stringWithFormat:@"%lu", uploadId++];
        }
    }

    @try {
        NSURL *requestUrl = [NSURL URLWithString:uploadUrl];
        if (requestUrl == nil) {
            // This was @throw in original, but reject is cleaner for RN modules
            reject(@"RN Uploader", @"Request URL cannot be nil or is invalid.", nil);
            return;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestUrl];
        [request setHTTPMethod:method];

        [headers enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull val, BOOL * _Nonnull stop) {
            if ([val respondsToSelector:@selector(stringValue)]) {
                val = [val stringValue];
            }
            if ([val isKindOfClass:[NSString class]]) {
                [request setValue:val forHTTPHeaderField:key];
            }
        }];

        // Directly use uploadTaskWithRequest:fromFile:
        NSURLSessionUploadTask *uploadTask = [[self urlSession] uploadTaskWithRequest:request fromFile:localFileUrl];

        if (!uploadTask) {
            // This can happen if the fileURL is invalid or inaccessible
            reject(@"RN Uploader", [NSString stringWithFormat:@"Failed to create upload task. Check file path: %@", fileURI], nil);
            return;
        }
        
        uploadTask.taskDescription = thisUploadId;
        [uploadTask resume];
        resolve(uploadTask.taskDescription);
    }
    @catch (NSException *exception) {
        reject(@"RN Uploader", exception.name, exception.reason); // Include reason
    }
}
}

/*
 * Cancels file upload
 * Accepts upload ID as a first argument, this upload will be cancelled
 * Event "cancelled" will be fired when upload is cancelled.
 */
RCT_EXPORT_METHOD(cancelUpload: (NSString *)cancelUploadId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    [_urlSession getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        for (NSURLSessionTask *uploadTask in uploadTasks) {
            if ([uploadTask.taskDescription isEqualToString:cancelUploadId]){
                // == checks if references are equal, while isEqualToString checks the string value
                [uploadTask cancel];
            }
        }
    }];
    resolve([NSNumber numberWithBool:YES]);
}


/*
 * Returns remaining allowed background time
 */
RCT_REMAP_METHOD(getRemainingBgTime, getRemainingBgTimeResolver:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {

    dispatch_sync(dispatch_get_main_queue(), ^(void){
        double time = [[UIApplication sharedApplication] backgroundTimeRemaining];
        //NSLog(@"Background xx time Remaining: %f", time);
        resolve([NSNumber numberWithDouble:time]);
    });
}

// Let the OS it can suspend, must be called after enqueing all requests
RCT_EXPORT_METHOD(canSuspendIfBackground) {
    //NSLog(@"RNBU canSuspendIfBackground");

    // run with delay to give JS some time
    double delayInSeconds = 0.2;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        @synchronized (self) {
            if (self->backgroundSessionCompletionHandler) {
                self->backgroundSessionCompletionHandler();
                //NSLog(@"RNBU did call backgroundSessionCompletionHandler (canSuspendIfBackground)");
                self->backgroundSessionCompletionHandler = nil;
            }
        }
    });
}

// requests / releases background task time to the OS
// returns task id
RCT_REMAP_METHOD(beginBackgroundTask, beginBackgroundTaskResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject){

    __block NSUInteger taskId = UIBackgroundTaskInvalid;

    taskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        //NSLog(@"RNBU beginBackgroundTaskWithExpirationHandler id: %ul", taskId);

        // do not use the other send event cause it has a delay
        // always send expire event, even if task id is invalid
        if (self.isObserving && self.bridge != nil) {
            [self sendEventWithName:@"RNFileUploader-bgExpired" body:@{@"id": [NSNumber numberWithUnsignedLong:taskId]}];
        }

        if (taskId != UIBackgroundTaskInvalid){

            //double time = [[UIApplication sharedApplication] backgroundTimeRemaining];
            //NSLog(@"Background xx time Remaining: %f", time);

            // dispatch async so we give time to JS to finish
            // we have about 3-4 seconds
            double delayInSeconds = 0.7;
            dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);

            dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                [[UIApplication sharedApplication] endBackgroundTask: taskId];
            });

        }
    }];

    //NSLog(@"RNBU beginBackgroundTask id: %ul", taskId);
    resolve([NSNumber numberWithUnsignedLong:taskId]);

}


RCT_EXPORT_METHOD(endBackgroundTask: (NSUInteger)taskId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject){

    @try{
        if(taskId != UIBackgroundTaskInvalid){
            [[UIApplication sharedApplication] endBackgroundTask: taskId];
        }

        //NSLog(@"RNBU endBackgroundTask id: %ul", taskId);
        resolve([NSNumber numberWithBool:YES]);
    }
    @catch (NSException *exception) {
        //NSLog(@"RNBU endBackgroundTask error: %@", exception);
        reject(@"RN Uploader", exception.name, nil);
    }
}



- (NSURLSession *)urlSession {
    @synchronized (self) {
        if (_urlSession == nil) {
            NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:BACKGROUND_SESSION_ID];

            // UPDATE: Enforce a timeout here because we will otherwise
            // not get errors if the server times out
            sessionConfiguration.timeoutIntervalForResource = 5 * 60;

            _urlSession = [NSURLSession sessionWithConfiguration:sessionConfiguration delegate:self delegateQueue:nil];
        }
    }

    return _urlSession;
}

#pragma NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithObjectsAndKeys:task.taskDescription, @"id", nil];
    NSURLSessionDataTask *uploadTask = (NSURLSessionDataTask *)task;
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)uploadTask.response;
    if (response != nil)
    {
        [data setObject:[NSNumber numberWithInteger:response.statusCode] forKey:@"responseCode"];
    }
    
    // add headers
    NSMutableDictionary *headers = [[NSMutableDictionary alloc] init];
    NSDictionary *respHeaders = response.allHeaderFields;
    for (NSString *key in respHeaders)
    {
        headers[[key lowercaseString]] = respHeaders[key];
    }
    [data setObject:headers forKey:@"responseHeaders"];
    
    // Add data that was collected earlier by the didReceiveData method
    NSMutableData *responseData = _responsesData[@(task.taskIdentifier)];
    if (responseData) {
        [_responsesData removeObjectForKey:@(task.taskIdentifier)];
        NSString *response = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
        [data setObject:response forKey:@"responseBody"];
    } else {
        [data setObject:[NSNull null] forKey:@"responseBody"];
    }


    if (error == nil) {
        [self _sendEventWithName:@"RNFileUploader-completed" body:data];
        //NSLog(@"RNBU did complete upload %@", task.taskDescription);
    } else {
        [data setObject:error.localizedDescription forKey:@"error"];
        if (error.code == NSURLErrorCancelled) {
            [self _sendEventWithName:@"RNFileUploader-cancelled" body:data];
            //NSLog(@"RNBU did cancel upload %@", task.taskDescription);
        } else {
            [self _sendEventWithName:@"RNFileUploader-error" body:data];
            //NSLog(@"RNBU did error upload %@", task.taskDescription);
        }
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    // for some reason we're sometimes getting *** -[__NSPlaceholderDictionary initWithObjects:forKeys:count:]: attempt to insert nil object from objects[0]
    // no idea why, so just catch and log the error
    //
    // https://scribeware-bo.sentry.io/issues/5386385626/events/a0cd584421f04e05be9ac01853b7fa00/?project=5288441&query=release%3Acom.scribeware.ios%406.178.186%2B530+error.unhandled%3Atrue&referrer=previous-event&sort=freq&statsPeriod=7d&stream_index=0
    @try {
        float progress = -1;
        if (totalBytesExpectedToSend > 0) { // see documentation.  For unknown size it's -1 (NSURLSessionTransferSizeUnknown)
            progress = 100.0 * (float)totalBytesSent / (float)totalBytesExpectedToSend;
        }
        [self _sendEventWithName:@"RNFileUploader-progress" body:@{ @"id": task.taskDescription, @"progress": [NSNumber numberWithFloat:progress] }];
    } 
    @catch (NSException *exception) {
        NSLog(@"Exception: %@", exception);
    } 

}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (!data.length) return;
    // Hold returned data so it can be picked up by the didCompleteWithError method later
    NSMutableData *responseData = _responsesData[@(dataTask.taskIdentifier)];
    if (!responseData) {
        responseData = [NSMutableData dataWithData:data];
        _responsesData[@(dataTask.taskIdentifier)] = responseData;
    } else {
        [responseData appendData:data];
    }
}


// this will allow the app *technically* to wake up, run some code
// and then sleep. We will set a very short timeout (less than 5 seconds)
// to call the completion handler if it wasn't called already
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    //NSLog(@"RNBU URLSessionDidFinishEventsForBackgroundURLSession");

    if (backgroundSessionCompletionHandler) {
        double delayInSeconds = 4;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            @synchronized (self) {
                if (self->backgroundSessionCompletionHandler) {
                    self->backgroundSessionCompletionHandler();
                    //NSLog(@"RNBU did call backgroundSessionCompletionHandler (URLSessionDidFinishEventsForBackgroundURLSession)");
                    self->backgroundSessionCompletionHandler = nil;
                }
            }
        });
    }
}

@end
