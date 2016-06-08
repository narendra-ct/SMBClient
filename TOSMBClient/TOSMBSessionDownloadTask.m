//
// TOSMBDownloadTask.m
// Copyright 2015-2016 Timothy Oliver
//
// This file is dual-licensed under both the MIT License, and the LGPL v2.1 License.
//
// -------------------------------------------------------------------------------
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
// -------------------------------------------------------------------------------

#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>

#import "TOSMBSessionDownloadTask.h"
#import "TOSMBClient.h"
#import "smb_session.h"
#import "smb_share.h"
#import "smb_file.h"
#import "smb_defs.h"
#import "smb_dir.h"

#include <arpa/inet.h>
#include <string.h>

#define BUFFER_UPLOAD_SIZE   (0xFFFF - 64)



// -------------------------------------------------------------------------
// Private methods in TOSMBSession shared here

@interface TOSMBSession ()

@property (readonly) NSOperationQueue *downloadsQueue;

@property (readonly) dispatch_queue_t serialQueue;

- (NSError *)attemptConnectionWithSessionPointer:(smb_session *)session;
- (NSString *)shareNameFromPath:(NSString *)path;
- (NSString *)filePathExcludingSharePathFromPath:(NSString *)path;
- (void)resumeDownloadTask:(TOSMBSessionDownloadTask *)task;

@end

// -------------------------------------------------------------------------

@interface TOSMBSessionDownloadTask ()

@property (assign, readwrite) TOSMBSessionDownloadTaskState state;

@property (nonatomic, strong, readwrite) NSString *sourceFilePath;
@property (nonatomic, strong, readwrite) NSString *destinationFilePath;
@property (nonatomic, strong) NSString *tempFilePath;

@property (nonatomic, weak, readwrite) TOSMBSession *session;
@property (nonatomic, strong) TOSMBSessionFile *file;
@property (assign) smb_session *downloadSession;
@property (nonatomic, strong) NSBlockOperation *downloadOperation;

@property (assign, readwrite) int64_t countOfBytesReceived;
@property (assign, readwrite) int64_t countOfBytesExpectedToReceive;

@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTaskIdentifier;

/** Feedback handlers */
@property (nonatomic, weak) id<TOSMBSessionDownloadTaskDelegate> delegate;

@property (nonatomic, copy) void (^progressHandler)(uint64_t totalBytesWritten, uint64_t totalBytesExpected);
@property (nonatomic, copy) void (^successHandler)(NSString *filePath);
@property (nonatomic, copy) void (^failHandler)(NSError *error);

/* Download methods */
- (void)setupDownloadOperation;
- (void)performDownloadWithOperation:(__weak NSBlockOperation *)weakOperation;
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

@implementation TOSMBSessionDownloadTask

- (instancetype)init
{
    //This class cannot be instantiated on its own.
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (instancetype)initWithSession:(TOSMBSession *)session filePath:(NSString *)filePath destinationPath:(NSString *)destinationPath delegate:(id<TOSMBSessionDownloadTaskDelegate>)delegate
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
    if (self.state == TOSMBSessionDownloadTaskStateRunning)
        return;
    
    [self setupDownloadOperation];
    [self.session.downloadsQueue addOperation:self.downloadOperation];
    self.state = TOSMBSessionDownloadTaskStateRunning;
}

- (void)suspend
{
    if (self.state != TOSMBSessionDownloadTaskStateRunning)
        return;
    
    [self.downloadOperation cancel];
    self.state = TOSMBSessionDownloadTaskStateSuspended;
    self.downloadOperation = nil;
}

- (void)cancel
{
    if (self.state != TOSMBSessionDownloadTaskStateRunning)
        return;
    
    id deleteBlock = ^{
        [[NSFileManager defaultManager] removeItemAtPath:self.tempFilePath error:nil];
    };
    
    NSBlockOperation *deleteOperation = [[NSBlockOperation alloc] init];
    [deleteOperation addExecutionBlock:deleteBlock];
    [deleteOperation addDependency:self.downloadOperation];
    [self.session.downloadsQueue addOperation:deleteOperation];
    
    [self.downloadOperation cancel];
    self.state = TOSMBSessionDownloadTaskStateCancelled;
    
    self.downloadOperation = nil;
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
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(downloadTask:didFinishDownloadingToPath:)])
            [self.delegate downloadTask:self didFinishDownloadingToPath:filePath];
        
        if (self.successHandler)
            self.successHandler(filePath);
    });
}

- (void)didFailWithError:(NSError *)error
{
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(downloadTask:didCompleteWithError:)])
            [self.delegate downloadTask:self didCompleteWithError:error];
        
        if (self.failHandler)
            self.failHandler(error);
    });
}

- (void)didUpdateWriteBytes:(uint64_t)bytesWritten totalBytesWritten:(uint64_t)totalBytesWritten totalBytesExpected:(uint64_t)totalBytesExpected
{
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(downloadTask:didWriteBytes:totalBytesReceived:totalBytesExpectedToReceive:)])
            [self.delegate downloadTask:self didWriteBytes:bytesWritten totalBytesReceived:self.countOfBytesReceived totalBytesExpectedToReceive:self.countOfBytesExpectedToReceive];
        
        if (self.progressHandler)
            self.progressHandler(self.countOfBytesReceived, self.countOfBytesExpectedToReceive);
    }];
}

- (void)didResumeAtOffset:(uint64_t)bytesWritten totalBytesExpected:(uint64_t)totalBytesExpected
{
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(downloadTask:didResumeAtOffset:totalBytesExpectedToReceive:)])
            [self.delegate downloadTask:self didResumeAtOffset:bytesWritten totalBytesExpectedToReceive:totalBytesExpected];
    }];
}

#pragma mark - Downloading -
- (TOSMBSessionFile *)requestFileForItemAtPath:(NSString *)filePath inTree:(smb_tid)treeID
{
    const char *fileCString = [filePath cStringUsingEncoding:NSUTF8StringEncoding];
    smb_stat fileStat = smb_fstat(self.downloadSession, treeID, fileCString);
    if (!fileStat)
        return nil;
    
    TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:fileStat session:self.session parentDirectoryFilePath:filePath];
    
    //naren commented and added new
    // TOSMBSessionFile *file = [[TOSMBSessionFile alloc] initWithStat:fileStat session:nil parentDirectoryFilePath:filePath];
    
    smb_stat_destroy(fileStat);
    
    return file;
}

- (void)setupDownloadOperation
{
    if (self.downloadOperation)
        return;
    
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    
    __weak typeof (self) weakSelf = self;
    __weak NSBlockOperation *weakOperation = operation;
    
    id executionBlock = ^{
        [weakSelf performDownloadWithOperation:weakOperation];
    };
    [operation addExecutionBlock:executionBlock];
    operation.completionBlock = ^{
        weakSelf.downloadOperation = nil;
    };
    
    self.downloadOperation = operation;
}

- (void)performDownloadWithOperation:(__weak NSBlockOperation *)weakOperation
{
    if (weakOperation.isCancelled)
        return;
    
    smb_tid treeID = 0;
    smb_fd fileID = 0;
    
    //---------------------------------------------------------------------------------------
    //Set up a cleanup block that'll release any handles before cancellation
    void (^cleanup)(void) = ^{
        
        //Release the background task handler, making the app eligible to be suspended now
        if (self.backgroundTaskIdentifier)
            [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskIdentifier];
        
        if (self.downloadSession && treeID)
            smb_tree_disconnect(self.downloadSession, treeID);
        
        if (self.downloadSession && fileID)
            smb_fclose(self.downloadSession, fileID);
        
        if (self.downloadSession) {
            smb_session_destroy(self.downloadSession);
            self.downloadSession = nil;
        }
    };
    
    //---------------------------------------------------------------------------------------
    //Connect to SMB device
    
    self.downloadSession = smb_session_new();
    
    //First, check to make sure the server is there, and to acquire its attributes
    __block NSError *error = nil;
    dispatch_sync(self.session.serialQueue, ^{
        error = [self.session attemptConnectionWithSessionPointer:self.downloadSession];
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
    smb_tree_connect(self.downloadSession, shareCString, &treeID);
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
    
    if (self.file.directory) {
        [self didFailWithError:errorForErrorCode(TOSMBSessionErrorCodeDirectoryDownloaded)];
        cleanup();
        return;
    }
    
    self.countOfBytesExpectedToReceive = self.file.fileSize;
    
    //---------------------------------------------------------------------------------------
    //Open the file handle
    
    smb_fopen(self.downloadSession, treeID, [formattedPath cStringUsingEncoding:NSUTF8StringEncoding], SMB_MOD_RO, &fileID);
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
    //Start downloading
    
    //Create the directories to the download destination
    [[NSFileManager defaultManager] createDirectoryAtPath:[self.tempFilePath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    
    //Create a new blank file to write to
    if (self.canBeResumed == NO)
        [[NSFileManager defaultManager] createFileAtPath:self.tempFilePath contents:nil attributes:nil];
    
    //Open a handle to the file and skip ahead if we're resuming
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:self.tempFilePath];
    unsigned long long seekOffset = (ssize_t)[fileHandle seekToEndOfFile];
    self.countOfBytesReceived = seekOffset;
    
    //Create a background handle so the download will continue even if the app is suspended
    self.backgroundTaskIdentifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{ [self suspend]; }];
    
    if (seekOffset > 0) {
        smb_fseek(self.downloadSession, fileID, (ssize_t)seekOffset, SMB_SEEK_SET);
        [self didResumeAtOffset:seekOffset totalBytesExpected:self.countOfBytesExpectedToReceive];
    }
    
    //Perform the file download
    uint64_t bytesRead = 0;
    NSInteger bufferSize = 65535;
    char *buffer = malloc(bufferSize);
    
    do {
        //Read the bytes from the network device
        bytesRead = smb_fread(self.downloadSession, fileID, buffer, bufferSize);
        
        //Save them to the file handle (And ensure the NSData object is flushed immediately)
        @autoreleasepool {
            [fileHandle writeData:[NSData dataWithBytes:buffer length:bufferSize]];
        }
        
        //Ensure the data is properly written to disk before proceeding
        [fileHandle synchronizeFile];
        
        if (weakOperation.isCancelled)
            break;
        
        self.countOfBytesReceived += bytesRead;
        
        [self didUpdateWriteBytes:bytesRead totalBytesWritten:self.countOfBytesReceived totalBytesExpected:self.countOfBytesExpectedToReceive];
    } while (bytesRead > 0);
    
    //Set the modification date to match the one on the SMB device so we can compare the two at a later date
    [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate:self.file.modificationTime} ofItemAtPath:self.tempFilePath error:nil];
    
    free(buffer);
    [fileHandle closeFile];
    
    if (weakOperation.isCancelled) {
        cleanup();
        return;
    }
    
    //---------------------------------------------------------------------------------------
    //Move the finished file to its destination
    
    //Workout the destination of the file and move it
    NSString *finalDestinationPath = [self finalFilePathForDownloadedFile];
    [[NSFileManager defaultManager] moveItemAtPath:self.tempFilePath toPath:finalDestinationPath error:nil];
    
    self.state =TOSMBSessionDownloadTaskStateCompleted;
    
    //Alert the delegate that we finished, so they may perform any additional cleanup operations
    [self didSucceedWithFilePath:finalDestinationPath];
    
//    //Perform a final cleanup of all handles and references
//    cleanup();
    
    [self createFolder:@"xzxzxz" shareName:shareName PathName:formattedPath inFolder:self.file];
    
   // [self writeTextFileFromHost:self.file.session.hostName withLogin:self.file.session.userName withPassword:self.file.session.password withFileName:formattedPath onShare:shareName textToWrite:@"MyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShareMyShare" append:TRUE error:nil];
    
    //Perform a final cleanup of all handles and references
    cleanup();
}

-(int) writeTextFileFromHost:(NSString *)shareHostName
                   withLogin:(NSString *)user
                withPassword:(NSString *)password
                withFileName:(NSString *)filePath
                     onShare:(NSString *)shareName
                 textToWrite:(NSString *)textToWrite
                      append:(BOOL) append
                       error:(NSError **)error
{
    // convert incomming shareHostName parameter into a local const char hostName variable
    const char * hostName = [shareHostName cStringUsingEncoding:NSUTF8StringEncoding];
    
    // convert incomming user parameter into a local const char userName variable
    const char * userName = [user cStringUsingEncoding:NSUTF8StringEncoding];
    
    // convert incomming password parameter into a local const char loginPassword variable
    const char * loginPassword = [password cStringUsingEncoding:NSUTF8StringEncoding];
    
    // strip the filePath of its first '/' if it exists
    if([filePath hasPrefix: @"/"])
    {
        filePath = [filePath substringFromIndex:1];
    }
    
    // change every '/' to '\\'
    if([filePath containsString: @"/"])
    {
        filePath = [filePath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    }
    
    // convert incomming filePath parameter into a local const char fileNameAndPath variable
    const char * fileNameAndPath = [filePath cStringUsingEncoding:NSUTF8StringEncoding];
    
    // convert incomming shareName parameter into a local const char sharedFolder variable
    const char * sharedFolder = [shareName cStringUsingEncoding:NSUTF8StringEncoding];
    
    // variable to contain the ip address of the destination host
    struct sockaddr_in ipAddress;
    
    // variable to contain a NetBios name service
    netbios_ns * netbiosNameService;
    
    // variable to contain the SMB created session
    smb_session * smbSession;
    
    // the connected share id (share descriptor)
    smb_tid shareID = 0 ;
    
    // the requested and opened file descriptor
    smb_fd fileDescriptor = 0;
    
    // create a NetBios name service instance
    netbiosNameService = netbios_ns_new();
    
    // make sure the requested host is resolveable and fetch it's IP address, otherwise - return error code
    int resolveResult = netbios_ns_resolve(netbiosNameService, hostName, NETBIOS_FILESERVER, &ipAddress.sin_addr.s_addr);
    
    if (resolveResult == 0)
    {
        // debug print
        [self logLine:[NSString stringWithFormat:@"Successfully reversed lookup host: %s into IP address: %s\n", hostName, inet_ntoa(ipAddress.sin_addr)]];
    }
    else
    {
        // debug print
        NSString * errorMessageString = [NSString stringWithFormat:@"Failed to reverse lookup, could not resolve the host: %s IP address, libDSM errorCode: %d", hostName, resolveResult];
        [self logLine:errorMessageString];
        
        NSMutableDictionary* errorMessage = [NSMutableDictionary dictionary];
        [errorMessage setValue:errorMessageString forKey:NSLocalizedDescriptionKey];
        
//*error = [NSError errorWithDomain:@"SMBError" code:-1 userInfo:errorMessage];
        return -1;
    }
    
    // create a new SMB session
    smbSession = smb_session_new();
    
    // try to connect to the requested host using the resolved IP address using a TCP connection
    int connectResult = smb_session_connect(smbSession, hostName, ipAddress.sin_addr.s_addr, SMB_TRANSPORT_TCP);
    
    
    // make sure the connection to the requested host has succeeded, else return error
    if (connectResult == 0)
    {
        // debug print
        [self logLine:[NSString stringWithFormat:@"Successfully connected to %s\n", hostName]];
    }
    else
    {
        // debug print
        NSString * errorMessageString = [NSString stringWithFormat:@"Failed connecting to host: %s, libDSM returned errorCode:%d", hostName, connectResult];
        [self logLine:errorMessageString];
        
        // return relevant error message
        NSMutableDictionary* errorMessage = [NSMutableDictionary dictionary];
        [errorMessage setValue:errorMessageString forKey:NSLocalizedDescriptionKey];
        *error = [NSError errorWithDomain:@"SMBError" code:-2 userInfo:errorMessage];
        return -1;
    }
    
    // login to the host using the userName and loginPassword
    smb_session_set_creds(smbSession, hostName, userName, loginPassword);
    
    // try to login to the connected host with the supplied user and password
    int loginResult = smb_session_login(smbSession);
    
    // check if the login is successful, and if it used a Guest user or the supplied credentials
    if (loginResult == 0)
    {
        // debug print
        [self logLine:[NSString stringWithFormat:@"Successfully loggedin to host: %s as user: %s\n", hostName, userName]];
    }
    else if (loginResult == 1)
    {
        // debug print
        [self logLine:[NSString stringWithFormat:@"successfully login using a Guest user, due to failiour with supplied user and password\n"]];
    }
    else if (loginResult == -1)
    {
        // debug print
        NSString * errorMessageString = [NSString stringWithFormat:@"Failed to login to host: %s as user: %s, and also failed to login as guest", hostName, userName];
        [self logLine:errorMessageString];
        
        // return relevant error message
        NSMutableDictionary* errorMessage = [NSMutableDictionary dictionary];
        [errorMessage setValue:errorMessageString forKey:NSLocalizedDescriptionKey];
        *error = [NSError errorWithDomain:@"SMBError" code:-3 userInfo:errorMessage];
        return -1;
    }
    
    // connect to the requested share folder
    int shareConnectResult = smb_tree_connect(smbSession, sharedFolder, &shareID);
    
    // check if connection to the shared folder was successful
    if (shareConnectResult == 0)
    {
        // debug print
        [self logLine:[NSString stringWithFormat:@"Successfully connected to share: %s\n", sharedFolder]];
    }
    else
    {
        // debug print
        NSString * errorMessageString = [NSString stringWithFormat:@"Failed to connect to share: %s libDSM errorCode: %d", sharedFolder, shareConnectResult];
        [self logLine:errorMessageString];
        
        // return relevant error message
        NSMutableDictionary* errorMessage = [NSMutableDictionary dictionary];
        [errorMessage setValue:errorMessageString forKey:NSLocalizedDescriptionKey];
      //  *error = [NSError errorWithDomain:@"SMBError" code:-4 userInfo:errorMessage];
        return -1;
    }
    
    // check if append requested, open the file in the requested manner (ReadWrite or Append)
    
    smb_fopen(smbSession, shareID, fileNameAndPath, SMB_MOD_RW, &fileDescriptor);
    if (!fileDescriptor) {
        
        printf("error to open file");
    }
    
//    int openFileResult = -1;
//    if(append)
//    {
//        // open the requested file (using connected share) in a Append mode
//        openFileResult = smb_fopen(smbSession, shareID, fileNameAndPath, SMB_MOD_APPEND, &fileDescriptor);
//    }
//    else
//    {
//        // open the requested file (using connected share) in a Read/Write mode
//        openFileResult = smb_fopen(smbSession, shareID, fileNameAndPath, SMB_MOD_RW, &fileDescriptor);
//    }
    
//    // make sure file was opened successfully
//    if (!openFileResult)
//    {
//        // debug print
//        [self logLine:[NSString stringWithFormat:@"Successfully opened file: %s\n", fileNameAndPath]];
//    }
//    else
//    {
//        // debug print
//        NSString * errorMessageString = [NSString stringWithFormat:@"Failed to open file: %s libDSM errorCode: %d", fileNameAndPath, openFileResult];
//        [self logLine:errorMessageString];
//        
//        // return relevant error message
//        NSMutableDictionary* errorMessage = [NSMutableDictionary dictionary];
//        [errorMessage setValue:errorMessageString forKey:NSLocalizedDescriptionKey];
//       // *error = [NSError errorWithDomain:@"SMBError" code:-5 userInfo:errorMessage];
//        return -1;
//    }
    
    // if append requested, then get current file size and set write pointer to the end of the file
//    if(append)
//    {
//        // fetch the file stat (file metadata information)
//        smb_stat fileStats = smb_stat_fd(smbSession, fileDescriptor);
//        
//        if(fileStats != NULL)
//        {
//            uint64_t fileSize = smb_stat_get(fileStats, SMB_STAT_SIZE);
//            
//            ssize_t currentFileSize = smb_fseek(smbSession, fileDescriptor, fileSize, SMB_SEEK_SET);
//            [self logLine:[NSString stringWithFormat:@"%zd", currentFileSize]];
//        }
//        else
//        {
//            // debug print
//            NSString * errorMessageString = [NSString stringWithFormat:@"Failed to get metadate of file: %s", fileNameAndPath];
//            [self logLine:errorMessageString];
//            
//            // return relevant error message
//            NSMutableDictionary* errorMessage = [NSMutableDictionary dictionary];
//            [errorMessage setValue:errorMessageString forKey:NSLocalizedDescriptionKey];
//           // *error = [NSError errorWithDomain:@"SMBError" code:-6 userInfo:errorMessage];
//            return -1;
//        }
//    }
    
    
    ssize_t  length, write_total_length = 0;
    size_t   read_length = 1;
    ssize_t *written_length_p = &write_total_length;
    BOOL     success = YES;
    FILE    *fp;
    char     buffer[BUFFER_UPLOAD_SIZE];
    

    
    
//    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
//                                                     0, 0, dispatch_get_main_queue());
//    
//    
//    long long totalSize = [[NSNumber numberWithUnsignedLong:_file.fileSize] longLongValue];
//    if (timer)
//    {
//        dispatch_source_set_timer(timer, dispatch_walltime(NULL, 0), 100 * USEC_PER_SEC,  100 * USEC_PER_SEC);
//        dispatch_source_set_event_handler(timer, ^{
//            
//            //                               dispatch_async(dispatch_get_main_queue(), ^{
//            //                                   [self.delegate CMUploadProgress:[NSDictionary dictionaryWithObjectsAndKeys:
//            //                                                                    [NSNumber numberWithLongLong:*(written_length_p)],@"uploadedBytes",
//            //                                                                    file.fileSizeNumber,@"totalBytes",
//            //                                                                    [NSNumber numberWithFloat:(float)((float)*(written_length_p)/(float)totalSize)],@"progress",
//            //                                                                    nil]];
//            //                               });
//        });
//        dispatch_resume(timer);
//    }
    
    NSString *path = [[NSBundle mainBundle] pathForResource:@"dashboard" ofType:@"jpg"];
    
    fp = fopen([path UTF8String],"r");
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:path];
    
    //NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:_file.filePath];
    
    while (read_length != 0)
    {
        @autoreleasepool {
            read_length = fread(&buffer, 1, BUFFER_UPLOAD_SIZE, fp);
            if (read_length != 0)
            {
                length = smb_fwrite(smbSession, fileDescriptor, (void *)&buffer, read_length);
                if (length != -1)
                {
                    write_total_length += length;
                }
                else
                {
                    success = NO;
                    break;
                }
            }
        }
    }
    [fileHandle closeFile];
    
    
    
    
    
    
    if (success) {
        NSLog(@"filewrite success");
    }else{
        NSLog(@"could not write a file");
    }
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    ssize_t writtenBytes = 0;
    ssize_t totalWrittenBytes = 0;
    ssize_t textLength = strlen([textToWrite UTF8String]);
    ssize_t charactersRemainingToWrite = 0;
    // substring the textToWrite from the last written position until the end of the string
    
    do
    {
        // calculate the length of characters remained to write
        charactersRemainingToWrite = textLength - totalWrittenBytes;
        
        // create a char array in the length of the characters that were not written yet
        char nextBufferToWrite[charactersRemainingToWrite + 1];
        
        // copy from the original textToWrite char array the characters that were not written yet into the new array
        memcpy(nextBufferToWrite, &[textToWrite UTF8String][totalWrittenBytes], charactersRemainingToWrite);
        
        // add at the last position of the array the null character (since strlen doesn't count it and memcpy doesn't copy it)
        nextBufferToWrite[charactersRemainingToWrite] = '\0';
        
        // write the nextBufferToWrite text into supplied file path and name
 ///////   //    writtenBytes = smb_fwrite(smbSession, fileDescriptor, (void *)nextBufferToWrite, charactersRemainingToWrite);
        
        // if bytes were written then add their total to the totalWrittenBytes accumelator
        if(writtenBytes > 0)
        {
            totalWrittenBytes = totalWrittenBytes + writtenBytes;
        }
    } while (totalWrittenBytes < textLength && writtenBytes > 0);
    
    // deallocation - close file
    smb_fclose(smbSession, fileDescriptor);
    
    int writeResult = -1;
    
    if(writtenBytes == -1 || textLength != totalWrittenBytes)
    {
        NSString * errorMessageString = [NSString stringWithFormat:@"Failed to write full text to file: %s", fileNameAndPath];
        
        // debug print
        [self logLine:errorMessageString];
        
        // return relevant error message
        NSMutableDictionary* errorMessage = [NSMutableDictionary dictionary];
        [errorMessage setValue:errorMessageString forKey:NSLocalizedDescriptionKey];
       // *error = [NSError errorWithDomain:@"SMBError" code:-7 userInfo:errorMessage];
    }
    else
    {
        // debug print
        [self logLine:[NSString stringWithFormat:@"Successfully written bytes: %zd to file: %s\n", writtenBytes, fileNameAndPath]];
        writeResult = 0;
    }
    
    // deallocation - close session
    smb_session_destroy(smbSession);
    
    // deallocation - destroy the netbios service object since we don't need it anymore
    netbios_ns_destroy(netbiosNameService);
    
    return writeResult;
}


#pragma mark - Folder creation management

- (void)createFolder:(NSString *)folderName shareName:(NSString *)share PathName:(NSString *)filePath inFolder:(TOSMBSessionFile *)folder
{
    //#ifndef APP_EXTENSION
    __block UIBackgroundTaskIdentifier bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [[UIApplication sharedApplication] endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
    //#endif
    // GCD queue
    dispatch_queue_t backgroundQueue = dispatch_queue_create("com.sylver.nastify.local.bgqueue", DISPATCH_QUEUE_SERIAL);
    
  //  dispatch_async(backgroundQueue, ^(void)
   //                {
                       int32_t result = NT_STATUS_SUCCESS;
                       
                       // Start the network activity spinner
                       // [[SBNetworkActivityIndicator sharedInstance] beginActivity:self];
                       
                     //  NSString *shareName = [self.session shareNameFromPath:self.sourceFilePath];
                       
                       
                       
                       // convert incomming shareHostName parameter into a local const char hostName variable
                       const char * hostName = [self.file.session.hostName cStringUsingEncoding:NSUTF8StringEncoding];
                       
                       // convert incomming user parameter into a local const char userName variable
                       const char * userName = [self.file.session.userName cStringUsingEncoding:NSUTF8StringEncoding];
                       
                       // convert incomming password parameter into a local const char loginPassword variable
                       const char * loginPassword = [self.file.session.password cStringUsingEncoding:NSUTF8StringEncoding];
                       
                       // strip the filePath of its first '/' if it exists
                       if([filePath hasPrefix: @"/"])
                       {
                           filePath = [filePath substringFromIndex:1];
                       }
                       
                       // change every '/' to '\\'
                       if([filePath containsString: @"/"])
                       {
                           filePath = [filePath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
                       }
                       
                       // convert incomming filePath parameter into a local const char fileNameAndPath variable
                       const char * fileNameAndPath = [filePath cStringUsingEncoding:NSUTF8StringEncoding];
                       
                       // convert incomming shareName parameter into a local const char sharedFolder variable
                       const char * sharedFolder = [share cStringUsingEncoding:NSUTF8StringEncoding];
                       
                       // variable to contain the ip address of the destination host
                       struct sockaddr_in ipAddress;
                       
                       // variable to contain a NetBios name service
                       netbios_ns * netbiosNameService;
                       
                       // variable to contain the SMB created session
                       smb_session * smbSession;
                       
                       // the connected share id (share descriptor)
                       smb_tid shareID = 0 ;
                       
                       // the requested and opened file descriptor
                       smb_fd fileDescriptor = 0;
                       
                       // create a NetBios name service instance
                       netbiosNameService = netbios_ns_new();
                       
                       // make sure the requested host is resolveable and fetch it's IP address, otherwise - return error code
                       int resolveResult = netbios_ns_resolve(netbiosNameService, hostName, NETBIOS_FILESERVER, &ipAddress.sin_addr.s_addr);
                       
                       if (resolveResult == 0)
                       {
                           // debug print
                           [self logLine:[NSString stringWithFormat:@"Successfully reversed lookup host: %s into IP address: %s\n", hostName, inet_ntoa(ipAddress.sin_addr)]];
                       }
                       else
                       {
                           // debug print
                           NSString * errorMessageString = [NSString stringWithFormat:@"Failed to reverse lookup, could not resolve the host: %s IP address, libDSM errorCode: %d", hostName, resolveResult];
                           [self logLine:errorMessageString];
                           
                           NSMutableDictionary* errorMessage = [NSMutableDictionary dictionary];
                           [errorMessage setValue:errorMessageString forKey:NSLocalizedDescriptionKey];
                           
                           //*error = [NSError errorWithDomain:@"SMBError" code:-1 userInfo:errorMessage];
                           return ;
                       }
                       
                       // create a new SMB session
                       smbSession = smb_session_new();
                       
                       // try to connect to the requested host using the resolved IP address using a TCP connection
                       int connectResult = smb_session_connect(smbSession, hostName, ipAddress.sin_addr.s_addr, SMB_TRANSPORT_TCP);
                       
                       
                       // make sure the connection to the requested host has succeeded, else return error
                       if (connectResult == 0)
                       {
                           // debug print
                           [self logLine:[NSString stringWithFormat:@"Successfully connected to %s\n", hostName]];
                       }
                       else
                       {
                           // debug print
                           NSString * errorMessageString = [NSString stringWithFormat:@"Failed connecting to host: %s, libDSM returned errorCode:%d", hostName, connectResult];
                           [self logLine:errorMessageString];
                           
                           // return relevant error message
                           NSMutableDictionary* errorMessage = [NSMutableDictionary dictionary];
                           [errorMessage setValue:errorMessageString forKey:NSLocalizedDescriptionKey];
                        //   *error = [NSError errorWithDomain:@"SMBError" code:-2 userInfo:errorMessage];
                           return ;
                       }
                       
                       // login to the host using the userName and loginPassword
                       smb_session_set_creds(smbSession, hostName, userName, loginPassword);
                       
                       // try to login to the connected host with the supplied user and password
                       int loginResult = smb_session_login(smbSession);
                       
                       // check if the login is successful, and if it used a Guest user or the supplied credentials
                       if (loginResult == 0)
                       {
                           // debug print
                           [self logLine:[NSString stringWithFormat:@"Successfully loggedin to host: %s as user: %s\n", hostName, userName]];
                       }
                       else if (loginResult == 1)
                       {
                           // debug print
                           [self logLine:[NSString stringWithFormat:@"successfully login using a Guest user, due to failiour with supplied user and password\n"]];
                       }
                       else if (loginResult == -1)
                       {
                           // debug print
                           NSString * errorMessageString = [NSString stringWithFormat:@"Failed to login to host: %s as user: %s, and also failed to login as guest", hostName, userName];
                           [self logLine:errorMessageString];
                           
                           // return relevant error message
                           NSMutableDictionary* errorMessage = [NSMutableDictionary dictionary];
                           [errorMessage setValue:errorMessageString forKey:NSLocalizedDescriptionKey];
                         //  *error = [NSError errorWithDomain:@"SMBError" code:-3 userInfo:errorMessage];
                           return ;
                       }
                       
                       // connect to the requested share folder
                       int shareConnectResult = smb_tree_connect(smbSession, sharedFolder, &shareID);
                       
                       // check if connection to the shared folder was successful
                       if (shareConnectResult == 0)
                       {
                           // debug print
                           [self logLine:[NSString stringWithFormat:@"Successfully connected to share: %s\n", sharedFolder]];
                       }
                       else
                       {
                           // debug print
                           NSString * errorMessageString = [NSString stringWithFormat:@"Failed to connect to share: %s libDSM errorCode: %d", sharedFolder, shareConnectResult];
                           [self logLine:errorMessageString];
                           
                           // return relevant error message
                           NSMutableDictionary* errorMessage = [NSMutableDictionary dictionary];
                           [errorMessage setValue:errorMessageString forKey:NSLocalizedDescriptionKey];
                           //  *error = [NSError errorWithDomain:@"SMBError" code:-4 userInfo:errorMessage];
                           return;
                       }

                       
                       NSLog(@"formated path %@",filePath);
                       
                       NSArray *objcts = folder.filePath.pathComponents;
                      // NSMutableString *path = [[NSMutableString alloc] init];
//                       for (NSInteger i = 2;i < objcts.count; i++)
//                       {
//                           [path appendFormat:@"\\%@",[objcts objectAtIndex:i]];
//                       }
    
                        NSString *path = filePath;
                        if (objcts.count>1) {
                            
                            path = [NSString stringWithFormat:@"%@",[objcts objectAtIndex:0]];
                            path = [path stringByReplacingOccurrencesOfString:[objcts objectAtIndex:1] withString:folderName];
                        }
    
    
                    result = smb_directory_create(smbSession,shareID , [path cStringUsingEncoding:NSUTF8StringEncoding]);
                       
                       // End the network activity spinner
                       //         [[SBNetworkActivityIndicator sharedInstance] endActivity:self];
                       
                       if (result == 0)
                       {
                           
                           NSLog(@"Success");
                           
                           //                           dispatch_async(dispatch_get_main_queue(), ^{
                           //                               [self.delegate CMCreateFolder:[NSDictionary dictionaryWithObjectsAndKeys:
                           //                                                              [NSNumber numberWithBool:YES],@"success",
                           //                                                              nil]];
                           //                           });
                       }
                       else
                       {
                           //                           dispatch_async(dispatch_get_main_queue(), ^{
                           //                               [self.delegate CMCreateFolder:[NSDictionary dictionaryWithObjectsAndKeys:
                           //                                                              [NSNumber numberWithBool:NO],@"success",
                           //                                                              [self stringForError:result],@"error",
                           //                                                              nil]];
                           //                           });
                       }
    

    return;
    
    path = [path stringByAppendingString:@"\\\\zipTest.zip"];
    smb_fopen(smbSession, shareID, [path cStringUsingEncoding:NSUTF8StringEncoding], SMB_MOD_RW, &fileDescriptor);
    if (!fileDescriptor) {
        
        printf("error to open file");
       // return;
    }
    
    
    ssize_t  length, write_total_length = 0;
    size_t   read_length = 1;
    ssize_t *written_length_p = &write_total_length;
    BOOL     success = YES;
    FILE    *fp;
    char     buffer[BUFFER_UPLOAD_SIZE];
    
    
    NSString *imagePath = [[NSBundle mainBundle] pathForResource:@"dashboard" ofType:@"jpg"];
    fp = fopen([imagePath UTF8String],"r");
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:imagePath];
    
    while (read_length != 0)
    {
        @autoreleasepool {
            read_length = fread(&buffer, 1, BUFFER_UPLOAD_SIZE, fp);
            if (read_length != 0)
            {
                length = smb_fwrite(smbSession, fileDescriptor, (void *)&buffer, read_length);
                if (length != -1)
                {
                    write_total_length += length;
                }
                else
                {
                    success = NO;
                    break;
                }
            }
        }
    }
    [fileHandle closeFile];
    
    
    
//    int fileMove = smb_file_mv(smbSession,shareID,[filePath cStringUsingEncoding:NSUTF8StringEncoding],[path cStringUsingEncoding:NSUTF8StringEncoding]);
//    
//    
//    
//    if (fileMove == 0) {
//        NSLog(@"file move success");
//
//    }else{
//        NSLog(@"could not move a file");
//    }
    
    if (success) {
        NSLog(@"filewrite success");
    }else{
        NSLog(@"could not write a file");
    }

    
    
    
    
    
    
                       //#ifndef APP_EXTENSION
                       [[UIApplication sharedApplication] endBackgroundTask:bgTask];
                       bgTask = UIBackgroundTaskInvalid;
                       //#endif
                 //  });
}

#pragma mark - upload management


- (void)uploadLocalFile:(TOSMBSessionFile *)file toPath:(TOSMBSessionFile *)destFolder overwrite:(BOOL)overwrite serverFiles:(NSArray *)filesArray
{
    //#ifndef APP_EXTENSION
    __block UIBackgroundTaskIdentifier bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [[UIApplication sharedApplication] endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
    //#endif
    dispatch_queue_t backgroundQueue = dispatch_queue_create("com.sylver.nastify.local.bgqueue", DISPATCH_QUEUE_SERIAL);
    
    dispatch_async(backgroundQueue, ^(void)
                   {
                       ssize_t  length, write_total_length = 0;
                       size_t   read_length = 1;
                       ssize_t *written_length_p = &write_total_length;
                       BOOL     success = YES;
                       FILE    *fp;
                       char     buffer[BUFFER_UPLOAD_SIZE];
                       smb_fd   fd;
                       smb_tid  tid;
                       
                       //  self.cancelUpload = NO;
                       
                       // Start the network activity spinner
                       //  [[SBNetworkActivityIndicator sharedInstance] beginActivity:self];
                       
                       NSString *shareName = [self.session shareNameFromPath:self.sourceFilePath];
                       smb_tid treeID = 0;
                       
                       smb_session * smbSession = smb_session_new();
                       
                       
                       // variable to contain the ip address of the destination host
                       struct sockaddr_in ipAddress;
                       
                       // variable to contain a NetBios name service
                       netbios_ns * netbiosNameService;
                       
                       
                       // the connected share id (share descriptor)
                       
                       
                       // create a NetBios name service instance
                       netbiosNameService = netbios_ns_new();
                       
                       // make sure the requested host is resolveable and fetch it's IP address, otherwise - return error code
                       int resolveResult = netbios_ns_resolve(netbiosNameService, [self.session.hostName cStringUsingEncoding:NSUTF8StringEncoding], NETBIOS_FILESERVER, &ipAddress.sin_addr.s_addr);
                       
                       if (resolveResult == 0)
                       {
                           // debug print
                           //        [self logLine:[NSString stringWithFormat:@"Successfully reversed lookup host: %s into IP address: %s\n", hostName, inet_ntoa(ipAddress.sin_addr)]];
                       }
                       else
                       {
                           // debug print
                           NSString * errorMessageString = [NSString stringWithFormat:@"Failed to reverse lookup, could not resolve the host: %@ IP address, libDSM errorCode: %d", self.session.hostName, resolveResult];
                           //  [self logLine:errorMessageString];
                           
                           NSMutableDictionary* errorMessage = [NSMutableDictionary dictionary];
                           [errorMessage setValue:errorMessageString forKey:NSLocalizedDescriptionKey];
                           
                           //*error = [NSError errorWithDomain:@"SMBError" code:-1 userInfo:errorMessage];
                           return;
                       }
                       
                       
                       // try to connect to the requested host using the resolved IP address using a TCP connection
                       int connectResult = smb_session_connect(smbSession, [self.session.hostName cStringUsingEncoding:NSUTF8StringEncoding], ipAddress.sin_addr.s_addr, SMB_TRANSPORT_TCP);
                       
                       // make sure the connection to the requested host has succeeded, else return error
                       if (connectResult == 0)
                       {
                           // debug print
                           //   [self logLine:[NSString stringWithFormat:@"Successfully connected to %s\n", hostName]];
                       }
                       else
                       {
                           // debug print
                           NSString * errorMessageString = [NSString stringWithFormat:@"Failed connecting to host: %s, libDSM returned errorCode:%d", self.session.hostName, connectResult];
                           //  [self logLine:errorMessageString];
                           
                           // return relevant error message
                           NSMutableDictionary* errorMessage = [NSMutableDictionary dictionary];
                           [errorMessage setValue:errorMessageString forKey:NSLocalizedDescriptionKey];
                           return ;
                       }
                       
                       
                       tid = smb_tree_connect(smbSession, [shareName cStringUsingEncoding:NSUTF8StringEncoding],&treeID);
                       if (tid == -1)
                       {
                           // End the network activity spinner
                           // [[SBNetworkActivityIndicator sharedInstance] endActivity:self];
                           
                           NSLog(@"Unable to connect to share");
                           
                           //                           dispatch_async(dispatch_get_main_queue(), ^{
                           //                               [self.delegate CMUploadFinished:[NSDictionary dictionaryWithObjectsAndKeys:
                           //                                                                [NSNumber numberWithBool:NO],@"success",
                           //                                                                NSLocalizedString(@"Unable to connect to share", nil),@"error",
                           //                                                                nil]];
                           //                           });
                           return ;
                       }
                       
                       NSArray *objectIds = file.filePath.pathComponents;
                       
                       NSMutableString *path = [[NSMutableString alloc] initWithString:@"\\"];
                       for (NSInteger i = 2;i < objectIds.count; i++)
                       {
                           [path appendFormat:@"%@\\",[objectIds objectAtIndex:i]];
                       }
                       [path appendString:file.name];
                       
                       NSLog(@"path %s",[path cStringUsingEncoding:NSUTF8StringEncoding]);
                       
                       smb_fd fileDescriptor = 0;
                       smb_tid shareID = 0 ;
                       
                       NSString *formattedPath = [self.session filePathExcludingSharePathFromPath:file.filePath];
                       formattedPath = [NSString stringWithFormat:@"\\%@",file.name];
                       //  formattedPath = [formattedPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\\\"];
                       
                       
                       
                       smb_fopen(smbSession, shareID, [formattedPath cStringUsingEncoding:NSUTF8StringEncoding], SMB_MOD_RW, &fileDescriptor);
                       if (!fileDescriptor) {
                           
                           printf("error to open file");
                           return;
                       }
                       
                       
                       
                       
                       //                       fd = smb_fopen(self.session, tid, [path cStringUsingEncoding:NSUTF8StringEncoding], SMB_MOD_RW);
                       //                       if (!fd)
                       //                       {
                       //                           // End the network activity spinner
                       //                         //  [[SBNetworkActivityIndicator sharedInstance] endActivity:self];
                       //
                       ////                           dispatch_async(dispatch_get_main_queue(), ^{
                       ////                               [self.delegate CMUploadFinished:[NSDictionary dictionaryWithObjectsAndKeys:
                       ////                                                                [NSNumber numberWithBool:NO],@"success",
                       ////                                                                NSLocalizedString(@"Unable to create destination file", nil),@"error",
                       ////                                                                nil]];
                       ////                           });
                       //
                       //                           NSLog(@"Unable to create destination file");
                       //
                       //                           smb_tree_disconnect(self.session, tid);
                       //
                       //                           return;
                       //                       }
                       
                       dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                                        0, 0, dispatch_get_main_queue());
                       
                       
                       long long totalSize = [[NSNumber numberWithUnsignedLong:file.fileSize] longLongValue];
                       if (timer)
                       {
                           dispatch_source_set_timer(timer, dispatch_walltime(NULL, 0), 100 * USEC_PER_SEC,  100 * USEC_PER_SEC);
                           dispatch_source_set_event_handler(timer, ^{
                               
                               //                               dispatch_async(dispatch_get_main_queue(), ^{
                               //                                   [self.delegate CMUploadProgress:[NSDictionary dictionaryWithObjectsAndKeys:
                               //                                                                    [NSNumber numberWithLongLong:*(written_length_p)],@"uploadedBytes",
                               //                                                                    file.fileSizeNumber,@"totalBytes",
                               //                                                                    [NSNumber numberWithFloat:(float)((float)*(written_length_p)/(float)totalSize)],@"progress",
                               //                                                                    nil]];
                               //                               });
                           });
                           dispatch_resume(timer);
                       }
                       
                       fp = fopen([file.filePath UTF8String],"r");
                       
                       NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:file.filePath];
                       
                       while (read_length != 0)
                       {
                           @autoreleasepool {
                               read_length = fread(&buffer, 1, BUFFER_UPLOAD_SIZE, fp);
                               if (read_length != 0)
                               {
                                   length = smb_fwrite(smbSession, fd, (void *)&buffer, read_length);
                                   if (length != -1)
                                   {
                                       write_total_length += length;
                                   }
                                   else
                                   {
                                       success = NO;
                                       break;
                                   }
                               }
                           }
                       }
                       [fileHandle closeFile];
                       
                       smb_fclose(smbSession, fd);
                       smb_tree_disconnect(smbSession, tid);
                       
                       // End the network activity spinner
                       //   [[SBNetworkActivityIndicator sharedInstance] endActivity:self];
                       
                       if (success)
                       {
                           
                           NSLog(@"Success");
                           //                           dispatch_async(dispatch_get_main_queue(), ^{
                           //                               [self.delegate CMUploadFinished:[NSDictionary dictionaryWithObjectsAndKeys:
                           //                                                                [NSNumber numberWithBool:YES],@"success",
                           //                                                                nil]];
                           //                           });
                       }
                       else
                       {
                           //                           dispatch_async(dispatch_get_main_queue(), ^{
                           //                               [self.delegate CMUploadFinished:[NSDictionary dictionaryWithObjectsAndKeys:
                           //                                                                [NSNumber numberWithBool:NO],@"success",
                           //                                                                NSLocalizedString(@"Unable to write file", nil),@"error",
                           //                                                                nil]];
                           //                           });
                           
                           
                           NSLog(@"Unable to write file");
                       }
                       
                       //#ifndef APP_EXTENSION
                       [[UIApplication sharedApplication] endBackgroundTask:bgTask];
                       bgTask = UIBackgroundTaskInvalid;
                       //#endif
                   });
}


-(void) logLine:(NSString *) logMessage
{
    printf("%s\n", [logMessage UTF8String]);
}

@end
