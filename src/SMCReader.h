//
//  SMCReader.h  —  AppleSMC 只读封装（AppleSMC key = 4 字节 ASCII！）
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SMCSensor : NSObject
@property (nonatomic, copy) NSString *key;    // 例如 TC0P
@property (nonatomic, copy) NSString *name;   // 例如 CPU 核心
@property (nonatomic, assign) double value;   // 摄氏度
@property (nonatomic, assign) BOOL available;
@end

@interface SMCReader : NSObject

+ (instancetype)shared;

/// 读一组温度键，返回全部（不可用的 available=NO）
- (NSArray<SMCSensor *> *)readTemperatures;

/// 风扇数量（本机为 0）
- (NSInteger)fanCount;

/// 风扇当前转速（fpe2 -> rpm），不可用时返回 nil
- (nullable NSNumber *)fanRPMAt:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
