@import Foundation;
@import MachO;

typedef void (^ _Null_unspecified LCParseMachOCallback)(const char * _Null_unspecified path, struct mach_header_64 * _Null_unspecified header, int fd, void * _Null_unspecified filePtr);

#define PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER 1
#define PATCH_EXEC_RESULT_SEG_COUNT_MISMATCH 2
#define PATCH_EXEC_RESULT_MISALIGNED_LINKEDIT_STRING_POOL 4

void LCPatchAppBundleFixupARM64eSlice(NSURL * _Null_unspecified bundleURL);
NSString * _Null_unspecified LCPatchMachOFixupARM64eSlice(const char * _Null_unspecified path);
NSString * _Null_unspecified LCParseMachO(const char * _Null_unspecified path, bool readOnly, NS_NOESCAPE LCParseMachOCallback callback);
void LCPatchAddRPath(const char * _Null_unspecified path, struct mach_header_64 * _Null_unspecified header);
int LCPatchExecSlice(const char * _Null_unspecified path, struct mach_header_64 * _Null_unspecified header, bool doInject);
void LCUnpatchExecSlice(const char * _Null_unspecified path, struct mach_header_64 * _Null_unspecified header);
NSString * _Nullable LCUnpatchMachOExecutableAtPath(const char * _Null_unspecified path);
void LCChangeMachOUUID(struct mach_header_64 * _Null_unspecified header);
const uint8_t * _Null_unspecified LCGetMachOUUID(struct mach_header_64 * _Null_unspecified header);
bool LCIsMachOEncrypted(struct mach_header_64 * _Null_unspecified header);
uint64_t LCFindSymbolOffset(const char * _Null_unspecified basePath, const char * _Null_unspecified symbol);
struct mach_header_64 * _Null_unspecified LCGetLoadedImageHeader(int i0, const char * _Null_unspecified name);
NSString * _Null_unspecified getEntitlementXML(struct mach_header_64 * _Null_unspecified header, void * _Null_unspecified * _Null_unspecified entitlementXMLPtrOut);
NSString * _Null_unspecified getExecutableEntitlementXML(NSString * _Null_unspecified path);
bool checkCodeSignature(const char * _Null_unspecified path);
