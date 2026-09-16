#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
static void dumpClass(id obj, const char *label) {
    if (!obj) { printf("%s: nil\n", label); return; }
    Class c = object_getClass(obj);
    printf("%s: class %s (super %s)\n", label, class_getName(c), class_getName(class_getSuperclass(c)));
    unsigned n; Method *ms = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n; i++) printf("   -%s\n", sel_getName(method_getName(ms[i])));
    free(ms);
    objc_property_t *ps = class_copyPropertyList(c, &n);
    for (unsigned i = 0; i < n; i++) printf("   @%s : %s\n", property_getName(ps[i]), property_getAttributes(ps[i]));
    free(ps);
}
int main(int argc, char **argv) { @autoreleasepool {
    dlopen("/System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine", RTLD_NOW);
    NSString *dir = [NSString stringWithUTF8String:argv[1]];
    NSData *mil = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"model.mil"]];
    NSData *wb = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"weights/weight.bin"]];
    id desc = ((id(*)(Class,SEL,id,id,id))objc_msgSend)(NSClassFromString(@"_ANEInMemoryModelDescriptor"), @selector(modelWithMILText:weights:optionsPlist:), mil, @{@"@model_path/weights/weight.bin": @{@"offset": @0, @"data": wb}}, nil);
    id model = ((id(*)(Class,SEL,id))objc_msgSend)(NSClassFromString(@"_ANEInMemoryModel"), @selector(inMemoryModelWithDescriptor:), desc);
    id hexId = ((id(*)(id,SEL))objc_msgSend)(model, @selector(hexStringIdentifier));
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:hexId];
    [[NSFileManager defaultManager] createDirectoryAtPath:[tmp stringByAppendingPathComponent:@"weights"] withIntermediateDirectories:YES attributes:nil error:nil];
    [mil writeToFile:[tmp stringByAppendingPathComponent:@"model.mil"] atomically:YES];
    [wb writeToFile:[tmp stringByAppendingPathComponent:@"weights/weight.bin"] atomically:YES];
    NSError *err = nil;
    BOOL ok = ((BOOL(*)(id,SEL,unsigned int,id,NSError**))objc_msgSend)(model, @selector(compileWithQoS:options:error:), 21, @{}, &err);
    printf("compile: %s\n", ok ? "ok" : "FAILED");
    dumpClass(model, "model");
    id program = ((id(*)(id,SEL))objc_msgSend)(model, @selector(program));
    dumpClass(program, "program");
    id handle = ((id(*)(id,SEL))objc_msgSend)(model, @selector(programHandle));
    dumpClass(handle, "programHandle");
    printf("localModelPath: %s\n", [[((id(*)(id,SEL))objc_msgSend)(model, @selector(localModelPath)) description] UTF8String]);
    system([[NSString stringWithFormat:@"ls -la '%@'", tmp] UTF8String]);
    system([[NSString stringWithFormat:@"cp '%@/data' '%@/compiled_full_512.data'", tmp, [[NSFileManager defaultManager] currentDirectoryPath]] UTF8String]);
    ok = ((BOOL(*)(id,SEL,unsigned int,id,NSError**))objc_msgSend)(model, @selector(loadWithQoS:options:error:), 21, @{}, &err);
    printf("load: %s\n", ok ? "ok" : "FAILED");
    program = ((id(*)(id,SEL))objc_msgSend)(model, @selector(program));
    dumpClass(program, "program (after load)");
    printf("programHandle (after load): %llu\n", (unsigned long long)((uint64_t(*)(id,SEL))objc_msgSend)(model, @selector(programHandle)));
    ((BOOL(*)(id,SEL,unsigned int,NSError**))objc_msgSend)(model, @selector(unloadWithQoS:error:), 21, &err);
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
} return 0; }
