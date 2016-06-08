//
//  SMBSessionUploadTask.m
//  TOSMBClientExample
//
//  Created by Narendra on 02/06/16.
//  Copyright © 2016 Narendra. All rights reserved.
//

#import "SMBSessionUploadTask.h"

#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>

#import "TOSMBClient.h"
#import "smb_session.h"
#import "smb_share.h"
#import "smb_file.h"
#import "smb_defs.h"
#import "smb_dir.h"

#include <arpa/inet.h>
#include <string.h>

 #define BUFFER_UPLOAD_SIZE   (0xFFFF - 64)

// #define BUFFER_UPLOAD_SIZE  4559

// -------------------------------------------------------------------------
// Private methods in TOSMBSession shared here

@interface TOSMBSession ()

@property (readonly) NSOperationQueue *downloadsQueue;
@property (readonly) NSOperationQueue *uploadsQueue;
@property (readonly) dispatch_queue_t serialQueue;

- (NSError *)attemptConnectionWithSessionPointer:(smb_session *)session;
- (NSString *)shareNameFromPath:(NSString *)path;
- (NSString *)filePathExcludingSharePathFromPath:(NSString *)path;
- (void)resumeDownloadTask:(TOSMBSessionDownloadTask *)task;

@end

// -------------------------------------------------------------------------

@interface SMBSessionUploadTask ()

@property (assign, readwrite) TOSMBSessionUploadTaskState state;

@property (nonatomic, strong, readwrite) NSString *sourceFilePath;
@property (nonatomic, strong, readwrite) NSString *destinationFilePath;
@property (nonatomic, strong) NSString *tempFilePath;

@property (nonatomic, weak, readwrite) TOSMBSession *session;
@property (nonatomic, strong) TOSMBSessionFile *file;
@property (assign) smb_session *uploadSession;

@property (nonatomic, strong) NSBlockOperation *uploadOperation;


@property (assign, readwrite) int64_t countOfBytesReceived;
@property (assign, readwrite) int64_t countOfBytesExpectedToReceive;

@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTaskIdentifier;

/** Feedback handlers */
@property (nonatomic, weak) id<TOSMBSessionUploadTaskDelegate> delegate;

@property (nonatomic, copy) void (^progressHandler)(uint64_t totalBytesWritten, uint64_t totalBytesExpected);
@property (nonatomic, copy) void (^successHandler)(NSString *filePath);
@property (nonatomic, copy) void (^failHandler)(NSError *error);

/* Download methods */
- (void)setupUploadOperation;

- (void)performUploadWithOperation:(__weak NSBlockOperation *)weakOperation;
- (TOSMBSessionFile *)requestFileForItemAtPath:(NSString *)filePath inTree:(smb_tid)treeID;

/* File Path Methods */
- (NSString *)hashForFilePath;
- (NSString *)filePathForTemporaryDestination;
- (NSString *)finalFilePathForDownloadedFile;
- (NSString *)documentsDirectory;

/* Feedback events sent to either the delegate or callback blocks */
- (void)didSucceedWithFilePath:(NSString *)filePath;
- (void)didFailWithError:(NSError *)error;
- (void)didUpdateWriteBytes:(uint64_t)bytesWritten totalBytesWritten:(uint64_t)totalBytesWritten totalBytesExpected:(uint64_t)totalBytesExpected;
- (void)didResumeAtOffset:(uint64_t)bytesWritten totalBytesExpected:(uint64_t)totalBytesExpected;


@end

@implementation SMBSessionUploadTask

- (instancetype)init
{
    //This class cannot be instantiated on its own.
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (instancetype)initWithSession:(TOSMBSession *)session filePath:(NSString *)filePath destinationPath:(NSString *)destinationPath delegate:(id<TOSMBSessionUploadTaskDelegate>)delegate
{
    if (self = [super init]) {
        _session = session;
        _sourceFilePath = filePath;
        _destinationFilePath = destinationPath.length ? destinationPath : [self documentsDirectory];
        _delegate = delegate;
        
        _tempFilePath = [self filePathForTemporaryDestination];
    }
    
    return self;
}

- (instancetype)initWithSession:(TOSMBSession *)session filePath:(NSString *)filePath destinationPath:(NSString *)destinationPath progressHandler:(id)progressHandler successHandler:(id)successHandler failHandler:(id)failHandler
{
    if (self = [super init]) {
        _session = session;
        _sourceFilePath = filePath;
        _destinationFilePath = destinationPath.length ? destinationPath : [self documentsDirectory];
        
        _progressHandler = progressHandler;
        _successHandler = successHandler;
        _failHandler = failHandler;
        
        _tempFilePath = [self filePathForTemporaryDestination];
    }
    
    return self;
}

- (void)dealloc
{
    // This is called after TOSMBSession dealloc is called, where the smb_session object is released.
    // As so, probably this part is not required at all, so I'm commenting it out.
    // Anyway, even if my assumptions are wrong, we should firstly check if the whole session still exists.
    
    //    if (self.downloadSession && self.session) {
    //        smb_session_destroy(self.downloadSession);
    //    }
}

#pragma mark - Temporary Destination Methods -
- (NSString *)filePathForTemporaryDestination
{
    NSString *fileName = [[self hashForFilePath] stringByAppendingPathExtension:@"smb.data"];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
}

- (NSString *)hashForFilePath
{
    NSString *filePath = self.sourceFilePath.lowercaseString;
    
    NSData *data = [filePath dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    
    CC_SHA1(data.bytes, (unsigned int)data.length, digest);
    
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++)
    {
        [output appendFormat:@"%02x", digest[i]];
    }
    
    return [NSString stringWithString:output];
}

- (NSString *)finalFilePathForDownloadedFile
{
    NSString *path = self.destinationFilePath;
    
    //Check to ensure the destination isn't referring to a file name
    NSString *fileName = [path lastPathComponent];
    BOOL isFile = ([fileName rangeOfString:@"."].location != NSNotFound && [fileName characterAtIndex:0] != '.');
    
    NSString *folderPath = nil;
    if (isFile) {
        folderPath = [path stringByDeletingLastPathComponent];
    }
    else {
        fileName = [self.sourceFilePath lastPathComponent];
        folderPath = path;
    }
    
    path = [folderPath stringByAppendingPathComponent:fileName];
    
    //If a file with that name already exists in the destination directory, append a number on the end of the file name
    NSString *newFilePath = path;
    NSString *newFileName = fileName;
    NSInteger index = 1;
    while ([[NSFileManager defaultManager] fileExistsAtPath:newFilePath]) {
        newFileName = [NSString stringWithFormat:@"%@-%ld.%@", [fileName stringByDeletingPathExtension], (long)index++, [fileName pathExtension]];
        newFilePath = [folderPath stringByAppendingPathComponent:newFileName];
    }
    
    return newFilePath;
}

- (NSString *)documentsDirectory
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
    return basePath;
}


#pragma mark - Public Control Methods -
- (void)resume
{
    if (self.state == TOSMBSessionUploadTaskStateRunning)
        return;
    
    [self setupUploadOperation];
    [self.session.uploadsQueue addOperation:self.uploadOperation];
    self.state = TOSMBSessionUploadTaskStateRunning;
}

- (void)suspend
{
    if (self.state != TOSMBSessionUploadTaskStateRunning)
        return;
    
    [self.uploadOperation cancel];
    self.state = TOSMBSessionUploadTaskStateSuspended;
    self.uploadOperation = nil;
}

- (void)cancel
{
    if (self.state != TOSMBSessionUploadTaskStateRunning)
        return;
    
    id deleteBlock = ^{
        [[NSFileManager defaultManager] removeItemAtPath:self.tempFilePath error:nil];
    };
    
    NSBlockOperation *deleteOperation = [[NSBlockOperation alloc] init];
    [deleteOperation addExecutionBlock:deleteBlock];
    [deleteOperation addDependency:self.uploadOperation];
    [self.session.uploadsQueue addOperation:deleteOperation];
    
    [self.uploadOperation cancel];
    self.state = TOSMBSessionUploadTaskStateCancelled;
    
    self.uploadOperation = nil;
}

#pragma mark - Feedback Methods -
- (BOOL)canBeResumed
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.tempFilePath] == NO)
        return NO;
    
    NSDate *modificationTime = [[[NSFileManager defaultManager] attributesOfItemAtPath:self.tempFilePath error:nil] fileModificationDate];
    if ([modificationTime isEqual:self.file.modificationTime] == NO) {
        return NO;
    }
    
    return YES;
}

- (void)didSucceedWithFilePath:(NSString *)filePath
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(uploadTask:didFinishUploadingToPath:)])
            
            [self.delegate uploadTask:self didFinishUploadingToPath:filePath];
        
        if (self.successHandler)
            self.successHandler(filePath);
    });
}

- (void)didSucceedCreatePath:(NSString *)filePath
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(uploadTask:didFinishCreatingPath:)])
            
            [self.delegate uploadTask:self didFinishCreatingPath:filePath];
        
        if (self.successHandler)
            self.successHandler(filePath);
    });
}

- (void)didFailWithError:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(uploadTask:didCompleteWithError:)])
            
            [self.delegate uploadTask:self didCompleteWithError:error];
        
        if (self.failHandler)
            self.failHandler(error);
    });
}

- (void)didFailCreatingFolderWithError:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(uploadTask:didCompleteCreatingPathWithError:)])
            
            [self.delegate uploadTask:self didCompleteCreatingPathWithError:error];
        
        if (self.failHandler)
            self.failHandler(error);
    });
}

- (void)didUpdateWriteBytes:(uint64_t)bytesWritten totalBytesWritten:(uint64_t)totalBytesWritten totalBytesExpected:(uint64_t)totalBytesExpected
{
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(uploadTask:didWriteBytes:totalBytesReceived:totalBytesExpectedToReceive:)])
            [self.delegate uploadTask:self didWriteBytes:bytesWritten totalBytesReceived:self.countOfBytesReceived totalBytesExpectedToReceive:self.countOfBytesExpectedToReceive];
        
        if (self.progressHandler)
            self.progressHandler(self.countOfBytesReceived, self.countOfBytesExpectedToReceive);
    }];
}

- (void)didResumeAtOffset:(uint64_t)bytesWritten totalBytesExpected:(uint64_t)totalBytesExpected
{
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(uploadTask:didResumeAtOffset:totalBytesExpectedToReceive:)])
            [self.delegate uploadTask:self didResumeAtOffset:bytesWritten totalBytesExpectedToReceive:totalBytesExpected];
    }];
}

#pragma mark - Downloading -
- (TOSMBSessionFile *)requestFileForItemAtPath:(NSString *)filePath inTree:(smb_tid)treeID
{
    const char *fileCString = [filePath cStringUsingEncoding:NSUTF8StringEncoding];
    smb_stat fileStat = smb_fstat(self.uploadSession, treeID, fileCString);
    if (!fileStat)
        return nil;
    
    TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:fileStat session:self.session parentDirectoryFilePath:filePath];
    
    //naren commented and added new
    // TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:fileStat session:nil parentDirectoryFilePath:filePath];
    
    smb_stat_destroy(fileStat);
    
    return file;
}

- (void)setupUploadOperation
{
    if (self.uploadOperation)
        return;
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    __weak typeof (self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    
    id executionBlock = ^{
        [weakSelf performUploadWithOperation:weakOperation];
    };
    [operation addExecutionBlock:executionBlock];
    operation.completionBlock = ^{
        weakSelf.uploadOperation = nil;
    };
    
    self.uploadOperation = operation;
}

-(void)performUploadTaskWithFile:(NSString *)filePath destinationPath:(NSString *)destinationPath;
{
    
    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
        //Background Thread

        smb_tid treeID = 0;
        smb_fd fileID = 0;
        // private variables
        //Perform the file download
        uint64_t read_length = 1;
        char *buffer = malloc(BUFFER_UPLOAD_SIZE);
        
        uint64_t  length = 0, write_total_length = 0;
        FILE    *fp;
        // uint64_t   read_length = 1;
        // uint64_t bytesRead = 0;
        // char *buffer = malloc(BUFFER_UPLOAD_SIZE);
        
        //  char     buffer[BUFFER_UPLOAD_SIZE];
        
        //---------------------------------------------------------------------------------------
        //Set up a cleanup block that'll release any handles before cancellation
        void (^cleanup)(void) = ^{
            
            //Release the background task handler, making the app eligible to be suspended now
            if (self.backgroundTaskIdentifier)
                [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskIdentifier];
            
            if (self.uploadOperation && treeID)
                smb_tree_disconnect(self.uploadSession, treeID);
            
            if (self.uploadSession && fileID)
                smb_fclose(self.uploadSession, fileID);
            
            if (self.uploadSession) {
                smb_session_destroy(self.uploadSession);
                self.uploadSession = nil;
            }
        };
        
        //---------------------------------------------------------------------------------------
        //Connect to SMB device
        
        self.uploadSession = smb_session_new();
        
        //First, check to make sure the server is there, and to acquire its attributes
        __block NSError *error = nil;
        dispatch_sync(self.session.serialQueue, ^{
            error = [self.session attemptConnectionWithSessionPointer:self.uploadSession];
        });
        if (error) {
            [self didFailWithError:error];
            cleanup();
            return;
        }
        
        //---------------------------------------------------------------------------------------
        //Connect to share
        
        //Next attach to the share we'll be using
        NSString *shareName = [self.session shareNameFromPath:self.sourceFilePath];
        const char *shareCString = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
        smb_tree_connect(self.uploadSession, shareCString, &treeID);
        if (!treeID) {
            [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed)];
            cleanup();
            return;
        }
        
        //---------------------------------------------------------------------------------------
        //Find the target file
        
        NSString *formattedPath = [self.session filePathExcludingSharePathFromPath:self.sourceFilePath];
        formattedPath = [NSString stringWithFormat:@"\\%@",formattedPath];
        formattedPath = [formattedPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\\\"];
        
        //---------------------------------------------------------------------------------------
        //Open the file handle
        
        NSString *imagePath = [[NSBundle mainBundle] pathForResource:@"CachesApplicationLogs" ofType:@"zip"];
        
        formattedPath = [NSString stringWithFormat:@"%@\\%@",formattedPath,imagePath.lastPathComponent];
        
        smb_fopen(self.uploadSession, treeID, [formattedPath cStringUsingEncoding:NSUTF8StringEncoding], SMB_MOD_RW, &fileID);
        if (!fileID) {
            [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
            cleanup();
            return;
        }
        
        //---------------------------------------------------------------------------------------
        //Open the file handle
        // perform the file upload
        
        fp = fopen([imagePath UTF8String],"r");
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:imagePath];
        
        // verify ths code later
        unsigned long long seekOffset = (ssize_t)[fileHandle seekToEndOfFile];
        self.countOfBytesExpectedToReceive = seekOffset;
        
            while (read_length != 0)
            {
                //Write the bytes to the network device
                @autoreleasepool {
                    read_length = fread(buffer, 1, BUFFER_UPLOAD_SIZE, fp);

                    if (read_length != 0)
                    {
                        
                        if(read_length < BUFFER_UPLOAD_SIZE)
                        {
                            NSLog(@"read_length - %llu",read_length);
                            NSLog(@"***** read_length errorrrrr ****");

 
                        }else if (read_length > BUFFER_UPLOAD_SIZE){
                            
                            NSLog(@"***** GREATER ERROR ****");
                            NSLog(@"read_length - %llu",read_length);
                            NSLog(@"***** read_length errorrrrr ****");

                        }
                        
                        length = smb_fwrite(self.uploadSession, fileID, buffer, read_length);
                        if (length != -1)
                        {
                            write_total_length += length;
                        }
                        else
                        {
                            NSString * errorMessageString = [NSString stringWithFormat:@"Failed to upload data."];
                            error = [NSError errorWithDomain:@"SMBClient" code:-1 userInfo:@{NSLocalizedDescriptionKey:errorMessageString}];
                            [self didFailWithError:error];
                            break;
                        }
        
                        self.countOfBytesReceived += read_length;
        
                        [self didUpdateWriteBytes:length totalBytesWritten:self.countOfBytesReceived totalBytesExpected:self.countOfBytesExpectedToReceive];
        
                    }
                }
            }
        
        [fileHandle closeFile];
        free(buffer);
        
        self.state =TOSMBSessionUploadTaskStateCompleted;
        
        //Alert the delegate that we finished, so they may perform any additional cleanup operations
        [self didSucceedWithFilePath:formattedPath]; // update path with required data
        
        //Perform a final cleanup of all handles and references
        cleanup();
        
    });
}

-(void)uploadMultipleFiles:(NSMutableArray *)filePaths destinationPath:(NSString *)destinationPath;
{
    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void)
    {
           smb_tid treeID = 0;
           smb_fd fileID = 0;
           // private variables
           //Perform the file download
//           uint64_t read_length = 1;
//           char *buffer = malloc(BUFFER_UPLOAD_SIZE);
//           uint64_t  length = 0, write_total_length = 0;
           FILE    *fp;
           
           //---------------------------------------------------------------------------------------
           //Set up a cleanup block that'll release any handles before cancellation
           void (^cleanup)(void) = ^{
               
               //Release the background task handler, making the app eligible to be suspended now
               if (self.backgroundTaskIdentifier)
                   [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskIdentifier];
               
               if (self.uploadOperation && treeID)
                   smb_tree_disconnect(self.uploadSession, treeID);
               
               if (self.uploadSession && fileID)
                   smb_fclose(self.uploadSession, fileID);
               
               if (self.uploadSession) {
                   smb_session_destroy(self.uploadSession);
                   self.uploadSession = nil;
               }
           };
           
           //---------------------------------------------------------------------------------------
           //Connect to SMB device
           
           self.uploadSession = smb_session_new();
           
           //First, check to make sure the server is there, and to acquire its attributes
           __block NSError *error = nil;
           dispatch_sync(self.session.serialQueue, ^{
               error = [self.session attemptConnectionWithSessionPointer:self.uploadSession];
           });
           if (error) {
               [self didFailWithError:error];
               cleanup();
               return;
           }
           
           //---------------------------------------------------------------------------------------
           //Connect to share
           
           //Next attach to the share we'll be using
           NSString *shareName = [self.session shareNameFromPath:self.sourceFilePath];
           const char *shareCString = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
           smb_tree_connect(self.uploadSession, shareCString, &treeID);
           if (!treeID) {
               [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed)];
               cleanup();
               return;
           }
           
           //---------------------------------------------------------------------------------------
           //Find the target file
           
           NSString *formattedPath = [self.session filePathExcludingSharePathFromPath:self.sourceFilePath];
           formattedPath = [NSString stringWithFormat:@"\\%@",formattedPath];
           formattedPath = [formattedPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\\\"];
           
           //---------------------------------------------------------------------------------------
           //Open the file handle
           
           for (NSString *imagePath in filePaths) {
               
               
             //  NSString *imagePath = [[NSBundle mainBundle] pathForResource:@"Dicom" ofType:@"zip"];
               
              NSString* newFormattedPath = [NSString stringWithFormat:@"%@\\%@",formattedPath,imagePath.lastPathComponent];
               
               smb_fopen(self.uploadSession, treeID, [newFormattedPath cStringUsingEncoding:NSUTF8StringEncoding], SMB_MOD_RW, &fileID);
               if (!fileID) {
                   [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
                   cleanup();
                   return;
               }
               
               //---------------------------------------------------------------------------------------
               //Open the file handle
               // perform the file upload
               
               fp = fopen([imagePath UTF8String],"r");
               NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:imagePath];
               
               // verify ths code later
               unsigned long long seekOffset = (ssize_t)[fileHandle seekToEndOfFile];
               self.countOfBytesExpectedToReceive = seekOffset;
               
               uint64_t read_length = 1;
               char *buffer = malloc(BUFFER_UPLOAD_SIZE);
               uint64_t  length = 0, write_total_length = 0;
               
               while (read_length != 0)
               {
                   //Write the bytes to the network device
                   @autoreleasepool {
                       read_length = fread(buffer, 1, BUFFER_UPLOAD_SIZE, fp);
                       if (read_length != 0)
                       {
                           length = smb_fwrite(self.uploadSession, fileID, buffer, read_length);
                           if (length != -1)
                           {
                               write_total_length += length;
                           }
                           else
                           {
                               NSString * errorMessageString = [NSString stringWithFormat:@"Failed to upload data."];
                               error = [NSError errorWithDomain:@"SMBClient" code:-1 userInfo:@{NSLocalizedDescriptionKey:errorMessageString}];
                               [self didFailWithError:error];
                               break;
                           }
                           
                           self.countOfBytesReceived += length;
                           
                           [self didUpdateWriteBytes:length totalBytesWritten:self.countOfBytesReceived totalBytesExpected:self.countOfBytesExpectedToReceive];
                           
                       }
                   }
               }
               
               if (buffer != nil) {
                   free(buffer);
               }
               [fileHandle closeFile];
               
               self.state =TOSMBSessionUploadTaskStateCompleted;
               //Alert the delegate that we finished, so they may perform any additional cleanup operations
               [self didSucceedWithFilePath:newFormattedPath]; // update path with required data
           }
        
        
        //Perform a final cleanup of all handles and references
           cleanup();
        
    });
}



- (void)performUploadWithOperation:(__weak NSBlockOperation *)weakOperation
{
    if (weakOperation.isCancelled)
        return;
    
    smb_tid treeID = 0;
    smb_fd fileID = 0;
    // private variables
    ssize_t  length = 0, write_total_length = 0;
    FILE    *fp;
    size_t   read_length = 1;
    char *buffer = malloc(BUFFER_UPLOAD_SIZE);
    
    //---------------------------------------------------------------------------------------
    //Set up a cleanup block that'll release any handles before cancellation
    void (^cleanup)(void) = ^{
        
        //Release the background task handler, making the app eligible to be suspended now
        if (self.backgroundTaskIdentifier)
            [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskIdentifier];
        
        if (self.uploadOperation && treeID)
            smb_tree_disconnect(self.uploadSession, treeID);
        
        if (self.uploadSession && fileID)
            smb_fclose(self.uploadSession, fileID);
        
        if (self.uploadSession) {
            smb_session_destroy(self.uploadSession);
            self.uploadSession = nil;
        }
    };
    
    //---------------------------------------------------------------------------------------
    //Connect to SMB device
    
    self.uploadSession = smb_session_new();
    
    //First, check to make sure the server is there, and to acquire its attributes
    __block NSError *error = nil;
    dispatch_sync(self.session.serialQueue, ^{
        error = [self.session attemptConnectionWithSessionPointer:self.uploadSession];
    });
    if (error) {
        [self didFailWithError:error];
        cleanup();
        return;
    }
    
    if (weakOperation.isCancelled) {
        cleanup();
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Connect to share
    
    //Next attach to the share we'll be using
    NSString *shareName = [self.session shareNameFromPath:self.sourceFilePath];
    const char *shareCString = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    smb_tree_connect(self.uploadSession, shareCString, &treeID);
    if (!treeID) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed)];
        cleanup();
        return;
    }
    
    if (weakOperation.isCancelled) {
        cleanup();
        return;
    }

    //---------------------------------------------------------------------------------------
    //Find the target file
    
    NSString *formattedPath = [self.session filePathExcludingSharePathFromPath:self.sourceFilePath];
    formattedPath = [NSString stringWithFormat:@"\\%@",formattedPath];
    formattedPath = [formattedPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\\\"];
    
    // ????????? check he is it require for upload task ????????
    // ?????????????????????????????????????????????????????????
    
    //Get the file info we'll be working off
    self.file = [self requestFileForItemAtPath:formattedPath inTree:treeID];
    if (self.file == nil) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
        cleanup();
        return;
    }
    
    if (weakOperation.isCancelled) {
        cleanup();
        return;
    }
    
//    if (self.file.directory) {
//        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeDirectoryDownloaded)];
//        cleanup();
//        return;
//    }
    
   // self.countOfBytesExpectedToReceive = self.file.fileSize;

    //---------------------------------------------------------------------------------------
    //Open the file handle
    
    NSString *imagePath = [[NSBundle mainBundle] pathForResource:@"Zuno3" ofType:@"zip"];
    formattedPath = [NSString stringWithFormat:@"%@\\%@",formattedPath,imagePath.lastPathComponent];
    
    smb_fopen(self.uploadSession, treeID, [formattedPath cStringUsingEncoding:NSUTF8StringEncoding], SMB_MOD_RW, &fileID);
    if (!fileID) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
        cleanup();
        return;
    }
    
    if (weakOperation.isCancelled) {
        cleanup();
        return;
    }
    

    //---------------------------------------------------------------------------------------
    //Open the file handle
    // perform the file upload

    fp = fopen([imagePath UTF8String],"r");
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:imagePath];
    
    // verify ths code later
    unsigned long long seekOffset = (ssize_t)[fileHandle seekToEndOfFile];
    self.countOfBytesExpectedToReceive = seekOffset;
    
//    while (read_length != 0)
//    {
//        //Write the bytes to the network device
//        
//        @autoreleasepool {
//            read_length = fread(buffer, 1, BUFFER_UPLOAD_SIZE, fp);
//            if (read_length != 0)
//            {
//                length = smb_fwrite(self.uploadSession, fileID, buffer, read_length);
//                if (length != -1)
//                {
//                    write_total_length += length;
//                }
//                else
//                {
//                   // success = NO;
//                    break;
//                }
//                
//                self.countOfBytesReceived += length;
//                
//                [self didUpdateWriteBytes:length totalBytesWritten:self.countOfBytesReceived totalBytesExpected:self.countOfBytesExpectedToReceive];
//                
//            }
//        }
//        
//        if (weakOperation.isCancelled)
//            break;
//    }
//    
//    free(buffer);
//    [fileHandle closeFile];
    
    while (read_length != 0)
    {
        @autoreleasepool {
            read_length = fread(&buffer, 1, BUFFER_UPLOAD_SIZE, fp);
            if (read_length != 0)
            {
                length = smb_fwrite(self.uploadSession, fileID, (void *)&buffer, read_length);
                if (length != -1)
                {
                    write_total_length += length;
                }
                else
                {
                   // success = NO;
                    NSString * errorMessageString = [NSString stringWithFormat:@"Failed to upload data."];
                    error = [NSError errorWithDomain:@"SMBClient" code:-1 userInfo:@{NSLocalizedDescriptionKey:errorMessageString}];
                    [self didFailWithError:error];
                    break;
                }
            }
        }
        
        self.countOfBytesReceived += length;
        [self didUpdateWriteBytes:length totalBytesWritten:self.countOfBytesReceived totalBytesExpected:self.countOfBytesExpectedToReceive];

    }
    free(buffer);
    [fileHandle closeFile];
    
    if (weakOperation.isCancelled) {
        cleanup();
        return;
    }
    
    self.state =TOSMBSessionUploadTaskStateCompleted;
    
    //Alert the delegate that we finished, so they may perform any additional cleanup operations
    [self didSucceedWithFilePath:formattedPath]; // update path with required data
    
    //Perform a final cleanup of all handles and references
    cleanup();
}

-(void)createFolderWithPath:(NSString *)folderPath withFolderName:(NSString *)folderName;
{
    
    smb_tid treeID = 0;
    smb_fd fileID = 0;
    int32_t result = NT_STATUS_SUCCESS;
    __block NSError *error = nil;
    
    // variable to contain a NetBios name service
    netbios_ns * netbiosNameService;

    
    //---------------------------------------------------------------------------------------
    //Set up a cleanup block that'll release any handles before cancellation
    void (^cleanup)(void) = ^{
        
        //Release the background task handler, making the app eligible to be suspended now
        if (self.backgroundTaskIdentifier)
            [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskIdentifier];
        
        if (treeID)
            smb_tree_disconnect(self.uploadSession, treeID);
        
        if (fileID)
            smb_fclose(self.uploadSession, fileID);
        
        if (self.uploadSession) {
            smb_session_destroy(self.uploadSession);
            self.uploadSession = nil;
        }
    };
    
    //---------------------------------------------------------------------------------------
    //Connect to SMB device
    
    // create a NetBios name service instance
    netbiosNameService = netbios_ns_new();
    // variable to contain the ip address of the destination host
    struct sockaddr_in ipAddress;

    // make sure the requested host is resolveable and fetch it's IP address, otherwise - return error code
    int resolveResult = netbios_ns_resolve(netbiosNameService, [self.session.hostName cStringUsingEncoding:NSUTF8StringEncoding], NETBIOS_FILESERVER, &ipAddress.sin_addr.s_addr);
    
    if (resolveResult != 0)
    {
        // debug print
        NSString * errorMessageString = [NSString stringWithFormat:@"Failed to reverse lookup, could not resolve the host: %@ IP address, libDSM errorCode: %d", self.session.hostName, resolveResult];
       error = [NSError errorWithDomain:@"SMBClient" code:resolveResult userInfo:@{NSLocalizedDescriptionKey:errorMessageString}];
        [self didFailCreatingFolderWithError:error];
        cleanup();
        return;
    }


    //---------------------------------------------------------------------------------------
    //Connect to SMB device
    
    self.uploadSession = smb_session_new();
    
    //First, check to make sure the server is there, and to acquire its attributes
    dispatch_sync(self.session.serialQueue, ^{
        error = [self.session attemptConnectionWithSessionPointer:self.uploadSession];
    });
    if (error) {
        [self didFailCreatingFolderWithError:error];
        cleanup();
        return;
    }

    
    //---------------------------------------------------------------------------------------
    //Connect to share
    
    //Next attach to the share we'll be using
    NSString *shareName = [self.session shareNameFromPath:self.sourceFilePath];
    const char *shareCString = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    smb_tree_connect(self.uploadSession, shareCString, &treeID);
    if (!treeID) {
        [self didFailCreatingFolderWithError:errorForErrorCode(TOSMBSessionErrorCodeShareConnectionFailed)];
        cleanup();
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Find the target file
    
    NSString *formattedPath = [self.session filePathExcludingSharePathFromPath:folderPath];
    formattedPath = [NSString stringWithFormat:@"\\%@",formattedPath];
    formattedPath = [formattedPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\\\"];


    formattedPath = [NSString stringWithFormat:@"%@\\%@",formattedPath,folderName];
    NSLog(@"formated path %@",formattedPath);

    //---------------------------------------------------------------------------------------
    //Create Directory/Folder
    
    result = smb_directory_create(self.uploadSession,treeID , [formattedPath cStringUsingEncoding:NSUTF8StringEncoding]);
    
    if (result == 0)
    {
        [self didSucceedCreatePath: formattedPath];
    }
    else
    {
        [self didFailCreatingFolderWithError:errorForErrorCode(TOSMBSessionErrorCodeFileNotFound)];
        cleanup();
        return;
    }
    
    //perform cleanup
    cleanup();
}


@end
