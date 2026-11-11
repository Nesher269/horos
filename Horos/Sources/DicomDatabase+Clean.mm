/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/

#import "DicomDatabase+Clean.h"
#import "N2Debug.h"
#import "AppController.h"
#import "ThreadsManager.h"
#import "DicomImage.h"
#import "DicomStudy.h"
#import "DicomSeries.h"
#import "BrowserController.h"
#import "Notifications.h"
#import "NSThread+N2.h"
#import "PreferencesWindowController.h"
#import "QueryController.h"
#import "DCMTKStudyQueryNode.h"

#define MAXSTUDYDELETE 50

@interface DicomDatabase (Private)

-(NSRecursiveLock*)cleanLock;

+(void)_syncCleanTimer;

@end

@implementation DicomDatabase (Clean)

-(void)initClean {
	if (self.isMainDatabase) {
        _cleanLock = [[NSRecursiveLock alloc] init];
    } else {
        _cleanLock = [[self.mainDatabase cleanLock] retain];
    }
	[DicomDatabase _syncCleanTimer];
}

-(void)deallocClean {
	NSRecursiveLock* temp;
	
    if (self.isMainDatabase) {
        temp = _cleanLock;
        [temp lock]; // if currently cleaning, wait until finished
        _cleanLock = nil;
        [temp unlock];
        [temp release];
    } else {
        [_cleanLock release];
    }
}

-(NSRecursiveLock*)cleanLock {
    return _cleanLock;
}

+(void)_syncCleanTimer {
	static NSTimer* cleanTimer = nil;
	
	if (cleanTimer)
		return;
	
	cleanTimer = [[NSTimer timerWithTimeInterval:15*60+2.5 target:self selector:@selector(_cleanTimerCallback:) userInfo:nil repeats:YES] retain];
	[[NSRunLoop mainRunLoop] addTimer:cleanTimer forMode:NSModalPanelRunLoopMode];
	[[NSRunLoop mainRunLoop] addTimer:cleanTimer forMode:NSDefaultRunLoopMode];
}

+(void)_cleanTimerCallback:(NSTimer*)timer {
	for (DicomDatabase* dbi in [self allDatabases])
		if (dbi.isLocal)
			[dbi initiateCleanUnlessAlreadyCleaning];
}

-(void)initiateCleanUnlessAlreadyCleaning {
	if ([_cleanLock tryLock])
		@try {
			[self performSelectorInBackground:@selector(_cleanThread) withObject:nil];
		} @catch (NSException* e) {
			N2LogExceptionWithStackTrace(e);
		} @finally {
			[_cleanLock unlock];
		}
	else NSLog(@"Warning: couldn't initiate clean");
}

-(void)_cleanThread {
	NSAutoreleasePool* pool = [NSAutoreleasePool new];
	@try {
		NSThread* thread = [NSThread currentThread];
		thread.name = NSLocalizedString(@"Cleaning...", nil);
		[self.independentDatabase cleanOldStuff];
	} @catch (NSException * e) {
		N2LogExceptionWithStackTrace(e);
	} @finally {
		[pool release];
	}
}

-(void)cleanOldStuff {
    if (self.isReadOnly)
        return;
	if (!self.isLocal) return;
	if ([AppController.sharedAppController isSessionInactive]) return;
    if( [[NSUserDefaults standardUserDefaults] integerForKey:@"LOGCLEANINGDAYS"] <= 1) return;
    if( [[NSUserDefaults standardUserDefaults] integerForKey:@"AUTOCLEANINGDATEPRODUCEDDAYS"] <= 1) return;
    if( [[NSUserDefaults standardUserDefaults] integerForKey:@"AUTOCLEANINGDATEOPENEDDAYS"] <= 1) return;
	
	[_cleanLock lock];
	@try {
		NSUserDefaults	*defaults = [NSUserDefaults standardUserDefaults];
		
		// Log cleaning
		if ([self tryLock])
			@try {
				NSDate *producedDate = [[NSDate date] dateByAddingTimeInterval: -[defaults integerForKey:@"LOGCLEANINGDAYS"]*60*60*24];
				NSPredicate *predicate = [NSPredicate predicateWithFormat: @"startTime <= CAST(%lf, \"NSDate\")", [producedDate timeIntervalSinceReferenceDate]];
				for (id log in [self objectsForEntity:self.logEntryEntity predicate:predicate])
					[self.managedObjectContext deleteObject:log];
			} @catch (NSException* e) {
				N2LogExceptionWithStackTrace(e);
			} @finally {
				[self unlock];
			}
		
		if ([defaults boolForKey:@"AUTOCLEANINGDATE"] && ([defaults boolForKey:@"AUTOCLEANINGDATEPRODUCED"] || [defaults boolForKey:@"AUTOCLEANINGDATEOPENED"]))
        {
			if ([self tryLock])
				@try {
					NSArray				*studiesArray;
					NSDate				*now = [NSDate date];
					NSDate				*producedDate = [now dateByAddingTimeInterval: -[[defaults stringForKey:@"AUTOCLEANINGDATEPRODUCEDDAYS"] intValue]*60*60*24];
					NSDate				*openedDate = [now dateByAddingTimeInterval: -[[defaults stringForKey:@"AUTOCLEANINGDATEOPENEDDAYS"] intValue]*60*60*24];
					NSMutableArray		*toBeRemoved = [NSMutableArray array];
					BOOL				dontDeleteStudiesWithComments = [[NSUserDefaults standardUserDefaults] boolForKey: @"dontDeleteStudiesWithComments"];
					BOOL                dontDeleteStudiesIfInAlbum = [[NSUserDefaults standardUserDefaults] boolForKey:@"dontDeleteStudiesIfInAlbum"];
                    
					@try {
						studiesArray = [[self objectsForEntity:self.studyEntity] sortedArrayUsingDescriptors:[NSArray arrayWithObject:[[[NSSortDescriptor alloc] initWithKey:@"patientUID" ascending:YES] autorelease]]];
						for (NSInteger i = 0; i < [studiesArray count]; i++)
                        {
							NSString	*patientID = [[studiesArray objectAtIndex: i] valueForKey:@"patientUID"];
							NSDate		*studyDate = [[studiesArray objectAtIndex: i] valueForKey:@"date"];
							NSDate		*openedStudyDate = [[studiesArray objectAtIndex: i] valueForKey:@"dateOpened"];
							
							if( openedStudyDate == nil) openedStudyDate = [[studiesArray objectAtIndex: i] valueForKey:@"dateAdded"];
							
							int to, from = i;
							
							while( i < (long)[studiesArray count]-1 && [patientID compare: [[studiesArray objectAtIndex: i+1] valueForKey:@"patientUID"] options: NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch] == NSOrderedSame)
							{
								i++;
								studyDate = [studyDate laterDate: [[studiesArray objectAtIndex: i] valueForKey:@"date"]];
								if( [[studiesArray objectAtIndex: i] valueForKey:@"dateOpened"]) openedStudyDate = [openedStudyDate laterDate: [[studiesArray objectAtIndex: i] valueForKey:@"dateOpened"]];
								else openedStudyDate = [openedStudyDate laterDate: [[studiesArray objectAtIndex: i] valueForKey:@"dateAdded"]];
							}
							to = i;
							
							BOOL dateProduced = YES, dateOpened = YES;
							
							if( [defaults boolForKey: @"AUTOCLEANINGDATEPRODUCED"])
								dateProduced = [producedDate compare: studyDate] == NSOrderedDescending;
							
							if( [defaults boolForKey: @"AUTOCLEANINGDATEOPENED"])
							{
								if( openedStudyDate == nil) openedStudyDate = [[studiesArray objectAtIndex: i] valueForKey:@"dateAdded"];
								
								dateOpened = [openedDate compare: openedStudyDate] == NSOrderedDescending;
							}
							
							if(  dateProduced == YES && dateOpened == YES)
							{
								for( int x = from; x <= to; x++)
								{
									if( [toBeRemoved containsObject:[studiesArray objectAtIndex: x]] == NO && [[[studiesArray objectAtIndex: x] valueForKey:@"lockedStudy"] boolValue] == NO)
									{
                                        BOOL addIt = YES;
                                        DicomStudy *dy = [studiesArray objectAtIndex: x];
                                        
                                        if( dontDeleteStudiesIfInAlbum)
                                        {
                                            if( dy.albums.count > 0)
                                                addIt = NO;
                                        }
                                        
										if( dontDeleteStudiesWithComments)
										{
											NSString *str = @"";
											
											if( [dy valueForKey: @"comment"])
												str = [str stringByAppendingString: [dy valueForKey: @"comment"]];
											if( [dy valueForKey: @"comment2"])
												str = [str stringByAppendingString: [dy valueForKey: @"comment2"]];
											if( [dy valueForKey: @"comment3"])
												str = [str stringByAppendingString: [dy valueForKey: @"comment3"]];
											if( [dy valueForKey: @"comment4"])
												str = [str stringByAppendingString: [dy valueForKey: @"comment4"]];
											
											if( str.length > 0)
												addIt = NO;
										}
										
                                        if( addIt)
											[toBeRemoved addObject: [studiesArray objectAtIndex: x]];
									}
								}
							}
                            
                            if( toBeRemoved.count > MAXSTUDYDELETE)
                                break;
						}
						
						for ( int i = 0; i < [toBeRemoved count]; i++) // Check if studies are in an album or added this week.  If so don't autoclean that study from the database (DDP: 051108).
						{
							if ( [[[toBeRemoved objectAtIndex: i] valueForKey: @"albums"] count] > 0 ||
								[[[toBeRemoved objectAtIndex: i] valueForKey: @"dateAdded"] timeIntervalSinceNow] > -60*60*7*24.0)  // within 7 days
							{
								[toBeRemoved removeObjectAtIndex: i];
								i--;
							}
						}
						
						if( [defaults boolForKey: @"AUTOCLEANINGCOMMENTS"])
						{
							for ( int i = 0; i < [toBeRemoved count]; i++)
							{
								NSString *comment = [[toBeRemoved objectAtIndex: i] valueForKey: @"comment"];
								
								if( comment == nil) comment = @"";
								
								if ([comment rangeOfString:[defaults stringForKey: @"AUTOCLEANINGCOMMENTSTEXT"] options:NSCaseInsensitiveSearch].location == NSNotFound)
								{
									if( [defaults integerForKey: @"AUTOCLEANINGDONTCONTAIN"] == 0)
									{
										[toBeRemoved removeObjectAtIndex: i];
										i--;
									}
								}
								else
								{
									if( [defaults integerForKey: @"AUTOCLEANINGDONTCONTAIN"] == 1)
									{
										[toBeRemoved removeObjectAtIndex: i];
										i--;
									}
								}
							}
						}
					}
					@catch (NSException * e)
					{
                        N2LogExceptionWithStackTrace(e);
					}
					
					if( [toBeRemoved count] > 0)
					{
						NSLog(@"DicomDatabase Clean: will delete: %d studies", (int) [toBeRemoved count]);
						
						@try
						{
							if ([defaults boolForKey:@"AUTOCLEANINGDELETEORIGINAL"]) {
								NSMutableArray* nonLocalImagesPath = [NSMutableArray array];
								
								for (NSManagedObject* curObj in toBeRemoved) {
									if ([[curObj valueForKey:@"type"] isEqualToString:@"Study"])
										for (DicomSeries* series in [[((DicomStudy*)curObj) series] allObjects])
											[nonLocalImagesPath addObjectsFromArray:[[series.images.allObjects filteredArrayUsingPredicate: [NSPredicate predicateWithFormat:@"inDatabaseFolder == NO"]] valueForKey:@"completePath"]];
									else NSLog(@"Uh? Autocleaning, object strange...");
								}
								
								for (NSString* path in nonLocalImagesPath) {
									[NSFileManager.defaultManager removeItemAtPath:path error:nil];
									if ([path.pathExtension isEqualToString:@"hdr"]) // ANALYZE -> DELETE IMG
										[NSFileManager.defaultManager removeItemAtPath:[path.stringByDeletingPathExtension stringByAppendingPathExtension:@"img"] error:NULL];
								}
							}
							
							for (DicomStudy *study in toBeRemoved) {
                                NSLog( @"Delete Study: %@ - %@", study.patientID, study.studyInstanceUID);
								[self.managedObjectContext deleteObject:study];
							}
							
							[self save:NULL];
						} @catch (NSException* e) {
                            N2LogExceptionWithStackTrace(e);
						}
						
						// refresh database
						[NSNotificationCenter.defaultCenter postNotificationName:_O2AddToDBAnywayNotification object:self userInfo: nil];
						[NSNotificationCenter.defaultCenter postNotificationName:_O2AddToDBAnywayCompleteNotification object:self userInfo: nil];
						[NSNotificationCenter.defaultCenter postNotificationName:OsirixAddToDBNotification object:self userInfo: nil];
						[NSNotificationCenter.defaultCenter postNotificationName:OsirixAddToDBCompleteNotification object:self userInfo: nil];
					}
					
				} @catch (NSException* e) {
					N2LogExceptionWithStackTrace(e);
				} @finally {
					[self unlock];
				}
		}
		
        [self save];
        
		[self cleanForFreeSpace];
	} @catch (NSException* e) {
		N2LogExceptionWithStackTrace(e);
	} @finally {
		[_cleanLock unlock];
	}
	
}

static BOOL _showingCleanForFreeSpaceWarning = NO;

-(void)_cleanForFreeSpaceWarning {
    if (!_showingCleanForFreeSpaceWarning) {
        _showingCleanForFreeSpaceWarning = YES;
        
        if( [[NSUserDefaults standardUserDefaults] boolForKey: @"hideListenerError"] == NO) // Server mode
            NSBeginAlertSheet(NSLocalizedString(@"Warning", nil), nil, nil, nil, nil, [self retain], @selector(_cleanForFreeSpaceWarningDidEnd:returnCode:contextInfo:), nil, nil, NSLocalizedString(@"Your hard disk is FULL! Major risks of failure! Clean your database!!", nil));
    }
}

-(void)_cleanForFreeSpaceWarningDidEnd:(NSWindow*)sheet returnCode:(int)returnCode contextInfo:(void*)contextInfo {
    _showingCleanForFreeSpaceWarning = NO;
    [self autorelease];
}

-(void)cleanForFreeSpace {
	if (self.isReadOnly)
        return;

    // Database size cap (AUTOCLEANINGDATABASESIZE, MB): replaces the free-disk-space rule.
    // Runs in the background, so imports never wait on the PACS check.
    if ([NSUserDefaults.standardUserDefaults integerForKey:@"AUTOCLEANINGDATABASESIZE"] > 0) {
        if (self.isLocal)
            [(self.isMainDatabase ? self : (DicomDatabase*)self.mainDatabase) _initiateCleanForDatabaseSize];
        if ([self isFileSystemFreeSizeLimitReached])
            [self performSelectorOnMainThread:@selector(_cleanForFreeSpaceWarning) withObject:nil waitUntilDone:NO];
        return;
    }

    [_cleanLock lock];
    
    NSThread* thread = [NSThread currentThread];
    [thread enterOperationIgnoringLowerLevels];
    thread.status = NSLocalizedString(@"Cleaning database...", nil);
    
	@try {
        
        if( [NSUserDefaults.standardUserDefaults boolForKey:@"AUTOCLEANINGSPACE"])
		{
            NSDictionary* fsattrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:self.dataBaseDirPath error:NULL];
            if (![fsattrs objectForKey:NSFileSystemSize]) {
                NSLog(@"Error: database cleaning mechanism couldn't obtain filesystem size information for %@", self.dataBaseDirPath);
                return;
            }
            
			float acss = [[NSUserDefaults.standardUserDefaults stringForKey:@"AUTOCLEANINGSPACESIZE"] floatValue];
			unsigned long long freeMemoryRequested = 0;
			if (acss < 0) { // Percentages !
                unsigned long long diskSizeMB = [[fsattrs objectForKey:NSFileSystemSize] unsignedLongLongValue]/1024/1024;
				freeMemoryRequested = -acss/100*diskSizeMB;
			} else freeMemoryRequested = acss;
			
			[self cleanForFreeSpaceMB:freeMemoryRequested];
		}
		
		// warn user if less than 1% / 300MB available
		if ([self isFileSystemFreeSizeLimitReached])
            [self performSelectorOnMainThread:@selector(_cleanForFreeSpaceWarning) withObject:nil waitUntilDone:NO];
		
	} @catch (NSException* e) {
		N2LogExceptionWithStackTrace(e);
	} @finally {
        [thread exitOperation];
		[_cleanLock unlock];
	}
}

static BOOL _errorCurrentlyDisplayed = NO;
static BOOL _cleanForFreeSpaceLimitSoonReachedDisplayed = NO;

- (void) _cleanForFreeSpaceLimitSoonReachedWarning
{
    if( _errorCurrentlyDisplayed)
        return;
    
    if([[NSUserDefaults standardUserDefaults] boolForKey: @"hideListenerError"] == NO)
    {
        if ([[NSUserDefaults standardUserDefaults] boolForKey: @"hideCleanForFreeSpaceLimitSoonReachedWarning"] == NO)
        {
            _errorCurrentlyDisplayed = YES;
            
            NSAlert* alert = [[NSAlert new] autorelease];
            [alert setMessageText: NSLocalizedString(@"Warning - Free Space", nil)];
            [alert setInformativeText: NSLocalizedString( @"Free space limit will be soon reached for your hard disk storing the database. Some studies will be deleted according to the rules specified in Preferences Database window (Database Auto-Cleaning).", nil)];
            [alert setShowsSuppressionButton:YES ];
            [alert addButtonWithTitle: NSLocalizedString( @"OK", nil)];
            [alert addButtonWithTitle: NSLocalizedString( @"See Preferences", nil)];
            
            if( [alert runModal] == NSAlertSecondButtonReturn)
            {
                [[PreferencesWindowController sharedPreferencesWindowController] showWindow: self];
                [[PreferencesWindowController sharedPreferencesWindowController] setCurrentContextWithResourceName: @"OSIDatabasePreferencePanePref"];
            }
            
            if ([[alert suppressionButton] state] == NSOnState)
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey: @"hideCleanForFreeSpaceLimitSoonReachedWarning"];
            
            _errorCurrentlyDisplayed = NO;
        }
    }
}

- (void) _cleanDisplayWarningAboutTryingToDeleteRecentlyAddedStudy
{
    if( _errorCurrentlyDisplayed)
        return;
    
    if([[NSUserDefaults standardUserDefaults] boolForKey: @"hideListenerError"] == NO)
    {
        _errorCurrentlyDisplayed = YES;
        
        NSInteger r = NSRunCriticalAlertPanel( NSLocalizedString( @"Warning - Free Space", nil), NSLocalizedString( @"The current auto-cleaning rules cannot find studies to delete. Check the parameters in Preferences Database window (Database Auto-Cleaning), or delete other files from your hard disk.", nil), NSLocalizedString( @"OK", nil), NSLocalizedString( @"See Preferences", nil), nil);
        
        if( r == NSAlertAlternateReturn)
        {
            [[PreferencesWindowController sharedPreferencesWindowController] showWindow: self];
            [[PreferencesWindowController sharedPreferencesWindowController] setCurrentContextWithResourceName: @"OSIDatabasePreferencePanePref"];
        }
        
        _errorCurrentlyDisplayed = NO;
    }
}

-(void)cleanForFreeSpaceMB:(NSInteger)freeMemoryRequested {
	if (self.isReadOnly)
        return;

	[_cleanLock lock];
    
    NSThread* thread = [NSThread currentThread];
    [thread enterOperation];
    
	@try {
        NSDictionary* fsattrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:self.dataBaseDirPath error:NULL];
		if ([fsattrs objectForKey:NSFileSystemFreeSize] == nil) {
			NSLog(@"Error: database cleaning mechanism couldn't obtain filesystem space information for %@", self.dataBaseDirPath);
			return;
		}
        
		unsigned long long free = [[fsattrs objectForKey:NSFileSystemFreeSize] unsignedLongLongValue]/1024/1024; // megabytes

/*		if (_lastFreeSpace != free && ([NSDate timeIntervalSinceReferenceDate] - _lastFreeSpaceLogTime) > 60*10) { // not more often than every ten minutes, log about the disk's free space
			_lastFreeSpace = free;
			_lastFreeSpaceLogTime = [NSDate timeIntervalSinceReferenceDate];
			NSLog(@"Info: database free space is %ld MB", (long)free);
		}*/
		
		if (free >= freeMemoryRequested)
        {
            if( free <= freeMemoryRequested * 1.2) // 20%
            {
                if( _cleanForFreeSpaceLimitSoonReachedDisplayed == NO)
                {
                    _cleanForFreeSpaceLimitSoonReachedDisplayed = YES;
                    [self performSelectorOnMainThread:@selector(_cleanForFreeSpaceLimitSoonReachedWarning) withObject:nil waitUntilDone:NO];
                }
            }
            
			return;
		}
        
		NSLog(@"Info: cleaning for space (%lld MB available, %lld MB requested)", free, (unsigned long long)freeMemoryRequested);
		
        unsigned long long initialDelta = freeMemoryRequested - free;
        
        NSMutableArray* studiesDates = [NSMutableArray array];
        
//        BOOL dontDeleteStudiesIfInAlbum = [[NSUserDefaults standardUserDefaults] boolForKey:@"dontDeleteStudiesIfInAlbum"];
        BOOL flagDoNotDeleteIfComments = [[NSUserDefaults standardUserDefaults] boolForKey:@"dontDeleteStudiesWithComments"];
        NSInteger autocleanSpaceMode = [[[NSUserDefaults standardUserDefaults] objectForKey:@"AutocleanSpaceMode"] intValue];
        
        for (DicomStudy* study in [self objectsForEntity:self.studyEntity]) {
            // if study is locked, do not delete it
            if ([study.lockedStudy boolValue])
                continue;
            // if the user told us not to delete studies with comments and there are comments, do not delete it
            if (flagDoNotDeleteIfComments)
                if (study.comment.length || study.comment2.length || study.comment3.length || study.comment4.length)
                    continue;
            
            if( study.albums.count > 0)
                continue;
            
            // study can be deleted
            NSDate* d = nil; // determine the delete priority date
            switch (autocleanSpaceMode) {
                case 0: { // oldest Studies
                    d = study.date;
                } break;
                case 1: { // oldest unopened
                    if (study.dateOpened)
                        d = study.dateOpened;
                    else
                        if (study.dateAdded)
                            d = study.dateAdded;
                        else d = study.date;
                } break;
                case 2: { // least recently added
                    if (study.dateAdded)
                        d = study.dateAdded;
                    else d = study.date;
                } break;
            }
            
            [studiesDates addObject:[NSArray arrayWithObjects: study, d, nil]];   
        }
        
        // sort studiesDates by date
        [studiesDates sortUsingComparator: ^NSComparisonResult(id a, id b) {
            if ([a count] < 2 || [b count] < 2) return NSOrderedSame;
            return [[a objectAtIndex:1] compare:[b objectAtIndex:1]];
        }];
        
        NSString* dataBaseDirPathSlashed = self.dataBaseDirPath;
        if (![dataBaseDirPathSlashed hasSuffix:@"/"])
            dataBaseDirPathSlashed = [dataBaseDirPathSlashed stringByAppendingString:@"/"];
        
        BOOL flagDeleteLinkedImages = [[NSUserDefaults standardUserDefaults] boolForKey:@"AUTOCLEANINGDELETEORIGINAL"];
        
        BOOL displayError = NO;
        int deletedStudies = 0;
        
        for (NSArray* sd in studiesDates)
        {
            @autoreleasepool
            {
                { CGFloat a = initialDelta, b = freeMemoryRequested, f = free; [NSThread currentThread].progress = (a-(b-f))/a; }
                
                DicomStudy* study = [sd objectAtIndex:0];
                
                if( [study.dateAdded timeIntervalSinceNow] > -60*60*2) // The study was added less than 2 hours.... we cannot remove it !
                {
                    NSLog( @"---- WARNING: trying to remove a study added recently: %@", study.dateAdded);
                    displayError = YES;
                    continue;
                }
                
                NSLog(@"Info: study [%@ - %@ - %@] is being deleted for space (added %@, last opened %@)", study.studyName, study.patientID, study.date, study.dateAdded, study.dateOpened);
                
                // list images to be deleted
                NSMutableArray* imagesToDelete = [NSMutableArray array];
                for (DicomSeries* series in [[study series] allObjects])
                    for (DicomImage* image in series.images.allObjects)
                        if (flagDeleteLinkedImages || [image.completePath hasPrefix:dataBaseDirPathSlashed])
                            [imagesToDelete addObject:image];
                
                // delete image files
                for (DicomImage* image in imagesToDelete) {
                    NSString* path = image.completePath;
                    unlink(path.fileSystemRepresentation); // faster than [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
                    if ([path.pathExtension isEqualToString:@"hdr"]) // ANALYZE -> DELETE IMG
                        [NSFileManager.defaultManager removeItemAtPath:[path.stringByDeletingPathExtension stringByAppendingPathExtension:@"img"] error:NULL];
                }
                
                // delete managed objects: images, series, studies
                
                for (DicomSeries* series in [[study series] allObjects]) {
                    @try {
                        for (DicomImage* image in series.images.allObjects)
                            @try {
                                [self.managedObjectContext deleteObject:image];
                            } @catch (...) { }
                    } @catch (...) { }
                    
                    @try {
                        [self.managedObjectContext deleteObject:series];
                    } @catch (...) { }
                }
                
                @try {
                    [self.managedObjectContext deleteObject:study];
                } @catch (...) { }
                
                // did we free up enough space?
                
                NSDictionary* fsattrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:self.dataBaseDirPath error:NULL];
                free = [[fsattrs objectForKey:NSFileSystemFreeSize] unsignedLongLongValue]/1024/1024;
                if (free >= freeMemoryRequested) // if so, stop deleting studies
                    break;
                
                deletedStudies++;
                if( deletedStudies > MAXSTUDYDELETE) // To avoid HUGE loop with very large DB
                    break;
            }
        }
        
        [self save: nil];
        
        if( deletedStudies > 0)
        {
            // refresh database
            [NSNotificationCenter.defaultCenter postNotificationName:_O2AddToDBAnywayNotification object:self userInfo: nil];
            [NSNotificationCenter.defaultCenter postNotificationName:_O2AddToDBAnywayCompleteNotification object:self userInfo: nil];
            [NSNotificationCenter.defaultCenter postNotificationName:OsirixAddToDBNotification object:self userInfo: nil];
            [NSNotificationCenter.defaultCenter postNotificationName:OsirixAddToDBCompleteNotification object:self userInfo: nil];
        }
        
		NSLog(@"Info: done cleaning for space, %lld MB are free", free);
        
        if( displayError)
            [self performSelectorOnMainThread:@selector( _cleanDisplayWarningAboutTryingToDeleteRecentlyAddedStudy) withObject:nil waitUntilDone:NO];
        
    } @catch (NSException* e) {
        N2LogExceptionWithStackTrace(e);
    } @finally {
        [thread exitOperation];
        [_cleanLock unlock];
    }
}

#pragma mark - Database size cap

// Keeps the local database under AUTOCLEANINGDATABASESIZE megabytes, whatever the free space
// left on the disk. The least recently imported studies go first (dateAdded, refreshed when a
// study is imported or retrieved again). A study is deleted only if the DICOM node named by
// AUTOCLEANINGDATABASESIZEPACS answers that it holds at least as many instances; if that node
// is unreachable, nothing is deleted. Always kept: locked studies, studies in an album,
// studies imported less than 30 min ago (import in progress) or opened less than 12 h ago.

static BOOL _cleanForDatabaseSizeRunning = NO;
static NSMutableSet* _cleanForDatabaseSizeWarnedStudies = nil;

-(void)_initiateCleanForDatabaseSize {
    @synchronized ([DicomDatabase class]) {
        if (_cleanForDatabaseSizeRunning)
            return;
        _cleanForDatabaseSizeRunning = YES;
    }
    [self performSelectorInBackground:@selector(_cleanForDatabaseSizeThread) withObject:nil];
}

-(void)_cleanForDatabaseSizeThread {
    NSAutoreleasePool* pool = [NSAutoreleasePool new];
    @try {
        [NSThread currentThread].name = NSLocalizedString(@"Cleaning...", nil);
        NSInteger maxMB = [NSUserDefaults.standardUserDefaults integerForKey:@"AUTOCLEANINGDATABASESIZE"];
        if (maxMB > 0)
            [self.independentDatabase cleanForDatabaseSizeMB:maxMB];
    } @catch (NSException* e) {
        N2LogExceptionWithStackTrace(e);
    } @finally {
        @synchronized ([DicomDatabase class]) {
            _cleanForDatabaseSizeRunning = NO;
        }
        [pool release];
    }
}

-(unsigned long long)_cleanDatabaseSizeBytes {
    unsigned long long total = 0;
    NSURL* url = [NSURL fileURLWithPath:self.dataDirPath isDirectory:YES];
    NSArray* keys = [NSArray arrayWithObjects:NSURLIsRegularFileKey, NSURLTotalFileAllocatedSizeKey, nil];
    NSDirectoryEnumerator* e = [NSFileManager.defaultManager enumeratorAtURL:url includingPropertiesForKeys:keys options:0 errorHandler:nil];
    for (NSURL* f in e) {
        @autoreleasepool {
            NSNumber* isFile = nil;
            NSNumber* size = nil;
            [f getResourceValue:&isFile forKey:NSURLIsRegularFileKey error:NULL];
            if (![isFile boolValue])
                continue;
            [f getResourceValue:&size forKey:NSURLTotalFileAllocatedSizeKey error:NULL];
            total += [size unsignedLongLongValue];
        }
    }
    return total;
}

// Files of the study stored in the database folder (frames of a multi-frame image share one
// file), and how many DICOM instances the PACS should hold for it: Horos' own ROI, report,
// annotation and "no autodeletion" series are never sent, so they are not counted.
-(NSSet*)_cleanLocalPathsOfStudy:(DicomStudy*)study instances:(NSUInteger*)instances {
    NSString* dir = self.dataBaseDirPath;
    if (![dir hasSuffix:@"/"])
        dir = [dir stringByAppendingString:@"/"];
    
    NSMutableSet* localPaths = [NSMutableSet set];
    NSMutableSet* dicomPaths = [NSMutableSet set];
    for (DicomSeries* series in study.series) {
        int seriesID = series.id.intValue;
        BOOL internal = (seriesID >= 5002 && seriesID <= 5005 && [series.name hasPrefix:@"OsiriX "]);
        for (DicomImage* image in series.images) {
            NSString* path = image.completePath;
            if (path == nil)
                continue;
            if ([path hasPrefix:dir])
                [localPaths addObject:path];
            if (!internal)
                [dicomPaths addObject:path];
        }
    }
    if (instances)
        *instances = dicomPaths.count;
    return localPaths;
}

-(NSDictionary*)_cleanPACSServer {
    NSString* name = [NSUserDefaults.standardUserDefaults stringForKey:@"AUTOCLEANINGDATABASESIZEPACS"];
    if (name.length == 0)
        return nil;
    for (NSDictionary* server in [NSUserDefaults.standardUserDefaults arrayForKey:@"SERVERS"])
        if ([server isKindOfClass:[NSDictionary class]] && [[server objectForKey:@"Description"] isEqualToString:name])
            return server;
    return nil;
}

-(void)_cleanForDatabaseSizeNotOnPACSWarning:(NSArray*)studies {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"hideListenerError"])
        return;
    NSAlert* alert = [[NSAlert new] autorelease];
    [alert setMessageText:@"Nettoyage de la base : \u00e9tudes conserv\u00e9es"];
    [alert setInformativeText:[NSString stringWithFormat:@"La base d\u00e9passe sa taille maximale, mais ces \u00e9tudes n'ont pas \u00e9t\u00e9 effac\u00e9es parce que le PACS ne les a pas en entier :\n\n%@\n\nRenvoyez-les au PACS, ou verrouillez-les (cadenas) pour les garder.", [studies componentsJoinedByString:@"\n"]]];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

-(void)cleanForDatabaseSizeMB:(NSInteger)maxMB {
    if (self.isReadOnly || !self.isLocal || maxMB <= 0)
        return;
    
    unsigned long long limit = (unsigned long long)maxMB * 1024 * 1024;
    unsigned long long size = [self _cleanDatabaseSizeBytes];
    if (size <= limit)
        return;
    
    NSLog(@"Info: database size cap: %llu MB used, %ld MB allowed", size/1024/1024, (long)maxMB);
    
    NSDictionary* pacs = [self _cleanPACSServer];
    if (pacs == nil) {
        NSLog(@"Warning: database size cap: no DICOM node named \"%@\", nothing deleted", [NSUserDefaults.standardUserDefaults stringForKey:@"AUTOCLEANINGDATABASESIZEPACS"]);
        return;
    }
    if (![QueryController echoServer:pacs]) {
        NSLog(@"Info: database size cap: %@ unreachable, nothing deleted", [pacs objectForKey:@"Description"]);
        return;
    }
    
    [_cleanLock lock];
    
    NSThread* thread = [NSThread currentThread];
    [thread enterOperation];
    thread.status = NSLocalizedString(@"Cleaning database...", nil);
    
    NSMutableArray* notOnPACS = [NSMutableArray array];
    int deletedStudies = 0;
    
    @try {
        BOOL flagDoNotDeleteIfComments = [NSUserDefaults.standardUserDefaults boolForKey:@"dontDeleteStudiesWithComments"];
        NSDate* now = [NSDate date];
        NSTimeInterval minAge = 30*60; // AUTOCLEANINGDATABASESIZEMINAGE (minutes) only exists for testing
        if ([NSUserDefaults.standardUserDefaults objectForKey:@"AUTOCLEANINGDATABASESIZEMINAGE"])
            minAge = [NSUserDefaults.standardUserDefaults integerForKey:@"AUTOCLEANINGDATABASESIZEMINAGE"] * 60;
        
        NSMutableArray* candidates = [NSMutableArray array];
        for (DicomStudy* study in [self objectsForEntity:self.studyEntity]) {
            if ([study.lockedStudy boolValue])
                continue;
            if (study.albums.count > 0)
                continue;
            if (flagDoNotDeleteIfComments && (study.comment.length || study.comment2.length || study.comment3.length || study.comment4.length))
                continue;
            NSDate* added = study.dateAdded ? study.dateAdded : study.date;
            if (added == nil || [now timeIntervalSinceDate:added] < minAge) // import in progress
                continue;
            if (study.dateOpened && [now timeIntervalSinceDate:study.dateOpened] < 12*60*60) // probably on screen
                continue;
            [candidates addObject:study];
        }
        
        [candidates sortUsingComparator:^NSComparisonResult(DicomStudy* a, DicomStudy* b) {
            NSDate* da = a.dateAdded ? a.dateAdded : a.date;
            NSDate* db = b.dateAdded ? b.dateAdded : b.date;
            return [da compare:db];
        }];
        
        @synchronized ([DicomDatabase class]) {
            if (_cleanForDatabaseSizeWarnedStudies == nil)
                _cleanForDatabaseSizeWarnedStudies = [[NSMutableSet alloc] init];
        }
        
        for (DicomStudy* study in candidates) {
            if (size <= limit || deletedStudies >= MAXSTUDYDELETE)
                break;
            
            @autoreleasepool {
                NSUInteger instances = 0;
                NSSet* paths = [self _cleanLocalPathsOfStudy:study instances:&instances];
                NSString* uid = study.studyInstanceUID;
                if (uid.length == 0 || instances == 0)
                    continue;
                
                BOOL found = NO;
                NSUInteger onPACS = 0;
                for (id node in [QueryController queryStudyInstanceUID:uid server:pacs showErrors:NO]) {
                    if ([node isKindOfClass:[DCMTKStudyQueryNode class]] && [[node uid] isEqualToString:uid]) {
                        found = YES;
                        onPACS = [[node numberImages] unsignedIntegerValue];
                    }
                }
                
                if (!found || onPACS < instances) {
                    NSLog(@"Warning: database size cap: study %@ has %lu of %lu instances on %@, kept", uid, (unsigned long)onPACS, (unsigned long)instances, [pacs objectForKey:@"Description"]);
                    @synchronized ([DicomDatabase class]) {
                        if (![_cleanForDatabaseSizeWarnedStudies containsObject:uid]) {
                            [_cleanForDatabaseSizeWarnedStudies addObject:uid];
                            [notOnPACS addObject:[NSString stringWithFormat:@"%@, %@ (%lu/%lu images)", study.name, study.studyName ? study.studyName : @"", (unsigned long)onPACS, (unsigned long)instances]];
                        }
                    }
                    continue;
                }
                
                unsigned long long freed = 0;
                for (NSString* path in paths) {
                    freed += [[NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL] fileSize];
                    unlink(path.fileSystemRepresentation);
                    if ([path.pathExtension isEqualToString:@"hdr"]) // ANALYZE -> DELETE IMG
                        [NSFileManager.defaultManager removeItemAtPath:[path.stringByDeletingPathExtension stringByAppendingPathExtension:@"img"] error:NULL];
                }
                
                NSLog(@"Info: study %@ deleted for the database size cap (added %@, %lu instances on %@)", uid, study.dateAdded, (unsigned long)onPACS, [pacs objectForKey:@"Description"]);
                
                for (DicomSeries* series in [[study series] allObjects]) {
                    @try {
                        for (DicomImage* image in series.images.allObjects)
                            @try {
                                [self.managedObjectContext deleteObject:image];
                            } @catch (...) { }
                    } @catch (...) { }
                    @try {
                        [self.managedObjectContext deleteObject:series];
                    } @catch (...) { }
                }
                @try {
                    [self.managedObjectContext deleteObject:study];
                } @catch (...) { }
                
                size = (freed < size) ? size - freed : 0;
                deletedStudies++;
            }
        }
        
        [self save:nil];
        
        if (deletedStudies > 0) {
            [NSNotificationCenter.defaultCenter postNotificationName:_O2AddToDBAnywayNotification object:self userInfo:nil];
            [NSNotificationCenter.defaultCenter postNotificationName:_O2AddToDBAnywayCompleteNotification object:self userInfo:nil];
            [NSNotificationCenter.defaultCenter postNotificationName:OsirixAddToDBNotification object:self userInfo:nil];
            [NSNotificationCenter.defaultCenter postNotificationName:OsirixAddToDBCompleteNotification object:self userInfo:nil];
        }
        
        NSLog(@"Info: database size cap: %d studies deleted, about %llu MB used", deletedStudies, size/1024/1024);
    } @catch (NSException* e) {
        N2LogExceptionWithStackTrace(e);
    } @finally {
        [thread exitOperation];
        [_cleanLock unlock];
    }
    
    if (notOnPACS.count > 0)
        [self performSelectorOnMainThread:@selector(_cleanForDatabaseSizeNotOnPACSWarning:) withObject:notOnPACS waitUntilDone:NO];
}

@end
