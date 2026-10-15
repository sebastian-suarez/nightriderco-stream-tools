#define KEYCHAIN_TOOL_NO_MAIN 1
#include "keychain-tool.m"

// This test executable uses only a new disposable keychain supplied by test.sh.
// It never opens, changes, or searches the user's login keychain.
static NSUInteger Checks = 0;

static void Check(BOOL passed, NSString *description) {
    if (!passed) {
        fprintf(stderr, "FAILED: %s\n", description.UTF8String);
        @throw [NSException exceptionWithName:@"TestFailure" reason:description userInfo:nil];
    }
    ++Checks;
}

static NSDictionary *Child(NSString *executable, NSString *path, NSDictionary *request) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = @[@"--child", path];
    NSPipe *input = [NSPipe pipe], *output = [NSPipe pipe];
    task.standardInput = input;
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    [task launchAndReturnError:&error];
    Check(error == nil, @"Child helper starts");
    [input.fileHandleForWriting writeData:[NSJSONSerialization dataWithJSONObject:request options:0 error:NULL]];
    [input.fileHandleForWriting closeFile];
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSDictionary *response = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    Check([response isKindOfClass:[NSDictionary class]], @"Child returns only JSON");
    return response;
}

static BOOL HasOwnReadAccessOnly(SecKeychainRef keychain) {
    NSMutableDictionary *query = Query(keychain, @4455);
    query[(__bridge id)kSecReturnRef] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef item = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &item) != errSecSuccess) return NO;
    SecAccessRef access = NULL;
    OSStatus status = SecKeychainItemCopyAccess((SecKeychainItemRef)item, &access);
    CFRelease(item);
    if (status != errSecSuccess) return NO;
    CFArrayRef rules = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt);
    CFRelease(access);
    BOOL valid = rules && CFArrayGetCount(rules) == 1;
    if (valid) {
        CFArrayRef applications = NULL;
        CFStringRef description = NULL;
        SecKeychainPromptSelector prompt;
        status = SecACLCopyContents((SecACLRef)CFArrayGetValueAtIndex(rules, 0), &applications, &description, &prompt);
        valid = status == errSecSuccess && applications && CFArrayGetCount(applications) == 1;
        if (applications) CFRelease(applications);
        if (description) CFRelease(description);
    }
    if (rules) CFRelease(rules);
    return valid;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)MaxRequestBytes;
        SecKeychainSetUserInteractionAllowed(false);
        if (argc == 3 && strcmp(argv[1], "--child") == 0) {
            SecKeychainRef keychain = NULL;
            if (SecKeychainOpen(argv[2], &keychain) != errSecSuccess) return 2;
            id request = [NSJSONSerialization JSONObjectWithData:[[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile] options:0 error:NULL];
            NSDictionary *response = ProcessRequest(request, keychain);
            NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:NULL];
            fwrite(data.bytes, 1, data.length, stdout);
            fputc('\n', stdout);
            CFRelease(keychain);
            return 0;
        }
        if (argc != 2) return 2;
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSString *executable = [NSProcessInfo processInfo].arguments[0];
        const char testPassword[] = "not-a-real-credential-test-only";
        SecKeychainRef keychain = NULL;
        OSStatus createStatus = SecKeychainCreate(path.fileSystemRepresentation, (UInt32)strlen(testPassword), testPassword, false, NULL, &keychain);
        if (createStatus != errSecSuccess) fprintf(stderr, "Temporary keychain create status: %d\n", (int)createStatus);
        if (createStatus != errSecSuccess) return 1;
        Check(YES, @"Create isolated keychain");
        BOOL failed = NO;
        @try {
            NSDictionary *result = ProcessRequest(@{@"action": @"status", @"port": @4455}, keychain);
            Check([result[@"ok"] boolValue] && ![result[@"saved"] boolValue], @"New port has no saved item");
            result = Child(executable, path, @{@"action": @"save", @"port": @4455, @"password": @"test-only $ password \" with ü\n"});
            Check([result[@"ok"] boolValue] && [result[@"saved"] boolValue], @"Save an unusual UTF-8 password");
            Check(HasOwnReadAccessOnly(keychain), @"New item restricts password reads to one trusted helper");
            result = Child(executable, path, @{@"action": @"status", @"port": @4455});
            Check([result[@"ok"] boolValue] && [result[@"saved"] boolValue], @"Saved item survives helper process exit");
            result = Child(executable, path, @{@"action": @"auth", @"port": @4455, @"salt": @"OBS-salt", @"challenge": @"OBS-challenge"});
            Check([result[@"authentication"] isEqualToString:@"wO0dYMvUxsEKJr16/GTsXuAHesKt06ihuxWghaRIl+Y="], @"Authentication matches independent SHA-256 fixture");
            Check(result[@"password"] == nil && result.count == 2, @"Authentication does not return raw password");
            result = Child(executable, path, @{@"action": @"save", @"port": @4455, @"password": @"replacement-test-only"});
            if (![result[@"ok"] boolValue]) fprintf(stderr, "Replacement error: %s\n", [result[@"error"] UTF8String]);
            Check([result[@"ok"] boolValue], @"Replace password in place");
            Check(HasOwnReadAccessOnly(keychain), @"Password replacement preserves the restricted read ACL");
            result = Child(executable, path, @{@"action": @"auth", @"port": @4455, @"salt": @"OBS-salt", @"challenge": @"OBS-challenge"});
            Check([result[@"authentication"] isEqualToString:@"t6ytSkJAC8ceInMEBMPfTXT3l5c80r20gF9zPHRMqUg="], @"Replacement used for new authentication");
            result = ProcessRequest(@{@"action": @"status", @"port": @4456}, keychain);
            Check([result[@"ok"] boolValue] && ![result[@"saved"] boolValue], @"Ports have isolated saved passwords");
            NSArray *invalid = @[
                @{}, @[], @{@"action": @"read", @"port": @4455},
                @{@"action": @"status", @"port": @YES},
                @{@"action": @"status", @"port": @4455.5},
                @{@"action": @"status", @"port": @0},
                @{@"action": @"status", @"port": @65536},
                @{@"action": @"status", @"port": @4455, @"password": @"unexpected"},
                @{@"action": @"save", @"port": @4455, @"password": @""},
                @{@"action": @"save", @"port": @4455, @"password": [@"a" stringByPaddingToLength:4097 withString:@"a" startingAtIndex:0]},
                @{@"action": @"auth", @"port": @4455, @"salt": @"", @"challenge": @"a"},
                @{@"action": @"auth", @"port": @4455, @"salt": @"a", @"challenge": [@"a" stringByPaddingToLength:1025 withString:@"a" startingAtIndex:0]}
            ];
            for (id request in invalid) {
                result = ProcessRequest(request, keychain);
                Check(![result[@"ok"] boolValue] && [result[@"error"] isEqualToString:@"invalid_request"], @"Invalid input rejected");
            }
            Check(SecKeychainLock(keychain) == errSecSuccess, @"Lock isolated keychain");
            result = Child(executable, path, @{@"action": @"auth", @"port": @4455, @"salt": @"OBS-salt", @"challenge": @"OBS-challenge"});
            if ([result[@"ok"] boolValue] || ![result[@"error"] isEqualToString:@"keychain_locked"]) fprintf(stderr, "Locked request result: ok=%d, error=%s\n", [result[@"ok"] boolValue], [result[@"error"] UTF8String]);
            Check(![result[@"ok"] boolValue] && [result[@"error"] isEqualToString:@"keychain_locked"], @"Locked keychain fails without a blocking prompt");
            Check(SecKeychainUnlock(keychain, (UInt32)strlen(testPassword), testPassword, true) == errSecSuccess, @"Unlock isolated keychain");
            result = Child(executable, path, @{@"action": @"forget", @"port": @4455});
            Check([result[@"ok"] boolValue] && ![result[@"saved"] boolValue], @"Forget deletes saved item");
            result = ProcessRequest(@{@"action": @"forget", @"port": @4455}, keychain);
            Check([result[@"ok"] boolValue], @"Forget is idempotent");
            result = ProcessRequest(@{@"action": @"auth", @"port": @4455, @"salt": @"OBS-salt", @"challenge": @"OBS-challenge"}, keychain);
            Check([result[@"error"] isEqualToString:@"missing_password"], @"Forgotten credential cannot authenticate");
        } @catch (NSException *exception) {
            (void)exception;
            failed = YES;
        } @finally {
            SecKeychainDelete(keychain);
            CFRelease(keychain);
        }
        if (!failed) printf("Native Keychain checks passed: %lu\n", (unsigned long)Checks);
        return failed ? 1 : 0;
    }
}
