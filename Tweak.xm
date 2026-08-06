#import <Foundation/Foundation.h>
// Emergency safe build: removed all global CALayer hooks.  In particular,
// never call presentationLayer from a CALayer setter hook: QuartzCore itself
// invokes these setters while creating presentation objects, causing recursion.
__attribute__((constructor)) static void SthenoBoundsSafeStart(void) {}
