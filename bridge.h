#ifndef _BRIDGE_H
#define _BRIDGE_H
#include <CoreGraphics/CoreGraphics.h>
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);
extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);
#endif
