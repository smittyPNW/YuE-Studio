/*
 * ane_synth_probe.m — how long does the Neural Engine take to COMPILE and RUN a
 * YuE2-synthesis-shaped transformer stack, via the private AppleNeuralEngine
 * framework (no Core ML at build or run time)?
 *
 * Per layer, at hidden 2048, 16 heads x 128, MLP 11008, fp16, S frames:
 *   q,k,v = x@Wq, x@Wk, x@Wv      (k/v use 16 heads here; the real model uses 8)
 *   scores = softmax(q k^T / sqrt(128))  -> [1,16,S,S]
 *   attn   = scores v -> @Wo, + residual
 *   mlp    = (silu(h@Wg) * (h@Wu)) @ Wd, + residual        (norms omitted)
 * Weights are random fp16 baked into the program as BLOBFILE constants,
 * exactly as a real export would do. Shapes are fixed at compile time.
 *
 * Build: clang -O2 -fobjc-arc ane_synth_probe.m -o ane_synth_probe \
 *            -framework Foundation -framework IOSurface
 * Run:   ./ane_synth_probe <S frames> <layers> [evals]
 */
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>

#define D 2048
#define H 16
#define HD 128
#define FF 11008

static mach_timebase_info_data_t tb;
static double ms(uint64_t t) { return (double)t * tb.numer / tb.denom / 1e6; }

typedef struct { const char *name; int rows, cols; unsigned long offset; } W;

static NSData *weightBlob(W *ws, int n, unsigned long *total) {
    unsigned long size = 64;
    for (int i = 0; i < n; i++) { ws[i].offset = size; size += 64 + (unsigned long)ws[i].rows * ws[i].cols * 2; }
    uint8_t *buf = calloc(size, 1);
    buf[0] = 0x01; buf[4] = 0x02;
    uint32_t seed = 12345;
    for (int i = 0; i < n; i++) {
        uint8_t *chunk = buf + ws[i].offset;
        chunk[0]=0xEF; chunk[1]=0xBE; chunk[2]=0xAD; chunk[3]=0xDE; chunk[4]=0x01; chunk[10]=0x08;
        uint16_t *h = (uint16_t *)(chunk + 64);
        unsigned long count = (unsigned long)ws[i].rows * ws[i].cols;
        for (unsigned long j = 0; j < count; j++) {
            seed = seed * 1664525u + 1013904223u;
            h[j] = (uint16_t)((seed >> 8) & 0x83FF) | 0x2000;   /* random sign, |w| ~ 0.01 */
        }
    }
    *total = size;
    return [NSData dataWithBytesNoCopy:buf length:size freeWhenDone:YES];
}

static NSString *mil(int S, int L, W *ws) {
    NSMutableString *m = [NSMutableString string];
    [m appendString:@"program(1.3)\n[buildInfo = dict<string, string>({{\"coremltools-version\", \"9.0\"}})]\n{\n"];
    [m appendFormat:@"    func main<ios18>(tensor<fp16, [1, 1, %d, %d]> x) {\n", S, D];
    [m appendString:@"        bool bF = const()[name=string(\"bF\"), val=bool(false)];\n"
                     "        bool bT = const()[name=string(\"bT\"), val=bool(true)];\n"
                     "        int32 axl = const()[name=string(\"axl\"), val=int32(-1)];\n"
                     "        fp16 scale = const()[name=string(\"scale\"), val=fp16(0.08838)];\n"];
    [m appendFormat:@"        tensor<int32, [4]> shHeads = const()[name=string(\"shHeads\"), val=tensor<int32, [4]>([1, %d, %d, %d])];\n", S, H, HD];
    [m appendFormat:@"        tensor<int32, [4]> shFlat = const()[name=string(\"shFlat\"), val=tensor<int32, [4]>([1, 1, %d, %d])];\n", S, D];
    [m appendString:@"        tensor<int32, [4]> permH = const()[name=string(\"permH\"), val=tensor<int32, [4]>([0, 2, 1, 3])];\n"];
    int wi = 0;
    NSString *h = @"x";
    for (int l = 0; l < L; l++) {
        const char *names[7] = {"q","k","v","o","g","u","d"};
        for (int j = 0; j < 7; j++, wi++)
            [m appendFormat:@"        tensor<fp16, [%d, %d]> W%s%d = const()[name=string(\"W%s%d\"), val=tensor<fp16, [%d, %d]>(BLOBFILE(path=string(\"@model_path/weights/weight.bin\"), offset=uint64(%lu)))];\n",
                ws[wi].rows, ws[wi].cols, names[j], l, names[j], l, ws[wi].rows, ws[wi].cols, ws[wi].offset];
        #define OP(fmt, ...) [m appendFormat:@"        " fmt "\n", ##__VA_ARGS__]
        OP("tensor<fp16, [1, 1, %d, %d]> q%d = matmul(transpose_x=bF, transpose_y=bF, x=%@, y=Wq%d)[name=string(\"q%d\")];", S, D, l, h, l, l);
        OP("tensor<fp16, [1, 1, %d, %d]> k%d = matmul(transpose_x=bF, transpose_y=bF, x=%@, y=Wk%d)[name=string(\"k%d\")];", S, D, l, h, l, l);
        OP("tensor<fp16, [1, 1, %d, %d]> v%d = matmul(transpose_x=bF, transpose_y=bF, x=%@, y=Wv%d)[name=string(\"v%d\")];", S, D, l, h, l, l);
        OP("tensor<fp16, [1, %d, %d, %d]> qh%d = reshape(shape=shHeads, x=q%d)[name=string(\"qh%d\")];", S, H, HD, l, l, l);
        OP("tensor<fp16, [1, %d, %d, %d]> kh%d = reshape(shape=shHeads, x=k%d)[name=string(\"kh%d\")];", S, H, HD, l, l, l);
        OP("tensor<fp16, [1, %d, %d, %d]> vh%d = reshape(shape=shHeads, x=v%d)[name=string(\"vh%d\")];", S, H, HD, l, l, l);
        OP("tensor<fp16, [1, %d, %d, %d]> qt%d = transpose(perm=permH, x=qh%d)[name=string(\"qt%d\")];", H, S, HD, l, l, l);
        OP("tensor<fp16, [1, %d, %d, %d]> kt%d = transpose(perm=permH, x=kh%d)[name=string(\"kt%d\")];", H, S, HD, l, l, l);
        OP("tensor<fp16, [1, %d, %d, %d]> vt%d = transpose(perm=permH, x=vh%d)[name=string(\"vt%d\")];", H, S, HD, l, l, l);
        OP("tensor<fp16, [1, %d, %d, %d]> sc%d = matmul(transpose_x=bF, transpose_y=bT, x=qt%d, y=kt%d)[name=string(\"sc%d\")];", H, S, S, l, l, l, l);
        OP("tensor<fp16, [1, %d, %d, %d]> ss%d = mul(x=sc%d, y=scale)[name=string(\"ss%d\")];", H, S, S, l, l, l);
        OP("tensor<fp16, [1, %d, %d, %d]> pr%d = softmax(axis=axl, x=ss%d)[name=string(\"pr%d\")];", H, S, S, l, l, l);
        OP("tensor<fp16, [1, %d, %d, %d]> at%d = matmul(transpose_x=bF, transpose_y=bF, x=pr%d, y=vt%d)[name=string(\"at%d\")];", H, S, HD, l, l, l, l);
        OP("tensor<fp16, [1, %d, %d, %d]> ab%d = transpose(perm=permH, x=at%d)[name=string(\"ab%d\")];", S, H, HD, l, l, l);
        OP("tensor<fp16, [1, 1, %d, %d]> af%d = reshape(shape=shFlat, x=ab%d)[name=string(\"af%d\")];", S, D, l, l, l);
        OP("tensor<fp16, [1, 1, %d, %d]> ao%d = matmul(transpose_x=bF, transpose_y=bF, x=af%d, y=Wo%d)[name=string(\"ao%d\")];", S, D, l, l, l, l);
        OP("tensor<fp16, [1, 1, %d, %d]> r%d = add(x=%@, y=ao%d)[name=string(\"r%d\")];", S, D, l, h, l, l);
        OP("tensor<fp16, [1, 1, %d, %d]> gt%d = matmul(transpose_x=bF, transpose_y=bF, x=r%d, y=Wg%d)[name=string(\"gt%d\")];", S, FF, l, l, l, l);
        OP("tensor<fp16, [1, 1, %d, %d]> up%d = matmul(transpose_x=bF, transpose_y=bF, x=r%d, y=Wu%d)[name=string(\"up%d\")];", S, FF, l, l, l, l);
        OP("tensor<fp16, [1, 1, %d, %d]> sg%d = silu(x=gt%d)[name=string(\"sg%d\")];", S, FF, l, l, l);
        OP("tensor<fp16, [1, 1, %d, %d]> hp%d = mul(x=sg%d, y=up%d)[name=string(\"hp%d\")];", S, FF, l, l, l, l);
        OP("tensor<fp16, [1, 1, %d, %d]> dn%d = matmul(transpose_x=bF, transpose_y=bF, x=hp%d, y=Wd%d)[name=string(\"dn%d\")];", S, D, l, l, l, l);
        OP("tensor<fp16, [1, 1, %d, %d]> h%d = add(x=r%d, y=dn%d)[name=string(\"h%d\")];", S, D, l, l, l, l);
        h = [NSString stringWithFormat:@"h%d", l];
    }
    [m appendFormat:@"        tensor<fp16, [1, 1, %d, %d]> out = identity(x=%@)[name=string(\"out\")];\n", S, D, h];
    [m appendString:@"    } -> (out);\n}\n"];
    return m;
}

static IOSurfaceRef surface(size_t bytes) {
    return IOSurfaceCreate((__bridge CFDictionaryRef)@{(id)kIOSurfaceWidth: @(bytes), (id)kIOSurfaceHeight: @1,
        (id)kIOSurfaceBytesPerElement: @1, (id)kIOSurfaceBytesPerRow: @(bytes), (id)kIOSurfaceAllocSize: @(bytes), (id)kIOSurfacePixelFormat: @0});
}

int main(int argc, char **argv) {
    @autoreleasepool {
        mach_timebase_info(&tb);
        if (argc < 2) { printf("usage: %s <dir with model.mil + weights/weight.bin + meta.json> [evals]\n", argv[0]); return 1; }
        NSString *dir = [NSString stringWithUTF8String:argv[1]];
        int evals = argc > 2 ? atoi(argv[2]) : 3;
        NSDictionary *meta = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"meta.json"]] options:0 error:nil];
        if (!meta) { printf("missing meta.json\n"); return 1; }
        int S = [meta[@"frames"] intValue], L = [meta[@"layers"] intValue];
        double flops = [meta[@"gflop_per_pass"] doubleValue] * 1e9;
        if (!dlopen("/System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine", RTLD_NOW)) { printf("dlopen failed\n"); return 1; }
        Class Desc = NSClassFromString(@"_ANEInMemoryModelDescriptor"), IMM = NSClassFromString(@"_ANEInMemoryModel");
        Class Req = NSClassFromString(@"_ANERequest"), Surf = NSClassFromString(@"_ANEIOSurfaceObject");
        if (!Desc || !IMM || !Req || !Surf) { printf("private classes missing\n"); return 1; }

        NSData *milData = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"model.mil"]];
        NSData *wb = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"weights/weight.bin"]];
        if (!milData || !wb) { printf("missing model.mil or weights/weight.bin\n"); return 1; }
        printf("{\"S\": %d, \"layers\": %d, \"attn\": \"%s\", \"weights_MB\": %.0f, \"mil_KB\": %lu, \"gflop_per_pass\": %.0f}\n",
               S, L, [meta[@"attn"] UTF8String], wb.length / 1048576.0, (unsigned long)milData.length / 1024, flops / 1e9);
        fflush(stdout);

        id desc = ((id(*)(Class,SEL,id,id,id))objc_msgSend)(Desc, @selector(modelWithMILText:weights:optionsPlist:),
                     milData, @{@"@model_path/weights/weight.bin": @{@"offset": @0, @"data": wb}}, nil);
        if (!desc) { printf("descriptor failed\n"); return 1; }
        id model = ((id(*)(Class,SEL,id))objc_msgSend)(IMM, @selector(inMemoryModelWithDescriptor:), desc);
        id hexId = ((id(*)(id,SEL))objc_msgSend)(model, @selector(hexStringIdentifier));
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:hexId];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:[tmp stringByAppendingPathComponent:@"weights"] withIntermediateDirectories:YES attributes:nil error:nil];
        [milData writeToFile:[tmp stringByAppendingPathComponent:@"model.mil"] atomically:YES];
        [wb writeToFile:[tmp stringByAppendingPathComponent:@"weights/weight.bin"] atomically:YES];

        NSError *err = nil;
        uint64_t t0 = mach_absolute_time();
        BOOL ok = ((BOOL(*)(id,SEL,unsigned int,id,NSError**))objc_msgSend)(model, @selector(compileWithQoS:options:error:), 21, @{}, &err);
        double compileMs = ms(mach_absolute_time() - t0);
        if (!ok) { printf("{\"compile\": \"FAILED\", \"error\": \"%s\"}\n", [[[err description] stringByReplacingOccurrencesOfString:@"\"" withString:@"'"] UTF8String]); [fm removeItemAtPath:tmp error:nil]; return 2; }
        t0 = mach_absolute_time();
        ok = ((BOOL(*)(id,SEL,unsigned int,id,NSError**))objc_msgSend)(model, @selector(loadWithQoS:options:error:), 21, @{}, &err);
        double loadMs = ms(mach_absolute_time() - t0);
        if (!ok) { printf("{\"load\": \"FAILED\", \"error\": \"%s\"}\n", [[[err description] stringByReplacingOccurrencesOfString:@"\"" withString:@"'"] UTF8String]); [fm removeItemAtPath:tmp error:nil]; return 3; }
        printf("{\"compile_s\": %.2f, \"load_s\": %.2f}\n", compileMs / 1000, loadMs / 1000);
        fflush(stdout);

        size_t bytes = (size_t)S * D * 2;
        IOSurfaceRef sIn = surface(bytes), sOut = surface(bytes);
        IOSurfaceLock(sIn, 0, NULL);
        __fp16 *in = IOSurfaceGetBaseAddress(sIn);
        for (size_t i = 0; i < (size_t)S * D; i++) in[i] = (__fp16)(((double)(i * 2654435761u % 1000) / 1000.0 - 0.5));
        IOSurfaceUnlock(sIn, 0, NULL);
        id wIn = ((id(*)(Class,SEL,IOSurfaceRef))objc_msgSend)(Surf, @selector(objectWithIOSurface:), sIn);
        id wOut = ((id(*)(Class,SEL,IOSurfaceRef))objc_msgSend)(Surf, @selector(objectWithIOSurface:), sOut);
        id req = ((id(*)(Class,SEL,id,id,id,id,id,id,id))objc_msgSend)(Req,
            @selector(requestWithInputs:inputIndices:outputs:outputIndices:weightsBuffer:perfStats:procedureIndex:),
            @[wIn], @[@0], @[wOut], @[@0], nil, nil, @0);
        double best = 1e30, total = 0;
        for (int i = 0; i < evals; i++) {
            t0 = mach_absolute_time();
            ok = ((BOOL(*)(id,SEL,unsigned int,id,id,NSError**))objc_msgSend)(model, @selector(evaluateWithQoS:options:request:error:), 21, @{}, req, &err);
            double e = ms(mach_absolute_time() - t0);
            if (!ok) { printf("{\"evaluate\": \"FAILED\", \"error\": \"%s\"}\n", [[[err description] stringByReplacingOccurrencesOfString:@"\"" withString:@"'"] UTF8String]); break; }
            if (e < best) best = e; total += e;
        }
        IOSurfaceLock(sOut, kIOSurfaceLockReadOnly, NULL);
        __fp16 *out = IOSurfaceGetBaseAddress(sOut);
        int finite = 1; double mx = 0;
        for (size_t i = 0; i < (size_t)S * D; i += 97) { double v = out[i]; if (!isfinite(v)) finite = 0; if (fabs(v) > mx) mx = fabs(v); }
        if (getenv("DUMP_OUT")) {
            NSData *od = [NSData dataWithBytes:out length:bytes];
            [od writeToFile:[NSString stringWithUTF8String:getenv("DUMP_OUT")] atomically:YES];
        }
        IOSurfaceUnlock(sOut, kIOSurfaceLockReadOnly, NULL);
        printf("{\"eval_best_ms\": %.1f, \"eval_mean_ms\": %.1f, \"tflops\": %.2f, \"output_finite\": %s, \"output_max\": %.3g}\n",
               best, total / evals, flops / (best / 1000) / 1e12, finite ? "true" : "false", mx);
        ((BOOL(*)(id,SEL,unsigned int,NSError**))objc_msgSend)(model, @selector(unloadWithQoS:error:), 21, &err);
        if (!getenv("KEEP_TMP")) [fm removeItemAtPath:tmp error:nil];
        else printf("{\"kept\": \"%s\", \"compiledModelExists\": %s}\n", [tmp UTF8String],
                    ((BOOL(*)(id,SEL))objc_msgSend)(model, @selector(compiledModelExists)) ? "true" : "false");
        CFRelease(sIn); CFRelease(sOut);
    }
    return 0;
}
