//
//  SMBSessionUploadTask.h
//  TOSMBClientExample
//
//  Created by Narendra on 02/06/16.
//  Copyright © 2016 Narendra. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TOSMBConstants.h"

@class TOSMBSession;
@class SMBSessionUploadTask;

@protocol TOSMBSessionUploadTaskDelegate <NSObject>

@optional

/**
 Delegate event that is called when the file has successfully completed uploading.
 
 @param uploadTask The upload task object calling this delegate method.
 @param destinationPath The absolute file path to the file.
 */


-(void)uploadTask:(SMBSessionUploadTask *)uploadTask didFinishUploadingToPath:(NSString *)destinationPath;

/**
 Delegate event that is called when the path/folder has successfully created.
 
 @param uploadTask The upload task object calling this delegate method.
 @param destinationPath The absolute file path to the folder.
 */

-(void)uploadTask:(SMBSessionUploadTask *)uploadTask didFinishCreatingPath:(NSString *)destinationPath;


/**
 Delegate event that is called when the folder/path creating did not successfully complete.
 
 @param uploadTask The upload task object calling this delegate method.
 @param error The error describing why the task failed.
 */

-(void)uploadTask:(SMBSessionUploadTask *)uploadTask didCompleteCreatingPathWithError:(NSError *)error;


/**
 Delegate event that is called periodically as the upload progresses, updating the delegate with the amount of data that has been uploaded.
 
 @param uploadTask The download task object calling this delegate method.
 @param bytesWritten The number of bytes written in this particular iteration
 @param totalBytesWrite The total number of bytes written to disk so far
 @param totalBytesTowWrite The expected number of bytes encompassing this entire file
 */
- (void)uploadTask:(SMBSessionUploadTask *)uploadTask
       didWriteBytes:(uint64_t)bytesWritten
  totalBytesReceived:(uint64_t)totalBytesReceived
totalBytesExpectedToReceive:(int64_t)totalBytesToReceive;

/**
 Delegate event that is called when a file upload that was previously suspended is now resumed.
 
 @param uploadTask The upload task object calling this delegate method.
 @param byteOffset The byte offset at which the download resumed.
 @param totalBytesToWrite The number of bytes expected to write for this entire file.
 */
- (void)uploadTask:(SMBSessionUploadTask *)uploadTask
   didResumeAtOffset:(uint64_t)byteOffset
totalBytesExpectedToReceive:(uint64_t)totalBytesToReceive;

/**
 Delegate event that is called when the file upload did not successfully complete.
 
 @param uploadTask The upload task object calling this delegate method.
 @param error The error describing why the task failed.
 */
- (void)uploadTask:(SMBSessionUploadTask *)uploadTask didCompleteWithError:(NSError *)error;

@end


@interface SMBSessionUploadTask : NSObject

/** The parent session that is managing this upload task. (Retained by this class) */
@property (readonly, weak) TOSMBSession *session;

/** The file path to the target file on the SMB network device. */
@property (readonly) NSString *sourceFilePath;

/** The target file path that the file will be uploaded to. */
@property (readonly) NSString *destinationFilePath;

/** The number of bytes presently uploaded by this task */
@property (readonly) int64_t countOfBytesReceived;

/** The total number of bytes we expect to uploaded */
@property (readonly) int64_t countOfBytesExpectedToReceive;

/** Returns if upload data from a suspended task exists */
@property (readonly) BOOL canBeResumed;

/** The state of the upload task. */
@property (readonly) TOSMBSessionUploadTaskState state;



-(void)createFolderWithPath:(NSString *)folderPath withFolderName:(NSString *)folderName;

- (instancetype)initWithSession:(TOSMBSession *)session filePath:(NSString *)filePath destinationPath:(NSString *)destinationPath delegate:(id<TOSMBSessionUploadTaskDelegate>)delegate;

-(void)performUploadTaskWithFile:(NSString *)filePath destinationPath:(NSString *)destinationPath;
-(void)uploadMultipleFiles:(NSMutableArray *)filePaths destinationPath:(NSString *)destinationPath;


/**
 Resumes an existing upload, or starts a new one otherwise.
 
 uploads are resumed if there is already data for this file on disk,
 and the modification date of that file matches the one on the network device.
 */
- (void)resume;

/**
 Suspends a upload and halts network activity.
 */
- (void)suspend;

/**
 Cancels a upload, and deletes all related transient data on disk.
 */
- (void)cancel;



@end
