//
//  ZBDatabaseManager.m
//  Zebra
//
//  Created by Wilson Styres on 11/30/18.
//  Copyright © 2018 Wilson Styres. All rights reserved.
//

#import "ZBDatabaseManager.h"
#import <Parsel/Parsel.h>
#import <sqlite3.h>
#import <NSTask.h>
#import <ZBAppDelegate.h>
#import <Repos/Helpers/ZBRepo.h>
#import <Packages/Helpers/ZBPackage.h>

@implementation ZBDatabaseManager

- (void)fullImport {
    //Refresh repos
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"databaseStatusUpdate" object:self userInfo:@{@"level": @1, @"message": @"Importing Remote APT Repositories...\n"}];
    [self fullRemoteImport:^(BOOL success) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"databaseStatusUpdate" object:self userInfo:@{@"level": @1, @"message": @"Importing Local Packages...\n"}];
        [self fullLocalImport:^(BOOL success) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"databaseStatusUpdate" object:self userInfo:@{@"level": @1, @"message": @"Done.\n"}];
        }];
    }];
}

- (void)partialImport:(void (^)(BOOL success))completion {
    if ([ZBAppDelegate needsSimulation]) {
        [self fullImport];
        completion(true);
    }
    else {
        NSLog(@"Beginning partial import of repos");
        [self partialRemoteImport:^(BOOL success) {
            NSLog(@"Done.");
            completion(true);
        }];
    }
}

//Imports packages from repositories located in /var/lib/zebra/lists
- (void)fullRemoteImport:(void (^)(BOOL success))completion {
    if ([ZBAppDelegate needsSimulation]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"databaseStatusUpdate" object:self userInfo:@{@"level": @1, @"message": @"Importing sample BigBoss repo.\n"}];
        NSArray *sourceLists = @[[[NSBundle mainBundle] pathForResource:@"apt.thebigboss.org_repofiles_cydia_dists_stable_._Release" ofType:@""]];
        NSString *packageFile = [[NSBundle mainBundle] pathForResource:@"BigBoss" ofType:@"pack"];
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *databasePath = [paths[0] stringByAppendingPathComponent:@"zebra.db"];
        NSLog(@"[Zebra] Database: %@", databasePath);
        
        sqlite3 *database;
        sqlite3_open([databasePath UTF8String], &database);
        
        sqlite3_exec(database, "DELETE FROM REPOS; DELETE FROM PACKAGES", NULL, NULL, NULL);
        int i = 1;
        for (NSString *path in sourceLists) {
            importRepoToDatabase([path UTF8String], database, i);
            importPackagesToDatabase([packageFile UTF8String], database, i);
            i++;
        }
        sqlite3_close(database);
    }
    else {
        NSLog(@"[Zebra] APT Update");
        [[NSNotificationCenter defaultCenter] postNotificationName:@"databaseStatusUpdate" object:self userInfo:@{@"level": @1, @"message": @"Updating APT Repositories...\n"}];
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/Applications/Zebra.app/supersling"];
        NSArray *arguments = [[NSArray alloc] initWithObjects: @"apt-get", @"update", @"-o", @"Dir::Etc::SourceList=/var/lib/zebra/sources.list", @"-o", @"Dir::State::Lists=/var/lib/zebra/lists", @"-o", @"Dir::Etc::SourceParts=/var/lib/zebra/lists/partial/false", nil];
        [task setArguments:arguments];
        
        NSPipe *outputPipe = [[NSPipe alloc] init];
        NSFileHandle *output = [outputPipe fileHandleForReading];
        [output waitForDataInBackgroundAndNotify];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedData:) name:NSFileHandleDataAvailableNotification object:output];
        
        NSPipe *errorPipe = [[NSPipe alloc] init];
        NSFileHandle *error = [errorPipe fileHandleForReading];
        [error waitForDataInBackgroundAndNotify];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedErrorData:) name:NSFileHandleDataAvailableNotification object:error];
        
        [task setStandardOutput:outputPipe];
        [task setStandardError:errorPipe];
        
        [task launch];
        [task waitUntilExit];
        NSLog(@"[Zebra] Update Complete");
        [[NSNotificationCenter defaultCenter] postNotificationName:@"databaseStatusUpdate" object:self userInfo:@{@"level": @1, @"message": @"APT Repository Update Complete.\n"}];
        
        NSDate *methodStart = [NSDate date];
        NSArray *sourceLists = [self managedSources];
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *databasePath = [paths[0] stringByAppendingPathComponent:@"zebra.db"];
        
        sqlite3 *database;
        sqlite3_open([databasePath UTF8String], &database);
        
        sqlite3_exec(database, "DELETE FROM REPOS; DELETE FROM PACKAGES", NULL, NULL, NULL);
        int i = 1;
        for (NSString *path in sourceLists) {
            NSLog(@"[Zebra] Repo: %@ %d", path, i);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"databaseStatusUpdate" object:self userInfo:@{@"level": @1, @"message": [NSString stringWithFormat:@"Parsing %@\n", path]}];
            importRepoToDatabase([path UTF8String], database, i);
            
            NSString *baseFileName = [path stringByReplacingOccurrencesOfString:@"_Release" withString:@""];
            NSString *packageFile = [NSString stringWithFormat:@"%@_Packages", baseFileName];
            if (![[NSFileManager defaultManager] fileExistsAtPath:packageFile]) {
                packageFile = [NSString stringWithFormat:@"%@_main_binary-iphoneos-arm_Packages", baseFileName]; //Do some funky package file with the default repos
            }
            NSLog(@"[Zebra] Packages: %@ %d", packageFile, i);
            importPackagesToDatabase([packageFile UTF8String], database, i);
            i++;
        }
        sqlite3_close(database);
        NSDate *methodFinish = [NSDate date];
        NSTimeInterval executionTime = [methodFinish timeIntervalSinceDate:methodStart];
        NSLog(@"[Zebra] Time to parse and import %d repos = %f", i - 1, executionTime);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"databaseStatusUpdate" object:self userInfo:@{@"level": @1, @"message": [NSString stringWithFormat:@"Imported %d repos in %f seconds\n", i - 1, executionTime]}];
    }
    completion(true);
}

- (void)receivedData:(NSNotification *)notif {
    NSFileHandle *fh = [notif object];
    NSData *data = [fh availableData];
    
    if (data.length > 0) {
        [fh waitForDataInBackgroundAndNotify];
        NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        
        [[NSNotificationCenter defaultCenter] postNotificationName:@"databaseStatusUpdate" object:self userInfo:@{@"level": @0, @"message": str}];
    }
}

- (void)receivedErrorData:(NSNotification *)notif {
    NSFileHandle *fh = [notif object];
    NSData *data = [fh availableData];
    
    if (data.length > 0) {
        [fh waitForDataInBackgroundAndNotify];
        NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        
        [[NSNotificationCenter defaultCenter] postNotificationName:@"databaseStatusUpdate" object:self userInfo:@{@"level": @2, @"message": str}];
    }
}

//Imports packages in /var/lib/dpkg/status into Zebra's database with a repoValue of '0' to indicate that the package is installed
- (void)fullLocalImport:(void (^)(BOOL success))completion {
    NSString *installedPath;
    if ([ZBAppDelegate needsSimulation]) { //If the target is a simlator, load a demo list of installed packages
        installedPath = [[NSBundle mainBundle] pathForResource:@"Installed" ofType:@"pack"];
    }
    else { //Otherwise, load the actual file
        installedPath = @"/var/lib/dpkg/status";
    }
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *databasePath = [paths[0] stringByAppendingPathComponent:@"zebra.db"];
    
    sqlite3 *database;
    sqlite3_open([databasePath UTF8String], &database);
    //We need to delete the entire list of installed packages
    
    char *sql = "DELETE FROM PACKAGES WHERE REPOID = 0";
    sqlite3_exec(database, sql, NULL, 0, NULL);
    importPackagesToDatabase([installedPath UTF8String], database, 0);
    sqlite3_close(database);
    completion(true);
}

- (void)partialRemoteImport:(void (^)(BOOL success))completion {
    NSTask *removeCacheTask = [[NSTask alloc] init];
    [removeCacheTask setLaunchPath:@"/Applications/Zebra.app/supersling"];
    NSArray *rmArgs = [[NSArray alloc] initWithObjects: @"rm", @"-rf", @"/var/mobile/Library/Caches/xyz.willy.Zebra/lists", nil];
    [removeCacheTask setArguments:rmArgs];
    
    [removeCacheTask launch];
    [removeCacheTask waitUntilExit];
    
    NSTask *cpTask = [[NSTask alloc] init];
    [cpTask setLaunchPath:@"/Applications/Zebra.app/supersling"];
    NSArray *cpArgs = [[NSArray alloc] initWithObjects: @"cp", @"-fR", @"/var/lib/zebra/lists", @"/var/mobile/Library/Caches/xyz.willy.Zebra/", nil];
    [cpTask setArguments:cpArgs];
    
    [cpTask launch];
    [cpTask waitUntilExit];
    
    NSTask *refreshTask = [[NSTask alloc] init];
    [refreshTask setLaunchPath:@"/Applications/Zebra.app/supersling"];
    NSArray *arguments = [[NSArray alloc] initWithObjects: @"apt-get", @"update", @"-o", @"Dir::Etc::SourceList=/var/lib/zebra/sources.list", @"-o", @"Dir::State::Lists=/var/lib/zebra/lists", @"-o", @"Dir::Etc::SourceParts=/var/lib/zebra/lists/partial/false", nil];
    [refreshTask setArguments:arguments];
    
    [refreshTask launch];
    [refreshTask waitUntilExit];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *databasePath = [paths[0] stringByAppendingPathComponent:@"zebra.db"];
    
    sqlite3 *database;
    sqlite3_open([databasePath UTF8String], &database);
    
    NSArray *bill = [self billOfReposToUpdate];
    for (ZBRepo *repo in bill) {
        //[[NSNotificationCenter defaultCenter] postNotificationName:@"databaseStatusUpdate" object:self userInfo:@{@"level": @1, @"message": [NSString stringWithFormat:@"Parsing %@\n", [repo baseFileName]]}];
        NSString *release = [NSString stringWithFormat:@"/var/lib/zebra/lists/%@_Release", [repo baseFileName]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:release]) {
            release = [NSString stringWithFormat:@"/var/lib/zebra/lists/%@_main_binary-iphoneos-arm_Release", [repo baseFileName]]; //Do some funky package file with the default repos
        }
        NSLog(@"[Zebra] Repo: %@ %d", release, [repo repoID]);
        updateRepoInDatabase([release UTF8String], database, [repo repoID]);
            
        NSString *baseFileName = [release stringByReplacingOccurrencesOfString:@"_Release" withString:@""];
        NSString *packageFile = [NSString stringWithFormat:@"%@_Packages", baseFileName];
        if (![[NSFileManager defaultManager] fileExistsAtPath:packageFile]) {
            packageFile = [NSString stringWithFormat:@"%@_main_binary-iphoneos-arm_Packages", baseFileName]; //Do some funky package file with the default repos
        }
        NSLog(@"[Zebra] Repo: %@ %d", packageFile, [repo repoID]);
        updatePackagesInDatabase([packageFile UTF8String], database, [repo repoID]);
    }
    
    NSLog(@"[Zebra] Populating installed database");
    
    NSDate *newUpdateDate = [NSDate date];
    [[NSUserDefaults standardUserDefaults] setObject:newUpdateDate forKey:@"lastUpdatedDate"];

    completion(true);
//    [self updateEssentials:^(BOOL success) {
//        completion(true);
//    }];
}

//Get number of packages in the database for each repo
- (int)numberOfPackagesInRepo:(int)repoID {
    int numberOfPackages = 0;
    
    NSString *query = [NSString stringWithFormat:@"SELECT COUNT(*) FROM PACKAGES WHERE REPOID = %d", repoID];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *databasePath = [paths[0] stringByAppendingPathComponent:@"zebra.db"];
    
    sqlite3 *database;
    sqlite3_open([databasePath UTF8String], &database);
    
    sqlite3_stmt *statement;
    sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        numberOfPackages = sqlite3_column_int(statement, 0);
    }
    sqlite3_close(database);
    
    return numberOfPackages;
}

//Gets paths of repo lists that need to be read from /var/lib/zebra/lists
- (NSArray <NSString *> *)managedSources {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *aptListDirectory = @"/var/lib/zebra/lists";
    NSArray *listOfFiles = [fileManager contentsOfDirectoryAtPath:aptListDirectory error:nil];
    NSMutableArray *managedSources = [[NSMutableArray alloc] init];
    
    for (NSString *path in listOfFiles) {
        if (([path rangeOfString:@"Release"].location != NSNotFound) && ([path rangeOfString:@".gpg"].location == NSNotFound)) {
            NSString *fullPath = [NSString stringWithFormat:@"/var/lib/zebra/lists/%@", path];
            [managedSources addObject:fullPath];
        }
    }
    
    return managedSources;
}

- (NSArray <ZBRepo *> *)sources {
    NSMutableArray *sources = [NSMutableArray new];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *databasePath = [paths[0] stringByAppendingPathComponent:@"zebra.db"];
    
    sqlite3 *database;
    sqlite3_open([databasePath UTF8String], &database);
    
    NSString *query = @"SELECT * FROM REPOS ORDER BY ORIGIN ASC";
    sqlite3_stmt *statement;
    sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        const char *originChars = (const char *)sqlite3_column_text(statement, 0);
        const char *descriptionChars = (const char *)sqlite3_column_text(statement, 1);
        const char *baseFilenameChars = (const char *)sqlite3_column_text(statement, 2);
        const char *baseURLChars = (const char *)sqlite3_column_text(statement, 3);
        const char *suiteChars = (const char *)sqlite3_column_text(statement, 7);
        const char *compChars = (const char *)sqlite3_column_text(statement, 8);
        
        NSURL *iconURL;
        NSString *baseURL = [[NSString alloc] initWithUTF8String:baseURLChars];
        NSArray *separate = [baseURL componentsSeparatedByString:@"dists"];
        NSString *shortURL = separate[0];
        
        NSString *url = [baseURL stringByAppendingPathComponent:@"CydiaIcon.png"];
        if ([url hasPrefix:@"http://"] || [url hasPrefix:@"https://"]) {
            iconURL = [NSURL URLWithString:url] ;
        }
        else{
            iconURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@", url]] ;
        }
        
        ZBRepo *source = [[ZBRepo alloc] initWithOrigin:[[NSString alloc] initWithUTF8String:originChars] description:[[NSString alloc] initWithUTF8String:descriptionChars] baseFileName:[[NSString alloc] initWithUTF8String:baseFilenameChars] baseURL:baseURL secure:sqlite3_column_int(statement, 4) repoID:sqlite3_column_int(statement, 5) iconURL:iconURL isDefault:sqlite3_column_int(statement, 6) suite:[[NSString alloc] initWithUTF8String:suiteChars] components:[[NSString alloc] initWithUTF8String:compChars] shortURL:shortURL];
        
        [sources addObject:source];
    }
    sqlite3_finalize(statement);

    return (NSArray*)sources;
}

- (NSArray <ZBPackage *> *)packagesFromRepo:(int)repoID numberOfPackages:(int)limit startingAt:(int)start {
    NSMutableArray *packages = [NSMutableArray new];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *databasePath = [paths[0] stringByAppendingPathComponent:@"zebra.db"];
    
    sqlite3 *database;
    sqlite3_open([databasePath UTF8String], &database);
    
    NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES WHERE REPOID = %d ORDER BY NAME ASC LIMIT %d OFFSET %d", repoID, limit, start];
    sqlite3_stmt *statement;
    sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        const char *packageIDChars = (const char *)sqlite3_column_text(statement, 0);
        const char *packageNameChars = (const char *)sqlite3_column_text(statement, 1);
        const char *versionChars = (const char *)sqlite3_column_text(statement, 2);
        const char *descriptionChars = (const char *)sqlite3_column_text(statement, 3);
        const char *sectionChars = (const char *)sqlite3_column_text(statement, 4);
        const char *depictionChars = (const char *)sqlite3_column_text(statement, 5);
        
        ZBPackage *package = [[ZBPackage alloc] initWithIdentifier:[[NSString alloc] initWithUTF8String:packageIDChars] name:[[NSString alloc] initWithUTF8String:packageNameChars] version:[[NSString alloc] initWithUTF8String:versionChars] description:[[NSString alloc] initWithUTF8String:descriptionChars] section:[[NSString alloc] initWithUTF8String:sectionChars] depictionURL:[[NSString alloc] initWithUTF8String:depictionChars] installed:false remote:true];
        
        [packages addObject:package];
    }
    sqlite3_finalize(statement);
    
    return (NSArray *)packages;
}

- (NSArray <ZBPackage *> *)installedPackages {
    NSMutableArray *installedPackages = [NSMutableArray new];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *databasePath = [paths[0] stringByAppendingPathComponent:@"zebra.db"];
    
    sqlite3 *database;
    sqlite3_open([databasePath UTF8String], &database);
    
    NSString *query = @"SELECT * FROM PACKAGES WHERE REPOID = 0 ORDER BY NAME ASC";
    sqlite3_stmt *statement;
    sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        const char *packageIDChars = (const char *)sqlite3_column_text(statement, 0);
        const char *packageNameChars = (const char *)sqlite3_column_text(statement, 1);
        const char *versionChars = (const char *)sqlite3_column_text(statement, 2);
        const char *descriptionChars = (const char *)sqlite3_column_text(statement, 3);
        const char *sectionChars = (const char *)sqlite3_column_text(statement, 4);
        const char *depictionChars = (const char *)sqlite3_column_text(statement, 5);
        
        ZBPackage *package = [[ZBPackage alloc] initWithIdentifier:[[NSString alloc] initWithUTF8String:packageIDChars] name:[[NSString alloc] initWithUTF8String:packageNameChars] version:[[NSString alloc] initWithUTF8String:versionChars] description:[[NSString alloc] initWithUTF8String:descriptionChars] section:[[NSString alloc] initWithUTF8String:sectionChars] depictionURL:[[NSString alloc] initWithUTF8String:depictionChars] installed:true remote:false];
        
        [installedPackages addObject:package];
    }
    sqlite3_finalize(statement);
    
    return (NSArray*)installedPackages;
}

- (NSArray <ZBPackage *> *)searchForPackageName:(NSString *)name numberOfResults:(int)results {
    NSMutableArray *searchResults = [NSMutableArray new];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *databasePath = [paths[0] stringByAppendingPathComponent:@"zebra.db"];
    
    sqlite3 *database;
    sqlite3_open([databasePath UTF8String], &database);
    
    NSString *query;
    
    if (results > 0) {
        query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES WHERE NAME LIKE \'%%%@\%%\' LIMIT %d", name, results];
    }
    else {
        query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES WHERE NAME LIKE \'%%%@\%%\'", name];
    }
    
    sqlite3_stmt *statement;
    sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil);
    while (sqlite3_step(statement) == SQLITE_ROW) {
        const char *packageIDChars = (const char *)sqlite3_column_text(statement, 0);
        const char *packageNameChars = (const char *)sqlite3_column_text(statement, 1);
        const char *versionChars = (const char *)sqlite3_column_text(statement, 2);
        const char *descriptionChars = (const char *)sqlite3_column_text(statement, 3);
        const char *sectionChars = (const char *)sqlite3_column_text(statement, 4);
        const char *depictionChars = (const char *)sqlite3_column_text(statement, 5);
        
        ZBPackage *package = [[ZBPackage alloc] initWithIdentifier:[[NSString alloc] initWithUTF8String:packageIDChars] name:[[NSString alloc] initWithUTF8String:packageNameChars] version:[[NSString alloc] initWithUTF8String:versionChars] description:[[NSString alloc] initWithUTF8String:descriptionChars] section:[[NSString alloc] initWithUTF8String:sectionChars] depictionURL:[[NSString alloc] initWithUTF8String:depictionChars] installed:false remote:false];
        
        [searchResults addObject:package];
    }
    sqlite3_finalize(statement);
    
    return searchResults;
}

- (NSArray <ZBRepo *> *)billOfReposToUpdate {
    NSMutableArray *bill = [NSMutableArray new];
    
    for (ZBRepo *repo in [self sources]) {
        BOOL needsUpdate = false;
        NSString *aptPackagesFile = [NSString stringWithFormat:@"/var/lib/zebra/lists/%@_Packages", [repo baseFileName]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:aptPackagesFile]) {
            aptPackagesFile = [NSString stringWithFormat:@"/var/lib/zebra/lists/%@_main_binary-iphoneos-arm_Packages", [repo baseFileName]]; //Do some funky package file with the default repos
        }
        
        NSString *cachedPackagesFile = [NSString stringWithFormat:@"/var/mobile/Library/Caches/xyz.willy.Zebra/lists/%@_Packages", [repo baseFileName]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:cachedPackagesFile]) {
            cachedPackagesFile = [NSString stringWithFormat:@"/var/mobile/Library/Caches/xyz.willy.Zebra/lists/%@_main_binary-iphoneos-arm_Packages", [repo baseFileName]]; //Do some funky package file with the default repos
            if (![[NSFileManager defaultManager] fileExistsAtPath:cachedPackagesFile]) {
                NSLog(@"[Zebra] There is no cache file for %@ so it needs an update", [repo origin]);
                needsUpdate = true; //There isn't a cache for this so we need to parse it
            }
        }
        
        if (!needsUpdate) {
            FILE *aptFile = fopen([aptPackagesFile UTF8String], "r");
            FILE *cachedFile = fopen([cachedPackagesFile UTF8String], "r");
            needsUpdate = packages_file_changed(aptFile, cachedFile);
        }
        
        if (needsUpdate) {
            [bill addObject:repo];
        }
    }
    
    if ([bill count] > 0) {
        NSLog(@"[Zebra] Bill of Repositories that require an update: %@", bill);
    }
    else {
        NSLog(@"[Zebra] No repositories need an update");
    }
    
    
    return (NSArray *)bill;
}

- (void)deleteRepo:(ZBRepo *)repo {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *databasePath = [paths[0] stringByAppendingPathComponent:@"zebra.db"];
    
    sqlite3 *database;
    sqlite3_open([databasePath UTF8String], &database);
    
    NSString *query = @"DELETE FROM PACKAGES WHERE REPOID = ?; DELETE FROM REPOS WHERE REPOID = ?;";
    sqlite3_stmt *statement;
    if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, 0) == SQLITE_OK) {
        sqlite3_bind_int(statement, 1, [repo repoID]);
        sqlite3_bind_int(statement, 2, [repo repoID]);
        sqlite3_step(statement);
    }
    
    sqlite3_close(database);
}

- (void)updateEssentials:(void (^)(BOOL success))completion {
    [self fullLocalImport:^(BOOL installedSuccess) {
        if (installedSuccess) {
            [self getPackagesThatNeedUpdates:^(NSArray *updates, BOOL hasUpdates) {
//                if (hasUpdates) {
//                    _updateObjects = updates;
//                    _numberOfPackagesThatNeedUpdates = updates.count;
//                    NSLog(@"[AUPM] I have %d updates! %@", _numberOfPackagesThatNeedUpdates, _updateObjects);
//                }
//                _hasPackagesThatNeedUpdates = hasUpdates;
                completion(true);
            }];
        }
    }];
}

- (void)getPackagesThatNeedUpdates:(void (^)(NSArray *updates, BOOL hasUpdates))completion {
//    dispatch_async(dispatch_get_main_queue(), ^{
//        NSMutableArray *updates = [NSMutableArray new];
//        RLMResults<AUPMPackage *> *installedPackages = [AUPMPackage objectsWhere:@"installed = true"];
//
//        for (AUPMPackage *package in installedPackages) {
//            RLMResults<AUPMPackage *> *otherVersions = [AUPMPackage objectsWhere:@"packageIdentifier == %@", [package packageIdentifier]];
//            if ([otherVersions count] != 1) {
//                for (AUPMPackage *otherPackage in otherVersions) {
//                    if (otherPackage != package) {
//                        int result = verrevcmp([[package version] UTF8String], [[otherPackage version] UTF8String]);
//
//                        if (result < 0) {
//                            [updates addObject:otherPackage];
//                        }
//                    }
//                }
//            }
//        }
//
//        NSArray *updateObjects = [self cleanUpDuplicatePackages:updates];
//        if (updateObjects.count > 0) {
//            completion(updateObjects, true);
//        }
//        else {
//            completion(NULL, false);
//        }
//    });
    completion(NULL, true);
}

@end
