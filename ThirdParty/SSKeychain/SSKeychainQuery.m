//
//  SSKeychainQuery.m
//  SSKeychain
//
//  Created by Caleb Davenport on 3/19/13.
//  Copyright (c) 2013-2014 Sam Soffes. All rights reserved.
//

#import "SSKeychainQuery.h"
#import "SSKeychain.h"

@implementation SSKeychainQuery

@synthesize account = _account;
@synthesize service = _service;
@synthesize label = _label;
@synthesize passwordData = _passwordData;

#if __IPHONE_3_0 && TARGET_OS_IPHONE
@synthesize accessGroup = _accessGroup;
#endif

@synthesize synchronizationMode = _synchronizationMode;

#pragma mark - Public

- (BOOL)save:(NSError *__autoreleasing *)error {
    OSStatus status = SSKeychainErrorBadArguments;
    if (!self.service || !self.account || !self.passwordData) {
        if (error) {
            *error = [[self class] errorWithCode:status];
        }
        return NO;
    }

    [self deleteItem:nil];

    NSMutableDictionary *query = [self query];
    [query setObject:self.passwordData forKey:(__bridge id)kSecValueData];
    if (self.label) {
        [query setObject:self.label forKey:(__bridge id)kSecAttrLabel];
    }
#if __IPHONE_4_0 && TARGET_OS_IPHONE
    CFTypeRef accessibilityType = [SSKeychain accessibilityType];
    if (accessibilityType) {
        [query setObject:(__bridge id)accessibilityType forKey:(__bridge id)kSecAttrAccessible];
    }
#endif
    if (self.pathToKeychain) {
        query[(__bridge id)kSecUseKeychain] = self.pathToKeychain;
    }
    status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);

    if (status != errSecSuccess && error != NULL) {
        *error = [[self class] errorWithCode:status];
    }

    return (status == errSecSuccess);
}

- (BOOL)getKeychain:(SecKeychainRef *)keychainPtr query:(NSMutableDictionary *)query error:(NSError * __autoreleasing *)error {
    if (self.pathToKeychain) {
        const OSStatus status = SecKeychainOpen(self.pathToKeychain.UTF8String, keychainPtr);
        if (*keychainPtr == NULL) {
            if (error) {
                *error = [[self class] errorWithCode:status];
            }
            return NO;
        }
        query[(__bridge id)kSecMatchSearchList] = @[(__bridge id)*keychainPtr];
    }
    return YES;
}

- (BOOL)deleteItem:(NSError *__autoreleasing *)error {
    OSStatus status = SSKeychainErrorBadArguments;
    if (!self.service || !self.account) {
        if (error) {
            *error = [[self class] errorWithCode:status];
        }
        return NO;
    }

    NSMutableDictionary *query = [self query];
    SecKeychainRef keychain = NULL;
    if (![self getKeychain:&keychain query:query error:error]) {
        return NO;
    }
    if (self.pathToKeychain) {
        status = SecKeychainOpen(self.pathToKeychain.UTF8String, &keychain);
        if (keychain == NULL) {
            if (error) {
                *error = [[self class] errorWithCode:status];
            }
            return NO;
        }
    }
#if TARGET_OS_IPHONE
    status = SecItemDelete((__bridge CFDictionaryRef)query);
#else
    CFTypeRef result = NULL;
    [query setObject:@YES forKey:(__bridge id)kSecReturnRef];
    status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess) {
        status = SecKeychainItemDelete((SecKeychainItemRef)result);
        CFRelease(result);
    }
#endif

    if (status != errSecSuccess && error != NULL) {
        *error = [[self class] errorWithCode:status];
    }
    if (keychain != NULL) {
        CFRelease(keychain);
    }
    return (status == errSecSuccess);
}


- (NSArray *)fetchAll:(NSError *__autoreleasing *)error {
    OSStatus status = SSKeychainErrorBadArguments;
    NSMutableDictionary *query = [self query];
    [query setObject:@YES forKey:(__bridge id)kSecReturnAttributes];
    [query setObject:(__bridge id)kSecMatchLimitAll forKey:(__bridge id)kSecMatchLimit];
    SecKeychainRef keychain = NULL;
    if (![self getKeychain:&keychain query:query error:error]) {
        return nil;
    }

    CFTypeRef result = NULL;
    status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (keychain != NULL) {
        CFRelease(keychain);
    }
    if (status != errSecSuccess && error != NULL) {
        *error = [[self class] errorWithCode:status];
        return nil;
    }

    return (__bridge_transfer NSArray *)result;
}


- (BOOL)fetch:(NSError *__autoreleasing *)error {
    OSStatus status = SSKeychainErrorBadArguments;
    if (!self.service || !self.account) {
        if (error) {
            *error = [[self class] errorWithCode:status];
        }
        return NO;
    }

    CFTypeRef result = NULL;
    NSMutableDictionary *query = [self query];
    [query setObject:@YES forKey:(__bridge id)kSecReturnData];
    [query setObject:(__bridge id)kSecMatchLimitOne forKey:(__bridge id)kSecMatchLimit];
    SecKeychainRef keychain = NULL;
    if (![self getKeychain:&keychain query:query error:error]) {
        return NO;
    }

    status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (keychain != NULL) {
        CFRelease(keychain);
    }

    if (status != errSecSuccess && error != NULL) {
        *error = [[self class] errorWithCode:status];
        return NO;
    }

    self.passwordData = (__bridge_transfer NSData *)result;
    return YES;
}


#pragma mark - Accessors

- (void)setPassword:(NSString *)password {
    self.passwordData = [password dataUsingEncoding:NSUTF8StringEncoding];
}


- (NSString *)password {
    if ([self.passwordData length]) {
        return [[NSString alloc] initWithData:self.passwordData encoding:NSUTF8StringEncoding];
    }
    return nil;
}


#pragma mark - Private

- (NSMutableDictionary *)query {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:3];
    [dictionary setObject:(__bridge id)kSecClassGenericPassword forKey:(__bridge id)kSecClass];

    if (self.service) {
        [dictionary setObject:self.service forKey:(__bridge id)kSecAttrService];
    }

    if (self.account) {
        [dictionary setObject:self.account forKey:(__bridge id)kSecAttrAccount];
    }

#if __IPHONE_3_0 && TARGET_OS_IPHONE && !TARGET_IPHONE_SIMULATOR
    if (self.accessGroup) {
        [dictionary setObject:self.accessGroup forKey:(__bridge id)kSecAttrAccessGroup];
    }
#endif

    id value;

    switch (self.synchronizationMode) {
        case SSKeychainQuerySynchronizationModeNo: {
          value = @NO;
          break;
        }
        case SSKeychainQuerySynchronizationModeYes: {
          value = @YES;
          break;
        }
        case SSKeychainQuerySynchronizationModeAny: {
          value = (__bridge id)(kSecAttrSynchronizableAny);
          break;
        }
    }

    [dictionary setObject:value forKey:(__bridge id)(kSecAttrSynchronizable)];

    return dictionary;
}


+ (NSError *)errorWithCode:(OSStatus) code {
    NSString *message = nil;
    switch (code) {
        case errSecSuccess: return nil;
        case SSKeychainErrorBadArguments: message = NSLocalizedStringFromTable(@"SSKeychainErrorBadArguments", @"SSKeychain", nil); break;

#if TARGET_OS_IPHONE
        case errSecUnimplemented: {
            message = NSLocalizedStringFromTable(@"errSecUnimplemented", @"SSKeychain", nil);
            break;
        }
        case errSecParam: {
            message = NSLocalizedStringFromTable(@"errSecParam", @"SSKeychain", nil);
            break;
        }
        case errSecAllocate: {
            message = NSLocalizedStringFromTable(@"errSecAllocate", @"SSKeychain", nil);
            break;
        }
        case errSecNotAvailable: {
            message = NSLocalizedStringFromTable(@"errSecNotAvailable", @"SSKeychain", nil);
            break;
        }
        case errSecDuplicateItem: {
            message = NSLocalizedStringFromTable(@"errSecDuplicateItem", @"SSKeychain", nil);
            break;
        }
        case errSecItemNotFound: {
            message = NSLocalizedStringFromTable(@"errSecItemNotFound", @"SSKeychain", nil);
            break;
        }
        case errSecInteractionNotAllowed: {
            message = NSLocalizedStringFromTable(@"errSecInteractionNotAllowed", @"SSKeychain", nil);
            break;
        }
        case errSecDecode: {
            message = NSLocalizedStringFromTable(@"errSecDecode", @"SSKeychain", nil);
            break;
        }
        case errSecAuthFailed: {
            message = NSLocalizedStringFromTable(@"errSecAuthFailed", @"SSKeychain", nil);
            break;
        }
        default: {
            message = NSLocalizedStringFromTable(@"errSecDefault", @"SSKeychain", nil);
        }
#else
        default:
            message = (__bridge_transfer NSString *)SecCopyErrorMessageString(code, NULL);
#endif
    }

    NSDictionary *userInfo = nil;
    if (message) {
        userInfo = @{ NSLocalizedDescriptionKey : message };
    }
    return [NSError errorWithDomain:kSSKeychainErrorDomain code:code userInfo:userInfo];
}

@end
