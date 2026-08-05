#ifndef _CGS_H
#define _CGS_H

#include <CoreGraphics/CoreGraphics.h>

// Private CoreGraphics SPI: enable/disable a display at the OS level. macOS stops
// driving the display, which makes the monitor lose signal and enter standby on its
// own — no DDC cooperation from the monitor required.
extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config,
                                          CGDirectDisplayID display,
                                          bool enabled);

#endif
