//
//  QuickSpec+GTFixtures.m
//  ObjectiveGitFramework
//
//  Created by Josh Abernathy on 3/22/13.
//  Copyright (c) 2013 GitHub, Inc. All rights reserved.
//

#import "QuickSpec+GTFixtures.h"

@import ObjectiveC;
@import ObjectiveGit;
@import ZipArchive;

static const NSInteger FixturesErrorUnzipFailed = 666;

static NSString * const FixturesErrorDomain = @"com.objectivegit.Fixtures";

@interface QuickSpec (Fixtures)

@property (nonatomic, readonly, copy) NSString *repositoryFixturesPath;
@property (nonatomic, copy) NSString *tempDirectoryPath;

@end

@implementation QuickSpec (Fixtures)

#pragma mark Properties

- (NSString *)tempDirectoryPath {
	NSString *path = objc_getAssociatedObject(self, _cmd);
	if (path != nil) return path;

	[self setUpTempDirectoryPath];
	return objc_getAssociatedObject(self, _cmd);
}

- (void)setTempDirectoryPath:(NSString *)path {
	objc_setAssociatedObject(self, @selector(tempDirectoryPath), path, OBJC_ASSOCIATION_COPY);
}

- (NSURL *)tempDirectoryFileURL {
	return [NSURL fileURLWithPath:self.tempDirectoryPath isDirectory:YES];
}

- (NSString *)repositoryFixturesPath {
	return [self.tempDirectoryPath stringByAppendingPathComponent:@"repositories"];
}

#pragma mark Setup/Teardown

- (void)tearDown {
	[super tearDown];

	[self cleanUp];
}

- (void)cleanUp {
	NSString *path = self.tempDirectoryPath;
	if (path == nil) return;

	[NSFileManager.defaultManager removeItemAtPath:path error:NULL];
	self.tempDirectoryPath = nil;
}

#pragma mark Fixtures

- (NSString *)rootTempDirectory {
	return [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.libgit2.objectivegit"];
}

- (void)setUpTempDirectoryPath {
	self.tempDirectoryPath = [self.rootTempDirectory stringByAppendingPathComponent:NSProcessInfo.processInfo.globallyUniqueString];

	NSError *error = nil;
	BOOL success = [NSFileManager.defaultManager createDirectoryAtPath:self.tempDirectoryPath withIntermediateDirectories:YES attributes:nil error:&error];
	XCTAssertTrue(success, @"Couldn't create the temp fixtures directory at %@: %@", self.tempDirectoryPath, error);
}

- (void)setUpRepositoryFixtureIfNeeded:(NSString *)repositoryName {
	NSString *path = [self.repositoryFixturesPath stringByAppendingPathComponent:repositoryName];

	BOOL isDirectory = NO;
	if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) return;

	NSError *error = nil;
	BOOL success = [NSFileManager.defaultManager createDirectoryAtPath:self.repositoryFixturesPath withIntermediateDirectories:YES attributes:nil error:&error];
	XCTAssertTrue(success, @"Couldn't create the repository fixtures directory at %@: %@", self.repositoryFixturesPath, error);

	NSString *zippedRepositoriesPath = [[NSBundle bundleForClass:self.class] pathForResource:@"fixtures" ofType:@"zip"];

	NSString *cleanRepositoryPath = [self.rootTempDirectory stringByAppendingPathComponent:@"clean_repository"];
	if (![NSFileManager.defaultManager fileExistsAtPath:cleanRepositoryPath isDirectory:nil]) {
		// Parallel test execution runs each Spec class in its own process, but
		// they all share the same rootTempDirectory (NSTemporaryDirectory() is
		// per-user, not per-process). If two processes both see
		// cleanRepositoryPath missing and unzip straight into it, one process
		// can observe the directory as soon as it's created (e.g. via mkdir)
		// and start copying out of it before the other process has finished
		// extracting every entry, hitting "no such file" for whichever
		// fixture hadn't been written yet.
		//
		// Avoid that by unzipping into a private, uniquely named staging
		// directory first, then publishing it under cleanRepositoryPath with
		// a single atomic rename. That way the shared name only ever refers
		// to a fully extracted directory, never a partial one.
		NSString *stagingPath = [self.rootTempDirectory stringByAppendingPathComponent:[@"clean_repository-" stringByAppendingString:NSProcessInfo.processInfo.globallyUniqueString]];

		error = nil;
		success = [self unzipFromArchiveAtPath:zippedRepositoriesPath intoDirectory:stagingPath error:&error];
		XCTAssertTrue(success, @"Couldn't unzip fixture \"%@\" from %@ to %@: %@", repositoryName, zippedRepositoriesPath, stagingPath, error);

		error = nil;
		if (![NSFileManager.defaultManager moveItemAtPath:stagingPath toPath:cleanRepositoryPath error:&error]) {
			// Another process already published cleanRepositoryPath first;
			// that's fine, just discard our redundant staging copy.
			[NSFileManager.defaultManager removeItemAtPath:stagingPath error:NULL];
			XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:cleanRepositoryPath isDirectory:nil], @"Couldn't publish unzipped fixtures at %@: %@", cleanRepositoryPath, error);
		}
	}

	success = [[NSFileManager defaultManager] copyItemAtPath:[cleanRepositoryPath stringByAppendingPathComponent:repositoryName] toPath:path error:&error];
	XCTAssertTrue(success, @"Couldn't copy directory %@", error);
}

- (NSString *)pathForFixtureRepositoryNamed:(NSString *)repositoryName {
	[self setUpRepositoryFixtureIfNeeded:repositoryName];

	return [self.repositoryFixturesPath stringByAppendingPathComponent:repositoryName];
}

- (BOOL)unzipFromArchiveAtPath:(NSString *)zipPath intoDirectory:(NSString *)destinationPath error:(NSError **)error {
	BOOL success = [SSZipArchive unzipFileAtPath:zipPath toDestination:destinationPath overwrite:YES password:nil error:error];

	if (!success) {
		NSLog(@"Unzip failed");
		return NO;
	}

	return YES;
}

#pragma mark API

- (GTRepository *)fixtureRepositoryNamed:(NSString *)name {
	NSURL *url = [NSURL fileURLWithPath:[self pathForFixtureRepositoryNamed:name]];
	GTRepository *repository = [[GTRepository alloc] initWithURL:url error:NULL];
	XCTAssertNotNil(repository, @"Couldn't create a repository for %@", name);
	return repository;
}

- (GTRepository *)testAppFixtureRepository {
	return [self fixtureRepositoryNamed:@"Test_App"];
}

- (GTRepository *)testAppForkFixtureRepository {
	return [self fixtureRepositoryNamed:@"Test_App_fork"];
}

- (GTRepository *)testUnicodeFixtureRepository {
	return [self fixtureRepositoryNamed:@"unicode-files-repo"];
}

- (GTRepository *)bareFixtureRepository {
	return [self fixtureRepositoryNamed:@"testrepo.git"];
}

- (GTRepository *)submoduleFixtureRepository {
	return [self fixtureRepositoryNamed:@"repo-with-submodule"];
}

- (GTRepository *)conflictedFixtureRepository {
	return [self fixtureRepositoryNamed:@"conflicted-repo"];
}

- (GTRepository *)blankFixtureRepository {
	NSURL *repoURL = [self.tempDirectoryFileURL URLByAppendingPathComponent:@"blank-repo"];

	GTRepository *repository = [GTRepository initializeEmptyRepositoryAtFileURL:repoURL options:nil error:NULL];
	XCTAssertNotNil(repository, @"Couldn't create a blank repository");
	return repository;
}

- (GTRepository *)blankBareFixtureRepository {
	NSURL *repoURL = [self.tempDirectoryFileURL URLByAppendingPathComponent:@"blank-repo.git"];
	NSDictionary *options = @{
		GTRepositoryInitOptionsFlags: @(GTRepositoryInitBare | GTRepositoryInitCreatingRepositoryDirectory)
	};

	GTRepository *repository = [GTRepository initializeEmptyRepositoryAtFileURL:repoURL options:options error:NULL];
	XCTAssertNotNil(repository, @"Couldn't create a blank repository");
	return repository;
}

#pragma mark Properties

- (NSBundle *)mainTestBundle {
	return [NSBundle bundleForClass:self.class];
}

@end
