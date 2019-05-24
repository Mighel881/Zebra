//
//  ZBQueue.h
//  Zebra
//
//  Created by Wilson Styres on 1/29/19.
//  Copyright © 2019 Wilson Styres. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ZBQueueType.h"
#import "ZBQueueViewController.h"

@class ZBPackage;

NS_ASSUME_NONNULL_BEGIN

@interface ZBQueue : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *managedQueue;
@property (nonatomic, strong) NSMutableArray<NSArray *> *failedDepQueue;
@property (nonatomic, strong) NSMutableArray<NSArray *> *failedConQueue;
+ (id)sharedInstance;
- (void)addPackage:(ZBPackage *)package toQueue:(ZBQueueType)queue;
- (void)addPackages:(NSArray<ZBPackage *> *)packages toQueue:(ZBQueueType)queue;
- (void)markPackageAsFailed:(ZBPackage *)package forDependency:(NSString *)failedDependency;
- (void)markPackageAsFailed:(ZBPackage *)package forConflicts:(ZBPackage *)conflict conflictionType:(int)type;
- (void)removePackage:(ZBPackage *)package fromQueue:(ZBQueueType)queue;
- (NSArray *)tasks:(NSArray *)debs;
- (int)numberOfPackagesForQueue:(NSString *)queue;
- (ZBPackage *)packageInQueue:(ZBQueueType)queue atIndex:(NSInteger)index;
- (void)clearQueue;
- (NSArray *)actionsToPerform;
- (NSMutableArray *)queueArray:(ZBQueueType)queue;
- (BOOL)hasObjects;
- (BOOL)containsPackage:(ZBPackage *)package;
- (BOOL)containsPackage:(ZBPackage *)package queue:(ZBQueueType)queue;
- (NSArray *)packagesToDownload;
- (BOOL)needsHyena;
- (NSString *)queueToKey:(ZBQueueType)queue;
- (ZBQueueType)queueStatusForPackageIdentifier:(NSString *)identifier;
@end

NS_ASSUME_NONNULL_END
