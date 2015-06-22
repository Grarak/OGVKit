//
//  OGVInputStream.h
//  OGVKit
//
//  Created by Brion on 6/16/15.
//  Copyright (c) 2015 Brion Vibber. All rights reserved.
//

#import "OGVKit.h"

@interface OGVInputStream (Private)
@property (nonatomic) NSURL *URL;
@property (nonatomic) OGVInputStreamState state;
@property (nonatomic) BOOL dataAvailable;
@property (nonatomic) NSUInteger bytePosition;
@property (nonatomic) NSUInteger bytesAvailable;
@end

@implementation OGVInputStream
{
    NSObject *timeLock;

    NSURL *_URL;
    OGVInputStreamState _state;
    BOOL _dataAvailable;
    NSUInteger _bytePosition;
    NSUInteger _bytesAvailable;

    NSURLConnection *connection;
    NSMutableArray *inputDataQueue;
    BOOL doneDownloading;

    dispatch_semaphore_t waitingForDataSemaphore;
}

#pragma mark - public methods

-(void)dealloc
{
    if (connection) {
        [connection cancel];
    }
}

-(NSURL *)URL
{
    return _URL;
}

-(void)setURL:(NSURL *)URL
{
    _URL = URL;
}

-(OGVInputStreamState)state
{
    @synchronized (timeLock) {
        return _state;
    }
}

-(void)setState:(OGVInputStreamState)state
{
    @synchronized (timeLock) {
        OGVInputStreamState oldState = _state;
        _state = state;
        
        if (self.delegate && state != oldState) {
            dispatch_async(dispatch_get_main_queue(), ^() {
                if ([self.delegate respondsToSelector:@selector(OGVInputStreamStateChanged:)]) {
                    [self.delegate OGVInputStreamStateChanged:self];
                }
            });
        }
    }
}

-(BOOL)dataAvailable
{
    @synchronized (timeLock) {
        return _dataAvailable;
    }
}

-(void)setDataAvailable:(BOOL)dataAvailable
{
    @synchronized (timeLock) {
        BOOL wasAvailable = _dataAvailable;
        _dataAvailable = dataAvailable;
        
        if (self.delegate && !wasAvailable && dataAvailable) {
            dispatch_async(dispatch_get_main_queue(), ^() {
                if ([self.delegate respondsToSelector:@selector(OGVInputStreamDataAvailable:)]) {
                    [self.delegate OGVInputStreamDataAvailable:self];
                }
            });
        }
    }
}

-(NSUInteger)bytesAvailable
{
    @synchronized (timeLock) {
        return _bytesAvailable;
    }
}

-(void)setBytesAvailable:(NSUInteger)bytesAvailable
{
    @synchronized (timeLock) {
        _bytesAvailable = bytesAvailable;
    }
}

-(NSUInteger)bytePosition
{
    @synchronized (timeLock) {
        return _bytePosition;
    }
}

-(void)setBytePosition:(NSUInteger)bytePosition
{
    @synchronized (timeLock) {
        _bytePosition = bytePosition;
    }
}

-(instancetype)initWithURL:(NSURL *)URL
{
    self = [super init];
    if (self) {
        timeLock = [[NSObject alloc] init];
        self.URL = URL;
        self.state = OGVInputStreamStateInit;
        self.dataAvailable = NO;
        inputDataQueue = [[NSMutableArray alloc] init];
    }
    return self;
}

-(void)start
{
    @synchronized (timeLock) {
        assert(!connection);
        
        [NSThread detachNewThreadSelector:@selector(startDownloadThread:)
                                 toTarget:self
                               withObject:nil];
    }
}

-(void)cancel
{
    [connection cancel];
}

-(NSData *)readBytes:(NSUInteger)nBytes blocking:(BOOL)blocking
{
    NSData *data = nil;
    BOOL blockingWait = NO;

    @synchronized (timeLock) {
        switch (self.state) {
            case OGVInputStreamStateInit:
            case OGVInputStreamStateConnecting:
            case OGVInputStreamStateReading:
                // We're ok.
                break;
            case OGVInputStreamStateDone:
            case OGVInputStreamStateFailed:
            case OGVInputStreamStateSeeking:
                NSLog(@"OGVInputStream reading in invalid state %d", (int)self.state);
                return nil;
        }

        NSUInteger bytesAvailable = self.bytesAvailable;
        //NSLog(@"nBytes: %ld; bytesAvailable: %ld", (long)nBytes, (long)bytesAvailable);
        if (bytesAvailable >= nBytes) {
            data = [self dequeueBytes:nBytes];
        } else if (blocking) {
            // ...
            blockingWait = YES;
        } else if (bytesAvailable) {
            // Non-blocking, return as much data as we have.
            data = [self dequeueBytes:bytesAvailable];
        } else {
            // Non-blocking, and there is no data.
            data = nil;
        }
    }

    if (blockingWait) {
        [self waitForBytesAvailable:nBytes];
        data = [self dequeueBytes:nBytes];
    }
    
    if (data) {
        self.bytePosition += [data length];
    }
    return data;
}

#pragma mark - private methods

-(void)startDownloadThread:(id)obj
{
    NSRunLoop *downloadRunLoop = [NSRunLoop currentRunLoop];

    @synchronized (timeLock) {
        NSURLRequest *req = [NSURLRequest requestWithURL:self.URL];
        connection = [[NSURLConnection alloc] initWithRequest:req delegate:self startImmediately:NO];
        [connection scheduleInRunLoop:downloadRunLoop forMode:NSRunLoopCommonModes];
        [connection start];

        self.state = OGVInputStreamStateConnecting;
        doneDownloading = NO;
    }

    [downloadRunLoop run];
}

-(void)waitForBytesAvailable:(NSUInteger)nBytes
{
    assert(waitingForDataSemaphore == NULL);
    waitingForDataSemaphore = dispatch_semaphore_create(0);
    while (YES) {
        @synchronized (timeLock) {
            if (self.bytesAvailable >= nBytes ||
                self.state == OGVInputStreamStateDone ||
                self.state == OGVInputStreamStateFailed) {
                waitingForDataSemaphore = nil;
                break;
            }
        }

        dispatch_semaphore_wait(waitingForDataSemaphore,
                                DISPATCH_TIME_FOREVER);

    }
}

-(void)queueData:(NSData *)data
{
    @synchronized (timeLock) {
        [inputDataQueue addObject:data];
        self.bytesAvailable += [data length];

        if ([inputDataQueue count] == 1) {
            self.dataAvailable = YES;

            if (waitingForDataSemaphore) {
                dispatch_semaphore_signal(waitingForDataSemaphore);
            }
        }
    }
}

-(NSData *)peekData
{
    @synchronized (timeLock) {
        if ([inputDataQueue count] > 0) {
            NSData *inputData = inputDataQueue[0];
            return inputData;
        } else {
            return nil;
        }
    }
}

-(NSData *)dequeueData
{
    @synchronized (timeLock) {
        NSData *inputData = [self peekData];
        if (inputData) {
            [inputDataQueue removeObjectAtIndex:0];
            self.bytesAvailable -= [inputData length];
        }
        if ([inputDataQueue count] == 0) {
            self.dataAvailable = NO;
        }
        return inputData;
    }
}

-(NSData *)dequeueBytes:(NSUInteger)nBytes
{
    @synchronized (timeLock) {
        NSMutableData *outputData = [[NSMutableData alloc] initWithCapacity:nBytes];
        
        if (doneDownloading && nBytes > self.bytesAvailable) {
            nBytes = self.bytesAvailable;
        }

        while ([outputData length] < nBytes) {
            NSData *inputData = [self peekData];
            if (inputData) {
                NSUInteger inputSize = [inputData length];
                NSUInteger chunkSize = nBytes - [outputData length];

                if (inputSize <= chunkSize) {
                    [self dequeueData];
                    [outputData appendData:inputData];
                } else {
                    // Split the buffer for convenience. Not super efficient. :)
                    NSData *dataHead = [inputData subdataWithRange:NSMakeRange(0, chunkSize)];
                    NSData *dataTail = [inputData subdataWithRange:NSMakeRange(chunkSize, inputSize - chunkSize)];
                    inputDataQueue[0] = dataTail;
                    self.bytesAvailable -= [dataHead length];
                    [outputData appendData:dataHead];
                }
            } else {
                // Ran out of input data
                break;
            }
        }

        if (doneDownloading && self.bytesAvailable == 0) {
            // Ran out of input data.
            self.state = OGVInputStreamStateDone;
        }

        return outputData;
    }
}


#pragma mark - NSURLConnectionDataDelegate methods

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    @synchronized (timeLock) {
        self.state = OGVInputStreamStateReading;
        _mediaType = [[OGVMediaType alloc] initWithString:response.MIMEType];
    }
}

- (void)connection:(NSURLConnection *)sender didReceiveData:(NSData *)data
{
    @synchronized (timeLock) {
        [self queueData:data];
        
        // @todo once moved to its own thread, throttle this connection!
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)sender
{
    @synchronized (timeLock) {
        doneDownloading = YES;
        self.dataAvailable = ([inputDataQueue count] > 0);

        if (waitingForDataSemaphore) {
            dispatch_semaphore_signal(waitingForDataSemaphore);
        }
    }
}

- (void)connection:(NSURLConnection *)sender didFailWithError:(NSError *)error
{
    @synchronized (timeLock) {
        // @todo if we're in read state, let us read out the rest of data
        // already fetched!
        self.state = OGVInputStreamStateFailed;
        self.dataAvailable = ([inputDataQueue count] > 0);

        if (waitingForDataSemaphore) {
            dispatch_semaphore_signal(waitingForDataSemaphore);
        }
    }
}

@end
