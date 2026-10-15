#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

// This short-lived executable is the only process allowed to read its password
// items. The web host receives only status or an OBS challenge response.
static void Wipe(void *memory, size_t length) {
    volatile unsigned char *bytes = memory;
    while (length--) *bytes++ = 0;
}

static NSString *const Service = @"com.nightriderco.obs-websocket";
static const NSUInteger MaxRequestBytes = 16384;
static const NSUInteger MaxPasswordBytes = 4096;
static const NSUInteger MaxChallengeBytes = 1024;

static NSDictionary *Failure(NSString *code, NSString *message) {
    return @{@"ok": @NO, @"error": code, @"message": message};
}

static NSDictionary *KeychainFailure(OSStatus status) {
    if (status == errSecItemNotFound) {
        return Failure(@"missing_password", @"No password is saved for this OBS port. Enter it once to save it in Keychain.");
    }
    if (status == errSecInteractionNotAllowed || status == errSecNotAvailable) {
        return Failure(@"keychain_locked", @"The login Keychain is locked or unavailable. Unlock it in Keychain Access and try again.");
    }
    if (status == errSecAuthFailed || status == errSecUserCanceled) {
        return Failure(@"keychain_denied", @"Keychain access was denied. Check this helper's access in Keychain Access and try again.");
    }
    return Failure(@"keychain_unavailable", @"The password could not be accessed in the login Keychain. Check Keychain Access and try again.");
}

static BOOL ValidPort(id value) {
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    const double number = [value doubleValue];
    return isfinite(number) && number >= 1 && number <= 65535 && number == floor(number);
}

static NSMutableDictionary *Query(SecKeychainRef keychain, NSNumber *port) {
    return [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: Service,
              (__bridge id)kSecAttrAccount: [NSString stringWithFormat:@"127.0.0.1:%ld", (long)[port integerValue]],
              (__bridge id)kSecMatchSearchList: @[(__bridge id)keychain]} mutableCopy];
}

static BOOL BoundedString(id value, NSUInteger limit, BOOL allowEmpty) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    return data != nil && (allowEmpty || data.length > 0) && data.length <= limit;
}

static BOOL ValidKeys(NSDictionary *request, NSSet *allowed) {
    for (id key in request) if (![key isKindOfClass:[NSString class]] || ![allowed containsObject:key]) return NO;
    return YES;
}

static void Base64Digest(const unsigned char digest[CC_SHA256_DIGEST_LENGTH], char output[45]) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    NSUInteger in = 0, out = 0;
    while (in + 3 <= CC_SHA256_DIGEST_LENGTH) {
        uint32_t value = ((uint32_t)digest[in] << 16) | ((uint32_t)digest[in + 1] << 8) | digest[in + 2];
        output[out++] = alphabet[(value >> 18) & 63];
        output[out++] = alphabet[(value >> 12) & 63];
        output[out++] = alphabet[(value >> 6) & 63];
        output[out++] = alphabet[value & 63];
        in += 3;
    }
    const uint32_t value = ((uint32_t)digest[in] << 16) | ((uint32_t)digest[in + 1] << 8);
    output[out++] = alphabet[(value >> 18) & 63];
    output[out++] = alphabet[(value >> 12) & 63];
    output[out++] = alphabet[(value >> 6) & 63];
    output[out++] = '=';
    output[out] = '\0';
}

static NSString *Authentication(NSData *password, NSString *salt, NSString *challenge) {
    NSData *saltData = [salt dataUsingEncoding:NSUTF8StringEncoding];
    NSData *challengeData = [challenge dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA256_CTX context;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    char secret[45], response[45];
    CC_SHA256_Init(&context);
    CC_SHA256_Update(&context, password.bytes, (CC_LONG)password.length);
    CC_SHA256_Update(&context, saltData.bytes, (CC_LONG)saltData.length);
    CC_SHA256_Final(digest, &context);
    Base64Digest(digest, secret);
    CC_SHA256_Init(&context);
    CC_SHA256_Update(&context, secret, 44);
    CC_SHA256_Update(&context, challengeData.bytes, (CC_LONG)challengeData.length);
    CC_SHA256_Final(digest, &context);
    Base64Digest(digest, response);
    NSString *result = [[NSString alloc] initWithBytes:response length:44 encoding:NSASCIIStringEncoding];
    Wipe(&context, sizeof(context));
    Wipe(digest, sizeof(digest));
    Wipe(secret, sizeof(secret));
    Wipe(response, sizeof(response));
    return result;
}

static OSStatus OwnAccess(SecAccessRef *access) {
    SecTrustedApplicationRef application = NULL;
    OSStatus status = SecTrustedApplicationCreateFromPath(NULL, &application);
    if (status != errSecSuccess) return status;
    const void *values[] = {application};
    CFArrayRef applications = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
    status = SecAccessCreate(CFSTR("NIGHTRIDERCO OBS WebSocket password"), applications, access);
    CFRelease(applications);
    CFRelease(application);
    return status;
}

static NSDictionary *ProcessRequest(id value, SecKeychainRef keychain) {
    if (![value isKindOfClass:[NSDictionary class]]) return Failure(@"invalid_request", @"Expected a JSON object.");
    NSDictionary *request = value;
    NSString *action = request[@"action"];
    if (![action isKindOfClass:[NSString class]] || !ValidPort(request[@"port"])) return Failure(@"invalid_request", @"Use a supported action and an integer OBS port from 1 to 65535.");
    NSSet *keys = [NSSet setWithArray:@[@"action", @"port"]];
    if ([action isEqualToString:@"save"]) keys = [keys setByAddingObject:@"password"];
    else if ([action isEqualToString:@"auth"]) keys = [keys setByAddingObjectsFromSet:[NSSet setWithArray:@[@"salt", @"challenge"]]];
    else if (![action isEqualToString:@"status"] && ![action isEqualToString:@"forget"]) return Failure(@"invalid_request", @"Unsupported action.");
    if (!ValidKeys(request, keys)) return Failure(@"invalid_request", @"Unexpected request fields.");
    SecKeychainStatus keychainState = 0;
    if (![action isEqualToString:@"status"] && SecKeychainGetStatus(keychain, &keychainState) == errSecSuccess && !(keychainState & kSecUnlockStateStatus)) return KeychainFailure(errSecInteractionNotAllowed);
    NSMutableDictionary *query = Query(keychain, request[@"port"]);
    if ([action isEqualToString:@"save"]) {
        if (!BoundedString(request[@"password"], MaxPasswordBytes, NO)) return Failure(@"invalid_request", @"Enter a nonempty OBS password of at most 4096 UTF-8 bytes.");
        NSMutableData *password = [[request[@"password"] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        // Updating an ACL can trigger separate Keychain authorization. Preserve
        // the existing helper-only ACL when changing this item's secret value.
        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: password});
        if (status == errSecItemNotFound) {
            SecAccessRef access = NULL;
            status = OwnAccess(&access);
            if (status == errSecSuccess) {
                [query removeObjectForKey:(__bridge id)kSecMatchSearchList];
                query[(__bridge id)kSecUseKeychain] = (__bridge id)keychain;
                query[(__bridge id)kSecValueData] = password;
                query[(__bridge id)kSecAttrAccess] = (__bridge id)access;
                query[(__bridge id)kSecAttrLabel] = @"NIGHTRIDERCO OBS WebSocket";
                status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
                CFRelease(access);
            }
        }
        Wipe(password.mutableBytes, password.length);
        return status == errSecSuccess ? @{@"ok": @YES, @"saved": @YES} : KeychainFailure(status);
    }
    if ([action isEqualToString:@"forget"]) {
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
        return status == errSecSuccess || status == errSecItemNotFound ? @{@"ok": @YES, @"saved": @NO} : KeychainFailure(status);
    }
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    if ([action isEqualToString:@"status"]) {
        query[(__bridge id)kSecReturnAttributes] = @YES;
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (result) CFRelease(result);
        if (status == errSecItemNotFound) return @{@"ok": @YES, @"saved": @NO};
        return status == errSecSuccess ? @{@"ok": @YES, @"saved": @YES} : KeychainFailure(status);
    }
    if (!BoundedString(request[@"salt"], MaxChallengeBytes, NO) || !BoundedString(request[@"challenge"], MaxChallengeBytes, NO)) return Failure(@"invalid_request", @"OBS authentication needs a nonempty salt and challenge of at most 1024 UTF-8 bytes each.");
    query[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess) {
        if (result) CFRelease(result);
        return KeychainFailure(status);
    }
    if (!result || CFGetTypeID(result) != CFDataGetTypeID() || CFDataGetLength((CFDataRef)result) <= 0 || CFDataGetLength((CFDataRef)result) > (CFIndex)MaxPasswordBytes) {
        if (result) CFRelease(result);
        return Failure(@"keychain_unavailable", @"The saved Keychain item is invalid. Save the OBS password again.");
    }
    NSMutableData *password = [(__bridge NSData *)result mutableCopy];
    CFRelease(result);
    NSString *authentication = Authentication(password, request[@"salt"], request[@"challenge"]);
    Wipe(password.mutableBytes, password.length);
    return @{@"ok": @YES, @"authentication": authentication};
}

#ifndef KEYCHAIN_TOOL_NO_MAIN
static NSDictionary *ReadRequest(void) {
    NSMutableData *input = [NSMutableData data];
    unsigned char buffer[1024];
    size_t size;
    while ((size = fread(buffer, 1, sizeof(buffer), stdin)) > 0) {
        if (input.length + size > MaxRequestBytes) {
            Wipe(buffer, sizeof(buffer));
            Wipe(input.mutableBytes, input.length);
            return nil;
        }
        [input appendBytes:buffer length:size];
    }
    Wipe(buffer, sizeof(buffer));
    id request = ferror(stdin) ? nil : [NSJSONSerialization JSONObjectWithData:input options:0 error:NULL];
    Wipe(input.mutableBytes, input.length);
    return [request isKindOfClass:[NSDictionary class]] ? request : nil;
}

int main(int argc, const char *argv[]) {
    (void)argv;
    @autoreleasepool {
        NSDictionary *response;
        if (argc != 1) {
            response = Failure(@"invalid_request", @"This helper accepts JSON on standard input only.");
        } else {
            NSDictionary *request = ReadRequest();
            if (!request) response = Failure(@"invalid_request", @"Expected one JSON object of at most 16384 bytes.");
            else {
                SecKeychainSetUserInteractionAllowed(false);
                NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Keychains/login.keychain-db"];
                SecKeychainRef keychain = NULL;
                OSStatus status = SecKeychainOpen(path.fileSystemRepresentation, &keychain);
                if (status == errSecSuccess) {
                    @try { response = ProcessRequest(request, keychain); }
                    @catch (NSException *exception) { (void)exception; response = Failure(@"internal_error", @"The Keychain request could not be completed."); }
                    CFRelease(keychain);
                } else response = KeychainFailure(status);
            }
        }
        NSData *output = [NSJSONSerialization dataWithJSONObject:response options:0 error:NULL];
        if (!output) return 2;
        fwrite(output.bytes, 1, output.length, stdout);
        fputc('\n', stdout);
        return [response[@"ok"] boolValue] ? 0 : 1;
    }
}
#endif
