@import Foundation;
@import MachO;

typedef void (^LCParseMachOCallback)(const char *path, struct mach_header_64 *header, int fd, void* filePtr);

#define PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER 1
#define PATCH_EXEC_RESULT_SEG_COUNT_MISMATCH 2

void LCPatchAppBundleFixupARM64eSlice(NSURL *bundleURL);
NSString *LCPatchMachOFixupARM64eSlice(const char *path);
NSString *LCParseMachO(const char *path, bool readOnly, NS_NOESCAPE LCParseMachOCallback callback);
void LCPatchAddRPath(const char *path, struct mach_header_64 *header);
int LCPatchExecSlice(const char * _Null_unspecified path, struct mach_header_64 * _Null_unspecified header, bool doInject);
void LCUnpatchExecSlice(const char * _Null_unspecified path, struct mach_header_64 * _Null_unspecified header);
NSString * _Nullable LCUnpatchMachOExecutableAtPath(const char * _Null_unspecified path);
void LCChangeMachOUUID(struct mach_header_64 *header);
const uint8_t* LCGetMachOUUID(struct mach_header_64 *header);
bool LCIsMachOEncrypted(struct mach_header_64 *header);
uint64_t LCFindSymbolOffset(const char *basePath, const char *symbol);
struct mach_header_64 *LCGetLoadedImageHeader(int i0, const char* name);
NSString* getEntitlementXML(struct mach_header_64* header, void** entitlementXMLPtrOut);
NSString* getExecutableEntitlementXML(NSString* path);
bool checkCodeSignature(const char* path);
