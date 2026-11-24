//
//  SMCReader.m
//
//  AppleSMC 用户态只读访问。
//  关键点（踩过坑）：SMC 的 key 是 4 字节 ASCII，例如 "TC0P" => 0x54433050，
//  不是十六进制数值 0x70724330 之类。写错会得到 0x84 (key not found)。
//

#import "SMCReader.h"
#import <IOKit/IOKitLib.h>

typedef struct {
    char major, minor, build, reserved[1];
    unsigned short release;
} SMCVers;

typedef struct {
    unsigned short version, length;
    unsigned int cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimit;

typedef struct {
    unsigned int dataSize, dataType;
    char dataAttributes;
} SMCKeyInfo;

typedef struct {
    unsigned int key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    char result, status, data8;
    unsigned int data32;
    unsigned char bytes[32];
} SMCKeyData;

static const int kKernelIndexSMC = 2;
static const int kReadBytes = 5;
static const int kReadKeyInfo = 9;

static io_connect_t gConn = IO_OBJECT_NULL;
static NSTimeInterval gLastOpenAttempt = 0;

static BOOL smcEnsureOpen(void) {
    if (gConn) return YES;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastOpenAttempt < 5.0) return NO;   // 失败后别每 2 秒刷屏
    gLastOpenAttempt = now;

    io_service_t dev = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!dev) return NO;
    kern_return_t r = IOServiceOpen(dev, mach_task_self(), 0, &gConn);
    IOObjectRelease(dev);
    if (r != kIOReturnSuccess) { gConn = IO_OBJECT_NULL; return NO; }
    return YES;
}

static unsigned int smcKeyValue(const char *k) {
    return ((unsigned char)k[0] << 24) | ((unsigned char)k[1] << 16) |
           ((unsigned char)k[2] << 8)  | ((unsigned char)k[3]);
}

static kern_return_t smcCall(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(gConn, kKernelIndexSMC, in, sizeof(SMCKeyData), out, &outSize);
}

/// 读取 key，成功返回 YES 并填 outType/outSize/outBytes
static BOOL smcRead(const char *key, char outType[5], unsigned int *outSize, unsigned char outBytes[32]) {
    if (!smcEnsureOpen()) return NO;

    SMCKeyData in;
    memset(&in, 0, sizeof(in));
    in.key = smcKeyValue(key);
    in.data8 = kReadKeyInfo;

    SMCKeyData out;
    memset(&out, 0, sizeof(out));
    if (smcCall(&in, &out) != kIOReturnSuccess || out.result != 0) return NO;

    unsigned int size = out.keyInfo.dataSize;
    unsigned int type = out.keyInfo.dataType;
    if (size == 0 || size > 32) return NO;

    in.keyInfo.dataSize = size;
    in.data8 = kReadBytes;
    memset(&out, 0, sizeof(out));
    if (smcCall(&in, &out) != kIOReturnSuccess || out.result != 0) return NO;

    if (outType) {
        outType[0] = (char)(type >> 24);
        outType[1] = (char)(type >> 16);
        outType[2] = (char)(type >> 8);
        outType[3] = (char)type;
        outType[4] = 0;
    }
    if (outSize) *outSize = size;
    if (outBytes) memcpy(outBytes, out.bytes, 32);
    return YES;
}

static BOOL smcReadDouble(const char *key, double *outValue) {
    char type[5] = {0};
    unsigned int size = 0;
    unsigned char bytes[32] = {0};
    if (!smcRead(key, type, &size, bytes)) return NO;

    if (strcmp(type, "sp78") == 0 && size >= 2) {
        *outValue = ((int)(signed char)bytes[0] * 256 + (int)bytes[1]) / 256.0;
        return YES;
    }
    if (strcmp(type, "fpe2") == 0 && size >= 2) {
        *outValue = ((int)bytes[0] * 256 + (int)bytes[1]) / 4.0;
        return YES;
    }
    if (strcmp(type, "flt ") == 0 && size >= 4) {
        float f;
        memcpy(&f, bytes, 4);
        *outValue = f;
        return YES;
    }
    if (strcmp(type, "ui8 ") == 0 && size >= 1) { *outValue = bytes[0]; return YES; }
    if (strcmp(type, "ui16") == 0 && size >= 2) { *outValue = bytes[0] * 256.0 + bytes[1]; return YES; }
    return NO;
}

@implementation SMCSensor
@end

@implementation SMCReader

+ (instancetype)shared {
    static SMCReader *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SMCReader new]; });
    return s;
}

- (NSArray<SMCSensor *> *)readTemperatures {
    static NSArray<NSArray<NSString *> *> *spec;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        spec = @[
            @[@"TC0P", @"CPU 封装"],
            @[@"TC0D", @"CPU 核心 A"],
            @[@"TC0E", @"CPU 核心 B"],
            @[@"TC1C", @"CPU 核心 C"],
        ];
    });

    NSMutableArray<SMCSensor *> *list = [NSMutableArray array];
    for (NSArray<NSString *> *pair in spec) {
        SMCSensor *s = [SMCSensor new];
        s.key = pair[0];
        s.name = pair[1];
        double v = 0;
        s.available = smcReadDouble(pair[0].UTF8String, &v) && v > -20 && v < 150;
        s.value = s.available ? v : 0;
        [list addObject:s];
    }

    // GPU：本机 dGPU 被 -wegnoegpu 禁用，核显没有 SMC 温度键，正常都会不可用
    static NSArray<NSString *> *gpuKeys;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{ gpuKeys = @[@"TG0P", @"TG0D", @"TG1P", @"TI0P"]; });
    for (NSString *k in gpuKeys) {
        double v = 0;
        if (smcReadDouble(k.UTF8String, &v) && v > -20 && v < 150) {
            SMCSensor *s = [SMCSensor new];
            s.key = k;
            s.name = @"GPU 温度";
            s.value = v;
            s.available = YES;
            [list addObject:s];
            break;
        }
    }
    return list;
}

- (NSInteger)fanCount {
    double n = 0;
    if (!smcReadDouble("FNum", &n)) return 0;
    return (NSInteger)n;
}

- (NSNumber *)fanRPMAt:(NSInteger)index {
    if (index < 0 || index > 9) return nil;
    char key[5];
    snprintf(key, sizeof(key), "F%ldAc", (long)index);
    double rpm = 0;
    if (!smcReadDouble(key, &rpm)) return nil;
    return @(rpm);
}

@end
