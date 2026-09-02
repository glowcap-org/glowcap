/* Frame ownership over the C ABI: a borrowed GlowcapFrame view over
   caller-owned bytes. The C ABI has no owned-frame constructor; an owned
   frame is a GlowcapManagedFrame from glowcap_host_session_take_outbound,
   as the host embedder example shows. */

#include "glowcap_ocapn.h"

#include <stdio.h>

int main(void) {
    const uint8_t bytes[] = {0xca, 0xfe, 0x00};
    const GlowcapFrame frame = {
        .bytes = bytes,
        .len = sizeof(bytes),
        .shape = GLOWCAP_FRAME_SHAPE_BYTE,
    };

    printf("shape=%u bytes=%zu\n", frame.shape, frame.len);
    return 0;
}
