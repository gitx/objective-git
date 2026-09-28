//
//  GTFilter.m
//  ObjectiveGitFramework
//
//  Created by Josh Abernathy on 2/14/14.
//  Copyright (c) 2014 GitHub, Inc. All rights reserved.
//

#import "GTFilter.h"
#import "GTRepository.h"
#import "NSError+Git.h"
#import "GTFilterSource.h"

#import "git2/errors.h"
#import "git2/sys/filter.h"

NSString * const GTFilterErrorDomain = @"GTFilterErrorDomain";

const NSInteger GTFilterErrorNameAlreadyRegistered = -1;

static NSMutableDictionary *GTFiltersNameToRegisteredFilters = nil;
static NSMutableDictionary *GTFiltersGitFilterToRegisteredFilters = nil;

static int GTFilterStreamNew(git_writestream **out, git_filter *filter, void **payload, const git_filter_source *src, git_writestream *next);

@interface GTFilter () {
	git_filter _filter;
}

@property (nonatomic, readonly, copy) NSString *name;

@property (nonatomic, readonly, copy) NSData * (^applyBlock)(void **payload, NSData *from, GTFilterSource *source, BOOL *applied);

@end

@implementation GTFilter

#pragma mark Lifecycle

+ (void)initialize {
	if (self != GTFilter.class) return;

	GTFiltersNameToRegisteredFilters = [[NSMutableDictionary alloc] init];
	GTFiltersGitFilterToRegisteredFilters = [[NSMutableDictionary alloc] init];
}

- (instancetype)init {
	NSAssert(NO, @"Call to an unavailable initializer.");
	return nil;
}

- (instancetype)initWithName:(NSString *)name attributes:(NSString *)attributes applyBlock:(NSData * (^)(void **payload, NSData *from, GTFilterSource *source, BOOL *applied))applyBlock {
	NSParameterAssert(name != nil);
	NSParameterAssert(applyBlock != NULL);

	self = [super init];
	if (self == nil) return nil;

	_filter.version = GIT_FILTER_VERSION;
	_filter.attributes = attributes.UTF8String;
	_filter.stream = &GTFilterStreamNew;

	_name = [name copy];
	_applyBlock = [applyBlock copy];

	return self;
}

#pragma mark NSObject

- (BOOL)isEqual:(GTFilter *)object {
	if (object == self) return YES;
	if (![object isKindOfClass:self.class]) return NO;

	return [object.name isEqual:object.name];
}

- (NSUInteger)hash {
	return self.name.hash;
}

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@: %p> name: %@", self.class, self, self.name];
}

#pragma mark Properties

static int GTFilterInit(git_filter *filter) {
	GTFilter *self = GTFiltersGitFilterToRegisteredFilters[[NSValue valueWithPointer:filter]];
	self.initializeBlock();
	return 0;
}

static void GTFilterShutdown(git_filter *filter) {
	GTFilter *self = GTFiltersGitFilterToRegisteredFilters[[NSValue valueWithPointer:filter]];
	self.shutdownBlock();
}

static int GTFilterCheck(git_filter *filter, void **payload, const git_filter_source *src, const char **attr_values) {
	GTFilter *self = GTFiltersGitFilterToRegisteredFilters[[NSValue valueWithPointer:filter]];
	GTFilterSource *source = [[GTFilterSource alloc] initWithGitFilterSource:src];
	NSCAssert(source != nil, @"Unexpected nil filter source");
	BOOL accept = self.checkBlock(payload, source, attr_values);
	return accept ? 0 : GIT_PASSTHROUGH;
}

// Backing storage for the `git_writestream` handed to libgit2 by
// `GTFilterStreamNew`. `git_writestream` structs are used with C-style
// "inheritance": `parent` must be the first field so a `GTFilterWriteStream *`
// can be reinterpreted as a `git_writestream *`.
//
// The apply block operates on a complete buffer (an `NSData`), not a stream,
// so incoming chunks are accumulated in `bufferRef` and only handed to the
// block once `close` is called (i.e. once all data has been written).
typedef struct {
	git_writestream parent;
	void *filterRef;    // (GTFilter *), retained via CFBridgingRetain
	void *sourceRef;    // (GTFilterSource *), retained via CFBridgingRetain
	void *bufferRef;    // (NSMutableData *), retained via CFBridgingRetain
	void **payload;
	git_writestream *next;
} GTFilterWriteStream;

static int GTFilterStreamWrite(git_writestream *s, const char *buffer, size_t len) {
	GTFilterWriteStream *stream = (GTFilterWriteStream *)s;
	NSMutableData *data = (__bridge NSMutableData *)stream->bufferRef;
	[data appendBytes:buffer length:len];
	return 0;
}

static int GTFilterStreamClose(git_writestream *s) {
	GTFilterWriteStream *stream = (GTFilterWriteStream *)s;
	GTFilter *filter = (__bridge GTFilter *)stream->filterRef;
	GTFilterSource *source = (__bridge GTFilterSource *)stream->sourceRef;
	NSData *fromData = (__bridge NSData *)stream->bufferRef;

	BOOL applied = YES;
	NSData *toData = filter.applyBlock(stream->payload, fromData, source, &applied);
	NSData *outputData = applied ? toData : fromData;

	git_writestream *next = stream->next;
	int result = next->write(next, outputData.bytes, outputData.length);
	if (result < 0) return result;

	return next->close(next);
}

static void GTFilterStreamFree(git_writestream *s) {
	GTFilterWriteStream *stream = (GTFilterWriteStream *)s;
	CFBridgingRelease(stream->filterRef);
	CFBridgingRelease(stream->sourceRef);
	CFBridgingRelease(stream->bufferRef);
	stream->next->free(stream->next);
	free(stream);
}

static int GTFilterStreamNew(git_writestream **out, git_filter *filter, void **payload, const git_filter_source *src, git_writestream *next) {
	GTFilter *self = GTFiltersGitFilterToRegisteredFilters[[NSValue valueWithPointer:filter]];
	GTFilterSource *source = [[GTFilterSource alloc] initWithGitFilterSource:src];
	NSCAssert(source != nil, @"Unexpected nil filter source");

	GTFilterWriteStream *stream = calloc(1, sizeof(GTFilterWriteStream));
	if (stream == NULL) return GIT_ERROR;

	stream->parent.write = GTFilterStreamWrite;
	stream->parent.close = GTFilterStreamClose;
	stream->parent.free = GTFilterStreamFree;
	stream->filterRef = (void *)CFBridgingRetain(self);
	stream->sourceRef = (void *)CFBridgingRetain(source);
	stream->bufferRef = (void *)CFBridgingRetain([NSMutableData data]);
	stream->payload = payload;
	stream->next = next;

	*out = (git_writestream *)stream;
	return 0;
}

static void GTFilterCleanup(git_filter *filter, void *payload) {
	GTFilter *self = GTFiltersGitFilterToRegisteredFilters[[NSValue valueWithPointer:filter]];
	self.cleanupBlock(payload);
}

- (void)setInitializeBlock:(void (^)(void))initializeBlock {
	_filter.initialize = (initializeBlock != nil ? &GTFilterInit : NULL);
	_initializeBlock = [initializeBlock copy];
}

- (void)setShutdownBlock:(void (^)(void))shutdownBlock {
	_filter.shutdown = (shutdownBlock != nil ? &GTFilterShutdown : NULL);
	_shutdownBlock = [shutdownBlock copy];
}

- (void)setCheckBlock:(BOOL (^)(void **, GTFilterSource *, const char **))checkBlock {
	_filter.check = (checkBlock != nil ? &GTFilterCheck : NULL);
	_checkBlock = [checkBlock copy];
}

- (void)setCleanupBlock:(void (^)(void *))cleanupBlock {
	_filter.cleanup = (cleanupBlock != nil ? &GTFilterCleanup : NULL);
	_cleanupBlock = [cleanupBlock copy];
}

#pragma mark Registration

- (BOOL)registerWithPriority:(int)priority error:(NSError **)error {
	if (GTFiltersNameToRegisteredFilters[self.name] != nil) {
		if (error != NULL) {
			NSString *description = [NSString stringWithFormat:NSLocalizedString(@"A filter named \"%@\" has already been registered", @""), self.name];
			NSString *recoverySuggestion = NSLocalizedString(@"Unregister the existing filter first.", @"");
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: description,
				NSLocalizedRecoverySuggestionErrorKey: recoverySuggestion,
			};
			*error = [NSError errorWithDomain:GTFilterErrorDomain code:GTFilterErrorNameAlreadyRegistered userInfo:userInfo];
		}

		return NO;
	}

	int result = git_filter_register(self.name.UTF8String, &_filter, GIT_FILTER_DRIVER_PRIORITY + priority);
	if (result != GIT_OK) {
		if (error != NULL) {
			*error = [NSError git_errorFor:result description:@"Failed to register filter: %@", self.name];
		}

		return NO;
	}

	GTFiltersNameToRegisteredFilters[self.name] = self;
	GTFiltersGitFilterToRegisteredFilters[[NSValue valueWithPointer:&_filter]] = self;

	return YES;
}

- (BOOL)unregister:(NSError **)error {
	int result = git_filter_unregister(self.name.UTF8String);
	if (result != GIT_OK) {
		if (error != NULL) {
			*error = [NSError git_errorFor:result description:@"Failed to unregister filter: %@", self.name];
		}

		return NO;
	}

	[GTFiltersNameToRegisteredFilters removeObjectForKey:self.name];
	[GTFiltersGitFilterToRegisteredFilters removeObjectForKey:[NSValue valueWithPointer:&_filter]];

	return YES;
}

#pragma mark Lookup

+ (GTFilter *)filterForName:(NSString *)name {
	NSParameterAssert(name != nil);

	return GTFiltersNameToRegisteredFilters[name];
}

@end
